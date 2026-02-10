#!/bin/bash
# ============================================================
# HikeWise Agent Runner
# Runs Claude Code in headless mode against the worktree
# Reports status back to the dashboard
# Works on macOS and Linux
# ============================================================

set -euo pipefail

# --- Configuration (from environment or defaults) ---
WORKTREE="${WORKTREE_PATH:-$HOME/AppDev/thetriage}"
LOG_DIR="${HOME}/App Development/Agent_Control/files/hikewise-agent-system/agent/logs"
mkdir -p "$LOG_DIR"
LOG="${LOG_FILE:-$LOG_DIR/agent-$(date +%s).log}"
DASHBOARD="${DASHBOARD_URL:-http://localhost:3847}"
MODE="${AGENT_MODE:-auto}"
TASK_CONTEXT="${TASK_CONTEXT:-}"
TASKS_JSON="${TASKS_JSON:-[]}"
MAX_RUNTIME="${MAX_RUNTIME:-3600}"

# --- Logging ---
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG"
}

# --- Dashboard notification ---
notify() {
  curl -s -X POST "$DASHBOARD/api/tasks" \
    -H "Content-Type: application/json" \
    -d "$1" > /dev/null 2>&1 || true
}

# --- Pre-flight ---
log "======================================================"
log "  HikeWise Agent Starting"
log "  Mode: $MODE"
log "  Worktree: $WORKTREE"
log "======================================================"

if [ ! -d "$WORKTREE" ]; then
  log "ERROR: Worktree directory not found: $WORKTREE"
  log "   Run: cd /path/to/thetriage && git worktree add $WORKTREE agent-work"
  exit 1
fi

cd "$WORKTREE"

# Verify it's a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  log "ERROR: Not a git repository: $WORKTREE"
  exit 1
fi

BRANCH=$(git branch --show-current)
log "On branch: $BRANCH"

# --- Ensure progress file exists ---
PROGRESS_FILE="$WORKTREE/claude-progress.txt"
if [ ! -f "$PROGRESS_FILE" ]; then
  cat > "$PROGRESS_FILE" << 'PROGRESS'
# HikeWise Agent Progress Log

## Current Sprint Tasks
(No tasks yet. Add tasks via the dashboard or edit this file.)

## In Progress
(None)

## Completed
(None)

## Blocked / Needs Review
(None)

## Agent Notes
- Working on branch: agent-work
- All changes committed to this branch
- Human review required before merging to main
PROGRESS
  git add "$PROGRESS_FILE"
  git commit -m "chore: initialize agent progress tracking" || true
  log "Created progress tracking file"
fi

# --- Build the agent prompt based on mode ---
build_prompt() {
  local prompt=""

  case "$MODE" in
    "specific-task")
      prompt="You are the HikeWise automated development agent. Your job is to complete one specific task.

TASK: $TASK_CONTEXT

Instructions:
1. Read claude-progress.txt and CLAUDE.md for project context
2. Understand the codebase structure (src/screens/, src/navigation/, src/components/)
3. Implement the fix for this specific task
4. Run available tests to verify your changes work
5. If Maestro flows exist, run: maestro test maestro/flows/verify/
6. Update claude-progress.txt - move this task to Completed with notes
7. Commit your changes with a descriptive message
8. Do NOT push - commits stay local for human review

Important safety rules:
- Only modify files related to this task
- Do not change the git branch
- Do not delete or modify unrelated files
- If you encounter something unexpected, note it in claude-progress.txt and move on
- Keep your changes minimal and focused"
      ;;

    "test-and-fix")
      prompt="You are the HikeWise automated QA and fix agent.

Instructions:
1. Read claude-progress.txt and CLAUDE.md for project context
2. Run the Maestro test suite: maestro test maestro/flows/verify/ (if flows exist)
3. Also run discovery: maestro test maestro/flows/discovery/ (if available)
4. For each failure:
   a. Analyze the error
   b. Find the relevant source code in src/
   c. Implement a fix
   d. Re-run the specific failing test to verify
5. Update claude-progress.txt with what you found and fixed
6. Commit each fix separately with descriptive messages
7. Do NOT push

Focus on:
- Navigation issues (back button going to Landing instead of parent)
- Drawer opening from wrong side (should be RIGHT only)
- Missing UI elements that tests expect
- Broken component interactions
- Console errors or warnings"
      ;;

    "auto"|*)
      prompt="You are the HikeWise automated development agent running in autonomous mode.

Read claude-progress.txt and CLAUDE.md for project context.

Here are the queued tasks from the dashboard:
$TASKS_JSON

Instructions:
1. Read the progress file to understand current state
2. Pick the highest priority queued task
3. Implement the fix or feature (code is in src/ directory)
4. Run any available tests: maestro test maestro/flows/verify/
5. Update claude-progress.txt:
   - Move completed task to Completed section with notes
   - Add any new issues you discovered to the Current Sprint Tasks
6. Commit with a descriptive message
7. If time allows, move to the next queued task
8. Do NOT push - all commits stay local

Important:
- Work incrementally - one task at a time
- Keep changes focused and minimal
- If something is too complex, document what you've learned and move on
- Always leave the codebase in a working state
- If you discover test failures in existing code, create a note for them
- Print [TASK_COMPLETE] followed by the task description when you finish a task
- Print [TASK_FAILED] followed by the reason if you can't complete a task"
      ;;
  esac

  echo "$prompt"
}

PROMPT=$(build_prompt)

# --- Run Claude Code ---
log "Starting Claude Code in headless mode..."
log "   Timeout: ${MAX_RUNTIME}s"

# Use gtimeout on macOS (from coreutils), timeout on Linux
TIMEOUT_CMD="timeout"
if [[ "$(uname)" == "Darwin" ]] && command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD="gtimeout"
elif [[ "$(uname)" == "Darwin" ]]; then
  # No gtimeout on Mac, use perl-based timeout
  TIMEOUT_CMD=""
fi

if [ -n "$TIMEOUT_CMD" ]; then
  $TIMEOUT_CMD "$MAX_RUNTIME" claude -p "$PROMPT" \
    --allowedTools "Edit,Read,Write,Bash(npm test:*),Bash(npx jest*),Bash(maestro test*),Bash(git add*),Bash(git commit*),Bash(git diff*),Bash(git log*),Bash(git status),Bash(ls*),Bash(cat*),Bash(find*),Bash(grep*),Bash(npm run*),Bash(npx expo*),Bash(python*)" \
    2>&1 | tee -a "$LOG"
else
  # Fallback: run without timeout on Mac if coreutils not installed
  claude -p "$PROMPT" \
    --allowedTools "Edit,Read,Write,Bash(npm test:*),Bash(npx jest*),Bash(maestro test*),Bash(git add*),Bash(git commit*),Bash(git diff*),Bash(git log*),Bash(git status),Bash(ls*),Bash(cat*),Bash(find*),Bash(grep*),Bash(npm run*),Bash(npx expo*),Bash(python*)" \
    2>&1 | tee -a "$LOG"
fi

EXIT_CODE=${PIPESTATUS[0]}

# --- Post-run ---
if [ $EXIT_CODE -eq 0 ]; then
  log "Agent completed successfully"
  echo "[TASK_COMPLETE] Agent run finished successfully"
elif [ $EXIT_CODE -eq 124 ]; then
  log "Agent timed out after ${MAX_RUNTIME}s"
  echo "[TASK_FAILED] Agent timed out"
else
  log "Agent exited with code $EXIT_CODE"
  echo "[TASK_FAILED] Agent exited with error code $EXIT_CODE"
fi

# Show what changed
log ""
log "Changes made during this session:"
cd "$WORKTREE"
git log --oneline -10 2>/dev/null || log "(no commits)"
log ""
git diff --stat HEAD~5..HEAD 2>/dev/null || true

log ""
log "Agent session complete. Review changes before merging."
exit $EXIT_CODE
