from typing import Optional, Tuple
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta

try:
    from bedrock_agentcore.tools.browser_client import BrowserClient, browser_session
    HAS_AGENTCORE = True
except ImportError:
    HAS_AGENTCORE = False
    browser_session = None
    print("⚠️  bedrock_agentcore not available - using mock mode")


@dataclass
class PresignInfo:
    """Presigned URL information"""
    presigned_url: Optional[str] = None
    ws_url: Optional[str] = None
    headers: Optional[dict] = None
    expires_at: Optional[str] = None


class AgentCoreClient:
    """Wrapper for AWS AgentCore BrowserClient"""
    
    def __init__(self, region: str = "us-west-2", mock: bool = False):
        self.region = region
        self.mock = mock
        self.browser_id: Optional[str] = None
        self.session_id: Optional[str] = None
        self._client: Optional[BrowserClient] = None
        
        if not HAS_AGENTCORE and not mock:
            raise RuntimeError(
                "bedrock-agentcore package not available. "
                "Install with: pip install bedrock-agentcore"
            )
    
    def create_session(self, ttl_seconds: int = 3600) -> Tuple[str, str]:
        """
        Create a new browser session in AgentCore
        
        Returns:
            (browser_id, agentcore_session_id)
        """
        if self.mock:
            # Mock implementation for testing
            self.browser_id = "aws.browser.v1"
            self.session_id = f"MOCK_{datetime.now().timestamp()}"
            return self.browser_id, self.session_id
        
        # Create real AgentCore session using context manager
        self._session_context = browser_session(self.region)
        self._client = self._session_context.__enter__()
        
        # Extract session information
        self.session_id = getattr(self._client, 'session_id', None)
        self.browser_id = getattr(self._client, 'identifier', None)
        
        if not self.session_id:
            raise RuntimeError("Failed to create browser session - no session ID returned")
        
        if not self.browser_id:
            # Fallback: use session_id as browser_id
            print("⚠️  No separate browser identifier found, using session_id as browser_id")
            self.browser_id = self.session_id
        
        print(f"✅ Created AgentCore session: {self.session_id}")
        print(f"   Browser ID: {self.browser_id}")
        
        return self.browser_id, self.session_id
    
    def presign_live_view(self, ttl_seconds: int = 300) -> PresignInfo:
        """
        Generate presigned URL for DCV live view
        
        Args:
            ttl_seconds: URL validity duration in seconds
        
        Returns:
            PresignInfo with presigned_url and expires_at
        """
        if not self._client:
            raise RuntimeError("No active session. Call create_session first.")
        
        if self.mock:
            expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
            return PresignInfo(
                presigned_url=f"https://mock-dcv.aws.com/sessions/{self.session_id}",
                expires_at=expires_at.isoformat()
            )
        
        # Get presigned URL from AgentCore
        # BrowserClient has a method to get DCV URL
        presigned_url = self._client.generate_live_view_url(expires=ttl_seconds)
        
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
        
        return PresignInfo(
            presigned_url=presigned_url,
            expires_at=expires_at.isoformat()
        )
    
    def presign_automation(self, ttl_seconds: int = 300) -> PresignInfo:
        """
        Generate presigned WebSocket URL and headers for CDP automation
        
        Args:
            ttl_seconds: Credentials validity duration
        
        Returns:
            PresignInfo with ws_url, headers, and expires_at
        """
        if not self._client:
            raise RuntimeError("No active session. Call create_session first.")
        
        if self.mock:
            expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
            return PresignInfo(
                ws_url=f"wss://mock-cdp.aws.com/sessions/{self.session_id}/cdp",
                headers={"Authorization": "Bearer mock_token"},
                expires_at=expires_at.isoformat()
            )
        
        # Get CDP WebSocket URL and auth headers
        ws_url, headers = self._client.generate_ws_headers()
        
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
        
        return PresignInfo(
            ws_url=ws_url,
            headers=headers,
            expires_at=expires_at.isoformat()
        )
    
    def close(self):
        """Close the browser session"""
        if self._client and not self.mock:
            try:
                self._client.close()
                print(f"✅ Closed AgentCore session: {self.session_id}")
            except Exception as e:
                print(f"⚠️  Error closing session: {e}")


def create_agentcore_client(region: str = "us-west-2", mock: bool = False) -> AgentCoreClient:
    """Factory function to create AgentCore client"""
    return AgentCoreClient(region=region, mock=mock)


def attach_agentcore_client(region: str, browser_id: str, session_id: str) -> AgentCoreClient:
    """
    Attach to an existing AgentCore session
    
    Note: AgentCore BrowserClient does not support attaching to existing sessions.
    This is a limitation of the current SDK. Sessions must be created and kept alive
    in memory for the duration of their use.
    """
    raise NotImplementedError(
        "AgentCore BrowserClient does not support attaching to existing sessions. "
        "Keep sessions alive in memory using a session manager."
    )