from fastapi import FastAPI, Request
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Webhook Receiver")


@app.get("/")
async def root():
    return {"message": "Webhook receiver is running"}


@app.post("/webhook")
async def handle_webhook(request: Request):
    """
    Receives webhook POST requests and logs headers and body
    """
    # Get all headers
    headers = dict(request.headers)
    
    # Get the body
    body = await request.body()
    
    # Try to parse as JSON, fallback to raw text
    try:
        json_body = await request.json()
        logger.info("=" * 50)
        logger.info("WEBHOOK RECEIVED")
        logger.info("=" * 50)
        logger.info(f"Received Headers: {headers}")
        logger.info(f"Body (JSON): {json_body}")
        logger.info("=" * 50)
        
        return {
            "status": "success",
            "message": "Webhook received",
            "headers": headers,
            "body": json_body
        }
    except:
        logger.info("=" * 50)
        logger.info("WEBHOOK RECEIVED")
        logger.info("=" * 50)
        logger.info(f"Received Headers: {headers}")
        logger.info(f"Body (raw): {body.decode('utf-8', errors='ignore')}")
        logger.info("=" * 50)
        
        return {
            "status": "success",
            "message": "Webhook received",
            "headers": headers,
            "body": body.decode('utf-8', errors='ignore')
        }


@app.get("/health")
async def health_check():
    return {"status": "healthy"}