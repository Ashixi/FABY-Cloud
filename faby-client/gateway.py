import os
import uuid
import sqlite3
import hashlib
import shutil
import base64
import asyncio
import traceback
import time
from collections import defaultdict
from datetime import datetime, timedelta

import requests
import uvicorn
from fastapi import FastAPI, Request, Response, HTTPException, BackgroundTasks
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from mnemonic import Mnemonic

try:
    import faby_grid
except ImportError:
    raise RuntimeError("[Error] faby_grid module not found. Ensure 'maturin develop' was executed successfully.")

# ==========================================
# Configuration & Constants
# ==========================================
LOCAL_DB = os.getenv("FABY_DB_PATH", "data/faby_keys.db")
ENV_KEYS_PATH = os.getenv("FABY_KEYS_PATH", "data/keys.env")
TEMP_PARTS_DIR = "data/tmp_multipart"

CLOUD_API_URL = "https://api.boardly.studio" 
# CLOUD_API_URL = "http://localhost:8000"

FALLBACK_ACCESS = os.getenv("FABY_ACCESS_KEY", "faby_ak_XVgN6nBnj5sVsH770F1l4w")
FALLBACK_SECRET = os.getenv("FABY_SECRET_KEY", "faby_sk_4dB4CYNRLZMHlcJCLUUuUcFEikHtK88jibNLxMGzbFk")
FABY_GRID_SECRET = os.getenv("FABY_GRID_SECRET", "super_secret_network_key_2026")

app = FastAPI(title="FABY B2B S3-Compatible Gateway (P2P Enabled)")

# ==========================================
# Data Models
# ==========================================
class AddKeyRequest(BaseModel):
    access_key: str
    secret_key: str
    tier: str = "balanced"
    
class RecoverVaultRequest(BaseModel):
    seed_phrase: str
    access_key: str

class BackupVaultRequest(BaseModel):
    access_key: str

# ==========================================
# Rate Limiting & Database Setup
# ==========================================
class GatewayRateLimiter:
    """Simple in-memory rate limiter based on tier limits."""
    def __init__(self):
        self.requests = defaultdict(list)

    def is_allowed(self, access_key: str, tier: str) -> bool:
        now = time.time()
        limit = 1000 if tier == 'cdn' else 5
        
        # Keep only requests from the last 1.0 second
        self.requests[access_key] = [req_time for req_time in self.requests[access_key] if now - req_time < 1.0]
        
        if len(self.requests[access_key]) >= limit:
            return False
        
        self.requests[access_key].append(now)
        return True

rate_limiter = GatewayRateLimiter()

def init_db():
    """Initializes the SQLite database and creates necessary tables."""
    os.makedirs(os.path.dirname(LOCAL_DB), exist_ok=True)
    os.makedirs(TEMP_PARTS_DIR, exist_ok=True)
    
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    
    c.execute('''CREATE TABLE IF NOT EXISTS file_keys 
                 (file_id TEXT PRIMARY KEY, zk_key TEXT, original_name TEXT)''')
    
    # Handle schema migrations safely
    try:
        c.execute("ALTER TABLE file_keys ADD COLUMN s3_bucket TEXT")
        c.execute("ALTER TABLE file_keys ADD COLUMN s3_key TEXT")
        c.execute("ALTER TABLE file_keys ADD COLUMN size INTEGER DEFAULT 0")
        c.execute("ALTER TABLE file_keys ADD COLUMN last_modified TEXT DEFAULT CURRENT_TIMESTAMP")
    except sqlite3.OperationalError:
        pass 
        
    c.execute('''CREATE TABLE IF NOT EXISTS local_api_keys 
                 (access_key TEXT PRIMARY KEY, secret_key TEXT)''')

    try:
        c.execute("ALTER TABLE local_api_keys ADD COLUMN tier TEXT DEFAULT 'balanced'")
    except sqlite3.OperationalError:
        pass
                 
    c.execute('''CREATE TABLE IF NOT EXISTS settings 
                 (key TEXT PRIMARY KEY, value TEXT)''')

    c.execute('''CREATE TABLE IF NOT EXISTS chunk_locations 
                 (file_id TEXT, chunk_index INTEGER, multiaddr TEXT)''')
                 
    conn.commit()
    conn.close()

def sync_env_keys():
    """Synchronizes static API keys from the .env file to the database."""
    if not os.path.exists(ENV_KEYS_PATH):
        return

    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    with open(ENV_KEYS_PATH, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                ak, sk = line.split("=", 1)
                c.execute("INSERT OR REPLACE INTO local_api_keys (access_key, secret_key) VALUES (?, ?)", 
                          (ak.strip(), sk.strip()))
    conn.commit()
    conn.close()

# Initialize system state
init_db()
sync_env_keys()

# ==========================================
# Core Helper Functions
# ==========================================
def get_allocation_and_hosters(access_key: str, file_id: str, size_bytes: int, count: int = 3) -> dict:
    """Discovers hosters and retrieves an allocation ticket for file upload."""
    try:
        res = requests.get(
            f"{CLOUD_API_URL}/grid/discover-and-allocate?access_key={access_key}&file_id={file_id}&size_bytes={size_bytes}&count={count}", 
            timeout=5
        )
        if res.status_code == 200:
            data = res.json()
            print(f"[Signaling] Discovered {len(data['multiaddrs'])} nodes and received ticket.")
            return data
        elif res.status_code == 402:
            raise HTTPException(status_code=402, detail="Storage Limit Exceeded on Central API")
        else:
            print(f"[Signaling Error] Server responded with error: {res.text}")
            raise Exception("Failed to get allocation")
    except Exception as e:
        print(f"[Signaling Exception] {e}")
        raise HTTPException(status_code=503, detail="FABY Grid is offline or storage limits reached.")

def get_dynamic_headers(request: Request = None, forced_access_key: str = None) -> dict:
    """Parses S3-compatible authentication headers or presigned URL parameters."""
    client_access_key = forced_access_key
    
    if not client_access_key and request:
        # 1. Check standard S3 Authorization header
        auth_header = request.headers.get("Authorization", "")
        if "Credential=" in auth_header:
            try:
                client_access_key = auth_header.split("Credential=")[1].split("/")[0]
            except IndexError:
                pass

        # 2. Check query parameters for Presigned URLs
        if not client_access_key and "X-Amz-Credential" in request.query_params:
            try:
                credential_param = request.query_params.get("X-Amz-Credential")
                client_access_key = credential_param.split("/")[0]
                
                amz_date_str = request.query_params.get("X-Amz-Date")
                amz_expires_str = request.query_params.get("X-Amz-Expires")
                
                if amz_date_str and amz_expires_str:
                    amz_date = datetime.strptime(amz_date_str, "%Y%m%dT%H%M%SZ")
                    expires_seconds = int(amz_expires_str)
                    
                    if datetime.utcnow() > amz_date + timedelta(seconds=expires_seconds):
                        raise HTTPException(status_code=403, detail="Presigned URL has expired.")
            except ValueError:
                raise HTTPException(status_code=400, detail="Invalid date format in Presigned URL.")
            except Exception as e:
                raise HTTPException(status_code=403, detail=f"Invalid Presigned URL parameters: {e}")

    # Validate key against gateway database
    if client_access_key:
        conn = sqlite3.connect(LOCAL_DB)
        c = conn.cursor()
        
        row = c.execute("SELECT secret_key, tier FROM local_api_keys WHERE access_key=?", (client_access_key,)).fetchone()
        
        # Retry with synced keys if not found
        if not row:
            sync_env_keys()
            row = c.execute("SELECT secret_key, tier FROM local_api_keys WHERE access_key=?", (client_access_key,)).fetchone()
            
        conn.close()

        if row:
            secret_key, tier = row[0], row[1]
            if not rate_limiter.is_allowed(client_access_key, tier):
                raise HTTPException(status_code=429, detail=f"Rate limit exceeded for {tier} tier.")
                
            return {
                "X-Faby-Access-Key": client_access_key,
                "X-Faby-Secret-Key": secret_key,
                "Content-Type": "application/json"
            }
            
    # Fallback access
    if FALLBACK_ACCESS and FALLBACK_SECRET:
        return {
            "X-Faby-Access-Key": FALLBACK_ACCESS,
            "X-Faby-Secret-Key": FALLBACK_SECRET,
            "Content-Type": "application/json"
        }
        
    raise HTTPException(status_code=403, detail="Forbidden: Unrecognized Access Key.")

def send_audits_to_central_api(file_id: str, chunk_audits: dict, headers: dict):
    """Submits cryptographic audits to the Central API to enable hoster verification."""
    payload = {
        "file_id": file_id,
        "audits": {str(k): [{"salt": a[0], "expected_hash": a[1]} for a in v] for k, v in chunk_audits.items()}
    }
    try:
        res = requests.post(f"{CLOUD_API_URL}/grid/save-audits", headers=headers, json=payload, timeout=5)
        if res.status_code != 200:
            print(f"[Gateway Warning] Failed to save audits: {res.text}")
        else:
            print(f"[Gateway] Audits for {file_id} saved successfully.")
    except Exception as e:
        print(f"[Gateway Error] Failed to dispatch audits: {e}")

def get_gateway_master_key() -> str:
    """Retrieves the master encryption key from the database."""
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    row = c.execute("SELECT value FROM settings WHERE key='master_key'").fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=400, detail="Vault not initialized. Generate the 12-word seed phrase first.")
    return row[0]

def auto_backup_vault(access_key: str):
    """Automatically backs up the encrypted SQLite database to the P2P network."""
    try:
        conn = sqlite3.connect(LOCAL_DB)
        c = conn.cursor()
        row = c.execute("SELECT value FROM settings WHERE key='master_key'").fetchone()
        conn.close()
        
        if not row:
            return

        master_key = row[0]
        headers = get_dynamic_headers(forced_access_key=access_key)
        client_secret = headers["X-Faby-Secret-Key"]
        
        with open(LOCAL_DB, "rb") as f:
            db_bytes = f.read()
            
        encrypted_db = bytes(faby_grid.encrypt_data_with_key(db_bytes, master_key))
        backup_id = f"backup_{access_key[:8]}" 
        
        allocation_data = get_allocation_and_hosters(access_key, backup_id, len(encrypted_db))
        raw_hosters = allocation_data["multiaddrs"]
        ticket = allocation_data["allocation_ticket"]
        clean_hosters = [addr.split(",")[0].strip() for addr in raw_hosters]
        
        chunk_map, chunk_audits = faby_grid.upload_to_p2p(
            backup_id, encrypted_db, clean_hosters, access_key, client_secret, ticket
        )
        
        if isinstance(chunk_audits, dict):
            send_audits_to_central_api(backup_id, chunk_audits, headers)
        
        payload = {
            "backup_id": backup_id,
            "encrypted_size": len(encrypted_db),
            "chunk_map": chunk_map
        }
        
        res = requests.post(f"{CLOUD_API_URL}/storage/b2b/backup/save-map", headers=headers, json=payload)
        if res.status_code == 200:
            print("[Auto-Backup] Vault backed up successfully to P2P network.")
        else:
            print(f"[Auto-Backup Error] Cloud API error: {res.text}")
            
    except Exception as e:
        print(f"[Auto-Backup Error] Background task failed: {e}")

# ==========================================
# Admin & Vault Routes
# ==========================================
@app.post("/admin/keys")
async def add_local_key(data: AddKeyRequest):
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO local_api_keys (access_key, secret_key, tier) VALUES (?, ?, ?)", 
              (data.access_key, data.secret_key, data.tier))
    conn.commit()
    conn.close()
    return {"status": "success", "message": f"Key {data.access_key} ({data.tier} tier) registered successfully."}

@app.post("/admin/vault/init")
async def init_b2b_vault():
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    row = c.execute("SELECT value FROM settings WHERE key='master_key'").fetchone()
    if row:
        conn.close()
        raise HTTPException(status_code=400, detail="Vault already initialized.")

    mnemo = Mnemonic("english")
    words = mnemo.generate(strength=128)
    
    seed = mnemo.to_seed(words, passphrase="")
    master_key_bytes = hashlib.pbkdf2_hmac('sha256', seed, b"faby_b2b_salt", 100000)
    gateway_master_key_base64 = base64.b64encode(master_key_bytes[:32]).decode()
    
    c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", 
              ("master_key", gateway_master_key_base64))
    conn.commit()
    conn.close()

    return {
        "message": "WARNING! Save these 12 words securely. This is the only way to recover your files.",
        "seed_phrase": words
    }

@app.post("/admin/vault/backup")
async def backup_vault(request: BackupVaultRequest):
    master_key = get_gateway_master_key()
    headers = get_dynamic_headers(forced_access_key=request.access_key)
    
    try:
        with open(LOCAL_DB, "rb") as f:
            db_bytes = f.read()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database read error: {e}")

    try:
        encrypted_db = bytes(faby_grid.encrypt_data_with_key(db_bytes, master_key))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Encryption error: {e}")

    res = requests.post(f"{CLOUD_API_URL}/storage/b2b/backup/upload-url", headers=headers)
    if res.status_code != 200:
        raise HTTPException(status_code=res.status_code, detail="Failed to retrieve backup upload URL.")
    
    upload_url = res.json()["upload_url"]
    put_res = requests.put(upload_url, data=encrypted_db)
    if put_res.status_code != 200:
        raise HTTPException(status_code=500, detail="Cloud upload failed.")

    return {"status": "success", "message": "Database backup encrypted and uploaded to cloud storage."}

@app.post("/admin/vault/recover")
async def recover_vault(request: RecoverVaultRequest):
    mnemo = Mnemonic("english")
    if not mnemo.check(request.seed_phrase):
        raise HTTPException(status_code=400, detail="Invalid seed phrase.")
        
    seed = mnemo.to_seed(request.seed_phrase, passphrase="")
    master_key_bytes = hashlib.pbkdf2_hmac('sha256', seed, b"faby_b2b_salt", 100000)
    master_key = base64.b64encode(master_key_bytes[:32]).decode()

    headers = get_dynamic_headers(forced_access_key=request.access_key)

    res = requests.get(f"{CLOUD_API_URL}/storage/b2b/backup/get-map", headers=headers)
    if res.status_code != 200:
        raise HTTPException(status_code=res.status_code, detail="Backup map not found in cloud.")
        
    map_data = res.json()
    backup_id = map_data["backup_id"]
    encrypted_size = map_data["encrypted_size"]
    
    chunk_map = {int(k): v for k, v in map_data["chunk_map"].items()}
    
    try:
        print("[Vault Recovery] Downloading database backup from P2P nodes...")
        enc_db_bytes = await asyncio.to_thread(faby_grid.download_from_p2p, backup_id, chunk_map, encrypted_size)
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"P2P Download error: {str(e)}")
    
    try:
        dec_db_bytes = bytes(faby_grid.decrypt_data_with_key(enc_db_bytes, master_key))
    except Exception:
        raise HTTPException(status_code=403, detail="Valid seed phrase, but does not match this backup.")
        
    with open(LOCAL_DB, "wb") as f:
        f.write(dec_db_bytes)
        
    return {"status": "success", "message": "Gateway database restored completely from P2P network."}

# ==========================================
# S3-Compatible Routes
# ==========================================
@app.get("/")
async def s3_list_buckets(request: Request):
    get_dynamic_headers(request)
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    buckets = c.execute("SELECT DISTINCT s3_bucket FROM file_keys WHERE s3_bucket IS NOT NULL").fetchall()
    conn.close()
    
    buckets_xml = "".join(
        f"<Bucket><Name>{b[0]}</Name><CreationDate>2024-01-01T00:00:00.000Z</CreationDate></Bucket>" 
        for b in buckets
    )
        
    xml_response = f'''<?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Owner>
            <ID>faby-b2b-owner</ID>
            <DisplayName>FABY Gateway</DisplayName>
        </Owner>
        <Buckets>
            {buckets_xml}
        </Buckets>
    </ListAllMyBucketsResult>'''
    return Response(content=xml_response, media_type="application/xml")

@app.head("/{bucket}")
async def s3_head_bucket(bucket: str, request: Request):
    get_dynamic_headers(request)
    return Response(status_code=200)

@app.put("/{bucket}")
async def s3_create_bucket(bucket: str, request: Request):
    get_dynamic_headers(request)
    return Response(status_code=200, headers={"Location": f"/{bucket}"})

@app.delete("/{bucket}")
async def s3_delete_bucket(bucket: str, request: Request):
    get_dynamic_headers(request)
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    count = c.execute("SELECT COUNT(*) FROM file_keys WHERE s3_bucket=?", (bucket,)).fetchone()[0]
    conn.close()
    
    if count > 0:
        xml_error = f'''<?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>BucketNotEmpty</Code><Message>The bucket is not empty.</Message><BucketName>{bucket}</BucketName></Error>'''
        return Response(content=xml_error, status_code=409, media_type="application/xml")
        
    return Response(status_code=204)

@app.get("/{bucket}")
async def s3_list_objects(bucket: str, request: Request):
    get_dynamic_headers(request)
    prefix = request.query_params.get("prefix", "")
    
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    if prefix:
        objects = c.execute("SELECT s3_key, size, last_modified FROM file_keys WHERE s3_bucket=? AND s3_key LIKE ?", (bucket, f"{prefix}%")).fetchall()
    else:
        objects = c.execute("SELECT s3_key, size, last_modified FROM file_keys WHERE s3_bucket=?", (bucket,)).fetchall()
    conn.close()
    
    contents_xml = ""
    for key, size, last_mod in objects:
        last_mod_iso = last_mod.replace(" ", "T") + ".000Z" if len(last_mod) == 19 else "2024-01-01T00:00:00.000Z"
        contents_xml += f'''
        <Contents>
            <Key>{key}</Key>
            <LastModified>{last_mod_iso}</LastModified>
            <ETag>"{hashlib.md5(key.encode()).hexdigest()}"</ETag>
            <Size>{size}</Size>
            <StorageClass>STANDARD</StorageClass>
        </Contents>
        '''
        
    xml_response = f'''<?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>{bucket}</Name>
        <Prefix>{prefix}</Prefix>
        <KeyCount>{len(objects)}</KeyCount>
        <MaxKeys>1000</MaxKeys>
        <IsTruncated>false</IsTruncated>
        {contents_xml}
    </ListBucketResult>'''
    
    return Response(content=xml_response, media_type="application/xml")

@app.head("/{bucket}/{key:path}")
async def s3_head_object(bucket: str, key: str, request: Request):
    get_dynamic_headers(request)
    
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    row = c.execute("SELECT size, last_modified FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key)).fetchone()
    conn.close()
    
    if not row:
        return Response(status_code=404)
        
    size, last_mod = row
    last_mod_http = datetime.strptime(last_mod, "%Y-%m-%d %H:%M:%S").strftime("%a, %d %b %Y %H:%M:%S GMT") if len(last_mod) == 19 else ""
    
    headers = {
        "Content-Length": str(size),
        "Last-Modified": last_mod_http,
        "ETag": f'"{hashlib.md5(key.encode()).hexdigest()}"'
    }
    return Response(status_code=200, headers=headers)

@app.post("/{bucket}/{key:path}")
async def s3_multipart_post(bucket: str, key: str, request: Request, background_tasks: BackgroundTasks):
    if "uploads" in request.query_params:
        get_dynamic_headers(request)
        upload_id = str(uuid.uuid4()).replace("-", "")
        os.makedirs(os.path.join(TEMP_PARTS_DIR, upload_id), exist_ok=True)
        
        xml_response = f'''<?xml version="1.0" encoding="UTF-8"?>
        <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Bucket>{bucket}</Bucket>
            <Key>{key}</Key>
            <UploadId>{upload_id}</UploadId>
        </InitiateMultipartUploadResult>'''
        return Response(content=xml_response, media_type="application/xml")

    if "uploadId" in request.query_params:
        faby_headers = get_dynamic_headers(request)
        client_access_key = faby_headers["X-Faby-Access-Key"]
        client_secret_key = faby_headers["X-Faby-Secret-Key"]
        
        upload_id = request.query_params["uploadId"]
        upload_dir = os.path.join(TEMP_PARTS_DIR, upload_id)
        
        if not os.path.exists(upload_dir):
            return Response(status_code=404, content="Upload session not found")

        assembled_data = bytearray()
        part_files = sorted(os.listdir(upload_dir), key=lambda x: int(x))
        for part_file in part_files:
            with open(os.path.join(upload_dir, part_file), "rb") as f:
                assembled_data.extend(f.read())
                
        shutil.rmtree(upload_dir)

        file_id = str(uuid.uuid4())
        try:
            zk_key = faby_grid.generate_random_key()
            encrypted_bytes = bytes(faby_grid.encrypt_data_with_key(bytes(assembled_data), zk_key))
            
            allocation_data = get_allocation_and_hosters(client_access_key, file_id, len(assembled_data))
            raw_hosters = allocation_data["multiaddrs"]
            ticket = allocation_data["allocation_ticket"]
            
            clean_hosters = [addr.split(",")[0].strip() for addr in raw_hosters]
            print(f"[Gateway] Attempting connection to: {clean_hosters}")

            chunk_map, chunk_audits = await asyncio.to_thread(
                faby_grid.upload_to_p2p, 
                file_id, 
                encrypted_bytes, 
                clean_hosters, 
                client_access_key,
                client_secret_key,
                ticket
            )
            
            if isinstance(chunk_audits, dict):
                send_audits_to_central_api(file_id, chunk_audits, faby_headers)
            
            # P2P Network Analysis
            total_chunks = len(chunk_map)
            relay_count = sum(1 for _, (_, is_relay) in chunk_map.items() if is_relay)
            has_direct_p2p = relay_count < total_chunks 

            if not has_direct_p2p:
                print(f"[Warning] All {total_chunks} connections used Relay. Direct connections might be blocked by NAT/Firewall. Traffic is billed at Relay rates.")
            elif relay_count > 0:
                print(f"[Info] {relay_count}/{total_chunks} chunks uploaded via Relay. Direct connection is active; no additional relay fees apply.")
            
            print(f"[P2P] Multipart file {file_id} uploaded to {total_chunks} nodes successfully.")
            
        except Exception as e:
            traceback.print_exc()
            return Response(content=f"P2P Encryption/Upload failed: {str(e)}", status_code=500)

        conn = sqlite3.connect(LOCAL_DB)
        c = conn.cursor()
        c.execute("DELETE FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key))
        c.execute("DELETE FROM chunk_locations WHERE file_id=?", (file_id,))
        
        c.execute("INSERT INTO file_keys (file_id, zk_key, original_name, s3_bucket, s3_key, size) VALUES (?, ?, ?, ?, ?, ?)", 
                  (file_id, zk_key, key, bucket, key, len(assembled_data)))
                  
        for chunk_idx, (addr, _) in chunk_map.items():
            c.execute("INSERT INTO chunk_locations (file_id, chunk_index, multiaddr) VALUES (?, ?, ?)", 
                      (file_id, int(chunk_idx), addr))
                      
        conn.commit()
        conn.close()

        background_tasks.add_task(auto_backup_vault, client_access_key)

        etag = hashlib.md5(assembled_data).hexdigest()
        xml_response = f'''<?xml version="1.0" encoding="UTF-8"?>
        <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Location>http://localhost:9000/{bucket}/{key}</Location>
            <Bucket>{bucket}</Bucket>
            <Key>{key}</Key>
            <ETag>"{etag}"</ETag>
        </CompleteMultipartUploadResult>'''
        
        return Response(content=xml_response, media_type="application/xml")

@app.put("/{bucket}/{key:path}")
async def s3_put_object(bucket: str, key: str, request: Request, background_tasks: BackgroundTasks):
    faby_headers = get_dynamic_headers(request)
    client_access_key = faby_headers["X-Faby-Access-Key"]
    client_secret_key = faby_headers["X-Faby-Secret-Key"]
    
    file_id = str(uuid.uuid4())
    zk_key = faby_grid.generate_random_key()
    
    BLOCK_SIZE = 4 * 1024 * 1024  # 4 MB
    buffer = bytearray()
    block_index = 0
    total_size = 0
    
    # Request hosters once for the whole file, padding count.
    allocation_data = get_allocation_and_hosters(client_access_key, file_id, int(request.headers.get("Content-Length", 100000000)), count=10)
    clean_hosters = [addr.split(",")[0].strip() for addr in allocation_data["multiaddrs"]]
    ticket = allocation_data["allocation_ticket"]
    
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    
    try:
        # Stream chunks dynamically
        async for chunk in request.stream():
            buffer.extend(chunk)
            
            while len(buffer) >= BLOCK_SIZE:
                block_data = bytes(buffer[:BLOCK_SIZE])
                del buffer[:BLOCK_SIZE]
                total_size += len(block_data)
                
                encrypted_block = bytes(faby_grid.encrypt_data_with_key(block_data, zk_key))
                
                chunk_map, chunk_audits = await asyncio.to_thread(
                    faby_grid.upload_block_to_p2p, 
                    file_id, block_index, encrypted_block, clean_hosters, 
                    client_access_key, client_secret_key, ticket
                )
                
                for chunk_idx, (addr, _) in chunk_map.items():
                    c.execute("INSERT INTO chunk_locations (file_id, chunk_index, multiaddr) VALUES (?, ?, ?)", 
                              (file_id, int(chunk_idx), addr))
                
                if isinstance(chunk_audits, dict):
                    send_audits_to_central_api(file_id, chunk_audits, faby_headers)
                    
                block_index += 1

        # Handle remaining buffer (tail)
        if len(buffer) > 0:
            block_data = bytes(buffer)
            total_size += len(block_data)
            encrypted_block = bytes(faby_grid.encrypt_data_with_key(block_data, zk_key))
            
            chunk_map, chunk_audits = await asyncio.to_thread(
                faby_grid.upload_block_to_p2p, 
                file_id, block_index, encrypted_block, clean_hosters, 
                client_access_key, client_secret_key, ticket
            )
            
            for chunk_idx, (addr, _) in chunk_map.items():
                c.execute("INSERT INTO chunk_locations (file_id, chunk_index, multiaddr) VALUES (?, ?, ?)", 
                          (file_id, int(chunk_idx), addr))
                          
            if isinstance(chunk_audits, dict):
                send_audits_to_central_api(file_id, chunk_audits, faby_headers)

    except Exception as e:
        traceback.print_exc()
        return Response(content=f"P2P Stream Upload failed: {str(e)}", status_code=500)

    # Save metadata locally
    c.execute("DELETE FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key))
    c.execute("INSERT INTO file_keys (file_id, zk_key, original_name, s3_bucket, s3_key, size) VALUES (?, ?, ?, ?, ?, ?)", 
              (file_id, zk_key, key, bucket, key, total_size))
              
    conn.commit()
    conn.close()

    background_tasks.add_task(auto_backup_vault, client_access_key)
    return Response(status_code=200, headers={"ETag": f'"{file_id}"'})

@app.delete("/{bucket}/{key:path}")
async def s3_delete_object(bucket: str, key: str, request: Request, background_tasks: BackgroundTasks):
    faby_headers = get_dynamic_headers(request)
    client_access_key = faby_headers["X-Faby-Access-Key"]
    
    if "uploadId" in request.query_params:
        upload_id = request.query_params["uploadId"]
        upload_dir = os.path.join(TEMP_PARTS_DIR, upload_id)
        if os.path.exists(upload_dir):
            shutil.rmtree(upload_dir)
        return Response(status_code=204)
        
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    row = c.execute("SELECT file_id FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key)).fetchone()
    
    if not row:
        conn.close()
        return Response(status_code=204)
        
    file_id = row[0]
        
    c.execute("DELETE FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key))
    c.execute("DELETE FROM chunk_locations WHERE file_id=?", (file_id,))
    conn.commit()
    conn.close()
    
    background_tasks.add_task(auto_backup_vault, client_access_key)
    
    return Response(status_code=204)

@app.get("/{bucket}/{key:path}")
async def s3_get_object(bucket: str, key: str, request: Request):
    get_dynamic_headers(request)
    
    conn = sqlite3.connect(LOCAL_DB)
    c = conn.cursor()
    row = c.execute("SELECT file_id, zk_key, size FROM file_keys WHERE s3_bucket=? AND s3_key=?", (bucket, key)).fetchone()
    conn.close() 
    
    if not row: 
        return Response(content="NoSuchKey", status_code=404)
        
    file_id, zk_key, original_size = row
    
    try:
        res = requests.get(f"{CLOUD_API_URL}/grid/map/{file_id}", timeout=5)
        if res.status_code != 200:
            return Response(content="Map not found", status_code=404)
        map_data = res.json()
        full_chunk_map = {int(k): v for k, v in map_data.get("chunk_map", {}).items()}
    except Exception as e:
        return Response(content=str(e), status_code=502)

    # Erasure Coding Matrix Constants
    TOTAL_SHARDS = 45 # 30 data + 15 parity chunks per block
    BLOCK_SIZE = 4 * 1024 * 1024

    async def file_streamer():
        bytes_yielded = 0
        block_index = 0
        
        while bytes_yielded < original_size:
            remaining = original_size - bytes_yielded
            current_block_size = min(BLOCK_SIZE, remaining)
            
            # Encrypted block size accounts for AES GCM overhead (+28 bytes)
            encrypted_block_size = current_block_size + 28 
            
            # Filter chunk map exactly for the current block iteration
            start_idx = block_index * TOTAL_SHARDS
            end_idx = start_idx + TOTAL_SHARDS
            block_map = {k: v for k, v in full_chunk_map.items() if start_idx <= k < end_idx}
            
            try:
                enc_data = await asyncio.to_thread(
                    faby_grid.download_block_from_p2p, 
                    file_id, 
                    block_index, 
                    block_map, 
                    encrypted_block_size
                )
                dec_data = bytes(faby_grid.decrypt_data_with_key(enc_data, zk_key))
                yield dec_data
                
                bytes_yielded += current_block_size
                block_index += 1
            except Exception as e:
                print(f"[Stream Error] Failed to download block {block_index}: {e}")
                break

    return StreamingResponse(
        file_streamer(), 
        media_type="application/octet-stream", 
        headers={"Content-Length": str(original_size)}
    )

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=9000)