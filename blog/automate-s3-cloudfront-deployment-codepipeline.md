
In [Host Your Static S3 Website with CloudFront Using CloudFormation](./host-static-s3-website-cloudfront-cloudformation.md), you deployed S3 and CloudFront with CloudFormation, then manually uploaded files and invalidated the cache. That works for one-off deployments, but every content change requires running AWS CLI commands. CodePipeline can automate this—push to GitHub, and your site updates automatically.

The setup uses three CloudFormation stacks. The first two create the S3 bucket and CloudFront distribution, exporting values the pipeline needs. The third stack creates a CodePipeline that watches your GitHub repository, runs CodeBuild to upload files to S3, and invalidates CloudFront cache on every push.

Here's what we'll build: fork a GitHub repository, create a CodeStar connection, deploy the three stacks, then push a change and watch the pipeline deploy it automatically.

## What You'll Build

Three CloudFormation stacks. The S3 and CloudFront stacks are similar to the [manual deployment setup](./host-static-s3-website-cloudfront-cloudformation.md), but they export additional values the pipeline needs. The CodePipeline stack imports those values and creates a pipeline with a CodeBuild project that runs your buildspec—a YAML file that defines the build commands CodeBuild executes to upload files to S3 and invalidate CloudFront cache.

When you push to GitHub, CodePipeline triggers, CodeBuild uploads files to S3, and CloudFront cache invalidates automatically.

```
Stack 1: S3 Bucket
  ├─ Bucket with versioning and encryption
  ├─ Exports: BucketName, BucketDomainName

Stack 2: CloudFront Distribution
  ├─ Imports: BucketName (from Stack 1)
  ├─ CloudFront distribution with OAC
  └─ Exports: DistributionId

Stack 3: CodePipeline
  ├─ Imports: BucketName, DistributionId (from Stacks 1 & 2)
  ├─ Artifact bucket for pipeline artifacts
  ├─ CodeStar connection to GitHub
  ├─ CodeBuild project with buildspec
  └─ Pipeline: Source → Build → Deploy
```

| Component | Purpose |
|-----------|---------|
| S3 Stack | Creates bucket, exports name for pipeline |
| CloudFront Stack | Creates distribution, exports ID for invalidation |
| CodePipeline Stack | Connects GitHub, runs buildspec, deploys automatically |
| CodeStar Connection | OAuth-based GitHub integration (no access tokens) |
| CodeBuild | Runs buildspec to upload files and invalidate cache |

## Prerequisites

You'll need AWS CLI v2, CloudFormation permissions (S3, CloudFront, CodePipeline, CodeBuild, IAM), and an AWS account in **us-west-2**. You'll also need a GitHub account to fork the repository.

The demo files are in the [buildwithbrainyl/ccp](https://github.com/buildwithbrainyl/ccp) repository. Fork the repository so CodePipeline can connect to your copy.

## Step-by-Step Playbook

### Step 1: Fork the GitHub Repository

Fork the repository so CodePipeline can connect to your GitHub account:

1. Visit [https://github.com/buildwithbrainyl/ccp](https://github.com/buildwithbrainyl/ccp)
2. Click "Fork" in the top right
3. Choose your GitHub account
4. Note your fork's URL: `https://github.com/YOUR_USERNAME/ccp`

The buildspec.yaml file is already in the repository at `builders-day/s3/demo_s3/buildspec.yml`. CodeBuild will use this file automatically.

### Step 2: Create CodeStar Connection

CodeStar connections use OAuth to connect AWS to GitHub without storing access tokens. Create the connection in the AWS Console first—CloudFormation can't create it for you.

1. Open AWS Console → CodePipeline → Settings → Connections
2. Click "Create connection"
3. Select "GitHub" as the provider
4. Name the connection: `github-connection`
5. Click "Connect to GitHub"
6. Authorize AWS CodeStar in GitHub
7. Under GitHub Apps, choose an existing app installation if you've already installed the AWS Connector for GitHub app, or choose "Install a new app" to create one (you only install the app once per GitHub account)
8. If installing a new app, select the repository or organization you want to grant access to and click "Install"
9. Click "Connect" in the AWS Console

Note the connection ARN—you'll use it in the CodePipeline stack. It looks like: `arn:aws:codestar-connections:us-west-2:ACCOUNT_ID:connection/CONNECTION_ID`

### Step 3: Deploy the S3 Bucket Stack

This stack is identical to the [S3 stack from the manual deployment](./host-static-s3-website-cloudfront-cloudformation.md), but we'll ensure it exports the bucket name:

```yaml
# s3-bucket.yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'S3 bucket for static website hosting with CloudFront'

Parameters:
  BucketName:
    Type: String
    Description: 'Globally unique bucket name'
    Default: 'cloudfront-demo-bucket'

Resources:
  StaticWebsiteBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Ref BucketName
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

Outputs:
  BucketName:
    Description: 'Name of the S3 bucket'
    Value: !Ref StaticWebsiteBucket
    Export:
      Name: !Sub '${AWS::StackName}-BucketName'

  BucketDomainName:
    Description: 'Domain name of the S3 bucket'
    Value: !GetAtt StaticWebsiteBucket.RegionalDomainName
    Export:
      Name: !Sub '${AWS::StackName}-BucketDomainName'
```

Deploy the stack:

```bash
aws cloudformation create-stack \
  --stack-name s3-static-website \
  --template-body file://s3-bucket.yaml \
  --parameters ParameterKey=BucketName,ParameterValue=cloudfront-demo-$(date +%Y%m%d) \
  --region us-west-2

aws cloudformation wait stack-create-complete \
  --stack-name s3-static-website \
  --region us-west-2
```

### Step 4: Deploy the CloudFront Distribution Stack

This stack creates the CloudFront distribution and exports the distribution ID for cache invalidation:

```yaml
# cloudfront-distribution.yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'CloudFront distribution for S3 static website'

Parameters:
  S3StackName:
    Type: String
    Description: 'Name of the S3 bucket stack'
    Default: 's3-static-website'

Resources:
  OriginAccessControl:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub '${AWS::StackName}-OAC'
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  CloudFrontDistribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Origins:
          - Id: S3Origin
            DomainName:
              Fn::ImportValue:
                Fn::Sub: '${S3StackName}-BucketDomainName'
            OriginAccessControlId: !GetAtt OriginAccessControl.Id
            S3OriginConfig: {}
        Enabled: true
        DefaultRootObject: index.html
        Comment: 'Static website distribution'
        DefaultCacheBehavior:
          TargetOriginId: S3Origin
          ViewerProtocolPolicy: redirect-to-https
          AllowedMethods:
            - GET
            - HEAD
          CachedMethods:
            - GET
            - HEAD
          ForwardedValues:
            QueryString: false
            Cookies:
              Forward: none
          MinTTL: 0
          DefaultTTL: 86400
          MaxTTL: 31536000
          Compress: true
        PriceClass: PriceClass_All
        HttpVersion: http2
        IPV6Enabled: true
        CustomErrorResponses:
          - ErrorCode: 403
            ResponseCode: 404
            ResponsePagePath: /error.html
            ErrorCachingMinTTL: 300
          - ErrorCode: 404
            ResponseCode: 404
            ResponsePagePath: /error.html
            ErrorCachingMinTTL: 300

  BucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket:
        Fn::ImportValue:
          Fn::Sub: '${S3StackName}-BucketName'
      PolicyDocument:
        Statement:
          - Sid: AllowCloudFrontServicePrincipal
            Effect: Allow
            Principal:
              Service: cloudfront.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub
              - 'arn:aws:s3:::${BucketName}/*'
              - BucketName:
                  Fn::ImportValue:
                    Fn::Sub: '${S3StackName}-BucketName'
            Condition:
              StringEquals:
                AWS:SourceArn: !Sub 'arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}'

Outputs:
  DistributionId:
    Description: 'CloudFront distribution ID'
    Value: !Ref CloudFrontDistribution
    Export:
      Name: !Sub '${AWS::StackName}-DistributionId'

  DistributionDomainName:
    Description: 'CloudFront distribution domain name'
    Value: !GetAtt CloudFrontDistribution.DomainName

  DistributionURL:
    Description: 'Full URL to access the website'
    Value: !Sub 'https://${CloudFrontDistribution.DomainName}'
```

Deploy the CloudFront stack:

```bash
aws cloudformation create-stack \
  --stack-name cloudfront-distribution \
  --template-body file://cloudfront-distribution.yaml \
  --parameters ParameterKey=S3StackName,ParameterValue=s3-static-website \
  --region us-west-2

aws cloudformation wait stack-create-complete \
  --stack-name cloudfront-distribution \
  --region us-west-2
```

### Step 5: Deploy the CodePipeline Stack

This stack creates the pipeline that watches GitHub and runs CodeBuild. It imports the bucket name and distribution ID from the previous stacks:

```yaml
# codepipeline-stack.yaml
# codepipeline-stack.yaml
# codepipeline-stack.yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'CodePipeline for automated S3 and CloudFront deployments'

Parameters:
  S3StackName:
    Type: String
    Description: 'Name of the S3 bucket stack'
    Default: 's3-static-website'

  CloudFrontStackName:
    Type: String
    Description: 'Name of the CloudFront distribution stack'
    Default: 'cloudfront-distribution'

  GitHubOwner:
    Type: String
    Description: 'GitHub username or organization name'

  GitHubRepo:
    Type: String
    Description: 'GitHub repository name'
    Default: 'ccp'

  GitHubBranch:
    Type: String
    Description: 'GitHub branch to watch'
    Default: 'main'

  CodeStarConnectionArn:
    Type: String
    Description: 'ARN of the CodeStar connection to GitHub'

Resources:
  ArtifactBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub '${AWS::StackName}-artifacts-${AWS::AccountId}'
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: DeleteOldArtifacts
            Status: Enabled
            ExpirationInDays: 7

  CodeBuildRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: codebuild.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: S3Access
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - s3:PutObject
                  - s3:GetObject
                  - s3:ListBucket
                Resource:
                  - !Sub
                      - 'arn:aws:s3:::${BucketName}/*'
                      - BucketName:
                          Fn::ImportValue:
                            Fn::Sub: '${S3StackName}-BucketName'
                  - !Sub
                      - 'arn:aws:s3:::${BucketName}'
                      - BucketName:
                          Fn::ImportValue:
                            Fn::Sub: '${S3StackName}-BucketName'
        - PolicyName: CloudFrontAccess
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - cloudfront:CreateInvalidation
                Resource: '*'

  CodeBuildProject:
    Type: AWS::CodeBuild::Project
    Properties:
      Name: !Sub '${AWS::StackName}-build'
      ServiceRole: !GetAtt CodeBuildRole.Arn
      Artifacts:
        Type: CODEPIPELINE
      Environment:
        Type: LINUX_CONTAINER
        ComputeType: BUILD_GENERAL1_SMALL
        Image: aws/codebuild/standard:7.0
        EnvironmentVariables:
          - Name: S3_BUCKET
            Value:
              Fn::ImportValue:
                Fn::Sub: '${S3StackName}-BucketName'
          - Name: CLOUDFRONT_DISTRIBUTION_ID
            Value:
              Fn::ImportValue:
                Fn::Sub: '${CloudFrontStackName}-DistributionId'
      Source:
        Type: CODEPIPELINE
        BuildSpec: builders-day/s3/demo_s3/buildspec.yml

  PipelineRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: codepipeline.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: PipelinePolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - codebuild:BatchGetBuilds
                  - codebuild:StartBuild
                  - codestar-connections:UseConnection
                Resource: '*'
              - Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:PutObject
                Resource: !Sub
                  - '${BucketArn}/*'
                  - BucketArn: !GetAtt ArtifactBucket.Arn
              - Effect: Allow
                Action:
                  - s3:ListBucket
                Resource: !GetAtt ArtifactBucket.Arn

  DeploymentPipeline:
    Type: AWS::CodePipeline::Pipeline
    DependsOn: CodeBuildProject
    Properties:
      Name: !Sub '${AWS::StackName}-pipeline'
      RoleArn: !GetAtt PipelineRole.Arn
      ArtifactStore:
        Type: S3
        Location: !Ref ArtifactBucket
      Stages:
        - Name: Source
          Actions:
            - Name: SourceAction
              ActionTypeId:
                Category: Source
                Owner: AWS
                Provider: CodeStarSourceConnection
                Version: '1'
              Configuration:
                ConnectionArn: !Ref CodeStarConnectionArn
                FullRepositoryId: !Sub '${GitHubOwner}/${GitHubRepo}'
                BranchName: !Ref GitHubBranch
              OutputArtifacts:
                - Name: SourceOutput
        - Name: Build
          Actions:
            - Name: BuildAction
              ActionTypeId:
                Category: Build
                Owner: AWS
                Provider: CodeBuild
                Version: '1'
              Configuration:
                ProjectName: !Ref CodeBuildProject
              InputArtifacts:
                - Name: SourceOutput
              OutputArtifacts:
                - Name: BuildOutput

Outputs:
  PipelineName:
    Description: 'Name of the CodePipeline'
    Value: !Ref DeploymentPipeline

  PipelineUrl:
    Description: 'URL to view the pipeline in AWS Console'
    Value: !Sub 'https://${AWS::Region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${DeploymentPipeline}/view'
```

Get your CodeStar connection ARN:

```bash
CONNECTION_ARN=$(aws codestar-connections list-connections \
  --query 'Connections[?ConnectionName==`github-connection`].ConnectionArn' \
  --output text \
  --region us-west-2)

echo "Connection ARN: $CONNECTION_ARN"
```

Deploy the CodePipeline stack:

```bash

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
```

### Step 6: Trigger the Pipeline

The pipeline runs automatically on the first deployment. To trigger it manually or test a change:

1. Make a small change to a file in your forked repository
2. Commit and push to the `main` branch:

```bash
# In your local clone of the forked repo
cd ccp
echo "<!-- Updated via CodePipeline -->" >> builders-day/s3/demo_s3/index.html
git add builders-day/s3/demo_s3/index.html
git commit -m "Test CodePipeline deployment"
git push origin main
```

3. Watch the pipeline in AWS Console → CodePipeline → Your pipeline name

The pipeline stages:
- **Source**: Pulls code from GitHub
- **Build**: Runs CodeBuild with your buildspec, uploads files to S3, invalidates CloudFront

After the build completes, check your CloudFront URL—the changes should be live.

### Step 7: Understanding the Buildspec

The buildspec.yaml file defines what CodeBuild runs:

```yaml
version: 0.2

phases:
  install:
    runtime-versions:
      python: 3.11
    commands:
      - pip install --upgrade awscli
      
  pre_build:
    commands:
      - aws --version
      - aws s3 ls s3://$S3_BUCKET/ || echo "Bucket might be empty"
      
  build:
    commands:
      - aws s3 cp builders-day/s3/demo_s3/index.html s3://$S3_BUCKET/index.html --content-type "text/html"
      - aws s3 cp builders-day/s3/demo_s3/error.html s3://$S3_BUCKET/error.html --content-type "text/html"
      - aws s3 cp builders-day/s3/demo_s3/sample-image.jpg s3://$S3_BUCKET/sample-image.jpg --content-type "image/jpeg"
      
  post_build:
    commands:
      - |
        if [ ! -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
          aws cloudfront create-invalidation --distribution-id $CLOUDFRONT_DISTRIBUTION_ID --paths "/*"
        fi
```

CodeBuild sets `S3_BUCKET` and `CLOUDFRONT_DISTRIBUTION_ID` from the environment variables defined in the CloudFormation stack. The buildspec uploads files and invalidates cache automatically.

## Validation

Verify all three stacks are deployed:

```bash
aws cloudformation describe-stacks \
  --stack-name s3-static-website \
  --query 'Stacks[0].StackStatus' \
  --output text \
  --region us-west-2
# Expected: CREATE_COMPLETE

aws cloudformation describe-stacks \
  --stack-name cloudfront-distribution \
  --query 'Stacks[0].StackStatus' \
  --output text \
  --region us-west-2
# Expected: CREATE_COMPLETE

aws cloudformation describe-stacks \
  --stack-name codepipeline-deployment \
  --query 'Stacks[0].StackStatus' \
  --output text \
  --region us-west-2
# Expected: CREATE_COMPLETE
```

Check the pipeline execution:

```bash
PIPELINE_NAME=$(aws cloudformation describe-stacks \
  --stack-name codepipeline-deployment \
  --query 'Stacks[0].Outputs[?OutputKey==`PipelineName`].OutputValue' \
  --output text \
  --region us-west-2)

aws codepipeline list-pipeline-executions \
  --pipeline-name $PIPELINE_NAME \
  --max-items 1 \
  --region us-west-2
```

Verify files were uploaded to S3:

```bash
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name s3-static-website \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text \
  --region us-west-2)

aws s3 ls s3://$BUCKET_NAME/ --region us-west-2
```

## Cleanup

Delete stacks in reverse order—CodePipeline first, then CloudFront, then S3:

```bash
# Get artifact bucket name and empty it before deleting CodePipeline stack
ARTIFACT_BUCKET=$(aws cloudformation describe-stack-resources \
  --stack-name codepipeline-deployment \
  --logical-resource-id ArtifactBucket \
  --query 'StackResources[0].PhysicalResourceId' \
  --output text \
  --region us-west-2)

# Empty artifact bucket (versioned buckets require deleting all versions)
# First, delete all objects and their versions
aws s3api delete-objects \
  --bucket $ARTIFACT_BUCKET \
  --delete "$(aws s3api list-object-versions --bucket $ARTIFACT_BUCKET --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" \
  --region us-west-2 2>/dev/null || true

# Delete delete markers
aws s3api delete-objects \
  --bucket $ARTIFACT_BUCKET \
  --delete "$(aws s3api list-object-versions --bucket $ARTIFACT_BUCKET --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" \
  --region us-west-2 2>/dev/null || true

# Delete any remaining objects
aws s3 rm s3://$ARTIFACT_BUCKET --recursive --region us-west-2 2>/dev/null || true

# Delete CodePipeline stack
aws cloudformation delete-stack \
  --stack-name codepipeline-deployment \
  --region us-west-2

aws cloudformation wait stack-delete-complete \
  --stack-name codepipeline-deployment \
  --region us-west-2

# Delete CloudFront stack
aws cloudformation delete-stack \
  --stack-name cloudfront-distribution \
  --region us-west-2

aws cloudformation wait stack-delete-complete \
  --stack-name cloudfront-distribution \
  --region us-west-2

# Empty S3 bucket before deleting stack (versioned buckets require deleting all versions)
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name s3-static-website \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text \
  --region us-west-2)

# Delete all object versions
aws s3api delete-objects \
  --bucket $BUCKET_NAME \
  --delete "$(aws s3api list-object-versions --bucket $BUCKET_NAME --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" \
  --region us-west-2 2>/dev/null || true

# Delete delete markers
aws s3api delete-objects \
  --bucket $BUCKET_NAME \
  --delete "$(aws s3api list-object-versions --bucket $BUCKET_NAME --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" \
  --region us-west-2 2>/dev/null || true

# Delete any remaining objects
aws s3 rm s3://$BUCKET_NAME --recursive --region us-west-2 2>/dev/null || true

# Delete S3 stack
aws cloudformation delete-stack \
  --stack-name s3-static-website \
  --region us-west-2

aws cloudformation wait stack-delete-complete \
  --stack-name s3-static-website \
  --region us-west-2
```

CodePipeline and CodeBuild bill per execution and compute time. Delete the stacks to stop charges.

## Production Notes

**IAM Permissions:** The CodeBuild role has permissions to write to the specific S3 bucket and invalidate CloudFront. Tighten these to least privilege in production—limit S3 actions to the bucket path and CloudFront to the specific distribution.

**Buildspec Location:** The buildspec path is `builders-day/s3/demo_s3/buildspec.yml`. If you move files in your repository, update the `BuildSpec` parameter in the CodeBuild project.

**Multiple Environments:** Create separate pipelines for staging and production. Use different branches (e.g., `staging`, `main`) and different S3 buckets. Export environment-specific values from each stack.

**Build Optimization:** Use `aws s3 sync` instead of individual `cp` commands for faster uploads. Add build caching to speed up subsequent runs. Consider using CodeBuild's cache feature for dependencies.

**Error Handling:** Add CloudWatch alarms for pipeline failures. Set up SNS notifications to alert on build failures. Monitor CodeBuild logs for deployment issues.

**Cost Management:** CodeBuild charges for compute time. Use `BUILD_GENERAL1_SMALL` for small projects. Consider using `aws s3 sync` with `--delete` to remove old files, but test this carefully to avoid deleting content unintentionally.

See also: [Host Your Static S3 Website with CloudFront Using CloudFormation](./host-static-s3-website-cloudfront-cloudformation.md)

## Conclusion

- CodePipeline automates deployments: push to GitHub, files upload to S3, CloudFront cache invalidates
- Three-stack pattern separates concerns: S3, CloudFront, and pipeline each have their own stack
- CodeStar connections use OAuth—no access tokens to manage
- Export/import pattern connects stacks: pipeline imports bucket name and distribution ID
- Buildspec defines deployment steps: upload files, invalidate cache, all automated

Push code, watch it deploy. No manual AWS CLI commands needed.

