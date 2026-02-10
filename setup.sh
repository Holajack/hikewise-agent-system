#!/bin/bash
# ============================================================
# HikeWise Agent System - Master Setup Script
# Run this on your Lenovo (Ubuntu) machine
# ============================================================

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║       🏔️  HikeWise Agent System Setup  🏔️           ║"
echo "║                                                      ║"
echo "║  Automated Testing + Agent Coding + Dashboard        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --- Pre-flight checks ---
echo -e "${YELLOW}[1/8] Pre-flight checks...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker not found. Installing...${NC}"
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
    echo -e "${GREEN}Docker installed. You may need to log out and back in for group changes.${NC}"
fi

if ! command -v docker compose &> /dev/null; then
    echo -e "${RED}Docker Compose not found. Installing...${NC}"
    sudo apt-get update && sudo apt-get install -y docker-compose-plugin
fi

if ! command -v node &> /dev/null || [[ $(node -v | cut -d'.' -f1 | tr -d 'v') -lt 22 ]]; then
    echo -e "${YELLOW}Installing Node.js 22...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

echo -e "${GREEN}✓ Docker, Docker Compose, Node.js ready${NC}"

# --- Install Tailscale ---
echo -e "${YELLOW}[2/8] Checking Tailscale...${NC}"

if ! command -v tailscale &> /dev/null; then
    echo -e "${YELLOW}Installing Tailscale...${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh
    echo -e "${GREEN}Tailscale installed. Run 'sudo tailscale up' to connect.${NC}"
else
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
    echo -e "${GREEN}✓ Tailscale installed. IP: ${TAILSCALE_IP}${NC}"
fi

# --- Install Claude Code ---
echo -e "${YELLOW}[3/8] Installing Claude Code...${NC}"

if ! command -v claude &> /dev/null; then
    npm install -g @anthropic-ai/claude-code@latest
    echo -e "${GREEN}✓ Claude Code installed${NC}"
else
    echo -e "${GREEN}✓ Claude Code already installed ($(claude --version 2>/dev/null || echo 'installed'))${NC}"
fi

# --- Install Maestro ---
echo -e "${YELLOW}[4/8] Installing Maestro...${NC}"

if ! command -v maestro &> /dev/null; then
    curl -Ls "https://get.maestro.mobile.dev" | bash
    export PATH="$PATH:$HOME/.maestro/bin"
    echo 'export PATH="$PATH:$HOME/.maestro/bin"' >> ~/.bashrc
    echo -e "${GREEN}✓ Maestro installed${NC}"
else
    echo -e "${GREEN}✓ Maestro already installed${NC}"
fi

# --- Android SDK for Maestro (headless testing) ---
echo -e "${YELLOW}[5/8] Checking Android SDK for emulator testing...${NC}"

if [ -z "$ANDROID_HOME" ]; then
    echo -e "${YELLOW}Android SDK not found. Installing command-line tools...${NC}"
    sudo apt-get install -y openjdk-17-jdk wget unzip
    
    ANDROID_SDK_ROOT="$HOME/Android/Sdk"
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    
    if [ ! -d "$ANDROID_SDK_ROOT/cmdline-tools/latest" ]; then
        wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -O /tmp/cmdline-tools.zip
        unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-tmp
        mv /tmp/cmdline-tools-tmp/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest"
        rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-tmp
    fi
    
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"
    
    cat >> ~/.bashrc << 'ANDROIDEOF'
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"
ANDROIDEOF
    
    yes | sdkmanager --licenses 2>/dev/null || true
    sdkmanager "platform-tools" "platforms;android-34" "system-images;android-34;google_apis;x86_64" "emulator"
    
    echo "no" | avdmanager create avd -n hikewise_test -k "system-images;android-34;google_apis;x86_64" --force
    
    echo -e "${GREEN}✓ Android SDK + emulator configured${NC}"
else
    echo -e "${GREEN}✓ Android SDK found at $ANDROID_HOME${NC}"
fi

# --- Create project directory structure ---
echo -e "${YELLOW}[6/8] Creating project structure...${NC}"

PROJECT_DIR="$HOME/hikewise-agent-system"
mkdir -p "$PROJECT_DIR"/{dashboard,agent/logs,maestro/flows,maestro/results,templates,data}

echo -e "${GREEN}✓ Project structure created at $PROJECT_DIR${NC}"

# --- Copy files ---
echo -e "${YELLOW}[7/8] Setting up files...${NC}"

# Copy all files from the distribution (this script's directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -d "$SCRIPT_DIR/dashboard" ]; then
    cp -r "$SCRIPT_DIR/dashboard/"* "$PROJECT_DIR/dashboard/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/agent" ]; then
    cp -r "$SCRIPT_DIR/agent/"* "$PROJECT_DIR/agent/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/maestro" ]; then
    cp -r "$SCRIPT_DIR/maestro/"* "$PROJECT_DIR/maestro/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/templates" ]; then
    cp -r "$SCRIPT_DIR/templates/"* "$PROJECT_DIR/templates/" 2>/dev/null || true
fi
if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" "$PROJECT_DIR/"
fi
if [ -f "$SCRIPT_DIR/Dockerfile" ]; then
    cp "$SCRIPT_DIR/Dockerfile" "$PROJECT_DIR/"
fi

# Make scripts executable
chmod +x "$PROJECT_DIR/agent/"*.sh 2>/dev/null || true

echo -e "${GREEN}✓ Files deployed${NC}"

# --- Install dashboard dependencies ---
echo -e "${YELLOW}[8/8] Installing dashboard dependencies...${NC}"

cd "$PROJECT_DIR/dashboard"
if [ -f "package.json" ]; then
    npm install
    echo -e "${GREEN}✓ Dashboard dependencies installed${NC}"
fi

# --- Summary ---
echo ""
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              ✅ Setup Complete!                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
echo "║  Next steps:                                         ║"
echo "║                                                      ║"
echo "║  1. Connect Tailscale:                               ║"
echo "║     sudo tailscale up                                ║"
echo "║                                                      ║"
echo "║  2. Start the dashboard:                             ║"
echo "║     cd ~/hikewise-agent-system/dashboard             ║"
echo "║     npm start                                        ║"
echo "║                                                      ║"
echo "║  3. Access from anywhere via Tailscale:              ║"
echo "║     http://<tailscale-ip>:3847                       ║"
echo "║                                                      ║"
echo "║  4. Set up your HikeWise repo worktree:              ║"
echo "║     cd ~/your-hikewise-repo                          ║"
echo "║     git worktree add ../hikewise-agent agent-work    ║"
echo "║                                                      ║"
echo "║  5. Copy CLAUDE.md to your repo:                     ║"
echo "║     cp ~/hikewise-agent-system/templates/CLAUDE.md \ ║"
echo "║        ~/your-hikewise-repo/                         ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
