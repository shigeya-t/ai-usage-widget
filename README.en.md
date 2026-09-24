# AI Usage Widget

[日本語](README.md)

**A macOS menu bar app and WidgetKit widget that keeps "how much is left" for Cursor, Claude, and Codex in front of you.**

The menu bar always shows the percentage of whichever quota is closest to running out. Click it and you get
the plan name, reset date, per-window meters, and pay-as-you-go spend on one panel — no dashboard needed.

<p align="center">
  <img src="docs/screenshots/widget-en.png" alt="Widget (English)" width="500" />
</p>
<p align="center">
  <img src="docs/screenshots/menu-en.png" alt="Menu bar (English)" width="300" />
</p>

The architecture matches [Subway Widget](https://github.com/shigeya-t/subway-widget), with a strict split of roles:

| Role | Owner |
| --- | --- |
| Fetching usage | The menu bar host app, and only it |
| Display | The widget extension. It never makes a request; it just draws the snapshot it was handed |
| Hand-off | An App Group (a shared container prefixed with your Team ID) |

## Contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Reading the display](#reading-the-display)
- [Authentication](#authentication)
- [How refresh works](#how-refresh-works)
- [Troubleshooting](#troubleshooting)
- [Privacy and permissions](#privacy-and-permissions)
- [Uninstall](#uninstall)
- [For developers](#for-developers)
- [Notes](#notes)
- [License](#license)

## Why this exists

Cursor's dashboard has a Plan & Usage page, but there does not seem to be a clear notification when
remaining credits run low. It was easy to burn through the included pool and drift deep into on-demand
spend before noticing.

This app keeps plan quotas visible in the menu bar and on the desktop, without opening settings every
time. Claude and Codex use the same surface.

## Features

- **Switch services** — Cursor / Claude / Codex from a segmented control in the menu. Each placed widget can show a different service.
- **A Plan & Usage–style view** — plan name and price, reset date and days left, per-window percent meters, and spend.
- **Menu bar resident** — no Dock icon. The menu bar title alone tells you which quota is closest to its limit.
- **Widgets in three sizes** — small, medium, large, on the desktop or in Notification Center. Buttons in the top-right corner pause/resume and refresh.
- **Japanese / English switch** — shared by the app and the widgets. Defaults to your system language and can be changed from the menu.
- **Pause and Refresh Now** — available in both the app and the widget, with shared state. Refresh Now works even while paused.
- **Save, replace, and delete a manual token or cookie** — one per service, stored in the Keychain. This is the fallback when automatic pickup fails.

### What each service shows

| Service | Main source | What you see | Login needed |
| --- | --- | --- | --- |
| **Cursor** | `cursor.com` (unofficial API) | Cursor Models / Other Models / Grok Bot usage, on-demand spend | A Cursor.app login |
| **Claude** | `api.anthropic.com` (unofficial OAuth API) | 5-hour, weekly, weekly Opus / Sonnet windows, cloud session credits, extra usage spend | A Claude Code (CLI) login |
| **Claude (API key only)** | Official Cost API | This month's API spend | An Admin key such as `sk-ant-admin01-` |
| **Codex** | `chatgpt.com` (unofficial API) | Primary / secondary / code review windows, extra credit balance | A Codex CLI login (ChatGPT account) |
| **Codex (API key only)** | Official Cost API | This month's API spend | An OpenAI Admin key |

Subscription windows and API spend are different things. Plan-window percentages are only available through
each service's own login (OAuth); with just an API key you get a "how much did I spend this month" amount instead.

## Requirements

| Item | What you need | Notes |
| --- | --- | --- |
| OS | macOS 14 or later | Required for the interactive widget buttons |
| Build | Xcode 15 or later | There is no prebuilt release; you build it yourself |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen`. The `.xcodeproj` is not committed |
| Signing | An Apple Development certificate | Created once you sign in to Xcode with an Apple ID. Team-signed builds are mandatory |
| A login for the service you want to watch | Cursor.app / Claude Code / Codex CLI | Only for the services you actually use |

> **Why signing is mandatory**
> The widget's configuration (which service it shows) is implemented with AppIntents. With ad-hoc or unsigned
> builds, AppIntents cannot be resolved and widgets stay stuck on placeholders. The App Group ID is also
> `<Team ID>.jp.shigeya.AIUsageWidget`, so without a Team ID the app and the widget cannot share data at all.

## Quick start

```sh
brew install xcodegen                     # 1. project generator
cp Config/Team.xcconfig.example Config/Team.xcconfig
./scripts/sync-team.sh                    # 2. write your Team ID from your certificate
xcodegen generate                         # 3. create AIUsageWidget.xcodeproj
./scripts/test.sh                         # 4. unit tests (optional)
swift scripts/generate-app-icon.swift     # 5. regenerate the app icon (optional)
./scripts/deploy-local.sh                 # 6. build and install into ~/Applications
```

| Step | What it does | Skippable? |
| --- | --- | --- |
| 1 | Installs XcodeGen | Yes, if you already have it |
| 2 | Reads the Team ID from your local "Apple Development" certificate and writes `Config/Team.xcconfig` (gitignored) | **No.** Skipping it breaks the App Group |
| 3 | Generates `.xcodeproj`, `Info.plist`, and `*.entitlements` from `project.yml` | **No** (also needed after every `project.yml` edit) |
| 4 | Runs the offline unit tests | Yes |
| 5 | Rebuilds the icon images | Yes (generated icons are committed) |
| 6 | Builds Release with signing, stops running processes, installs, and relaunches | **No** |

If you have more than one certificate, name the team explicitly:

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh
./scripts/deploy-local.sh /Applications     # install somewhere else
```

### After installing

1. Right-click the desktop → **Edit Widgets** → pick **AI Usage** (**AI使用量** on a Japanese system).
2. Right-click the placed widget → **Edit Widget** to choose which service it shows (Cursor / Claude / Codex).
3. For everyday use, add the app under System Settings → General → Login Items so it starts at login.

> If an older **Cursor使用量.app** is still in the install directory, `deploy-local.sh` removes it.

## Reading the display

### The menu bar title

| State | Title | Icon |
| --- | --- | --- |
| Normal | The highest used percentage (e.g. `86%`) | Filled bar chart |
| No meters (API spend only) | The amount (e.g. `$12.30/$50`) | Filled bar chart |
| Nothing fetched yet | The service name (e.g. `Cursor`) | Filled bar chart |
| An error is showing | The previous value | Warning triangle |
| Paused | `Paused` | Outlined bar chart |

### The menu panel

From top to bottom: current plan name and price → service switch → error text (in red, if any) → reset date
and days left → account label → per-window meters → spend → last updated → language switch → the
authentication section → **Open Dashboard** → **Pause / Resume**, **Refresh Now**, **Quit** → build stamp.

**Open Dashboard** opens the official page for the selected service in your browser.

| Service | Page |
| --- | --- |
| Cursor | `https://cursor.com/dashboard?tab=usage` |
| Claude | `https://claude.ai/settings/usage` |
| Codex | `https://chatgpt.com/codex/settings/usage` |

### The widget

| Size | Content |
| --- | --- |
| Small | Service, plan name, shortened reset date, meters, amount. Explanatory text is dropped |
| Medium | The above plus plan price and meter subtitles ("Session usage window", …) |
| Large | The above plus meter and spend notes ("Usage past your limit is billed later as on-demand", …) |

Every size has two buttons in the top-right corner:

- **Pause / Resume** — stops or resumes automatic refresh; the state is shared with the app.
- **Refresh** — asks for an immediate fetch (works while paused too).

### Glossary of meter names

| Label | Service | Meaning |
| --- | --- | --- |
| Cursor Models | Cursor | The included pool for the main models. Includes Cursor Grok and Composer |
| Other Models | Cursor | The pool for other models; usage beyond it goes to on-demand spend |
| Grok Bot | Cursor | Grok Bot's weekly allowance |
| On-Demand | Cursor | Usage past your limit, billed later (spent / limit, or "Unlimited") |
| 5-hour | Claude | The short, session-length window |
| Weekly / Weekly Opus / Weekly Sonnet | Claude | Seven-day windows, split per model when the API reports them separately |
| Cloud session credits | Claude | A one-time credit for cloud sessions. Shows the remaining amount and expiry, and is not part of the plan-window percent |
| Extra usage | Claude | Pay-as-you-go beyond the plan window. Says so when the credit balance is empty |
| Primary / Secondary | Codex | Named from the reset period the API reports: 5-hour, Daily, Weekly, or Monthly |
| Code Review | Codex | The code review allowance |
| Credits | Codex | The extra usage-credit balance — not a plan window |
| API usage | Claude / Codex | This month's API spend from the official Cost API. An amount, not a percentage |

Rounding follows what the dashboards show: any usage above 0% but below 1% displays as **1%**, and usage
past 100% is reported as-is (the bar itself stops at 100%).

## Authentication

Personal plan usage is not available through the official Admin APIs. This app calls unofficial endpoints
using **credentials the local apps have already stored**.

Rules that apply to all three services:

- **OAuth tokens are never refreshed.** A refresh token can be single-use, and spending it here could break the original app's login. If a token expired, open the original app once.
- **Cookies, JWTs, and access tokens are never logged.**
- **Requests go through a dedicated ephemeral session** (`UsageHTTP.session`) with no on-disk cookie store or cache.
- **Manually entered credentials live only in the Keychain** — never in app preferences or the App Group.
- **Only usage snapshots are shared with the widget.** Tokens are not.

### Cursor

Endpoint: `GET https://cursor.com/api/usage-summary`

Credentials are resolved in this order:

1. A cookie you saved in the menu bar (Keychain) — preferred when present
2. Cursor.app's `state.vscdb` (`cursorAuth/accessToken`)

Paste a cookie only when automatic resolution fails:

1. Open https://cursor.com/dashboard?tab=usage
2. DevTools → **Application** → **Cookies** → copy the **Value** of `WorkosCursorSessionToken`
3. Paste just the value into the menu bar field and press **Save / Replace**

### Claude

Plan windows (OAuth): `GET https://api.anthropic.com/api/oauth/usage`

Credentials are resolved in this order:

1. An access token you saved in the menu bar (Keychain) — preferred when present. A value starting with `sk-ant-` that is not an `sk-ant-oat…` Claude Code OAuth token is treated as an API key and uses the official Cost API
2. `~/.claude/.credentials.json` (or `CLAUDE_CONFIG_DIR` if set). No prompt appears
3. The Claude Code keychain item (`Claude Code-credentials`). A confirmation dialog may appear, at most once per fetch
4. The environment variables `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_ADMIN_KEY` / `ANTHROPIC_API_KEY`

- A Claude.app (desktop) login cannot be used. The 5-hour and weekly windows come from **a Claude Code login in the terminal**.
- With only an API key, the official `GET https://api.anthropic.com/v1/organizations/cost_report` (Admin key required) reports this month's API spend. The Admin API is unavailable for many individual accounts.
- If the token expired, run `claude` in the terminal once, then press **Refresh Now**.

### Codex

Plan windows (ChatGPT login): `GET https://chatgpt.com/backend-api/wham/usage` (falls back to `.../codex/usage` on 404)

Credentials are resolved in this order:

1. An access token or API key you saved in the menu bar (Keychain) — preferred when present. Values starting with `sk-` use the official Cost API
2. The Codex CLI's `~/.codex/auth.json` (or `CODEX_HOME` if set). An access token gives plan windows; an API key alone uses the official Cost API
3. The environment variables `OPENAI_ADMIN_KEY` / `OPENAI_API_KEY`

- Codex rate-limit windows require **a Codex CLI login with a ChatGPT account**.
- With only an API key, the official `GET https://api.openai.com/v1/organization/costs` (Admin key required) reports this month's API spend.
- If one file holds both a ChatGPT login and an API key, plan windows win.
- If the token expired, open Codex once, then press **Refresh Now**.

### About the manual field

- The field is a `SecureField`; what you paste is never shown in plain text.
- **Save / Replace** stores it in the Keychain and refetches immediately. Once something is stored, a **Delete** button appears.
- Only **one credential per service** is stored; pasting a new value replaces the old one.
- The `Bearer ` shown to the left of the Claude / Codex field is the fixed prefix that will be added for you — do not paste `Bearer ` yourself.

## How refresh works

Widgets stay fresh only **while the menu bar app is running**.

- Fetching is centralized in the host app; the widget extension never makes a request.
- The host fetches every **5 minutes** by default and hands snapshots to the widgets through the App Group.
- It fetches the service selected in the menu **plus every service configured on a placed widget**.
- The widget's own timeline asks for its next update after 5 minutes, or after an hour while paused.
- When the snapshot a widget reads is **more than 10 minutes old**, the widget asks the host to fetch again.
- **Pause** stops automatic fetches. **Refresh Now** still fetches while paused.

Quit the host and refreshing stops; widgets keep showing the last snapshot.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Widget stuck on a placeholder | Built unsigned or ad-hoc | Reinstall with `./scripts/deploy-local.sh`, which signs with your team |
| Menu says "Team ID is empty" | `Config/Team.xcconfig` is missing or empty | Run `./scripts/sync-team.sh`, then `xcodegen generate` and rebuild |
| Widget says "Open the menu bar app to fetch usage" | The host is not running, or no snapshot exists for that service yet | Launch the app and press the widget's refresh button |
| "Could not read a … session" | You are not signed in to the original app, or it could not be read | Sign in to the original app, or paste a value into the authentication field |
| "The … token expired" | The local access token expired | Open the original app (Cursor.app / `claude` / Codex) once, then press **Refresh Now** |
| A keychain dialog appears, or you denied it | Reading the Claude Code keychain item needs your approval | Choose **Always Allow**. If you denied it, **Refresh Now** asks again |
| "The usage API is rate-limited" | Rate limiting | Wait a while, then refresh |
| Values are frozen | Paused, or the host quit | If the menu bar reads "Paused", resume. Otherwise launch the app |
| Claude shows only an amount, no plan windows | API-key-only mode | Sign in with `claude` in the terminal to get plan windows |

### The widget does not update

WidgetKit throttles timeline reloads. Press the refresh button in the widget's top-right corner first; if
nothing changes, press **Refresh Now** in the menu bar app. Right after you place a widget it can keep
showing stale content for a little while.

### The build succeeds but the widget lists no service

That means AppIntents (`SelectProviderIntent`) could not be resolved. Check signing and the App Group:

```sh
codesign -dv ~/Applications/AI使用量.app/Contents/PlugIns/AIUsageWidgetExtension.appex 2>&1 | grep TeamIdentifier
```

`TeamIdentifier=not set` means the build is unsigned. Start again from `./scripts/sync-team.sh`.

### Watching what it does

```sh
log stream --predicate 'subsystem beginswith "jp.shigeya.AIUsageWidget"' --level debug
```

Credentials are kept out of the log, so you only see which path was taken and whether it succeeded.

## Privacy and permissions

### Host (menu bar app)

App Sandbox is **off on purpose**: a sandboxed host cannot read Cursor's `state.vscdb`. As a result this
process:

- reads Cursor's `state.vscdb`, Claude Code's credential files, and Codex's `auth.json`
- reads the Claude Code keychain item via `/usr/bin/security` (a prompt may appear)
- sends those tokens to `cursor.com` / `api.anthropic.com` / `chatgpt.com` / `api.openai.com` to fetch usage

### Widget extension

Sandboxed, without the network client entitlement. It makes no requests and only renders snapshots from
the App Group.

### Handling values that come from outside

An App Group and distributed notifications can be written by any process running as the same user, so
values arriving from the widget are not trusted as-is:

- URLs opened by **Open Dashboard** pass through `AppSettings.isAllowedDashboardURL`, which only allows the **https URLs of registered providers**.
- The credential field is a `SecureField` and never renders in plain text.
- Keychain retries are rate-limited so repeated external refresh requests cannot spam the dialog.

This is a design for personal, private use. Shipping with a mandatory host sandbox would need a different
design — manual tokens only, or a security-scoped bookmark for file access.

## Uninstall

1. Right-click each placed widget → **Remove Widget**
2. **Quit** from the menu bar menu
3. Remove the app
   ```sh
   rm -rf ~/Applications/AI使用量.app
   rm -rf build/AI使用量.app
   ```
4. If you ever saved a credential by hand, delete it in Keychain Access by searching for these service names:
   - `jp.shigeya.AIUsageWidget.cursor`
   - `jp.shigeya.AIUsageWidget.claude`
   - `jp.shigeya.AIUsageWidget.chatgpt`
5. Remove settings and snapshots
   ```sh
   rm -rf ~/Library/Group\ Containers/*.jp.shigeya.AIUsageWidget
   ```
6. Remove it from System Settings → General → Login Items if you added it there

## For developers

Notes aimed at coding agents live in [AGENTS.md](AGENTS.md).

### Layout

```
project.yml                  XcodeGen project definition (Info.plist / entitlements come from here)
Config/
  Team.xcconfig.example      Template for the Team ID file (the real one is gitignored)
Shared/
  UsageModels.swift          Shared models: UsageSnapshot / UsageMeter / SpendMeter
  UsageProvider.swift        Provider protocol and registry
  CursorProvider.swift       Cursor fetch and mapping
  ClaudeProvider.swift       Claude fetch and mapping
  ChatGPTProvider.swift      Codex fetch and mapping
  *Session.swift             Credential resolution per service (files / Keychain / environment)
  AppSettings.swift          App Group settings and snapshot storage
  L10n.swift                 Japanese / English strings
  RefreshUsageIntent.swift   App Intents for refresh, pause, and dashboard
  SelectProviderIntent.swift Widget configuration (which service to show)
  UsageHTTP.swift            The ephemeral URLSession
App/                         Menu bar host app (fetching and UI)
WidgetExtension/             Widget UI (no networking)
Tests/                       Unit tests and JSON fixtures
docs/screenshots/            Screenshots for the README
scripts/                     sync-team / test / deploy-local / icon generator
```

`AIUsageWidget.xcodeproj`, `Info.plist`, and `*.entitlements` are generated from `project.yml` and are not
committed. Run `xcodegen generate` after cloning and after every `project.yml` change.

### Scripts

| Script | Purpose |
| --- | --- |
| `scripts/sync-team.sh` | Reads the Team ID from your certificate and writes `Config/Team.xcconfig` |
| `scripts/test.sh` | Runs the unit tests (`-v` streams raw `xcodebuild` output) |
| `scripts/deploy-local.sh` | Builds Release → stops running processes → installs → refreshes Launch Services → relaunches |
| `scripts/generate-app-icon.swift` | Regenerates the app icon images |
| `scripts/stamp-git-commit.sh` | Writes the short git hash into `Info.plist` (run automatically as a build phase; shown at the bottom of the menu) |
| `scripts/_common.sh` | Shared helpers `source`d by the others (not meant to be run directly) |

### Tests

`AIUsageWidgetTests` are unit tests that never launch the host app. They do no networking and do not touch
the production UserDefaults / Keychain paths — they verify cookie normalization and JSON mapping as pure
functions.

| Test class | Covers |
| --- | --- |
| `CursorProviderMappingTests` | usage-summary JSON from `Tests/Fixtures/` → snapshot |
| `ClaudeProviderMappingTests` | OAuth usage JSON and the official Cost API mapping |
| `ChatGPTProviderMappingTests` | wham usage JSON and the official organization-costs mapping |
| `CursorSessionTests` / `ClaudeSessionTests` / `ChatGPTSessionTests` | Cookie / token normalization and credential resolution order |
| `L10nTests` | Every key exists in both languages with intact format specifiers |
| `UsageProviderRegistryTests` | Registry contents |

```sh
./scripts/test.sh          # summary only
./scripts/test.sh -v       # raw xcodebuild output
```

### Adding another AI provider

1. Add a type in `Shared/` conforming to `UsageProvider` (`id`, `displayNameKey`, `dashboardURL`, `credentialNameKey`, `authNeededKey`, `usingAppKey`, `fetchSnapshot()`, and the manual-credential accessors).
2. In `fetchSnapshot()`, call the API and map it into a `UsageSnapshot` (`PlanInfo` + `[UsageMeter]` + an optional `SpendMeter`). Use `UsageHTTP.session` for the request.
3. Add the display strings to `Shared/L10n.swift` in both `.ja` and `.en` (`L10nTests` catches anything missing).
4. Register it in `UsageProviderRegistry.all`. The menu's segmented control and the widget's picker pick it up automatically.
5. Drop the API's JSON into `Tests/Fixtures/` and add mapping tests.

No UI changes are needed: the views only render `UsageSnapshot` (plan, percent meters, spend).

### When forking

The bundle ID is `jp.shigeya.AIUsageWidget`. To use your own, change all of these together:

| File | What to change |
| --- | --- |
| `project.yml` | `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` |
| `Shared/AppSettings.swift` | `Notification.Name` values and `groupSuffix` |
| `Shared/CursorSession.swift` / `ClaudeSession.swift` / `ChatGPTSession.swift` | Keychain service names |
| `scripts/_common.sh` | `BUNDLE_ID` |

The App Group is `$(DEVELOPMENT_TEAM).jp.shigeya.AIUsageWidget`.

### About the app name

The `.app` wrapper name is the Japanese **AI使用量.app** (no dakuten). A dakuten in the wrapper name stops
the widget extension from launching. English display names live in `en.lproj`, so do not change
`WRAPPER_NAME` to English.

## Notes

- The usage endpoints are unofficial and may change without notice.
- Intended for personal, private use.
- Do not contact Cursor, Anthropic, or OpenAI support about issues with this app.

## License

[MIT License](LICENSE)
