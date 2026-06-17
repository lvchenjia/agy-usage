# agy-usage

A lightweight native macOS menu bar app that monitors your [Antigravity (agy)](https://antigravity.google) 5-hour rolling quota in real time.

## Features

- **⚡ Real-time quota display** in the macOS menu bar
- **Dynamic color coding**: green (>50%), orange (20-50%), red (<20%)
- **Grouped model quotas**: Gemini and Claude/GPT-OSS displayed separately with progress bars and countdown timers
- **Dynamic port discovery**: Automatically detects the active `agy` daemon on any port via `lsof`
- **Offline resilience**: Gracefully handles agy daemon restarts or offline state
- **Display toggles**: Show/hide icon and/or percentage number independently
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

This compiles `main.swift` with `swiftc` and packages the result into `AgyStatus.app`.

## Run

```bash
open AgyStatus.app
```

Or double-click `AgyStatus.app` in Finder. The app will appear in your menu bar with no Dock icon.

## Auto-start at Login

1. Open **System Settings** → **General** → **Login Items**
2. Click `+` and select `AgyStatus.app`
