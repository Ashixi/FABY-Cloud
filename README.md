# FABY Cloud: Hybrid Decentralized P2P Storage System

FABY Cloud is a professional-grade, hybrid decentralized storage solution that combines the ease of use of S3-compatible cloud interfaces with the security and resilience of a Peer-to-Peer (P2P) network. It features a high-performance **Rust core** and a versatile **Python-based gateway**.

---

## 🚀 System Overview

The project is built on a **"Zero-Knowledge"** architecture. Files are encrypted and fragmented locally before any data ever leaves the user's machine. The system is orchestrated by a central signaling server (**FABY Grid**) but relies on a global network of independent nodes for actual data persistence.

### Core Components

1.  **FABY Hoster (Rust):** A storage node daemon that manages physical disk allocation, handles P2P chunk transfers, and responds to cryptographic health audits.
2.  **FABY Client (Rust Core):** A library providing low-level cryptographic primitives, Reed-Solomon encoding/decoding, and libp2p networking logic.
3.  **FABY Gateway (Python/FastAPI):** An S3-compatible bridge that allows standard S3 tools (like AWS CLI, Rclone, or Cyberduck) to interact with the P2P network.

---

## 🛠 Technical Architecture

### 1. Data Redundancy (Reed-Solomon)
FABY ensures high availability through **Erasure Coding**. Every file or block is split into:

| Component | Quantity |
| :--- | :--- |
| **Data Shards** | 30 |
| **Parity Shards** | 15 |
| **Total Shards** | 45 per block |
| **Fault Tolerance** | ~33% (Requires any 30 of 45) |

### 2. Security & Zero-Knowledge Privacy
* **Client-Side Encryption:** Data is encrypted using **AES-256-GCM** with a unique key generated for each file.
* **Identity:** Nodes and clients use **Ed25519** keypairs for identity and secure noise-encrypted communication channels.
* **Integrity:** Every chunk is signed using **HMAC-SHA256** and verified via cryptographic tickets to prevent unauthorized storage or tampering.

### 3. Networking Stack (libp2p)
The P2P layer is built on the **libp2p** framework, supporting:
* **Transports:** TCP with Noise encryption and Yamux multiplexing.
* **NAT Traversal:** Integrated **UPnP** and **NAT-PMP** for automatic port forwarding.
* **Relay Support:** Automatic fallback to `libp2p-circuit-relay` for nodes behind restrictive firewalls.

---

## 📦 Project Structure

```text
├── faby-client/                # Client-side logic & Gateway
│   ├── lib.rs                  # Rust core (Maturin/PyO3 bindings)
│   ├── gateway.py              # S3-compatible FastAPI server
│   ├── requirements.txt        # Python dependencies
│   └── Cargo.toml              # Rust dependencies (aes-gcm, libp2p, etc.)
└── faby-hoster/                # Storage Node logic
    ├── main.rs                 # Node entry point & disk management
    └── Cargo.toml              # Release-optimized build profile





🔧 Installation & Setup
Prerequisites
Rust: 1.70+

Python: 3.9+

Maturin: Required to compile the Rust core (pip install maturin)

Setting up the Hoster Node
The Hoster node provides storage capacity to the network.

Build:

Bash
cd faby-hoster
cargo build --release
Configuration:
Run the interactive setup to allocate disk space (min 100GB recommended):

Bash
./target/release/faby-hoster setup
Run:

Bash
./target/release/faby-hoster start --p2p-port 4001
Setting up the S3 Gateway
The Gateway allows you to use the P2P network as a local S3 bucket.

Compile the Rust Core:

Bash
cd faby-client
maturin develop --release
Initialize the Vault:
The gateway uses a secure SQLite database to store file keys.

Bash
# Start the gateway
python gateway.py

# In another terminal, initialize the vault:
curl -X POST http://localhost:9000/admin/vault/init
[!WARNING]
Save the 12-word seed phrase. It is the ONLY way to recover your data if the local database is lost.

🔄 How It Works (Data Lifecycle)
PUT Request: An S3 client sends a file to the Gateway.

Processing: The Gateway encrypts data (AES-GCM) and encodes it into 45 shards (Reed-Solomon).

Allocation: The Gateway contacts FABY Grid to discover active hosters and receives a signed "Allocation Ticket".

Distribution: Shards are uploaded directly to hoster nodes via P2P. Only metadata (chunk maps) is stored on the Grid.

GET Request: The Gateway fetches the chunk map, connects to at least 30 hosters, reconstructs shards, and streams decrypted data back.

🛡 Security & Compliance
Master Key: Derived from your 12-word seed using PBKDF2.

Audit Mechanism: Hosters must provide a proof-of-possession hash combined with a server-side salt to prove they still hold the data.

Auto-Backup: The Gateway automatically backs up an encrypted version of its internal database to the P2P network whenever keys are updated.
