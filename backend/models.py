import uuid
from datetime import datetime
from sqlalchemy import JSON, Column, Integer, String, Boolean, DateTime, ForeignKey, BigInteger
from sqlalchemy.orm import relationship
from database import Base

# MARK: - USER MODELS
class UserInfo(Base):
    __tablename__ = "users"
    
    internal_id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    public_id = Column(String, nullable=False, unique=True, default=lambda: str(uuid.uuid4()))
    email = Column(String, nullable=False, unique=True)
    username = Column(String, nullable=False)
    hashed_password = Column(String, nullable=False)
    
    is_pro = Column(Boolean, default=False) 
    is_confirmed = Column(Boolean, default=False)
    has_vault = Column(Boolean, default=False) 
    
    storage_limit_mb = Column(Integer, default=500) 
    storage_used_bytes = Column(BigInteger, default=0)
    current_period_end = Column(DateTime, nullable=True) 
    
    stripe_customer_id = Column(String, nullable=True)
    stripe_subscription_id = Column(String, nullable=True)
    stripe_storage_sub_id = Column(String, nullable=True)
    
    boards = relationship("Board", back_populates="owner", cascade="all, delete-orphan")

# MARK: - BOARD MODELS
class Board(Base):
    __tablename__ = "boards"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id = Column(String, ForeignKey("users.internal_id"), nullable=False)
    name = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    owner = relationship("UserInfo", back_populates="boards")

class JoinedBoard(Base):
    __tablename__ = "joined_boards"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(String, ForeignKey("users.internal_id")) 
    board_id = Column(String, ForeignKey("boards.id"))
    joined_at = Column(DateTime, default=datetime.utcnow)

# MARK: - SHARING MODELS
class SharedLink(Base):
    __tablename__ = "shared_links"
    
    id = Column(String, primary_key=True, index=True)
    owner_public_id = Column(String, nullable=False)
    file_id = Column(String, nullable=False)

class SharedFolder(Base):
    __tablename__ = "shared_folders"
    
    id = Column(String, primary_key=True)
    owner_public_id = Column(String)
    folder_name = Column(String)
    manifest_id = Column(String)
    file_ids = Column(JSON)

class SharedBoard(Base):
    __tablename__ = "shared_boards"
    
    id = Column(String, primary_key=True, index=True)
    owner_public_id = Column(String, nullable=False)
    board_id = Column(String, nullable=False)
    board_name = Column(String, nullable=False)
    manifest_id = Column(String, nullable=False)
    file_ids = Column(JSON, nullable=False)