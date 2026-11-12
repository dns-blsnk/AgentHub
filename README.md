# AgentHub

A macOS menu bar and notch app that keeps your AI coding agents in one place: **Claude Code, Codex, Antigravity (`agy`), Gemini CLI, Cursor and Claude Desktop**.

- **One MCP registry for every agent.** Add an MCP server once and it is written into every agent's own config. Restart Codex, open Claude Code or Claude Desktop, and the server is already there, after a reboot too.
- **Usage limits** for Claude, Antigravity and Codex, refreshed whenever you open the panel.
- **Live sessions in the notch.** See which agents are working or waiting for you, and get Dynamic Island-style alerts when a turn finishes or an agent needs permission.
- **Account switching** for Claude Code, Codex and Antigravity: keep several sign-ins and switch with one click.
- **Runs in the background.** Hover the notch to open the panel, use the menu bar icon, or start it at login.

No dependencies: Swift, SwiftUI, AppKit and the macOS Keychain.

---

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using AgentHub](#using-agenthub)
  - [Notch panel](#notch-panel)
  - [Menu bar](#menu-bar)
  - [Main window](#main-window)
- [MCP servers](#mcp-servers)
  - [Where each agent's servers go](#where-each-agents-servers-go)
  - [Keys and secrets](#keys-and-secrets)
  - [Per-agent switches](#per-agent-switches)
  - [Importing existing servers](#importing-existing-servers)
  - [Snapshots](#snapshots)
- [Usage limits](#usage-limits)
- [Sessions and alerts](#sessions-and-alerts)
- [Accounts](#accounts)
- [Launch at login](#launch-at-login)
- [Files AgentHub keeps](#files-agenthub-keeps)
- [Security](#security)
- [Architecture](#architecture)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Requirements

- macOS 15 (Sequoia) or later. The notch panel works best on a MacBook with a notch. On other screens it opens from a hover zone at the top center of the screen.
- Swift 6 toolchain (Xcode 16 or the Command Line Tools) to build.
- The agents you want to manage, installed the usual way. AgentHub finds their CLIs through your login shell's `PATH`:
  - `claude` (Claude Code)
  - `codex` (Codex CLI)
  - `agy` (Antigravity CLI)
  - Gemini CLI, Cursor and Claude Desktop are managed through their config files, so their CLIs aren't required.

## Install

```sh
git clone https://github.com/dns-blsnk/AgentHub.git
cd AgentHub
./scripts/build-app.sh --install    # release build, copied to /Applications/AgentHub.app
open /Applications/AgentHub.app
```

`./scripts/build-app.sh` without flags builds `build/AgentHub.app` and leaves it there.

The app is ad-hoc signed and is a background app (`LSUIElement`), so it has no Dock icon. On first use macOS asks for Keychain access: once for AgentHub's own items, and once each for the agents' sign-in items when you use account switching or Claude limits. Choose **Always Allow**. After a rebuild the signature changes, and macOS may ask again.

## Using AgentHub

### Notch panel

Move the cursor onto the notch and rest it there briefly. The panel drops down. It shows:

- **Alerts**: the latest session or limit alert, if any.
- **Sessions**: running Claude Code, Codex and Antigravity sessions with project name, state and how long they've been in it. Click a session to bring its terminal or IDE to the front.
- **Limits**: one row per window (5-hour session, week, per model…) with a usage bar and reset time. Opening the panel re-reads limits if they are older than 30 seconds, so the numbers are fresh.
- **Quick actions**: switch accounts per agent, add an MCP server, open the main window.

The panel closes when the cursor leaves it. When an alert is showing, resting on the alert pill opens the panel too.

### Menu bar

The menu bar icon (connected dots) is always there:

- **Open AgentHub** opens the main window.
- Server counts and a short usage summary per agent, plus **Refresh Usage**.
- Account switchers for every agent with more than one saved account.
- **Launch at Login** toggle.
- **Quit AgentHub**.

Opening the app again from Finder or Spotlight also opens the main window.

### Main window

Three tabs:

| Tab | What it does |
|---|---|
| **Servers** | The MCP registry: a grid of servers × agents with a switch in each cell, plus add, edit, delete and import. |
| **Usage** | Every limit window of every agent, with plan, reset time and errors. |
| **Accounts** | Saved accounts per agent: switch, add or forget. |

## MCP servers

The registry is AgentHub's list of MCP servers. It is the source of truth: every change is written to each agent's config straight away.

A server has:

- **Name**: letters, digits, `-` and `_`.
- **Transport**:
  - **stdio**: a command and arguments, for example `npx -y @modelcontextprotocol/server-slack`.
  - **http**: a URL.
- **Keys**: any number of named values, such as `SLACK_BOT_TOKEN`, `JIRA_URL` or `Authorization`. For stdio they become environment variables. For http they become request headers.
- **Agents**: which agents get the server. All of them by default.

### Where each agent's servers go

| Agent | Where | How |
|---|---|---|
| Claude Code | user scope in `~/.claude.json` | `claude mcp add` / `add-json` / `remove -s user` |
| Codex | `~/.codex/config.toml` → `[mcp_servers.<name>]` | edited in place; comments, formatting and other settings stay as they were |
| Antigravity | `~/.gemini/config/mcp_config.json` | `agy mcp add` / `remove` |
| Gemini CLI | `~/.gemini/settings.json` → `mcpServers` | JSON edit |
| Cursor | `~/.cursor/mcp.json` → `mcpServers` | JSON edit |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON edit; http servers go through `npx -y mcp-remote <url> --header Name:${MCP_HEADER_NAME}`, with the header value in `env` |

Servers are written at **user (global) scope**, so they work in every project. Agents read their config at start, so restart an agent that is already running to pick up a change.

Renaming a server removes the old name from each agent and adds the new one. Deleting a server removes it from every agent.

### Keys and secrets

Key values never go into the registry file. They are kept in the macOS Keychain in a single item for all servers (service `dev.agenthub.mcp`, account `servers`), and written only into the agents' configs, which need them in plain text.

- AgentHub reads that item once per launch, so macOS asks for access at most once, however many servers you switch. Turning servers off doesn't read it at all. Choose **Always Allow** to stop the prompt for good (until the next rebuild of an ad-hoc signed app).
- Ticking one checkbox writes only to that agent. The other agents' configs aren't touched.
- Older versions kept one item per server. They are moved into the single item on first use and deleted.

- Values can't contain line breaks or NUL characters, so they can't inject extra config lines.
- Agent config files get owner-only permissions (`0600`) after AgentHub writes secrets into them.
- Older registry entries with a single `secretKey` are read and migrated automatically.

### Per-agent switches

Each cell in the servers grid turns a server on or off for one agent. For example, add a Figma server and keep it only in Codex. Turning a cell off removes the server from that agent's config. Turning it on writes it back with the current keys.

To change many at once:

- **A whole agent**: the checkbox under the agent's name in the column header turns that agent on for every server it can run, or off for all of them. It shows a dash when only some are on. Servers the agent already has from elsewhere are skipped when turning on, since replacing those needs a confirmation each.
- **A whole server**: **Enable for All Agents** / **Disable for All Agents** in the row's ⋯ menu or its right-click menu.

An agent that is not installed is shown greyed out and skipped.

### Importing existing servers

**Import** scans every agent's config, plus project `.mcp.json` files that Claude Code knows about, and lists the servers it finds:

- The same server found in several agents is shown once.
- When agents disagree (different args or keys), every variant is listed and the most common one is suggested.
- Values that look like secrets (tokens in env, headers or arguments) go into keys in the Keychain, not into the registry.
- Importing a server with a name already in the registry asks before overwriting it.

After import, the servers are written to every agent you leave switched on, so they end up everywhere.

### Snapshots

Before AgentHub changes an agent's config, it copies the file to
`~/Library/Application Support/AgentHub/snapshots/<timestamp>_<action>/`. The last 100 snapshots are kept. To undo a change by hand, copy a file back.

## Usage limits

| Agent | Source | What you see |
|---|---|---|
| **Claude** | `https://api.anthropic.com/api/oauth/usage` with Claude Code's own sign-in (Keychain item `Claude Code-credentials`) | 5-hour session, weekly (all models), weekly per model; plan; reset times |
| **Antigravity** | Google Cloud Code endpoints `loadCodeAssist` and `fetchAvailableModels` with `agy`'s sign-in (Keychain `gemini` / `antigravity`) | quota left per model (shown as "left", the way the service reports it) and reset time. The list includes Claude and GPT-OSS models because Antigravity offers them itself, each with its own quota |
| **Codex** | the latest `rate_limits` event and the `token_count` events in `~/.codex/sessions/**/*.jsonl` | 5-hour and weekly windows and plan (ChatGPT sign-in), as of the last Codex turn; tokens spent today for any sign-in, API key included: total, an hourly chart, and the split between cached input, new input and output |

- Limits refresh when the panel opens (if older than 30 s), from **Refresh**, and every 5 minutes in the background.
- An Antigravity quota that hasn't been touched shows no reset time: the service reports "now + 7 days" for it, which moves on every read.
- Percentages are colored by how much is used: green, then orange from 70 %, red from 90 %.
- When a window crosses **80 %**, the notch shows an alert once for that window.
- An expired Antigravity token is renewed by running `agy models`, which refreshes it the way `agy` itself does.
- These are the same endpoints the agents use themselves. They are not public APIs and may change.

## Sessions and alerts

AgentHub scans running sessions every 2 seconds, using only what the agents already write to disk plus the process table. No hooks or agent config are needed.

| Agent | How it is detected | States |
|---|---|---|
| Claude Code | `~/.claude/sessions/<pid>.json` (`status`, `waitingFor`, `cwd`, `name`), checked against live processes | working, waiting (with reason), idle |
| Codex | `codex` processes (not `app-server` / `mcp-server`) and their rollout file in `~/.codex/sessions` (`task_started` without `task_complete` = working) | working, idle |
| Antigravity | `agy` processes (not `acp`) | running |

A session's working directory and parent apps come from `libproc` / `sysctl`.

Alerts appear as a pill under the notch:

- **Finished**: a turn that was seen in progress has ended. Fades after a few seconds.
- **Waiting / needs permission**: stays until the session continues or exits.
- **Limit**: a usage window crossed 80 %.

Click an alert or a session to bring its terminal or IDE to the front. AgentHub walks up the process tree to the first regular app.

## Accounts

AgentHub keeps several sign-ins per agent and swaps which one the agent uses.

| Agent | The sign-in it swaps |
|---|---|
| Claude Code | Keychain `Claude Code-credentials` (`claudeAiOauth`) and `oauthAccount` in `~/.claude.json` |
| Codex | `~/.codex/auth.json` |
| Antigravity | Keychain `gemini` / `antigravity` |

- **The account in use is saved automatically.** Each refresh captures the current sign-in, so it is always in the list.
- **Switch**: AgentHub saves the current sign-in and puts the chosen one in its place.
- **Add Account**: AgentHub saves the current sign-in, clears the slot and opens Terminal with the agent's login (`claude auth login`, `codex login`, `agy`). The new account is picked up as soon as you sign in. **Cancel** puts the previous one back.
- **Forget** removes a saved account that isn't in use.
- Claude Code and Codex rewrite their sign-in while running (token refresh, state on exit), so AgentHub **refuses to switch while any of their sessions are running**. Close them first. Antigravity can be switched any time.
- AgentHub never calls an agent's own logout, so switching doesn't revoke the other account's tokens.

Saved sign-ins are kept in the Keychain (services `dev.agenthub.claude`, `dev.agenthub.codex`, `dev.agenthub.antigravity`). Only the email, sign-in method and dates go into `*-accounts.json`.

## Launch at login

On the first launch from `/Applications`, AgentHub registers itself as a login item (`SMAppService`). Turn it off with the **Launch at Login** toggle in the menu bar or in System Settings → General → Login Items. A copy running from `build/` doesn't register, so dev builds don't take over the login item.

## Files AgentHub keeps

All in `~/Library/Application Support/AgentHub/` (directory `0700`, files `0600`):

| File | Contents |
|---|---|
| `registry.json` | MCP servers: name, transport, command/args or URL, key names, agent switches. No values. |
| `snapshots/` | Copies of agent configs taken before each change (last 100). |
| `claude-accounts.json`, `codex-accounts.json`, `antigravity-accounts.json` | Saved accounts' metadata. No tokens. |
| `<agent>-sign-in.command` | The Terminal script used by "Add Account". |

Keychain items:

| Service | Contents |
|---|---|
| `dev.agenthub.mcp` | MCP key values of all servers, one JSON item (account `servers`) |
| `dev.agenthub.claude`, `dev.agenthub.codex`, `dev.agenthub.antigravity` | Saved sign-ins, one item per account |

## Security

What AgentHub does:

- Secrets live in the Keychain. The registry and account files hold no tokens.
- Agent configs that contain secrets are set to `0600`. AgentHub's own files are `0600` and its directories `0700`.
- Keychain writes go through `security -i` on stdin, so tokens never appear in process arguments. Claude's item is written hex-encoded.
- Key values with line breaks or NUL are rejected, so they can't inject extra config.
- Overwriting an existing server on import needs confirmation.
- No telemetry. Network requests go only to the usage endpoints above, with the agents' own tokens.

Known trade-offs:

- **Agents need secrets in plain text in their own configs**, for example Codex's `config.toml` or Cursor's `mcp.json`. AgentHub can't change that. It only restricts the file permissions.
- **Command-line arguments are visible to other local processes.** Prefer keys (env vars/headers) over tokens in args. Import moves tokens it finds in args into keys where it can.
- **`npx` packages aren't pinned** unless you pin them (`pkg@1.2.3`) in the server's args.
- Antigravity's usage endpoint only answers requests with `User-Agent: antigravity`, so AgentHub sends that header.
- The app is **ad-hoc signed**, not notarized. Build it yourself from source.

## Architecture

A Swift package with three targets:

```
Sources/
  AgentHubCore/          models and logic, no UI, unit-tested
    Models.swift           AgentID, Transport, MCPServer (keys, validation)
    AgentStatus.swift      which agents are installed
    Adapters.swift         one adapter per agent: read, write, remove servers
    ConfigFiles.swift      JSON and format-preserving TOML editing, private file writes
    MCPSync.swift          applies a server to every agent, with snapshots
    Stores.swift           paths, registry, Keychain, snapshots
    ServerImport.swift     finds and merges servers from agent configs
    Usage.swift            limit readers for Claude, Antigravity, Codex
    Sessions.swift         session scanner and process table (libproc/sysctl)
    Accounts.swift         sign-in slots, account vault, switcher (Claude, Codex)
    AntigravityAccounts.swift
    CommandRunner.swift    runs CLIs through the login shell's PATH
  AgentHub/              the app (SwiftUI + AppKit)
    App/                   AgentHubApp (composition root), menu bar
    Stores/                ServerStore, UsageStore, SessionStore, AccountsStore,
                           LoginItemStore, NavigationStore
    Notch/                 NotchStore, NotchController (panels, hover), NotchPanelView
    Views/                 MainView, Servers/, Usage/, Accounts/
Tests/
  AgentHubCoreTests/
```

The app follows **MV (Model–View with Stores)**:

- **Stores** are `@Observable @MainActor` classes, one per area. They own state and actions and call into `AgentHubCore`. There are no view models.
- **Views** read stores from the SwiftUI environment and call their methods. Views never create stores.
- **Stores don't know about each other.** They publish domain events, such as `SessionStore.onEvent`, `UsageStore.onLimitCrossed` and `NotchStore.onExpand`, and `Stores.connect()` wires them together. For example, a waiting session becomes a notch alert, and opening the notch refreshes limits.
- **`AppDelegate` is the composition root.** It creates `Stores` once, the `NotchController` (which follows `NotchStore` via observation) and the main window on demand.
- Every store has a `preview()` with sample data for SwiftUI previews.

To add an agent:

1. Add a case to `AgentID`.
2. Write an `AgentAdapter` (config path, read, write, remove).
3. Register the adapter in `Agents.detect` (`AgentStatus.swift`).
4. Optionally, add a usage reader, a session scanner or a `SignInSlot` for account switching.

## Development

```sh
swift build                       # build everything
swift test                        # run AgentHubCore tests
./scripts/dev.sh                  # live loop: rebuild and relaunch on every save
./scripts/build-app.sh --debug    # debug .app in build/
./scripts/build-app.sh --install  # release .app into /Applications
./scripts/format.sh               # format the code in place
./scripts/lint.sh                 # fail on any formatting or lint finding
```

Formatting and linting use two tools:

- **swift format** (Apple's swift-format, part of the Swift 6 toolchain) handles layout: 4-space indentation, lines up to 140 characters, trailing commas, import order. Config: `.swift-format`.
- **SwiftLint** (`brew install swiftlint`) checks style and common mistakes. Config: `.swiftlint.yml`. Rules that overlap with swift format's layout are turned off.

Run `./scripts/format.sh` before committing, and `./scripts/lint.sh` to check.

`scripts/dev.sh` watches `Sources/` and `Package.swift`. A failed build keeps the previous app running and prints the errors.

Tests cover TOML editing, CLI argument building, JSON configs, sync, multiple keys, import and merging, project scope, usage parsing, value validation, session state and account switching. They use temporary directories and a fake command runner, so they never touch your real configs or Keychain.

## Troubleshooting

- **A server doesn't show up in an agent.** Restart the agent: they read config at start. Check that the agent's cell is on in the grid, and that the agent shows as installed.
- **"command not found" for `claude` / `codex` / `agy`.** AgentHub uses your login shell's `PATH`. Make sure the CLI works in a new Terminal window.
- **Claude limits fail with 401.** Sign in to Claude Code again (`claude auth login`).
- **Antigravity limits fail.** Run `agy models` once in Terminal to refresh the sign-in.
- **Codex limits are old.** They come from the last Codex turn. Run something in Codex to update them.
- **Keychain prompts after every rebuild.** That's ad-hoc signing. Choose **Always Allow**, or sign the build with your own certificate.
- **The notch panel doesn't open.** The cursor has to rest on the notch for a moment. On screens without a notch, use the top center of the screen or the menu bar icon.
- **Undo a config change.** Copy the file back from `~/Library/Application Support/AgentHub/snapshots/`.

## License

[MIT](LICENSE) © 2026 Denys Bilousenko
