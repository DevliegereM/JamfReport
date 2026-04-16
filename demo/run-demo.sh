#!/bin/bash
# Generates a demo HTML report using fixture data in the demo/ directory.
# No real Jamf Pro connection is needed.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/Users/$(whoami)/Downloads/jamf-demo-report.html}"

export PATH="$DEMO_DIR:$PATH"

if [[ -f "$DEMO_DIR/icon.png" ]]; then
    export JAMF_REPORT_ICON_B64
    JAMF_REPORT_ICON_B64="$(base64 < "$DEMO_DIR/icon.png")"
fi

echo "  Demo jamf-cli : $DEMO_DIR/jamf-cli"
echo "  Output        : $OUT"
echo ""

bash "$SCRIPT_DIR/report.sh" --no-open -o "$OUT"
