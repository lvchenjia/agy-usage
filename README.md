# Agy Usage

<p align="center">
  <strong>A lightweight, native macOS menu bar app for Google Antigravity (AGY) quota monitoring, live token speed tracking, and remote control management.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> •
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013%2B-blue?logo=apple" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white" alt="Swift 6.1" />
  <img src="https://img.shields.io/badge/Dependencies-Zero-success" alt="Zero Dependencies" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License" />
</p>

---

## Overview

**Agy Usage** is designed specifically for developers using **Google Antigravity (AGY)** CLI and IDE. Built entirely with native Swift and AppKit, it runs with zero third-party dependencies, consumes virtually zero CPU, and uses under 25MB of RAM.

It keeps you informed of your 5-hour rolling quota, weekly quota, active Google account status, live generation token speed, and Antigravity Remote Control daemon directly from your macOS menu bar.

---

## Key Features

### 1. Minimalist Menu Bar Status
* **Distraction-Free Typography**: Displays clean, monospaced text such as **`G96`** (14pt Regular), indicating Gemini's remaining quota percentage.
* **Remote Control Indicator**: Seamlessly transitions to **`G96 R`** when the Antigravity Remote Control daemon is active, and automatically restores to **`G96`** when stopped.

### 2. Google Account Profile Header
* **Live Account Card**: The top row of the dropdown menu displays the currently authenticated Google user with their high-resolution circular profile photo.
* **Tier Badge & Identifier**: Displays username (e.g., `Alex`), active subscription pill tag (e.g., `Google AI Pro`), and full email address (`alex@example.com`).
* **Direct Navigation**: Clicking the profile card opens your Antigravity Web Console directly in your default browser.

### 3. Dual-Window Quota Cards (5h + Weekly)
* **Dual Progress Tracking**: Separate, dedicated cards for **Gemini Models** and **Claude & GPT Models**.
* **Comprehensive Limits**: Monitors both the short-term **5-Hour Rolling Limit** and the long-term **Weekly Limit** simultaneously.
* **Countdown Timers**: Precise reset countdowns (e.g., `in 4h 55m` or `in 5d 21h`).

### 4. Interactive Remote Control Hub
* **Web Console Access**: One-click menu item `Open Remote Control Web...` navigating directly to `https://antigravity.google.com`.
* **Daemon Management**: Toggle between `Start Remote Control` and `Stop Remote Control`.
* **In-Flight Debouncing & Anti-Spam**:
  * Displays real-time transitional states (`Starting Remote Control...` / `Stopping Remote Control...`).
  * Disables the menu item while in progress to prevent repeated clicks, process collision, or launchd registration issues.

### 5. Real-Time Token Analytics Dashboard (`Cmd + T`)
* **Live Generation Speed**: Real-time 3-minute rolling speed indicator in the window status bar:
  * 🟢 **`Live: 44.2 tok/s (3m)`** with active status during code generation.
  * `○ Live: Idle` after 3 minutes of inactivity.
  * Accompanied by the comprehensive **`Window Avg: 45.8 tok/s`**.
* **Flexible Time Filters**: Switch between **5 Minutes**, **1 Hour**, **5 Hours**, **24 Hours**, **7 Days**, or **All History**.
* **Per-Model Inset Table**: Detailed breakdown showing:
  * Input Tokens, Output Tokens, Total Tokens
  * Timed Output Tokens, Speed (tok/s), Call Count, and Model Share (%)
* **WAL-Safe SQLite Engine**: Reads active conversation databases using URI mode `mode=ro&immutable=1`, completely avoiding lock contention with the Antigravity CLI while maintaining 1-to-1 token/duration matching.

---

## Menu Layout

```
┌──────────────────────────────────────────────┐
│  (Avatar)  Alex  [Google AI Pro]             │
│            alex@example.com                  │
├──────────────────────────────────────────────┤
│  Gemini Models                               │
│  5h Limit · resets in 4h 55m          99%    │
│  [======================================-]   │
│  Weekly Limit · resets in 5d 21h      92%    │
│  [==================================-----]   │
├──────────────────────────────────────────────┤
│  Claude and GPT models                       │
│  5h Limit · resets in 5h 00m         100%    │
│  [=======================================]   │
│  Weekly Limit · resets in 50m        100%    │
│  [=======================================]   │
├──────────────────────────────────────────────┤
│  Open Remote Control Web...                  │
│  Stop Remote Control                         │
│  Token Usage Dashboard...             ⌘T     │
├──────────────────────────────────────────────┤
│  Auto-Quit if Offline                        │
├──────────────────────────────────────────────┤
│  Refresh                              ⌘R     │
│  Quit                                 ⌘Q     │
└──────────────────────────────────────────────┘
```

---

## Technical Architecture

* **Zero External Dependencies**: Pure Swift 6.1 + AppKit. No third-party package managers required.
* **Auto-Discovery Engine**: Discovers active local Language Server daemon ports and CSRF tokens automatically using `lsof`, process inspection, and secure token files (`/tmp/agy_csrf_token`).
* **Multi-Turn WAL Isolation**: Directly inspects `~/.gemini/antigravity-cli/brain/*/` SQLite conversation databases in immutable read-only mode to prevent file-locking errors.
* **Async Concurrency**: All network queries, CLI invocations (`agy remote-control`), and disk I/O run on background dispatch queues, guaranteeing the macOS menu bar remains 100% responsive.

---

## Build & Installation

### Requirements
* macOS 13.0 (Ventura) or later (Apple Silicon & Intel)
* Xcode Command Line Tools (`xcode-select --install`)

### Build & Install
Run the build script from the repository root:

```bash
./build.sh
```

This compiles optimized Swift source files and packages the application directly into:
```
/Applications/Agy Usage.app
```

### Launch
```bash
open -a "/Applications/Agy Usage.app"
```

The application will immediately appear in your macOS status bar without cluttering your Dock.

---

## Keyboard Shortcuts

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| <kbd>⌘</kbd> + <kbd>T</kbd> | **Open Dashboard** | Opens the Token Analytics & Speed Dashboard |
| <kbd>⌘</kbd> + <kbd>R</kbd> | **Refresh** | Immediately re-probes local daemon and updates quotas |
| <kbd>⌘</kbd> + <kbd>Q</kbd> | **Quit** | Exits the Agy Usage application |

---

## Auto-Start on System Login

### Method A: Terminal Command
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Agy Usage.app", hidden:false}'
```

### Method B: System Settings
1. Open **System Settings** → **General** → **Login Items**.
2. Click the **+** button under **Open at Login** and select `/Applications/Agy Usage.app`.

---

## Git Commit Guidelines

This project strictly adheres to the [Conventional Commits](https://www.conventionalcommits.org/) standard. Detailed rules, scopes, and subject length limits are documented in [COMMIT_CONVENTION.md](COMMIT_CONVENTION.md).

```bash
# Format
<type>(<scope>): <subject>

# Example
feat(menubar): show 'R' suffix when remote control daemon is running
```

---

## License

This project is licensed under the [MIT License](LICENSE).
