
AWS Lambda functions are great for running serverless code, but they're typically reactive—they execute when triggered and return a response. What if your Lambda could reason about requests, make decisions, and autonomously trigger other AWS services? That's where Strands Agent comes in.

Strands Agent is a Python SDK that transforms Lambda functions into intelligent agents capable of using large language models (LLMs) through Amazon Bedrock and calling AWS services via built-in tools. Instead of hardcoding every workflow, you give the agent instructions and let it figure out how to accomplish tasks. The agent can translate text, analyze data, make API calls, publish to SNS, write to DynamoDB, and more—all driven by natural language instructions rather than rigid if-then logic.

This playbook walks you through converting a standard Lambda function into a Strands-powered agent that translates English text to French using Bedrock and publishes results to SNS. You'll package the Strands SDK as a Lambda layer, configure IAM permissions, enable Bedrock model access, and deploy a working agent in under 30 minutes. By the end, you'll have a pattern you can reuse to agentify any Lambda function.

## What You'll Build

You'll build a French translation agent that accepts English text, uses Amazon Bedrock's Nova Pro model to translate it, and publishes the result to an SNS topic. The agent uses Strands' `use_aws` tool to interact with SNS without hardcoding boto3 calls, demonstrating how agents can autonomously trigger AWS services based on instructions.

```
Client → Lambda (Strands Agent) → Bedrock (Nova Pro) → SNS Topic → Email/Webhook
```

| Component      | Purpose                               |
|----------------|----------------------------------------|
| Lambda Layer   | Packages Strands SDK and tools         |
| Lambda Function| Agent handler with Bedrock integration |
| Amazon Bedrock | LLM inference (Nova Pro)               |
| SNS Topic      | Destination for translated messages    |
| IAM Role       | Grants Bedrock invoke and SNS publish  |

## Prerequisites

* AWS account in `us-west-2` with permissions to create Lambda functions, layers, SNS topics, and IAM roles.
* Amazon Bedrock access with at least one text model enabled (this guide uses `us.amazon.nova-pro-v1:0`). Enable models in the [Bedrock console](https://console.aws.amazon.com/bedrock/) if needed.
* AWS CloudShell access (recommended) or local AWS CLI v2 configured with appropriate credentials.
* **Python 3.12** (required). The Strands SDK requires Python 3.10+, but this guide uses Python 3.12 to match Lambda's runtime. This guide uses `uv` to automatically install Python 3.12 if needed, but you can also use `python3.12` directly if available.

## Step-by-Step Playbook

### Step 1: Prepare the Strands Layer in CloudShell

CloudShell comes preloaded with the AWS CLI and a persistent home directory, making it the quickest place to stage the Lambda layer. We'll use `uv` (a fast Python package installer) to automatically handle Python 3.12 and install the Strands SDK. Set your region and artifact bucket once, then install the Strands SDK plus bundled tools into a `python/` directory, zip it, and publish the layer.

**Install `uv` (if not already available):**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Build and publish the layer:**

```bash
# --- set once ---
REGION=us-west-2
BUCKET=my-artifacts-<acct>-$REGION

# create the artifacts bucket once (skip if it already exists)
aws s3 mb s3://$BUCKET --region $REGION

# clean & prep
rm -rf ~/strands_layer && mkdir -p ~/strands_layer/python
cd ~/strands_layer

# use uv to install Python 3.12 (if needed) and install packages
# uv automatically downloads Python 3.12 if not available
uv python install 3.12
uv pip install --python 3.12 --target python strands-agents strands-agents-tools

# package & upload
zip -r strands-layer-py312.zip python
aws s3 cp strands-layer-py312.zip s3://$BUCKET/layers/strands-layer-py312.zip --region $REGION

# publish the layer
aws lambda publish-layer-version \
  --layer-name strands-agents-py312 \
  --content S3Bucket=$BUCKET,S3Key=layers/strands-layer-py312.zip \
  --compatible-runtimes python3.12 \
  --region $REGION
```

The CLI returns a `LayerVersionArn`. Keep it handy—you'll attach it in the console shortly.

💡 Tip: Replace `<acct>` with a short identifier (e.g., last four digits of your account ID) to keep bucket names globally unique.

💡 Tip: `uv` automatically downloads Python 3.12 if it's not available, handles version requirements, and installs packages much faster than pip.

### Step 2: Create the SNS Topic

The agent publishes every translation to a dedicated SNS topic. Create it once (either in CloudShell or the SNS console) and note the returned ARN—it will match the `SNS_TOPIC_ARN` environment variable later.

```bash
aws sns create-topic --name demo-agent-topic --region $REGION
```

💡 Tip: In the SNS console, open the new topic, create an email subscription, and confirm the opt-in email that Amazon SNS sends you. Every Lambda invocation will then drop the French text straight into your mail client.

### Step 3: Configure IAM Permissions for the Lambda Role

Keep permissions lean. The role only needs CloudWatch Logs, SNS publish access, and the Bedrock invoke actions. Update `ACCOUNT_ID` with your own account number and confirm the Bedrock model you plan to use is enabled in your region.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { 
      "Effect": "Allow", 
      "Action": ["logs:CreateLogGroup"], 
      "Resource": "arn:aws:logs:us-west-2:ACCOUNT_ID:*" 
    },
    { 
      "Effect": "Allow", 
      "Action": ["logs:CreateLogStream","logs:PutLogEvents"], 
      "Resource": "arn:aws:logs:us-west-2:ACCOUNT_ID:log-group:/aws/lambda/msg-to-french-llm:*" 
    },
    { 
      "Effect": "Allow", 
      "Action": ["sns:Publish"], 
      "Resource": "arn:aws:sns:us-west-2:ACCOUNT_ID:demo-agent-topic" 
    },
    { 
      "Effect": "Allow", 
      "Action": ["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"], 
      "Resource": "*" 
    }
  ]
}
```

Create or update a Lambda execution role with this policy (inline or as a managed policy), then head to the Lambda console.

⚠️ Caution: The Bedrock resource is set to `"*"` for demo simplicity. In production, scope this to specific model ARNs like `"arn:aws:bedrock:us-west-2::foundation-model/us.amazon.nova-pro-v1:0"` to follow least-privilege principles.

### Step 4: Configure the Lambda Function

Create a new function named **msg-to-french-llm** in the console. Choose the Python 3.12 runtime and the IAM role you just configured. Add the Strands layer using the `LayerVersionArn` from Step 1, then set these environment variables:

* `SNS_TOPIC_ARN=arn:aws:sns:us-west-2:ACCOUNT_ID:demo-agent-topic`
* `DEFAULT_REGION=us-west-2`
* `BYPASS_TOOL_CONSENT=true`

That last flag keeps the Strands tooling opt-in prompt out of the way for this demo.

💡 Tip: If you prefer infrastructure-as-code, mirror the same settings in CloudFormation, CDK, or Terraform—the console walkthrough keeps things visual for a first-time conversion.

### Step 5: Implement the Agent Handler

Replace the default handler with the Strands-powered version below. The agent handles everything: it translates the text using Bedrock and publishes the result to SNS autonomously based on your instructions.

```python
import json
import os
from strands import Agent
from strands.models import BedrockModel
from strands_tools import use_aws

REGION = os.environ.get("AWS_REGION") or os.environ.get("DEFAULT_REGION", "us-west-2")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")

# Use any enabled Bedrock text model
model = BedrockModel(
    model_id="us.amazon.nova-pro-v1:0",  # pick a model you have access to
    temperature=0.0,  # deterministic for translation
)

# Create agent with system instructions and AWS tools
agent = Agent(
    model=model,
    tools=[use_aws],
    system_prompt=(
        f"You are a translator. When you receive a message, that message IS the text to translate. "
        f"Translate it to French, then publish the translation to SNS topic {SNS_TOPIC_ARN} "
        f"with subject 'Translated (FR)'. Output ONLY the French translation—no quotes, no explanations, no questions."
    )
)

def lambda_handler(event, context):
    """
    Input:
      {
        "prompt": "Your text to translate to French",
        "topic_arn": "optional SNS topic override"
      }
    """
    msg = (event.get("prompt") or "").strip()
    if not msg:
        return {"statusCode": 400, "body": json.dumps({"error": "Provide 'prompt'."})}

    # Call the agent directly with the prompt
    response = agent(msg)
    
    return {
        "statusCode": 200,
        "body": json.dumps({
            "original": msg,
            "translation": response.content if hasattr(response, 'content') else str(response)
        })
    }
```

The handler calls the agent directly with the prompt. The agent uses its system instructions to translate the text with Bedrock and publish to SNS using the `use_aws` tool—all autonomously without manual model calls or boto3.

### Step 6: Test the Agent

In the Lambda console, create a test event that passes a `prompt` key:

```json
{
  "prompt": "I hope you are having a great day!"
}
```

Run the test and watch CloudWatch capture the French output along with the SNS `MessageId`.

If you created the email subscription earlier, you should see the translated message appear moments after the test run completes.

### Step 7: Optional: Expose as a Function URL

Need to invoke the agent from a chat app or Zapier? Enable a Function URL (Auth type **NONE** for a quick demo) and call it from anywhere:

```bash
curl -s -X POST https://<function-url> \
  -H 'content-type: application/json' \
  -d '{"prompt":"We will meet at 3 PM near Union Station."}'
```

⚠️ Caution: Function URLs with `AuthType: NONE` are publicly accessible. For production, use `AuthType: AWS_IAM` and sign requests with SigV4, or place the function behind API Gateway with authentication.

## Validation

Verify the agent works end-to-end:

1. **Check Lambda execution**: In CloudWatch Logs, confirm the function invoked Bedrock and published to SNS:

```bash
aws logs tail /aws/lambda/msg-to-french-llm --follow --region us-west-2
```

2. **Verify SNS message**: List messages published to the topic:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-west-2:$ACCOUNT_ID:demo-agent-topic \
  --region us-west-2
```

3. **Test with different prompts**: Invoke the function multiple times with varied input to ensure consistent translation quality.

✅ Result: You should see successful Lambda invocations, Bedrock API calls in CloudTrail, and SNS messages delivered to your subscription endpoint.

## Cleanup

1. Delete the Lambda function:

```bash
aws lambda delete-function \
  --function-name msg-to-french-llm \
  --region us-west-2
```

2. Delete the Lambda layer (optional, but recommended to avoid clutter):

```bash
LAYER_VERSION=$(aws lambda list-layer-versions \
  --layer-name strands-agents-py312 \
  --region us-west-2 \
  --query 'LayerVersions[0].Version' --output text)

aws lambda delete-layer-version \
  --layer-name strands-agents-py312 \
  --version-number $LAYER_VERSION \
  --region us-west-2
```

3. Delete SNS subscriptions, then the topic:

```bash
# First, list and delete all subscriptions
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TOPIC_ARN=arn:aws:sns:us-west-2:$ACCOUNT_ID:demo-agent-topic
SUBSCRIPTIONS=$(aws sns list-subscriptions-by-topic \
  --topic-arn $TOPIC_ARN \
  --region us-west-2 \
  --query 'Subscriptions[].SubscriptionArn' \
  --output text)

for sub in $SUBSCRIPTIONS; do
  if [ "$sub" != "None" ] && [ -n "$sub" ]; then
    aws sns unsubscribe --subscription-arn "$sub" --region us-west-2
  fi
done

# Then delete the topic
aws sns delete-topic \
  --topic-arn $TOPIC_ARN \
  --region us-west-2
```

4. Delete the S3 artifacts bucket:

```bash
aws s3 rm s3://my-artifacts-<acct>-us-west-2/layers/strands-layer-py312.zip
aws s3 rb s3://my-artifacts-<acct>-us-west-2 --region us-west-2
```

5. Remove the IAM role and policies you created (if not reused elsewhere).

⚠️ Caution: CloudWatch Logs groups persist after function deletion. Delete them manually if you want to remove all traces:

```bash
aws logs delete-log-group \
  --log-group-name /aws/lambda/msg-to-french-llm \
  --region us-west-2
```

## Production Notes

* **IAM tightening**: Scope Bedrock permissions to specific model ARNs instead of `"*"`. Add resource-level conditions if your organization requires it.
* **Error handling**: Wrap Bedrock calls in try-except blocks and return meaningful error messages. Consider retries with exponential backoff for transient failures.
* **Cost optimization**: Use Bedrock's on-demand pricing for low-volume workloads, or provisioned throughput for predictable high-volume scenarios. Monitor token usage in CloudWatch.
* **Security**: Never hardcode credentials. Use IAM roles for Lambda execution. If exposing via Function URL, implement authentication (AWS_IAM or API Gateway with Cognito/OIDC).
* **Monitoring**: Set up CloudWatch alarms for Bedrock invocation failures, SNS publish errors, and Lambda duration spikes. Enable X-Ray tracing for end-to-end visibility.
* **Scaling**: Lambda automatically scales, but be aware of Bedrock service quotas. Request limit increases if you expect high concurrency.

## Key Takeaways

1. Strands Agent transforms Lambda functions into reasoning agents that can autonomously call AWS services based on natural language instructions.
2. Lambda layers keep the Strands SDK separate from your handler code, making updates and versioning easier.
3. The `use_aws` tool eliminates boilerplate boto3 code—agents call services declaratively through the SDK.
4. Bedrock integration gives you access to multiple LLM models without managing infrastructure or API keys.
5. This pattern extends to any AWS service: DynamoDB writes, Step Functions orchestration, EventBridge events, and more.

### Related Reading

* Learn how to secure Lambda functions with least-privilege IAM in the [AWS IAM best practices guide](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html).
* Explore more Bedrock models and capabilities in the [Amazon Bedrock documentation](https://docs.aws.amazon.com/bedrock/).
* Understand Lambda layers and best practices in the [AWS Lambda developer guide](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-concepts.html#gettingstarted-concepts-layer).

For deeper agent patterns, explore Strands' tool ecosystem and consider adding custom tools for domain-specific workflows. External references like the <a href="http://strandsagents.com/" target="_blank" rel="noopener">Strands documentation</a> and <a href="https://docs.aws.amazon.com/bedrock-agentcore/" target="_blank" rel="noopener">Amazon Bedrock AgentCore user guide</a> include advanced production considerations.
