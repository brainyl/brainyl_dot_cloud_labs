aws cloudformation create-stack \
  --stack-name s3-static-website \
  --template-body file://s3-bucket.yaml \
  --parameters ParameterKey=BucketName,ParameterValue=cloudfront-demo-$(date +%Y%m%d) \
  --region us-west-2

aws cloudformation wait stack-create-complete \
  --stack-name s3-static-website \
  --region us-west-2


aws cloudformation create-stack \
  --stack-name cloudfront-distribution \
  --template-body file://cloudfront-distribution.yaml \
  --parameters ParameterKey=S3StackName,ParameterValue=s3-static-website \
  --region us-west-2

aws cloudformation wait stack-create-complete \
  --stack-name cloudfront-distribution \
  --region us-west-2


aws cloudformation create-stack \
  --stack-name codepipeline-deployment \
  --template-body file://codepipeline-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=S3StackName,ParameterValue=s3-static-website \
    ParameterKey=CloudFrontStackName,ParameterValue=cloudfront-distribution \
    ParameterKey=GitHubOwner,ParameterValue=YOUR_GITHUB_USERNAME \
    ParameterKey=GitHubRepo,ParameterValue=ccp \
    ParameterKey=GitHubBranch,ParameterValue=main \
    ParameterKey=CodeStarConnectionArn,ParameterValue=$CONNECTION_ARN \
  --region us-west-2

aws cloudformation wait stack-create-complete \
  --stack-name codepipeline-deployment \
  --region us-west-2