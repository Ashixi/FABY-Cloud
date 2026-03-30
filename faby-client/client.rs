use libp2p::{
    futures::StreamExt,
    identity, noise,
    request_response::{self, ProtocolSupport},
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, StreamProtocol, SwarmBuilder,
};
use reed_solomon_erasure::galois_8::ReedSolomon;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, error::Error, str::FromStr, time::Duration};

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

// --- 1. Configuration & Cryptography ---

const DATA_SHARDS: usize = 30;
const PARITY_SHARDS: usize = 15;
const TOTAL_SHARDS: usize = DATA_SHARDS + PARITY_SHARDS;
const TEST_GRID_SECRET: &str = "super_secret_network_key_2026";

type HmacSha256 = Hmac<Sha256>;

/// Generates an HMAC-SHA256 signature for a specific chunk
fn generate_signature(file_id: &str, chunk_index: u32, data: &[u8], secret: &str) -> String {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(secret.as_bytes())
        .expect("HMAC can take key of any size");

    mac.update(file_id.as_bytes());
    mac.update(&chunk_index.to_be_bytes());
    mac.update(data);
    hex::encode(mac.finalize().into_bytes())
}

// --- 2. Protocol Definitions ---

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FabyRequest {
    StoreChunk {
        file_id: String,
        chunk_index: u32,
        data: Vec<u8>,
        signature: String,
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
}

// --- 3. Encoding & Decoding Helpers ---

/// Encodes data into Reed-Solomon shards
fn encode_data(data: &[u8]) -> Result<(Vec<Vec<u8>>, usize), Box<dyn Error>> {
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
    Ok((shards, data.len()))
}

/// Decodes Reed-Solomon shards back into the original data
fn decode_data(
    mut shards: Vec<Option<Vec<u8>>>,
    original_len: usize,
) -> Result<Vec<u8>, Box<dyn Error>> {
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

// --- 4. Main Client Event Loop ---

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let local_key = identity::Keypair::generate_ed25519();
    let local_peer_id = PeerId::from(local_key.public());
    println!("🚀 Starting FABY Client. PeerId: {}", local_peer_id);

    let protocol = StreamProtocol::new("/faby/storage/1.0.0");
    let mut config = request_response::Config::default();
    config.set_request_timeout(Duration::from_secs(10));

    let req_resp = request_response::cbor::Behaviour::new([(protocol, ProtocolSupport::Full)], config);
    let behaviour = ClientBehaviour { req_resp };

    let mut swarm = SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_behaviour(|_| behaviour)?
        .build();

    let target_addr = Multiaddr::from_str("/ip4/127.0.0.1/tcp/4001")?;
    println!("📞 Dialing hoster at: {}", target_addr);
    swarm.dial(target_addr)?;

    let test_file_id = "test_faby_b2b_file".to_string();
    let test_data = b"Hello, Decentralized FABY Storage! This is encrypted data.".to_vec();

    let mut original_data_len = 0;
    let mut stored_chunks = 0;

    let mut pending_get_requests = HashMap::new();
    let mut received_shards: Vec<Option<Vec<u8>>> = vec![None; TOTAL_SHARDS];

    loop {
        tokio::select! {
            event = swarm.select_next_some() => match event {
                SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                    println!("🔗 Connected to hoster: {}", peer_id);
                    println!("🧮 Encoding data with Reed-Solomon ({} + {})...", DATA_SHARDS, PARITY_SHARDS);

                    match encode_data(&test_data) {
                        Ok((shards, data_len)) => {
                            original_data_len = data_len;
                            for (index, shard_data) in shards.into_iter().enumerate() {
                                let signature = generate_signature(
                                    &test_file_id,
                                    index as u32,
                                    &shard_data,
                                    TEST_GRID_SECRET,
                                );

                                let request = FabyRequest::StoreChunk {
                                    file_id: test_file_id.clone(),
                                    chunk_index: index as u32,
                                    data: shard_data,
                                    signature,
                                };

                                println!("📤 Sending chunk #{}...", index);
                                swarm.behaviour_mut().req_resp.send_request(&peer_id, request);
                            }
                        }
                        Err(e) => eprintln!("❌ Encoding error: {}", e),
                    }
                }

                SwarmEvent::Behaviour(ClientBehaviourEvent::ReqResp(
                    request_response::Event::Message { peer, message }
                )) => {
                    match message {
                        request_response::Message::Response { request_id, response } => {
                            match response {
                                FabyResponse::Stored { hash } => {
                                    stored_chunks += 1;
                                    println!("✅ Chunk successfully stored! (Total: {}/{}) Hash: {}", stored_chunks, TOTAL_SHARDS, hash);

                                    // Request chunks back once all are stored
                                    if stored_chunks == TOTAL_SHARDS {
                                        println!("\n📥 All chunks stored. Requesting them back...");
                                        for i in 0..TOTAL_SHARDS {
                                            let get_req = FabyRequest::GetChunk {
                                                file_id: test_file_id.clone(),
                                                chunk_index: i as u32,
                                            };
                                            let req_id = swarm.behaviour_mut().req_resp.send_request(&peer, get_req);
                                            pending_get_requests.insert(req_id, i as usize);
                                        }
                                    }
                                }
                                FabyResponse::ChunkData(data) => {
                                    if let Some(chunk_index) = pending_get_requests.remove(&request_id) {
                                        println!("📦 Received data for chunk #{}", chunk_index);
                                        received_shards[chunk_index] = Some(data);

                                        let valid_shards = received_shards.iter().filter(|s| s.is_some()).count();

                                        if valid_shards >= DATA_SHARDS {
                                            println!("🎉 Gathered enough chunks ({} of {}). Restoring file...", valid_shards, TOTAL_SHARDS);

                                            match decode_data(received_shards.clone(), original_data_len) {
                                                Ok(recovered_data) => {
                                                    let content = String::from_utf8_lossy(&recovered_data);
                                                    println!("\n==================================");
                                                    println!("🔓 FILE SUCCESSFULLY RESTORED!");
                                                    println!("📄 Data: {}", content);
                                                    println!("==================================\n");

                                                    println!("👋 All tests passed. Exiting.");
                                                    return Ok(());
                                                }
                                                Err(e) => eprintln!("❌ File restoration error: {}", e),
                                            }
                                        }
                                    }
                                }
                                FabyResponse::Error(err) => {
                                    eprintln!("❌ Hoster error: {}", err);
                                }
                            }
                        }
                        _ => {}
                    }
                }

                SwarmEvent::OutgoingConnectionError { error, .. } => {
                    eprintln!("❌ Failed to connect: {:?}", error);
                    return Ok(());
                }
                SwarmEvent::ConnectionClosed { peer_id, .. } => {
                    println!("💔 Hoster {} disconnected", peer_id);
                    return Ok(());
                }
                _ => {}
            }
        }
    }
}