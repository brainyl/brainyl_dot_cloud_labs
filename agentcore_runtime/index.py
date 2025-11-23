"""
Simple agent that can be used to test BedrockAgentCoreApp.
"""

import argparse
import json
import logging
import os

os.environ["OTEL_TRACES_EXPORTER"] = "console"

from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp

logger = logging.getLogger()
logger.setLevel(logging.INFO)

app = BedrockAgentCoreApp()

nova_pro = BedrockModel(
    model_id="us.amazon.nova-pro-v1:0",
)

if not logger.handlers:
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)


SYSTEM_PROMPT = """
You are a helpful assistant that answers infrastructure and DevOps questions clearly and concisely.
"""


@app.entrypoint
def invoke(payload):
    """Simple agent that can be used to test BedrockAgentCoreApp."""
    logger.info("Received payload: %s", json.dumps(payload, default=str))

    try:
        agent = Agent(
            system_prompt=SYSTEM_PROMPT,
            model=nova_pro,
        )
        user_message = payload.get("prompt", "Hello")
        response = agent(user_message)
        return str(response)
    except Exception as exc:
        logger.error("Failed to initialize or use agent: %s", exc)
        return str(exc)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run Bedrock AgentCore app")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("PORT", 8080)),
        help="Port to bind the server (default: 8080 or PORT env var)",
    )
    args = parser.parse_args()
    
    logger.info("Starting server on port %d", args.port)
    app.run(port=args.port)
