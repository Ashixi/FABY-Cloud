import uuid
import time
import boto3
from botocore.config import Config
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from cachetools import TTLCache

from database import get_db
from routes.auth_routes import get_current_user
from models import SharedBoard, SharedFolder, SharedLink, TrashItem, UserInfo, Board, JoinedBoard
from config import (
    R2_ACCESS_KEY_ID, 
    R2_SECRET_ACCESS_KEY, 
    R2_ENDPOINT_URL, 
    R2_BUCKET_NAME
)
from schemas import MultipartAbortRequest, MultipartCompleteRequest, MultipartInitRequest, MultipartUrlsRequest


# ==========================================
# MARK: - INITIALISATION AND CONFIGURATION
# ==========================================

router = APIRouter(prefix="/storage", tags=["Cloud Storage"])

s3_client = boto3.client(
    's3',
    endpoint_url=R2_ENDPOINT_URL,
    aws_access_key_id=R2_ACCESS_KEY_ID,
    aws_secret_access_key=R2_SECRET_ACCESS_KEY,
    config=Config(signature_version='s3v4'),
    region_name='auto'
)

nodes_cache = TTLCache(maxsize=1000, ttl=5)


# ==========================================
# MARK: - PYDANTIC SCHEMES
# ==========================================

class StorageRequest(BaseModel):
    file_id: str

class NodeRequest(BaseModel):
    node_id: str

class BoardStorageRequest(BaseModel):
    board_id: str
    file_id: str
    
class ShareCreateRequest(BaseModel):
    file_id: str
    
class FolderShareCreateRequest(BaseModel):
    manifest_id: str
    folder_name: str
    file_ids: list[str]
    
class BoardShareCreateRequest(BaseModel):
    manifest_id: str
    board_name: str
    board_id: str
    file_ids: list[str]
    
class RestoreRequest(BaseModel):
    item_type: str
    item_id: str
    
class StorageUsageUpdate(BaseModel):
    delta_bytes: int
    
class ConfirmUploadRequest(BaseModel):
    file_id: str
    
class LogicalTrashRequest(BaseModel):
    items: list[dict]

class BatchStorageRequest(BaseModel):
    file_ids: list[str]
    
class VfsSnapshotUrlRequest(BaseModel):
    action: str


# ==========================================
# MARK: - SUPPORTING BACKGROUND FUNCTIONS
# ==========================================

def background_s3_wipe(prefixes: list[str]):
    try:
        for prefix in prefixes:
            continuation_token = None
            while True:
                list_kwargs = {'Bucket': R2_BUCKET_NAME, 'Prefix': prefix}
                if continuation_token:
                    list_kwargs['ContinuationToken'] = continuation_token

                response = s3_client.list_objects_v2(**list_kwargs)
                
                if 'Contents' in response:
                    objects_to_delete = [{'Key': obj['Key']} for obj in response['Contents']]
                    if objects_to_delete:
                        s3_client.delete_objects(
                            Bucket=R2_BUCKET_NAME, 
                            Delete={'Objects': objects_to_delete}
                        )
                
                if not response.get('IsTruncated'):
                    break
                continuation_token = response.get('NextContinuationToken')
    except Exception as e:
        print(f"[BACKGROUND TASK ERROR] Wipe data failed: {e}")

def background_delete_v1_nodes(public_id: str):
    prefix = f"user_storage/{public_id}/nodes/"
    try:
        continuation_token = None
        while True:
            list_kwargs = {'Bucket': R2_BUCKET_NAME, 'Prefix': prefix}
            if continuation_token:
                list_kwargs['ContinuationToken'] = continuation_token

            response = s3_client.list_objects_v2(**list_kwargs)
            
            if 'Contents' in response:
                objects_to_delete = [{'Key': obj['Key']} for obj in response['Contents']]
                if objects_to_delete:
                    s3_client.delete_objects(Bucket=R2_BUCKET_NAME, Delete={'Objects': objects_to_delete})
            
            if not response.get('IsTruncated'):
                break
            continuation_token = response.get('NextContinuationToken')
    except Exception as e:
        print(f"Failed to delete old nodes for {public_id}: {e}")


# ==========================================
# MARK: - FILES & NODES
# ==========================================

@router.post("/file/upload-url")
async def generate_file_upload_url(request: StorageRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    try:
        url = s3_client.generate_presigned_url(
            'put_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=900
        )
        return {"upload_url": url, "file_id": request.file_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/file/download-url")
async def generate_file_download_url(request: StorageRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    try:
        url = s3_client.generate_presigned_url(
            'get_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=3600
        )
        return {"download_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/node/upload-url")
async def generate_node_upload_url(request: NodeRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/nodes/{request.node_id}.json"
    try:
        url = s3_client.generate_presigned_url(
            'put_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=900
        )
        return {"upload_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/node/download-url")
async def generate_node_download_url(request: NodeRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/nodes/{request.node_id}.json"
    try:
        url = s3_client.generate_presigned_url(
            'get_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=3600
        )
        return {"download_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/file/confirm-upload")
async def confirm_upload(
    request: ConfirmUploadRequest, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    marker_key = f"user_storage/{current_user.public_id}/markers/{request.file_id}.confirmed"
    
    try:
        meta = s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=object_key)
        actual_size = meta.get('ContentLength', 0)
        
        try:
            s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=marker_key)
            return {"status": "already_confirmed"}
        except Exception:
            pass 
            
        s3_client.put_object(Bucket=R2_BUCKET_NAME, Key=marker_key, Body=b"")
        current_user.storage_used_bytes = (current_user.storage_used_bytes or 0) + actual_size
        db.commit()
        
        return {"status": "confirmed", "added_bytes": actual_size}
    except Exception as e:
        print(f"Confirm Upload Error: {e}") 
        raise HTTPException(status_code=404, detail="File not found in storage yet")

@router.post("/file/batch-confirm-upload")
async def batch_confirm_upload(
    request: BatchStorageRequest, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    total_added_bytes = 0
    confirmed = []

    for file_id in request.file_ids:
        object_key = f"user_storage/{current_user.public_id}/files/{file_id}"
        marker_key = f"user_storage/{current_user.public_id}/markers/{file_id}.confirmed"
        
        try:
            try:
                s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=marker_key)
                continue
            except:
                pass 
                
            meta = s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=object_key)
            actual_size = meta.get('ContentLength', 0)
            
            s3_client.put_object(Bucket=R2_BUCKET_NAME, Key=marker_key, Body=b"")
            total_added_bytes += actual_size
            confirmed.append(file_id)
        except Exception as e:
            print(f"Skipping {file_id}: {e}")

    if total_added_bytes > 0:
        current_user.storage_used_bytes = (current_user.storage_used_bytes or 0) + total_added_bytes
        db.commit()

    return {"status": "batch_confirmed", "added_bytes": total_added_bytes, "confirmed_files": confirmed}


# ==========================================
# MARK: - MULTIPART 
# ==========================================

@router.post("/file/multipart/initiate")
async def initiate_multipart_upload(request: MultipartInitRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    try:
        response = s3_client.create_multipart_upload(Bucket=R2_BUCKET_NAME, Key=object_key)
        return {"upload_id": response["UploadId"], "file_id": request.file_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/file/multipart/presigned-urls")
async def generate_multipart_urls(request: MultipartUrlsRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    urls = []
    try:
        for i in range(1, request.parts_count + 1):
            url = s3_client.generate_presigned_url(
                ClientMethod='upload_part',
                Params={
                    'Bucket': R2_BUCKET_NAME,
                    'Key': object_key,
                    'UploadId': request.upload_id,
                    'PartNumber': i
                },
                ExpiresIn=3600 
            )
            urls.append({"part_number": i, "upload_url": url})
            
        return {"urls": urls}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/file/multipart/complete")
async def complete_multipart_upload(request: MultipartCompleteRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    try:
        parts = [{"ETag": p.ETag, "PartNumber": p.PartNumber} for p in request.parts]
        
        response = s3_client.complete_multipart_upload(
            Bucket=R2_BUCKET_NAME,
            Key=object_key,
            UploadId=request.upload_id,
            MultipartUpload={'Parts': parts}
        )
        return {"message": "Multipart upload completed successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.delete("/file/multipart/abort")
async def abort_multipart_upload(request: MultipartAbortRequest, current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/files/{request.file_id}"
    try:
        s3_client.abort_multipart_upload(Bucket=R2_BUCKET_NAME, Key=object_key, UploadId=request.upload_id)
        return {"message": "Multipart upload aborted"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# MARK: - TRASH
# ==========================================

@router.post("/trash/logical-delete")
async def logical_delete(request: LogicalTrashRequest, current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    freed_bytes = 0
    
    for item in request.items:
        new_trash = TrashItem(
            owner_public_id=current_user.public_id,
            item_id=item["id"],
            item_type=item["type"],
            size_bytes=item.get("size", 0)
        )
        db.add(new_trash)
        
        if item["type"] == "file":
            freed_bytes += item.get("size", 0)
            
    if freed_bytes > 0:
        current_user.storage_used_bytes = max(0, (current_user.storage_used_bytes or 0) - freed_bytes)
        
    db.commit()
    return {"message": "Moved to trash instantly and storage updated"}

@router.post("/trash/logical-restore")
async def logical_restore(request: LogicalTrashRequest, current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    item_ids = [item["id"] for item in request.items]
    db.query(TrashItem).filter(
        TrashItem.owner_public_id == current_user.public_id,
        TrashItem.item_id.in_(item_ids)
    ).delete(synchronize_session=False)
    db.commit()
    return {"message": "Restored instantly"}

@router.get("/system/recovery/list-trash")
async def list_trash(current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    trashed_items = {"files": [], "nodes": []}
    
    prefix = f"user_storage/{current_user.public_id}/trash/"
    try:
        continuation_token = None
        while True:
            list_kwargs = {'Bucket': R2_BUCKET_NAME, 'Prefix': prefix}
            if continuation_token:
                list_kwargs['ContinuationToken'] = continuation_token

            response = s3_client.list_objects_v2(**list_kwargs)
            for obj in response.get('Contents', []):
                key = obj['Key']
                parts = key.split('/')
                deleted_at_iso = obj['LastModified'].isoformat()
                
                if 'files' in parts:
                    trashed_items["files"].append({"id": parts[-1], "deleted_at": deleted_at_iso, "size": obj['Size']})
                elif 'nodes' in parts:
                    trashed_items["nodes"].append({"id": parts[-1].replace('.json', ''), "deleted_at": deleted_at_iso, "size": obj['Size']})
            
            if not response.get('IsTruncated'):
                break
            continuation_token = response.get('NextContinuationToken')
    except Exception as e:
        print(f"R2 list trash error: {e}")

    logical_items = db.query(TrashItem).filter(TrashItem.owner_public_id == current_user.public_id).all()
    for item in logical_items:
        target_list = trashed_items["files"] if item.item_type == "file" else trashed_items["nodes"]
        target_list.append({
            "id": item.item_id,
            "deleted_at": item.deleted_at.isoformat(),
            "size": item.size_bytes
        })
        
    return trashed_items

@router.post("/system/recovery/restore-trash")
async def restore_trash(request: RestoreRequest, current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    is_node = "node" in request.item_type.lower()
    item_type_str = "node" if is_node else "file"
    
    logical_items = db.query(TrashItem).filter(
            TrashItem.owner_public_id == current_user.public_id,
            TrashItem.item_id == request.item_id
        ).all()

    if logical_items:
            restored_bytes = 0
            for item in logical_items:
                if item.item_type == "file":
                    restored_bytes += item.size_bytes
                db.delete(item)
                
            if restored_bytes > 0:
                current_user.storage_used_bytes = (current_user.storage_used_bytes or 0) + restored_bytes
                
            db.commit()
            return {"message": "Restored instantly (Logical)."}

    if is_node:
        trash_key = f"user_storage/{current_user.public_id}/trash/nodes/{request.item_id}.json"
        original_key = f"user_storage/{current_user.public_id}/nodes/{request.item_id}.json"
    else:
        trash_key = f"user_storage/{current_user.public_id}/trash/files/{request.item_id}"
        original_key = f"user_storage/{current_user.public_id}/files/{request.item_id}"

    try:
        s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=trash_key)
    except Exception as e:
        if hasattr(e, 'response') and e.response.get('Error', {}).get('Code') == '404':
            try:
                s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=original_key)
                return {"message": "Already restored."}
            except Exception:
                raise HTTPException(status_code=404, detail="Item not found in trash.")
        raise e

    try:
        s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=original_key)
        raise HTTPException(status_code=409, detail=f"Active {item_type_str} with this ID already exists. Cannot overwrite.")
    except Exception as e:
        if hasattr(e, 'response') and e.response.get('Error', {}).get('Code') == '404':
            pass 
        elif isinstance(e, HTTPException):
            raise e 
        else:
            raise e
    
    copy_source = {'Bucket': R2_BUCKET_NAME, 'Key': trash_key}
    s3_client.copy(copy_source, R2_BUCKET_NAME, original_key)
    s3_client.delete_object(Bucket=R2_BUCKET_NAME, Key=trash_key)
    
    if not is_node:
        meta = s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=original_key)
        file_size = meta.get('ContentLength', 0)
        current_user.storage_used_bytes = (current_user.storage_used_bytes or 0) + file_size
        
        marker_key = f"user_storage/{current_user.public_id}/markers/{request.item_id}.confirmed"
        s3_client.put_object(Bucket=R2_BUCKET_NAME, Key=marker_key, Body=b"")
        db.commit()

    return {"message": f"{item_type_str.capitalize()} restored successfully from S3."}


# ==========================================
# MARK: - SHARE
# ==========================================

@router.post("/share/create")
async def create_share_link(
    request: ShareCreateRequest, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    share_id = uuid.uuid4().hex[:16] 
    new_share = SharedLink(
        id=share_id,
        owner_public_id=current_user.public_id,
        file_id=request.file_id,
    )
    db.add(new_share)
    db.commit()
    return {"share_id": share_id}

@router.delete("/share/{share_id}")
async def revoke_share_link(share_id: str, current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    shared_link = db.query(SharedLink).filter(SharedLink.id == share_id, SharedLink.owner_public_id == current_user.public_id).first()
    if shared_link:
        db.delete(shared_link)
        db.commit()
        return {"message": "Access revoked (File)"}

    shared_folder = db.query(SharedFolder).filter(SharedFolder.id == share_id, SharedFolder.owner_public_id == current_user.public_id).first()
    if shared_folder:
        db.delete(shared_folder)
        db.commit()
        return {"message": "Access revoked (Folder)"}

    shared_board = db.query(SharedBoard).filter(SharedBoard.id == share_id, SharedBoard.owner_public_id == current_user.public_id).first()
    if shared_board:
        db.delete(shared_board)
        db.commit()
        return {"message": "Access revoked (Board)"}

    return {"message": "Link already deleted or not found"}

@router.get("/share/download/{share_id}")
async def get_shared_file(share_id: str, db: Session = Depends(get_db)):
    shared_link = db.query(SharedLink).filter(SharedLink.id == share_id).first()
    
    if not shared_link:
        raise HTTPException(status_code=404, detail="Посилання недійсне")
        
    object_key = f"user_storage/{shared_link.owner_public_id}/files/{shared_link.file_id}"
    
    try:
        meta = s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=object_key)
        file_size = meta.get('ContentLength', 0)

        url = s3_client.generate_presigned_url(
            ClientMethod='get_object', 
            Params={
                'Bucket': R2_BUCKET_NAME, 
                'Key': object_key
            }, 
            ExpiresIn=3600
        )
        return {
            "download_url": url,
            "size": file_size
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/share/folder/create")
async def create_folder_share_link(
    request: FolderShareCreateRequest, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    share_id = uuid.uuid4().hex[:16] 
    new_folder_share = SharedFolder(
        id=share_id,
        owner_public_id=current_user.public_id,
        manifest_id=request.manifest_id,
        folder_name=request.folder_name,
        file_ids=request.file_ids
    )
    db.add(new_folder_share)
    db.commit()
    return {"share_id": share_id}

@router.get("/share/folder/{share_id}/manifest")
async def get_shared_folder_manifest(share_id: str, db: Session = Depends(get_db)):
    shared_folder = db.query(SharedFolder).filter(SharedFolder.id == share_id).first()
    if not shared_folder:
        raise HTTPException(status_code=404, detail="Посилання недійсне")
        
    object_key = f"user_storage/{shared_folder.owner_public_id}/files/{shared_folder.manifest_id}"
    
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='get_object', 
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, 
            ExpiresIn=3600
        )
        return {"download_url": url, "folder_name": shared_folder.folder_name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/share/folder/{share_id}/file/{file_id}")
async def get_shared_folder_file(share_id: str, file_id: str, db: Session = Depends(get_db)):
    shared_folder = db.query(SharedFolder).filter(SharedFolder.id == share_id).first()
    if not shared_folder or file_id not in shared_folder.file_ids:
        raise HTTPException(status_code=403, detail="Доступ заборонено або файл не знайдено в папці")
        
    object_key = f"user_storage/{shared_folder.owner_public_id}/files/{file_id}"
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='get_object', 
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, 
            ExpiresIn=3600
        )
        return {"download_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))    

@router.post("/share/board/create")
async def create_board_share_link(
    request: BoardShareCreateRequest, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    share_id = uuid.uuid4().hex[:16] 
    new_board_share = SharedBoard(  
        id=share_id,
        owner_public_id=current_user.public_id,
        manifest_id=request.manifest_id,
        board_name=request.board_name,
        board_id=request.board_id,
        file_ids=request.file_ids
    )
    db.add(new_board_share)
    db.commit()
    return {"share_id": share_id}

@router.get("/share/board/{share_id}/manifest")
async def get_shared_board_manifest(share_id: str, db: Session = Depends(get_db)):
    shared_board = db.query(SharedBoard).filter(SharedBoard.id == share_id).first()
    if not shared_board:
        raise HTTPException(status_code=404, detail="Посилання недійсне")
        
    object_key = f"board_storage/{shared_board.board_id}/{shared_board.manifest_id}"
    
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='get_object', 
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, 
            ExpiresIn=3600
        )
        return {"download_url": url, "board_name": shared_board.board_name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/share/board/{share_id}/file/{file_id}")
async def get_shared_board_file(share_id: str, file_id: str, db: Session = Depends(get_db)):
    shared_board = db.query(SharedBoard).filter(SharedBoard.id == share_id).first()
    if not shared_board or file_id not in shared_board.file_ids:
        raise HTTPException(status_code=403, detail="Доступ заборонено")
        
    object_key = f"board_storage/{shared_board.board_id}/{file_id}"
    
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='get_object', 
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, 
            ExpiresIn=3600
        )
        return {"download_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# MARK: - BOARDS
# ==========================================

@router.post("/board-upload-url")
async def generate_board_upload_url(
    request: BoardStorageRequest,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    board = db.query(Board).filter(Board.id == request.board_id).first()
    
    if board:
        is_owner = board.owner_id == current_user.internal_id
        is_joined = db.query(JoinedBoard).filter(
            JoinedBoard.board_id == request.board_id,
            JoinedBoard.user_id == current_user.internal_id
        ).first()

        if not (is_owner or is_joined):
            raise HTTPException(status_code=403, detail="Access denied to this board")

    object_key = f"board_storage/{request.board_id}/{request.file_id}"
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='put_object',
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key},
            ExpiresIn=900
        )
        return {"upload_url": url, "file_id": request.file_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/board-download-url")
async def generate_board_download_url(
    request: BoardStorageRequest,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    board = db.query(Board).filter(Board.id == request.board_id).first()
    
    if board:
        is_owner = board.owner_id == current_user.internal_id
        is_joined = db.query(JoinedBoard).filter(
            JoinedBoard.board_id == request.board_id,
            JoinedBoard.user_id == current_user.internal_id
        ).first()

        if not (is_owner or is_joined):
            raise HTTPException(status_code=403, detail="Access denied to this board")

    object_key = f"board_storage/{request.board_id}/{request.file_id}"
    try:
        url = s3_client.generate_presigned_url(
            ClientMethod='get_object',
            Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key},
            ExpiresIn=3600
        )
        return {"download_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.patch("/usage/update")
async def update_storage_usage(
    data: StorageUsageUpdate,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    current_bytes = getattr(current_user, 'storage_used_bytes', 0) or 0
    new_bytes = max(0, current_bytes + data.delta_bytes)
    
    current_user.storage_used_bytes = new_bytes
    db.commit()
    
    return {
        "message": "Storage usage updated",
        "storage_used_bytes": new_bytes,
        "storage_used_mb": round(new_bytes / (1024 * 1024), 2)
    }


# ==========================================
# MARK: - VFS AND RECOVERY
# ==========================================

@router.get("/nodes/list")
async def list_vfs_nodes(current_user: UserInfo = Depends(get_current_user), db: Session = Depends(get_db)):
    vfs_version = getattr(current_user, 'vfs_version', 1)
    if vfs_version >= 2:
        return {"nodes": [], "is_v2": True}
    
    if current_user.public_id in nodes_cache:
        return {"nodes": nodes_cache[current_user.public_id], "cached": True}

    prefix = f"user_storage/{current_user.public_id}/nodes/"
    nodes = []
    
    trashed_nodes = db.query(TrashItem.item_id).filter(
        TrashItem.owner_public_id == current_user.public_id,
        TrashItem.item_type == "node"
    ).all()
    trashed_ids = {t[0] for t in trashed_nodes}
    
    try:
        continuation_token = None
        while True:
            list_kwargs = {'Bucket': R2_BUCKET_NAME, 'Prefix': prefix}
            if continuation_token:
                list_kwargs['ContinuationToken'] = continuation_token

            response = s3_client.list_objects_v2(**list_kwargs)
            
            for obj in response.get('Contents', []):
                node_id = obj['Key'].split('/')[-1].replace('.json', '')
                
                if node_id in trashed_ids:
                    continue
                    
                nodes.append({
                    "node_id": node_id,
                    "last_modified": obj['LastModified'].isoformat(),
                    "etag": obj['ETag'].replace('"', '')
                })
            
            if not response.get('IsTruncated'):
                break
            continuation_token = response.get('NextContinuationToken')

        nodes_cache[current_user.public_id] = nodes
        return {"nodes": nodes, "cached": False}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/vfs/snapshot-url")
async def generate_vfs_snapshot_url(
    request: VfsSnapshotUrlRequest, 
    current_user: UserInfo = Depends(get_current_user)
):
    object_key = f"user_storage/{current_user.public_id}/system/vfs_snapshot.enc"
    try:
        if request.action == 'upload':
            url = s3_client.generate_presigned_url(
                'put_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=900
            )
        else:
            url = s3_client.generate_presigned_url(
                'get_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=3600
            )
        return {"url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/vfs/upgrade")
async def upgrade_vfs_version(
    background_tasks: BackgroundTasks,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    if getattr(current_user, 'vfs_version', 1) < 2:
        current_user.vfs_version = 2
        db.commit()
        background_tasks.add_task(background_delete_v1_nodes, current_user.public_id)
    
    return {"message": "Upgraded to VFS v2", "vfs_version": 2}

@router.post("/system/recovery/upload-url")
async def generate_recovery_upload_url(current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/system/recovery.enc"
    try:
        url = s3_client.generate_presigned_url(
            'put_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=900
        )
        return {"upload_url": url}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/system/recovery/download-url")
async def generate_recovery_download_url(current_user: UserInfo = Depends(get_current_user)):
    object_key = f"user_storage/{current_user.public_id}/system/recovery.enc"
    try:
        try:
            s3_client.head_object(Bucket=R2_BUCKET_NAME, Key=object_key)
        except Exception:
            raise HTTPException(status_code=404, detail="Recovery file not found. Have you created a vault yet?")

        url = s3_client.generate_presigned_url(
            'get_object', Params={'Bucket': R2_BUCKET_NAME, 'Key': object_key}, ExpiresIn=3600
        )
        return {"download_url": url}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.delete("/system/recovery/wipe")
async def wipe_all_user_data(
    background_tasks: BackgroundTasks, 
    current_user: UserInfo = Depends(get_current_user), 
    db: Session = Depends(get_db)
):
    prefixes_to_delete = [
        f"user_storage/{current_user.public_id}/",
        f"trash/{current_user.public_id}/"
    ]
    
    current_user.storage_used_bytes = 0
    
    db.query(TrashItem).filter(TrashItem.owner_public_id == current_user.public_id).delete()
    db.commit()
    
    background_tasks.add_task(background_s3_wipe, prefixes_to_delete)
    
    return {"message": "Wipe initiated in background. Database cleared."}