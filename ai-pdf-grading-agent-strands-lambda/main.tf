terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# S3 bucket for PDFs
resource "aws_s3_bucket" "grading_bucket" {
  bucket = "pdf-grading-agent-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "PDF Grading Agent Bucket"
    Environment = "demo"
  }
  
  # Allow bucket to be destroyed even if it contains objects
  force_destroy = true
}

# Upload sample PDFs (v1 naming convention)
# - question_and_answers.pdf = Answer key (questions + correct answers)
# - answers.pdf = Student submission (their answers only)
resource "aws_s3_object" "answer_key" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "question_and_answers.pdf"
  source = "${path.module}/question_and_answers.pdf"
  etag   = filemd5("${path.module}/question_and_answers.pdf")
}

resource "aws_s3_object" "student_submission" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "answers.pdf"
  source = "${path.module}/answers.pdf"
  etag   = filemd5("${path.module}/answers.pdf")
}

# Upload Lambda layer to S3
resource "aws_s3_object" "lambda_layer" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "layers/strands-pymupdf-layer.zip"
  source = "${path.module}/lambda_layer/strands-pymupdf-layer.zip"
  etag   = filemd5("${path.module}/lambda_layer/strands-pymupdf-layer.zip")
}

# Lambda layer
resource "aws_lambda_layer_version" "strands_pymupdf" {
  layer_name          = "strands-pymupdf-py312"
  s3_bucket           = aws_s3_bucket.grading_bucket.id
  s3_key              = aws_s3_object.lambda_layer.key
  compatible_runtimes = ["python3.12"]
  
  description = "Strands SDK, Strands Tools, and PyMuPDF for PDF grading"
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name_prefix = "pdf-grading-agent-lambda-"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name_prefix = "pdf-grading-agent-policy-"
  role        = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.function_name}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.grading_bucket.arn,
          "${aws_s3_bucket.grading_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/us.amazon.nova-pro-v1:0",
          "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      }
    ]
  })
}

# Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "grading_agent" {
  function_name = var.function_name
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 512
  
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  layers = [aws_lambda_layer_version.strands_pymupdf.arn]
  
  environment {
    variables = {
      DEFAULT_REGION       = var.aws_region
      BYPASS_TOOL_CONSENT  = "true"
    }
  }
  
  tags = {
    Name        = "PDF Grading Agent"
    Environment = "demo"
  }
}

# Data sources
data "aws_caller_identity" "current" {}

# Outputs
output "bucket_name" {
  description = "S3 bucket name for PDFs"
  value       = aws_s3_bucket.grading_bucket.id
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.grading_agent.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.grading_agent.arn
}

output "test_command" {
  description = "AWS CLI command to test the function (v1 naming)"
  value       = <<-EOT
    aws lambda invoke \
      --function-name ${aws_lambda_function.grading_agent.function_name} \
      --payload '{"student_bucket":"${aws_s3_bucket.grading_bucket.id}","student_key":"answers.pdf","answer_key_bucket":"${aws_s3_bucket.grading_bucket.id}","answer_key_key":"question_and_answers.pdf"}' \
      --region ${var.aws_region} \
      response.json && cat response.json
  EOT
}