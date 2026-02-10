#!/bin/bash
# ============================================================
# Maestro Flow Generator for Expo Router Apps
# Scans your /app directory and generates basic test flows
# for every screen it finds
# ============================================================

REPO_PATH="${1:-$HOME/hikewise}"
APP_DIR="$REPO_PATH/app"
OUTPUT_DIR="${2:-$HOME/hikewise-agent-system/maestro/flows}"
APP_ID="${3:-com.hikewise.app}"

if [ ! -d "$APP_DIR" ]; then
  echo "❌ App directory not found: $APP_DIR"
  echo "Usage: $0 /path/to/hikewise [output-dir] [app-bundle-id]"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "🏔️  Scanning Expo Router screens in: $APP_DIR"
echo "   Output: $OUTPUT_DIR"
echo ""

# Find all screen files (tsx/jsx in /app)
SCREEN_COUNT=0

generate_flow() {
  local file="$1"
  local relative="${file#$APP_DIR/}"
  local screen_name=$(echo "$relative" | sed 's/\.\(tsx\|jsx\|ts\|js\)$//' | tr '/' '-' | tr '()[]' '____')
  
  # Skip layout files, they're not screens
  if [[ "$relative" == *"_layout"* ]]; then
    return
  fi
  
  # Skip index in group directories (these are usually tab defaults)
  local clean_name=$(echo "$screen_name" | sed 's/^__[^-]*__-//')
  
  local flow_file="$OUTPUT_DIR/auto-screen-${clean_name}.yaml"
  
  # Extract testIDs from the file if they exist
  local test_ids=$(grep -oP 'testID[=:]\s*["'"'"']\K[^"'"'"']+' "$file" 2>/dev/null || true)
  
  cat > "$flow_file" << EOF
# Auto-generated flow for: $relative
# Review and customize this flow for your specific needs
appId: $APP_ID
---
- launchApp:
    clearState: false

# TODO: Add navigation steps to reach this screen
# Example: - tapOn: { id: "tab-name" }

# Verify screen loads
- assertVisible:
    id: "${clean_name}-screen"
    optional: true
EOF

  # Add assertions for found testIDs
  if [ -n "$test_ids" ]; then
    echo "" >> "$flow_file"
    echo "# Found testIDs in source:" >> "$flow_file"
    while IFS= read -r tid; do
      echo "- assertVisible:" >> "$flow_file"
      echo "    id: \"$tid\"" >> "$flow_file"
      echo "    optional: true" >> "$flow_file"
    done <<< "$test_ids"
  fi

  # Add back navigation test
  cat >> "$flow_file" << EOF

# Test back navigation
- pressKey: back
EOF

  echo "  ✓ Generated: auto-screen-${clean_name}.yaml"
  ((SCREEN_COUNT++))
}

# Recursively find all screen files
while IFS= read -r -d '' file; do
  generate_flow "$file"
done < <(find "$APP_DIR" -name "*.tsx" -o -name "*.jsx" | sort -z)

echo ""
echo "✅ Generated $SCREEN_COUNT screen test flows in $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. Review each generated flow and add navigation steps"
echo "  2. Update testIDs to match your actual component IDs"
echo "  3. Run: maestro test $OUTPUT_DIR/"
echo "  4. Use 'maestro studio' to interactively discover element IDs"
echo ""
echo "Tip: Run 'maestro studio' with your app running on a simulator"
echo "     to visually inspect elements and auto-generate test commands."
