#!/bin/bash
# ============================================================
# scan-app.sh - Deep Discovery Scanner for HikeWise
#
# Systematically scans every screen of the HikeWise app running
# on a physical iPhone via Expo Go. Uses Maestro hierarchy
# captures and screenshots to build a complete map of the app.
#
# Scan phases:
#   1. Launch app via Expo Go
#   2. Handle landing/login screen ("Continue as Jacken")
#   3. Capture home screen and discover bottom tabs
#   4. Navigate each bottom tab and capture
#   5. Explore profile area (top-right icon)
#   6. Explore settings
#   7. Deep scan sub-screens within each tab
#   8. Compile discovery report
#
# Environment variables:
#   DASHBOARD_URL - Dashboard HTTP endpoint (default: http://localhost:3847)
#   APP_ID        - App bundle ID (default: com.hikewise.app)
#   SCAN_ID       - Unique scan identifier (auto-generated if not set)
#   DEVICE_TYPE   - physical | simulator | auto
#   DEVICE_UDID   - Device UDID
#   APP_MODE      - expo-go | development-build
#   EXPO_DEV_URL  - Expo dev server URL (e.g. exp://10.2.1.233:8081)
# ============================================================

set -uo pipefail

# --- Logging (defined first so it can be used everywhere) ---
log() {
  echo "[scanner][$(date '+%H:%M:%S')] $1"
}

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD="${DASHBOARD_URL:-http://localhost:3847}"
APP_ID="${APP_ID:-com.hikewise.app}"
SCAN_ID="${SCAN_ID:-scan-$(date +%s)}"
DISCOVERY_DIR="$BASE_DIR/data/discovery"
SCREENSHOTS_DIR="$BASE_DIR/data/screenshots"
TEMP_DIR="$BASE_DIR/maestro/flows/_scanner_temp"
PARSER="$SCRIPT_DIR/parse-hierarchy.py"
SCAN_TIMEOUT=30  # seconds per Maestro command
NAV_WAIT=2       # seconds to wait after navigation

# Device detection: physical iPhone vs simulator
DEVICE_TYPE="${DEVICE_TYPE:-auto}"
DEVICE_UDID="${DEVICE_UDID:-}"
DEVICE_NAME="${DEVICE_NAME:-}"

# Auto-detect device if not specified
if [ "$DEVICE_TYPE" = "auto" ] || [ -z "$DEVICE_UDID" ]; then
  PHYSICAL_UDID=$(xcrun devicectl list devices 2>/dev/null | grep -i "available" | head -1 | grep -oE '[A-F0-9-]{36}' || true)
  if [ -n "$PHYSICAL_UDID" ]; then
    DEVICE_TYPE="physical"
    DEVICE_UDID="$PHYSICAL_UDID"
    DEVICE_NAME=$(xcrun devicectl list devices 2>/dev/null | grep "$PHYSICAL_UDID" | awk '{print $1}' || echo "Physical iPhone")
  else
    DEVICE_TYPE="simulator"
    DEVICE_UDID=""
    DEVICE_NAME="Simulator"
  fi
fi

# Maestro device flag
MAESTRO_DEVICE_FLAG=""
if [ "$DEVICE_TYPE" = "physical" ] && [ -n "$DEVICE_UDID" ]; then
  MAESTRO_DEVICE_FLAG="--device $DEVICE_UDID"
fi

# Expo Go support
APP_MODE="${APP_MODE:-expo-go}"
EXPO_DEV_URL="${EXPO_DEV_URL:-}"

# Effective appId for Maestro flows
EFFECTIVE_APP_ID="$APP_ID"
if [ "$APP_MODE" = "expo-go" ]; then
  EFFECTIVE_APP_ID="host.exp.Exponent"
fi

# Auto-detect Expo dev server URL if not set
if [ "$APP_MODE" = "expo-go" ] && [ -z "$EXPO_DEV_URL" ]; then
  LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
  if [ -n "$LOCAL_IP" ] && lsof -i :8081 -t > /dev/null 2>&1; then
    EXPO_DEV_URL="exp://${LOCAL_IP}:8081"
    log "Auto-detected local Expo dev server: $EXPO_DEV_URL"
  else
    log "WARNING: No Expo server found. Set EXPO_DEV_URL in dashboard Config."
  fi
elif [ "$APP_MODE" = "expo-go" ] && [ -n "$EXPO_DEV_URL" ]; then
  log "Using configured Expo URL: $EXPO_DEV_URL"
fi

mkdir -p "$DISCOVERY_DIR" "$SCREENSHOTS_DIR" "$TEMP_DIR"

# --- State: accumulate screens into a temp JSON file ---
SCREENS_FILE="$TEMP_DIR/_screens.json"
echo "[]" > "$SCREENS_FILE"
TOTAL_SCREENS=0
SUCCESSFUL=0
FAILED=0

# Track visited screens to avoid duplicates
VISITED_SCREENS=""

# --- Progress reporting ---
progress() {
  local step="$1"
  local total="$2"
  local label="$3"
  local status="${4:-scanning}"
  curl -s -X POST "$DASHBOARD/api/scanner/progress" \
    -H "Content-Type: application/json" \
    -d "{\"scanId\":\"$SCAN_ID\",\"step\":$step,\"total\":$total,\"label\":\"$label\",\"status\":\"$status\"}" \
    > /dev/null 2>&1 || true
}

# --- Cleanup on exit ---
cleanup() {
  log "Cleaning up temp files..."
  rm -rf "$TEMP_DIR"
  mkdir -p "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================
# CORE HELPERS
# ============================================================

# Write a mini Maestro YAML (actions on current screen, no launch)
write_mini_yaml() {
  local name="$1"
  local content="$2"
  local yaml_path="$TEMP_DIR/${name}.yaml"
  cat > "$yaml_path" << EOF
appId: ${EFFECTIVE_APP_ID}
---
$content
EOF
  echo "$yaml_path"
}

# Write the launch YAML (used once at start)
write_launch_yaml() {
  local yaml_path="$TEMP_DIR/_launch.yaml"
  if [ "$APP_MODE" = "expo-go" ] && [ -n "$EXPO_DEV_URL" ]; then
    cat > "$yaml_path" << EOF
appId: host.exp.Exponent
---
- launchApp:
    clearState: false
- openLink: ${EXPO_DEV_URL}
- waitForAnimationToEnd
- extendedWaitUntil:
    visible: .*
    timeout: 20000
EOF
  else
    cat > "$yaml_path" << EOF
appId: ${APP_ID}
---
- launchApp
- waitForAnimationToEnd
EOF
  fi
  echo "$yaml_path"
}

# Run a mini Maestro YAML flow
run_mini_flow() {
  local yaml_path="$1"
  # shellcheck disable=SC2086
  timeout "$SCAN_TIMEOUT" maestro $MAESTRO_DEVICE_FLAG test "$yaml_path" > /dev/null 2>&1
  return $?
}

# Capture hierarchy XML for the current screen
capture_hierarchy() {
  local screen_name="$1"
  local output_file="$DISCOVERY_DIR/${SCAN_ID}_hierarchy_${screen_name}.xml"

  # shellcheck disable=SC2086
  if timeout "$SCAN_TIMEOUT" maestro $MAESTRO_DEVICE_FLAG hierarchy > "$output_file" 2>/dev/null; then
    if [ -s "$output_file" ]; then
      echo "$output_file"
      return 0
    fi
  fi

  # Retry once
  sleep 2
  # shellcheck disable=SC2086
  if timeout "$SCAN_TIMEOUT" maestro $MAESTRO_DEVICE_FLAG hierarchy > "$output_file" 2>/dev/null; then
    if [ -s "$output_file" ]; then
      echo "$output_file"
      return 0
    fi
  fi

  echo ""
  return 1
}

# Take a screenshot using correct appId
capture_screenshot() {
  local screen_name="$1"
  local filename="${SCAN_ID}_${screen_name}.png"
  local filepath="$SCREENSHOTS_DIR/$filename"

  if [ "$DEVICE_TYPE" = "physical" ] && [ -n "$DEVICE_UDID" ]; then
    local ss_yaml="$TEMP_DIR/_screenshot.yaml"
    cat > "$ss_yaml" << SSEOF
appId: ${EFFECTIVE_APP_ID}
---
- takeScreenshot: ${filepath}
SSEOF
    # shellcheck disable=SC2086
    if timeout "$SCAN_TIMEOUT" maestro $MAESTRO_DEVICE_FLAG test "$ss_yaml" > /dev/null 2>&1; then
      if [ -f "$filepath" ]; then
        echo "$filename"
        return 0
      fi
    fi
  else
    if xcrun simctl io booted screenshot "$filepath" 2>/dev/null; then
      echo "$filename"
      return 0
    fi
  fi
  echo ""
  return 1
}

# Parse hierarchy XML to JSON using the Python parser
parse_elements() {
  local xml_file="$1"
  if [ -f "$xml_file" ] && [ -s "$xml_file" ]; then
    python3 "$PARSER" "$xml_file" 2>/dev/null
  else
    echo '{"totalElements":0,"textElements":[],"testIds":[],"buttons":[],"inputFields":[]}'
  fi
}

# Sanitize a name for use as a filename
safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//'
}

# Check if a screen was already visited
is_visited() {
  local name="$1"
  echo "$VISITED_SCREENS" | grep -qF "|${name}|"
}

# Mark a screen as visited
mark_visited() {
  local name="$1"
  VISITED_SCREENS="${VISITED_SCREENS}|${name}|"
}

# ============================================================
# SCAN & RECORD A SCREEN
# Captures hierarchy + screenshot, parses elements, appends
# to the screens JSON file.
# Args: screen_name navigated_via
# ============================================================
scan_screen() {
  local screen_name="$1"
  local navigated_via="$2"
  local safe=$(safe_name "$screen_name")

  if is_visited "$safe"; then
    log "    (skipping $screen_name - already scanned)"
    return 0
  fi
  mark_visited "$safe"

  sleep 1  # let animations settle

  local hierarchy_file=$(capture_hierarchy "$safe")
  local screenshot_file=$(capture_screenshot "$safe")
  local elements_json='{"totalElements":0,"textElements":[],"testIds":[],"buttons":[],"inputFields":[]}'
  local status="failed"

  if [ -n "$hierarchy_file" ]; then
    elements_json=$(parse_elements "$hierarchy_file")
    local elem_count=$(echo "$elements_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("totalElements",0))' 2>/dev/null || echo '?')
    log "    Captured $screen_name: $elem_count elements"
    status="success"
    SUCCESSFUL=$((SUCCESSFUL + 1))
  else
    log "    FAILED to capture $screen_name"
    FAILED=$((FAILED + 1))
  fi
  TOTAL_SCREENS=$((TOTAL_SCREENS + 1))

  # Append to screens file using Python (safe JSON handling)
  python3 << PYEOF
import json

# Load existing screens
with open("$SCREENS_FILE", "r") as f:
    screens = json.load(f)

# Parse elements
elements = json.loads('''$(echo "$elements_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || echo '{}')''')

screens.append({
    "name": $(python3 -c "import json; print(json.dumps('$screen_name'))" 2>/dev/null),
    "navigatedVia": "$navigated_via",
    "hierarchyFile": "$hierarchy_file",
    "screenshotUrl": "/screenshots/$screenshot_file",
    "elements": elements,
    "status": "$status",
    "capturedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
})

with open("$SCREENS_FILE", "w") as f:
    json.dump(screens, f)
PYEOF
}

# ============================================================
# HIERARCHY ANALYSIS HELPERS (Python inline)
# ============================================================

# Find bottom tab bar items from a hierarchy XML file.
# Returns JSON array of {text, bounds_y, bounds_x} for items in the bottom ~15% of screen.
find_bottom_tabs() {
  local xml_file="$1"
  python3 << 'PYEOF' "$xml_file"
import xml.etree.ElementTree as ET
import json, sys

xml_file = sys.argv[1]
try:
    tree = ET.parse(xml_file)
except:
    print("[]")
    sys.exit(0)

root = tree.getroot()

# First pass: find screen dimensions
max_y = 0
def find_max_y(node):
    global max_y
    bounds = node.get("bounds", "")
    if bounds:
        try:
            parts = bounds.replace("][", ",").strip("[]").split(",")
            if len(parts) == 4:
                y2 = int(parts[3])
                if y2 > max_y:
                    max_y = y2
        except:
            pass
    for child in node:
        find_max_y(child)

find_max_y(root)
if max_y == 0:
    max_y = 2532  # default iPhone 14 Pro Max

# Bottom 15% threshold
bottom_threshold = max_y * 0.85

# Second pass: find tappable items in the bottom region
tabs = []
seen_text = set()

def find_tabs(node):
    text = (node.get("text") or node.get("accessibilityText") or "").strip()
    clickable = node.get("clickable", "false").lower() == "true"
    node_class = (node.get("class") or node.get("type") or node.tag or "").lower()

    bounds = node.get("bounds", "")
    center_y = 0
    center_x = 0
    if bounds:
        try:
            parts = bounds.replace("][", ",").strip("[]").split(",")
            if len(parts) == 4:
                x1, y1, x2, y2 = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
                center_y = (y1 + y2) / 2
                center_x = (x1 + x2) / 2
        except:
            pass

    is_tappable = clickable or any(k in node_class for k in ("touchable", "pressable", "button", "tab"))

    # Tab bar items: tappable, in bottom region, short text
    if text and is_tappable and center_y > bottom_threshold and len(text) < 30:
        if text not in seen_text:
            seen_text.add(text)
            tabs.append({"text": text, "y": center_y, "x": center_x})

    # Also check for accessibility labels on image-based tabs (no text but has label)
    acc_label = (node.get("accessibilityLabel") or "").strip()
    if acc_label and not text and is_tappable and center_y > bottom_threshold and len(acc_label) < 30:
        if acc_label not in seen_text:
            seen_text.add(acc_label)
            tabs.append({"text": acc_label, "y": center_y, "x": center_x})

    for child in node:
        find_tabs(child)

find_tabs(root)

# Sort left to right
tabs.sort(key=lambda t: t["x"])
print(json.dumps(tabs))
PYEOF
}

# Find login/continue buttons from a hierarchy XML file.
# Looks for buttons with text like "Continue", "Get Started", "Sign In", "Log In", etc.
find_login_buttons() {
  local xml_file="$1"
  python3 << 'PYEOF' "$xml_file"
import xml.etree.ElementTree as ET
import json, sys, re

xml_file = sys.argv[1]
try:
    tree = ET.parse(xml_file)
except:
    print("[]")
    sys.exit(0)

root = tree.getroot()
buttons = []

login_patterns = [
    r"continue",
    r"get\s*started",
    r"sign\s*in",
    r"log\s*in",
    r"let.*go",
    r"start",
    r"enter",
    r"begin",
    r"skip",
]

def walk(node):
    text = (node.get("text") or node.get("accessibilityText") or "").strip()
    clickable = node.get("clickable", "false").lower() == "true"
    node_class = (node.get("class") or node.get("type") or node.tag or "").lower()
    is_tappable = clickable or any(k in node_class for k in ("touchable", "pressable", "button"))

    if text and is_tappable:
        text_lower = text.lower()
        for pattern in login_patterns:
            if re.search(pattern, text_lower):
                buttons.append({"text": text, "pattern": pattern})
                break

    for child in node:
        walk(child)

walk(root)
print(json.dumps(buttons))
PYEOF
}

# Find all tappable elements on a screen for deep exploration.
# Returns JSON array of {text, testId, x, y, region} where region is top/middle/bottom.
find_tappable_elements() {
  local xml_file="$1"
  python3 << 'PYEOF' "$xml_file"
import xml.etree.ElementTree as ET
import json, sys

xml_file = sys.argv[1]
try:
    tree = ET.parse(xml_file)
except:
    print("[]")
    sys.exit(0)

root = tree.getroot()

# Find screen dimensions
max_y = 0
def find_max(node):
    global max_y
    bounds = node.get("bounds", "")
    if bounds:
        try:
            parts = bounds.replace("][", ",").strip("[]").split(",")
            if len(parts) == 4 and int(parts[3]) > max_y:
                max_y = int(parts[3])
        except:
            pass
    for c in node:
        find_max(c)
find_max(root)
if max_y == 0:
    max_y = 2532

items = []
seen = set()

# Skip common non-navigable text
skip_patterns = {"back", "close", "cancel", "ok", "done", "x", "search", "type", "enter"}

def walk(node):
    text = (node.get("text") or node.get("accessibilityText") or "").strip()
    test_id = (node.get("resource-id") or node.get("testId") or node.get("accessibilityIdentifier") or "").strip()
    clickable = node.get("clickable", "false").lower() == "true"
    node_class = (node.get("class") or node.get("type") or node.tag or "").lower()
    is_tappable = clickable or any(k in node_class for k in ("touchable", "pressable", "button"))

    bounds = node.get("bounds", "")
    cx, cy = 0, 0
    if bounds:
        try:
            parts = bounds.replace("][", ",").strip("[]").split(",")
            if len(parts) == 4:
                cx = (int(parts[0]) + int(parts[2])) / 2
                cy = (int(parts[1]) + int(parts[3])) / 2
        except:
            pass

    if is_tappable and (text or test_id):
        key = text or test_id
        if key not in seen and key.lower() not in skip_patterns and len(key) < 60:
            seen.add(key)
            region = "top" if cy < max_y * 0.15 else ("bottom" if cy > max_y * 0.85 else "middle")
            items.append({
                "text": text,
                "testId": test_id,
                "x": round(cx),
                "y": round(cy),
                "region": region
            })

    for child in node:
        walk(child)

walk(root)
print(json.dumps(items))
PYEOF
}

# ============================================================
# MAIN SCAN FLOW
# ============================================================

TOTAL_PHASES=8

log "======================================================"
log "  HikeWise Deep Discovery Scanner"
log "  Scan ID:  $SCAN_ID"
log "  App ID:   $APP_ID ($EFFECTIVE_APP_ID)"
log "  App Mode: $APP_MODE"
log "  Device:   $DEVICE_TYPE ($DEVICE_NAME)"
log "  UDID:     ${DEVICE_UDID:-N/A (simulator)}"
log "  Expo URL: ${EXPO_DEV_URL:-not set}"
log "======================================================"

# ============================================================
# PHASE 1: Launch the app
# ============================================================
log ""
log "=== PHASE 1/$TOTAL_PHASES: Launching app ==="
progress 1 "$TOTAL_PHASES" "Launching app" "starting"

LAUNCH_YAML=$(write_launch_yaml)
if run_mini_flow "$LAUNCH_YAML"; then
  log "  App launched successfully"
else
  log "  WARNING: Launch flow returned error, app may already be running. Continuing..."
fi
sleep 3  # extra time for Expo to load the JS bundle

# ============================================================
# PHASE 2: Handle landing/login screen
# ============================================================
log ""
log "=== PHASE 2/$TOTAL_PHASES: Handling landing/login screen ==="
progress 2 "$TOTAL_PHASES" "Landing screen" "scanning"

# Capture what's on screen right now (could be landing page or home)
LANDING_HIERARCHY=$(capture_hierarchy "landing")
LANDING_SCREENSHOT=$(capture_screenshot "landing")

if [ -n "$LANDING_HIERARCHY" ]; then
  # Look for login/continue buttons
  LOGIN_BUTTONS=$(find_login_buttons "$LANDING_HIERARCHY")
  LOGIN_COUNT=$(echo "$LOGIN_BUTTONS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")

  if [ "$LOGIN_COUNT" -gt 0 ]; then
    FIRST_LOGIN=$(echo "$LOGIN_BUTTONS" | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b[0]["text"])' 2>/dev/null)
    log "  Found login button: \"$FIRST_LOGIN\""
    log "  Recording landing screen before tapping..."

    # Record the landing screen
    scan_screen "Landing Page" "launch"

    # Tap the login/continue button
    LOGIN_YAML=$(write_mini_yaml "login" "- tapOn:
    text: \"${FIRST_LOGIN}\"
- waitForAnimationToEnd
- extendedWaitUntil:
    visible: .*
    timeout: 10000")

    if run_mini_flow "$LOGIN_YAML"; then
      log "  Tapped \"$FIRST_LOGIN\" - waiting for app to load..."
      sleep "$NAV_WAIT"
    else
      log "  WARNING: Could not tap login button. Trying tap by text containing 'Continue'..."
      # Fallback: try tapping anything with "Continue" or "Jacken"
      FALLBACK_YAML=$(write_mini_yaml "login_fallback" "- tapOn:
    text: \".*ontinue.*\"
    optional: true
- waitForAnimationToEnd")
      run_mini_flow "$FALLBACK_YAML" || true
      sleep "$NAV_WAIT"
    fi
  else
    log "  No login buttons found - may already be on home screen"
    # Still record this as the initial screen
    scan_screen "Initial Screen" "launch"
  fi
else
  log "  WARNING: Could not capture landing screen hierarchy"
fi

# ============================================================
# PHASE 3: Capture home screen and discover bottom tabs
# ============================================================
log ""
log "=== PHASE 3/$TOTAL_PHASES: Home screen + bottom tab discovery ==="
progress 3 "$TOTAL_PHASES" "Home screen" "scanning"

HOME_HIERARCHY=$(capture_hierarchy "home")
HOME_SCREENSHOT=$(capture_screenshot "home")

BOTTOM_TABS_JSON="[]"
TAB_COUNT=0

if [ -n "$HOME_HIERARCHY" ]; then
  scan_screen "Home" "tab"

  # Discover bottom tabs
  BOTTOM_TABS_JSON=$(find_bottom_tabs "$HOME_HIERARCHY")
  TAB_COUNT=$(echo "$BOTTOM_TABS_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
  log "  Discovered $TAB_COUNT bottom tabs: $(echo "$BOTTOM_TABS_JSON" | python3 -c 'import json,sys; tabs=json.load(sys.stdin); print(", ".join(t["text"] for t in tabs))' 2>/dev/null || echo 'none')"

  # Also capture tappable elements for deep scan later
  HOME_TAPPABLES=$(find_tappable_elements "$HOME_HIERARCHY")
  HOME_TAP_COUNT=$(echo "$HOME_TAPPABLES" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
  log "  Found $HOME_TAP_COUNT tappable elements on home screen"
else
  log "  FAILED to capture home screen"
  scan_screen "Home" "tab"
fi

# ============================================================
# PHASE 4: Navigate each bottom tab
# ============================================================
log ""
log "=== PHASE 4/$TOTAL_PHASES: Scanning bottom tabs ==="
progress 4 "$TOTAL_PHASES" "Bottom tabs" "scanning"

for i in $(seq 0 $((TAB_COUNT - 1))); do
  TAB_TEXT=$(echo "$BOTTOM_TABS_JSON" | python3 -c "import json,sys; tabs=json.load(sys.stdin); print(tabs[$i]['text'])" 2>/dev/null)
  TAB_SAFE=$(safe_name "$TAB_TEXT")

  if [ -z "$TAB_TEXT" ] || is_visited "$TAB_SAFE"; then
    continue
  fi

  log "  [$((i+1))/$TAB_COUNT] Tapping bottom tab: $TAB_TEXT"

  # Tap the tab by text
  TAB_YAML=$(write_mini_yaml "tab_${TAB_SAFE}" "- tapOn:
    text: \"${TAB_TEXT}\"
- waitForAnimationToEnd")

  if run_mini_flow "$TAB_YAML"; then
    sleep "$NAV_WAIT"
    scan_screen "$TAB_TEXT" "bottom-tab"

    # Capture hierarchy for this tab to find sub-elements
    TAB_HIERARCHY=$(capture_hierarchy "tab_${TAB_SAFE}_detail")

    if [ -n "$TAB_HIERARCHY" ]; then
      # Look for sub-tabs within this tab
      TAB_SUB_TABS=$(find_bottom_tabs "$TAB_HIERARCHY")
      TAB_TAPPABLES=$(find_tappable_elements "$TAB_HIERARCHY")
      SUB_TAP_COUNT=$(echo "$TAB_TAPPABLES" | python3 -c 'import json,sys; items=json.load(sys.stdin); print(len([i for i in items if i["region"]=="middle"]))' 2>/dev/null || echo "0")
      log "    Found $SUB_TAP_COUNT tappable items in middle region"

      # Scroll down to see more content
      log "    Scrolling down to discover more..."
      SCROLL_YAML=$(write_mini_yaml "scroll_${TAB_SAFE}" "- scroll:
    direction: DOWN
- waitForAnimationToEnd")
      if run_mini_flow "$SCROLL_YAML"; then
        sleep 1
        SCROLL_SAFE="${TAB_SAFE}_scrolled"
        if ! is_visited "$SCROLL_SAFE"; then
          scan_screen "${TAB_TEXT} (scrolled)" "scroll"
        fi
      fi

      # Tap interesting sub-elements in the middle region (max 5 per tab)
      SUB_ITEMS=$(echo "$TAB_TAPPABLES" | python3 -c "
import json, sys
items = json.load(sys.stdin)
# Only middle-region items, skip things that look like bottom tabs
middle = [i for i in items if i['region'] == 'middle' and len(i.get('text','')) > 2]
# Prioritize items with text over just testIds
middle.sort(key=lambda x: (0 if x.get('text') else 1, x.get('y', 0)))
for item in middle[:5]:
    print(item.get('text') or item.get('testId', ''))
" 2>/dev/null)

      SUB_IDX=0
      while IFS= read -r SUB_ITEM; do
        [ -z "$SUB_ITEM" ] && continue
        SUB_SAFE=$(safe_name "$SUB_ITEM")
        [ -z "$SUB_SAFE" ] && continue

        if is_visited "${TAB_SAFE}_${SUB_SAFE}"; then
          continue
        fi

        SUB_IDX=$((SUB_IDX + 1))
        log "    Sub-screen $SUB_IDX: tapping \"$SUB_ITEM\""

        SUB_YAML=$(write_mini_yaml "sub_${TAB_SAFE}_${SUB_SAFE}" "- tapOn:
    text: \"${SUB_ITEM}\"
    optional: true
- waitForAnimationToEnd")

        if run_mini_flow "$SUB_YAML"; then
          sleep "$NAV_WAIT"
          mark_visited "${TAB_SAFE}_${SUB_SAFE}"
          scan_screen "${TAB_TEXT} > ${SUB_ITEM}" "sub-screen"

          # Scroll down in sub-screen too
          SUBSCROLL_YAML=$(write_mini_yaml "subscroll_${TAB_SAFE}_${SUB_SAFE}" "- scroll:
    direction: DOWN
- waitForAnimationToEnd")
          run_mini_flow "$SUBSCROLL_YAML" || true
          sleep 1
          if ! is_visited "${TAB_SAFE}_${SUB_SAFE}_scrolled"; then
            scan_screen "${TAB_TEXT} > ${SUB_ITEM} (scrolled)" "scroll"
          fi

          # Go back
          BACK_YAML=$(write_mini_yaml "back_${TAB_SAFE}_${SUB_SAFE}" "- pressKey: back
- waitForAnimationToEnd")
          run_mini_flow "$BACK_YAML" || true
          sleep 1
        else
          log "      Could not tap \"$SUB_ITEM\""
        fi
      done <<< "$SUB_ITEMS"

      # Scroll back to top before moving to next tab
      SCROLL_UP_YAML=$(write_mini_yaml "scrollup_${TAB_SAFE}" "- scroll:
    direction: UP
- scroll:
    direction: UP
- waitForAnimationToEnd")
      run_mini_flow "$SCROLL_UP_YAML" || true
    fi
  else
    log "    FAILED to tap tab: $TAB_TEXT"
  fi
done

# ============================================================
# PHASE 5: Explore profile area (top-right icon)
# ============================================================
log ""
log "=== PHASE 5/$TOTAL_PHASES: Exploring profile / top-right area ==="
progress 5 "$TOTAL_PHASES" "Profile area" "scanning"

# First, go back to home tab
if [ "$TAB_COUNT" -gt 0 ]; then
  FIRST_TAB=$(echo "$BOTTOM_TABS_JSON" | python3 -c 'import json,sys; tabs=json.load(sys.stdin); print(tabs[0]["text"])' 2>/dev/null || echo "")
  if [ -n "$FIRST_TAB" ]; then
    HOME_TAB_YAML=$(write_mini_yaml "go_home" "- tapOn:
    text: \"${FIRST_TAB}\"
    optional: true
- waitForAnimationToEnd")
    run_mini_flow "$HOME_TAB_YAML" || true
    sleep 1
  fi
fi

# Try tapping the top-right area (profile icon)
# On iPhone 14 Pro Max (1170x2532), top-right is around 90-95%, 5-8%
log "  Tapping top-right area for profile icon..."
PROFILE_YAML=$(write_mini_yaml "profile_icon" "- tapOn:
    point: \"90%,5%\"
- waitForAnimationToEnd")

if run_mini_flow "$PROFILE_YAML"; then
  sleep "$NAV_WAIT"

  # Check if something new appeared
  PROFILE_HIERARCHY=$(capture_hierarchy "profile_area")

  if [ -n "$PROFILE_HIERARCHY" ]; then
    scan_screen "Profile Area" "profile-icon"

    # Find tappable items in the profile/drawer area
    PROFILE_ITEMS=$(find_tappable_elements "$PROFILE_HIERARCHY")
    PROFILE_TEXTS=$(echo "$PROFILE_ITEMS" | python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    t = item.get('text', '')
    if t and len(t) > 1 and len(t) < 40:
        print(t)
" 2>/dev/null)

    PROF_IDX=0
    while IFS= read -r PROF_ITEM; do
      [ -z "$PROF_ITEM" ] && continue
      PROF_SAFE=$(safe_name "$PROF_ITEM")
      [ -z "$PROF_SAFE" ] && continue

      if is_visited "profile_$PROF_SAFE"; then
        continue
      fi

      PROF_IDX=$((PROF_IDX + 1))
      [ "$PROF_IDX" -gt 8 ] && break  # limit to 8 items in profile area

      log "    Profile item $PROF_IDX: tapping \"$PROF_ITEM\""

      PROF_NAV_YAML=$(write_mini_yaml "profile_${PROF_SAFE}" "- tapOn:
    text: \"${PROF_ITEM}\"
    optional: true
- waitForAnimationToEnd")

      if run_mini_flow "$PROF_NAV_YAML"; then
        sleep "$NAV_WAIT"
        mark_visited "profile_$PROF_SAFE"
        scan_screen "Profile > ${PROF_ITEM}" "profile-menu"

        # Scroll down in this sub-screen
        PROF_SCROLL_YAML=$(write_mini_yaml "profscroll_${PROF_SAFE}" "- scroll:
    direction: DOWN
- waitForAnimationToEnd")
        run_mini_flow "$PROF_SCROLL_YAML" || true
        sleep 1
        scan_screen "Profile > ${PROF_ITEM} (scrolled)" "scroll"

        # Go back
        PROF_BACK_YAML=$(write_mini_yaml "profback_${PROF_SAFE}" "- pressKey: back
- waitForAnimationToEnd")
        run_mini_flow "$PROF_BACK_YAML" || true
        sleep 1
      fi
    done <<< "$PROFILE_TEXTS"

    # Close profile area
    CLOSE_PROFILE_YAML=$(write_mini_yaml "close_profile" "- pressKey: back
- waitForAnimationToEnd")
    run_mini_flow "$CLOSE_PROFILE_YAML" || true
    sleep 1
  fi
else
  log "  Top-right tap didn't navigate anywhere, trying other positions..."
  # Try slightly different position
  for POS in "92%,6%" "88%,5%" "93%,7%" "85%,5%"; do
    ALT_YAML=$(write_mini_yaml "profile_alt_$(echo $POS | tr '%,' '_')" "- tapOn:
    point: \"${POS}\"
- waitForAnimationToEnd")
    if run_mini_flow "$ALT_YAML"; then
      sleep "$NAV_WAIT"
      ALT_HIERARCHY=$(capture_hierarchy "profile_alt")
      if [ -n "$ALT_HIERARCHY" ]; then
        log "  Found something at position $POS"
        scan_screen "Profile Area" "profile-icon-alt"
        # Close it
        CLOSE_ALT_YAML=$(write_mini_yaml "close_profile_alt" "- pressKey: back
- waitForAnimationToEnd")
        run_mini_flow "$CLOSE_ALT_YAML" || true
        break
      fi
    fi
  done
fi

# ============================================================
# PHASE 6: Navigate to Settings
# ============================================================
log ""
log "=== PHASE 6/$TOTAL_PHASES: Finding and scanning Settings ==="
progress 6 "$TOTAL_PHASES" "Settings" "scanning"

if ! is_visited "settings"; then
  # Strategy 1: Look for Settings in bottom tabs
  SETTINGS_FOUND=false

  # Try tapping text "Settings"
  SETTINGS_YAML=$(write_mini_yaml "nav_settings" "- tapOn:
    text: \"Settings\"
    optional: true
- waitForAnimationToEnd")

  if run_mini_flow "$SETTINGS_YAML"; then
    sleep "$NAV_WAIT"
    SETTINGS_HIERARCHY=$(capture_hierarchy "settings_check")
    if [ -n "$SETTINGS_HIERARCHY" ]; then
      scan_screen "Settings" "direct-tap"
      SETTINGS_FOUND=true

      # Scroll through settings to capture everything
      for SCROLL_NUM in 1 2 3; do
        SSETTINGS_SCROLL_YAML=$(write_mini_yaml "settings_scroll_${SCROLL_NUM}" "- scroll:
    direction: DOWN
- waitForAnimationToEnd")
        run_mini_flow "$SSETTINGS_SCROLL_YAML" || true
        sleep 1
        scan_screen "Settings (scroll $SCROLL_NUM)" "scroll"
      done

      # Go back
      SETTINGS_BACK_YAML=$(write_mini_yaml "settings_back" "- pressKey: back
- waitForAnimationToEnd")
      run_mini_flow "$SETTINGS_BACK_YAML" || true
    fi
  fi

  if [ "$SETTINGS_FOUND" = "false" ]; then
    log "  Settings not found via direct tap, trying profile > settings..."
    # Open profile area again and look for settings
    PROF2_YAML=$(write_mini_yaml "prof_for_settings" "- tapOn:
    point: \"90%,5%\"
- waitForAnimationToEnd")
    if run_mini_flow "$PROF2_YAML"; then
      sleep 1
      SETTINGS_YAML2=$(write_mini_yaml "settings_from_profile" "- tapOn:
    text: \"Settings\"
    optional: true
- tapOn:
    text: \".*etting.*\"
    optional: true
- waitForAnimationToEnd")
      if run_mini_flow "$SETTINGS_YAML2"; then
        sleep "$NAV_WAIT"
        scan_screen "Settings" "profile-menu"
        # Scroll
        for SCROLL_NUM in 1 2; do
          SSCROLL_YAML=$(write_mini_yaml "settings_scroll2_${SCROLL_NUM}" "- scroll:
    direction: DOWN
- waitForAnimationToEnd")
          run_mini_flow "$SSCROLL_YAML" || true
          sleep 1
          scan_screen "Settings (scroll $SCROLL_NUM)" "scroll"
        done
      fi
      # Go back twice (settings -> profile -> home)
      BACK2_YAML=$(write_mini_yaml "back_from_settings" "- pressKey: back
- waitForAnimationToEnd
- pressKey: back
- waitForAnimationToEnd")
      run_mini_flow "$BACK2_YAML" || true
    fi
  fi
fi

# ============================================================
# PHASE 7: Nora screen (paw icon at bottom)
# ============================================================
log ""
log "=== PHASE 7/$TOTAL_PHASES: Exploring Nora screen (paw icon) ==="
progress 7 "$TOTAL_PHASES" "Nora screen" "scanning"

if ! is_visited "nora"; then
  NORA_FOUND=false

  # Strategy 1: Try text-based tap
  for NORA_TEXT in "Nora" "nora" "AI" "Assistant" "Chat"; do
    NORA_YAML=$(write_mini_yaml "nora_${NORA_TEXT}" "- tapOn:
    text: \"${NORA_TEXT}\"
    optional: true
- waitForAnimationToEnd")
    if run_mini_flow "$NORA_YAML"; then
      sleep "$NAV_WAIT"
      NORA_HIERARCHY=$(capture_hierarchy "nora_check")
      if [ -n "$NORA_HIERARCHY" ]; then
        scan_screen "Nora" "bottom-tab"
        NORA_FOUND=true

        # Explore Nora screen
        NORA_TAPPABLES=$(find_tappable_elements "$NORA_HIERARCHY")
        NORA_ITEMS=$(echo "$NORA_TAPPABLES" | python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    t = item.get('text', '')
    if t and len(t) > 2 and item.get('region') == 'middle':
        print(t)
" 2>/dev/null)

        NORA_IDX=0
        while IFS= read -r NORA_ITEM; do
          [ -z "$NORA_ITEM" ] && continue
          NORA_SAFE=$(safe_name "$NORA_ITEM")
          NORA_IDX=$((NORA_IDX + 1))
          [ "$NORA_IDX" -gt 5 ] && break

          log "    Nora sub-item $NORA_IDX: \"$NORA_ITEM\""
          NORA_SUB_YAML=$(write_mini_yaml "nora_sub_${NORA_SAFE}" "- tapOn:
    text: \"${NORA_ITEM}\"
    optional: true
- waitForAnimationToEnd")
          if run_mini_flow "$NORA_SUB_YAML"; then
            sleep "$NAV_WAIT"
            scan_screen "Nora > ${NORA_ITEM}" "sub-screen"
            NORA_BACK_YAML=$(write_mini_yaml "nora_back_${NORA_SAFE}" "- pressKey: back
- waitForAnimationToEnd")
            run_mini_flow "$NORA_BACK_YAML" || true
            sleep 1
          fi
        done <<< "$NORA_ITEMS"

        break
      fi
    fi
  done

  # Strategy 2: If not found by text, try tapping paw icon area in bottom nav
  if [ "$NORA_FOUND" = "false" ]; then
    log "  Nora not found by text, trying bottom tab positions..."

    # The paw icon is typically one of the middle or last bottom tabs
    # Try center and right-center of bottom bar
    for POS in "50%,96%" "62%,96%" "75%,96%" "37%,96%"; do
      NORA_POS_YAML=$(write_mini_yaml "nora_pos_$(echo $POS | tr '%,' '_')" "- tapOn:
    point: \"${POS}\"
- waitForAnimationToEnd")
      if run_mini_flow "$NORA_POS_YAML"; then
        sleep "$NAV_WAIT"
        NORA_POS_HIERARCHY=$(capture_hierarchy "nora_pos")
        if [ -n "$NORA_POS_HIERARCHY" ]; then
          scan_screen "Bottom Tab ($POS)" "position-tap"
          log "    Found screen at bottom position $POS"
        fi
      fi
    done
  fi

  # Go back to first tab
  if [ "$TAB_COUNT" -gt 0 ]; then
    FIRST_TAB=$(echo "$BOTTOM_TABS_JSON" | python3 -c 'import json,sys; tabs=json.load(sys.stdin); print(tabs[0]["text"])' 2>/dev/null || echo "")
    if [ -n "$FIRST_TAB" ]; then
      GOHOME_YAML=$(write_mini_yaml "go_home_final" "- tapOn:
    text: \"${FIRST_TAB}\"
    optional: true
- waitForAnimationToEnd")
      run_mini_flow "$GOHOME_YAML" || true
    fi
  fi
fi

# ============================================================
# PHASE 8: Compile discovery report
# ============================================================
log ""
log "=== PHASE 8/$TOTAL_PHASES: Compiling discovery report ==="
progress 8 "$TOTAL_PHASES" "Compiling report" "compiling"

REPORT_FILE="$DISCOVERY_DIR/${SCAN_ID}_report.json"

python3 << PYEOF
import json

with open("$SCREENS_FILE", "r") as f:
    screens = json.load(f)

bottom_tabs = json.loads('''$(echo "$BOTTOM_TABS_JSON" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || echo '[]')''')

# Compute summary stats
total_test_ids = set()
total_text_labels = set()
total_elements = 0

for s in screens:
    elems = s.get("elements", {})
    for tid in elems.get("testIds", []):
        total_test_ids.add(tid)
    for t in elems.get("textElements", []):
        total_text_labels.add(t)
    total_elements += elems.get("totalElements", 0)

report = {
    "scanId": "$SCAN_ID",
    "appId": "$APP_ID",
    "appMode": "$APP_MODE",
    "expoDevUrl": "$EXPO_DEV_URL",
    "deviceType": "$DEVICE_TYPE",
    "deviceName": "$DEVICE_NAME",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "discoveredBottomTabs": [t["text"] for t in bottom_tabs],
    "screens": screens,
    "summary": {
        "totalScreens": len(screens),
        "successfulCaptures": sum(1 for s in screens if s.get("status") == "success"),
        "failedCaptures": sum(1 for s in screens if s.get("status") == "failed"),
        "totalTestIds": len(total_test_ids),
        "totalTextLabels": len(total_text_labels),
        "totalElements": total_elements,
        "navigationPaths": list(set(s.get("navigatedVia", "") for s in screens))
    }
}

with open("$REPORT_FILE", "w") as f:
    json.dump(report, f, indent=2)

print(json.dumps(report, indent=2))
PYEOF

log ""
log "======================================================"
log "  Deep Scan Complete!"
log "  Screens scanned: $TOTAL_SCREENS ($SUCCESSFUL ok, $FAILED failed)"
log "  Report: $REPORT_FILE"
log "======================================================"

# Notify dashboard
progress "$TOTAL_PHASES" "$TOTAL_PHASES" "Complete" "complete"

exit 0
