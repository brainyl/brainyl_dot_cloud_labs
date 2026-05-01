from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import create_engine, Column, Integer, String, text
from sqlalchemy.engine import URL as SQLAlchemyURL
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from pydantic import BaseModel
import os
import logging
import sys
import time

# Configure logging for ECS (stdout/stderr for CloudWatch)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# Database setup
# Option 1: Build DATABASE_URL from individual env vars (ECS injects from Secrets Manager)
DB_USERNAME = os.getenv("DB_USERNAME")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "3306")
DB_NAME = os.getenv("DB_NAME", "simpledb")

# Option 2: Use full DATABASE_URL if provided (for local dev)
if DB_USERNAME and DB_PASSWORD and DB_HOST:
    # Use URL.create() so special characters in the password are handled safely
    DATABASE_URL = SQLAlchemyURL.create(
        drivername="mysql+pymysql",
        username=DB_USERNAME,
        password=DB_PASSWORD,
        host=DB_HOST,
        port=int(DB_PORT),
        database=DB_NAME,
    )
    logger.info(f"Connecting to database: {DB_HOST}:{DB_PORT}/{DB_NAME}")
else:
    DATABASE_URL = os.getenv("DATABASE_URL", "mysql+pymysql://appuser:apppassword@localhost:3306/simpledb")
    logger.info(f"Connecting to database: {DATABASE_URL.split('@')[1] if '@' in DATABASE_URL else 'local'}")

# Initialize database components but don't connect yet
engine = None
SessionLocal = None
Base = declarative_base()

# Database model
class Item(Base):
    __tablename__ = "items"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    description = Column(String(255))

def init_database():
    """Initialize database connection and create tables with retries"""
    global engine, SessionLocal
    max_retries = 10
    retry_delay = 2
    
    for attempt in range(max_retries):
        try:
            logger.info(f"Attempting database connection (attempt {attempt + 1}/{max_retries})...")
            engine = create_engine(
                DATABASE_URL,
                pool_pre_ping=True,
                pool_recycle=300,
                connect_args={
                    "connect_timeout": 30,
                    "read_timeout": 30,
                    "write_timeout": 30
                }
            )
            SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
            
            # Test connection with timeout
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
                logger.info("Database connection successful")
            
            # Create tables
            Base.metadata.create_all(bind=engine)
            logger.info("Database tables created successfully")
            return True
            
        except Exception as e:
            logger.warning(f"Database connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                logger.info(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                logger.error(f"Failed to connect to database after {max_retries} attempts")
                return False
    
    return False

# Pydantic models
class ItemCreate(BaseModel):
    name: str
    description: str | None = None

class ItemResponse(BaseModel):
    id: int
    name: str
    description: str | None

    class Config:
        from_attributes = True

# FastAPI app
app = FastAPI(title="Simple API")

# Request logging middleware
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.time()
    logger.info(f"Request: {request.method} {request.url.path}")
    
    response = await call_next(request)
    
    process_time = time.time() - start_time
    logger.info(f"Response: {request.method} {request.url.path} - Status: {response.status_code} - Time: {process_time:.3f}s")
    
    return response

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Startup event
@app.on_event("startup")
async def startup_event():
    logger.info("Application starting up...")
    # Don't block startup on database connection
    # Database will be initialized on first request if needed
    logger.info("Application startup completed - database will be initialized on first request")

# Shutdown event
@app.on_event("shutdown")
async def shutdown_event():
    logger.info("Application shutting down...")

# Dependency
def get_db():
    global engine, SessionLocal
    if SessionLocal is None:
        logger.info("Database not initialized, attempting to initialize now...")
        if not init_database():
            raise HTTPException(status_code=503, detail="Database connection failed - service temporarily unavailable")
    
    db = SessionLocal()
    try:
        yield db
    except Exception as e:
        logger.error(f"Database session error: {e}")
        db.rollback()
        raise HTTPException(status_code=503, detail="Database connection error")
    finally:
        db.close()

# Routes
@app.get("/")
def read_root():
    return {"message": "Welcome to Simple API", "status": "healthy"}

@app.get("/health")
def health_check():
    return {"status": "healthy", "database": "connected" if engine else "not connected"}

@app.get("/init-db")
def initialize_database():
    """Initialize database and create tables"""
    try:
        if not init_database():
            raise HTTPException(status_code=503, detail="Failed to initialize database")
        return {"status": "success", "message": "Database initialized successfully"}
    except Exception as e:
        logger.error(f"Error initializing database: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to initialize database: {str(e)}")

@app.get("/items", response_model=list[ItemResponse])
def get_items(db: Session = Depends(get_db)):
    try:
        items = db.query(Item).all()
        logger.info(f"Retrieved {len(items)} items")
        return items
    except Exception as e:
        logger.error(f"Error retrieving items: {e}")
        raise HTTPException(status_code=500, detail="Failed to retrieve items")

@app.post("/items", response_model=ItemResponse)
def create_item(item: ItemCreate, db: Session = Depends(get_db)):
    try:
        db_item = Item(name=item.name, description=item.description)
        db.add(db_item)
        db.commit()
        db.refresh(db_item)
        logger.info(f"Created item: {db_item.id} - {db_item.name}")
        return db_item
    except Exception as e:
        logger.error(f"Error creating item: {e}")
        db.rollback()
        raise HTTPException(status_code=500, detail="Failed to create item")

@app.get("/items/{item_id}", response_model=ItemResponse)
def get_item(item_id: int, db: Session = Depends(get_db)):
    try:
        item = db.query(Item).filter(Item.id == item_id).first()
        if not item:
            logger.warning(f"Item not found: {item_id}")
            raise HTTPException(status_code=404, detail="Item not found")
        logger.info(f"Retrieved item: {item_id}")
        return item
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error retrieving item {item_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to retrieve item")

@app.delete("/items/{item_id}")
def delete_item(item_id: int, db: Session = Depends(get_db)):
    try:
        item = db.query(Item).filter(Item.id == item_id).first()
        if not item:
            logger.warning(f"Item not found for deletion: {item_id}")
            raise HTTPException(status_code=404, detail="Item not found")
        db.delete(item)
        db.commit()
        logger.info(f"Deleted item: {item_id}")
        return {"message": "Item deleted"}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error deleting item {item_id}: {e}")
        db.rollback()
        raise HTTPException(status_code=500, detail="Failed to delete item")

