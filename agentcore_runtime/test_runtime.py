import boto3
import json
import os
import uuid

# Initialize the AgentCore Runtime client
agent_core_client = boto3.client('bedrock-agentcore')

# Get the runtime ARN from environment variable (set from Terraform output)
agent_arn = os.environ.get('RUNTIME_ARN')
session_id = str(uuid.uuid4())

# Prepare the payload - use errors='replace' to handle invalid UTF-8 bytes
prompt = "Give me a quick Terraform tip"
payload = json.dumps({"prompt": prompt}).encode('utf-8', errors='replace')

# Invoke the agent
response = agent_core_client.invoke_agent_runtime(
    agentRuntimeArn=agent_arn,
    runtimeSessionId=session_id,
    payload=payload
)

# Read and display the response
# The response field contains a StreamingBody that needs to be read
response_body = response['response'].read().decode('utf-8')
print("Response body:", response_body)
result = json.loads(response_body)
print(json.dumps(result, indent=2))
