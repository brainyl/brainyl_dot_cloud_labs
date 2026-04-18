
Browser automation typically runs headless—agents click, navigate, and extract data without anyone watching. This works until you need to verify behavior, debug unexpected failures, or demonstrate what an agent is doing.

AWS AgentCore's browser tool provides two interfaces to the same Chrome instance: one for watching (Amazon DCV), one for automating (Chrome DevTools Protocol). Your agent does its work while you watch every click, every navigation, every form submission in real-time.

This matters when you're testing new automation sequences, investigating why an agent failed on a specific site, showing stakeholders what an agent actually does, or letting users monitor long-running tasks.

This post walks through what AgentCore's browser tool is, how the dual-interface model works, and how to build a system where users create browser sessions, stream them live, and watch agents work.

![Live browser automation demo showing AgentCore DCV streaming and CDP automation in action](/media/images/2026/01/agentcore-browser-demo.gif)
*Watch an AI agent navigate websites in real-time through AWS AgentCore's live browser streaming*

## What Is AWS AgentCore's Browser Tool?

AWS AgentCore provides managed tools for AI agents. The browser tool is a fully-managed Chrome instance that runs in AWS infrastructure with two simultaneous access methods:

1. **Amazon DCV Stream** - A low-latency video stream of the browser's display. This is what humans see. You get a presigned URL, open it in your browser, and watch the Chrome instance as if it were running locally.

2. **Chrome DevTools Protocol (CDP)** - A WebSocket connection that lets automation libraries like Playwright or Puppeteer control the browser programmatically. This is what agents use. They send commands to navigate, click, type, and extract data.

Both interfaces connect to the same browser instance at the same time. When your agent clicks a button via CDP, you see that click happen in the DCV stream. When your agent navigates to a new page, you see the page load in real-time.

This dual-interface model means you never have to choose between automation and visibility.

## How DCV Streaming Works

Amazon DCV (NICE DCV) is a remote display protocol designed for high-performance graphics streaming. AWS uses it for Windows WorkSpaces, Linux desktops, and graphics workloads.

For AgentCore browsers, DCV streams the Chrome window at 30-60 FPS with sub-100ms latency. The stream runs over HTTPS with WebRTC for efficiency. From your perspective, it looks like Chrome is running on your local machine.

**Key characteristics:**

- **Presigned URLs**: You request a presigned DCV URL from AgentCore with a configurable TTL. The URL contains temporary credentials that expire after the specified duration.
- **Browser-based viewer**: The DCV stream renders in your browser using the DCV SDK (JavaScript). No plugins or native apps required.
- **Read-only by default**: The DCV stream is view-only unless you explicitly request "take control" permissions. This prevents accidental interference with automation.
- **Adaptive quality**: DCV adjusts frame rate and compression based on network conditions.

The presigned URL pattern means you can share live views safely. Generate a URL, send it to someone, and they can watch the browser without needing AWS credentials. The URL expires automatically, limiting exposure.

## How CDP Automation Works

Chrome DevTools Protocol is the same protocol Chrome DevTools uses to debug web pages. It's a JSON-RPC API over WebSocket that lets you control Chrome programmatically.

AgentCore exposes CDP endpoints for its managed browsers. You get a WebSocket URL with authentication headers, connect via Playwright or Puppeteer, and issue commands.

**What CDP gives you:**

- **Full browser control**: Navigate, click, type, scroll, execute JavaScript, intercept network requests
- **Page introspection**: Read DOM, extract text, capture screenshots, get network activity
- **Multi-page support**: Open tabs, switch contexts, handle popups
- **Event stream**: Get notified when pages load, console messages appear, or dialogs open

Playwright and Puppeteer both support connecting to remote browsers via CDP. You provide the WebSocket URL and headers, and they handle the rest. From the automation script's perspective, it's the same as controlling a local Chrome instance.

AgentCore's CDP endpoint requires SigV4 authentication. You request presigned credentials from the API, and those credentials work for a configurable TTL (typically 5-15 minutes).

## Architecture Overview

Here's how the pieces fit together:

```
┌─────────────────┐
│   React App     │  User Interface
│  (Next.js)      │  • Create browser sessions
│                 │  • Request live view URLs
└────────┬────────┘  • Trigger automation
         │
         ▼
┌─────────────────┐
│  Browser API    │  FastAPI Service
│  (Python)       │  • Wraps AgentCore SDK
│                 │  • Manages sessions
└────────┬────────┘  • Generates presigned URLs
         │
         ▼
┌─────────────────┐
│  AWS AgentCore  │  Managed Chrome Browser
│  Browser Tool   │  • DCV streaming endpoint
│                 │  • CDP automation endpoint
└─────────────────┘

      ↓       ↓
      │       │
      │       └──────────────┐
      │                      │
      ▼                      ▼
┌──────────────┐    ┌────────────────┐
│  DCV Viewer  │    │ Automation     │
│  (Browser)   │    │ Agent (Python) │
│              │    │                │
│  Watches     │    │  Controls      │
│  Chrome      │    │  Chrome        │
└──────────────┘    └────────────────┘
```

**Data flow:**

1. User clicks "Create Browser" in the React app
2. React app calls the Browser API
3. Browser API calls AgentCore to provision a Chrome instance
4. AgentCore returns browser ID and session ID
5. User clicks "Get Live View"
6. Browser API requests a presigned DCV URL from AgentCore with a short TTL
7. React app opens the DCV URL in a new window
8. User sees the Chrome browser streaming via DCV
9. User clicks "Start Automation"
10. Browser API requests presigned CDP credentials from AgentCore
11. Automation agent connects to Chrome via CDP WebSocket
12. Agent navigates, clicks, types - user watches it happen in the DCV viewer

## Component Breakdown

### Browser Session API

This is a FastAPI service that wraps the `bedrock-agentcore` Python SDK. It exposes REST endpoints for:

- **POST /sessions** - Create a new AgentCore browser session
- **POST /sessions/{id}/live-view/presign** - Get a presigned DCV URL
- **POST /sessions/{id}/automation/presign** - Get presigned CDP credentials
- **DELETE /sessions/{id}** - Close the browser session

The API stores active sessions in memory (or DynamoDB in production). Each session holds a reference to the AgentCore `BrowserClient` object, which must stay alive for the session's lifetime. AgentCore doesn't support "attaching" to existing sessions - you create them and keep them in memory.

### Automation Agent

This is a Python script using Playwright's `connect_over_cdp()` method. It:

1. Requests CDP credentials from the Browser API
2. Connects to the AgentCore browser via WebSocket
3. Runs a sequence of actions (navigate to sites, search, scroll, etc.)
4. Disconnects when done

The automation runs in the backend for this demo, triggered by the React app. In production, automation agents might run in ECS tasks, Lambda functions, or Step Functions workflows.

### React Frontend

A Next.js app with three buttons: Create Browser, Get Live View, Start Automation. It also integrates the DCV SDK to render the live stream in a separate viewer page.

The frontend is straightforward - it's mostly calling the Browser API and handling responses. The interesting parts are:

- Loading the DCV SDK (a ~3MB JavaScript bundle)
- Handling DCV authentication and connection lifecycle
- Opening the live view in a new window so users can see the browser while interacting with controls

## What You'll Build

You'll download and run a complete demo that includes:

- **Backend API**: FastAPI service managing AgentCore sessions
- **Frontend UI**: React app for creating sessions and viewing browsers
- **Automation Agent**: Python script that navigates Wikipedia, searches for AI topics, and visits multiple sites
- **DCV Viewer**: Integrated viewer page that streams the browser in real-time

The automation sequence is deliberately slow (3-5 seconds between actions) so you can watch what's happening. The agent adds a banner to the page that says "🤖 AUTOMATION ACTIVE 🤖" so it's obvious when automation is running.

## Download and Setup

📦 **[Download Complete Demo (3.1 MB)](/media/images/2026/01/agentcore-browser-automation-demo.tar.gz)**

**SHA256 Checksum:**
```
10adc5ad84324090e0d81aa63753fadce91cf0b489e98c4abc32125e1d0e3d5d
```

Extract and set up:

```bash
tar -xzf agentcore-browser-automation-demo.tar.gz
cd agentcore-browser-automation-demo
```

**Prerequisites:**

| Tool | Version | Purpose |
|------|---------|---------|
| Python | 3.13+ | Backend API and automation |
| Node.js | 18+ | React frontend |
| npm | 9+ | Package management |
| AWS CLI | 2.x | Credential configuration |
| Playwright | Latest | Browser automation (auto-installed) |

**AWS Requirements:**
- Active AWS account
- IAM user/role with AgentCore permissions (see IAM section below)
- AWS credentials configured (`aws configure` or environment variables)
- Region: AgentCore Browser available in multiple AWS regions (check AWS Console for current availability)
- Estimated cost: **Under $1 for this tutorial** (if you destroy resources within 1 hour)

**Backend setup:**

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium

# Start backend
cd backend
python main.py
```

Backend runs on http://localhost:8100

**Frontend setup (new terminal):**

```bash
cd frontend
npm install
npm run dev
```

Frontend runs on http://localhost:3000

## Running the Demo

1. **Open the UI**: Navigate to http://localhost:3000
2. **Create Browser**: Click "Create Browser" and wait 10-15 seconds
3. **Open Live View**: Click "Get Live View" - a new window opens showing the AWS browser
4. **Start Automation**: Click "Start Automation" and watch the browser in the live view window

The agent will:
- Navigate to Example.com
- Go to Wikipedia and search for "Artificial Intelligence"
- Scroll through the article
- Visit the AWS website
- Navigate to Google

All of this happens in the live view window while the activity log shows progress.

## What's Happening Behind the Scenes

### Session Creation

When you click "Create Browser", the backend calls:

```python
from bedrock_agentcore.tools.browser_client import BrowserClient

# Region can be configured based on your deployment
client = BrowserClient(region="us-west-2")
browser_id = client.identifier
session_id = client.session_id
```

AgentCore provisions a fresh Chrome instance in a managed container. This takes 10-20 seconds. The browser starts at `about:blank` and waits for commands.

The `BrowserClient` object must stay in memory for the session's lifetime. If you lose the reference, the session becomes inaccessible (AgentCore doesn't support reattaching).

### Live View URL Generation

When you click "Get Live View", the backend calls:

```python
presigned_url = client.get_live_view_url(ttl_seconds=300)
```

AgentCore generates a DCV presigned URL valid for the specified duration. The URL contains:
- DCV server endpoint
- Session identifier
- Temporary authentication token
- Expiration timestamp

The frontend opens this URL in a new window. The DCV SDK (loaded from `public/dcv-sdk/`) handles authentication, WebSocket setup, and video decoding.

### Automation Credentials

When you click "Start Automation", the backend calls:

```python
ws_url, headers = client.generate_ws_headers()
```

AgentCore returns:
- CDP WebSocket URL (wss://...)
- SigV4 authentication headers
- Session identifier for routing

The automation agent uses these credentials with Playwright:

```python
from playwright.async_api import async_playwright

async with async_playwright() as p:
    browser = await p.chromium.connect_over_cdp(ws_url, headers=headers)
    page = await browser.new_page()
    await page.goto("https://example.com")
```

Playwright sends CDP commands over the WebSocket. Chrome executes them and sends back results. The DCV stream shows every action in real-time.

## Production Considerations

### Session Storage

This demo stores sessions in memory. In production, use DynamoDB:

- Store session metadata (user ID, created time, TTL)
- Store the AgentCore `BrowserClient` in a cache (Redis, ElastiCache)
- Implement cleanup jobs to close expired sessions
- Add session heartbeats to detect abandoned sessions

**Session Lifecycle Management:**

Critical: The `BrowserClient` object must remain in memory for the session's lifetime.

```python
# Production pattern: Store session metadata in DynamoDB
import boto3
from datetime import datetime, timedelta

dynamodb = boto3.resource('dynamodb')
sessions_table = dynamodb.Table('agentcore-browser-sessions')

def create_session(user_id, browser_client):
    session_id = browser_client.session_id
    
    # Store metadata in DynamoDB
    sessions_table.put_item(Item={
        'session_id': session_id,
        'user_id': user_id,
        'browser_id': browser_client.identifier,
        'created_at': datetime.utcnow().isoformat(),
        'expires_at': (datetime.utcnow() + timedelta(hours=1)).isoformat(),
        'status': 'active'
    })
    
    # Cache BrowserClient in Redis with TTL
    redis_client.setex(
        f"browser_client:{session_id}",
        3600,  # 1 hour TTL
        pickle.dumps(browser_client)
    )
    
    return session_id
```

**Recovery Strategy:**

If a backend instance crashes, sessions on that instance are lost. Implement:
1. Session health checks every 60 seconds
2. Automatic session recreation on failure detection
3. User notification of session interruption

### Scaling

AgentCore automatically scales browser sessions based on demand. For production:

- Check current quotas in the AWS Service Quotas console
- Request quota increases via AWS Support if needed
- Implement session pooling for high-concurrency workloads
- Add queueing if sessions reach quota limits
- Use multiple regions to distribute load and increase total capacity

**Monitoring:**

Key metrics to track:
- Active session count (alert when approaching quota)
- Session duration (detect abandoned sessions)
- DCV connection failures (network issues)
- CDP command errors (automation failures)


### Security

**Authentication and Access Control:**

- Replace demo credentials with proper authentication (Cognito, OAuth)
- Implement role-based access control for session operations
- Use AWS SigV4 for service-to-service API calls
- Add audit logging for session creation and access
- Restrict DCV URLs to specific IP ranges if needed

**Data Protection:**

- DCV streams use TLS 1.2+ encryption in transit
- CDP WebSocket connections are encrypted via WSS protocol
- Presigned URLs contain temporary credentials with configurable TTL
- For recording storage, enable S3 bucket encryption (SSE-S3 or SSE-KMS)

**Audit and Compliance:**

Enable CloudTrail logging for AgentCore API calls:
- Track session creation and deletion
- Monitor presigned URL generation
- Alert on unusual access patterns

CloudWatch Logs capture:
- Browser session activity
- CDP command execution
- DCV connection events

### Cost Management

⚠️ **Note:** AgentCore pricing varies by region and usage patterns. Check the AWS Console or contact AWS Support for current rates.

**Cost factors:**
- Session duration (billed per second)
- Number of concurrent sessions
- Data transfer for DCV streams (typically minimal)

**Cost Optimization Strategies:**

- **Session Pooling**: Reuse sessions for multiple tasks instead of creating new ones
- **Idle Timeout**: Set aggressive timeouts (5-10 minutes) for inactive sessions
- **Scheduled Cleanup**: Run Lambda function every 15 minutes to close abandoned sessions
- **Region Selection**: Choose regions with lower data transfer costs for your use case
- **Right-Sizing**: Use session recording sparingly (adds S3 storage costs)
- **Cost Allocation Tags**: Tag browser sessions by project, team, or environment for detailed billing analysis

Always close sessions when done. Implement auto-cleanup for abandoned sessions (no activity for N minutes).

### IAM Permissions

The backend needs these IAM permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockAgentCoreBrowserAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:CreateBrowser",
        "bedrock-agentcore:ListBrowsers",
        "bedrock-agentcore:GetBrowser",
        "bedrock-agentcore:DeleteBrowser",
        "bedrock-agentcore:StartBrowserSession",
        "bedrock-agentcore:ListBrowserSessions",
        "bedrock-agentcore:GetBrowserSession",
        "bedrock-agentcore:StopBrowserSession",
        "bedrock-agentcore:UpdateBrowserStream",
        "bedrock-agentcore:ConnectBrowserAutomationStream",
        "bedrock-agentcore:ConnectBrowserLiveViewStream"
      ],
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:123456789012:browser/*"
    },
    {
      "Sid": "BedrockModelAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "*"
    }
  ]
}
```

**Production Security Best Practices:**

Replace `123456789012` with your AWS account ID. For production:

- Scope permissions to specific browser resources using ARNs
- Use separate IAM roles for session creation vs. viewing
- Implement resource tags for multi-tenant isolation
- Enable CloudTrail logging for all AgentCore API calls
- Use IAM conditions to restrict access by IP or VPC endpoint

**Least Privilege Example:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SessionCreationOnly",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:CreateBrowser",
        "bedrock-agentcore:StartBrowserSession"
      ],
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:123456789012:browser/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-west-2"
        }
      }
    },
    {
      "Sid": "ViewOnlyAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetBrowserSession",
        "bedrock-agentcore:ConnectBrowserLiveViewStream"
      ],
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:123456789012:browser/*"
    }
  ]
}
```

### Reliability Considerations

**Regional Availability:**

AgentCore Browser is a fully managed, serverless service available in multiple AWS regions. For production deployments:
- Choose regions based on latency requirements and data residency needs
- Browser sessions are regional - if a region experiences issues, create new sessions in another region
- AWS handles scaling, patching, and infrastructure management automatically
- Consider using multiple regions for geo-distributed users (reduces latency)

**Quota Management:**

Monitor concurrent session usage and request quota increases proactively:

- Check current quotas in the AWS Service Quotas console
- Track active session count (alert when approaching 90% of quota)
- Implement queueing or backoff when nearing limits
- Request quota increases via AWS Support before peak usage periods

## Troubleshooting

**"Service unavailable" when creating session**

Check the following:
- Your AWS region supports AgentCore Browser (check AWS Console for regional availability)
- Your IAM principal has the correct `bedrock-agentcore` permissions (see IAM section)
- AgentCore is enabled in your account

**Permission denied errors**

Verify your IAM permissions match the required actions:
```bash
# Test your credentials
aws sts get-caller-identity

# Verify you can list browsers (replace region as needed)
aws bedrock-agentcore list-browsers --region us-west-2
```

If you get permission errors, ensure your IAM policy includes all required actions listed in the IAM Permissions section.

**DCV viewer shows black screen**

Wait 30 seconds after session creation. The browser takes time to initialize. If still black:
- Check browser console for DCV SDK errors
- Verify the presigned URL hasn't expired (URLs have short TTLs)
- Try generating a new presigned URL
- Check network connectivity (DCV uses WebRTC)

**Automation can't connect**

Check:
- Session exists and status is "ready"
- CDP credentials haven't expired
- WebSocket URL and headers are correct
- Playwright is installed: `playwright install chromium`
- Network allows WebSocket connections (check firewall/proxy)

**Retry Strategy for Transient Failures:**

```python
import time
from botocore.exceptions import ClientError

def create_session_with_retry(max_retries=3):
    for attempt in range(max_retries):
        try:
            client = BrowserClient(region="us-west-2")
            return client
        except ClientError as e:
            if e.response['Error']['Code'] == 'ThrottlingException':
                wait_time = 2 ** attempt
                print(f"Throttled. Retrying in {wait_time}s...")
                time.sleep(wait_time)
            else:
                raise
    raise Exception("Max retries exceeded")
```

**Port conflicts**

If ports 8100 or 3000 are in use:

```bash
# Kill processes on ports
lsof -ti:8100 | xargs kill -9
lsof -ti:3000 | xargs kill -9
```

## Advanced Use Cases

### Human Takeover

Add a "Take Control" button that requests write access to the DCV stream. The user can then click, type, and navigate manually. When done, release control and let the agent continue.

This is useful for handling CAPTCHAs, unexpected dialogs, or demonstrating manual steps before automation.

```python
# Request interactive access to DCV stream
presigned_url = client.get_live_view_url(
    ttl_seconds=300,
    interactive=True  # Allow user input
)
```

### Session Recording

AgentCore supports session recording to S3 for playback and analysis. Configure recording when creating a custom browser:

```python
import boto3

client = boto3.client('bedrock-agentcore-control', region_name='us-west-2')

response = client.create_browser(
    name='RecordingBrowser',
    description='Browser with session recording enabled',
    networkConfiguration={'networkMode': 'PUBLIC'},
    executionRoleArn='arn:aws:iam::123456789012:role/AgentCoreBrowserRecordingRole',
    recording={
        'enabled': True,
        's3Location': {
            'bucket': 'my-recording-bucket',
            'prefix': 'browser-recordings'
        }
    }
)
```

Recording captures DOM mutations and reconstructs them during playback. Access recordings through the AWS Console or directly from S3.

### CI/CD Integration

Trigger automation from GitHub Actions, GitLab CI, or Jenkins. The workflow creates a browser session, runs end-to-end tests using Playwright + CDP, captures screenshots on failure, and closes the session in a cleanup step.

The live view URL can be posted to pull requests so reviewers can watch tests run in real-time. This provides visibility into test execution and helps debug failures faster.

## Next Steps

This demo shows the basics of AgentCore browser automation with live viewing. To go further:

- **Build a job application agent** that fills out forms while you watch
- **Create a testing platform** where QA teams can watch automated tests in real-time
- **Deploy to production** with DynamoDB session storage and ECS-hosted automation
- **Secure your infrastructure** with [VPC endpoints](./vpc-endpoint-service-private-connectivity.md) for private AgentCore access

For more AWS agent patterns and automation guides:

- [Deploy a Bedrock AgentCore Runtime with Terraform and ECR](./bedrock-agentcore-terraform.md)
- [Build an Intelligent PDF Grading Agent with Strands Multi-Tool Orchestration](./pdf-grading-agent-strands-multi-tool-orchestration.md)


## Conclusion

AWS AgentCore's browser tool solves the visibility problem in browser automation. Instead of reading logs to reconstruct what happened, you watch it happen in real-time.

**Key concepts:**

- **Dual interfaces**: DCV for viewing, CDP for automating, both connected to the same Chrome instance
- **Presigned URLs**: Short-lived credentials for secure, time-limited access
- **Stateful sessions**: BrowserClient objects must stay in memory for the session lifetime
- **Live streaming**: Sub-100ms latency DCV streams at 30-60 FPS
- **Programmatic control**: Full CDP access for Playwright/Puppeteer automation

The demo you downloaded includes all the pieces: API, frontend, automation, and DCV integration. You can run it locally, watch agents work, and extend it for your use case.

When automation fails, you'll see exactly what went wrong. When it succeeds, you'll know it followed the correct path. That visibility makes browser automation debuggable, verifiable, and trustworthy.

**Subscribe to Build with Brainyl** for more AWS automation patterns, or check the [labs directory](https://github.com/brainyl/build-with-brainyl/tree/main/labs) for more working examples.
