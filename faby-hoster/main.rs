//! FABY Cloud Hoster Node
//!
//! This is the main entry point for the FABY storage node. It handles P2P networking,
//! disk allocation, storage management, and communication with the FABY Grid API.

use async_trait::async_trait;
use clap::{Parser, Subcommand};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use futures::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use futures_util::{SinkExt, StreamExt};
use libp2p::{
    core::upgrade::Version,
    identify, identity, noise, relay,
    request_response::{self, Codec, ProtocolSupport},
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, StreamProtocol, SwarmBuilder, Transport,
};
use reed_solomon_erasure::galois_8::ReedSolomon;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    error::Error,
    io::{self, Write},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use sysinfo::{get_current_pid, Disk, Disks, System};
use tokio::{
    fs,
    sync::{mpsc, oneshot, Mutex, Semaphore},
    time::interval,
};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};

// ============================================================================
// CONSTANTS
// ============================================================================

const DATA_SHARDS: usize = 30;
const PARITY_SHARDS: usize = 15;
const TOTAL_SHARDS: usize = DATA_SHARDS + PARITY_SHARDS;

const DATA_DIR: &str = "faby_data";
const CONFIG_FILE: &str = "faby_data/faby_config.json";
const KEY_FILE: &str = "faby_data/identity.bin";

/// Maximum P2P frame size (16 MB limit)
const MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;
/// Minimum allocation required for the node to operate (1 GB)
const MIN_REQUIRED_ALLOCATION_BYTES: u64 = 1024 * 1024 * 1024;
/// Space threshold to pause node operations (100 MB)
const PAUSE_THRESHOLD_BYTES: u64 = 100 * 1024 * 1024;

// ============================================================================
// CONFIGURATION & STATE
// ============================================================================

/// Represents storage allocation on a specific system disk.
#[derive(Serialize, Deserialize, Clone, Debug)]
struct DiskAllocation {
    mount_point: String,
    allocated_bytes: u64,
}

/// Core configuration for the Hoster Node.
#[derive(Serialize, Deserialize, Clone)]
struct NodeConfig {
    is_setup: bool,
    node_token: String,
    grid_public_key: String,
    disks: Vec<DiskAllocation>,
    bandwidth_mbps: u32,
    min_mbps_per_conn: u32,
    max_cpu_percent: u8,
}

impl Default for NodeConfig {
    fn default() -> Self {
        Self {
            is_setup: false,
            node_token: String::new(),
            grid_public_key: "241288b3ec7a13a678b3373a9d2e66ca08f8001ccbf1edb412fc117c59352574".to_string(),
            disks: Vec::new(),
            bandwidth_mbps: 100,
            min_mbps_per_conn: 2,
            max_cpu_percent: 50,
        }
    }
}

/// Real-time statistics and operational status of the node.
#[derive(Clone, Serialize)]
pub struct HosterStats {
    pub stored_chunks: u32,
    pub total_bytes_stored: u64,
    pub earnings_faby: f64,
    pub status: String,
    pub current_cpu_usage: f32,
    pub cpu_history: Vec<f32>,
}

/// Shared application state accessible across concurrent async tasks.
struct AppState {
    config: Mutex<NodeConfig>,
    stats: Mutex<HosterStats>,
    chunk_hits: Mutex<HashMap<(String, u32), u32>>,
}

// ============================================================================
// P2P NETWORK TYPES & CUSTOM CODEC
// ============================================================================

/// Internal commands for orchestrating P2P operations.
#[derive(Debug)]
enum P2pCommand {
    UseRelay(String),
    FetchChunk {
        file_id: String,
        chunk_index: u32,
        addr: String,
        resp_tx: oneshot::Sender<Result<Vec<u8>, String>>,
    },
    StoreChunk {
        file_id: String,
        chunk_index: u32,
        data: Vec<u8>,
        addr: String,
        resp_tx: oneshot::Sender<Result<(), String>>,
    },
}

/// Tracks outbound requests waiting for a response over the network.
enum PendingRequest {
    Fetch(oneshot::Sender<Result<Vec<u8>, String>>),
    Store(oneshot::Sender<Result<(), String>>),
}

/// Request payloads exchanged between nodes.
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

/// Response payloads exchanged between nodes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FabyResponse {
    Stored { hash: String },
    ChunkData(Vec<u8>),
    Error(String),
}

/// Custom libp2p codec supporting payloads up to `MAX_FRAME_SIZE` (16MB).
#[derive(Clone, Default)]
pub struct FabyCodec;

#[async_trait]
impl Codec for FabyCodec {
    type Protocol = StreamProtocol;
    type Request = FabyRequest;
    type Response = FabyResponse;

    async fn read_request<T>(&mut self, _: &Self::Protocol, io: &mut T) -> io::Result<Self::Request>
    where
        T: AsyncRead + Unpin + Send,
    {
        let mut len_buf = [0u8; 4];
        io.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;

        if len > MAX_FRAME_SIZE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Request payload exceeds size limit"));
        }

        let mut data = vec![0u8; len];
        io.read_exact(&mut data).await?;
        bincode::deserialize(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    async fn read_response<T>(&mut self, _: &Self::Protocol, io: &mut T) -> io::Result<Self::Response>
    where
        T: AsyncRead + Unpin + Send,
    {
        let mut len_buf = [0u8; 4];
        io.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;

        if len > MAX_FRAME_SIZE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Response payload exceeds size limit"));
        }

        let mut data = vec![0u8; len];
        io.read_exact(&mut data).await?;
        bincode::deserialize(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    async fn write_request<T>(&mut self, _: &Self::Protocol, io: &mut T, req: Self::Request) -> io::Result<()>
    where
        T: AsyncWrite + Unpin + Send,
    {
        let data = bincode::serialize(&req).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        io.write_all(&(data.len() as u32).to_be_bytes()).await?;
        io.write_all(&data).await?;
        io.close().await
    }

    async fn write_response<T>(&mut self, _: &Self::Protocol, io: &mut T, res: Self::Response) -> io::Result<()>
    where
        T: AsyncWrite + Unpin + Send,
    {
        let data = bincode::serialize(&res).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        io.write_all(&(data.len() as u32).to_be_bytes()).await?;
        io.write_all(&data).await?;
        io.close().await
    }
}

/// The core libp2p network behaviour combining necessary protocols.
#[derive(NetworkBehaviour)]
struct HosterBehaviour {
    req_resp: request_response::Behaviour<FabyCodec>,
    relay_client: relay::client::Behaviour,
    relay_server: relay::Behaviour,
    identify: identify::Behaviour,
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Reads interactive user input from the standard input.
fn prompt(msg: &str) -> String {
    print!("{}", msg);
    io::stdout().flush().unwrap();
    let mut buf = String::new();
    io::stdin().read_line(&mut buf).unwrap();
    buf.trim().to_string()
}

/// Parses string storage sizes (e.g., "100gb", "full") into raw byte counts.
fn parse_size(input: &str, available_bytes: u64) -> u64 {
    let s = input.trim().to_lowercase();
    if s.is_empty() || s == "0" {
        return 0;
    }
    if s == "full" {
        return available_bytes;
    }

    let multiplier = if s.ends_with("tb") {
        1024.0 * 1024.0 * 1024.0 * 1024.0
    } else if s.ends_with("gb") {
        1024.0 * 1024.0 * 1024.0
    } else if s.ends_with("mb") {
        1024.0 * 1024.0
    } else {
        1024.0 * 1024.0 * 1024.0 // Default to GB
    };

    let numeric_part = s.trim_end_matches(|c: char| c.is_alphabetic()).trim();
    if let Ok(val) = numeric_part.parse::<f64>() {
        return (val * multiplier) as u64;
    }
    0
}

/// Validates whether a system disk is appropriate for storage allocation (ignores virtual/system mounts).
fn is_valid_disk(disk: &Disk) -> bool {
    let mount = disk.mount_point().to_string_lossy().to_string();
    let fs_type = disk.file_system().to_string_lossy().to_lowercase();

    let is_virtual_fs = fs_type.contains("overlay")
        || fs_type.contains("tmpfs")
        || fs_type.contains("devtmpfs")
        || fs_type.contains("squashfs");

    let is_system_mount = mount.starts_with("/etc")
        || mount.starts_with("/dev")
        || mount.starts_with("/sys")
        || mount.starts_with("/proc")
        || mount.ends_with(".json")
        || mount.ends_with(".conf");

    !is_virtual_fs && !is_system_mount && disk.total_space() >= MIN_REQUIRED_ALLOCATION_BYTES
}

/// Loads the node configuration from disk, creating a default one if missing.
async fn load_config() -> NodeConfig {
    if let Ok(data) = fs::read_to_string(CONFIG_FILE).await {
        if let Ok(config) = serde_json::from_str(&data) {
            return config;
        }
    }
    NodeConfig::default()
}

/// Saves the current node configuration to disk.
async fn save_config(config: &NodeConfig) {
    let _ = fs::create_dir_all(DATA_DIR).await;
    let data = serde_json::to_string_pretty(config).expect("Failed to serialize configuration");
    fs::write(CONFIG_FILE, data).await.expect("Failed to save configuration");
}

/// Loads the Ed25519 identity keypair or generates a new one.
fn load_or_generate_key() -> identity::Keypair {
    let dir = std::path::Path::new(DATA_DIR);
    if !dir.exists() {
        let _ = std::fs::create_dir_all(dir);
    }

    if let Ok(bytes) = std::fs::read(KEY_FILE) {
        if let Ok(keypair) = identity::Keypair::from_protobuf_encoding(&bytes) {
            println!("🔑 Loaded existing P2P identity key.");
            return keypair;
        }
    }

    println!("🔑 Generating new P2P identity key...");
    let keypair = identity::Keypair::generate_ed25519();
    if let Ok(bytes) = keypair.to_protobuf_encoding() {
        let _ = std::fs::write(KEY_FILE, bytes);
    }
    keypair
}

/// Extracts the PeerId from a Multiaddr, if present.
fn extract_peer_id(addr: &Multiaddr) -> Option<PeerId> {
    addr.iter().find_map(|p| match p {
        libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
        _ => None,
    })
}

/// Checks if a local port is accessible from the outside network via the Central API.
async fn is_port_open_externally(api_url: &str, port: u16) -> bool {
    let client = Client::new();
    let url = format!("{}/grid/check-port?port={}", api_url, port);

    match client.get(&url).timeout(Duration::from_secs(5)).send().await {
        Ok(resp) if resp.status().is_success() => {
            resp.json::<serde_json::Value>().await
                .map(|json| json["is_open"].as_bool().unwrap_or(false))
                .unwrap_or(false)
        }
        _ => false,
    }
}

/// Validates an allocation ticket using Ed25519 signature verification against the grid public key.
fn verify_allocation_ticket(ticket: &str, expected_file_id: &str, grid_public_key_hex: &str) -> Result<u64, String> {
    let parts: Vec<&str> = ticket.split(':').collect();
    if parts.len() != 4 {
        return Err("Invalid ticket format".into());
    }

    let file_id = parts[0];
    let size_bytes: u64 = parts[1].parse().unwrap_or(0);
    let expires_at: u64 = parts[2].parse().unwrap_or(0);
    let signature_hex = parts[3];

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    if now > expires_at {
        return Err("Ticket expired".into());
    }
    if file_id != expected_file_id {
        return Err("Ticket file_id mismatch".into());
    }

    let payload = format!("{}:{}:{}", file_id, size_bytes, expires_at);

    let public_key_bytes = hex::decode(grid_public_key_hex).map_err(|_| "Invalid public key hex format")?;
    let public_key_array: [u8; 32] = public_key_bytes.try_into().map_err(|_| "Invalid public key length")?;
    let public_key = VerifyingKey::from_bytes(&public_key_array).map_err(|_| "Invalid public key bytes")?;

    let signature_bytes = hex::decode(signature_hex).map_err(|_| "Invalid signature hex format")?;
    let signature = Signature::from_slice(&signature_bytes).map_err(|_| "Invalid signature bytes")?;

    public_key.verify(payload.as_bytes(), &signature).map_err(|_| "Invalid ticket signature")?;

    Ok(size_bytes)
}

// ============================================================================
// STORAGE MANAGEMENT
// ============================================================================

/// Manages multi-disk I/O operations, chunk hashing, and caching.
struct MultiStorageManager {
    disks: Vec<DiskAllocation>,
}

impl MultiStorageManager {
    /// Initializes storage directories across all allocated disks.
    async fn new(disks: Vec<DiskAllocation>) -> Result<Self, Box<dyn Error>> {
        for disk in &disks {
            let vault_path = PathBuf::from(&disk.mount_point).join("faby_vault");
            let cache_path = vault_path.join("cache");

            if !vault_path.exists() {
                fs::create_dir_all(&vault_path).await?;
            }
            if !cache_path.exists() {
                fs::create_dir_all(&cache_path).await?;
            }
        }
        Ok(Self { disks })
    }

    fn hash_chunk(file_id: &str, chunk_index: u32) -> String {
        let mut hasher = Sha256::new();
        hasher.update(format!("{}_{}", file_id, chunk_index).as_bytes());
        hex::encode(hasher.finalize())
    }

    fn hash_cache(file_id: &str, chunk_index: u32) -> String {
        let mut hasher = Sha256::new();
        hasher.update(format!("cache_{}_{}", file_id, chunk_index).as_bytes());
        hex::encode(hasher.finalize())
    }

    /// Retrieves a chunk from the main vault.
    async fn get(&self, file_id: &str, chunk_index: u32) -> Result<Vec<u8>, String> {
        let hash = Self::hash_chunk(file_id, chunk_index);
        for disk in &self.disks {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join(&hash);
            if path.exists() {
                return fs::read(&path).await.map_err(|e| e.to_string());
            }
        }
        Err("Chunk not found in any vault".to_string())
    }

    /// Retrieves a chunk from the cache vault.
    async fn get_cache(&self, file_id: &str, chunk_index: u32) -> Result<Vec<u8>, String> {
        let hash = Self::hash_cache(file_id, chunk_index);
        for disk in &self.disks {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join("cache").join(&hash);
            if path.exists() {
                return fs::read(&path).await.map_err(|e| e.to_string());
            }
        }
        Err("Cache chunk not found".to_string())
    }

    /// Stores a chunk in the main vault (defaults to the first available disk).
    async fn store(&self, file_id: &str, chunk_index: u32, data: &[u8]) -> Result<String, String> {
        let hash = Self::hash_chunk(file_id, chunk_index);
        if let Some(disk) = self.disks.first() {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join(&hash);
            fs::write(&path, data).await.map_err(|e| e.to_string())?;
            return Ok(hash);
        }
        Err("No configured disks available for storage".to_string())
    }

    /// Stores a chunk in the cache vault.
    async fn store_cache(&self, file_id: &str, chunk_index: u32, data: &[u8]) -> Result<String, String> {
        let hash = Self::hash_cache(file_id, chunk_index);
        if let Some(disk) = self.disks.first() {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join("cache").join(&hash);
            fs::write(&path, data).await.map_err(|e| e.to_string())?;
            return Ok(hash);
        }
        Err("No configured disks available for cache".to_string())
    }

    /// Deletes a chunk from the main vault.
    async fn delete(&self, file_id: &str, chunk_index: u32) -> Result<(), String> {
        let hash = Self::hash_chunk(file_id, chunk_index);
        for disk in &self.disks {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join(&hash);
            if path.exists() {
                return fs::remove_file(&path).await.map_err(|e| e.to_string());
            }
        }
        Err("Chunk not found for deletion".to_string())
    }

    /// Deletes a chunk from the cache vault.
    async fn delete_cache(&self, file_id: &str, chunk_index: u32) -> Result<(), String> {
        let hash = Self::hash_cache(file_id, chunk_index);
        for disk in &self.disks {
            let path = PathBuf::from(&disk.mount_point).join("faby_vault").join("cache").join(&hash);
            if path.exists() {
                return fs::remove_file(&path).await.map_err(|e| e.to_string());
            }
        }
        Err("Cache chunk not found for deletion".to_string())
    }
}

// ============================================================================
// SIGNALING & GRID ORCHESTRATION
// ============================================================================

/// Manages the WebSocket connection to the grid for node orchestration and signaling.
async fn start_signaling_client(
    signaling_url: String,
    peer_id: String,
    multiaddr: String,
    token: String,
    storage: Arc<MultiStorageManager>,
    api_url: String,
    mut ws_rx: mpsc::UnboundedReceiver<serde_json::Value>,
    p2p_command_tx: mpsc::UnboundedSender<P2pCommand>,
) {
    let peer_id_clone = peer_id.clone();

    loop {
        let url_with_auth = format!("{}?token={}", signaling_url, token);

        if let Ok((ws_stream, _)) = connect_async(&url_with_auth).await {
            let (mut write, mut read) = ws_stream.split();

            // Announce the node to the signaling server (omitting hardware_id as required)
            let _ = write.send(Message::Text(
                json!({
                    "type": "announce_hoster",
                    "peer_id": peer_id,
                    "multiaddr": multiaddr,
                    "node_type": "storage"
                }).to_string(),
            )).await;

            let mut ping_interval = interval(Duration::from_secs(30));

            loop {
                tokio::select! {
                    // Send periodic ping to keep WS connection alive
                    _ = ping_interval.tick() => {
                        let _ = write.send(Message::Text(json!({ "type": "ping" }).to_string())).await;
                    }

                    // Forward outbound messages from internal channels to WS
                    out_msg = ws_rx.recv() => {
                        if let Some(msg) = out_msg {
                            let _ = write.send(Message::Text(msg.to_string())).await;
                        }
                    }

                    // Handle incoming messages from the WS server
                    msg = read.next() => {
                        if msg.is_none() { break; }

                        if let Ok(Message::Text(txt)) = msg.unwrap() {
                            let json_msg: serde_json::Value = serde_json::from_str(&txt).unwrap_or_default();

                            match json_msg["type"].as_str() {
                                // --- TEST TRANSFER --- //
                                Some("test_p2p_transfer") => {
                                    let target_addr = json_msg["target_multiaddr"].as_str().unwrap_or("").to_string();
                                    let fake_file_id = json_msg["fake_file_id"].as_str().unwrap_or("").to_string();
                                    let chunk_index = json_msg["chunk_index"].as_u64().unwrap_or(0) as u32;

                                    let cmd_tx = p2p_command_tx.clone();
                                    tokio::spawn(async move {
                                        let (tx, rx) = oneshot::channel();
                                        let _ = cmd_tx.send(P2pCommand::FetchChunk {
                                            file_id: fake_file_id, chunk_index, addr: target_addr, resp_tx: tx
                                        });
                                        let _ = rx.await;
                                    });
                                }

                                // --- HEAL CHUNK --- //
                                Some("heal_chunk") => {
                                    let file_id = json_msg["file_id"].as_str().unwrap_or("").to_string();
                                    let missing_idx = json_msg["missing_index"].as_u64().unwrap_or(0) as usize;
                                    let new_target = json_msg["new_target_addr"].as_str().unwrap_or("").to_string();
                                    let new_peer_id = json_msg["new_target_peer_id"].as_str().unwrap_or("").to_string();

                                    if let Some(sources_arr) = json_msg["sources"].as_array() {
                                        let sources = sources_arr.clone();
                                        let storage_clone = Arc::clone(&storage);
                                        let api_clone = api_url.clone();
                                        let cmd_tx = p2p_command_tx.clone();

                                        tokio::spawn(async move {
                                            let mut shards: Vec<Option<Vec<u8>>> = vec![None; TOTAL_SHARDS];
                                            let mut valid_count = 0;

                                            // Gather required chunks for reconstruction
                                            for src in sources {
                                                if let (Some(idx_val), Some(addr_val)) = (src["index"].as_u64(), src["addr"].as_str()) {
                                                    let idx = idx_val as usize;

                                                    if addr_val == "local" {
                                                        if let Ok(data) = storage_clone.get(&file_id, idx as u32).await {
                                                            shards[idx] = Some(data);
                                                            valid_count += 1;
                                                        }
                                                    } else {
                                                        let (tx, rx) = oneshot::channel();
                                                        let _ = cmd_tx.send(P2pCommand::FetchChunk {
                                                            file_id: file_id.clone(), chunk_index: idx as u32,
                                                            addr: addr_val.to_string(), resp_tx: tx,
                                                        });

                                                        if let Ok(Ok(data)) = rx.await {
                                                            shards[idx] = Some(data);
                                                            valid_count += 1;
                                                        }
                                                    }
                                                }
                                            }

                                            // Attempt Reed-Solomon reconstruction
                                            if valid_count >= DATA_SHARDS {
                                                match ReedSolomon::new(DATA_SHARDS, PARITY_SHARDS) {
                                                    Ok(rs) => {
                                                        if let Ok(_) = rs.reconstruct(&mut shards) {
                                                            if let Some(restored_data) = &shards[missing_idx] {
                                                                let (tx, rx) = oneshot::channel();
                                                                println!("🛠️ [Heal] Chunk #{} successfully restored locally. Sending to new node...", missing_idx);

                                                                let send_res = cmd_tx.send(P2pCommand::StoreChunk {
                                                                    file_id: file_id.clone(),
                                                                    chunk_index: missing_idx as u32,
                                                                    data: restored_data.clone(),
                                                                    addr: new_target,
                                                                    resp_tx: tx,
                                                                });

                                                                if send_res.is_ok() {
                                                                    if let Ok(Ok(())) = rx.await {
                                                                        let size_bytes = restored_data.len() as u64;
                                                                        let client = Client::new();
                                                                        println!("✅ [Heal] Chunk #{} successfully transferred and saved. Notifying API...", missing_idx);

                                                                        let _ = client.post(format!("{}/grid/heal-success", api_clone))
                                                                            .json(&json!({
                                                                                "file_id": file_id,
                                                                                "chunk_index": missing_idx,
                                                                                "new_peer_id": new_peer_id,
                                                                                "size_bytes": size_bytes
                                                                            }))
                                                                            .send().await;
                                                                    }
                                                                }
                                                            }
                                                        } else {
                                                            eprintln!("⚠️ [Heal Error] Failed to reconstruct data for file {}", file_id);
                                                        }
                                                    }
                                                    Err(e) => eprintln!("❌ [Heal Error] ReedSolomon matrix creation failed: {}", e),
                                                }
                                            } else {
                                                eprintln!("⚠️ [Heal] Not enough chunks to restore file {} (have {}, need {})", file_id, valid_count, DATA_SHARDS);
                                            }
                                        });
                                    }
                                }

                                // --- MIGRATE CHUNK --- //
                                Some("migrate_chunk") => {
                                    let file_id = json_msg["file_id"].as_str().unwrap_or("").to_string();
                                    let chunk_index = json_msg["chunk_index"].as_u64().unwrap_or(0) as u32;
                                    let target_addr = json_msg["target_addr"].as_str().unwrap_or("").to_string();
                                    let target_peer_id = json_msg["target_peer_id"].as_str().unwrap_or("").to_string();

                                    let storage_clone = Arc::clone(&storage);
                                    let api_clone = api_url.clone();
                                    let my_peer = peer_id_clone.clone();
                                    let cmd_tx = p2p_command_tx.clone();

                                    tokio::spawn(async move {
                                        if let Ok(data) = storage_clone.get(&file_id, chunk_index).await {
                                            let (tx, rx) = oneshot::channel();
                                            let _ = cmd_tx.send(P2pCommand::StoreChunk {
                                                file_id: file_id.clone(), chunk_index, data: data.clone(),
                                                addr: target_addr, resp_tx: tx,
                                            });

                                            if let Ok(Ok(())) = rx.await {
                                                let client = Client::new();
                                                let res = client.post(format!("{}/grid/migrate-success", api_clone))
                                                    .json(&json!({
                                                        "file_id": file_id,
                                                        "chunk_index": chunk_index,
                                                        "old_peer_id": my_peer,
                                                        "new_peer_id": target_peer_id
                                                    }))
                                                    .send().await;

                                                if res.is_ok() {
                                                    let _ = storage_clone.delete(&file_id, chunk_index).await;
                                                }
                                            }
                                        }
                                    });
                                }

                                // --- CACHE HOT CHUNK --- //
                                Some("cache_hot_chunk") => {
                                    let file_id = json_msg["file_id"].as_str().unwrap_or("").to_string();
                                    let chunk_index = json_msg["chunk_index"].as_u64().unwrap_or(0) as u32;
                                    let source_addr = json_msg["source_multiaddr"].as_str().unwrap_or("").to_string();

                                    let storage_clone = Arc::clone(&storage);
                                    let api_clone = api_url.clone();
                                    let my_peer = peer_id_clone.clone();
                                    let cmd_tx = p2p_command_tx.clone();

                                    tokio::spawn(async move {
                                        let (tx, rx) = oneshot::channel();
                                        let _ = cmd_tx.send(P2pCommand::FetchChunk {
                                            file_id: file_id.clone(), chunk_index, addr: source_addr, resp_tx: tx
                                        });

                                        if let Ok(Ok(data)) = rx.await {
                                            if storage_clone.store_cache(&file_id, chunk_index, &data).await.is_ok() {
                                                let size_bytes = data.len() as u64;
                                                let client = Client::new();
                                                let _ = client.post(format!("{}/grid/cdn-cache-success", api_clone))
                                                    .json(&json!({
                                                        "file_id": file_id,
                                                        "chunk_index": chunk_index,
                                                        "peer_id": my_peer,
                                                        "size_bytes": size_bytes
                                                    }))
                                                    .send().await;
                                            }
                                        }
                                    });
                                }

                                // --- DELETE CHUNK --- //
                                Some("delete_chunk") => {
                                    let file_id = json_msg["file_id"].as_str().unwrap_or("").to_string();
                                    let chunk_index = json_msg["chunk_index"].as_u64().unwrap_or(0) as u32;
                                    let is_cache = json_msg["is_cache"].as_bool().unwrap_or(false);

                                    let storage_clone = Arc::clone(&storage);
                                    tokio::spawn(async move {
                                        if is_cache {
                                            let _ = storage_clone.delete_cache(&file_id, chunk_index).await;
                                        } else {
                                            let _ = storage_clone.delete(&file_id, chunk_index).await;
                                        }
                                    });
                                }

                                // --- SUGGEST RELAY --- //
                                Some("suggest_relay") => {
                                    if let Some(relay_addr_str) = json_msg["relay_multiaddr"].as_str() {
                                        let p2p_command_tx_clone = p2p_command_tx.clone();
                                        let relay_addr_owned = relay_addr_str.to_string();

                                        tokio::spawn(async move {
                                            tokio::time::sleep(Duration::from_secs(10)).await;
                                            let _ = p2p_command_tx_clone.send(P2pCommand::UseRelay(relay_addr_owned));
                                        });
                                    }
                                }

                                // --- AUDIT REQUEST --- //
                                Some("audit_request") => {
                                    let file_id = json_msg["file_id"].as_str().unwrap_or("").to_string();
                                    let chunk_index = json_msg["chunk_index"].as_u64().unwrap_or(0) as u32;
                                    let salt = json_msg["salt"].as_str().unwrap_or("").to_string();
                                    let audit_id = json_msg["audit_id"].as_u64().unwrap_or(0);

                                    let storage_clone = Arc::clone(&storage);
                                    let api_clone = api_url.clone();
                                    let my_peer = peer_id_clone.clone();

                                    tokio::spawn(async move {
                                        let proof_hash = match storage_clone.get(&file_id, chunk_index).await {
                                            Ok(data) => {
                                                if let Ok(salt_bytes) = hex::decode(&salt) {
                                                    let mut hasher = Sha256::new();
                                                    hasher.update(&salt_bytes);
                                                    hasher.update(&data);
                                                    hex::encode(hasher.finalize())
                                                } else {
                                                    "FILE_NOT_FOUND".to_string()
                                                }
                                            }
                                            Err(_) => "FILE_NOT_FOUND".to_string(),
                                        };

                                        let client = Client::new();
                                        let _ = client.post(format!("{}/grid/audit-reply", api_clone))
                                            .json(&json!({
                                                "audit_id": audit_id,
                                                "peer_id": my_peer,
                                                "proof_hash": proof_hash
                                            }))
                                            .send().await;
                                    });
                                }
                                _ => {}
                            }
                        }
                    }
                }
            }
        } else {
            println!("⚠️ Connection error to Signaling server: {}", signaling_url);
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

// ============================================================================
// CLI STRUCTURE
// ============================================================================

#[derive(Parser)]
#[command(name = "faby-grid", about = "FABY Cloud Hoster Node (Headless)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initial setup configuration for the node
    Setup {
        #[arg(long, env = "FABY_NODE_TOKEN")]
        token: Option<String>,
        #[arg(long, env = "FABY_GRID_PUBLIC_KEY")]
        _public_key: Option<String>,
        #[arg(long, env = "FABY_MAX_CPU")]
        cpu: Option<u8>,
        #[arg(long, env = "FABY_BW_MBPS")]
        bw: Option<u32>,
        #[arg(long, env = "FABY_MIN_BW_MBPS")]
        min_bw: Option<u32>,
        #[arg(long, env = "FABY_AUTO_ALLOCATE_GB")]
        auto_allocate_gb: Option<u64>,
    },
    /// Start the active hoster node
    Start {
        #[arg(long, env = "FABY_PORT", default_value_t = 4001)]
        p2p_port: u16,
    },
}

// ============================================================================
// MAIN APPLICATION ENTRY POINT
// ============================================================================

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();

    match cli.command {
        // --------------------------------------------------------------------
        // SETUP COMMAND
        // --------------------------------------------------------------------
        Commands::Setup { token, _public_key, cpu, bw, min_bw, auto_allocate_gb } => {
            println!("=======================================");
            println!("🛠  FABY HOSTER NODE SETUP");
            println!("=======================================\n");

            let final_token = token.unwrap_or_else(|| prompt("🔑 Enter your Node Token (from website): "));
            if final_token.is_empty() {
                println!("❌ Token cannot be empty!");
                return Ok(());
            }

            println!("\n🌐 Connecting to Central API to fetch network public key...");
            let api_url = env::var("FABY_API_URL").unwrap_or_else(|_| "https://api.boardly.studio".to_string());
            let client = reqwest::Client::new();

            let final_pub_key = match client.get(format!("{}/grid/public-key", api_url)).send().await {
                Ok(resp) if resp.status().is_success() => {
                    let json: serde_json::Value = resp.json().await.unwrap_or_default();
                    if let Some(key) = json["public_key"].as_str() {
                        println!("✅ Network public key successfully fetched automatically!");
                        key.to_string()
                    } else {
                        println!("❌ Error: API did not return public_key.");
                        return Ok(());
                    }
                },
                _ => {
                    println!("❌ Failed to connect to Central API to fetch key. Check your connection.");
                    return Ok(());
                }
            };

            let final_cpu: u8 = cpu.unwrap_or_else(|| prompt("💻 Max CPU usage (%): ").parse().unwrap_or(50));
            let final_bw: u32 = bw.unwrap_or_else(|| prompt("🌐 Total bandwidth limit (Mbps): ").parse().unwrap_or(20));
            let final_min_bw: u32 = min_bw.unwrap_or_else(|| prompt("⚡ Min bandwidth per connection (Mbps): ").parse().unwrap_or(2));

            println!("\n🔍 Scanning disks...");
            let disks = Disks::new_with_refreshed_list();
            let mut disks_config = Vec::new();

            let mut remaining_auto_alloc_bytes = auto_allocate_gb.map(|gb| gb * 1024 * 1024 * 1024);

            for disk in disks.list() {
                if !is_valid_disk(disk) {
                    continue;
                }

                let name = disk.name().to_string_lossy();
                let mount = disk.mount_point().to_string_lossy();
                let available_gb = disk.available_space() as f64 / 1_073_741_824.0;
                let total_gb = disk.total_space() as f64 / 1_073_741_824.0;

                if let Some(ref mut needed) = remaining_auto_alloc_bytes {
                    if *needed > 0 {
                        let to_allocate = std::cmp::min(*needed, disk.available_space());
                        if to_allocate > 0 {
                            disks_config.push(DiskAllocation {
                                mount_point: mount.to_string(),
                                allocated_bytes: to_allocate,
                            });
                            *needed -= to_allocate;
                            println!("✅ Automatically allocated {:.2} GB on {} ({})", to_allocate as f64 / 1_073_741_824.0, name, mount);
                        }
                    }
                } else {
                    println!("\n💽 Disk: {} (Mount point: {})", name, mount);
                    println!("   Total: {:.2} GB | Available: {:.2} GB", total_gb, available_gb);

                    let ans = prompt("   Specify how much to allocate (e.g. '100gb', 'full', or Enter to skip): ");

                    let requested = parse_size(&ans, disk.available_space());
                    if requested > 0 {
                        let allocated = requested.min(disk.available_space());
                        disks_config.push(DiskAllocation {
                            mount_point: mount.to_string(),
                            allocated_bytes: allocated,
                        });
                        println!("   ✅ Allocated {:.2} GB on {}", allocated as f64 / 1_073_741_824.0, mount);
                    } else {
                        println!("   ⏭  Skipped.");
                    }
                }
            }

            let total_allocated: u64 = disks_config.iter().map(|d| d.allocated_bytes).sum();

            if disks_config.is_empty() {
                println!("\n❌ Error: No space allocated on any disk!");
                return Ok(());
            }

            if total_allocated < MIN_REQUIRED_ALLOCATION_BYTES {
                println!("\n❌ Error: Total allocated space ({:.2} GB) is less than required minimum (1 GB).", total_allocated as f64 / 1_073_741_824.0);
                return Ok(());
            }

            let config = NodeConfig {
                is_setup: true,
                node_token: final_token,
                grid_public_key: final_pub_key,
                disks: disks_config,
                bandwidth_mbps: final_bw,
                min_mbps_per_conn: final_min_bw,
                max_cpu_percent: final_cpu,
            };

            save_config(&config).await;
            println!("\n✅ Configuration saved to {}!", CONFIG_FILE);
            Ok(())
        }

        // --------------------------------------------------------------------
        // START COMMAND
        // --------------------------------------------------------------------
        Commands::Start { p2p_port } => {
            let api_url = env::var("FABY_API_URL").unwrap_or_else(|_| "https://api.faby.world".to_string());
            let config = load_config().await;

            if !config.is_setup || config.disks.is_empty() {
                println!("❌ Node is not configured. Run 'faby-grid setup' first.");
                return Ok(());
            }

            let max_concurrent_requests = if config.bandwidth_mbps > 0 && config.min_mbps_per_conn > 0 {
                (config.bandwidth_mbps / config.min_mbps_per_conn).max(1) as usize
            } else {
                100
            };

            let transfer_semaphore = Arc::new(Semaphore::new(max_concurrent_requests));
            println!("🚀 [Setup] Dynamic bandwidth limit applied: max {} concurrent threads", max_concurrent_requests);

            let state = Arc::new(AppState {
                config: Mutex::new(config.clone()),
                stats: Mutex::new(HosterStats {
                    stored_chunks: 0,
                    total_bytes_stored: 0,
                    earnings_faby: 0.0,
                    status: "Online (Connected to Grid)".to_string(),
                    current_cpu_usage: 0.0,
                    cpu_history: Vec::new(),
                }),
                chunk_hits: Mutex::new(HashMap::new()),
            });

            // DAEMON: CPU Monitor
            let monitor_state = Arc::clone(&state);
            tokio::spawn(async move {
                let mut sys = System::new_all();
                let pid = match get_current_pid() {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("Failed to get PID: {}", e);
                        return;
                    }
                };
                let mut interval = interval(Duration::from_secs(2));

                loop {
                    interval.tick().await;
                    sys.refresh_cpu_usage();
                    sys.refresh_processes();

                    let num_cores = sys.cpus().len() as f32;
                    let new_usage = if let Some(process) = sys.process(pid) {
                        process.cpu_usage() / num_cores.max(1.0)
                    } else {
                        0.0
                    };

                    let mut stats = monitor_state.stats.lock().await;
                    stats.cpu_history.push(new_usage);
                    if stats.cpu_history.len() > 5 {
                        stats.cpu_history.remove(0);
                    }
                    let sum: f32 = stats.cpu_history.iter().sum();
                    stats.current_cpu_usage = sum / stats.cpu_history.len() as f32;
                }
            });

            println!("✅ Local configuration validated! Initializing P2P Networking...");

            let local_key = load_or_generate_key();
            let local_peer_id = PeerId::from(local_key.public());
            let storage = Arc::new(MultiStorageManager::new(config.disks.clone()).await.unwrap());
            let gc_disks = config.disks.clone();

            // DAEMON: Cache Cleanup (Garbage Collector)
            tokio::spawn(async move {
                let mut interval = interval(Duration::from_secs(3600)); // Hourly
                loop {
                    interval.tick().await;
                    for disk in &gc_disks {
                        let cache_dir = PathBuf::from(&disk.mount_point).join("faby_vault").join("cache");
                        if let Ok(mut entries) = fs::read_dir(&cache_dir).await {
                            while let Ok(Some(entry)) = entries.next_entry().await {
                                if let Ok(metadata) = entry.metadata().await {
                                    if let Ok(modified) = metadata.modified() {
                                        if let Ok(elapsed) = modified.elapsed() {
                                            // Expire cache items older than 24h
                                            if elapsed > Duration::from_secs(24 * 3600) {
                                                let _ = fs::remove_file(entry.path()).await;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            });

            // P2P Swarm Initialization
            let mut relay_config = relay::Config::default();
            relay_config.max_circuits = 16;
            relay_config.max_circuit_bytes = 20 * 1024 * 1024;
            relay_config.max_circuit_duration = Duration::from_secs(60 * 5);

            let (relay_transport, relay_client) = relay::client::new(local_peer_id);

            let mut yamux_config = yamux::Config::default();
            yamux_config.set_max_buffer_size(MAX_FRAME_SIZE);
            yamux_config.set_receive_window_size(MAX_FRAME_SIZE);

            let transport = tcp::tokio::Transport::default()
                .or_transport(relay_transport)
                .upgrade(Version::V1)
                .authenticate(noise::Config::new(&local_key).unwrap())
                .multiplex(yamux_config)
                .boxed();

            let identify_config = identify::Config::new("/faby/storage/1.0.0".to_string(), local_key.public());

            let mut swarm = SwarmBuilder::with_existing_identity(local_key.clone())
                .with_tokio()
                .with_other_transport(|_| transport)
                .unwrap()
                .with_behaviour(|_| {
                    let req_resp_config = request_response::Config::default()
                        .with_request_timeout(Duration::from_secs(60));

                    HosterBehaviour {
                        req_resp: request_response::Behaviour::with_codec(
                            FabyCodec,
                            [(StreamProtocol::new("/faby/storage/1.0.0"), ProtocolSupport::Full)],
                            req_resp_config,
                        ),
                        relay_client,
                        relay_server: relay::Behaviour::new(local_peer_id, relay_config),
                        identify: identify::Behaviour::new(identify_config),
                    }
                })
                .unwrap()
                .build();

            let listen_addr_ipv4 = format!("/ip4/0.0.0.0/tcp/{}", p2p_port);
            swarm.listen_on(listen_addr_ipv4.parse().unwrap()).expect("Failed to start listening on IPv4 interface");

            let (ws_tx, ws_rx) = mpsc::unbounded_channel::<serde_json::Value>();
            let mut ws_rx_opt = Some(ws_rx);

            // DAEMON: Storage Monitoring (Docker-Safe Version)
            let storage_monitor_state = Arc::clone(&state);
            let monitor_ws_tx = ws_tx.clone();

            tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(30));

                loop {
                    interval.tick().await;

                    let config = storage_monitor_state.config.lock().await;
                    let total_target_allocation: u64 = config.disks.iter().map(|d| d.allocated_bytes).sum();
                    drop(config);

                    let mut stats = storage_monitor_state.stats.lock().await;
                    let actual_usable_space = total_target_allocation.saturating_sub(stats.total_bytes_stored);
                    let is_paused = actual_usable_space < PAUSE_THRESHOLD_BYTES;

                    if is_paused && stats.status != "Paused (Insufficient space)" {
                        stats.status = "Paused (Insufficient space)".to_string();
                        println!("⚠️ [Space Monitor] Node Paused! Limit Remaining: {} bytes, Required: {} bytes", actual_usable_space, PAUSE_THRESHOLD_BYTES);

                        let _ = monitor_ws_tx.send(serde_json::json!({
                            "type": "capacity_update",
                            "status": "paused",
                            "actual_remaining_bytes": actual_usable_space,
                            "target_allocation": total_target_allocation
                        }));
                    } else if !is_paused && stats.status == "Paused (Insufficient space)" {
                        stats.status = "Online (Connected to Grid)".to_string();
                        println!("🚀 [Space Monitor] Space cleared. Node is back Online!");

                        let _ = monitor_ws_tx.send(serde_json::json!({
                            "type": "capacity_update",
                            "status": "active",
                            "actual_remaining_bytes": actual_usable_space,
                            "target_allocation": total_target_allocation
                        }));
                    } else if !is_paused {
                        let _ = monitor_ws_tx.send(serde_json::json!({
                            "type": "capacity_update",
                            "status": "active",
                            "actual_remaining_bytes": actual_usable_space,
                            "target_allocation": total_target_allocation
                        }));
                    }

                    drop(stats);
                }
            });

            let (p2p_cmd_tx, mut p2p_cmd_rx) = mpsc::unbounded_channel::<P2pCommand>();
            let (resp_channel_tx, mut resp_channel_rx) = mpsc::unbounded_channel::<(request_response::ResponseChannel<FabyResponse>, FabyResponse)>();
            let mut pending_requests = HashMap::<request_response::OutboundRequestId, PendingRequest>::new();
            let mut announced = false;

            // ----------------------------------------------------------------
            // EVENT LOOP: P2P Swarm & Commands
            // ----------------------------------------------------------------
            loop {
                tokio::select! {
                    // Handle internal P2P orchestration commands
                    cmd = p2p_cmd_rx.recv() => {
                        if let Some(command) = cmd {
                            match command {
                                P2pCommand::UseRelay(relay_addr_str) => {
                                    if let Ok(relay_addr) = relay_addr_str.parse::<Multiaddr>() {
                                        let _ = swarm.dial(relay_addr.clone());
                                        let circuit_addr = relay_addr.with(libp2p::multiaddr::Protocol::P2pCircuit);
                                        let _ = swarm.listen_on(circuit_addr);
                                    }
                                }
                                P2pCommand::FetchChunk { file_id, chunk_index, addr, resp_tx } => {
                                    if let Ok(multiaddr) = addr.parse::<Multiaddr>() {
                                        if let Some(peer_id) = extract_peer_id(&multiaddr) {
                                            let _ = swarm.dial(multiaddr);
                                            let req_id = swarm.behaviour_mut().req_resp.send_request(&peer_id, FabyRequest::GetChunk { file_id, chunk_index });
                                            pending_requests.insert(req_id, PendingRequest::Fetch(resp_tx));
                                        } else {
                                            let _ = resp_tx.send(Err("Invalid Multiaddr format".to_string()));
                                        }
                                    } else {
                                        let _ = resp_tx.send(Err("Invalid Multiaddr".to_string()));
                                    }
                                }
                                P2pCommand::StoreChunk { file_id, chunk_index, data, addr, resp_tx } => {
                                    if let Ok(multiaddr) = addr.parse::<Multiaddr>() {
                                        if let Some(peer_id) = extract_peer_id(&multiaddr) {
                                            let _ = swarm.dial(multiaddr);

                                            let expires_at = std::time::SystemTime::now()
                                                .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 300;
                                            let internal_ticket = format!("{}:{}:{}:INTERNAL_SIG", file_id, data.len(), expires_at);

                                            let req_id = swarm.behaviour_mut().req_resp.send_request(&peer_id, FabyRequest::StoreChunk {
                                                file_id,
                                                chunk_index,
                                                data,
                                                signature: "INTERNAL".to_string(),
                                                client_access_key: "INTERNAL_SYSTEM_OP".to_string(),
                                                ticket: internal_ticket
                                            });
                                            pending_requests.insert(req_id, PendingRequest::Store(resp_tx));
                                        } else {
                                            let _ = resp_tx.send(Err("Invalid Multiaddr format".to_string()));
                                        }
                                    } else {
                                        let _ = resp_tx.send(Err("Invalid Multiaddr".to_string()));
                                    }
                                }
                            }
                        }
                    }

                    // Forward responses back to pending network channels
                    Some((channel, response)) = resp_channel_rx.recv() => {
                        let _ = swarm.behaviour_mut().req_resp.send_response(channel, response);
                    }

                    // Main libp2p Swarm Event Handler
                    event = swarm.select_next_some() => match event {
                        SwarmEvent::NewListenAddr { address, .. } => {
                            let is_circuit = address.iter().any(|p| matches!(p, libp2p::multiaddr::Protocol::P2pCircuit));

                            let token = state.config.lock().await.node_token.clone();
                            let p_id = local_peer_id.to_string();

                            let mut final_addr = address.clone();
                            if !final_addr.iter().any(|p| matches!(p, libp2p::multiaddr::Protocol::P2p(_))) {
                                final_addr.push(libp2p::multiaddr::Protocol::P2p(local_peer_id));
                            }
                            let m_addr = final_addr.to_string();

                            if !is_circuit && !announced {
                                announced = true;
                                let sig_url = env::var("FABY_SIGNALING_URL").unwrap_or_else(|_| "wss://api.faby.world/ws/signaling".to_string());
                                let st = Arc::clone(&storage);
                                let api = api_url.clone();
                                let cmd_tx = p2p_cmd_tx.clone();
                                let rx = ws_rx_opt.take().unwrap();
                                let current_port = p2p_port;

                                println!("✅ Physical network interface initialized. Checking port accessibility...");

                                tokio::spawn(async move {
                                    // Query Central API to check if node is externally reachable
                                    let is_open = is_port_open_externally(&api, current_port).await;

                                    let address_to_announce = if is_open {
                                        println!("🌐 Port {} is OPEN! Connecting as a direct Storage Node.", current_port);
                                        m_addr // Expose the real multiaddr
                                    } else {
                                        println!("⚠️ Port {} is CLOSED (NAT/Firewall). Connecting and waiting for Relay...", current_port);
                                        "".to_string() // Hide multiaddr to prevent network pollution
                                    };

                                    // Boot up signaling client
                                    start_signaling_client(sig_url, p_id, address_to_announce, token, st, api, rx, cmd_tx).await;
                                });
                            } else if is_circuit && announced {
                                // Re-announce new circuit address to the Grid after successful relay connection
                                println!("🔗 Successfully connected via Relay! Announcing route to the Grid.");
                                let _ = ws_tx.send(json!({"type": "announce_hoster", "peer_id": p_id, "multiaddr": m_addr, "node_type": "storage"}));
                            }
                        }

                        // Network Request Processing
                        SwarmEvent::Behaviour(HosterBehaviourEvent::ReqResp(request_response::Event::Message { message, .. })) => {
                            match message {
                                request_response::Message::Request { request, channel, .. } => {
                                    match request {
                                        // Store a new chunk on disk
                                        FabyRequest::StoreChunk { file_id, chunk_index, data, client_access_key, signature, ticket } => {
                                            let grid_public_key = state.config.lock().await.grid_public_key.clone();

                                            // Cryptographic verification of allocation tickets
                                            if client_access_key != "INTERNAL_SYSTEM_OP" {
                                                if let Err(err_msg) = verify_allocation_ticket(&ticket, &file_id, &grid_public_key) {
                                                    let _ = swarm.behaviour_mut().req_resp.send_response(channel, FabyResponse::Error(err_msg));
                                                    continue;
                                                }
                                            }

                                            let semaphore = transfer_semaphore.clone();
                                            let state_clone = Arc::clone(&state);
                                            let storage_clone = Arc::clone(&storage);
                                            let tx = resp_channel_tx.clone();

                                            let claim_file_id = file_id.clone();
                                            let claim_ak = client_access_key.clone();
                                            let claim_sig = signature.clone();
                                            let claim_ticket = ticket.clone();
                                            let claim_api_url = api_url.clone();
                                            let claim_peer_id = local_peer_id.to_string();

                                            tokio::spawn(async move {
                                                if let Ok(_permit) = semaphore.acquire_owned().await {
                                                    let mut st = state_clone.stats.lock().await;
                                                    let config = state_clone.config.lock().await;

                                                    let chunk_size = data.len();
                                                    let limit_bytes: u64 = config.disks.iter().map(|d| d.allocated_bytes).sum();
                                                    let node_token = config.node_token.clone();

                                                    if st.status == "Paused (Insufficient space)" {
                                                        let _ = tx.send((channel, FabyResponse::Error("Node is currently paused".to_string())));
                                                    } else if st.total_bytes_stored + (chunk_size as u64) > limit_bytes {
                                                        let _ = tx.send((channel, FabyResponse::Error("Storage limit reached".to_string())));
                                                    } else {
                                                        st.stored_chunks += 1;
                                                        st.total_bytes_stored += chunk_size as u64;
                                                        st.earnings_faby += 0.005;

                                                        drop(st);
                                                        drop(config);

                                                        let response = match storage_clone.store(&file_id, chunk_index, &data).await {
                                                            Ok(hash) => {
                                                                let payload = json!({
                                                                    "file_id": claim_file_id,
                                                                    "chunk_index": chunk_index,
                                                                    "size_bytes": chunk_size,
                                                                    "client_access_key": claim_ak,
                                                                    "signature": claim_sig,
                                                                    "hoster_peer_id": claim_peer_id,
                                                                    "ticket": claim_ticket,
                                                                    "node_token": node_token.clone()
                                                                });

                                                                tokio::spawn(async move {
                                                                    let client = reqwest::Client::new();
                                                                    let res = client.post(format!("{}/grid/claim-chunk", claim_api_url))
                                                                        .header("Authorization", format!("Bearer {}", node_token))
                                                                        .json(&payload)
                                                                        .send()
                                                                        .await;

                                                                    match res {
                                                                        Ok(resp) => {
                                                                            if !resp.status().is_success() {
                                                                                let status = resp.status();
                                                                                let err_text = resp.text().await.unwrap_or_default();
                                                                                println!("❌ API Error (claim-chunk) [{}]: {}", status, err_text);
                                                                            } else {
                                                                                println!("✅ Chunk successfully claimed on the backend!");
                                                                            }
                                                                        }
                                                                        Err(e) => println!("❌ Network error during claim-chunk: {}", e),
                                                                    }
                                                                });

                                                                FabyResponse::Stored { hash }
                                                            }
                                                            Err(e) => FabyResponse::Error(e),
                                                        };

                                                        let _ = tx.send((channel, response));
                                                    }
                                                }
                                            });
                                        }

                                        // Serve an existing chunk
                                        FabyRequest::GetChunk { file_id, chunk_index } => {
                                            if let Ok(permit) = transfer_semaphore.clone().try_acquire_owned() {
                                                {
                                                    let mut hits = state.chunk_hits.lock().await;
                                                    let count = hits.entry((file_id.clone(), chunk_index)).or_insert(0);
                                                    *count += 1;

                                                    let st = state.stats.lock().await;
                                                    let config = state.config.lock().await;

                                                    // Trigger CDN replication if piece is highly requested & CPU is stressed
                                                    if *count > 50 && st.current_cpu_usage > config.max_cpu_percent as f32 {
                                                        let _ = ws_tx.send(json!({"type": "request_cdn_replication", "file_id": file_id.clone(), "chunk_index": chunk_index}));
                                                        *count = 0;
                                                    }
                                                }

                                                let storage_clone = Arc::clone(&storage);
                                                let tx = resp_channel_tx.clone();

                                                tokio::spawn(async move {
                                                    let mut response_data = storage_clone.get(&file_id, chunk_index).await;
                                                    if response_data.is_err() {
                                                        response_data = storage_clone.get_cache(&file_id, chunk_index).await;
                                                    }
                                                    let response = match response_data {
                                                        Ok(data) => FabyResponse::ChunkData(data),
                                                        Err(e) => FabyResponse::Error(e),
                                                    };
                                                    let _ = tx.send((channel, response));
                                                    drop(permit);
                                                });
                                            } else {
                                                let _ = swarm.behaviour_mut().req_resp.send_response(channel, FabyResponse::Error("Node throttling active".to_string()));
                                            }
                                        }
                                    }
                                }

                                request_response::Message::Response { request_id, response } => {
                                    if let Some(pending) = pending_requests.remove(&request_id) {
                                        match (pending, response) {
                                            (PendingRequest::Fetch(tx), FabyResponse::ChunkData(data)) => { let _ = tx.send(Ok(data)); }
                                            (PendingRequest::Fetch(tx), FabyResponse::Error(e)) => { let _ = tx.send(Err(e)); }
                                            (PendingRequest::Store(tx), FabyResponse::Stored { .. }) => { let _ = tx.send(Ok(())); }
                                            (PendingRequest::Store(tx), FabyResponse::Error(e)) => { let _ = tx.send(Err(e)); }
                                            _ => {}
                                        }
                                    }
                                }
                            }
                        }

                        // Network Failure Handling
                        SwarmEvent::Behaviour(HosterBehaviourEvent::ReqResp(request_response::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some(pending) = pending_requests.remove(&request_id) {
                                let err_msg = format!("Outbound network request failed: {:?}", error);
                                match pending {
                                    PendingRequest::Fetch(tx) => { let _ = tx.send(Err(err_msg)); }
                                    PendingRequest::Store(tx) => { let _ = tx.send(Err(err_msg)); }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}
