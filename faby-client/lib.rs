use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Key, Nonce,
};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use rand::{rngs::OsRng, RngCore};

use libp2p::{
    core::upgrade::Version,
    futures::StreamExt,
    identity, noise, relay,
    request_response::{self, ProtocolSupport},
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, StreamProtocol, SwarmBuilder, Transport,
};
use reed_solomon_erasure::galois_8::ReedSolomon;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, str::FromStr, time::Duration};

use once_cell::sync::Lazy;
use tokio::runtime::Runtime;

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

const DATA_SHARDS: usize = 30;
const PARITY_SHARDS: usize = 15;
const TOTAL_SHARDS: usize = DATA_SHARDS + PARITY_SHARDS;

static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("❌ Failed to initialize global Tokio runtime")
});

// --- 1. Cryptography & Signatures ---

fn generate_client_signature(
    file_id: &str,
    chunk_index: u32,
    data_len: usize,
    secret: &str,
) -> String {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(secret.as_bytes())
        .expect("HMAC can take key of any size");

    mac.update(file_id.as_bytes());
    mac.update(&chunk_index.to_be_bytes());
    mac.update(&data_len.to_be_bytes());
    hex::encode(mac.finalize().into_bytes())
}

#[pyfunction]
fn generate_random_key() -> PyResult<String> {
    let mut key = [0u8; 32];
    OsRng.fill_bytes(&mut key);
    Ok(STANDARD.encode(key))
}

#[pyfunction]
fn encrypt_data_with_key(data: Vec<u8>, base64_key: String) -> PyResult<Vec<u8>> {
    let key_bytes = STANDARD
        .decode(base64_key)
        .map_err(|e| PyValueError::new_err(format!("Base64 error: {}", e)))?;
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    
    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    
    let ciphertext = cipher
        .encrypt(nonce, data.as_ref())
        .map_err(|e| PyValueError::new_err(format!("Encryption error: {:?}", e)))?;
        
    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

#[pyfunction]
fn decrypt_data_with_key(encrypted_data: Vec<u8>, base64_key: String) -> PyResult<Vec<u8>> {
    if encrypted_data.len() < 28 {
        return Err(PyValueError::new_err("Data too short"));
    }
    
    let key_bytes = STANDARD
        .decode(base64_key)
        .map_err(|e| PyValueError::new_err(format!("Base64 error: {}", e)))?;
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    
    let nonce = Nonce::from_slice(&encrypted_data[0..12]);
    let ciphertext = &encrypted_data[12..];
    
    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| PyValueError::new_err(format!("Decryption error: {:?}", e)))?;
    Ok(plaintext)
}

// --- 2. Reed-Solomon Helpers ---

fn encode_data(data: &[u8]) -> Result<Vec<Vec<u8>>, Box<dyn std::error::Error>> {
    let rs = ReedSolomon::new(DATA_SHARDS, PARITY_SHARDS)?;
    let shard_size = (data.len() + DATA_SHARDS - 1) / DATA_SHARDS;
    let mut shards = vec![vec![0u8; shard_size]; TOTAL_SHARDS];

    for i in 0..DATA_SHARDS {
        let start = i * shard_size;
        let end = std::cmp::min(start + shard_size, data.len());
        let slice_len = end - start;

        if slice_len > 0 {
            shards[i][..slice_len].copy_from_slice(&data[start..end]);
        }
    }
    rs.encode(&mut shards)?;
    Ok(shards)
}

fn decode_data(
    mut shards: Vec<Option<Vec<u8>>>,
    original_len: usize,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let rs = ReedSolomon::new(DATA_SHARDS, PARITY_SHARDS)?;
    rs.reconstruct(&mut shards)?;

    let mut result = Vec::with_capacity(original_len);
    for i in 0..DATA_SHARDS {
        if let Some(shard) = &shards[i] {
            result.extend_from_slice(shard);
        }
    }
    result.truncate(original_len);
    Ok(result)
}

// --- 3. P2P Network Types & Behavior ---

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FabyRequest {
    StoreChunk {
        file_id: String,
        chunk_index: u32,
        data: Vec<u8>,
        client_access_key: String,
        signature: String,
        ticket: String,
    },
    GetChunk {
        file_id: String,
        chunk_index: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FabyResponse {
    Stored { hash: String },
    ChunkData(Vec<u8>),
    Error(String),
}

#[derive(NetworkBehaviour)]
struct ClientBehaviour {
    req_resp: request_response::cbor::Behaviour<FabyRequest, FabyResponse>,
    relay_client: relay::client::Behaviour,
}

fn generate_audits_for_chunk(chunk_data: &[u8], num_audits: usize) -> Vec<(String, String)> {
    let mut audits = Vec::new();
    for _ in 0..num_audits {
        let mut salt_bytes = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut salt_bytes);
        let salt_hex = hex::encode(salt_bytes);

        let mut hasher = Sha256::new();
        hasher.update(&salt_bytes);
        hasher.update(chunk_data);
        let hash_hex = hex::encode(hasher.finalize());

        audits.push((salt_hex, hash_hex));
    }
    audits
}

// --- 4. Core Async Network Functions ---

async fn do_upload_chunk(
    file_id: String,
    chunk_index: u32,
    data: Vec<u8>,
    addr_str: String,
    client_access_key: String,
    signature: String,
    ticket: String,
) -> Result<(u32, String, bool), anyhow::Error> {
    let local_key = identity::Keypair::generate_ed25519();
    let local_peer_id = PeerId::from(local_key.public());
    let protocol = StreamProtocol::new("/faby/storage/1.0.0");
    let config = request_response::Config::default().with_request_timeout(Duration::from_secs(60));

    let (relay_transport, relay_client) = relay::client::new(local_peer_id);
    let transport = tcp::tokio::Transport::default()
        .or_transport(relay_transport)
        .upgrade(Version::V1)
        .authenticate(noise::Config::new(&local_key).unwrap())
        .multiplex(yamux::Config::default())
        .boxed();

    let req_resp = request_response::cbor::Behaviour::<FabyRequest, FabyResponse>::new(
        [(protocol, ProtocolSupport::Full)],
        config,
    );
    let mut swarm = SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_other_transport(|_| transport)
        .unwrap()
        .with_behaviour(|_| ClientBehaviour { req_resp, relay_client })
        .unwrap()
        .build();

    // Sort addresses: direct connections first, p2p-circuit (relay) last
    let mut addrs: Vec<&str> = addr_str
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    addrs.sort_by_key(|a| a.contains("p2p-circuit"));

    let mut connected_peer = None;
    let mut used_relay = false;
    let mut successful_addr = String::new();

    for trimmed_addr in addrs {
        let target_addr = Multiaddr::from_str(trimmed_addr)?;
        if swarm.dial(target_addr).is_err() {
            continue;
        }

        let connect_res = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                match swarm.select_next_some().await {
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => return Ok(peer_id),
                    SwarmEvent::OutgoingConnectionError { .. } => return Err(anyhow::anyhow!("Dial error")),
                    _ => {}
                }
            }
        })
        .await;

        if let Ok(Ok(peer)) = connect_res {
            connected_peer = Some(peer);
            used_relay = trimmed_addr.contains("p2p-circuit");
            successful_addr = trimmed_addr.to_string();
            break;
        }
    }

    let peer_id = connected_peer
        .ok_or_else(|| anyhow::anyhow!("All connection attempts failed (Direct + Relay)"))?;

    let req = FabyRequest::StoreChunk {
        file_id: file_id.clone(),
        chunk_index,
        data: data.clone(),
        client_access_key,
        signature,
        ticket,
    };
    swarm.behaviour_mut().req_resp.send_request(&peer_id, req);

    loop {
        tokio::select! {
            event = swarm.select_next_some() => match event {
                SwarmEvent::Behaviour(ClientBehaviourEvent::ReqResp(event)) => match event {
                    request_response::Event::Message { message, .. } => match message {
                        request_response::Message::Response { response, .. } => match response {
                            FabyResponse::Stored { .. } => return Ok((chunk_index, successful_addr, used_relay)),
                            FabyResponse::Error(e) => return Err(anyhow::anyhow!(e)),
                            _ => return Err(anyhow::anyhow!("Unexpected response")),
                        },
                        _ => {}
                    },
                    request_response::Event::OutboundFailure { error, .. } => return Err(anyhow::anyhow!("{:?}", error)),
                    _ => {}
                },
                SwarmEvent::ConnectionClosed { cause, .. } => return Err(anyhow::anyhow!("{:?}", cause)),
                _ => {}
            }
        }
    }
}

async fn do_download_chunk(
    file_id: String,
    chunk_index: u32,
    addr_str: String,
) -> Result<(u32, Vec<u8>), anyhow::Error> {
    let local_key = identity::Keypair::generate_ed25519();
    let local_peer_id = PeerId::from(local_key.public());
    let protocol = StreamProtocol::new("/faby/storage/1.0.0");
    let config = request_response::Config::default().with_request_timeout(Duration::from_secs(60));

    let (relay_transport, relay_client) = relay::client::new(local_peer_id);
    let transport = tcp::tokio::Transport::default()
        .or_transport(relay_transport)
        .upgrade(Version::V1)
        .authenticate(noise::Config::new(&local_key).unwrap())
        .multiplex(yamux::Config::default())
        .boxed();

    let mut swarm = SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_other_transport(|_| transport)
        .unwrap()
        .with_behaviour(|_| ClientBehaviour {
            req_resp: request_response::cbor::Behaviour::<FabyRequest, FabyResponse>::new(
                [(protocol, ProtocolSupport::Full)],
                config,
            ),
            relay_client,
        })
        .unwrap()
        .build();

    let addrs: Vec<&str> = addr_str.split(',').collect();
    let mut connected_peer = None;

    for a in &addrs {
        let trimmed_addr = a.trim();
        if trimmed_addr.is_empty() {
            continue;
        }

        let target_addr = Multiaddr::from_str(trimmed_addr)?;
        if swarm.dial(target_addr).is_err() {
            continue;
        }

        let connect_res = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                match swarm.select_next_some().await {
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => return Ok(peer_id),
                    SwarmEvent::OutgoingConnectionError { .. } => return Err(anyhow::anyhow!("Dial error")),
                    _ => {}
                }
            }
        })
        .await;

        if let Ok(Ok(peer)) = connect_res {
            connected_peer = Some(peer);
            break;
        }
    }

    let peer_id = connected_peer.ok_or_else(|| anyhow::anyhow!("All connection attempts failed"))?;

    let req = FabyRequest::GetChunk { file_id, chunk_index };
    swarm.behaviour_mut().req_resp.send_request(&peer_id, req);

    loop {
        tokio::select! {
            event = swarm.select_next_some() => match event {
                SwarmEvent::Behaviour(ClientBehaviourEvent::ReqResp(event)) => match event {
                    request_response::Event::Message { message, .. } => match message {
                        request_response::Message::Response { response, .. } => match response {
                            FabyResponse::ChunkData(data) => return Ok((chunk_index, data)),
                            FabyResponse::Error(e) => return Err(anyhow::anyhow!(e)),
                            _ => return Err(anyhow::anyhow!("Unexpected response")),
                        },
                        _ => {}
                    },
                    request_response::Event::OutboundFailure { error, .. } => return Err(anyhow::anyhow!("{:?}", error)),
                    _ => {}
                },
                SwarmEvent::ConnectionClosed { cause, .. } => return Err(anyhow::anyhow!("{:?}", cause)),
                _ => {}
            }
        }
    }
}

// --- 5. PyO3 Python Bindings ---

#[pyfunction]
fn upload_to_p2p(
    file_id: String,
    data: Vec<u8>,
    hoster_addrs: Vec<String>,
    client_access_key: String,
    client_secret_key: String,
    ticket: String,
) -> PyResult<(HashMap<u32, (String, bool)>, HashMap<u32, Vec<(String, String)>>)> {
    RUNTIME.block_on(async {
        let shards = encode_data(&data).map_err(|e| PyValueError::new_err(e.to_string()))?;
        let mut tasks = vec![];
        let mut all_audits = HashMap::new();

        for (i, shard) in shards.into_iter().enumerate() {
            let addr = hoster_addrs.get(i % hoster_addrs.len()).cloned().unwrap_or_default();
            let fid = file_id.clone();
            let ak = client_access_key.clone();
            let tkt = ticket.clone();

            let sig = generate_client_signature(&fid, i as u32, shard.len(), &client_secret_key);

            let mut chunk_audits = Vec::new();
            for _ in 0..5 {
                let mut salt_bytes = [0u8; 16];
                rand::thread_rng().fill_bytes(&mut salt_bytes);
                let salt_hex = hex::encode(salt_bytes);

                let mut hasher = Sha256::new();
                hasher.update(&salt_bytes);
                hasher.update(&shard);
                let expected_hash = hex::encode(hasher.finalize());

                chunk_audits.push((salt_hex, expected_hash));
            }
            all_audits.insert(i as u32, chunk_audits);

            tasks.push(tokio::spawn(async move {
                tokio::time::timeout(
                    Duration::from_secs(120),
                    do_upload_chunk(fid, i as u32, shard, addr, ak, sig, tkt),
                )
                .await
            }));
        }

        let results = futures::future::join_all(tasks).await;
        let mut map = HashMap::new();

        for res in results {
            if let Ok(Ok(Ok((idx, addr, is_relay)))) = res {
                map.insert(idx, (addr, is_relay));
            }
        }

        if map.len() < DATA_SHARDS {
            return Err(PyValueError::new_err(format!(
                "Successfully uploaded only {} chunks. This is insufficient.",
                map.len()
            )));
        }

        let mut successful_audits = HashMap::new();
        for (idx, _tuple) in &map {
            if let Some(audits) = all_audits.remove(idx) {
                successful_audits.insert(*idx, audits);
            }
        }

        Ok((map, successful_audits))
    })
}

#[pyfunction]
fn download_from_p2p(
    file_id: String,
    chunk_map: HashMap<u32, String>,
    original_size: usize,
) -> PyResult<Vec<u8>> {
    RUNTIME.block_on(async {
        let mut tasks = vec![];

        for (idx, addr) in chunk_map {
            let fid = file_id.clone();
            tasks.push(tokio::spawn(async move {
                tokio::time::timeout(Duration::from_secs(60), do_download_chunk(fid, idx, addr))
                    .await
            }));
        }

        let results = futures::future::join_all(tasks).await;
        let mut received_shards: Vec<Option<Vec<u8>>> = vec![None; TOTAL_SHARDS];
        let mut valid_count = 0;

        for res in results {
            if let Ok(Ok(Ok((idx, data)))) = res {
                if (idx as usize) < TOTAL_SHARDS {
                    received_shards[idx as usize] = Some(data);
                    valid_count += 1;
                }
            }
        }

        if valid_count < DATA_SHARDS {
            return Err(PyValueError::new_err(format!(
                "Downloaded only {} chunks out of the required {}.",
                valid_count, DATA_SHARDS
            )));
        }

        let recovered = decode_data(received_shards, original_size)
            .map_err(|e| PyValueError::new_err(e.to_string()))?;

        Ok(recovered)
    })
}

#[pyfunction]
fn upload_block_to_p2p(
    file_id: String,
    block_index: u32,
    data: Vec<u8>,
    hoster_addrs: Vec<String>,
    client_access_key: String,
    client_secret_key: String,
    ticket: String,
) -> PyResult<(HashMap<u32, (String, bool)>, HashMap<u32, Vec<(String, String)>>)> {
    RUNTIME.block_on(async {
        let shards = encode_data(&data).map_err(|e| PyValueError::new_err(e.to_string()))?;
        let mut tasks = vec![];
        let mut all_audits = HashMap::new();

        for (i, shard) in shards.into_iter().enumerate() {
            // Calculate absolute chunk index based on the block index
            let abs_chunk_idx = block_index * (TOTAL_SHARDS as u32) + (i as u32);

            let addr = hoster_addrs.get(i % hoster_addrs.len()).cloned().unwrap_or_default();
            let fid = file_id.clone();
            let ak = client_access_key.clone();
            let tkt = ticket.clone();

            let sig = generate_client_signature(
                &fid,
                abs_chunk_idx,
                shard.len(),
                &client_secret_key,
            );

            let mut chunk_audits = Vec::new();
            for _ in 0..5 {
                let mut salt_bytes = [0u8; 16];
                rand::thread_rng().fill_bytes(&mut salt_bytes);
                
                // Simplified hash generation for audit mechanism
                let chunk_hash = hex::encode(
                    Sha256::digest(&salt_bytes)
                        .iter()
                        .zip(Sha256::digest(&shard).iter())
                        .map(|(a, b)| a ^ b)
                        .collect::<Vec<u8>>(),
                );
                chunk_audits.push((hex::encode(salt_bytes), chunk_hash));
            }
            all_audits.insert(abs_chunk_idx, chunk_audits);

            tasks.push(tokio::spawn(async move {
                tokio::time::timeout(
                    Duration::from_secs(120),
                    do_upload_chunk(fid, abs_chunk_idx, shard, addr, ak, sig, tkt),
                )
                .await
            }));
        }

        let results = futures::future::join_all(tasks).await;
        let mut map = HashMap::new();

        for res in results {
            if let Ok(Ok(Ok((idx, addr, is_relay)))) = res {
                map.insert(idx, (addr, is_relay));
            }
        }

        if map.len() < DATA_SHARDS {
            return Err(PyValueError::new_err(format!(
                "Successfully uploaded only {} chunks.",
                map.len()
            )));
        }

        let mut successful_audits = HashMap::new();
        for (idx, _) in &map {
            if let Some(audits) = all_audits.remove(idx) {
                successful_audits.insert(*idx, audits);
            }
        }

        Ok((map, successful_audits))
    })
}

#[pyfunction]
fn download_block_from_p2p(
    file_id: String,
    block_index: u32,
    chunk_map: HashMap<u32, String>,
    original_size: usize,
) -> PyResult<Vec<u8>> {
    RUNTIME.block_on(async {
        let mut tasks = vec![];

        for (idx, addr) in chunk_map {
            let fid = file_id.clone();
            tasks.push(tokio::spawn(async move {
                tokio::time::timeout(Duration::from_secs(60), do_download_chunk(fid, idx, addr))
                    .await
            }));
        }

        let results = futures::future::join_all(tasks).await;
        let mut received_shards: Vec<Option<Vec<u8>>> = vec![None; TOTAL_SHARDS];
        let mut valid_count = 0;

        for res in results {
            if let Ok(Ok(Ok((idx, data)))) = res {
                // Determine the local chunk index within this specific block
                let local_idx = (idx - (block_index * TOTAL_SHARDS as u32)) as usize;
                if local_idx < TOTAL_SHARDS {
                    received_shards[local_idx] = Some(data);
                    valid_count += 1;
                }
            }
        }

        if valid_count < DATA_SHARDS {
            return Err(PyValueError::new_err(
                "Insufficient chunks to restore the block.",
            ));
        }

        decode_data(received_shards, original_size)
            .map_err(|e| PyValueError::new_err(e.to_string()))
    })
}

#[pymodule]
fn faby_grid(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(generate_random_key, m)?)?;
    m.add_function(wrap_pyfunction!(encrypt_data_with_key, m)?)?;
    m.add_function(wrap_pyfunction!(decrypt_data_with_key, m)?)?;
    m.add_function(wrap_pyfunction!(upload_to_p2p, m)?)?;
    m.add_function(wrap_pyfunction!(download_from_p2p, m)?)?;
    // Ensure new functions are exposed to Python
    m.add_function(wrap_pyfunction!(upload_block_to_p2p, m)?)?;
    m.add_function(wrap_pyfunction!(download_block_from_p2p, m)?)?;
    Ok(())
}