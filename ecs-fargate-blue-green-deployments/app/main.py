from fastapi import FastAPI
from fastapi.responses import HTMLResponse
import os

app = FastAPI()
version = os.getenv("APP_VERSION", "blue-v1")

@app.get("/health")
def health():
    return {"ok": True, "version": version}

@app.get("/", response_class=HTMLResponse)
def home():
    color = "#1d4ed8" if "blue" in version.lower() else "#15803d"
    return f"""
    <html><body style='font-family: sans-serif; text-align: center; margin-top: 4rem;'>
      <h1 style='color:{color};'>ECS Blue/Green Demo</h1>
      <p>Current version: <strong>{version}</strong></p>
    </body></html>
    """