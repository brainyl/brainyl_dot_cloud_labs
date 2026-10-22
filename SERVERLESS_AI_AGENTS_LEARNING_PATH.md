# AWS Serverless & AI Agents — Practical Learning Path

[Build with Brainyl on YouTube](https://www.youtube.com/@buildwithbrainyl) · [All labs](./README.md)

Two existing, hands-on live recordings that explore complementary AWS patterns: **event-driven automation** and **an LLM-powered Lambda agent that can call AWS tools**. Each lesson is self-contained; this ordering takes you from rule-based event handling to tool-using AI automation.

## Watch the two episodes

| Episode | YouTube lesson | What is built | Source / lab notes |
| --- | --- | --- | --- |
| **01** | [AWS EventBridge Pipes — DynamoDB → SQS → Lambda](https://youtu.be/C8CIhEk33go) | Configure a DynamoDB Stream to SQS pipe, consume events with Lambda, try content-based filters, transform the message shape, and test the resulting invocations | **AWS Console live build.** No video-matched code directory currently in this repository |
| **02** | [Build an AI Agent on AWS Lambda with Strands](https://youtu.be/L-Qltsoy3Hw) | Package Strands as a Lambda layer, create a Bedrock-powered translation agent, and use a tool to publish translated messages to Amazon SNS | [Step-by-step lab with architecture and code snippets](./blog/lambda-to-strands-agent.md) · [Companion blog](https://brainyl.cloud/turn-your-first-lambda-into-a-strands-agent/) |

## What to learn

### 01 — EventBridge Pipes: event-driven, without custom polling

- Model a source-to-target data flow: **DynamoDB Streams → EventBridge Pipe → SQS → EventBridge Pipe → Lambda**.
- Inspect the DynamoDB stream record format and the SQS message body.
- Configure source filters and transform the target input to simplify each Lambda handler.
- Verify each stage with DynamoDB records, queue inspections, and Lambda / CloudWatch logs.

**Important architectural caveat:** The live session illustrates creating multiple EventBridge Pipes that consume from **the same SQS queue** to perform different actions. Those pipes are competing consumers, **not** a guaranteed fan-out or routing mechanism. A message received (and removed) by one consumer may not be delivered to another; filtered-out messages can also be lost to the intended branch. Use **EventBridge rules with an event bus**, **SNS fan-out to separate queues**, or another explicit event-routing design when you need guaranteed conditional delivery to multiple consumers. Treat this session as a useful exploration of Pipes, filtering, and input transformation—not a production reference for queue-based broadcasting.

### 02 — Lambda + Strands: tool-using agent on serverless

- Understand the differences between generative AI models and systems that use a model plus prompts, tools and context to **take actions**.
- Set up SNS and the AWS execution permissions required for a tool-enabled agent.
- Package the Strands SDK for AWS Lambda, wire it to a model hosted through Amazon Bedrock and use the **call_aws** tool.
- Test the translation-to-SNS workflow, inspect logs and clean up provisioned AWS resources.

[Detailed Lambda-to-Strands guide](./blog/lambda-to-strands-agent.md)

## Suggested lesson highlights

| Episode | Jump straight to |
| --- | --- |
| EventBridge Pipes | [DynamoDB, SQS and the first pipe (06:46)](https://youtu.be/C8CIhEk33go?t=406) · [Conditional filtering (33:44)](https://youtu.be/C8CIhEk33go?t=2024) · [Target input transformation (49:31)](https://youtu.be/C8CIhEk33go?t=2971) |
| Lambda + Strands | [The four agent building blocks (09:33)](https://youtu.be/L-Qltsoy3Hw?t=573) · [Packaging the Lambda layer (35:08)](https://youtu.be/L-Qltsoy3Hw?t=2108) · [Strands/SNS agent implementation (49:15)](https://youtu.be/L-Qltsoy3Hw?t=2955) |

## Cost and safety notes

AWS resources (including EventBridge Pipes, SQS, DynamoDB, Lambda, SNS and Bedrock usage) can incur charges. Use least-privilege IAM in real deployments and delete the demo resources after testing. Demo permissions, examples, and manually provisioned settings should be reviewed and hardened before production use.

## Continue learning

- [AWS Networking & Private Infrastructure — five-video series](./NETWORKING_LEARNING_PATH.md)
- [Amazon ECS Fargate — eight-video learning path](./ECS_LEARNING_PATH.md)
