# AgentCore Browser Automation Demo

Watch AI agents work in real-time with AWS AgentCore.

## Prerequisites

- Python 3.13+
- Node.js 18+
- AWS credentials configured
- AWS region: `us-west-2`

## Quick Start

### 1. Install Backend Dependencies

```bash
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Install Frontend Dependencies

```bash
cd frontend
npm install
cd ..
```

### 3. Start Backend

```bash
source .venv/bin/activate
export AWS_PROFILE=your-profile  # Optional
export AWS_DEFAULT_REGION=us-west-2
cd backend
python main.py
```

Backend runs on: http://localhost:8100

### 4. Start Frontend (New Terminal)

```bash
cd frontend
npm run dev
```

Frontend runs on: http://localhost:3000

## Usage

1. Open http://localhost:3000
2. Click **"Create Browser"** to start an AWS browser session
3. Click **"Get Live View"** to watch the browser (opens in new tab)
4. Click **"Start Automation"** to see the AI agent work

The agent will:
- Visit Example.com
- Navigate to Wikipedia and search for "Artificial Intelligence"
- Scroll through content
- Visit AWS website
- Navigate to Google

## Project Structure

```
├── backend/           # FastAPI service
│   ├── main.py       # API endpoints
│   ├── config.py     # Configuration
│   └── agentcore_client.py
├── frontend/          # Next.js React app
│   └── src/app/
│       ├── page.tsx  # Main demo UI
│       └── viewer/   # DCV live viewer
└── requirements.txt   # Python dependencies
```

## Troubleshooting

**Port already in use:**
```bash
lsof -ti:8100 | xargs kill -9  # Kill backend
lsof -ti:3000 | xargs kill -9  # Kill frontend
```

**AWS credentials:**
Ensure your AWS profile has permissions for:
- `bedrock-agentcore:CreateSession`
- `bedrock-agentcore:GeneratePresignedUrl`

**Python version:**
```bash
python --version  # Should be 3.13+
```

**Node version:**
```bash
node --version  # Should be 18+
```
