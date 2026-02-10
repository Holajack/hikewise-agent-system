#!/bin/bash
# ============================================================
# scan-app.sh - Dynamic Discovery Scanner for HikeWise
#
# Scans the running app screen-by-screen using maestro hierarchy,
# captures screenshots, discovers drawer items dynamically,
# and compiles a discovery report for the dashboard.
#
# Environment variables:
#   DASHBOARD_URL - Dashboard HTTP endpoint (default: http://localhost:3847)
#   APP_ID        - App bundle ID (default: com.hikewise.app)
#   SCAN_ID       - Unique scan identifier (auto-generated if not set)
# ============================================================

set -uo pipefail

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
SCAN_TIMEOUT=20  # seconds per screen capture attempt

# Device detection: physical iPhone vs simulator
DEVICE_TYPE="${DEVICE_TYPE:-auto}"
DEVICE_UDID="${DEVICE_UDID:-}"
DEVICE_NAME="${DEVICE_NAME:-}"

# Auto-detect device if not specified
if [ "$DEVICE_TYPE" = "auto" ] || [ -z "$DEVICE_UDID" ]; then
  # Try physical device first
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

# Auto-detect Expo dev server URL if not set
if [ "$APP_MODE" = "expo-go" ] && [ -z "$EXPO_DEV_URL" ]; then
  LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
  if [ -n "$LOCAL_IP" ] && lsof -i :8081 -t > /dev/null 2>&1; then
    EXPO_DEV_URL="exp://${LOCAL_IP}:8081"
    log "Auto-detected Expo dev server: $EXPO_DEV_URL"
  fi
fi

mkdir -p "$DISCOVERY_DIR" "$SCREENSHOTS_DIR" "$TEMP_DIR"

# --- Logging ---
log() {
  echo "[scanner][$(date '+%H:%M:%S')] $1"
}

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
  mkdir -p "$TEMP_DIR"  # recreate empty for next time
}
trap cleanup EXIT

# --- Write a mini Maestro YAML (no launchApp) ---
write_mini_yaml() {
  local name="$1"
  local content="$2"
  local yaml_path="$TEMP_DIR/${name}.yaml"

  local effective_app_id="$APP_ID"
  if [ "$APP_MODE" = "expo-go" ]; then
    effective_app_id="host.exp.Exponent"
  fi

  cat > "$yaml_path" << EOF
appId: ${effective_app_id}
---
$content
EOF
  echo "$yaml_path"
}

# --- Write a launch YAML (only used once at start) ---
write_launch_yaml() {
  local yaml_path="$TEMP_DIR/_launch.yaml"

  if [ "$APP_MODE" = "expo-go" ] && [ -n "$EXPO_DEV_URL" ]; then
    # Expo Go: open the dev server URL which loads the app inside Expo Go
    cat > "$yaml_path" << EOF
appId: host.exp.Exponent
---
- launchApp:
    clearState: false
- openLink: ${EXPO_DEV_URL}
- waitForAnimationToEnd
- extendedWaitUntil:
    visible: .*
    timeout: 15000
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

# --- Capture hierarchy for current screen ---
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

  # Retry once after a short wait
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

# --- Take a screenshot ---
capture_screenshot() {
  local screen_name="$1"
  local filename="${SCAN_ID}_${screen_name}.png"
  local filepath="$SCREENSHOTS_DIR/$filename"

  if [ "$DEVICE_TYPE" = "physical" ] && [ -n "$DEVICE_UDID" ]; then
    # Physical device: use Maestro takeScreenshot via mini flow
    local ss_yaml="$TEMP_DIR/_screenshot.yaml"
    cat > "$ss_yaml" << SSEOF
appId: ${APP_ID}
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
    # Simulator screenshot
    if xcrun simctl io booted screenshot "$filepath" 2>/dev/null; then
      echo "$filename"
      return 0
    fi
  fi
  echo ""
  return 1
}

# --- Parse hierarchy XML to JSON ---
parse_elements() {
  local xml_file="$1"
  if [ -f "$xml_file" ] && [ -s "$xml_file" ]; then
    python3 "$PARSER" "$xml_file" 2>/dev/null
  else
    echo '{"totalElements":0,"textElements":[],"testIds":[],"buttons":[],"inputFields":[]}'
  fi
}

# --- Run a mini YAML flow (returns 0 on success) ---
run_mini_flow() {
  local yaml_path="$1"
  # shellcheck disable=SC2086
  timeout "$SCAN_TIMEOUT" maestro $MAESTRO_DEVICE_FLAG test "$yaml_path" > /dev/null 2>&1
  return $?
}

# --- Extract tappable drawer items from hierarchy XML ---
extract_drawer_items() {
  local xml_file="$1"
  # Use Python for reliable XML parsing of drawer items
  python3 -c "
import xml.etree.ElementTree as ET
import json, sys

try:
    tree = ET.parse('$xml_file')
except:
    print('[]')
    sys.exit(0)

root = tree.getroot()
items = []
seen = set()

def walk(node):
    text = (node.get('text') or node.get('accessibilityText') or '').strip()
    clickable = node.get('clickable', 'false').lower() == 'true'
    node_class = (node.get('class') or node.get('type') or node.tag or '').lower()

    # Look for drawer menu items: clickable text that looks like a nav label
    # Skip very short or very long text, and common non-nav items
    skip_words = ['close', 'back', 'menu', 'settings', 'x', 'cancel', 'ok', 'done']
    if text and len(text) > 1 and len(text) < 50 and text.lower() not in skip_words:
        if clickable or 'touchable' in node_class or 'pressable' in node_class or 'button' in node_class:
            if text not in seen:
                seen.add(text)
                items.append(text)

    for child in node:
        walk(child)

walk(root)
print(json.dumps(items))
" 2>/dev/null || echo "[]"
}

# ============================================================
# MAIN SCAN FLOW
# ============================================================

log "======================================================"
log "  HikeWise Discovery Scanner"
log "  Scan ID: $SCAN_ID"
log "  App ID:  $APP_ID"
log "  Device:  $DEVICE_TYPE ($DEVICE_NAME)"
log "  UDID:    ${DEVICE_UDID:-N/A (simulator)}"
log "======================================================"

# Initialize report structure
SCREENS_JSON="[]"
DRAWER_ITEMS_JSON="[]"
TOTAL_SCREENS=0
SUCCESSFUL=0
FAILED=0

# --- Step 1: Launch the app ---
log "Step 1: Launching app..."
progress 0 1 "Launching app" "starting"

LAUNCH_YAML=$(write_launch_yaml)
if ! run_mini_flow "$LAUNCH_YAML"; then
  log "WARNING: Launch flow failed, app may already be running. Continuing..."
fi
sleep 2

# --- Step 2: Capture home screen ---
log "Step 2: Capturing home screen..."
progress 1 3 "Home screen" "scanning"

HOME_HIERARCHY=$(capture_hierarchy "home")
HOME_SCREENSHOT=$(capture_screenshot "home")
HOME_ELEMENTS=""

if [ -n "$HOME_HIERARCHY" ]; then
  HOME_ELEMENTS=$(parse_elements "$HOME_HIERARCHY")
  log "  Home: captured ($(echo "$HOME_ELEMENTS" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalElements",0))' 2>/dev/null || echo '?') elements)"
  SUCCESSFUL=$((SUCCESSFUL + 1))
else
  log "  Home: FAILED to capture hierarchy"
  HOME_ELEMENTS='{"totalElements":0,"textElements":[],"testIds":[],"buttons":[],"inputFields":[]}'
  FAILED=$((FAILED + 1))
fi
TOTAL_SCREENS=$((TOTAL_SCREENS + 1))

# Build home screen JSON entry
HOME_STATUS="success"
[ -z "$HOME_HIERARCHY" ] && HOME_STATUS="failed"
HOME_SCREEN_JSON=$(python3 -c "
import json, sys
elements = json.loads('''$HOME_ELEMENTS''')
print(json.dumps({
    'name': 'Home',
    'navigatedVia': 'launch',
    'hierarchyFile': '${HOME_HIERARCHY}',
    'screenshotUrl': '/screenshots/${HOME_SCREENSHOT}',
    'elements': elements,
    'status': '${HOME_STATUS}',
    'capturedAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}))
" 2>/dev/null)
SCREENS_JSON=$(echo "$SCREENS_JSON" | python3 -c "
import json, sys
screens = json.load(sys.stdin)
screens.append(json.loads('''$HOME_SCREEN_JSON'''))
print(json.dumps(screens))
" 2>/dev/null)

# --- Step 3: Open drawer and discover menu items ---
log "Step 3: Opening drawer to discover menu items..."
progress 2 3 "Discovering drawer items" "scanning"

# Strategy 1: Tap top-right corner (where menu icon typically is)
DRAWER_YAML=$(write_mini_yaml "open_drawer" "- tapOn:
    point: \"92%,6%\"
- waitForAnimationToEnd")

if run_mini_flow "$DRAWER_YAML"; then
  log "  Drawer opened via top-right tap"
else
  log "  Top-right tap failed, trying alternative strategies..."
  # Strategy 2: Try common drawer button selectors
  DRAWER_YAML2=$(write_mini_yaml "open_drawer2" "- tapOn:
    id: \"menu-button\"
    optional: true
- tapOn:
    id: \"drawer-toggle\"
    optional: true
- tapOn:
    text: \"Menu\"
    optional: true
- waitForAnimationToEnd")
  run_mini_flow "$DRAWER_YAML2" || log "  Alternative drawer strategies also failed"
fi

sleep 1

# Capture drawer hierarchy to discover items
DRAWER_HIERARCHY=$(capture_hierarchy "drawer")
DRAWER_SCREENSHOT=$(capture_screenshot "drawer")

if [ -n "$DRAWER_HIERARCHY" ]; then
  DRAWER_ITEMS_JSON=$(extract_drawer_items "$DRAWER_HIERARCHY")
  DRAWER_COUNT=$(echo "$DRAWER_ITEMS_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
  log "  Discovered $DRAWER_COUNT drawer items: $DRAWER_ITEMS_JSON"
else
  log "  WARNING: Could not capture drawer hierarchy"
  DRAWER_ITEMS_JSON="[]"
  DRAWER_COUNT=0
fi

# --- Step 4: Navigate to each discovered screen ---
log "Step 4: Scanning discovered screens..."

# Close drawer first by tapping outside or pressing back
CLOSE_YAML=$(write_mini_yaml "close_drawer" "- pressKey: back
- waitForAnimationToEnd")
run_mini_flow "$CLOSE_YAML" || true
sleep 1

# Parse drawer items into array
ITEM_COUNT=$(echo "$DRAWER_ITEMS_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
TOTAL_STEPS=$((ITEM_COUNT + 3))  # +3 for launch, home, drawer capture

for i in $(seq 0 $((ITEM_COUNT - 1))); do
  ITEM_NAME=$(echo "$DRAWER_ITEMS_JSON" | python3 -c "import json,sys; items=json.load(sys.stdin); print(items[$i])" 2>/dev/null)

  if [ -z "$ITEM_NAME" ]; then
    continue
  fi

  # Sanitize screen name for filenames
  SAFE_NAME=$(echo "$ITEM_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')

  STEP=$((i + 3))
  log "  [$((i+1))/$ITEM_COUNT] Navigating to: $ITEM_NAME"
  progress "$STEP" "$TOTAL_STEPS" "$ITEM_NAME" "scanning"

  # Open drawer
  OPEN_YAML=$(write_mini_yaml "nav_open_${SAFE_NAME}" "- tapOn:
    point: \"92%,6%\"
- waitForAnimationToEnd")
  run_mini_flow "$OPEN_YAML" || true
  sleep 1

  # Tap the menu item
  NAV_YAML=$(write_mini_yaml "nav_tap_${SAFE_NAME}" "- tapOn:
    text: \"${ITEM_NAME}\"
- waitForAnimationToEnd")

  SCREEN_STATUS="failed"
  SCREEN_HIERARCHY=""
  SCREEN_SCREENSHOT=""
  SCREEN_ELEMENTS='{"totalElements":0,"textElements":[],"testIds":[],"buttons":[],"inputFields":[]}'

  if run_mini_flow "$NAV_YAML"; then
    sleep 1

    # Capture this screen
    SCREEN_HIERARCHY=$(capture_hierarchy "$SAFE_NAME")
    SCREEN_SCREENSHOT=$(capture_screenshot "$SAFE_NAME")

    if [ -n "$SCREEN_HIERARCHY" ]; then
      SCREEN_ELEMENTS=$(parse_elements "$SCREEN_HIERARCHY")
      ELEM_COUNT=$(echo "$SCREEN_ELEMENTS" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalElements",0))' 2>/dev/null || echo '?')
      log "    Captured: $ELEM_COUNT elements"
      SCREEN_STATUS="success"
      SUCCESSFUL=$((SUCCESSFUL + 1))
    else
      log "    FAILED: hierarchy capture"
      FAILED=$((FAILED + 1))
    fi
  else
    log "    FAILED: navigation tap"
    FAILED=$((FAILED + 1))
  fi

  TOTAL_SCREENS=$((TOTAL_SCREENS + 1))

  # Add screen to report
  SCREEN_JSON=$(python3 -c "
import json
elements = json.loads('''$(echo "$SCREEN_ELEMENTS" | sed "s/'/\\\\'/g")''')
print(json.dumps({
    'name': '$ITEM_NAME',
    'navigatedVia': 'drawer',
    'hierarchyFile': '$SCREEN_HIERARCHY',
    'screenshotUrl': '/screenshots/$SCREEN_SCREENSHOT',
    'elements': elements,
    'status': '$SCREEN_STATUS',
    'capturedAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}))
" 2>/dev/null || echo '{}')

  if [ "$SCREEN_JSON" != "{}" ]; then
    SCREENS_JSON=$(echo "$SCREENS_JSON" | python3 -c "
import json, sys
screens = json.load(sys.stdin)
new_screen = json.loads('''$(echo "$SCREEN_JSON" | sed "s/'/\\\\'/g")''')
screens.append(new_screen)
print(json.dumps(screens))
" 2>/dev/null || echo "$SCREENS_JSON")
  fi
done

# --- Step 5: Compile discovery report ---
log "Step 5: Compiling discovery report..."
progress "$TOTAL_STEPS" "$TOTAL_STEPS" "Compiling report" "compiling"

# Compute totals from all screens
TOTAL_TEST_IDS=$(echo "$SCREENS_JSON" | python3 -c "
import json, sys
screens = json.load(sys.stdin)
ids = set()
for s in screens:
    for tid in s.get('elements', {}).get('testIds', []):
        ids.add(tid)
print(len(ids))
" 2>/dev/null || echo "0")

TOTAL_TEXT_LABELS=$(echo "$SCREENS_JSON" | python3 -c "
import json, sys
screens = json.load(sys.stdin)
labels = set()
for s in screens:
    for t in s.get('elements', {}).get('textElements', []):
        labels.add(t)
print(len(labels))
" 2>/dev/null || echo "0")

TOTAL_ELEMENTS=$(echo "$SCREENS_JSON" | python3 -c "
import json, sys
screens = json.load(sys.stdin)
total = sum(s.get('elements', {}).get('totalElements', 0) for s in screens)
print(total)
" 2>/dev/null || echo "0")

REPORT_FILE="$DISCOVERY_DIR/${SCAN_ID}_report.json"

python3 -c "
import json

screens = json.loads('''$(echo "$SCREENS_JSON" | sed "s/'/\\\\'/g")''')
drawer_items = json.loads('''$DRAWER_ITEMS_JSON''')

report = {
    'scanId': '$SCAN_ID',
    'appId': '$APP_ID',
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'discoveredDrawerItems': drawer_items,
    'screens': screens,
    'summary': {
        'totalScreens': $TOTAL_SCREENS,
        'successfulCaptures': $SUCCESSFUL,
        'failedCaptures': $FAILED,
        'totalTestIds': $TOTAL_TEST_IDS,
        'totalTextLabels': $TOTAL_TEXT_LABELS,
        'totalElements': $TOTAL_ELEMENTS
    }
}

with open('$REPORT_FILE', 'w') as f:
    json.dump(report, f, indent=2)

print(json.dumps(report, indent=2))
" 2>/dev/null

log ""
log "======================================================"
log "  Scan Complete!"
log "  Screens: $TOTAL_SCREENS ($SUCCESSFUL ok, $FAILED failed)"
log "  TestIDs: $TOTAL_TEST_IDS"
log "  Text Labels: $TOTAL_TEXT_LABELS"
log "  Report: $REPORT_FILE"
log "======================================================"

# Notify dashboard that scan is complete
progress "$TOTAL_STEPS" "$TOTAL_STEPS" "Complete" "complete"

exit 0
