#!/bin/bash
############################################################################
#
# Jamf Pro Instance Report Generator
#
# Generates a comprehensive, self-contained HTML report for a Jamf Pro
# instance using jamf-cli. Includes summary cards, security posture charts,
# OS distribution, organisational structure and a deployment hierarchy view.
#
# Requirements: jamf-cli (Jamf-Concepts/tap/jamf-cli), jq
#
# Usage: ./report.sh [-p profile] [-o output.html] [-n]
#
############################################################################

set -uo pipefail

SCRIPT_VERSION="1.0.0"

# ─── Defaults ────────────────────────────────────────────────────────────────
PROFILE=""
OUTPUT_FILE="jamf-report-$(date '+%Y%m%d-%H%M%S').html"
NO_OPEN=false
TRACK_HISTORY=false
HISTORY_FILE="${JAMF_REPORT_HISTORY_FILE:-$HOME/.jamf-report.history.json}"
RUN_CLEANUP=false
RUN_PATCH_STATUS=false
RUN_PROFILE_STATUS=false
PROFILE_STATUS_DAYS=30
RUN_APP_STATUS=false
APP_STATUS_DAYS=30
RUN_UPDATE_STATUS=false
RUN_DEVICE_COMPLIANCE=false
DEVICE_COMPLIANCE_DAYS=90

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Generate a comprehensive HTML report for a Jamf Pro instance using jamf-cli.

Options:
  -p, --profile <name>    jamf-cli profile to use (default: current profile)
  -o, --output  <file>    Output HTML file (default: jamf-report-TIMESTAMP.html)
  -n, --no-open           Do not auto-open the report after generation
  -t, --track-history     Save an OS-version snapshot for historical trend charts
      --history-file <f>  History file path (default: ~/.jamf-report.history.json)
                          Override with env var JAMF_REPORT_HISTORY_FILE
  -c, --cleanup           Run cleanup analysis: disabled/unscoped policies & profiles,
                          unused packages and scripts (one extra API call per object)
      --patch-status      Fetch patch title compliance data (adds Patch Compliance section)
      --profile-status    Fetch MDM InstallProfile failures (adds Profile Status section)
      --profile-days <n>  Look-back window for profile failures in days (default: 30)
      --app-status        Fetch MDM app deployment failures (adds App Status section)
      --app-days <n>      Look-back window for app failures in days (default: 30)
      --update-status     Fetch managed software update plan states (adds Update Status section)
      --device-compliance Fetch stale check-in report (adds Device Compliance section)
      --checkin-days <n>  Days without check-in to mark device stale (default: 90)
  -h, --help              Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --profile prod
  $(basename "$0") --profile prod --output /tmp/report.html --no-open
  $(basename "$0") --track-history          # opt-in to history tracking
  $(basename "$0") --cleanup                # opt-in to cleanup analysis

Requirements:
  brew install Jamf-Concepts/tap/jamf-cli jq
USAGE
}

# ─── Arguments ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile)     PROFILE="$2"; shift 2 ;;
        -o|--output)      OUTPUT_FILE="$2"; shift 2 ;;
        -n|--no-open)     NO_OPEN=true; shift ;;
        -t|--track-history) TRACK_HISTORY=true; shift ;;
        --history-file)   HISTORY_FILE="$2"; shift 2 ;;
        -c|--cleanup)     RUN_CLEANUP=true; shift ;;
        --patch-status)   RUN_PATCH_STATUS=true; shift ;;
        --profile-status) RUN_PROFILE_STATUS=true; shift ;;
        --profile-days)   PROFILE_STATUS_DAYS="$2"; shift 2 ;;
        --app-status)     RUN_APP_STATUS=true; shift ;;
        --app-days)       APP_STATUS_DAYS="$2"; shift 2 ;;
        --update-status)  RUN_UPDATE_STATUS=true; shift ;;
        --device-compliance) RUN_DEVICE_COMPLIANCE=true; shift ;;
        --checkin-days)   DEVICE_COMPLIANCE_DAYS="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ─── Prerequisites ────────────────────────────────────────────────────────────
missing_tools=()
for tool in jamf-cli jq; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing_tools[*]}" >&2
    echo "Install with: brew install Jamf-Concepts/tap/jamf-cli jq" >&2
    exit 1
fi

# ─── Build command prefix ────────────────────────────────────────────────────
JAMF="jamf-cli"
[[ -n "$PROFILE" ]] && JAMF="jamf-cli --profile $PROFILE"
JPRO="$JAMF pro"

# ─── Temp directory ──────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ─── Progress helper ─────────────────────────────────────────────────────────
STEP=0
[[ "$RUN_CLEANUP" == true ]] && STEPS=6 || STEPS=5
step() { STEP=$((STEP+1)); printf "\n  \033[1m[%d/%d]\033[0m %s\n" "$STEP" "$STEPS" "$1"; }

echo ""
echo "  Jamf Pro Instance Report  v${SCRIPT_VERSION}"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ -n "$PROFILE" ]] && echo "  Profile : $PROFILE"
echo "  Output  : $OUTPUT_FILE"
echo ""

# ─── Resilient parallel fetch ─────────────────────────────────────────────────
# _fetch LABEL OUTFILE COMMAND [ARGS…]
# Each fetch runs in a subshell: validates JSON, retries once after 3 s,
# writes a tab-separated status line to FETCH_STATUS for the summary.
FETCH_STATUS="$TMP/.fetch_status"
> "$FETCH_STATUS"

_fetch() {
    local _lbl="$1" _out="$2"; shift 2
    (
        _valid() {
            [[ -s "$_out" ]] \
                && jq -e 'type == "array" or (type == "object" and has("results"))' \
                       "$_out" >/dev/null 2>&1 \
                && ! jq -e 'has("error")' "$_out" >/dev/null 2>&1
        }
        local _retried=0
        for _attempt in 1 2; do
            "$@" > "$_out" 2>/dev/null
            _valid && break
            [[ $_attempt -eq 1 ]] && { _retried=1; sleep 3; }
        done
        if _valid; then
            local _cnt
            _cnt=$(jq 'if type=="array" then length else 1 end' "$_out" 2>/dev/null || echo "?")
            local _st; [[ $_retried -eq 1 ]] && _st="retry" || _st="ok"
            printf "%s\t%s\t%s\n" "$_st" "$_lbl" "$_cnt" >> "$FETCH_STATUS"
        else
            echo '[]' > "$_out"
            printf "fail\t%s\t0\n" "$_lbl" >> "$FETCH_STATUS"
        fi
    ) &
}

# ─── Data collection ────────────────────────────────────────────────────────
# Priority batch 1: overview + security run FIRST and alone so they are not
# rate-limited by the other 11 simultaneous requests.
step "Fetching data from Jamf Pro"
printf "  \033[90mBatch 1/2 — overview & security report…\033[0m\n"
_fetch "Overview"              "$TMP/overview.json"      $JPRO overview -o json
_fetch "Security Report"       "$TMP/security.json"      $JPRO report security -o json
wait

# Explicit re-validation for the security report: the summary section must
# be present. If it is missing (empty response / rate-limited), re-fetch
# synchronously with up to 2 additional attempts before continuing.
_sec_valid() {
    jq -e 'map(select(.section=="summary")) | length > 0' \
        "$TMP/security.json" >/dev/null 2>&1
}
if ! _sec_valid; then
    printf "  \033[33m↺  Security Report missing summary — re-fetching…\033[0m\n"
    for _retry in 1 2; do
        sleep $((_retry * 5))
        $JPRO report security -o json > "$TMP/security.json" 2>/dev/null || :
        if _sec_valid; then
            printf "  \033[32m✓  Security Report recovered (attempt %d)\033[0m\n" "$_retry"
            break
        fi
        printf "  \033[31m✗  Security Report attempt %d failed\033[0m\n" "$_retry"
    done
    _sec_valid || { printf '[]' > "$TMP/security.json"; }
fi

# Priority batch 2: everything else in parallel.
printf "  \033[90mBatch 2/2 — inventory & organisation…\033[0m\n"
_fetch "Policies"              "$TMP/policies.json"      $JPRO classic-policies list -o json
_fetch "macOS Config Profiles" "$TMP/macos_prof.json"    $JPRO classic-macos-config-profiles list -o json
_fetch "iOS Config Profiles"   "$TMP/ios_prof.json"      $JPRO classic-mobile-config-profiles list -o json
_fetch "Smart Groups"          "$TMP/smart_groups.json"  $JPRO smart-computer-groups list -o json
_fetch "Categories"            "$TMP/categories.json"    $JPRO categories list -o json
_fetch "Scripts"               "$TMP/scripts.json"       $JPRO scripts list -o json
_fetch "Packages"              "$TMP/packages.json"      $JPRO packages list -o json
_fetch "ADE Instances"         "$TMP/ade_instances.json" $JPRO device-enrollments list -o json
_fetch "Sites"                 "$TMP/sites.json"         $JPRO sites list -o json
_fetch "Buildings"             "$TMP/buildings.json"     $JPRO buildings list -o json
_fetch "Departments"           "$TMP/departments.json"   $JPRO departments list -o json
[[ "$RUN_PATCH_STATUS" == true ]] && \
    _fetch "Patch Status"      "$TMP/patch_status.json"       $JPRO report patch-status -q -o json
[[ "$RUN_PROFILE_STATUS" == true ]] && \
    _fetch "Profile Status"    "$TMP/profile_status.json"     $JPRO report profile-status -q --days "$PROFILE_STATUS_DAYS" -o json
[[ "$RUN_APP_STATUS" == true ]] && \
    _fetch "App Status"        "$TMP/app_status.json"         $JPRO report app-status -q --days "$APP_STATUS_DAYS" -o json
[[ "$RUN_UPDATE_STATUS" == true ]] && \
    _fetch "Update Status"     "$TMP/update_status.json"      $JPRO report update-status -q -o json
[[ "$RUN_DEVICE_COMPLIANCE" == true ]] && \
    _fetch "Device Compliance" "$TMP/device_compliance.json"  $JPRO report device-compliance -q --days-since-checkin "$DEVICE_COMPLIANCE_DAYS" -o json
wait

# ─── Print fetch results ───────────────────────────────────────────────────────
_nok=0; _nwarn=0; _nfail=0
while IFS=$'\t' read -r _st _lbl _cnt; do
    case "$_st" in
        ok)    printf "    \033[32m✓\033[0m  %-28s %s records\n"           "$_lbl" "$_cnt"; _nok=$((_nok+1))     ;;
        retry) printf "    \033[33m↺\033[0m  %-28s %s records (retried)\n" "$_lbl" "$_cnt"; _nwarn=$((_nwarn+1)) ;;
        fail)  printf "    \033[31m✗\033[0m  %-28s no data\n"              "$_lbl";         _nfail=$((_nfail+1)) ;;
    esac
done < "$FETCH_STATUS"
printf "\n  Collection: \033[32m%d ok\033[0m" "$_nok"
[[ $_nwarn -gt 0 ]] && printf ", \033[33m%d retried\033[0m" "$_nwarn"
[[ $_nfail -gt 0 ]] && printf ", \033[31m%d failed\033[0m" "$_nfail"
printf "\n"

step "Processing data"

# ─── Read collected data ──────────────────────────────────────────────────────
OV=$(cat "$TMP/overview.json")
SGR=$(cat "$TMP/smart_groups.json")
CAT=$(cat "$TMP/categories.json")
ADE_DETAIL=$(cat "$TMP/ade_instances.json")
SITES_DETAIL=$(cat "$TMP/sites.json")
BLDG_DETAIL=$(cat "$TMP/buildings.json")
DEPT_DETAIL=$(cat "$TMP/departments.json")
# Security, policies, profiles and scripts are read directly from files where needed
# (avoids pipe + pipefail interactions with large payloads)

# ─── Overview value extractor ────────────────────────────────────────────────
ov() {
    local val
    val=$(echo "$OV" | jq -r --arg r "$1" \
        'if type=="array" then .[] | select(.resource==$r) | .value else empty end' \
        2>/dev/null | head -1)
    [[ -z "$val" ]] && echo "N/A" || echo "$val"
}

# ─── Extract overview fields ──────────────────────────────────────────────────
INSTANCE_URL=$(ov "Server URL")
JAMF_VERSION=$(ov "Jamf Pro Version")
HEALTH_STATUS=$(ov "Health Status")
MANAGED_COMPUTERS=$(ov "Managed Computers")
UNMANAGED_COMPUTERS=$(ov "Unmanaged Computers")
MANAGED_DEVICES=$(ov "Managed Devices")
UNMANAGED_DEVICES=$(ov "Unmanaged Devices")
CHECKIN_FREQ=$(ov "Check-In Frequency")
POLICIES_COUNT=$(ov "Policies")
MACOS_PROF_COUNT=$(ov "macOS Config Profiles")
IOS_PROF_COUNT=$(ov "iOS Config Profiles")
PACKAGES_COUNT=$(ov "Packages")
SCRIPTS_COUNT=$(ov "Scripts")
COMP_SMART=$(ov "Computer Groups")
COMP_STATIC=$(ov "Computer Static Groups")
MD_SMART=$(ov "Mobile Device Smart Groups")
SITES_COUNT=$(ov "Sites")
BUILDINGS_COUNT=$(ov "Buildings")
DEPT_COUNT=$(ov "Departments")
CAT_COUNT=$(ov "Categories")
ACTIVE_ALERTS=$(ov "Active Alerts")
DEP_TOKEN_EXPIRES=$(ov "DEP Token Expires")
CA_EXPIRES=$(ov "Built-in CA Expires")
ADE_INSTANCES=$(ov "DEP Instances")
ADE_SYNC=$(ov "DEP Sync Status")
VPP_LOCATIONS=$(ov "VPP Locations")
COMP_PRESTAGES=$(ov "Computer Prestages")
MD_PRESTAGES=$(ov "Mobile Device Prestages")
APP_INSTALLERS=$(ov "App Installers")
WEBHOOKS=$(ov "Webhooks")
PATCH_TITLES=$(ov "Patch Titles")
JCDS_FILES=$(ov "JCDS Files")
EBOOKS=$(ov "eBooks")
MDM_RENEW_COMP=$(ov "MDM Auto Renew (Computers)")
MDM_RENEW_MD=$(ov "MDM Auto Renew (Mobile)")
LDAP_SERVERS=$(ov "LDAP/IdP Servers")

# ─── Jamf Pro console base URL (strip trailing slash) ────────────────────────
CONSOLE_URL="${INSTANCE_URL%/}"

# ─── Security summary ───────────────────────────────────────────────────────
# Read directly from the file to avoid pipe + pipefail interactions when
# the security JSON was empty or invalid.
sec() {
    local _v
    _v=$(jq -r --arg k "$1" \
        '.[] | select(.section=="summary") | .data[$k]' \
        "$TMP/security.json" 2>/dev/null | head -1)
    [[ -z "${_v:-}" || "$_v" == 'null' ]] && echo "N/A" || echo "$_v"
}

FV_PCT=$(sec "filevault_encrypted_pct")
GK_PCT=$(sec "gatekeeper_enabled_pct")
SIP_PCT=$(sec "sip_enabled_pct")
FW_PCT=$(sec "firewall_enabled_pct")
TOTAL_SCANNED=$(sec "total_devices")
FV_COUNT=$(sec "filevault_encrypted")
GK_COUNT=$(sec "gatekeeper_enabled")
SIP_COUNT=$(sec "sip_enabled")
FW_COUNT=$(sec "firewall_enabled")

strip_pct() { echo "${1//%/}"; }
is_num()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

FV_VAL=$(strip_pct "$FV_PCT");  is_num "$FV_VAL"  || FV_VAL="0"
GK_VAL=$(strip_pct "$GK_PCT");  is_num "$GK_VAL"  || GK_VAL="0"
SIP_VAL=$(strip_pct "$SIP_PCT"); is_num "$SIP_VAL" || SIP_VAL="0"
FW_VAL=$(strip_pct "$FW_PCT");  is_num "$FW_VAL"  || FW_VAL="0"

# ─── Overall compliance score (average of the 4 security metrics, 0-100) ─────
COMPLIANCE_SCORE=$(awk "BEGIN{printf \"%d\", ($FV_VAL+$GK_VAL+$SIP_VAL+$FW_VAL)/4}")
COMPLIANCE_DASH=$(awk "BEGIN{printf \"%.1f\", ($COMPLIANCE_SCORE/100)*264}")
if   [[ "$COMPLIANCE_SCORE" -ge 90 ]]; then COMPLIANCE_COLOR='#22c55e'
elif [[ "$COMPLIANCE_SCORE" -ge 75 ]]; then COMPLIANCE_COLOR='#f59e0b'
else                                         COMPLIANCE_COLOR='#ef4444'
fi

# OS version data for donut chart
# Normalise: strip a trailing ".0" so "26.4.0" and "26.4" are treated as the
# same version, then group and sum their counts.
_OS_NORM='[.[] | select(.section=="os_version")
           | {v: (.os_version | gsub("\\.0$"; "")), c: .count}]
          | group_by(.v)
          | map({v: .[0].v, c: ([.[].c] | add)})
          | sort_by(.v) | reverse'
OS_DATA=$(jq -c "$_OS_NORM" "$TMP/security.json" 2>/dev/null || echo '[]')
OS_LABELS=$(echo "$OS_DATA" | jq -c 'map(.v)' 2>/dev/null || echo '[]')
OS_COUNTS=$(echo "$OS_DATA" | jq -c 'map(.c)' 2>/dev/null || echo '[]')

# ─── Patch compliance (opt-in via --patch-status) ────────────────────────────
PATCH_STATUS_JSON='[]'
PATCH_TITLES_COUNT=0
if [[ "$RUN_PATCH_STATUS" == true ]] && [[ -s "$TMP/patch_status.json" ]]; then
    _raw=$(jq -c 'if type=="array" then . else [] end' "$TMP/patch_status.json" 2>/dev/null || echo '[]')
    PATCH_STATUS_JSON="$_raw"
    PATCH_TITLES_COUNT=$(echo "$_raw" | jq 'length' 2>/dev/null || echo 0)
    printf "  \033[32m✓\033[0m  Patch compliance: %d titles loaded\n" "$PATCH_TITLES_COUNT"
fi

# ─── Profile status (opt-in via --profile-status) ────────────────────────────
PROFILE_STATUS_JSON='{"failures":[],"device_failures":[],"device_pending":[],"summary":{"days":30,"total_errors":0,"unique_devices":0,"unique_profiles":0}}'
if [[ "$RUN_PROFILE_STATUS" == true ]] && [[ -s "$TMP/profile_status.json" ]]; then
    _raw=$(jq -c 'if type=="array" then .[0] // {} else . end' "$TMP/profile_status.json" 2>/dev/null || echo '{}')
    PROFILE_STATUS_JSON="$_raw"
    _ps_n=$(echo "$_raw" | jq '.failures | length' 2>/dev/null || echo 0)
    _ps_d=$(echo "$_raw" | jq -r '.summary.days // 30' 2>/dev/null || echo 30)
    printf "  \033[32m✓\033[0m  Profile status: %d profile(s) with failures (last %s days)\n" "$_ps_n" "$_ps_d"
fi

# ─── App status (opt-in via --app-status) ────────────────────────────────────
APP_STATUS_JSON='{"failures":[],"device_failures":[],"device_pending":[],"summary":{"days":30,"total_errors":0,"unique_devices":0,"unique_apps":0,"devices_high_failure":0}}'
if [[ "$RUN_APP_STATUS" == true ]] && [[ -s "$TMP/app_status.json" ]]; then
    _raw=$(jq -c 'if type=="array" then .[0] // {} else . end' "$TMP/app_status.json" 2>/dev/null || echo '{}')
    APP_STATUS_JSON="$_raw"
    _as_n=$(echo "$_raw" | jq '.failures | length' 2>/dev/null || echo 0)
    _as_d=$(echo "$_raw" | jq -r '.summary.days // 30' 2>/dev/null || echo 30)
    printf "  \033[32m✓\033[0m  App status: %d app(s) with failures (last %s days)\n" "$_as_n" "$_as_d"
fi

# ─── Update status (opt-in via --update-status) ──────────────────────────────
UPDATE_STATUS_JSON='{"plan_state_summary":[],"plan_total":0,"status_summary":[],"total":0}'
if [[ "$RUN_UPDATE_STATUS" == true ]] && [[ -s "$TMP/update_status.json" ]]; then
    _raw=$(jq -c 'if type=="array" then .[0] // {} else . end' "$TMP/update_status.json" 2>/dev/null || echo '{}')
    UPDATE_STATUS_JSON="$_raw"
    _us_failed=$(echo "$_raw" | jq '[.plan_state_summary[] | select(.state=="PlanFailed") | .count] | add // 0' 2>/dev/null || echo 0)
    _us_total=$(echo "$_raw" | jq '.plan_total // 0' 2>/dev/null || echo 0)
    printf "  \033[32m✓\033[0m  Update status: %d failed of %d plans\n" "$_us_failed" "$_us_total"
fi

# ─── Device compliance (opt-in via --device-compliance) ──────────────────────
DEVICE_COMPLIANCE_JSON='[]'
if [[ "$RUN_DEVICE_COMPLIANCE" == true ]] && [[ -s "$TMP/device_compliance.json" ]]; then
    _raw=$(jq -c 'if type=="array" then . else [] end' "$TMP/device_compliance.json" 2>/dev/null || echo '[]')
    DEVICE_COMPLIANCE_JSON="$_raw"
    _dc_stale=$(echo "$_raw" | jq '[.[] | select(.stale==true)] | length' 2>/dev/null || echo 0)
    _dc_total=$(echo "$_raw" | jq 'length' 2>/dev/null || echo 0)
    printf "  \033[32m✓\033[0m  Device compliance: %d stale of %d devices (threshold: %d days)\n" "$_dc_stale" "$_dc_total" "$DEVICE_COMPLIANCE_DAYS"
fi

# ─── History snapshot (opt-in via --track-history) ───────────────────────────
HISTORY_JSON='[]'
if [[ "$TRACK_HISTORY" == true ]]; then
    _SNAP=$(jq -cn \
        --arg  ts   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg  url  "$INSTANCE_URL" \
        --argjson ver "$OS_DATA" \
        --arg  fv   "$FV_VAL"  --arg gk  "$GK_VAL" \
        --arg  sip  "$SIP_VAL" --arg fw  "$FW_VAL" \
        --arg  comp "$COMPLIANCE_SCORE" \
        '{ts:$ts, instance:$url, versions:$ver, security:{fv:($fv|tonumber),gk:($gk|tonumber),sip:($sip|tonumber),fw:($fw|tonumber),compliance:($comp|tonumber)}}')
    # Load existing history, append snapshot, keep at most 365 entries
    _EXISTING='[]'
    [[ -f "$HISTORY_FILE" ]] && \
        _EXISTING=$(jq -c '.' "$HISTORY_FILE" 2>/dev/null || echo '[]')
    _UPDATED=$(jq -c --argjson s "$_SNAP" '. + [$s] | .[-365:]' \
        <<< "$_EXISTING" 2>/dev/null || echo "[$_SNAP]")
    printf '%s\n' "$_UPDATED" > "$HISTORY_FILE"
    printf "  \033[32m✓\033[0m  History snapshot saved → %s\n" "$HISTORY_FILE"
    # Expose to JS: only snapshots from this instance
    HISTORY_JSON=$(jq -c --arg url "$INSTANCE_URL" \
        '[.[] | select(.instance == $url)]' \
        "$HISTORY_FILE" 2>/dev/null || echo '[]')
fi

# Flagged devices — count + full list for table
FLAGGED_JSON=$(jq -c '
    [.[] | select(.section=="device") | select(
        (.filevault != "ENCRYPTED" and .filevault != "") or
        (.gatekeeper == "DISABLED" or .gatekeeper == "Disabled") or
        (.sip != "ENABLED" and .sip != "Enabled" and .sip != "") or
        (.firewall == false)
    ) | {
        name:       .name,
        serial:     .serial,
        os:         .os_version,
        filevault:  .filevault,
        gatekeeper: .gatekeeper,
        sip:        .sip,
        firewall:   .firewall
    }]' "$TMP/security.json" 2>/dev/null || echo '[]')
FLAGGED=$(jq -n --argjson a "$FLAGGED_JSON" '$a | length' 2>/dev/null || echo 0)

# ─── Deployment hierarchy builder ────────────────────────────────────────────
build_hier() {
    echo "$1" | jq -c '
        if type != "array" or length == 0 then [] else
            group_by(
                if .category then
                    if (.category|type) == "object" then (.category.name // "No Category")
                    else (.category|tostring) end
                else "No Category" end
            )
            | map({
                category: (
                    if .[0].category then
                        if (.[0].category|type) == "object" then (.[0].category.name // "No Category")
                        else (.[0].category|tostring) end
                    else "No Category" end
                ),
                count: length,
                items: (map(.name // "Unnamed") | sort)
            })
            | sort_by(.category)
        end
    ' 2>/dev/null || echo '[]'
}

step "Building deployment hierarchy"
# Policies and config profiles list only returns {id, name} — no category field.
# Derive a scope group from the naming convention: "SCOPE - Vendor - Product - Action".
# Scripts list returns {categoryName} directly.
_enrich_by_name() {
    # Reads JSON array from file $1, adds .category.name from first " - " segment of .name
    jq -c 'if type != "array" then [] else
        map(. + {category: {name:
            ((.name // "Unknown") | split(" - ") | if length > 0 then .[0] | ltrimstr(" ") | rtrimstr(" ") else "Other" end)
        }})
    end' "$1" 2>/dev/null || echo '[]'
}
POL_HIER=$(build_hier "$(_enrich_by_name "$TMP/policies.json")")
MCP_HIER=$(build_hier "$(_enrich_by_name "$TMP/macos_prof.json")")
ICP_HIER=$(build_hier "$(_enrich_by_name "$TMP/ios_prof.json")")
SCR_HIER=$(build_hier "$(jq -c 'if type != "array" then [] else map(. + {category: {name: (.categoryName // "No Category")}}) end' "$TMP/scripts.json" 2>/dev/null || echo '[]')")

# Smart groups list for hierarchy
SGR_LIST=$(echo "$SGR" | jq -c '
    if type != "array" then [] else
        map({name: (.name // "Unnamed"), id: (.id // "")})
        | sort_by(.name)
    end' 2>/dev/null || echo '[]')

# Stale / at-risk smart groups — names matching common staleness patterns
STALE_GROUPS_JSON=$(echo "$SGR" | jq -c '
    if type != "array" then [] else
        [.[] | select(.name | ascii_downcase |
            test("90.day|stale|inactive|at.risk|no.check|not.check|overdue|lapsed|offline")
        ) | {name: .name, id: (.id | tostring)}]
    end' 2>/dev/null || echo '[]')
STALE_COUNT=$(echo "$STALE_GROUPS_JSON" | jq 'length' 2>/dev/null || echo 0)

# Full overview sections — exclude Health & Alerts
OV_SECTIONS=$(echo "$OV" | jq -c '
    if type != "array" then [] else
        group_by(.section)
        | map(select(.[0].section != "Health & Alerts"))
        | map({
            section: .[0].section,
            items: map(select(.resource != null and .resource != "")
                | {resource: .resource, value: .value, status: (.status // "")})
          })
    end' 2>/dev/null || echo '[]')

# ADE instance names list
ADE_LIST=$(echo "$ADE_DETAIL" | jq -c '
    if type=="array" then [.[] | {name: (.name // "Unnamed"), id: (.id // "")}]
    elif type=="object" and .results then [.results[] | {name: (.name // "Unnamed"), id: (.id // "")}]
    else [] end' 2>/dev/null || echo '[]')

# Org item name lists for dropdowns
SITES_LIST=$(echo "$SITES_DETAIL" | jq -c 'if type=="array" then [.[].name // "Unnamed"] | sort else [] end' 2>/dev/null || echo '[]')
BLDG_LIST=$(echo  "$BLDG_DETAIL"  | jq -c 'if type=="array" then [.[].name // "Unnamed"] | sort elif type=="object" and .results then [.results[].name // "Unnamed"] | sort else [] end' 2>/dev/null || echo '[]')
DEPT_LIST=$(echo "$DEPT_DETAIL" | jq -c 'if type=="array" then [.[].name // "Unnamed"] | sort elif type=="object" and .results then [.results[].name // "Unnamed"] | sort else [] end' 2>/dev/null || echo '[]')
CAT_LIST=$(echo  "$CAT"  | jq -c 'if type=="array" then [.[].name // "Unnamed"] | sort elif type=="object" and .results then [.results[].name // "Unnamed"] | sort else [] end' 2>/dev/null || echo '[]')

# ─── Cleanup analysis (opt-in via --cleanup) ────────────────────────────────────
CLEANUP_DISABLED_POLICIES='[]'
CLEANUP_NO_SCOPE_POLICIES='[]'
CLEANUP_NO_SCOPE_PROFILES='[]'
CLEANUP_UNUSED_PACKAGES='[]'
CLEANUP_UNUSED_SCRIPTS='[]'
CLEANUP_TOTAL=0

if [[ "$RUN_CLEANUP" == true ]]; then
# Fetches run in batches of 8 concurrent subshells to stay well within OS fork
# limits while being ~8x faster than sequential. Each ID writes to its own temp
# file (no shared-file race condition); cat+jq combines them. bash 3.2 compatible.
step "Cleanup analysis"
_CL_TMP="$TMP/cleanup"
mkdir -p "$_CL_TMP/pol" "$_CL_TMP/prof"

_CL_BATCH=8   # concurrent fetches per resource type

# ── Policy details ──────────────────────────────────────────────────────────
_cl_pol_ids=$(jq -r 'if type=="array" then .[].id else empty end' \
    "$TMP/policies.json" 2>/dev/null || true)
_cl_pol_total=$(echo "$_cl_pol_ids" | grep -c '[0-9]' 2>/dev/null || echo 0)
printf "  \033[90mFetching %d policy details (batch/%d)…\033[0m\n" \
    "$_cl_pol_total" "$_CL_BATCH"

_cl_n=0
for _pid in $_cl_pol_ids; do
    (
        _det=$($JPRO classic-policies get "$_pid" -o json 2>/dev/null) || _det='{}'
        [[ -z "$_det" ]] && _det='{}'
        printf '%s' "$_det" > "$_CL_TMP/pol/${_pid}.json"
    ) &
    _cl_n=$((_cl_n + 1))
    if (( _cl_n % _CL_BATCH == 0 )); then
        wait
    fi
done
wait   # flush any remainder

# Combine per-ID files → analyse. cat on a glob that matches nothing exits non-zero;
# jq -sc '.' on empty input returns nothing; the || echo '[]' gives a safe fallback.
_CL_ALL_POL=$(cat "$_CL_TMP/pol/"*.json 2>/dev/null | jq -sc '.' 2>/dev/null || true)
_CL_ALL_POL="${_CL_ALL_POL:-[]}"
if [[ "$_CL_ALL_POL" != '[]' ]]; then
    CLEANUP_DISABLED_POLICIES=$(echo "$_CL_ALL_POL" | jq -c '
        [.[] | select(type=="object" and .general != null)
             | select(.general.enabled == false)
             | {id: (.general.id | tostring), name: (.general.name // "Unnamed")}]
        | sort_by(.name)' 2>/dev/null || echo '[]')
    CLEANUP_NO_SCOPE_POLICIES=$(echo "$_CL_ALL_POL" | jq -c '
        [.[] | select(type=="object" and .general != null)
             | select(.general.enabled != false)
             | select(
                 (.scope.all_computers // false) == false and
                 ((.scope.all_jss_users // false) == false) and
                 ((.scope.computers // []) | length) == 0 and
                 ((.scope.computer_groups // []) | length) == 0 and
                 ((.scope.buildings // []) | length) == 0 and
                 ((.scope.departments // []) | length) == 0
               )
             | {id: (.general.id | tostring), name: (.general.name // "Unnamed")}]
        | sort_by(.name)' 2>/dev/null || echo '[]')
fi

# ── Cross-reference packages + scripts against policy details ──────────────
# Build sets of IDs referenced by policies, then find anything not in those sets.
printf "  \033[90mCross-referencing packages and scripts…\033[0m\n"
if [[ "$_CL_ALL_POL" != '[]' ]]; then
    # Collect all package IDs referenced in any policy
    _USED_PKG_IDS=$(echo "$_CL_ALL_POL" | jq -c '
        [.[] | .package_configuration.packages // [] | .[] | .id | tostring]
        | unique' 2>/dev/null || echo '[]')
    CLEANUP_UNUSED_PACKAGES=$(jq -c --argjson used "$_USED_PKG_IDS" '
        if type != "array" then [] else
            [.[] | select( (.id | tostring) | IN($used[]) | not )
                 | {id: (.id | tostring), name: (.packageName // .name // "Unnamed")}]
            | sort_by(.name)
        end' "$TMP/packages.json" 2>/dev/null || echo '[]')

    # Collect all script IDs referenced in any policy
    _USED_SCR_IDS=$(echo "$_CL_ALL_POL" | jq -c '
        [.[] | .scripts // [] | .[] | .id | tostring]
        | unique' 2>/dev/null || echo '[]')
    CLEANUP_UNUSED_SCRIPTS=$(jq -c --argjson used "$_USED_SCR_IDS" '
        if type != "array" then [] else
            [.[] | select( (.id | tostring) | IN($used[]) | not )
                 | {id: (.id | tostring), name: (.name // "Unnamed")}]
            | sort_by(.name)
        end' "$TMP/scripts.json" 2>/dev/null || echo '[]')
fi

# ── macOS profile details ───────────────────────────────────────────────────
_cl_prof_ids=$(jq -r 'if type=="array" then .[].id else empty end' \
    "$TMP/macos_prof.json" 2>/dev/null || true)
_cl_prof_total=$(echo "$_cl_prof_ids" | grep -c '[0-9]' 2>/dev/null || echo 0)
printf "  \033[90mFetching %d macOS profile details (batch/%d)…\033[0m\n" \
    "$_cl_prof_total" "$_CL_BATCH"

_cl_n=0
for _prid in $_cl_prof_ids; do
    (
        _det=$($JPRO classic-macos-config-profiles get "$_prid" -o json 2>/dev/null) || _det='{}'
        [[ -z "$_det" ]] && _det='{}'
        printf '%s' "$_det" > "$_CL_TMP/prof/${_prid}.json"
    ) &
    _cl_n=$((_cl_n + 1))
    if (( _cl_n % _CL_BATCH == 0 )); then
        wait
    fi
done
wait   # flush any remainder

_CL_ALL_PROF=$(cat "$_CL_TMP/prof/"*.json 2>/dev/null | jq -sc '.' 2>/dev/null || true)
_CL_ALL_PROF="${_CL_ALL_PROF:-[]}"
if [[ "$_CL_ALL_PROF" != '[]' ]]; then
    CLEANUP_NO_SCOPE_PROFILES=$(echo "$_CL_ALL_PROF" | jq -c '
        [.[] | select(type=="object" and .general != null)
             | select(
                 (.scope.all_computers // false) == false and
                 ((.scope.all_jss_users // false) == false) and
                 ((.scope.computers // []) | length) == 0 and
                 ((.scope.computer_groups // []) | length) == 0 and
                 ((.scope.buildings // []) | length) == 0 and
                 ((.scope.departments // []) | length) == 0
               )
             | {id: (.general.id | tostring), name: (.general.name // "Unnamed")}]
        | sort_by(.name)' 2>/dev/null || echo '[]')
fi

CLEANUP_TOTAL=$(jq -n \
    --argjson a "${CLEANUP_DISABLED_POLICIES}" \
    --argjson b "${CLEANUP_NO_SCOPE_POLICIES}" \
    --argjson c "${CLEANUP_NO_SCOPE_PROFILES}" \
    --argjson d "${CLEANUP_UNUSED_PACKAGES}" \
    --argjson e "${CLEANUP_UNUSED_SCRIPTS}" \
    '($a|length)+($b|length)+($c|length)+($d|length)+($e|length)' 2>/dev/null || echo 0)
printf "  Found %s item(s) flagged for cleanup review\n" "$CLEANUP_TOTAL"

fi  # [[ "$RUN_CLEANUP" == true ]]
[[ "$RUN_CLEANUP" == true ]] && CLEANUP_LABEL="${CLEANUP_TOTAL}" || CLEANUP_LABEL="—"

# ─── Extract Self Service app icon (silent) ────────────────────────────────────
# If JAMF_REPORT_ICON_B64 is set (e.g. by run-demo.sh), use it directly.
SS_ICON_B64="${JAMF_REPORT_ICON_B64:-}"
if [[ -n "$SS_ICON_B64" ]]; then
    printf "  \033[32m✓\033[0m  Icon provided via JAMF_REPORT_ICON_B64\n"
fi
_try_ss_icon() {
    local _ss_app="" _icon_out="$TMP/.ss_icon.png" _candidate
    # Build candidate list: plist key (if enrolled) then standard locations
    local _plist_path
    _plist_path=$(defaults read /Library/Preferences/com.jamfsoftware.jamf \
        self_service_app_path 2>/dev/null) || true
    for _candidate in \
        "${_plist_path:-}" \
        "/Applications/Self Service.app" \
        "/Applications/Self Service+.app" ; do
        [[ -n "${_candidate:-}" && -d "${_candidate}" ]] && { _ss_app="${_candidate}"; break; }
    done
    if [[ -z "$_ss_app" ]]; then
        printf "  \033[33m⚠\033[0m  Self Service app not found — using default icon\n"
        return 1
    fi
    printf "  \033[90m   Self Service found: %s\033[0m\n" "$_ss_app"

    # Method 1: resource fork (custom branded icon set by Jamf admin console)
    local _rfork="${_ss_app}/Icon"$'\r'
    if [[ -f "$_rfork" ]]; then
        xxd -p -s 260 "$_rfork/..namedfork/rsrc" 2>/dev/null \
            | xxd -r -p > "$TMP/.ss_raw.icns" 2>/dev/null || true
        if [[ -s "$TMP/.ss_raw.icns" ]]; then
            sips -s format png "$TMP/.ss_raw.icns" \
                 --resampleHeightWidthMax 128 \
                 --out "$_icon_out" >/dev/null 2>&1 || true
        fi
    fi

    # Method 2: any ICNS inside the app bundle (always present, even default icon)
    if [[ ! -s "$_icon_out" ]]; then
        local _icns
        _icns=$(find "${_ss_app}/Contents/Resources" -maxdepth 3 \
            \( -name "AppIcon.icns" -o -name "SelfService.icns" -o -name "*.icns" \) \
            2>/dev/null | head -1) || true
        if [[ -n "${_icns:-}" ]]; then
            sips -s format png "$_icns" \
                 --resampleHeightWidthMax 128 \
                 --out "$_icon_out" >/dev/null 2>&1 || true
        fi
    fi

    if [[ ! -s "$_icon_out" ]]; then
        printf "  \033[33m⚠\033[0m  Could not convert icon — using default icon\n"
        return 1
    fi
    SS_ICON_B64=$(base64 < "$_icon_out" | tr -d '\n')
    if [[ -n "${SS_ICON_B64:-}" ]]; then
        printf "  \033[32m✓\033[0m  Self Service icon embedded (%d bytes base64)\n" \
            "$(echo -n "$SS_ICON_B64" | wc -c | tr -d ' ')"
    fi
}
# Only run the Self Service extraction if no icon was pre-supplied
[[ -z "$SS_ICON_B64" ]] && _try_ss_icon

# ─── Status colour helpers ────────────────────────────────────────────────────
# Extract the numeric alert count from values like "1 active", "3", "None", "N/A"
_alert_count() {
    local _n
    _n=$(echo "$ACTIVE_ALERTS" | grep -o '[0-9]\+' | head -1)
    echo "${_n:-0}"
}
health_badge() {
    # Healthy string + alert severity determines badge colour:
    #   no alerts  → green, 1 alert → amber, >1 alerts → red
    #   unhealthy string always → red
    case "$HEALTH_STATUS" in
        *online*|*ok*|*OK*|*healthy*|*OPERATIONAL*)
            local _ac; _ac=$(_alert_count)
            if   (( _ac == 0 )); then echo "badge-ok"
            elif (( _ac == 1 )); then echo "badge-warn"
            else                      echo "badge-err"
            fi ;;
        *degraded*|*warn*) echo "badge-warn" ;;
        *) echo "badge-err" ;;
    esac
}
alert_badge() {
    # 0 alerts → green, 1 alert → amber, >1 alerts → red
    local _ac; _ac=$(_alert_count)
    if   (( _ac == 0 ));                                     then echo "badge-ok"
    elif (( _ac == 1 ));                                     then echo "badge-warn"
    elif [[ "$ACTIVE_ALERTS" == "None" || "$ACTIVE_ALERTS" == "N/A" ]]; then echo "badge-ok"
    else echo "badge-err"
    fi
}
dep_sync_badge() {
    case "$ADE_SYNC" in
        *SUCCESSFUL*) echo "badge-ok" ;;
        N/A|'')       echo "badge-dim" ;;
        *)            echo "badge-warn" ;;
    esac
}
feat_badge()  { [[ "$1" == "enabled"* ]] && echo "badge-ok" || echo "badge-dim"; }

# ─── Expiry countdown helpers ─────────────────────────────────────────────────
_days_until() {
    local _ds="$1"
    [[ -z "$_ds" || "$_ds" == "N/A" ]] && { echo ""; return; }
    local _now _then=""
    _now=$(date +%s)
    if   _then=$(date -j -f "%Y-%m-%d"   "$_ds" "+%s" 2>/dev/null); then :
    elif _then=$(date -j -f "%B %d, %Y" "$_ds" "+%s" 2>/dev/null); then :
    elif _then=$(date -j -f "%d %B %Y"  "$_ds" "+%s" 2>/dev/null); then :
    else _then=""
    fi
    [[ -n "$_then" ]] && echo $(( (_then - _now) / 86400 )) || echo ""
}
_badge_for_days() {
    local _d="$1"
    [[ -z "$_d"      ]] && echo "badge-dim"  && return
    [[ "$_d" -lt 0   ]] && echo "badge-err"  && return
    [[ "$_d" -lt 30  ]] && echo "badge-err"  && return
    [[ "$_d" -lt 90  ]] && echo "badge-warn" && return
    echo "badge-ok"
}
_label_with_days() {
    local _d="$1" _raw="$2"
    [[ -z "$_d"      ]] && echo "$_raw"                      && return
    [[ "$_d" -lt 0   ]] && echo "$_raw — EXPIRED"            && return
    [[ "$_d" -eq 0   ]] && echo "$_raw — expires today"      && return
    [[ "$_d" -eq 1   ]] && echo "$_raw — 1 day left"         && return
    echo "$_raw — ${_d}d left"
}

DEP_TOKEN_DAYS=$(_days_until "$DEP_TOKEN_EXPIRES")
CA_DAYS=$(_days_until "$CA_EXPIRES")

HEALTH_BADGECLS=$(health_badge)
ALERT_BADGECLS=$(alert_badge)
DEP_TOKEN_BADGECLS=$(_badge_for_days "$DEP_TOKEN_DAYS")
CA_BADGECLS=$(_badge_for_days "$CA_DAYS")
DEP_SYNC_BADGECLS=$(dep_sync_badge)
DEP_TOKEN_LABEL=$(_label_with_days "$DEP_TOKEN_DAYS" "$DEP_TOKEN_EXPIRES")
CA_LABEL=$(_label_with_days "$CA_DAYS" "$CA_EXPIRES")

REPORT_DATE=$(date '+%A %d %B %Y, %H:%M')
CLI_VER=$(jamf-cli version 2>/dev/null | head -1 | awk '{print $NF}' 2>/dev/null || echo "unknown")

# Build topbar icon element (Self Service icon if available, SVG fallback otherwise)
if [[ -n "${SS_ICON_B64:-}" ]]; then
    SS_ICON_HTML='<img src="data:image/png;base64,'"${SS_ICON_B64}"'" class="ss-icon" alt="Self Service">'
else
    SS_ICON_HTML='<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M32 4C16.536 4 4 16.536 4 32s12.536 28 28 28 28-12.536 28-28S47.464 4 32 4zm0 4c13.255 0 24 10.745 24 24S45.255 56 32 56 8 45.255 8 32 18.745 8 32 8zm-1 8v16H19v4h12v8h4v-8h12v-4H35V16h-4z"/></svg>'
fi

step "Generating HTML"

# ─── HTML output – variable expansion is active in this heredoc ───────────────
# Dollar signs inside JS/CSS that should NOT expand are written as \$
# (there are none — all embedded JS avoids template literals and \$)
cat > "$OUTPUT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Jamf Pro Report — ${INSTANCE_URL}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"></script>
<style>
:root {
    --ink:       #111111;
    --ink-2:     #374151;
    --muted:     #6b7280;
    --border:    #e5e5e5;
    --bg:        #fafaf9;
    --surface:   #ffffff;
    --surface-2: #f5f5f4;
    --accent:    #1d6fa4;
    --accent-lt: #e8f3fb;
    --green:     #166534;
    --green-lt:  #dcfce7;
    --amber:     #92400e;
    --amber-lt:  #fef3c7;
    --red:       #991b1b;
    --red-lt:    #fee2e2;
    --radius:    8px;
    /* legacy aliases kept for Chart.js colour literals and JS references */
    --blue-dark: #1d6fa4;
    --blue:      #1d6fa4;
    --blue-lt:   #e8f3fb;
    --text:      #111111;
    --shadow:    0 1px 2px rgba(0,0,0,.05);
    --purple:    #7c3aed;
    --cyan:      #0891b2;
}
body.dark {
    --ink:       #e5e5e5;
    --ink-2:     #d1d5db;
    --muted:     #9ca3af;
    --border:    #374151;
    --bg:        #111827;
    --surface:   #1f2937;
    --surface-2: #111827;
    --accent:    #60a5fa;
    --accent-lt: #1e3a5f;
    --green:     #4ade80;
    --green-lt:  #14532d;
    --amber:     #fbbf24;
    --amber-lt:  #451a03;
    --red:       #f87171;
    --red-lt:    #450a0a;
    --blue-dark: #60a5fa;
    --blue:      #60a5fa;
    --blue-lt:   #1e3a5f;
    --text:      #e5e5e5;
    --shadow:    0 1px 2px rgba(0,0,0,.3);
    --purple:    #a78bfa;
    --cyan:      #22d3ee;
}
body.dark .topbar{background:#1f2937;border-bottom-color:#374151}
body.dark .data-table th{background:#273548}
body.dark .data-table tr:hover td{background:#1e3048}
body.dark .exp-child td{background:#273548}
body.dark .badge-ok{background:#14532d;color:#4ade80}
body.dark .badge-warn{background:#451a03;color:#fbbf24}
body.dark .badge-err{background:#450a0a;color:#f87171}
body.dark .badge-dim{background:#273548;color:#9ca3af}
body.dark .badge-blue{background:#1e3a5f;color:#60a5fa}
body.dark .sec-bar-track{background:#374151}
body.dark .tree-search{background:#273548;color:#e5e5e5;border-color:#374151}
body.dark .cat-toggle,.dark .sg-node{background:#273548;border-color:#374151}
body.dark .cu-section-hdr{background:#111827;border-color:#374151}
body.dark .item-node:hover{background:#1e3048}
body.dark .feat-on{background:#14532d;color:#4ade80;border-color:#166534}
body.dark .feat-off{background:#1f2937;color:#9ca3af;border-color:#374151}
body.dark .link-card{background:#1f2937;color:#e5e5e5}
body.dark .link-card:hover{border-color:var(--accent)}
body.dark .os-table th,.dark .os-table td{border-color:#374151}
body.dark .os-table td:last-child{color:var(--accent)}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--ink);font-size:14px;line-height:1.5}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}

/* ── top bar ── */
.topbar{background:var(--surface);border-bottom:1px solid var(--border);padding:12px 24px;display:flex;align-items:center;gap:16px;flex-wrap:wrap;justify-content:space-between;position:sticky;top:0;z-index:100}
.topbar-brand{font-size:1rem;font-weight:700;letter-spacing:-.2px;display:flex;align-items:center;gap:10px;color:var(--ink)}
.topbar-brand svg{width:24px;height:24px;fill:var(--accent)}
.topbar-brand .ss-icon{width:36px;height:36px;border-radius:8px;object-fit:cover;background:var(--surface-2);box-shadow:0 1px 3px rgba(0,0,0,.1)}
.topbar-meta{font-size:.78rem;color:var(--muted);text-align:right}
.topbar-meta strong{color:var(--ink-2);font-size:.85rem}
.dark-toggle{background:var(--surface-2);border:1px solid var(--border);color:var(--ink-2);border-radius:20px;padding:4px 12px;font-size:.76rem;font-weight:600;cursor:pointer;transition:background .15s}
.dark-toggle:hover{background:var(--border)}

/* ── layout ── */
.page{max-width:1400px;margin:0 auto;padding:24px 24px 48px}
.section-title{font-size:.7rem;font-weight:600;letter-spacing:.07em;text-transform:uppercase;color:var(--muted);margin:36px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--border)}
.collapsible-hd{display:flex;align-items:center;justify-content:space-between;cursor:pointer;margin:36px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--border);user-select:none}
.collapsible-hd:hover .collapsible-hd-title{color:var(--accent)}
.collapsible-hd-title{font-size:.7rem;font-weight:600;letter-spacing:.07em;text-transform:uppercase;color:var(--muted)}
.collapsible-hd-caret{font-size:.65rem;color:var(--muted);transition:transform .2s;display:inline-block;margin-left:8px}
.collapsible-hd-caret.closed{transform:rotate(-90deg)}
.collapsible-bd.hidden{display:none}
.grid{display:grid;gap:16px}
.grid-2{grid-template-columns:repeat(2,1fr)}
.grid-3{grid-template-columns:repeat(3,1fr)}
.grid-4{grid-template-columns:repeat(4,1fr)}
.grid-5{grid-template-columns:repeat(5,1fr)}
.grid-6{grid-template-columns:repeat(6,1fr)}
@media(max-width:1100px){.grid-6{grid-template-columns:repeat(3,1fr)}.grid-5{grid-template-columns:repeat(3,1fr)}.grid-4{grid-template-columns:repeat(2,1fr)}}
@media(max-width:700px){.grid-2,.grid-3,.grid-4,.grid-5,.grid-6{grid-template-columns:1fr}}

/* ── cards ── */
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:20px}
.card-sm{padding:14px 16px}
.stat-card{display:flex;flex-direction:column;gap:3px}
.stat-label{font-size:.72rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.stat-value{font-size:2rem;font-weight:700;color:var(--ink);line-height:1.1}
.stat-sub{font-size:.73rem;color:var(--muted)}
.stat-icon{font-size:1.2rem;margin-bottom:4px;opacity:.55}
.stat-link{font-size:.72rem;color:var(--accent);margin-top:6px}

/* ── status badges ── */
.badge{display:inline-block;font-size:.69rem;font-weight:600;padding:3px 9px;border-radius:9999px;letter-spacing:.03em;white-space:nowrap}
.badge-ok{background:var(--green-lt);color:var(--green)}
.badge-warn{background:var(--amber-lt);color:var(--amber)}
.badge-err{background:var(--red-lt);color:var(--red)}
.badge-dim{background:var(--surface-2);color:var(--muted)}
.badge-blue{background:var(--accent-lt);color:var(--accent)}

/* ── health strip ── */
.health-strip{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:14px 20px;display:flex;flex-wrap:wrap;gap:10px 28px;align-items:center}
.health-item{display:flex;align-items:center;gap:7px;font-size:.8rem}
.health-label{color:var(--muted);font-weight:500}

/* ── chart cards ── */
.chart-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:20px}
.chart-title{font-size:.85rem;font-weight:700;color:var(--ink-2);margin-bottom:14px}
.chart-sub{font-size:.73rem;color:var(--muted);margin-top:4px}
.chart-wrap{position:relative;height:220px}
.chart-wrap-lg{position:relative;height:260px}

/* ── security bar row ── */
.sec-bar-row{margin-bottom:13px}
.sec-bar-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:5px}
.sec-bar-name{font-size:.79rem;font-weight:500;color:var(--ink-2)}
.sec-bar-pct{font-size:.79rem;color:var(--muted)}
.sec-bar-track{background:var(--surface-2);border-radius:4px;height:6px;overflow:hidden}
.sec-bar-fill{height:100%;border-radius:4px;transition:width .5s cubic-bezier(.16,1,.3,1)}
.fill-fv{background:#22c55e}
.fill-gk{background:var(--accent)}
.fill-sip{background:#7c3aed}
.fill-fw{background:#f59e0b}

/* ── table ── */
.data-table{width:100%;border-collapse:collapse;font-size:.8rem}
.data-table th{text-align:left;padding:8px 12px;background:var(--surface-2);border-bottom:1px solid var(--border);color:var(--muted);font-weight:600;text-transform:uppercase;font-size:.67rem;letter-spacing:.05em}
.data-table td{padding:7px 12px;border-bottom:1px solid var(--border);vertical-align:top}
.data-table tr:last-child td{border-bottom:0}
.data-table tr:hover td{background:var(--surface-2)}
.data-table .val{font-weight:600;color:var(--ink);text-align:right}
.data-table .val-warn{color:var(--amber)}
.data-table .val-err{color:var(--red)}
.data-table .val-ok{color:var(--green)}

/* ── expandable org dropdown rows ── */
.exp-row{cursor:pointer;user-select:none}
.exp-row:hover td{background:var(--accent-lt)}
.exp-caret{display:inline-block;font-size:.65rem;transition:transform .18s;margin-right:5px;color:var(--muted)}
.exp-caret.open{transform:rotate(90deg)}
.exp-children{display:none}
.exp-children.open{display:table-row-group}
.exp-child td{background:var(--surface-2);font-size:.76rem;padding:4px 12px 4px 28px;color:var(--muted);border-bottom:1px solid var(--border)}

/* ── section heading ── */
.section-header{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px}
.section-count{font-size:.75rem;color:var(--muted);font-weight:500}

/* ── tabs (underline style) ── */
.tree-tabs{display:flex;border-bottom:1px solid var(--border)}
.tree-tab{padding:10px 18px;font-size:.8rem;font-weight:500;cursor:pointer;border:none;border-bottom:2px solid transparent;margin-bottom:-1px;color:var(--muted);background:transparent;transition:color .15s,border-color .15s;user-select:none}
.tree-tab.active{color:var(--accent);border-bottom-color:var(--accent);font-weight:600}
.tree-tab:hover:not(.active){color:var(--ink-2)}
.tree-pane{display:none;padding:16px}
.tree-pane.active{display:block}
.tree-search{width:100%;padding:8px 12px;border:1px solid var(--border);border-radius:var(--radius);font-size:.82rem;margin-bottom:12px;outline:none;color:var(--ink);background:var(--surface)}
.tree-search:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(29,111,164,.1)}
.tree-summary{font-size:.74rem;color:var(--muted);margin-bottom:10px}

/* ── deployment tree ── */
.cat-node{margin-bottom:4px}
.cat-toggle{display:flex;align-items:center;gap:6px;padding:8px 12px;background:var(--surface-2);border:1px solid var(--border);border-radius:6px;cursor:pointer;user-select:none;transition:background .15s}
.cat-toggle:hover{background:var(--accent-lt)}
.cat-caret{font-size:.65rem;color:var(--muted);width:12px;transition:transform .2s;display:inline-block}
.cat-caret.open{transform:rotate(90deg)}
.cat-name{font-weight:600;font-size:.82rem;flex:1;color:var(--ink-2)}
.cat-badge{font-size:.7rem;background:var(--accent-lt);color:var(--accent);padding:1px 7px;border-radius:10px;font-weight:600}
.cat-children{display:none;padding:4px 0 4px 28px}
.cat-children.open{display:block}
.item-node{padding:4px 8px;font-size:.79rem;border-radius:4px;color:var(--ink-2);display:flex;align-items:center;gap:6px}
.item-node:hover{background:var(--surface-2)}
.item-node::before{content:"·";color:var(--muted);font-size:.9rem}
.item-hidden{display:none !important}
.sg-node{padding:7px 12px;border-radius:6px;font-size:.79rem;margin-bottom:3px;background:var(--surface-2);border:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.sg-node .sg-name{font-weight:500;color:var(--ink-2)}
.sg-node .sg-id{font-size:.7rem;color:var(--muted)}

/* ── cleanup tab ── */
.cu-section{margin-bottom:12px}
.cu-section:last-child{margin-bottom:0}
.cu-section-hdr{display:flex;align-items:center;gap:8px;padding:8px 14px;background:var(--surface-2);border-bottom:1px solid var(--border);font-size:.7rem;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.cu-badge{display:inline-flex;align-items:center;justify-content:center;min-width:18px;padding:1px 6px;border-radius:9999px;font-size:.67rem;font-weight:700;background:var(--surface);color:var(--muted);margin-left:auto;border:1px solid var(--border)}
.cu-badge.cu-warn{background:var(--amber-lt);color:var(--amber);border-color:transparent}
.cu-badge.cu-err{background:var(--red-lt);color:var(--red);border-color:transparent}

/* ── feature pills ── */
.feat-grid{display:flex;flex-wrap:wrap;gap:8px;padding:16px}
.feat-pill{display:flex;align-items:center;gap:6px;padding:5px 12px;border-radius:9999px;font-size:.78rem;font-weight:600;border:1px solid var(--border)}
.feat-on{background:var(--green-lt);color:var(--green);border-color:transparent}
.feat-off{background:var(--surface-2);color:var(--muted);border-color:var(--border)}

/* ── links grid ── */
.links-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:8px}
.link-card{display:flex;align-items:center;gap:10px;padding:12px 14px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);text-decoration:none;color:var(--ink-2);font-size:.81rem;font-weight:500;transition:border-color .15s,background .15s}
.link-card:hover{border-color:var(--accent);background:var(--accent-lt);text-decoration:none}
.link-icon{font-size:1.1rem;opacity:.65}

/* ── os table inside donut pane ── */
.os-table{width:100%;border-collapse:collapse;font-size:.76rem;margin-top:12px}
.os-table th,.os-table td{padding:5px 8px;border-bottom:1px solid var(--border)}
.os-table th{color:var(--muted);font-weight:600;text-transform:uppercase;font-size:.65rem;background:var(--surface-2)}
.os-table td:last-child{text-align:right;font-weight:600;color:var(--accent)}
.os-dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px;vertical-align:middle}

/* ── footer ── */
.footer{text-align:center;font-size:.72rem;color:var(--muted);padding:20px 0 0;margin-top:40px;border-top:1px solid var(--border)}

/* ── cover block ── */
.cover-block{display:flex;align-items:center;justify-content:space-between;padding:16px 0 18px;border-bottom:1px solid var(--border);margin-bottom:20px;flex-wrap:wrap;gap:12px}
.cover-kv{font-size:.78rem;color:var(--muted)}
.cover-kv strong{color:var(--ink-2)}

/* ── stale groups ── */
.stale-item{padding:8px 16px;border-bottom:1px solid var(--border);font-size:.8rem;display:flex;align-items:center;gap:8px}
.stale-item:last-child{border-bottom:0}
.stale-dot{width:8px;height:8px;border-radius:50%;background:var(--amber);flex-shrink:0}
body.dark .stale-item{border-color:#374151}

/* ── print ── */
@media print {
    .dark-toggle,.topbar .dark-toggle{display:none!important}
    .tree-search{display:none}
    .tree-tab{display:none}
    .tree-pane{display:block!important}
    .cat-children{display:block!important}
    .cat-toggle{cursor:default;pointer-events:none}
    .exp-children{display:table-row-group!important}
    .links-grid,.footer a[href]:after{display:none}
    body{background:#fff;color:#000;font-size:12px}
    .topbar{background:#fff!important;border-bottom:1px solid #ddd!important;position:static!important}
    .card,.chart-card{break-inside:avoid;box-shadow:none;border:1px solid #ddd!important}
    .page{max-width:100%;padding:0 8px}
    .chart-wrap-lg{height:200px!important}
    canvas{max-width:100%!important}
    .grid-6{grid-template-columns:repeat(3,1fr)!important}
    .grid-3{grid-template-columns:repeat(3,1fr)!important}
    @page{margin:1.5cm}
}
</style>
</head>
<body>

<!-- ── Top Bar ── -->
<div class="topbar">
  <div class="topbar-brand">
    ${SS_ICON_HTML}
    Jamf Pro — Instance Report
  </div>
  <div style="display:flex;align-items:center;gap:12px">
    <div class="topbar-meta">
      <strong>${INSTANCE_URL}</strong><br>
      <span>v${JAMF_VERSION}</span> &nbsp;&middot;&nbsp; <span>${REPORT_DATE}</span>
    </div>
    <button class="dark-toggle" id="darkBtn" onclick="toggleDark()" title="Toggle dark mode">Dark</button>
  </div>
</div>

<div class="page">

<!-- ── Report Cover Block ── -->
<div class="cover-block">
  <div>
    <div style="font-weight:700;font-size:1.1rem;color:var(--ink);letter-spacing:-0.02em">Jamf Pro Environment Report</div>
    <div style="font-size:.75rem;color:var(--muted);margin-top:3px;font-family:var(--font-mono)">${INSTANCE_URL}</div>
  </div>
  <div style="display:flex;gap:24px;flex-wrap:wrap;align-items:center">
    <span class="cover-kv"><strong>Generated</strong> ${REPORT_DATE}</span>
    <span class="cover-kv"><strong>Jamf Pro</strong> <span style="font-family:var(--font-mono)">${JAMF_VERSION}</span></span>
    <span class="cover-kv"><strong>Managed Computers</strong> <span style="font-family:var(--font-mono)">${MANAGED_COMPUTERS}</span></span>
    <span class="cover-kv"><strong>Managed Devices</strong> <span style="font-family:var(--font-mono)">${MANAGED_DEVICES}</span></span>
    <span class="cover-kv"><strong>Flagged</strong> <span style="color:var(--red);font-weight:700;font-family:var(--font-mono)">${FLAGGED}</span></span>
    <span class="cover-kv"><strong>Compliance</strong> <span style="color:${COMPLIANCE_COLOR};font-weight:700;font-family:var(--font-mono)">${COMPLIANCE_SCORE}%</span></span>
  </div>
  <button onclick="window.print()" style="background:var(--ink);color:#fff;border:none;padding:8px 18px;border-radius:6px;font-size:.75rem;font-weight:700;cursor:pointer;flex-shrink:0;letter-spacing:.03em;transition:background .15s" onmouseover="this.style.background='#333'" onmouseout="this.style.background='var(--ink)'">Print / Export PDF</button>
</div>

<!-- ── Health Strip ── -->
<div class="health-strip">
  <div class="health-item">
    <span class="health-label">Health</span>
    <span class="badge ${HEALTH_BADGECLS}">${HEALTH_STATUS}</span>
  </div>
  <div class="health-item">
    <span class="health-label">Alerts</span>
    <span class="badge ${ALERT_BADGECLS}">${ACTIVE_ALERTS}</span>
  </div>
  <div class="health-item">
    <span class="health-label">DEP Token Expires</span>
    <span class="badge ${DEP_TOKEN_BADGECLS}">${DEP_TOKEN_LABEL}</span>
  </div>
  <div class="health-item">
    <span class="health-label">Built-in CA Expires</span>
    <span class="badge ${CA_BADGECLS}">${CA_LABEL}</span>
  </div>
  <div class="health-item">
    <span class="health-label">DEP Sync</span>
    <span class="badge ${DEP_SYNC_BADGECLS}">${ADE_SYNC}</span>
  </div>
  <div class="health-item">
    <span class="health-label">Check-In Frequency</span>
    <span class="badge badge-blue">${CHECKIN_FREQ}</span>
  </div>
</div>

<!-- ── Compliance Banner ── -->
<div class="card" style="margin-bottom:14px;padding:20px 24px">
  <div style="display:flex;align-items:center;gap:32px;flex-wrap:wrap">

    <!-- Ring gauge -->
    <div style="text-align:center;flex-shrink:0">
      <div style="font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:8px">Overall Compliance Score</div>
      <svg viewBox="0 0 100 100" width="110" height="110" aria-label="Compliance score ${COMPLIANCE_SCORE}%">
        <circle cx="50" cy="50" r="42" fill="none" stroke="#e2e8f0" stroke-width="12"/>
        <circle cx="50" cy="50" r="42" fill="none" stroke="${COMPLIANCE_COLOR}" stroke-width="12"
          stroke-dasharray="${COMPLIANCE_DASH} 264" stroke-linecap="round"
          transform="rotate(-90 50 50)"/>
        <text x="50" y="46" text-anchor="middle" font-size="21" font-weight="700" fill="${COMPLIANCE_COLOR}">${COMPLIANCE_SCORE}%</text>
        <text x="50" y="61" text-anchor="middle" font-size="8.5" fill="#94a3b8">COMPLIANT</text>
      </svg>
      <div style="font-size:.72rem;color:var(--muted);margin-top:4px">${TOTAL_SCANNED} devices scanned</div>
    </div>

    <!-- Security stats — compact summary (detail bars appear in Security Posture section below) -->
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px 36px;flex:1;min-width:200px">
      <div>
        <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">FileVault</div>
        <div style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:3px">${FV_PCT}</div>
        <div style="font-size:.71rem;color:var(--muted);margin-top:1px">${FV_COUNT} devices</div>
      </div>
      <div>
        <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Gatekeeper</div>
        <div style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:3px">${GK_PCT}</div>
        <div style="font-size:.71rem;color:var(--muted);margin-top:1px">${GK_COUNT} devices</div>
      </div>
      <div>
        <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">SIP</div>
        <div style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:3px">${SIP_PCT}</div>
        <div style="font-size:.71rem;color:var(--muted);margin-top:1px">${SIP_COUNT} devices</div>
      </div>
      <div>
        <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Firewall</div>
        <div style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:3px">${FW_PCT}</div>
        <div style="font-size:.71rem;color:var(--muted);margin-top:1px">${FW_COUNT} devices</div>
      </div>
    </div>

    <!-- Attention items -->
    <div style="flex-shrink:0;min-width:190px;display:flex;flex-direction:column;gap:10px">
      <div style="font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Attention Required</div>
      <div style="display:flex;align-items:flex-start;gap:9px;font-size:.82rem">
        <span style="font-size:1.1rem;line-height:1">⚠️</span>
        <div><strong>${FLAGGED}</strong> flagged devices<div style="font-size:.71rem;color:var(--muted)">Security compliance failures</div></div>
      </div>
      <div style="display:flex;align-items:flex-start;gap:9px;font-size:.82rem">
        <span style="font-size:1.1rem;line-height:1">🕐</span>
        <div><strong>${STALE_COUNT}</strong> at-risk group(s)<div style="font-size:.71rem;color:var(--muted)">Stale device smart groups</div></div>
      </div>
    </div>

  </div>
</div>

<!-- ── Summary Cards ── -->
<div class="collapsible-hd" onclick="toggleSection('fleetBd',this)">
  <span class="collapsible-hd-title">Fleet Inventory</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="fleetBd" class="collapsible-bd">
<div class="grid grid-6">

  <div class="card stat-card">
    <div class="stat-icon">💻</div>
    <div class="stat-label">Managed Computers</div>
    <div class="stat-value">${MANAGED_COMPUTERS}</div>
    <div class="stat-sub">Unmanaged: ${UNMANAGED_COMPUTERS}</div>
    <a class="stat-link" href="${CONSOLE_URL}/computers.html" target="_blank">Open in Jamf ↗</a>
  </div>

  <div class="card stat-card">
    <div class="stat-icon">📱</div>
    <div class="stat-label">Managed Devices</div>
    <div class="stat-value">${MANAGED_DEVICES}</div>
    <div class="stat-sub">Unmanaged: ${UNMANAGED_DEVICES}</div>
    <a class="stat-link" href="${CONSOLE_URL}/mobileDevices.html" target="_blank">Open in Jamf ↗</a>
  </div>

  <div class="card stat-card">
    <div class="stat-icon">📋</div>
    <div class="stat-label">Policies</div>
    <div class="stat-value">${POLICIES_COUNT}</div>
    <div class="stat-sub">Deployment policies</div>
    <a class="stat-link" href="${CONSOLE_URL}/policies.html" target="_blank">Open in Jamf ↗</a>
  </div>

  <div class="card stat-card">
    <div class="stat-icon">🛡️</div>
    <div class="stat-label">macOS Profiles</div>
    <div class="stat-value">${MACOS_PROF_COUNT}</div>
    <div class="stat-sub">Configuration profiles</div>
    <a class="stat-link" href="${CONSOLE_URL}/OSXConfigurationProfiles.html" target="_blank">Open in Jamf ↗</a>
  </div>

  <div class="card stat-card">
    <div class="stat-icon">📦</div>
    <div class="stat-label">Packages</div>
    <div class="stat-value">${PACKAGES_COUNT}</div>
    <div class="stat-sub">Scripts: ${SCRIPTS_COUNT}</div>
    <a class="stat-link" href="${CONSOLE_URL}/view/settings/computer-management/packages" target="_blank">Open in Jamf ↗</a>
  </div>

  <div class="card stat-card">
    <div class="stat-icon">🏷️</div>
    <div class="stat-label">Smart Groups</div>
    <div class="stat-value">${COMP_SMART}</div>
    <div class="stat-sub">Static: ${COMP_STATIC}</div>
    <a class="stat-link" href="${CONSOLE_URL}/smartComputerGroups.html" target="_blank">Open in Jamf ↗</a>
  </div>

</div>
</div>

<!-- ── Patch Compliance (opt-in, only shown when --patch-status was passed) ── -->
<div id="patchSection" style="display:none">
<div class="collapsible-hd" onclick="toggleSection('patchCard',this)">
  <span class="collapsible-hd-title">Patch Compliance</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="patchCard" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <div style="padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:28px;flex-wrap:wrap">
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Titles</div>
      <div id="patch-title-count" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Avg Compliance</div>
      <div id="patch-avg" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Below 80%</div>
      <div id="patch-below-threshold" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div style="margin-left:auto">
      <input class="tree-search" type="search" placeholder="Filter titles…" oninput="filterPatch(this)" style="margin:0;width:240px">
    </div>
  </div>
  <div style="overflow-x:auto">
    <table class="data-table" id="patchTable">
      <thead>
        <tr>
          <th style="cursor:pointer" onclick="sortPatch('title')">Title ↕</th>
          <th style="cursor:pointer;text-align:right" onclick="sortPatch('compliance_pct')">Compliance ↕</th>
          <th style="cursor:pointer;text-align:right" onclick="sortPatch('on_latest')">On Latest ↕</th>
          <th style="cursor:pointer;text-align:right" onclick="sortPatch('on_other')">On Other ↕</th>
          <th style="cursor:pointer;text-align:right" onclick="sortPatch('total')">Total ↕</th>
          <th>Latest Version</th>
        </tr>
      </thead>
      <tbody id="patchBody"></tbody>
    </table>
  </div>
</div>
</div>
</div>

<!-- ── Profile Status (opt-in, only shown when --profile-status was passed) ── -->
<div id="profileStatusSection" style="display:none">
<div class="collapsible-hd" onclick="toggleSection('psCard',this)">
  <span class="collapsible-hd-title">MDM Profile Failures</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="psCard" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <div style="padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:28px;flex-wrap:wrap">
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Look-back</div>
      <div id="ps-days" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Profiles with Errors</div>
      <div id="ps-profiles" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Devices Affected</div>
      <div id="ps-devices" style="font-size:1.5rem;font-weight:700;color:var(--amber);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Total Errors</div>
      <div id="ps-errors" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
  </div>
  <div style="overflow-x:auto">
    <table class="data-table" id="psTable">
      <thead>
        <tr>
          <th>Profile Name</th>
          <th>Device Type</th>
          <th style="text-align:right">Devices</th>
          <th style="text-align:right">Errors</th>
          <th>Last Error</th>
          <th>Top Error Message</th>
        </tr>
      </thead>
      <tbody id="psBody"></tbody>
    </table>
  </div>
</div>
</div>
</div>

<!-- ── App Status (opt-in, only shown when --app-status was passed) ── -->
<div id="appStatusSection" style="display:none">
<div class="collapsible-hd" onclick="toggleSection('asCard',this)">
  <span class="collapsible-hd-title">MDM App Deployment Failures</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="asCard" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <div style="padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:28px;flex-wrap:wrap">
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Look-back</div>
      <div id="as-days" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Apps with Errors</div>
      <div id="as-apps" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Devices Affected</div>
      <div id="as-devices" style="font-size:1.5rem;font-weight:700;color:var(--amber);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Total Errors</div>
      <div id="as-errors" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">High-failure Devices</div>
      <div id="as-high-failure" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
  </div>
  <div style="overflow-x:auto">
    <table class="data-table" id="asTable">
      <thead>
        <tr>
          <th>App Name</th>
          <th>Device Type</th>
          <th style="text-align:right">Devices</th>
          <th style="text-align:right">Errors</th>
          <th>Last Error</th>
          <th>Top Error Message</th>
        </tr>
      </thead>
      <tbody id="asBody"></tbody>
    </table>
  </div>
</div>
</div>
</div>

<!-- ── Update Status (opt-in, only shown when --update-status was passed) ── -->
<div id="updateStatusSection" style="display:none">
<div class="collapsible-hd" onclick="toggleSection('usCard',this)">
  <span class="collapsible-hd-title">Managed Software Update Status</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="usCard" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <div style="padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:28px;flex-wrap:wrap">
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Total Plans</div>
      <div id="us-total" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Failed</div>
      <div id="us-failed" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Completed</div>
      <div id="us-completed" style="font-size:1.5rem;font-weight:700;color:var(--green);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Exceptions</div>
      <div id="us-exception" style="font-size:1.5rem;font-weight:700;color:var(--amber);line-height:1.2;margin-top:2px">—</div>
    </div>
  </div>
  <div id="usPlanGrid" style="padding:16px 20px;display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px"></div>
</div>
</div>
</div>

<!-- ── Device Compliance (opt-in, only shown when --device-compliance was passed) ── -->
<div id="deviceComplianceSection" style="display:none">
<div class="collapsible-hd" onclick="toggleSection('dcCard',this)">
  <span class="collapsible-hd-title">Device Check-in Compliance</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="dcCard" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <div style="padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:28px;flex-wrap:wrap">
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Total Devices</div>
      <div id="dc-total" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Stale</div>
      <div id="dc-stale" style="font-size:1.5rem;font-weight:700;color:var(--red);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div>
      <div style="font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)">Threshold</div>
      <div id="dc-threshold" style="font-size:1.5rem;font-weight:700;color:var(--ink);line-height:1.2;margin-top:2px">—</div>
    </div>
    <div style="margin-left:auto">
      <label style="display:flex;align-items:center;gap:6px;font-size:.8rem;color:var(--muted);cursor:pointer">
        <input type="checkbox" id="dc-stale-only" onchange="filterDC()"> Stale only
      </label>
    </div>
    <div>
      <input class="tree-search" type="search" placeholder="Filter devices…" oninput="filterDCSearch(this)" style="margin:0;width:220px">
    </div>
  </div>
  <div style="overflow-x:auto">
    <table class="data-table" id="dcTable">
      <thead>
        <tr>
          <th style="cursor:pointer" onclick="sortDC('name')">Device Name ↕</th>
          <th>Serial</th>
          <th style="cursor:pointer;text-align:right" onclick="sortDC('days_since_contact')">Days Since Check-in ↕</th>
          <th>Last Contact</th>
          <th>OS Version</th>
          <th style="text-align:center">Status</th>
          <th></th>
        </tr>
      </thead>
      <tbody id="dcBody"></tbody>
    </table>
  </div>
</div>
</div>
</div>

<!-- ── Security + OS row ── -->
<div class="collapsible-hd" onclick="toggleSection('securityBd',this)">
  <span class="collapsible-hd-title">Security Posture &amp; OS Distribution</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="securityBd" class="collapsible-bd">
<div class="grid grid-2">

  <!-- Security Posture -->
  <div class="chart-card">
    <div class="chart-title">Security Posture — ${TOTAL_SCANNED} computers scanned
      <span style="float:right;font-size:.73rem;font-weight:400;color:var(--muted)">${FLAGGED} flagged devices</span>
    </div>

    <div class="sec-bar-row">
      <div class="sec-bar-header">
        <span class="sec-bar-name">🔒 FileVault Encryption</span>
        <span class="sec-bar-pct">${FV_PCT} (${FV_COUNT})</span>
      </div>
      <div class="sec-bar-track"><div class="sec-bar-fill fill-fv" style="width:${FV_VAL}%"></div></div>
    </div>

    <div class="sec-bar-row">
      <div class="sec-bar-header">
        <span class="sec-bar-name">🔐 Gatekeeper</span>
        <span class="sec-bar-pct">${GK_PCT} (${GK_COUNT})</span>
      </div>
      <div class="sec-bar-track"><div class="sec-bar-fill fill-gk" style="width:${GK_VAL}%"></div></div>
    </div>

    <div class="sec-bar-row">
      <div class="sec-bar-header">
        <span class="sec-bar-name">🛡️ System Integrity Protection</span>
        <span class="sec-bar-pct">${SIP_PCT} (${SIP_COUNT})</span>
      </div>
      <div class="sec-bar-track"><div class="sec-bar-fill fill-sip" style="width:${SIP_VAL}%"></div></div>
    </div>

    <div class="sec-bar-row">
      <div class="sec-bar-header">
        <span class="sec-bar-name">🔥 Firewall</span>
        <span class="sec-bar-pct">${FW_PCT} (${FW_COUNT})</span>
      </div>
      <div class="sec-bar-track"><div class="sec-bar-fill fill-fw" style="width:${FW_VAL}%"></div></div>
    </div>

    <div style="margin-top:16px">
      <div class="chart-wrap"><canvas id="securityChart"></canvas></div>
    </div>
  </div>

  <!-- OS Distribution -->
  <div class="chart-card">
    <div class="chart-title">macOS Version Distribution</div>
    <div class="chart-wrap-lg"><canvas id="osChart"></canvas></div>
    <table class="os-table" id="osTable"><thead><tr><th>Version</th><th>Devices</th><th>%</th></tr></thead><tbody></tbody></table>
  </div>

</div>
</div>

<!-- ── macOS Adoption Timeline (only when history data is present) ── -->
<div id="adoptionSection" style="display:none">
  <div class="collapsible-hd" onclick="toggleSection('adoptionBd',this)">
    <span class="collapsible-hd-title">macOS Adoption &amp; Security Compliance Trend</span>
    <span class="collapsible-hd-caret">&#9660;</span>
  </div>
  <div id="adoptionBd" class="collapsible-bd">
  <div class="grid grid-2" style="align-items:start">
    <div class="card">
      <div class="chart-title">macOS Version Adoption Over Time</div>
      <div class="chart-wrap-lg" style="height:280px"><canvas id="adoptionChart"></canvas></div>
      <p style="font-size:.72rem;color:var(--muted);margin-top:8px;text-align:center">
        Device counts per normalised macOS version across report runs (<code style="font-size:.7rem">--track-history</code>).
      </p>
    </div>
    <div class="card" id="secTrendCard" style="display:none">
      <div class="chart-title">Security Compliance Trend</div>
      <div class="chart-wrap-lg" style="height:280px"><canvas id="secTrendChart"></canvas></div>
      <p style="font-size:.72rem;color:var(--muted);margin-top:8px;text-align:center">
        Security posture percentages over time. Bold line = overall compliance average.
      </p>
    </div>
  </div>
  </div>
</div>

<!-- ── Stale / At-risk Groups ── -->
<div id="staleSection" style="display:none">
  <div class="collapsible-hd" onclick="toggleSection('staleBd',this)">
    <span class="collapsible-hd-title">At-risk Smart Groups (<span id="staleCount">0</span>)</span>
    <span class="collapsible-hd-caret">&#9660;</span>
  </div>
  <div id="staleBd" class="collapsible-bd">
  <div class="card" style="padding:0;overflow:hidden">
    <div style="padding:10px 16px 8px;border-bottom:1px solid var(--border);background:#fffbeb;font-size:.8rem;color:#92400e;font-weight:500">
      ⚠️ These smart groups suggest devices may be stale or inactive. Review membership in Jamf Pro.
    </div>
    <div id="staleList"></div>
  </div>
  </div>
</div>

<!-- ── Flagged Devices ── -->
<div id="flaggedSection" style="display:none">
  <div class="collapsible-hd" onclick="toggleSection('flaggedBd',this)">
    <span class="collapsible-hd-title">Devices with Security Issues (<span id="flaggedCount">0</span>)</span>
    <span class="collapsible-hd-caret">&#9660;</span>
  </div>
  <div id="flaggedBd" class="collapsible-bd">
  <div class="card" style="padding:0;overflow:hidden">
    <div style="padding:10px 16px 8px;display:flex;align-items:center;gap:10px;border-bottom:1px solid var(--border);background:#fafbfc;flex-wrap:wrap">
      <input id="flaggedSearch" class="tree-search" type="search" placeholder="Filter by name or serial…" style="margin:0;max-width:320px" oninput="filterFlagged(this)">
      <span style="font-size:.75rem;color:var(--muted)">Click a column header to sort</span>
      <button onclick="exportFlaggedCSV()" style="margin-left:auto;background:var(--blue);color:#fff;border:none;padding:5px 14px;border-radius:6px;font-size:.76rem;font-weight:600;cursor:pointer">&#11015; Export CSV</button>
    </div>
    <div style="overflow-x:auto">
      <table class="data-table" id="flaggedTable">
        <thead>
          <tr>
            <th style="cursor:pointer" onclick="sortFlagged('name')">Device ↕</th>
            <th style="cursor:pointer" onclick="sortFlagged('serial')">Serial ↕</th>
            <th style="cursor:pointer" onclick="sortFlagged('os')">macOS ↕</th>
            <th style="text-align:center">FileVault</th>
            <th style="text-align:center">Gatekeeper</th>
            <th style="text-align:center">SIP</th>
            <th style="text-align:center">Firewall</th>
            <th>Link</th>
          </tr>
        </thead>
        <tbody id="flaggedBody"></tbody>
      </table>
    </div>
  </div>
  </div>
</div>

<!-- ── Organisation + Enrollment ── -->
<div class="collapsible-hd" onclick="toggleSection('orgBd',this)">
  <span class="collapsible-hd-title">Organisation &amp; Enrollment</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="orgBd" class="collapsible-bd">
<div class="grid grid-3">

  <div class="card card-sm">
    <div class="section-header"><span class="section-title" style="margin:0">Organisation</span></div>
    <table class="data-table">
      <tbody id="orgTable">
        <tr class="exp-row" onclick="toggleExp('sitesExp',this)">
          <td><span class="exp-caret">▶</span>Sites</td>
          <td class="val">${SITES_COUNT}</td>
        </tr>
        <tbody class="exp-children" id="sitesExp"></tbody>
        <tr class="exp-row" onclick="toggleExp('bldgExp',this)">
          <td><span class="exp-caret">▶</span>Buildings</td>
          <td class="val">${BUILDINGS_COUNT}</td>
        </tr>
        <tbody class="exp-children" id="bldgExp"></tbody>
        <tr class="exp-row" onclick="toggleExp('deptExp',this)">
          <td><span class="exp-caret">▶</span>Departments</td>
          <td class="val">${DEPT_COUNT}</td>
        </tr>
        <tbody class="exp-children" id="deptExp"></tbody>
        <tr class="exp-row" onclick="toggleExp('catExp',this)">
          <td><span class="exp-caret">▶</span>Categories</td>
          <td class="val">${CAT_COUNT}</td>
        </tr>
        <tbody class="exp-children" id="catExp"></tbody>
        <tr><td>LDAP / IdP Servers</td><td class="val">${LDAP_SERVERS}</td></tr>
        <tr><td>Webhooks</td><td class="val">${WEBHOOKS}</td></tr>
      </tbody>
    </table>
  </div>

  <div class="card card-sm">
    <div class="section-header"><span class="section-title" style="margin:0">Enrollment</span></div>
    <table class="data-table">
      <tbody>
        <tr class="exp-row" onclick="toggleExp('adeExp',this)">
          <td><span class="exp-caret">▶</span>ADE Instances</td>
          <td class="val">${ADE_INSTANCES}</td>
        </tr>
        <tbody class="exp-children" id="adeExp"></tbody>
        <tr><td><a href="${CONSOLE_URL}/computerEnrollmentPrestage.html" target="_blank" style="color:inherit">Computer Prestages</a></td><td class="val">${COMP_PRESTAGES}</td></tr>
        <tr><td><a href="${CONSOLE_URL}/mobileDevicePrestage.html" target="_blank" style="color:inherit">Mobile Prestages</a></td><td class="val">${MD_PRESTAGES}</td></tr>
        <tr><td><a href="${CONSOLE_URL}/view/settings/global-management/volume-purchasing" target="_blank" style="color:inherit">VPP Locations</a></td><td class="val">${VPP_LOCATIONS}</td></tr>
        <tr><td>iOS Config Profiles</td><td class="val">${IOS_PROF_COUNT}</td></tr>
        <tr><td>Mobile Smart Groups</td><td class="val">${MD_SMART}</td></tr>
      </tbody>
    </table>
  </div>

  <div class="card card-sm">
    <div class="section-header"><span class="section-title" style="margin:0">Configuration</span></div>
    <table class="data-table">
      <tbody>
        <tr><td>App Installers</td><td class="val">${APP_INSTALLERS}</td></tr>
        <tr><td>Patch Titles</td><td class="val">${PATCH_TITLES}</td></tr>
        <tr><td>JCDS Files</td><td class="val">${JCDS_FILES}</td></tr>
        <tr><td><a href="${CONSOLE_URL}/eBooks.html" target="_blank" style="color:inherit">eBooks</a></td><td class="val">${EBOOKS}</td></tr>
        <tr><td><a href="${CONSOLE_URL}/view/settings/global-management/mdm-profile-settings" target="_blank" style="color:inherit">MDM Auto Renew (Comp)</a></td><td class="val">${MDM_RENEW_COMP}</td></tr>
        <tr><td><a href="${CONSOLE_URL}/view/settings/global-management/mdm-profile-settings" target="_blank" style="color:inherit">MDM Auto Renew (Mobile)</a></td><td class="val">${MDM_RENEW_MD}</td></tr>
      </tbody>
    </table>
  </div>

</div>
</div>

<!-- ── Features ── -->
<div class="collapsible-hd" onclick="toggleSection('featuresBd',this)">
  <span class="collapsible-hd-title">Enabled Features</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="featuresBd" class="collapsible-bd">
<div class="card" style="padding:0">
  <div class="feat-grid" id="featGrid"></div>
</div>
</div>

<!-- ── Deployment Hierarchy ── -->
<div class="collapsible-hd" onclick="toggleSection('hierarchyBd',this)">
  <span class="collapsible-hd-title">Deployment Hierarchy</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="hierarchyBd" class="collapsible-bd">
<div class="card" style="padding:0">

  <div class="tree-tabs">
    <span class="tree-tab active" onclick="showTab('tab-pol',this)">Policies (${POLICIES_COUNT})</span>
    <span class="tree-tab" onclick="showTab('tab-mcp',this)">macOS Profiles (${MACOS_PROF_COUNT})</span>
    <span class="tree-tab" onclick="showTab('tab-icp',this)">iOS Profiles (${IOS_PROF_COUNT})</span>
    <span class="tree-tab" onclick="showTab('tab-scr',this)">Scripts (${SCRIPTS_COUNT})</span>
    <span class="tree-tab" onclick="showTab('tab-sg',this)">Smart Groups (${COMP_SMART})</span>
    <span class="tree-tab" onclick="showTab('tab-cu',this)">Cleanup (${CLEANUP_LABEL})</span>
  </div>

  <!-- Policies by Scope -->
  <div class="tree-pane active" id="tab-pol">
    <input class="tree-search" type="search" placeholder="Search policies…" oninput="filterTree(this,'pol-tree')">
    <div class="tree-summary" id="pol-summary"></div>
    <div id="pol-tree"></div>
  </div>

  <!-- macOS Profiles by Scope -->
  <div class="tree-pane" id="tab-mcp">
    <input class="tree-search" type="search" placeholder="Search macOS profiles…" oninput="filterTree(this,'mcp-tree')">
    <div class="tree-summary" id="mcp-summary"></div>
    <div id="mcp-tree"></div>
  </div>

  <!-- iOS Profiles by Scope -->
  <div class="tree-pane" id="tab-icp">
    <input class="tree-search" type="search" placeholder="Search iOS profiles…" oninput="filterTree(this,'icp-tree')">
    <div class="tree-summary" id="icp-summary"></div>
    <div id="icp-tree"></div>
  </div>

  <!-- Scripts by Category -->
  <div class="tree-pane" id="tab-scr">
    <input class="tree-search" type="search" placeholder="Search scripts…" oninput="filterTree(this,'scr-tree')">
    <div class="tree-summary" id="scr-summary"></div>
    <div id="scr-tree"></div>
  </div>

  <!-- Smart Groups list -->
  <div class="tree-pane" id="tab-sg">
    <input class="tree-search" type="search" placeholder="Search smart groups…" oninput="filterSG(this)">
    <div class="tree-summary" id="sg-summary"></div>
    <div id="sg-list"></div>
  </div>

  <!-- Cleanup candidates — disabled policies, unscoped policies/profiles -->
  <div class="tree-pane" id="tab-cu">
    <input class="tree-search" type="search" placeholder="Search cleanup items…" oninput="filterCleanup(this)">
    <div class="tree-summary" id="cu-summary"></div>
    <div class="cu-section">
      <div class="cu-section-hdr">Disabled Policies <span class="cu-badge cu-err" id="cu-disabled-count">0</span></div>
      <div id="cu-disabled" style="padding:4px 10px"></div>
    </div>
    <div class="cu-section">
      <div class="cu-section-hdr">Policies with No Scope <span class="cu-badge cu-warn" id="cu-noscope-pol-count">0</span></div>
      <div id="cu-noscope-pol" style="padding:4px 10px"></div>
    </div>
    <div class="cu-section">
      <div class="cu-section-hdr">macOS Profiles with No Scope <span class="cu-badge cu-warn" id="cu-noscope-prof-count">0</span></div>
      <div id="cu-noscope-prof" style="padding:4px 10px"></div>
    </div>
    <div class="cu-section">
      <div class="cu-section-hdr">Unused Packages <span class="cu-badge cu-warn" id="cu-unused-pkg-count">0</span></div>
      <div id="cu-unused-pkg" style="padding:4px 10px"></div>
    </div>
    <div class="cu-section">
      <div class="cu-section-hdr">Unused Scripts <span class="cu-badge cu-warn" id="cu-unused-scr-count">0</span></div>
      <div id="cu-unused-scr" style="padding:4px 10px"></div>
    </div>
  </div>

</div>
</div>

<!-- ── Full Instance Overview ── -->
<div class="collapsible-hd" onclick="toggleSection('overviewBd',this)">
  <span class="collapsible-hd-title">Full Instance Overview</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="overviewBd" class="collapsible-bd">
<div class="card" style="padding:0;overflow:hidden">
  <table class="data-table" id="overviewTable">
    <thead><tr><th>Section</th><th>Resource</th><th class="val">Value</th></tr></thead>
    <tbody></tbody>
  </table>
</div>
</div>

<!-- ── Quick Links ── -->
<div class="collapsible-hd" onclick="toggleSection('quicklinksBd',this)">
  <span class="collapsible-hd-title">Quick Links — Jamf Pro Console</span>
  <span class="collapsible-hd-caret">&#9660;</span>
</div>
<div id="quicklinksBd" class="collapsible-bd">
<div class="links-grid">
  <a class="link-card" href="${CONSOLE_URL}/computers.html"               target="_blank"><span class="link-icon">💻</span>Computers</a>
  <a class="link-card" href="${CONSOLE_URL}/mobileDevices.html"           target="_blank"><span class="link-icon">📱</span>Mobile Devices</a>
  <a class="link-card" href="${CONSOLE_URL}/policies.html"                target="_blank"><span class="link-icon">📋</span>Policies</a>
  <a class="link-card" href="${CONSOLE_URL}/OSXConfigurationProfiles.html" target="_blank"><span class="link-icon">🛡️</span>macOS Profiles</a>
  <a class="link-card" href="${CONSOLE_URL}/mobileDeviceConfigurationProfiles.html" target="_blank"><span class="link-icon">🛡️</span>iOS Profiles</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/computer-management/packages" target="_blank"><span class="link-icon">📦</span>Packages</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/computer-management/scripts"  target="_blank"><span class="link-icon">⚙️</span>Scripts</a>
  <a class="link-card" href="${CONSOLE_URL}/smartComputerGroups.html"     target="_blank"><span class="link-icon">🏷️</span>Smart Groups</a>
  <a class="link-card" href="${CONSOLE_URL}/staticComputerGroups.html"    target="_blank"><span class="link-icon">📂</span>Static Groups</a>
  <a class="link-card" href="${CONSOLE_URL}/categories.html"              target="_blank"><span class="link-icon">🗂️</span>Categories</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/network-organization/departments" target="_blank"><span class="link-icon">🏢</span>Departments</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/network-organization/buildings"   target="_blank"><span class="link-icon">🏗️</span>Buildings</a>
  <a class="link-card" href="${CONSOLE_URL}/notifications.html"           target="_blank"><span class="link-icon">🔔</span>Notifications</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/system-settings/activation-code" target="_blank"><span class="link-icon">🪪</span>Licensing</a>
  <a class="link-card" href="${CONSOLE_URL}/advancedComputerSearches.html" target="_blank"><span class="link-icon">🔍</span>Adv. Searches</a>
  <a class="link-card" href="${CONSOLE_URL}/patch.html"                                                                      target="_blank"><span class="link-icon">🩹</span>Patch Management</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/system-settings/api-roles-and-clients?tab=api-roles"  target="_blank"><span class="link-icon">🔑</span>API Roles</a>
  <a class="link-card" href="${CONSOLE_URL}/view/settings/computer-management/check-in"                         target="_blank"><span class="link-icon">📡</span>Check-In Settings</a>
</div>
</div>

<div class="footer">
  Generated by jamf-cli ${CLI_VER} &nbsp;·&nbsp; jamf-report.sh v${SCRIPT_VERSION}
  &nbsp;·&nbsp; <a href="https://github.com/Jamf-Concepts/jamf-cli" target="_blank">github.com/Jamf-Concepts/jamf-cli</a>
</div>

</div><!-- /page -->

<script>
// ── Embedded data ────────────────────────────────────────────────────────────
const policiesHier      = ${POL_HIER};
const macosProfilesHier = ${MCP_HIER};
const iosProfilesHier   = ${ICP_HIER};
const scriptsHier       = ${SCR_HIER};
const smartGroupsList   = ${SGR_LIST};
const osLabels          = ${OS_LABELS};
const osCounts          = ${OS_COUNTS};
const overviewSections  = ${OV_SECTIONS};
const flaggedDevices    = ${FLAGGED_JSON};
const consoleURL        = '${CONSOLE_URL}';
const adeList           = ${ADE_LIST};
const sitesList         = ${SITES_LIST};
const bldgList          = ${BLDG_LIST};
const deptList          = ${DEPT_LIST};
const catList           = ${CAT_LIST};
const historyData       = ${HISTORY_JSON};
const staleGroups       = ${STALE_GROUPS_JSON};
const cleanupRan             = ${RUN_CLEANUP};
const cleanupDisabled        = ${CLEANUP_DISABLED_POLICIES};
const cleanupNoScopePolicies = ${CLEANUP_NO_SCOPE_POLICIES};
const cleanupNoScopeProfiles = ${CLEANUP_NO_SCOPE_PROFILES};
const cleanupUnusedPackages  = ${CLEANUP_UNUSED_PACKAGES};
const cleanupUnusedScripts   = ${CLEANUP_UNUSED_SCRIPTS};
const patchStatusEnabled     = ${RUN_PATCH_STATUS};
const patchData              = ${PATCH_STATUS_JSON};
const profileStatusEnabled   = ${RUN_PROFILE_STATUS};
const profileStatusData      = ${PROFILE_STATUS_JSON};
const appStatusEnabled       = ${RUN_APP_STATUS};
const appStatusData          = ${APP_STATUS_JSON};
const updateStatusEnabled    = ${RUN_UPDATE_STATUS};
const updateStatusData       = ${UPDATE_STATUS_JSON};
const deviceComplianceEnabled = ${RUN_DEVICE_COMPLIANCE};
const deviceComplianceData   = ${DEVICE_COMPLIANCE_JSON};

// ── Chart.js — Security posture radar ────────────────────────────────────────
(function() {
    const ctx = document.getElementById('securityChart').getContext('2d');
    new Chart(ctx, {
        type: 'radar',
        data: {
            labels: ['FileVault', 'Gatekeeper', 'SIP', 'Firewall'],
            datasets: [{
                label: 'Enabled %',
                data: [${FV_VAL}, ${GK_VAL}, ${SIP_VAL}, ${FW_VAL}],
                backgroundColor: 'rgba(0,118,182,0.12)',
                borderColor: '#0076B6',
                pointBackgroundColor: ['#22c55e','#0076B6','#8b5cf6','#f59e0b'],
                pointRadius: 5,
                borderWidth: 2
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                r: {
                    min: 0, max: 100,
                    ticks: { stepSize: 25, font: { size: 10 }, color: '#94a3b8' },
                    pointLabels: { font: { size: 11, weight: '600' } },
                    grid: { color: '#e2e8f0' }
                }
            },
            plugins: { legend: { display: false } }
        }
    });
})();

// ── Chart.js — OS Distribution donut ────────────────────────────────────────
(function() {
    if (!osLabels.length) return;
    const palette = [
        '#0076B6','#004165','#22c55e','#8b5cf6','#f59e0b','#06b6d4',
        '#ec4899','#84cc16','#f97316','#6366f1','#14b8a6','#e11d48'
    ];
    const ctx = document.getElementById('osChart').getContext('2d');
    new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: osLabels,
            datasets: [{
                data: osCounts,
                backgroundColor: palette.slice(0, osLabels.length),
                borderWidth: 2,
                borderColor: '#fff'
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: '62%',
            plugins: {
                legend: {
                    position: 'right',
                    labels: { font: { size: 10 }, boxWidth: 12, padding: 8 }
                }
            }
        }
    });

    // Populate OS table
    const tbody = document.querySelector('#osTable tbody');
    const total = osCounts.reduce(function(a,b){return a+b;}, 0);
    osLabels.forEach(function(ver, i) {
        const pct = total > 0 ? ((osCounts[i] / total) * 100).toFixed(1) : '0.0';
        const colour = palette[i % palette.length];
        const tr = document.createElement('tr');
        tr.innerHTML =
            '<td><span class="os-dot" style="background:' + colour + '"></span>' + ver + '</td>' +
            '<td>' + osCounts[i] + '</td>' +
            '<td>' + pct + '%</td>';
        tbody.appendChild(tr);
    });
})();

// ── Full overview table ───────────────────────────────────────────────────────
(function() {
    // Map overview resource names to their Jamf Pro console URLs.
    // Paths are relative to CONSOLE_URL (injected by the shell at report generation time).
    const base = '${CONSOLE_URL}';
    const resourceLinks = {
        // Fleet
        'Managed Computers':          base + '/computers.html',
        'Unmanaged Computers':         base + '/computers.html',
        'Managed Devices':             base + '/mobileDevices.html',
        'Unmanaged Devices':           base + '/mobileDevices.html',
        // Configuration
        'Policies':                    base + '/policies.html',
        'macOS Config Profiles':       base + '/OSXConfigurationProfiles.html',
        'iOS Config Profiles':         base + '/mobileDeviceConfigurationProfiles.html',
        'Packages':                    base + '/view/settings/computer-management/packages',
        'Scripts':                     base + '/view/settings/computer-management/scripts',
        'App Installers':              base + '/app-installers.html',
        'Patch Titles':                base + '/patch.html',
        'eBooks':                      base + '/eBooks.html',
        'Webhooks':                    base + '/webhooks.html',
        // Organization
        'Sites':                       base + '/sites.html',
        'Buildings':                   base + '/view/settings/network-organization/buildings',
        'Departments':                 base + '/view/settings/network-organization/departments',
        'Categories':                  base + '/categories.html',
        'Computer Smart Groups':       base + '/smartComputerGroups.html',
        'Computer Static Groups':      base + '/staticComputerGroups.html',
        'Mobile Smart Groups':         base + '/smartMobileDeviceGroups.html',
        'Mobile Static Groups':        base + '/staticMobileDeviceGroups.html',
        'Static User Groups':          base + '/staticUserGroups.html',
        // Enrollment & Certificates
        'ADE Instances':               base + '/deviceEnrollmentProgram.html',
        'ADE Sync Status':             base + '/deviceEnrollmentProgram.html',
        'Computer Prestages':          base + '/computerPrestages.html',
        'Mobile Device Prestages':     base + '/mobileDevicePrestages.html',
        'VPP Locations':               base + '/volumePurchaseProgram.html',
        'APNs Certificate':            base + '/apns.html',
        'Built-in CA Expires':         base + '/view/settings/pki/certificate-authority',
        // Health & Alerts
        'Active Alerts':               base + '/notifications.html',
        'Alert Types':                 base + '/notifications.html',
        'Health Status':               base + '/healthCheck.html',
        // Security / Settings
        'LAPS Auto Deploy':            base + '/view/settings/computer-management/security',
        'LAPS Auto Rotate':            base + '/view/settings/computer-management/security',
        'MDM Auto Renew (Computers)':  base + '/view/settings/global-management/mdm-profile-settings',
        'MDM Auto Renew (Mobile)':     base + '/view/settings/global-management/mdm-profile-settings',
        'Admin SSO':                   base + '/view/settings/system-settings/sso',
        'SSO (SAML)':                  base + '/view/settings/system-settings/sso',
        'SMTP':                        base + '/view/settings/system-settings/smtp-server',
        'LDAP/IdP Servers':            base + '/ldapServers.html',
        // Features
        'Volume Purchasing':           base + '/volumePurchaseProgram.html',
        'Automated Device Enrollment': base + '/deviceEnrollmentProgram.html',
        'Patch Management':            base + '/patch.html',
    };

    const tbody = document.querySelector('#overviewTable tbody');
    if (!overviewSections.length) {
        const tr = document.createElement('tr');
        tr.innerHTML = '<td colspan="3" style="text-align:center;color:#94a3b8;padding:20px">No overview data available</td>';
        tbody.appendChild(tr);
        return;
    }
    overviewSections.forEach(function(sec) {
        sec.items.forEach(function(item, idx) {
            const tr = document.createElement('tr');
            const secCell = idx === 0
                ? '<td rowspan="' + sec.items.length + '" style="font-weight:700;color:var(--blue-dark);vertical-align:top;padding-top:10px">' + sec.section + '</td>'
                : '';
            const valClass = item.status === 'red' ? 'val val-err'
                           : item.status === 'yellow' ? 'val val-warn'
                           : 'val';
            // Wrap resource label in a link if we have a URL for it
            const url = resourceLinks[item.resource];
            const resourceCell = url
                ? '<a href="' + url + '" target="_blank" style="color:var(--blue);font-weight:500">' + escHtml(item.resource || '') + ' ↗</a>'
                : escHtml(item.resource || '');
            tr.innerHTML = secCell +
                '<td>' + resourceCell + '</td>' +
                '<td class="' + valClass + '">' + escHtml(item.value || '') + '</td>';
            tbody.appendChild(tr);
        });
        // Spacer row
        const spacer = document.createElement('tr');
        spacer.innerHTML = '<td colspan="3" style="padding:2px;background:#f8fafc"></td>';
        tbody.appendChild(spacer);
    });
})();

// ── Enabled Features pills (populated from live overview data) ────────────────
(function() {
    var grid = document.getElementById('featGrid');
    if (!grid) return;
    var targetSections = { 'Features': true, 'Security': true };
    var icons = {
        'Volume Purchasing':           '📦',
        'Automated Device Enrollment': '📲',
        'Cloud Distribution':          '☁️',
        'Patch Management':            '🩹',
        'SSO (SAML)':                  '🔑',
        'SMTP':                        '✉️',
        'Admin SSO':                   '🔐',
        'LAPS Auto Deploy':            '🔏',
        'LAPS Auto Rotate':            '🔄',
        'MDM Auto Renew (Computers)':  '🖥️',
        'MDM Auto Renew (Mobile)':     '📱',
        'Self Service Login':          '🏠',
        'CSA Scopes':                  '🔗',
        'App Installers':              '🛒',
        'Webhooks':                    '🪝',
    };
    var added = 0;
    overviewSections.forEach(function(sec) {
        if (!targetSections[sec.section]) return;
        sec.items.forEach(function(item) {
            var val = (item.value || '').trim();
            if (!val) return;
            var lval = val.toLowerCase();
            var isOn  = lval.indexOf('enabled') >= 0 || lval === 'ok';
            var isOff = lval.indexOf('disabled') >= 0 || lval === 'false' || lval === 'n/a';
            var cls   = isOn ? 'feat-on' : isOff ? 'feat-off' : '';
            var pill  = document.createElement('span');
            pill.className = 'feat-pill ' + cls;
            pill.textContent = (icons[item.resource] || '⚙️') + ' ' + item.resource + ' — ' + val;
            grid.appendChild(pill);
            added++;
        });
    });
    if (!added) {
        grid.style.padding = '14px';
        grid.innerHTML = '<span style="color:var(--muted);font-style:italic;font-size:.82rem">No feature data available</span>';
    }
})();

// ── Expandable org/enrollment dropdowns ────────────────────────────────────
(function() {
    // Map of tbody id → array of name strings (or {name, id} objects for ADE)
    var expData = {
        sitesExp: sitesList,
        bldgExp:  bldgList,
        deptExp:  deptList,
        catExp:   catList,
        adeExp:   adeList.map(function(a){ return typeof a === 'object' ? a.name : a; })
    };
    Object.keys(expData).forEach(function(id) {
        var tbody = document.getElementById(id);
        if (!tbody) return;
        var items = expData[id];
        if (!items.length) {
            var tr = document.createElement('tr');
            tr.className = 'exp-child';
            tr.innerHTML = '<td colspan="2" style="color:#94a3b8;font-style:italic">No data fetched</td>';
            tbody.appendChild(tr);
            return;
        }
        items.forEach(function(name) {
            var tr = document.createElement('tr');
            tr.className = 'exp-child';
            tr.innerHTML = '<td colspan="2">' + escHtml(String(name)) + '</td>';
            tbody.appendChild(tr);
        });
    });
})();

window.toggleExp = function(id, rowEl) {
    var tbody  = document.getElementById(id);
    var caret  = rowEl.querySelector('.exp-caret');
    if (!tbody) return;
    var open = tbody.classList.toggle('open');
    if (caret) caret.classList.toggle('open', open);
};

// ── Flagged Devices table ────────────────────────────────────────────────────
(function() {
    if (!flaggedDevices.length) return;
    document.getElementById('flaggedSection').style.display = '';
    document.getElementById('flaggedCount').textContent = flaggedDevices.length;

    var currentData = flaggedDevices.slice();
    var sortCol = 'name';
    var sortAsc = true;

    function secIcon(val, goodVals, badVals) {
        var s = String(val || '');
        if (!s || s === 'null') return '<span style="color:#94a3b8">—</span>';
        var isGood = goodVals.some(function(g){ return s === g; });
        var isBad  = badVals.some(function(b){ return s === b; });
        if (isGood) return '<span style="color:#15803d;font-weight:600">' + s + ' ✓</span>';
        if (isBad)  return '<span style="color:#991b1b;font-weight:600">' + s + ' ✗</span>';
        return '<span style="color:#92400e;font-weight:600">' + s + '</span>';
    }
    function fwIcon(val) {
        if (val === true)  return '<span style="color:#15803d;font-weight:600">Enabled ✓</span>';
        if (val === false) return '<span style="color:#991b1b;font-weight:600">Disabled ✗</span>';
        return '<span style="color:#94a3b8">—</span>';
    }

    function render(data) {
        var tbody = document.getElementById('flaggedBody');
        tbody.innerHTML = '';
        if (!data.length) {
            tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;color:#94a3b8;padding:16px">No matching devices</td></tr>';
            return;
        }
        data.forEach(function(d) {
            var deviceLink = consoleURL + '/computers.html?query=' + encodeURIComponent(d.serial || d.name || '') + '&queryType=COMPUTERS&version=';
            var tr = document.createElement('tr');
            tr.innerHTML =
                '<td style="font-weight:600">' + escHtml(d.name || '') + '</td>' +
                '<td style="font-family:monospace;font-size:.78rem">' + escHtml(d.serial || '') + '</td>' +
                '<td>' + escHtml(d.os || '') + '</td>' +
                '<td style="text-align:center">' + secIcon(d.filevault,   ['ENCRYPTED'],            ['UNENCRYPTED','NOT ENCRYPTING']) + '</td>' +
                '<td style="text-align:center">' + secIcon(d.gatekeeper, ['APP_STORE_AND_IDENTIFIED_DEVELOPERS','GatekeeperEnabled','Enabled'], ['DISABLED','Disabled']) + '</td>' +
                '<td style="text-align:center">' + secIcon(d.sip,        ['ENABLED','Enabled'],     ['DISABLED','Disabled']) + '</td>' +
                '<td style="text-align:center">' + fwIcon(d.firewall) + '</td>' +
                '<td><a href="' + deviceLink + '" target="_blank" style="font-size:.75rem;color:var(--blue)">Open ↗</a></td>';
            tbody.appendChild(tr);
        });
    }

    window.sortFlagged = function(col) {
        if (sortCol === col) { sortAsc = !sortAsc; } else { sortCol = col; sortAsc = true; }
        currentData.sort(function(a, b) {
            var av = String(a[col] || '').toLowerCase();
            var bv = String(b[col] || '').toLowerCase();
            return sortAsc ? av.localeCompare(bv) : bv.localeCompare(av);
        });
        render(currentData);
    };

    window.filterFlagged = function(input) {
        var q = input.value.toLowerCase().trim();
        currentData = q
            ? flaggedDevices.filter(function(d){
                return (d.name  || '').toLowerCase().includes(q) ||
                       (d.serial|| '').toLowerCase().includes(q) ||
                       (d.os    || '').toLowerCase().includes(q);
              })
            : flaggedDevices.slice();
        render(currentData);
    };

    render(currentData);
})();

// ── Deployment Tree builder ───────────────────────────────────────────────────
function buildTree(containerId, summaryId, hierData) {
    const container = document.getElementById(containerId);
    const summary   = document.getElementById(summaryId);
    if (!hierData.length) {
        container.innerHTML = '<p style="color:#94a3b8;padding:10px;font-size:.8rem">No data available — ensure jamf-cli can list this resource.</p>';
        return;
    }
    const totalItems = hierData.reduce(function(sum, c){ return sum + c.count; }, 0);
    const totalCats  = hierData.length;
    summary.textContent = totalCats + ' categories  ·  ' + totalItems + ' items total';

    hierData.forEach(function(cat) {
        const node  = document.createElement('div');
        node.className = 'cat-node';

        const toggle = document.createElement('div');
        toggle.className = 'cat-toggle';
        toggle.innerHTML =
            '<span class="cat-caret">▶</span>' +
            '<span class="cat-name">' + escHtml(cat.category) + '</span>' +
            '<span class="cat-badge">' + cat.count + '</span>';

        const children = document.createElement('div');
        children.className = 'cat-children';

        cat.items.forEach(function(name) {
            const item = document.createElement('div');
            item.className = 'item-node';
            item.dataset.name = name.toLowerCase();
            item.textContent = name;
            children.appendChild(item);
        });

        toggle.addEventListener('click', function() {
            const open = children.classList.toggle('open');
            toggle.querySelector('.cat-caret').classList.toggle('open', open);
        });

        node.appendChild(toggle);
        node.appendChild(children);
        container.appendChild(node);
    });
}

buildTree('pol-tree', 'pol-summary', policiesHier);
buildTree('mcp-tree', 'mcp-summary', macosProfilesHier);
buildTree('icp-tree', 'icp-summary', iosProfilesHier);
buildTree('scr-tree', 'scr-summary', scriptsHier);

// ── Smart groups list ─────────────────────────────────────────────────────────
(function() {
    const container = document.getElementById('sg-list');
    const summary   = document.getElementById('sg-summary');
    summary.textContent = smartGroupsList.length + ' smart groups';
    if (!smartGroupsList.length) {
        container.innerHTML = '<p style="color:#94a3b8;padding:10px;font-size:.8rem">No smart groups found.</p>';
        return;
    }
    smartGroupsList.forEach(function(sg) {
        const node = document.createElement('div');
        node.className = 'sg-node';
        node.dataset.name = (sg.name || '').toLowerCase();
        node.innerHTML =
            '<span class="sg-name">' + escHtml(sg.name || 'Unnamed') + '</span>' +
            (sg.id ? '<span class="sg-id">ID ' + sg.id + '</span>' : '');
        container.appendChild(node);
    });
})();

// ── Patch Compliance table ────────────────────────────────────────────────────
(function() {
    if (!patchStatusEnabled || !patchData.length) return;
    document.getElementById('patchSection').style.display = 'block';

    // Summary metrics
    document.getElementById('patch-title-count').textContent = patchData.length;
    var hasPct = patchData.filter(function(r) { return r.total > 0 && r.compliance_pct !== 'N/A'; });
    if (hasPct.length) {
        var numSum = hasPct.reduce(function(a, r) { return a + (r.on_latest || 0); }, 0);
        var denSum = hasPct.reduce(function(a, r) { return a + (r.total || 0); }, 0);
        document.getElementById('patch-avg').textContent = denSum ? Math.round(numSum / denSum * 100) + '%' : 'N/A';
    }
    var below = patchData.filter(function(r) { return r.compliance_pct !== 'N/A' && parseInt(r.compliance_pct) < 80; });
    document.getElementById('patch-below-threshold').textContent = below.length;

    function pctNum(s) { return (s === 'N/A' || s == null) ? -1 : parseInt(s) || 0; }

    var sortCol = 'compliance_pct';
    var sortAsc = true;  // ascending = worst first by default
    var currentData = patchData.slice().sort(function(a, b) { return pctNum(a.compliance_pct) - pctNum(b.compliance_pct); });

    function renderPatch(data) {
        var tbody = document.getElementById('patchBody');
        tbody.innerHTML = '';
        if (!data.length) {
            tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:16px">No patch titles found.</td></tr>';
            return;
        }
        data.forEach(function(r) {
            var pct = pctNum(r.compliance_pct);
            var cls = pct < 0 ? '' : pct < 50 ? 'val-err' : pct < 80 ? 'val-warn' : 'val-ok';
            var tr = document.createElement('tr');
            tr.dataset.title = (r.title || '').toLowerCase();
            tr.innerHTML =
                '<td>' + escHtml(r.title || '') + '</td>' +
                '<td class="val ' + cls + '">' + escHtml(r.compliance_pct || 'N/A') + '</td>' +
                '<td class="val">' + (r.on_latest || 0) + '</td>' +
                '<td class="val">' + (r.on_other || 0) + '</td>' +
                '<td class="val">' + (r.total || 0) + '</td>' +
                '<td style="font-size:.76rem;color:var(--muted)">' + escHtml(r.latest || '') + '</td>';
            tbody.appendChild(tr);
        });
    }
    renderPatch(currentData);

    window.sortPatch = function(col) {
        if (sortCol === col) { sortAsc = !sortAsc; } else { sortCol = col; sortAsc = (col === 'title'); }
        currentData.sort(function(a, b) {
            var av, bv;
            if (col === 'title') {
                av = (a.title || '').toLowerCase(); bv = (b.title || '').toLowerCase();
                return sortAsc ? av.localeCompare(bv) : bv.localeCompare(av);
            }
            av = (col === 'compliance_pct') ? pctNum(a[col]) : (a[col] || 0);
            bv = (col === 'compliance_pct') ? pctNum(b[col]) : (b[col] || 0);
            return sortAsc ? av - bv : bv - av;
        });
        renderPatch(currentData);
    };

    window.filterPatch = function(input) {
        var q = input.value.toLowerCase().trim();
        document.querySelectorAll('#patchBody tr').forEach(function(tr) {
            tr.classList.toggle('item-hidden', q !== '' && !(tr.dataset.title || '').includes(q));
        });
    };
})();

// ── Profile Status failures table ─────────────────────────────────────────────
(function() {
    if (!profileStatusEnabled) return;
    var failures = (profileStatusData && profileStatusData.failures) || [];
    var summary  = (profileStatusData && profileStatusData.summary)  || {};
    document.getElementById('profileStatusSection').style.display = 'block';
    document.getElementById('ps-days').textContent     = (summary.days || '—') + 'd';
    document.getElementById('ps-profiles').textContent = summary.unique_profiles != null ? summary.unique_profiles : failures.length;
    document.getElementById('ps-devices').textContent  = summary.unique_devices  != null ? summary.unique_devices  : '—';
    document.getElementById('ps-errors').textContent   = summary.total_errors    != null ? summary.total_errors    : '—';

    var tbody = document.getElementById('psBody');
    if (!failures.length) {
        tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:16px">No profile failures in the selected period.</td></tr>';
        return;
    }
    failures.forEach(function(r) {
        var tr = document.createElement('tr');
        tr.innerHTML =
            '<td>' + escHtml(r.name || '') + '</td>' +
            '<td style="font-size:.76rem">' + escHtml(r.device_type || '') + '</td>' +
            '<td class="val">' + (r.devices || 0) + '</td>' +
            '<td class="val val-err">' + (r.errors || 0) + '</td>' +
            '<td style="font-size:.76rem;white-space:nowrap">' + escHtml(r.last_error || '') + '</td>' +
            '<td style="font-size:.73rem;color:var(--muted)">' + escHtml(r.top_error || '') + '</td>';
        tbody.appendChild(tr);
    });
})();

// ── App Status failures table ─────────────────────────────────────────────────
(function() {
    if (!appStatusEnabled) return;
    var failures = (appStatusData && appStatusData.failures) || [];
    var summary  = (appStatusData && appStatusData.summary)  || {};
    document.getElementById('appStatusSection').style.display = 'block';
    document.getElementById('as-days').textContent        = (summary.days || '—') + 'd';
    document.getElementById('as-apps').textContent        = summary.unique_apps    != null ? summary.unique_apps    : failures.length;
    document.getElementById('as-devices').textContent     = summary.unique_devices != null ? summary.unique_devices : '—';
    document.getElementById('as-errors').textContent      = summary.total_errors   != null ? summary.total_errors   : '—';
    document.getElementById('as-high-failure').textContent= summary.devices_high_failure != null ? summary.devices_high_failure : '—';

    var tbody = document.getElementById('asBody');
    if (!failures.length) {
        tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:16px">No app failures in the selected period.</td></tr>';
        return;
    }
    failures.forEach(function(r) {
        var tr = document.createElement('tr');
        tr.innerHTML =
            '<td>' + escHtml(r.name || r.id || '') + '</td>' +
            '<td style="font-size:.76rem">' + escHtml(r.device_type || '') + '</td>' +
            '<td class="val">' + (r.devices || 0) + '</td>' +
            '<td class="val val-err">' + (r.errors || 0) + '</td>' +
            '<td style="font-size:.76rem;white-space:nowrap">' + escHtml(r.last_error || '') + '</td>' +
            '<td style="font-size:.73rem;color:var(--muted)">' + escHtml(r.top_error || '') + '</td>';
        tbody.appendChild(tr);
    });
})();

// ── Update Status plan-state grid ─────────────────────────────────────────────
(function() {
    if (!updateStatusEnabled) return;
    var plans   = (updateStatusData && updateStatusData.plan_state_summary) || [];
    var summary = updateStatusData || {};
    document.getElementById('updateStatusSection').style.display = 'block';

    function stateCount(name) {
        var s = plans.filter(function(p){ return p.state === name; });
        return s.length ? s[0].count : 0;
    }
    var failed    = stateCount('PlanFailed');
    var completed = stateCount('PlanCompleted');
    var exception = stateCount('PlanException');

    document.getElementById('us-total').textContent     = summary.plan_total || 0;
    document.getElementById('us-failed').textContent    = failed;
    document.getElementById('us-completed').textContent = completed;
    document.getElementById('us-exception').textContent = exception;

    // Render one pill per plan state
    var stateLabels = {
        PlanCompleted:              { label: 'Completed',              cls: 'badge-ok' },
        PlanFailed:                 { label: 'Failed',                 cls: 'badge-err' },
        PlanException:              { label: 'Exception',              cls: 'badge-warn' },
        PlanCanceled:               { label: 'Cancelled',              cls: 'badge-dim' },
        WaitingToStartDDMUpdate:    { label: 'Waiting for DDM Update', cls: 'badge-blue' },
        CollectingAvailableOSUpdates:{ label: 'Collecting OS Updates', cls: 'badge-blue' },
        SchedulingScanForOSUpdates: { label: 'Scheduling Scan',        cls: 'badge-dim' },
        UpToDate:                   { label: 'Up to Date',             cls: 'badge-ok' }
    };
    var grid = document.getElementById('usPlanGrid');
    plans.slice().sort(function(a,b){ return b.count - a.count; }).forEach(function(p) {
        var info = stateLabels[p.state] || { label: p.state, cls: 'badge-dim' };
        var card = document.createElement('div');
        card.style.cssText = 'background:var(--surface-2);border:1px solid var(--border);border-radius:8px;padding:12px 16px;display:flex;flex-direction:column;gap:4px';
        card.innerHTML =
            '<span class="badge ' + info.cls + '" style="align-self:flex-start;font-size:.67rem">' + escHtml(info.label) + '</span>' +
            '<span style="font-size:1.6rem;font-weight:700;color:var(--ink);line-height:1.1">' + p.count + '</span>' +
            '<span style="font-size:.71rem;color:var(--muted)">' + Math.round(p.count / (summary.plan_total||1) * 100) + '% of plans</span>';
        grid.appendChild(card);
    });
})();
(function() {
    if (!deviceComplianceEnabled || !deviceComplianceData.length) return;
    document.getElementById('deviceComplianceSection').style.display = 'block';

    var allData     = deviceComplianceData.slice();
    var staleCount  = allData.filter(function(d) { return d.stale; }).length;
    var threshold   = allData.length && allData[0].days_since_contact !== undefined
        ? Math.max.apply(null, allData.filter(function(d){ return d.stale; }).map(function(d){ return parseInt(d.days_since_contact)||0; }))
        : 14;

    document.getElementById('dc-total').textContent     = allData.length;
    document.getElementById('dc-stale').textContent     = staleCount;
    document.getElementById('dc-threshold').textContent = staleCount ? (threshold + 'd+') : '—';

    var sortCol = 'days_since_contact';
    var sortAsc = false; // worst first (most days = top)
    var currentData = allData.slice().sort(function(a, b) {
        return parseInt(b.days_since_contact || 0) - parseInt(a.days_since_contact || 0);
    });
    var searchQ = '';
    var staleOnly = false;

    function fmt(iso) {
        if (!iso) return '—';
        try { return new Date(iso).toLocaleDateString(undefined, {year:'numeric',month:'short',day:'numeric'}); } catch(e) { return iso; }
    }

    function renderDC(data) {
        var tbody = document.getElementById('dcBody');
        tbody.innerHTML = '';
        var visible = data.filter(function(d) {
            if (staleOnly && !d.stale) return false;
            if (searchQ && !(d.name || '').toLowerCase().includes(searchQ) && !(d.serial || '').toLowerCase().includes(searchQ)) return false;
            return true;
        });
        if (!visible.length) {
            tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:16px">No matching devices.</td></tr>';
            return;
        }
        visible.forEach(function(d) {
            var days = parseInt(d.days_since_contact) || 0;
            var badge = d.stale
                ? '<span class="badge badge-red" style="font-size:.7rem">Stale</span>'
                : '<span class="badge badge-green" style="font-size:.7rem">Active</span>';
            var daysCls = d.stale ? 'val val-err' : (days > 7 ? 'val val-warn' : 'val val-ok');
            var searchQuery = encodeURIComponent(d.serial || d.name || '');
            var openLink = d.stale
                ? '<a href="' + consoleURL + '/computers.html?query=' + searchQuery + '&queryType=COMPUTERS&version=" target="_blank" style="font-size:.75rem;color:var(--accent)">Open ↗</a>'
                : '<span style="color:var(--muted);font-size:.75rem">—</span>';
            var tr = document.createElement('tr');
            tr.innerHTML =
                '<td>' + escHtml(d.name || '') + '</td>' +
                '<td style="font-size:.76rem;font-family:monospace">' + escHtml(d.serial || '') + '</td>' +
                '<td class="' + daysCls + '">' + days + '</td>' +
                '<td style="font-size:.76rem;white-space:nowrap">' + fmt(d.last_contact) + '</td>' +
                '<td style="font-size:.76rem">' + escHtml(d.os_version || '') + '</td>' +
                '<td style="text-align:center">' + badge + '</td>' +
                '<td style="text-align:center">' + openLink + '</td>';
            tbody.appendChild(tr);
        });
    }
    renderDC(currentData);

    window.sortDC = function(col) {
        if (sortCol === col) { sortAsc = !sortAsc; } else { sortCol = col; sortAsc = (col === 'name'); }
        currentData.sort(function(a, b) {
            if (col === 'name') {
                var av = (a.name || '').toLowerCase(), bv = (b.name || '').toLowerCase();
                return sortAsc ? av.localeCompare(bv) : bv.localeCompare(av);
            }
            var av = parseInt(a.days_since_contact || 0), bv = parseInt(b.days_since_contact || 0);
            return sortAsc ? av - bv : bv - av;
        });
        renderDC(currentData);
    };

    window.filterDC = function() {
        staleOnly = document.getElementById('dc-stale-only').checked;
        renderDC(currentData);
    };

    window.filterDCSearch = function(input) {
        searchQ = input.value.toLowerCase().trim();
        renderDC(currentData);
    };
})();

// ── Cleanup candidates ────────────────────────────────────────────────────────
(function() {
    var summary = document.getElementById('cu-summary');
    if (!cleanupRan) {
        summary.textContent = 'Cleanup analysis was not run. Re-generate the report with --cleanup to enable.';
        return;
    }
    var total = cleanupDisabled.length + cleanupNoScopePolicies.length +
        cleanupNoScopeProfiles.length + cleanupUnusedPackages.length + cleanupUnusedScripts.length;
    summary.textContent = total + ' item' + (total !== 1 ? 's' : '') + ' flagged for cleanup review';
    function setCount(id, n) {
        var el = document.getElementById(id);
        if (el) el.textContent = n;
    }
    setCount('cu-disabled-count',      cleanupDisabled.length);
    setCount('cu-noscope-pol-count',   cleanupNoScopePolicies.length);
    setCount('cu-noscope-prof-count',  cleanupNoScopeProfiles.length);
    setCount('cu-unused-pkg-count',    cleanupUnusedPackages.length);
    setCount('cu-unused-scr-count',    cleanupUnusedScripts.length);
    function renderList(containerId, items, emptyMsg) {
        var container = document.getElementById(containerId);
        if (!container) return;
        if (!items.length) {
            container.innerHTML = '<p style="color:#94a3b8;padding:6px 2px;font-size:.8rem">' + emptyMsg + '</p>';
            return;
        }
        items.forEach(function(item) {
            var node = document.createElement('div');
            node.className = 'sg-node cu-item';
            node.dataset.name = (item.name || '').toLowerCase();
            node.innerHTML =
                '<span class="sg-name">' + escHtml(item.name || 'Unnamed') + '</span>' +
                (item.id ? '<span class="sg-id">ID\u00a0' + item.id + '</span>' : '');
            container.appendChild(node);
        });
    }
    renderList('cu-disabled',     cleanupDisabled,        'No disabled policies found.');
    renderList('cu-noscope-pol',  cleanupNoScopePolicies, 'No enabled policies without scope found.');
    renderList('cu-noscope-prof', cleanupNoScopeProfiles, 'No macOS profiles without scope found.');
    renderList('cu-unused-pkg',   cleanupUnusedPackages,  'No unassigned packages found.');
    renderList('cu-unused-scr',   cleanupUnusedScripts,   'No unused scripts found.');
})();

function filterCleanup(input) {
    var q = input.value.toLowerCase().trim();
    document.querySelectorAll('#tab-cu .cu-item').forEach(function(node) {
        node.classList.toggle('item-hidden', q !== '' && !node.dataset.name.includes(q));
    });
}

// ── Tree search filter ────────────────────────────────────────────────────────
function filterTree(input, treeId) {
    const q = input.value.toLowerCase().trim();
    const tree = document.getElementById(treeId);
    tree.querySelectorAll('.cat-node').forEach(function(catNode) {
        const items = catNode.querySelectorAll('.item-node');
        let catVisible = false;
        items.forEach(function(item) {
            const match = !q || item.dataset.name.includes(q);
            item.classList.toggle('item-hidden', !match);
            if (match) catVisible = true;
        });
        catNode.classList.toggle('item-hidden', !catVisible);
        if (q && catVisible) {
            catNode.querySelector('.cat-children').classList.add('open');
            catNode.querySelector('.cat-caret').classList.add('open');
        }
    });
}

function filterSG(input) {
    const q = input.value.toLowerCase().trim();
    document.querySelectorAll('#sg-list .sg-node').forEach(function(node) {
        node.classList.toggle('item-hidden', q && !node.dataset.name.includes(q));
    });
}

// ── Dark mode ─────────────────────────────────────────────────────────────────
(function() {
    var btn = document.getElementById('darkBtn');
    function applyDark(on) {
        document.body.classList.toggle('dark', on);
        if (btn) btn.textContent = on ? '☀️ Light' : '🌙 Dark';
        try { localStorage.setItem('jamfReportDark', on ? '1' : '0'); } catch(e){}
    }
    var saved = '';
    try { saved = localStorage.getItem('jamfReportDark'); } catch(e){}
    var prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    applyDark(saved !== null ? saved === '1' : prefersDark);
    window.toggleDark = function() { applyDark(!document.body.classList.contains('dark')); };
})();

// ── Tab switcher ──────────────────────────────────────────────────────────────
function showTab(id, el) {
    document.querySelectorAll('.tree-pane').forEach(function(p){ p.classList.remove('active'); });
    document.querySelectorAll('.tree-tab').forEach(function(t){ t.classList.remove('active'); });
    document.getElementById(id).classList.add('active');
    el.classList.add('active');
}

// ── Chart.js — macOS Adoption Timeline ───────────────────────────────────────
(function() {
    if (!historyData || historyData.length < 2) return;
    document.getElementById('adoptionSection').style.display = '';

    // Collect all unique normalised versions across all snapshots (newest first)
    var versionSet = {};
    historyData.forEach(function(snap) {
        (snap.versions || []).forEach(function(v) { versionSet[v.v] = true; });
    });
    var versions = Object.keys(versionSet).sort().reverse();

    // X-axis labels — format the ISO timestamp as "DD MMM YY"
    var labels = historyData.map(function(snap) {
        var d = new Date(snap.ts);
        return d.toLocaleDateString('en-GB', {day:'2-digit', month:'short', year:'2-digit'});
    });

    var palette = [
        '#0076B6','#22c55e','#8b5cf6','#f59e0b','#06b6d4',
        '#ec4899','#84cc16','#f97316','#6366f1','#14b8a6','#e11d48','#004165'
    ];

    var datasets = versions.map(function(ver, i) {
        return {
            label: 'macOS ' + ver,
            data: historyData.map(function(snap) {
                var entry = (snap.versions || []).filter(function(v){ return v.v === ver; })[0];
                return entry ? entry.c : 0;
            }),
            borderColor:     palette[i % palette.length],
            backgroundColor: palette[i % palette.length] + '18',
            pointRadius: 4,
            pointHoverRadius: 6,
            tension: 0.3,
            fill: false,
            borderWidth: 2
        };
    });

    new Chart(document.getElementById('adoptionChart').getContext('2d'), {
        type: 'line',
        data: { labels: labels, datasets: datasets },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            scales: {
                x: { ticks: { font: { size: 10 }, maxRotation: 45 } },
                y: {
                    beginAtZero: true,
                    ticks: { font: { size: 10 } },
                    title: { display: true, text: 'Devices', font: { size: 11 } }
                }
            },
            plugins: {
                legend: {
                    position: 'right',
                    labels: { font: { size: 10 }, boxWidth: 12, padding: 8 }
                },
                tooltip: {
                    callbacks: {
                        footer: function(items) {
                            var total = items.reduce(function(s, i) { return s + i.parsed.y; }, 0);
                            return 'Total in snapshot: ' + total;
                        }
                    }
                }
            }
        }
    });
})();

// ── Chart.js — Security Compliance Trend ─────────────────────────────────────
(function() {
    if (!historyData || historyData.length < 2) return;
    var hasSec = historyData.some(function(s) { return s.security && typeof s.security.compliance === 'number'; });
    if (!hasSec) return;
    document.getElementById('secTrendCard').style.display = '';

    var labels = historyData.map(function(snap) {
        var d = new Date(snap.ts);
        return d.toLocaleDateString('en-GB', {day:'2-digit', month:'short', year:'2-digit'});
    });
    var mk = function(label, key, color, width, fill) {
        return {
            label: label,
            data: historyData.map(function(s) { return s.security ? s.security[key] : null; }),
            borderColor: color,
            backgroundColor: fill ? color + '22' : 'transparent',
            fill: fill || false,
            tension: 0.3,
            borderWidth: width,
            pointRadius: 4,
            pointHoverRadius: 6
        };
    };
    new Chart(document.getElementById('secTrendChart').getContext('2d'), {
        type: 'line',
        data: { labels: labels, datasets: [
            mk('Overall Compliance', 'compliance', '#004165', 2.5, true),
            mk('FileVault',          'fv',         '#22c55e', 1.5, false),
            mk('Gatekeeper',         'gk',         '#0076B6', 1.5, false),
            mk('SIP',                'sip',        '#8b5cf6', 1.5, false),
            mk('Firewall',           'fw',         '#f59e0b', 1.5, false)
        ]},
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            scales: {
                x: { ticks: { font: { size: 10 }, maxRotation: 45 } },
                y: {
                    min: 0, max: 100,
                    ticks: { font: { size: 10 }, callback: function(v) { return v + '%'; } },
                    title: { display: true, text: 'Compliance %', font: { size: 11 } }
                }
            },
            plugins: { legend: { position: 'right', labels: { font: { size: 10 }, boxWidth: 12, padding: 8 } } }
        }
    });
})();

// ── Stale / At-risk Smart Groups ─────────────────────────────────────────────
(function() {
    var sec = document.getElementById('staleSection');
    if (!sec || !staleGroups || !staleGroups.length) return;
    sec.style.display = '';
    document.getElementById('staleCount').textContent = staleGroups.length;
    var list = document.getElementById('staleList');
    staleGroups.forEach(function(g) {
        var div = document.createElement('div');
        div.className = 'stale-item';
        div.innerHTML =
            '<span class="stale-dot"></span>' +
            '<span style="flex:1;font-weight:500">' + escHtml(g.name) + '</span>' +
            '<a href="' + consoleURL + '/smartComputerGroups.html" target="_blank" ' +
            'style="font-size:.72rem;color:var(--blue)">View in Jamf \u2197</a>';
        list.appendChild(div);
    });
})();

// ── CSV Export — Flagged Devices ──────────────────────────────────────────────
window.exportFlaggedCSV = function() {
    var rows = [['Device', 'Serial', 'macOS', 'FileVault', 'Gatekeeper', 'SIP', 'Firewall']];
    flaggedDevices.forEach(function(d) {
        var fw = d.firewall === true ? 'Enabled' : d.firewall === false ? 'Disabled' : '';
        rows.push([d.name || '', d.serial || '', d.os || '',
                   d.filevault || '', d.gatekeeper || '', d.sip || '', fw]);
    });
    var csv = rows.map(function(r) {
        return r.map(function(v) { return '"' + String(v).replace(/"/g, '""') + '"'; }).join(',');
    }).join('\r\n');
    var a = document.createElement('a');
    a.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
    a.download = 'flagged-devices-' + new Date().toISOString().slice(0,10) + '.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
};

// ── HTML escape helper ────────────────────────────────────────────────────────
function escHtml(s) {
    return String(s)
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;');
}

// ── Collapsible section toggle ────────────────────────────────────────────────
window.toggleSection = function(bodyId, hd) {
    var bd    = document.getElementById(bodyId);
    var caret = hd.querySelector('.collapsible-hd-caret');
    var hidden = bd.classList.toggle('hidden');
    if (caret) caret.classList.toggle('closed', hidden);
};

// ── Scroll-entry animations ───────────────────────────────────────────────────
(function() {
    if (!window.IntersectionObserver) return;
    var obs = new IntersectionObserver(function(entries) {
        entries.forEach(function(e) {
            if (e.isIntersecting) {
                e.target.classList.add('visible');
                obs.unobserve(e.target);
            }
        });
    }, { threshold: 0.08 });
    document.querySelectorAll('.card,.chart-card,.health-strip,.cover-block').forEach(function(el, i) {
        el.classList.add('fade-in');
        el.style.transitionDelay = (i * 40) + 'ms';
        obs.observe(el);
    });
})();
</script>
</body>
</html>
HTMLEOF

step "Report complete"
echo ""
echo "  ✓ Report saved to: $OUTPUT_FILE"

if [[ "$NO_OPEN" == false ]] && command -v open >/dev/null 2>&1; then
    echo "  Opening in default browser..."
    open "$OUTPUT_FILE"
fi

echo ""
