# Jamf Pro Instance Report Generator

Generates a comprehensive, self-contained HTML report for a Jamf Pro instance
using [jamf-cli](https://github.com/Jamf-Concepts/jamf-cli). All data is
collected via the Jamf Pro API through `jamf-cli`; no credentials are stored by
this script.

---

## Report Contents

| Section | Details |
|---------|---------|
| **Instance overview** | Server URL, Jamf Pro version, health status, active alerts, managed / unmanaged device counts, check-in frequency, DEP token expiry, built-in CA expiry |
| **Summary cards** | Policies, macOS profiles, iOS profiles, scripts, packages, categories, smart groups, sites, buildings, departments, ADE instances, VPP locations, app installers, webhooks, patch titles |
| **Security posture** | Animated gauge charts for FileVault, Gatekeeper, SIP and Firewall compliance percentages across all managed computers |
| **macOS version distribution** | Interactive donut chart showing device counts per OS version, newest-first, with `.0` patch variants normalised (e.g. `15.4.0` and `15.4` are merged) |
| **macOS adoption timeline** | Line chart showing how each macOS version's device count has grown or shrunk across multiple report runs over time. Only visible when 2 or more historical snapshots exist for this instance. Opt-in via `--track-history`. |
| **Flagged devices** | Searchable table of every device that fails at least one security check, showing name, serial, OS version and exactly which checks failed |
| **Deployment hierarchy** | Expandable tree grouped by category for policies, macOS config profiles, iOS config profiles and scripts |
| **Cleanup analysis** | Separate tab listing disabled policies, enabled policies with no scope, macOS profiles with no scope, unused packages and unused scripts. Opt-in via `--cleanup`. |
| **MDM profile failures** | Profiles that have generated `InstallProfile` command failures in the last N days, with per-profile device count, error count and top error message. Opt-in via `--profile-status`. Look-back window configurable via `--profile-days` (default: 30 days). |
| **MDM app deployment failures** | Apps that have generated `InstallApplication` / `InstallEnterpriseApplication` MDM command failures, with per-app device count, error count and top error. Highlights high-failure devices. Opt-in via `--app-status`. Look-back window configurable via `--app-days` (default: 30 days). |
| **Managed software update status** | Plan-state breakdown (Failed, Completed, Exception, Waiting for DDM Update, …) across all managed software update plans. Shown as a visual pill grid with percentages. Opt-in via `--update-status`. |
| **Device check-in compliance** | All managed devices with days since last check-in, stale status, OS version and last contact timestamp. Sortable/filterable table with a "Stale only" toggle. Opt-in via `--device-compliance`. Stale threshold configurable via `--checkin-days` (default: 90 days). |
| **Organisational structure** | Expandable dropdowns for smart groups, sites, buildings, departments and categories |
| **Self Service icon** | Automatically extracted from the local Self Service app (or supplied via environment variable) and embedded in the report header |
| **Dark-mode toggle** | One-click switch between light and dark themes, persisted to `localStorage` |
| **Self-contained output** | A single `.html` file — no external CSS, JavaScript or image dependencies |

---

## Requirements

| Tool | Version | Install |
|------|---------|---------|
| `jamf-cli` | ≥ 1.9.0 | `brew install Jamf-Concepts/tap/jamf-cli` |
| `jq` | ≥ 1.6 | `brew install jq` |
| `bash` | ≥ 3.2 | Ships with macOS |
| `base64` | any | Ships with macOS |
| `sips` | any | Ships with macOS (used for icon extraction) |
| `swiftDialog` | ≥ 2.5 | `brew install swiftDialog` — required only for `report-ui.zsh` |

See [requirements.txt](requirements.txt) for the full dependency list.

> **Jamf Pro permissions** — the API account used by `jamf-cli` needs at minimum
> read access to: Computers, Policies, Configuration Profiles, Scripts, Packages,
> Smart Computer Groups, Categories, Sites, Buildings, Departments, and the
> Security Report.

---

## Usage

```bash
./report.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `-p`, `--profile <name>` | jamf-cli profile to use (default: active profile) |
| `-o`, `--output <file>` | Output HTML file path (default: `jamf-report-TIMESTAMP.html`) |
| `-n`, `--no-open` | Do not auto-open the report in the browser after generation |
| `-t`, `--track-history` | Opt in to history tracking — saves a snapshot of the macOS version distribution to the history file after each run |
| `--history-file <path>` | Override the history file location (default: `~/.jamf-report.history.json`, or set `JAMF_REPORT_HISTORY_FILE`) |
| `-c`, `--cleanup` | Opt in to cleanup analysis — fetches full details for every policy and macOS profile to identify disabled policies, unscoped policies/profiles, unused packages and unused scripts. Adds one extra step to the run. |
| `--patch-status` | Opt in to patch title compliance data — adds a Patch Compliance section showing per-title compliance percentages, device counts and latest version. |
| `--profile-status` | Opt in to MDM profile failure reporting — adds a Profile Failures section showing every profile that generated an `InstallProfile` error in the look-back window. |
| `--profile-days <n>` | Look-back window for profile failures in days (default: `30`). Only used when `--profile-status` is passed. |
| `--app-status` | Opt in to MDM app deployment failure reporting — adds an App Status section showing apps with MDM install failures, device counts and top error messages. |
| `--app-days <n>` | Look-back window for app failures in days (default: `30`). Only used when `--app-status` is passed. |
| `--update-status` | Opt in to managed software update plan reporting — adds an Update Status section with a plan-state pill grid (Failed, Completed, Exception, etc.). |
| `--device-compliance` | Opt in to device check-in compliance — adds a section listing all managed devices with their last check-in date and stale status. |
| `--checkin-days <n>` | Number of days without a check-in before a device is marked stale (default: `90`). Only used when `--device-compliance` is passed. |
| `-h`, `--help` | Show help and exit |

**Examples:**

```bash
# Use the currently active jamf-cli profile, open on completion
./report.sh

# Target a specific profile, write to a fixed path, skip auto-open
./report.sh --profile prod --output /tmp/report.html --no-open

# Quick one-liner for download folder
./report.sh -o ~/Downloads/jamf-report.html

# Opt in to history tracking (run regularly — e.g. weekly via cron/launchd)
./report.sh --track-history

# Opt in to cleanup analysis (fetches per-object details — slower but thorough)
./report.sh --cleanup

# Combine cleanup, history tracking, and a specific profile
./report.sh --profile prod --cleanup --track-history --no-open -o ~/Downloads/report.html

# Add MDM profile failure report (last 30 days, default)
./report.sh --profile-status

# Narrow the failure look-back window to 7 days
./report.sh --profile-status --profile-days 7

# Add MDM app deployment failure report
./report.sh --app-status

# Narrow the app failure look-back window to 7 days
./report.sh --app-status --app-days 7

# Add managed software update plan state summary
./report.sh --update-status

# Add device check-in compliance (stale = not seen in 90 days, default)
./report.sh --device-compliance

# Tighten the stale threshold to 7 days
./report.sh --device-compliance --checkin-days 7

# Full report: everything enabled
./report.sh --profile prod --cleanup --track-history --patch-status --profile-status --app-status --update-status --device-compliance
```

---

## swiftDialog UI (`report-ui.zsh`)

`report-ui.zsh` is a [swiftDialog](https://github.com/swiftDialog/swiftDialog)
wrapper that presents a native macOS UI around `report.sh`. It replaces the
terminal entirely — prompting for a save location, showing a live progress bar
while the report generates, then offering to open or reveal the finished file.

**Requires:** swiftDialog ≥ 2.5 installed at `/usr/local/bin/dialog`.

### Usage

```bash
./report-ui.zsh [report.sh options]
```

All options are forwarded verbatim to `report.sh`. Do **not** pass `-o` /
`--output` — the wrapper manages the output path via a native save panel.

```bash
# Basic: save panel → progress dialog → open on completion
./report-ui.zsh

# With a specific jamf-cli profile
./report-ui.zsh --profile prod

# With history tracking and cleanup analysis
./report-ui.zsh --track-history --cleanup
```

### Workflow

1. **Save panel** — a native macOS "Save As" sheet lets the user choose the
   output file name and location before anything is fetched.
2. **Confirmation dialog** — summarises what the report will include and shows
   the chosen save path. The user clicks **Generate Report** or **Cancel**.
3. **Progress dialog** — a live progress bar advances through each report step,
   with substep text describing what is happening inside each step (e.g.
   "Batch 1/2 — overview & security…", "Fetching policy details…").
4. **Completion** — the dialog re-enables its button. The user clicks
   **Open Report** to open in the default browser, or **Show in Finder** to
   reveal the file without opening it.
5. **Done notification** — a final confirmation dialog shows the full save path.

### Progress steps

| Step | Label | Substeps shown |
|------|-------|----------------|
| 1 | Fetching data from Jamf Pro | Batch 1/2 (overview & security), Batch 2/2 (inventory & organisation) |
| 2 | Processing data | Patch compliance, MDM profile failure data, MDM app failure data, managed update plan data, device check-in compliance *(each shown only when the matching flag is passed)* |
| 3 | Building deployment hierarchy | — |
| 4 | Cleanup analysis *(only when `--cleanup` is passed)* | Fetching policy details, fetching macOS profile details, cross-referencing packages and scripts |
| 4 or 5 | Generating HTML report | — |
| 5 or 6 | Finalising report | — |

The total step count adjusts automatically — 5 steps without `--cleanup`,
6 steps with it. The `--profile-status`, `--app-status`, `--update-status`,
`--device-compliance` and `--patch-status` flags add substep text during
step 2 but do not change the total step count.

---

## How it works

1. **Parallel data collection** — data is fetched from Jamf Pro in two batches:
   - Batch 1: `overview` and `security report` (run alone to avoid rate-limiting)
   - Batch 2: policies, profiles, scripts, packages, smart groups, categories,
     sites, buildings, departments, ADE instances — all in parallel
2. **Resilient fetching** — each request is validated as JSON. Failed or invalid
   responses are retried once after a short delay before marking as failed.
   The security report has an additional two-attempt recovery loop.
3. **Data processing** — `jq` normalises, groups and sorts all data in-shell.
   Version strings are normalised (trailing `.0` stripped) and duplicates merged.
4. **HTML generation** — a single `report.sh` heredoc writes the complete HTML,
   CSS and JavaScript inline. No templating engine or build step is needed.
5. **Cleanup analysis** *(opt-in, `--cleanup`)* — fetches the full detail record
   for every policy and macOS profile in batches of 8 concurrent requests.
   Cross-references package and script IDs across all policies to find unused
   objects. Results appear in the **Cleanup** tab of the report.
6. **Icon embedding** — the script attempts to extract the Self Service app icon
   from the local machine, convert it to PNG via `sips`, and embed it as a
   base64 `data:` URI. Falls back to a default icon if not found.
7. **Cleanup** — a `trap` on `EXIT` removes the temporary working directory.

---

## Demo Mode

A demo runner is included that generates a fully populated report from local
fixture JSON files — **no Jamf Pro connection or credentials required**.

```bash
./demo/run-demo.sh [output.html]
```

The output defaults to `~/Downloads/jamf-demo-report.html`.

To preview the UI wrapper against demo data (requires swiftDialog):

```bash
# Puts the demo jamf-cli stub first in PATH so report-ui.zsh uses it
PATH="$(pwd)/demo:$PATH" ./report-ui.zsh --cleanup
```

### Custom icon for demo

Place a file named `icon.png` in the `demo/` folder. The runner will
base64-encode it and pass it to the report script via the
`JAMF_REPORT_ICON_B64` environment variable, bypassing Self Service icon
extraction entirely.

### Demo fixture files (`demo/`)

| File | Contents |
|------|----------|
| `overview.json` | Server info (`https://demo.jamfcloud.com`), version, health, counts |
| `security.json` | 1,247 managed devices; security summary percentages; 4 flagged devices; OS version breakdown |
| `policies.json` | 20 sample policies across 5 categories |
| `macos_prof.json` | 15 macOS configuration profiles |
| `ios_prof.json` | 3 iOS configuration profiles |
| `scripts.json` | 10 scripts with category names |
| `smart_groups.json` | 13 generic smart groups |
| `categories.json` | 7 categories |
| `packages.json` | 8 packages |
| `jamf-cli` (stub) | Bash stub that serves all fixture data including per-ID policy and profile detail responses, used by the demo to simulate `--cleanup` analysis without a live Jamf Pro connection |

All fixture data is generic and contains no organisation-specific information.

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `JAMF_REPORT_ICON_B64` | Base64-encoded PNG to use as the report header icon. When set, the script skips Self Service app icon extraction entirely. Set automatically by `demo/run-demo.sh` when `demo/icon.png` exists. |
| `JAMF_REPORT_HISTORY_FILE` | Override the default history file path (`~/.jamf-report.history.json`). Equivalent to `--history-file`. |

---

## macOS Adoption Timeline (history tracking)

The report can display a line chart showing how each macOS version's device
count has changed over multiple report runs.

### How to enable

Pass `--track-history` each time you generate a report:

```bash
./report.sh --track-history
```

On each run, the script appends a timestamped snapshot of the current macOS
version distribution to the history file (default: `~/.jamf-report.history.json`).

The **macOS Adoption Timeline** section will appear in the report automatically
as soon as 2 or more snapshots exist for the same Jamf Pro instance URL.

### Suggested workflow

Run the report on a **weekly or monthly schedule** (e.g. via `cron` or a
`launchd` job) with `--track-history`. Over time the chart will show clearly
which versions are being adopted and which are stalling.

```bash
# Example: weekly cron at 08:00 on Monday
0 8 * * 1  /path/to/report.sh --track-history --no-open -o /archive/report-$(date +\%Y\%m\%d).html
```

### History file format

The file is a JSON array; each entry is one snapshot:

```json
[
  {
    "ts": "2026-01-10T08:00:00Z",
    "instance": "https://your-instance.jamfcloud.com",
    "versions": [
      { "v": "15.4", "c": 612 },
      { "v": "15.3", "c": 380 },
      { "v": "14.7", "c": 255 }
    ]
  }
]
```

The file keeps at most **365 entries** per instance. Older entries beyond that
limit are automatically removed when the file is updated.

### Sharing across machines

Set `JAMF_REPORT_HISTORY_FILE` (or use `--history-file`) to a path on a shared
drive so multiple team members contribute to the same history, or commit the
file to a repository alongside the reports.

---

## Cleanup Analysis (opt-in)

The **Cleanup** tab in the report surfaces objects that may be candidates for
removal or remediation. It is opt-in because it requires one additional API
call per policy and per macOS profile — which adds time proportional to the
size of your instance.

### How to enable

Pass `--cleanup` each time you generate a report:

```bash
./report.sh --cleanup
```

### What it checks

| Category | Logic |
|----------|-------|
| **Disabled policies** | Policies where `general.enabled == false` |
| **Policies with no scope** | Enabled policies not scoped to any computer, group, building, or department (and not set to "All Computers") |
| **macOS profiles with no scope** | Profiles not scoped to any target |
| **Unused packages** | Packages that do not appear in the `package_configuration` of any policy |
| **Unused scripts** | Scripts that do not appear in the `scripts` block of any policy |

When `--cleanup` is not passed the tab is still present in the report but
displays a notice explaining that cleanup analysis was skipped, along with the
flag to enable it.

### Performance

Fetches are batched at 8 concurrent requests. Typical runtimes:

| Instance size | Extra time |
|--------------|------------|
| ~50 policies + ~30 profiles | ~10–15 s |
| ~200 policies + ~100 profiles | ~45–60 s |

---

## App Status (opt-in)

The **MDM App Deployment Failures** section surfaces managed apps that have
generated `InstallApplication` or `InstallEnterpriseApplication` MDM command
failures, grouped by app with per-app device and error counts.

### How to enable

```bash
./report.sh --app-status

# Narrow the look-back window to 7 days
./report.sh --app-status --app-days 7
```

### What it shows

| Column | Details |
|--------|---------|
| App Name | Display name of the managed app (or command ID for enterprise apps) |
| Device Type | `Computer` or `Mobile Device` |
| Devices | Number of devices that received at least one failure |
| Errors | Total error count for the app in the look-back window |
| Last Error | Date of the most recent failure |
| Top Error Message | The most common error string returned by MDM |

Summary KPIs (apps with errors, devices affected, total errors, high-failure
devices and look-back window) are shown above the table.

---

## Update Status (opt-in)

The **Managed Software Update Status** section shows the distribution of
managed software update plan states across your fleet — useful for tracking
how DDM and classic update plans are progressing.

### How to enable

```bash
./report.sh --update-status
```

### What it shows

A KPI row (total plans, failed, completed, exceptions) followed by a
plan-state pill grid. Each pill shows:

- **State label** (e.g. Failed, Completed, Waiting for DDM Update)
- **Count** of plans in that state
- **Percentage** of total plans

| State | Meaning |
|-------|---------|
| `PlanFailed` | Update plan failed — device could not be updated |
| `PlanCompleted` | Device successfully updated |
| `PlanException` | Plan ended with an exception (e.g. user deferral limit reached) |
| `PlanCanceled` | Plan was cancelled |
| `WaitingToStartDDMUpdate` | DDM update scheduled but not yet started |
| `CollectingAvailableOSUpdates` | Device scanning for available updates |
| `SchedulingScanForOSUpdates` | Scan scheduled but not yet run |
| `UpToDate` | Device already on the target version |

---

## Profile Status (opt-in)

The **MDM Profile Failures** section surfaces configuration profiles that have
generated `InstallProfile` command failures, grouped by profile with per-profile
device and error counts.

### How to enable

```bash
./report.sh --profile-status

# Narrow the look-back window to 7 days
./report.sh --profile-status --profile-days 7
```

### What it shows

| Column | Details |
|--------|--------|
| Profile Name | Name of the configuration profile |
| Device Type | `Computer` or `Mobile Device` |
| Devices | Number of devices that received at least one failure |
| Errors | Total error count for the profile in the look-back window |
| Last Error | Date of the most recent failure |
| Top Error Message | The most common error string returned by MDM |

Summary KPIs (profiles with errors, devices affected, total errors and
look-back window) are shown above the table.

---

## Device Check-in Compliance (opt-in)

The **Device Check-in Compliance** section lists every managed device with its
last check-in date, days since contact and stale status, making it easy to
identify devices that have fallen out of management.

### How to enable

```bash
./report.sh --device-compliance

# Mark devices stale after 7 days without a check-in
./report.sh --device-compliance --checkin-days 7
```

### What it shows

| Column | Details |
|--------|--------|
| Device Name | Jamf-managed computer name |
| Serial | Hardware serial number |
| Days Since Check-in | Integer count; colour-coded (green / amber / red) |
| Last Contact | Formatted date of the last successful check-in |
| OS Version | macOS version string at last inventory update |
| Status | **Stale** or **Active** badge |

The table supports:
- **Sort** by device name or days since check-in (click column header)
- **Stale only** checkbox to hide active devices
- **Free-text search** filtering by device name or serial

---

## Output

A single self-contained `.html` file. Open it in any modern browser (Safari,
Chrome, Firefox, Edge) — no web server, internet connection, or additional
software required. The file can be emailed, shared via a file share, or
committed to a repository.

---

## Security Considerations

- No credentials are written to disk by this script.
- All Jamf Pro communication uses the `jamf-cli` tool and the credentials
  stored in its keychain-backed profile store.
- The temporary directory (`/tmp/jamf-report-XXXX`) is deleted on exit via
  `trap`, even if the script is interrupted.
- The generated HTML embeds all data inline. Treat the output file with the
  same sensitivity as any Jamf Pro inventory export.
