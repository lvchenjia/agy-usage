# agy-usage

A lightweight native macOS menu bar app that monitors your [Antigravity (agy)](https://antigravity.google) 5-hour rolling quota in real time.

## Features

- **⚡ Real-time quota display** in the macOS menu bar (fully monochrome to match system theme)
- **Dynamic color coding in dropdown**: green (>50%), orange (20-50%), red (<20%)
- **Grouped model quotas**: Gemini and Claude displayed separately with progress bars and countdown timers
- **Dual Support**: Works seamlessly with both **Antigravity CLI** (`agy`) and **Antigravity IDE**
- **Dynamic port & token discovery**: Automatically detects active daemon ports (`5xxxx`) and CSRF tokens via `lsof`, process arguments, and hook-persisted tokens
- **Offline resilience**: Gracefully handles daemon restarts or offline states
- **Display toggles**: Show/hide icon and/or percentage number independently
- **Auto-quit if offline**: Optionally auto-terminates the app when the agy daemon goes offline
- **Auto-refresh**: Polls every 60 seconds, or manually via the "Refresh" menu item

## How it Works

The app queries the local `agy` daemon's Connect JSON RPC endpoint:

```
POST http://127.0.0.1:{PORT}/exa.language_server_pb.LanguageServerService/GetUserStatus
```

It discovers the active port dynamically by scanning `lsof` for `agy` processes in `LISTEN` state, always picking the port belonging to the most recently started daemon.

## Build

Requires macOS 13+ and Xcode Command Line Tools.

```bash
bash build.sh
```

This compiles `main.swift` with `swiftc` and packages the result into `/Applications/Agy Usage.app`.

## Run

```bash
open "/Applications/Agy Usage.app"
```

The app will appear in your menu bar with no Dock icon.

## Auto-start on agy CLI invocation

### Method A: Via Antigravity Lifecycle Hook (Recommended)

Antigravity natively supports running hooks at session start and before invocations. Create or add to `~/.agents/hooks.json`:

```json
{
  "agy-usage-sync": {
    "enabled": true,
    "SessionStart": [
      {
        "type": "command",
        "command": "/Users/horse/Desktop/agy-usage/launch_hook.sh"
      }
    ],
    "PreInvocation": [
      {
        "type": "command",
        "command": "/Users/horse/Desktop/agy-usage/launch_hook.sh"
      }
    ]
  }
}
```

This guarantees `Agy Usage.app` is silently launched and authenticated with the fresh CSRF token whenever `agy` starts or runs anywhere.

### Method B: Via Terminal zsh wrapper

Add this wrapper function to your `~/.zshrc`:

```zsh
agy() {
    local token_file="/tmp/agy_csrf_token"
    if [[ ! -s "$token_file" ]]; then
        uuidgen | tr -d '\n' | tr '[:upper:]' '[:lower:]' > "$token_file"
    fi
    local csrf_token
    csrf_token=$(cat "$token_file")
    export ANTIGRAVITY_CSRF_TOKEN="$csrf_token"

    if ! pgrep -fl "AgyUsage" > /dev/null 2>&1; then
        open "/Applications/Agy Usage.app"
    fi
    command agy --csrf_token="$csrf_token" "$@"
}
```

## Auto-start at System Login

### Method A: One-line Terminal Command
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Agy Usage.app", hidden:false}'
```

### Method B: Via macOS Settings
1. Open **System Settings** → **General** → **Login Items**
2. Click `+` and select `/Applications/Agy Usage.app`

## Troubleshooting

### App shows "Antigravity is offline"

1. **Daemon not started**: Ensure either `agy` CLI or **Antigravity IDE** is currently running.
2. **Missing CSRF Token**:
   - For `agy` CLI: Ensure you have configured `~/.agents/hooks.json` (Method A above). Antigravity will pass `$ANTIGRAVITY_CSRF_TOKEN` to `launch_hook.sh` on session start, saving it to `/tmp/agy_csrf_token`.
   - For Antigravity IDE: The app automatically detects `--csrf_token <uuid>` and `--https_server_port` from running IDE language server processes.
3. **Manual Refresh**: Click on the menu bar icon and select **"Antigravity is offline (Click to retry)"** or **"Refresh"**.

