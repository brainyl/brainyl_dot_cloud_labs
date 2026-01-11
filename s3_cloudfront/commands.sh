aws cloudformation create-stack \
  --stack-name s3-static-website \
  --template-body file://s3-bucket.yaml \
  --parameters ParameterKey=BucketName,ParameterValue=cloudfront-demo-$(date +%Y%m%d) \
  --region us-west-2

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name s3-static-website \
  --region us-west-2


BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name s3-static-website \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text \
  --region us-west-2)

echo "Bucket name: $BUCKET_NAME"


# Create a temporary directory
mkdir -p /tmp/cloudfront-demo
cd /tmp/cloudfront-demo

# Download files (adjust URL if needed)
curl -O https://raw.githubusercontent.com/buildwithbrainyl/ccp/main/builders-day/s3/demo_s3/index.html
curl -O https://raw.githubusercontent.com/buildwithbrainyl/ccp/main/builders-day/s3/demo_s3/error.html
curl -O https://raw.githubusercontent.com/buildwithbrainyl/ccp/main/builders-day/s3/demo_s3/sample-image.jpg

# Download v1/index.html for later cache invalidation testing (keep in local directory)
mkdir -p v1
curl -o v1/index.html https://raw.githubusercontent.com/buildwithbrainyl/ccp/main/builders-day/s3/demo_s3/v1/index.html

# Upload all files to S3 (excluding v1 directory for now)
aws s3 sync . s3://$BUCKET_NAME/ --exclude "v1/*" --region us-west-2

# Verify uploads
aws s3 ls s3://$BUCKET_NAME/ --region us-west-2

aws cloudformation create-stack \
  --stack-name cloudfront-distribution \
  --template-body file://cloudfront-distribution.yaml \
  --parameters ParameterKey=S3StackName,ParameterValue=s3-static-website \
  --region us-west-2

# Wait for deployment (CloudFront takes 10-15 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name cloudfront-distribution \
  --region us-west-2
