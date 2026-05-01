"""
Health check endpoint for ECS target group health checks
"""
import sys
import requests

def check_health():
    try:
        response = requests.get("http://localhost:8000/", timeout=5)
        if response.status_code == 200:
            sys.exit(0)
        else:
            sys.exit(1)
    except Exception:
        sys.exit(1)

if __name__ == "__main__":
    check_health()
