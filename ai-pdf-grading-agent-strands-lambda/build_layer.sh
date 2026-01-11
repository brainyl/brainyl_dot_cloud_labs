#!/bin/bash
set -e

echo "Building Lambda layer..."

# Clean up any existing layer directory
rm -rf lambda_layer
mkdir -p lambda_layer/python

# Install packages with platform-specific binaries for Lambda (Linux x86_64)
# Use --platform to ensure compatibility with Lambda runtime
# PyMuPDF provides better text extraction than pypdf
pip install --target lambda_layer/python --no-cache-dir --upgrade \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --python-version 3.12 \
    strands-agents \
    strands-agents-tools \
    PyMuPDF

# Remove boto3/botocore (Lambda runtime provides these)
rm -rf lambda_layer/python/boto3* lambda_layer/python/botocore* lambda_layer/python/s3transfer* 2>/dev/null || true

# Clean up unnecessary files
echo "Cleaning up unnecessary files..."
find lambda_layer/python -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true
find lambda_layer/python -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find lambda_layer/python -type f -name '*.pyc' -delete 2>/dev/null || true
find lambda_layer/python -type f -name '*.pyo' -delete 2>/dev/null || true

# Package the layer
echo "Packaging layer..."
cd lambda_layer
zip -r strands-pymupdf-layer.zip python -q
cd ..

echo "✅ Layer built successfully: lambda_layer/strands-pymupdf-layer.zip"
ls -lh lambda_layer/strands-pymupdf-layer.zip