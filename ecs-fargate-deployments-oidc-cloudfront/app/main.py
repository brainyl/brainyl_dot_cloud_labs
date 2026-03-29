from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
import os

app = FastAPI()
version = os.getenv("APP_VERSION", "blue-v1")

@app.get("/health")
def health():
    return {"ok": True, "version": version}

@app.get("/static")
def cloudfront_static():
    """Fixed payload + cache headers: use a CloudFront behavior on this path with caching enabled."""
    return JSONResponse(
        content={
            "kind": "cache-friendly",
            "message": "Origin returns Cache-Control; map this path in CloudFront to a cached behavior.",
        },
        headers={"Cache-Control": "public, max-age=3600"},
    )

@app.get("/", response_class=HTMLResponse)
def home():
    color = "#1d4ed8" if "blue" in version.lower() else "#15803d"
    return f"""
    <html><body style='font-family: sans-serif; text-align: center; margin-top: 4rem;'>
      <h1 style='color:{color};'>ECS Blue/Green Demo</h1>
      <p>Current version: <strong>{version}</strong></p>
      <p><a href="/cloudfront-static">/cloudfront-static</a> — JSON with long cache TTL (CloudFront-friendly)</p>
    </body></html>
    """