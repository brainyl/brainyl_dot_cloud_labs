from fastapi import FastAPI
import os

app = FastAPI()

@app.get("/")
def read_root():
    return {
        "message": "Hello from Docker 101",
        "env": os.getenv("ENV_VAR", "not set"),
        "build_arg": os.getenv("BUILD_ARG", "not set")
    }

@app.get("/health")
def health_check():
    return {"status": "healthy"}
