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

To automatically launch the status bar app whenever you run `agy` in your terminal, add this wrapper function to your `~/.zshrc`:

```zsh
agy() {
    if ! pgrep -x "AgyUsage" > /dev/null; then
        # Delay launch by 2 seconds in background to allow agy daemon to spin up
        (sleep 2 && open "/Applications/Agy Usage.app") &!
    fi
    command agy "$@"
}
```

## Auto-start at System Login

1. Open **System Settings** → **General** → **Login Items**
2. Click `+` and select `/Applications/Agy Usage.app`
