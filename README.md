# agy-usage

A lightweight native macOS menu bar app that monitors your [Antigravity (agy)](https://antigravity.google) 5-hour rolling quota in real time.

## Features

- **⚡ Real-time quota display** in the macOS menu bar (fully monochrome to match system theme)
- **Dynamic color coding in dropdown**: green (>50%), orange (20-50%), red (<20%)
- **Grouped model quotas**: Gemini and Claude displayed separately with progress bars and countdown timers
- **Dynamic port discovery**: Automatically detects the active `agy` daemon on any port via `lsof`
- **Offline resilience**: Gracefully handles agy daemon restarts or offline state
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

Antigravity natively supports running hooks at session start. Create or add to `~/.gemini/config/hooks.json`:

```json
{
  "agy-usage-autostart": {
    "enabled": true,
    "SessionStart": [
      {
        "type": "command",
        "command": "/Users/horse/Desktop/agy-usage/launch_hook.sh",
        "timeout": 10
      }
    ]
  }
}
```

This guarantees `Agy Usage.app` is silently launched and authenticated whenever `agy` starts anywhere.

### Method B: Via Terminal zsh wrapper

Add this wrapper function to your `~/.zshrc`:

```zsh
agy() {
    if [[ -n "$ANTIGRAVITY_CSRF_TOKEN" ]]; then
        echo -n "$ANTIGRAVITY_CSRF_TOKEN" > /tmp/agy_csrf_token
    fi
    if ! pgrep -fl "AgyUsage" > /dev/null 2>&1; then
        open "/Applications/Agy Usage.app"
    fi
    command agy "$@"
}
```

## Auto-start at System Login

1. Open **System Settings** → **General** → **Login Items**
2. Click `+` and select `/Applications/Agy Usage.app`
