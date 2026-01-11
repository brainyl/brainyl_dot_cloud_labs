from fastapi import FastAPI
import os
import boto3
from botocore.config import Config
import json

app = FastAPI()
s3 = boto3.client('s3', region_name='us-west-2', config=Config(connect_timeout=5, read_timeout=5))

@app.get("/")
def read_root():
    try:
        response = s3.get_object(Bucket='brainyl-blackbox-bucket', Key='data.json')
        content = response['Body'].read().decode('utf-8')
        return json.loads(content)
    except Exception as e:
        return {"error": str(e)}

@app.get("/health")
def health_check():
    return {"status": "healthy"}
