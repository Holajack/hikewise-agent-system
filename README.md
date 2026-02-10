# 🏔️ HikeWise Agent System

A secure, local automation pipeline for autonomous mobile app testing and development.
No OpenClaw needed.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    YOUR MAC (anywhere)                   │
│                                                         │
│  Browser → http://lenovo-tailscale-ip:3847              │
│  ┌─────────────────────────────────────────────┐        │
│  │         Agent Control Dashboard              │        │
│  │  • Kanban task board                         │        │
│  │  • Agent status (active/idle/testing)        │        │
│  │  • Trigger Maestro tests                     │        │
│  │  • Queue tasks for the agent                 │        │
│  │  • View live logs                            │        │
│  └─────────────────────────────────────────────┘        │
└──────────────────────┬──────────────────────────────────┘
                       │ Tailscale (encrypted mesh VPN)
                       │
┌──────────────────────▼──────────────────────────────────┐
│               LENOVO (Ubuntu)                            │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │  Dashboard   │  │  Claude Code  │  │    Maestro    │  │
│  │  (Docker)    │  │  (headless)   │  │  (UI tester)  │  │
│  │  port 3847   │  │              │  │              │  │
│  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                │                  │           │
│         │         ┌──────▼───────┐   ┌──────▼───────┐  │
│         │         │ Git Worktree │   │   Android    │  │
│         │         │ (agent-work) │   │   Emulator   │  │
│         │         │              │   │              │  │
│         │         │ - Fixes code │   │ - Runs app   │  │
│         │         │ - Commits    │   │ - Taps/swipes│  │
│         │         │ - Never push │   │ - Verifies   │  │
│         └─────────┴──────────────┘   └──────────────┘  │
│                          │                              │
│                   ┌──────▼──────┐                       │
│                   │  Main Repo  │                       │
│                   │  (untouched │                       │
│                   │   by agent) │                       │
│                   └─────────────┘                       │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. On your Lenovo (Ubuntu)

```bash
# Install Tailscale and connect
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Note your Tailscale IP
tailscale ip -4

# Clone this system
git clone <this-repo> ~/hikewise-agent-system
cd ~/hikewise-agent-system

# Run setup (installs Docker, Node, Maestro, Claude Code, Android SDK)
chmod +x setup.sh
./setup.sh
```

### 2. Set up your HikeWise worktree

```bash
# Navigate to your HikeWise repo
cd ~/hikewise  # or wherever your repo is

# Create a worktree for the agent
git worktree add ../hikewise-agent -b agent-work

# Copy templates
cp ~/hikewise-agent-system/templates/CLAUDE.md ~/hikewise/CLAUDE.md
cp ~/hikewise-agent-system/templates/claude-progress.txt ~/hikewise-agent/claude-progress.txt
```

### 3. Start the dashboard

```bash
# Option A: Run directly
cd ~/hikewise-agent-system/dashboard
npm install
npm start

# Option B: Run in Docker (recommended)
cd ~/hikewise-agent-system
docker compose up -d
```

### 4. Configure via the dashboard

Open `http://<your-tailscale-ip>:3847` in your browser (from your Mac or phone).

Go to Config tab and set:
- **Repo Path**: `/home/your-user/hikewise`
- **Worktree Path**: `/home/your-user/hikewise-agent`
- **App Bundle ID**: `com.hikewise.app` (update to match yours)

### 5. Generate Maestro test flows

```bash
# Auto-generate basic flows from your Expo Router structure
chmod +x ~/hikewise-agent-system/maestro/generate-flows.sh
~/hikewise-agent-system/maestro/generate-flows.sh ~/hikewise

# Or use Maestro Studio to interactively discover elements
# (requires emulator/simulator running with your app)
maestro studio
```

### 6. On your Mac

```bash
# Install Tailscale
brew install tailscale
# Connect to same account as Lenovo

# Access dashboard from anywhere
open http://<lenovo-tailscale-ip>:3847
```

## How It Works

### Automated Testing (Replaces Human Tester)

1. **Build your app** for the emulator: `eas build --profile e2e-test --platform android`
2. **Install on emulator** running on Lenovo
3. **Press "Run Tests"** on the dashboard (or let agent trigger them)
4. **Maestro runs every flow**: navigation, messaging, sessions, study rooms
5. **Results appear on dashboard** with pass/fail for each flow
6. **Failed tests auto-create tasks** in the Kanban board

### Autonomous Agent (Codes While You Sleep)

1. **Queue tasks** on the dashboard Kanban board
2. **Press "Start Agent"** or schedule it via cron
3. **Claude Code picks up tasks**, works on the git worktree
4. **Makes fixes, runs tests, commits** (never pushes)
5. **Updates progress file** and dashboard
6. **You review in the morning**: `git log --oneline agent-work`

### Dashboard (Mission Control)

- **Kanban board**: Queued → In Progress → Review → Done / Failed
- **Agent status**: Real-time indicator showing active/idle/testing/error
- **Test runner**: Trigger specific Maestro flows or run all
- **Live logs**: See agent output in real-time via WebSocket
- **Activity feed**: Chronological history of everything

## Maestro Testing Guide

### How to discover element IDs

```bash
# Start your app on emulator/simulator
npx expo start

# Open Maestro Studio - visual element inspector
maestro studio
```

Maestro Studio shows you every element on screen. Click an element to see its:
- **Text** (what the user sees)
- **testID** (what you set in code)
- **Accessibility label**

### Writing custom flows

```yaml
appId: com.hikewise.app
---
- launchApp:
    clearState: true
- tapOn: "Get Started"           # By visible text
- tapOn:
    id: "email-input"            # By testID
- inputText: "test@example.com"
- tapOn:
    id: "submit-button"
- assertVisible: "Welcome!"
- swipe:
    direction: LEFT
- scroll:
    direction: DOWN
- pressKey: back
```

### Running tests

```bash
# All flows
maestro test maestro/flows/

# Specific flow
maestro test maestro/flows/03-messaging.yaml

# Record video of test run
maestro record maestro/flows/00-full-app-walkthrough.yaml

# Generate HTML report
maestro test maestro/flows/ --format html
```

### For HikeWise specifically

The `optional: true` flag on assertions means tests won't crash if an element isn't found yet. As you add testIDs to your components, remove the `optional: true` flags to make tests strict.

**Add testIDs to your React Native components:**
```jsx
<TouchableOpacity testID="trail-card-0" onPress={...}>
<TextInput testID="message-input" ... />
<Button testID="send-message-button" ... />
```

## File Structure

```
hikewise-agent-system/
├── setup.sh                    # Master setup script
├── docker-compose.yml          # Docker config for dashboard
├── Dockerfile                  # Dashboard container image
├── dashboard/
│   ├── package.json
│   ├── server.js               # Express + WebSocket backend
│   └── public/
│       └── index.html          # Dashboard UI
├── agent/
│   ├── run-agent.sh            # Claude Code headless runner
│   └── logs/                   # Agent session logs
├── maestro/
│   ├── generate-flows.sh       # Auto-generate flows from app structure
│   ├── flows/                  # Maestro YAML test flows
│   │   ├── 00-full-app-walkthrough.yaml
│   │   ├── 01-navigation-back-buttons.yaml
│   │   ├── 02-focus-sessions.yaml
│   │   ├── 03-messaging.yaml
│   │   └── 04-study-rooms.yaml
│   └── results/                # Test result JSON files
├── templates/
│   ├── CLAUDE.md               # Project context for the agent
│   └── claude-progress.txt     # Progress tracking template
└── data/                       # Dashboard persistent data
    ├── tasks.json
    ├── agent-status.json
    ├── history.json
    └── config.json
```

## Security

This system is significantly more secure than OpenClaw because:

- **No network exposure**: Dashboard only accessible via Tailscale (encrypted mesh VPN)
- **No third-party plugins**: No ClawHub supply chain risk
- **Scoped permissions**: Claude Code only has access to whitelisted tools
- **Git worktree isolation**: Agent can never modify your main branch
- **No push access**: Agent commits locally only, you review before merging
- **Docker isolation**: Dashboard runs in a container
- **No credential storage**: API keys stay in your local Claude Code config

## Scheduling Overnight Runs

```bash
# Add to crontab on Lenovo
crontab -e

# Run agent at midnight, stop at 6am
0 0 * * * cd /home/user/hikewise-agent-system && bash agent/run-agent.sh >> agent/logs/cron-$(date +\%Y\%m\%d).log 2>&1
0 6 * * * pkill -f "claude -p" || true

# Run full Maestro test suite every night at 11pm
0 23 * * * cd /home/user/hikewise-agent-system && maestro test maestro/flows/ --format json > maestro/results/nightly-$(date +\%Y\%m\%d).json 2>&1
```

## Troubleshooting

**Dashboard not accessible via Tailscale?**
- Verify both machines are on the same Tailscale network: `tailscale status`
- Check the dashboard is running: `docker compose ps` or `curl localhost:3847/api/stats`

**Maestro can't find elements?**
- Add `testID` props to your React Native components
- Use `maestro studio` to inspect the element hierarchy
- For Expo Go apps, use `openLink: exp://127.0.0.1:19000` instead of `launchApp`

**Agent not completing tasks?**
- Check logs: Dashboard → Logs tab
- Verify worktree path is correct in Config
- Ensure Claude Code is authenticated: `claude --version`
- Check progress file: `cat ~/hikewise-agent/claude-progress.txt`
