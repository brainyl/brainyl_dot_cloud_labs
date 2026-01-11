from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    """Application settings"""
    
    # Server config
    port: int = 8100
    environment: str = "development"
    version: str = "1.0.0"
    
    # AWS config
    aws_region: str = "us-west-2"
    dynamodb_table: str = "browser_sessions"
    
    # Session config
    max_sessions_per_user: int = 5
    default_session_ttl: int = 3600  # 1 hour
    
    # AgentCore config
    agentcore_region: str = "us-west-2"
    agentcore_mock: bool = False  # Set to True for testing without AWS
    
    # CORS
    allowed_origins: list[str] = ["http://localhost:3000", "http://localhost:8100"]
    
    class Config:
        env_prefix = "BROWSER_SESSION_"
        case_sensitive = False


@lru_cache()
def get_settings() -> Settings:
    """Get cached settings instance"""
    return Settings()