#!/bin/zsh
############################################################################
#
# report-ui.zsh  —  swiftDialog wrapper for report.sh
#
# Presents a progress dialog while report.sh generates the HTML report,
# then offers the user the choice to open it immediately or reveal it in
# Finder for sharing/exporting later.
#
# Tier 3: command-file driven live progress (demos 06, 12, 14)
# Runs as: the logged-in user (no root required)
#
# Usage:
#   ./report-ui.zsh [report.sh options]
#
# Any arguments passed to report-ui.zsh are forwarded verbatim to report.sh
# (e.g. --profile prod --track-history --history-file /path/to/file.json).
# The -o / --output flag is managed by this wrapper; do not pass it yourself.
#
############################################################################

# --- Constants -----------------------------------------------------------
DIALOG="/usr/local/bin/dialog"
SCRIPT_DIR="${0:A:h}"
REPORT_SH="$SCRIPT_DIR/report.sh"
# OUTPUT_FILE is chosen by the user via a save panel below.

DIALOG_TITLE="Jamf Pro Report"
DIALOG_ICON="SF=doc.text.magnifyingglass,palette=white,#004165"

# Step count depends on whether --cleanup was requested (adds one extra step)
if [[ " $* " == *" --cleanup "* ]] || [[ " $* " == *" -c "* ]]; then
    PROGRESS_STEPS=7   # 6 steps + fencepost
else
    PROGRESS_STEPS=6   # 5 steps + fencepost
fi
CMD_FILE=""
DIALOG_PID=""
REPORT_LOG=""
# --- Preflight -----------------------------------------------------------
if [[ ! -x "$DIALOG" ]]; then
    osascript -e 'display alert "swiftDialog not found" message "Install swiftDialog before running this wrapper.\nhttps://github.com/swiftDialog/swiftDialog/releases" as critical buttons {"OK"} default button "OK"'
    exit 1
fi

if [[ ! -x "$REPORT_SH" ]]; then
    osascript -e "display alert \"report.sh not found\" message \"Expected it at: $REPORT_SH\" as critical buttons {\"OK\"} default button \"OK\""
    exit 1
fi

for _tool in jamf-cli jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        "$DIALOG" \
            --title         "$DIALOG_TITLE" \
            --message       "**Missing required tool: \`$_tool\`**\n\nInstall it with:\n\`\`\`\nbrew install Jamf-Concepts/tap/jamf-cli jq\n\`\`\`" \
            --icon          "SF=exclamationmark.triangle,palette=white,#ef4444" \
            --button1text   "OK" \
            --moveable \
            --width         650 \
            --height        410 \
            2>/dev/null || true
        exit 1
    fi
done

# --- Jamf-CLI Setup Check -----------------------------------------------
# Uses 'pro auth token' (v1.9+) to verify the profile is valid and
# the OAuth2 token can be obtained. Falls back to config validate on older builds.
_jamfcli_configured() {
    [[ -f "${HOME}/.config/jamf-cli/config.yaml" ]] || return 1
    if jamf-cli pro auth token --no-color --quiet 2>/dev/null | grep -qE '^[A-Za-z0-9._-]{20}'; then
        return 0
    fi
    # Fallback: config validate (pre-v1.9)
    jamf-cli config validate --no-color 2>/dev/null | grep -q 'All checks passed'
}

if ! _jamfcli_configured; then
    # Collect URL and profile name with a Tier-2 swiftDialog form.
    # Credentials are intentionally NOT collected here — jamf-cli pro setup
    # reads them interactively from the Terminal for security.
    _SETUP_JSON=$("$DIALOG" \
        --title         "$DIALOG_TITLE" \
        --message       "**jamf-cli is not configured yet.**\n\nEnter your Jamf Pro URL below. A Terminal window will open where you can enter your **local Jamf Pro admin** username and password to complete setup.\n\nYour credentials are only used to create OAuth2 client credentials — they are **not** stored by this script." \
        --icon          "SF=person.badge.key,palette=white,#004165" \
        --textfield     "Jamf Pro URL,prompt=https://yourinstance.jamfcloud.com,required" \
        --textfield     "Profile Name,value=default" \
        --button1text   "Open Terminal to Set Up" \
        --button2text   "Cancel" \
        --moveable \
        --width         650 \
        --height        410 \
        --json \
        2>/dev/null)

    _SETUP_EXIT=$?
    [[ $_SETUP_EXIT -ne 0 ]] && exit 0   # user cancelled

    _SETUP_URL=$(printf '%s' "$_SETUP_JSON" | jq -r '."Jamf Pro URL" // ""' 2>/dev/null)
    _SETUP_PROFILE=$(printf '%s' "$_SETUP_JSON" | jq -r '."Profile Name" // "default"' 2>/dev/null)
    [[ -z "$_SETUP_PROFILE" ]] && _SETUP_PROFILE="default"

    if [[ -z "$_SETUP_URL" ]]; then
        "$DIALOG" \
            --title         "$DIALOG_TITLE" \
            --message       "A Jamf Pro URL is required." \
            --icon          "SF=exclamationmark.triangle,palette=white,#ef4444" \
            --button1text   "OK" \
            --moveable \
            --width         650 \
            --height        410 \
            2>/dev/null || true
        exit 1
    fi

    # Open Terminal.app running the setup command. Credentials stay in the
    # terminal — they never pass through this script.
    _SETUP_CMD="jamf-cli pro setup --url '${_SETUP_URL}' --profile-name '${_SETUP_PROFILE}' && echo '' && echo '✓ Setup complete. Return to the Jamf Pro Report window and click Continue.' || echo '✗ Setup failed — check the URL and credentials, then try again.'; echo ''; read -rsk1 'Press any key to continue…'"
    osascript 2>/dev/null <<OSASCRIPT
tell application "Terminal"
    activate
    do script "${_SETUP_CMD}"
end tell
OSASCRIPT

    # Waiting dialog — user returns here after completing Terminal setup.
    "$DIALOG" \
        --title         "$DIALOG_TITLE" \
        --message       "**Complete setup in the Terminal window that just opened.**\n\nEnter your Jamf Pro **admin username** and **password** when prompted.\n\n- Credentials are only used to create OAuth2 client credentials\n- They are **not** stored anywhere\n- The profile **${_SETUP_PROFILE}** will be saved for future use\n\nClick **Continue** once the Terminal shows ✓ Setup complete." \
        --icon          "SF=terminal,palette=white,#1d6fa4" \
        --button1text   "Continue" \
        --button2text   "Cancel" \
        --moveable \
        --width         650 \
        --height        410 \
        --ontop \
        2>/dev/null
    [[ $? -ne 0 ]] && exit 0   # user cancelled

    # Re-validate — fail clearly if setup didn't complete.
    if ! _jamfcli_configured; then
        "$DIALOG" \
            --title         "$DIALOG_TITLE" \
            --message       "**Setup could not be verified.**\n\nRun the following in Terminal to check the status:\n\`\`\`\njamf-cli config validate\n\`\`\`\nThen relaunch this app." \
            --icon          "SF=exclamationmark.triangle.fill,palette=white,#ef4444" \
            --button1text   "Close" \
            --moveable \
            --width         650 \
            --height        410 \
            2>/dev/null || true
        exit 1
    fi
fi

# --- Cleanup -------------------------------------------------------------
cleanup() {
    [[ -n "$CMD_FILE"   ]] && rm -f "$CMD_FILE"
    [[ -n "$REPORT_LOG" ]] && rm -f "$REPORT_LOG"
}
trap cleanup EXIT

# --- Temp files ----------------------------------------------------------
CMD_FILE=$(mktemp -t dialog.XXXXXX)
REPORT_LOG=$(mktemp -t report-log.XXXXXX)

# --- Step 0: Ask the user where to save the report ----------------------
_DEFAULT_NAME="jamf-report-$(date '+%Y%m%d-%H%M%S').html"
OUTPUT_FILE=$(osascript <<APPLESCRIPT 2>/dev/null
set defaultName to "$_DEFAULT_NAME"
set savePath to choose file name \
    with prompt "Where do you want to save the Jamf Pro report?" \
    default name defaultName
return POSIX path of savePath
APPLESCRIPT
)

if [[ -z "$OUTPUT_FILE" ]]; then
    exit 0   # user cancelled the save panel
fi

# Ensure .html extension
[[ "$OUTPUT_FILE" != *.html ]] && OUTPUT_FILE="${OUTPUT_FILE}.html"

# --- Helper: send command to the live dialog -----------------------------
send() { echo "$1" >> "$CMD_FILE"; }

# --- Step 1: Confirmation dialog -----------------------------------------
"$DIALOG" \
    --title         "$DIALOG_TITLE" \
    --message       "This will connect to your Jamf Pro instance and generate a comprehensive HTML report.\n\nThe report will be saved to:\n**$OUTPUT_FILE**\n\nThe report includes security posture, OS distribution, deployment hierarchy, flagged devices, and more.\n\n**Ready to start?**" \
    --icon          "$DIALOG_ICON" \
    --button1text   "Generate Report" \
    --button2text   "Cancel" \
    --moveable \
    --width         650 \
    --height        410 \
    --ontop \
    2>/dev/null || exit 0

# --- Step 2: Launch progress dialog in the background -------------------
"$DIALOG" \
    --title          "$DIALOG_TITLE" \
    --message        "Connecting to Jamf Pro…" \
    --icon           "$DIALOG_ICON" \
    --progress       "$PROGRESS_STEPS" \
    --progresstext   "Starting…" \
    --commandfile    "$CMD_FILE" \
    --button1text    "Please wait…" \
    --button1disabled \
    --moveable \
    --width         650 \
    --height        410 \
    --ontop \
    2>/dev/null &

DIALOG_PID=$!
sleep 0.8   # Give swiftDialog time to render before first update

# --- Step 3: Run report.sh in background, streaming output to log -------
# Forward all user-provided args, always pass --no-open (we handle opening)
# and always set -o to our managed output path.
bash "$REPORT_SH" --no-open -o "$OUTPUT_FILE" "$@" >"$REPORT_LOG" 2>&1 &
REPORT_PID=$!

# --- Step 4: Monitor report.sh output and advance the progress bar ------
# report.sh prints "[N/6] Step name" for each step.
# We watch for those lines and update the dialog accordingly.
declare -A _seen
_seen=()

_advance() {
    local _step_num="$1" _label="$2"
    send "progress: $_step_num"
    send "progresstext: Step $_step_num/$PROGRESS_STEPS — $_label"
    send "message: $_label"
}

# Update only the progress text (no bar movement) — used for substeps
_substep() { send "progresstext: $1"; }

# Poll the log file by line-count so we never block on tail -f.
# Each iteration reads only newly appended lines since the last check.
_log_offset=0
_process_line() {
    local _line="$1"
    # Extract step number from "[N/M] …" output — works regardless of total step count
    local _sn
    _sn=$(printf '%s' "$_line" | sed -n 's/.*\[\([0-9]*\)\/[0-9]*\].*/\1/p')
    case "$_line" in
        *"Fetching data from Jamf Pro"*)
            [[ -z "${_seen[fetch]:-}" ]] && { _advance "${_sn:-1}" "Fetching data from Jamf Pro"; _seen[fetch]=1; } ;;
        *"Batch 1/2"*)
            _substep "Batch 1/2 — overview & security…" ;;
        *"Batch 2/2"*)
            _substep "Batch 2/2 — inventory & organisation…" ;;
        *"Processing data"*)
            [[ -z "${_seen[proc]:-}" ]] && { _advance "${_sn:-2}" "Processing data"; _seen[proc]=1; } ;;
        *"Building deployment hierarchy"*)
            [[ -z "${_seen[hier]:-}" ]] && { _advance "${_sn:-3}" "Building deployment hierarchy"; _seen[hier]=1; } ;;
        *"Cleanup analysis"*)
            [[ -z "${_seen[cu]:-}" ]] && { _advance "${_sn:-4}" "Cleanup analysis"; _seen[cu]=1; } ;;
        *"Fetching "*"policy details"*)
            _substep "Fetching policy details…" ;;
        *"Fetching "*"macOS profile"*)
            _substep "Fetching macOS profile details…" ;;
        *"Cross-referencing packages"*)
            _substep "Cross-referencing packages and scripts…" ;;
        *"item(s) flagged"*)
            _substep "Analysing cleanup results…" ;;
        *"Patch compliance:"*)
            _substep "Processing patch compliance data…" ;;
        *"Profile status:"*)
            _substep "Processing MDM profile failure data…" ;;
        *"Device compliance:"*)
            _substep "Processing device check-in compliance…" ;;
        *"App status:"*)
            _substep "Processing MDM app failure data…" ;;
        *"Update status:"*)
            _substep "Processing managed software update plan data…" ;;
        *"Generating HTML"*)
            [[ -z "${_seen[html]:-}" ]] && { _advance "${_sn:-5}" "Generating HTML report"; _seen[html]=1; } ;;
        *"Report complete"*)
            [[ -z "${_seen[done]:-}" ]] && { _advance "${_sn:-6}" "Finalising report"; _seen[done]=1; } ;;
    esac
}

while kill -0 "$REPORT_PID" 2>/dev/null; do
    _cur_lines=$(wc -l < "$REPORT_LOG" 2>/dev/null | tr -d ' ')
    if (( _cur_lines > _log_offset )); then
        while IFS= read -r _line; do
            _process_line "$_line"
        done < <(sed -n "$((_log_offset + 1)),${_cur_lines}p" "$REPORT_LOG" 2>/dev/null)
        _log_offset=$_cur_lines
    fi
    sleep 0.5
done

# Final flush — read any lines written after the last poll interval
_cur_lines=$(wc -l < "$REPORT_LOG" 2>/dev/null | tr -d ' ')
if (( _cur_lines > _log_offset )); then
    while IFS= read -r _line; do
        _process_line "$_line"
    done < <(sed -n "$((_log_offset + 1)),${_cur_lines}p" "$REPORT_LOG" 2>/dev/null)
fi

# report.sh has exited — capture its exit code
wait "$REPORT_PID"
REPORT_EXIT=$?

# --- Step 5: Handle report failure --------------------------------------
if [[ "$REPORT_EXIT" -ne 0 ]] || [[ ! -f "$OUTPUT_FILE" ]]; then
    send "progress: complete"
    send "progresstext: Report generation failed"
    send "message: An error occurred while generating the report."
    send "button1text: Close"
    send "button1: enable"
    wait "$DIALOG_PID" 2>/dev/null || true

    "$DIALOG" \
        --title       "$DIALOG_TITLE" \
        --message     "**The report could not be generated.**\n\nCheck that \`jamf-cli\` is authenticated and your Jamf Pro instance is reachable.\n\nExit code: $REPORT_EXIT" \
        --icon        "SF=exclamationmark.triangle.fill,palette=white,#ef4444" \
        --button1text "Close" \
        --moveable \
        --width         650 \
        --height        410 \
        2>/dev/null || true
    exit 1
fi

# --- Step 6: Report ready — update dialog to completion state -----------
send "progress: $PROGRESS_STEPS"
send "progresstext: Report ready"
send "message: Your Jamf Pro report has been saved to:\n**$(basename "$OUTPUT_FILE")**"
send "button1text: Open Report"
send "button1: enable"
send "button2text: Show in Finder"

# Wait for user to dismiss the progress dialog (they click "Open Report")
wait "$DIALOG_PID" 2>/dev/null
PROG_EXIT=$?

# PROG_EXIT: 0 = button1 (Open Report), 2 = button2 (Show in Finder)
if [[ "$PROG_EXIT" -eq 2 ]]; then
    # Reveal in Finder without opening
    open -R "$OUTPUT_FILE"
else
    # Open in default browser (button1, or any other exit)
    open "$OUTPUT_FILE"
fi

# --- Step 7: Done notification ------------------------------------------
"$DIALOG" \
    --title         "$DIALOG_TITLE" \
    --message       "**Report saved successfully.**\n\nSaved to:\n$OUTPUT_FILE" \
    --icon          "SF=checkmark.circle.fill,palette=white,#22c55e" \
    --button1text   "Done" \
    --moveable \
    --width         650 \
    --height        410 \
    2>/dev/null || true
