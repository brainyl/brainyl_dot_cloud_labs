from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
import time
import asyncio

from config import get_settings
from agentcore_client import create_agentcore_client


app = FastAPI(
    title="Browser Session Service",
    description="Manage AWS AgentCore browser sessions with DCV viewing and CDP automation",
    version="1.0.0"
)

settings = get_settings()

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)

# In-memory session storage (replace with DynamoDB in production)
sessions = {}


class CreateSessionRequest(BaseModel):
    tenant_id: str = "demo_tenant"
    user_id: str = "demo_user"
    region: str = "us-west-2"
    ttl_seconds: int = 3600


class SessionResponse(BaseModel):
    session_id: str
    region: str
    status: str
    tenant_id: str
    owner_user_id: str
    created_at: str
    expires_at: str
    browser_id: Optional[str] = None
    agentcore_session_id: Optional[str] = None


class PresignLiveViewRequest(BaseModel):
    ttl_seconds: int = 300


class PresignLiveViewResponse(BaseModel):
    presigned_url: str
    expires_at: str


class PresignAutomationRequest(BaseModel):
    ttl_seconds: int = 300


class PresignAutomationResponse(BaseModel):
    ws_url: str
    headers: dict
    expires_at: str


class RunAutomationResponse(BaseModel):
    status: str
    message: str
    session_id: str


async def run_automation_task(session_id: str, ws_url: str, headers: dict):
    """Background task to run browser automation with engaging demo steps"""
    print(f"🤖 Starting automation for session: {session_id}")
    print("=" * 60)
    
    try:
        from playwright.async_api import async_playwright
        
        async with async_playwright() as p:
            # Connect to AWS browser via CDP
            browser = await p.chromium.connect_over_cdp(
                ws_url,
                headers=headers
            )
            
            # Get the first context and page
            contexts = browser.contexts
            if not contexts:
                print("❌ No browser contexts found")
                return
            
            context = contexts[0]
            pages = context.pages
            
            if not pages:
                print("❌ No pages found")
                return
            
            page = pages[0]
            
            print(f"✅ Connected to AWS browser via CDP")
            print(f"📄 Starting URL: {page.url}")
            print("")
            
            # Step 1: Visit Example.com
            print("🌐 Step 1/6: Visiting Example.com...")
            await page.goto("https://example.com", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(3)  # Give viewers time to see it
            print(f"   ✅ Loaded: {page.url}")
            print(f"   📝 Page title: {await page.title()}")
            print("")
            
            # Step 2: Navigate to Wikipedia
            print("🌐 Step 2/6: Navigating to Wikipedia...")
            await page.goto("https://en.wikipedia.org", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(2)
            print(f"   ✅ Loaded: {page.url}")
            print("")
            
            # Step 3: Search for "Artificial Intelligence"
            print("🔍 Step 3/6: Searching for 'Artificial Intelligence'...")
            try:
                # Find and fill the search box
                search_box = await page.wait_for_selector('input[name="search"]', timeout=5000)
                await search_box.fill("Artificial Intelligence")
                await asyncio.sleep(1)
                
                # Submit the search
                await search_box.press("Enter")
                await page.wait_for_load_state("domcontentloaded", timeout=30000)
                await asyncio.sleep(2)
                print(f"   ✅ Search completed")
                print(f"   📄 Viewing: {await page.title()}")
                print("")
            except Exception as e:
                print(f"   ⚠️ Search step skipped: {e}")
                print("")
            
            # Step 4: Scroll down to explore content
            print("📜 Step 4/6: Scrolling through the article...")
            try:
                # Scroll down in increments
                for i in range(3):
                    await page.evaluate("window.scrollBy(0, 500)")
                    await asyncio.sleep(1)
                print(f"   ✅ Scrolled through content")
                print("")
            except Exception as e:
                print(f"   ⚠️ Scroll step skipped: {e}")
                print("")
            
            # Step 5: Navigate to AWS website
            print("🌐 Step 5/6: Visiting AWS website...")
            await page.goto("https://aws.amazon.com", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(3)
            print(f"   ✅ Loaded: {page.url}")
            print(f"   📝 Page title: {await page.title()}")
            print("")
            
            # Step 6: Final destination - Google
            print("🌐 Step 6/6: Final stop - Google...")
            await page.goto("https://www.google.com", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(2)
            print(f"   ✅ Loaded: {page.url}")
            print("")
            
            print("=" * 60)
            print("✨ Automation sequence completed successfully!")
            print(f"🎬 Total steps executed: 6")
            print(f"🌐 Websites visited: Example.com, Wikipedia, AWS, Google")
            print("=" * 60)
            
    except Exception as e:
        print(f"❌ Automation failed: {e}")
        import traceback
        traceback.print_exc()


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "service": "browser-session"}


@app.post("/browser-session/v1/sessions", response_model=SessionResponse, status_code=201)
async def create_session(body: CreateSessionRequest):
    """Create a new browser session"""
    
    # Create AgentCore session
    client = create_agentcore_client(
        region=body.region,
        mock=settings.agentcore_mock
    )
    
    try:
        browser_id, agentcore_session_id = client.create_session(body.ttl_seconds)
        
        # Generate session ID
        session_id = f"S_{int(time.time())}_{agentcore_session_id[:8]}"
        
        # Store session in memory
        created_at = time.time()
        expires_at = created_at + body.ttl_seconds
        
        sessions[session_id] = {
            "client": client,
            "session_id": session_id,
            "region": body.region,
            "status": "ready",
            "tenant_id": body.tenant_id,
            "owner_user_id": body.user_id,
            "created_at": created_at,
            "expires_at": expires_at,
            "browser_id": browser_id,
            "agentcore_session_id": agentcore_session_id
        }
        
        print(f"✅ Created session {session_id}")
        
        return SessionResponse(
            session_id=session_id,
            region=body.region,
            status="ready",
            tenant_id=body.tenant_id,
            owner_user_id=body.user_id,
            created_at=str(created_at),
            expires_at=str(expires_at),
            browser_id=browser_id,
            agentcore_session_id=agentcore_session_id
        )
        
    except Exception as e:
        print(f"❌ Failed to create session: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to create session: {str(e)}")


@app.post("/browser-session/v1/sessions/{session_id}/live-view/presign", response_model=PresignLiveViewResponse)
async def presign_live_view(session_id: str, body: PresignLiveViewRequest):
    """Generate presigned URL for DCV live view"""
    
    if session_id not in sessions:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    
    session = sessions[session_id]
    client = session["client"]
    
    try:
        presign_info = client.presign_live_view(body.ttl_seconds)
        
        return PresignLiveViewResponse(
            presigned_url=presign_info.presigned_url,
            expires_at=presign_info.expires_at
        )
        
    except Exception as e:
        print(f"❌ Failed to presign live view: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to presign live view: {str(e)}")


@app.post("/browser-session/v1/sessions/{session_id}/automation/presign", response_model=PresignAutomationResponse)
async def presign_automation(session_id: str, body: PresignAutomationRequest):
    """Generate presigned WebSocket URL for CDP automation"""
    
    if session_id not in sessions:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    
    session = sessions[session_id]
    client = session["client"]
    
    try:
        presign_info = client.presign_automation(body.ttl_seconds)
        
        return PresignAutomationResponse(
            ws_url=presign_info.ws_url,
            headers=presign_info.headers,
            expires_at=presign_info.expires_at
        )
        
    except Exception as e:
        print(f"❌ Failed to presign automation: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to presign automation: {str(e)}")


@app.post("/browser-session/v1/sessions/{session_id}/automation/run", response_model=RunAutomationResponse)
async def run_automation(session_id: str, background_tasks: BackgroundTasks):
    """Start automation on the browser session"""
    
    if session_id not in sessions:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    
    session = sessions[session_id]
    client = session["client"]
    
    try:
        # Get CDP credentials
        presign_info = client.presign_automation(300)
        
        # Start automation in background
        background_tasks.add_task(
            run_automation_task,
            session_id,
            presign_info.ws_url,
            presign_info.headers
        )
        
        return RunAutomationResponse(
            status="started",
            message="Automation started successfully. Watch the live view to see it in action!",
            session_id=session_id
        )
        
    except Exception as e:
        print(f"❌ Failed to start automation: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to start automation: {str(e)}")


@app.delete("/browser-session/v1/sessions/{session_id}", status_code=204)
async def close_session(session_id: str):
    """Close browser session and cleanup resources"""
    
    if session_id not in sessions:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    
    session = sessions[session_id]
    client = session["client"]
    
    try:
        client.close()
        del sessions[session_id]
        print(f"✅ Closed session {session_id}")
        
    except Exception as e:
        print(f"⚠️  Error closing session: {e}")
        # Still remove from memory
        del sessions[session_id]


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=settings.port,
        reload=settings.environment == "development"
    )