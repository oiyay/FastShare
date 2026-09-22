# 🚀 FastShare

Cross-platform file sharing app for **Android** and **Windows**.

Share files between your devices quickly over your local Wi-Fi network — no internet required!

## Features

- 📱↔️🖥️ **Android ↔ Windows** file sharing via local network (HTTP + UDP Discovery)
- 📱↔️📱 **Android ↔ Android** file sharing via Nearby Connections (Wi-Fi Direct, no router needed!)
- 📂 **Stream-based transfer** — handles files of any size without crashing
- 🔍 **Auto-discovery** — devices find each other automatically on the same network
- ⚡ **Fast** — uses full Wi-Fi bandwidth

## Architecture

```
                    ┌─────────────────────────────────┐
                    │        TransportManager          │
                    │  (Auto-selects best transport)   │
                    └──────────┬──────────┬────────────┘
                               │          │
                    ┌──────────▼──┐  ┌────▼─────────────┐
                    │ HttpTransport│  │ NearbyTransport   │
                    │  (LAN/Wi-Fi) │  │ (Wi-Fi Direct)    │
                    └─────────────┘  └───────────────────┘
                    
Discovery: UDP Broadcast → find devices on same network
Transfer:  HTTP Streaming → cross-platform, large file safe
           Nearby Connections API → Android-to-Android P2P
```

## Building

Builds are automated via GitHub Actions:

- **APK** (Android): Built on `ubuntu-latest`
- **EXE** (Windows): Built on `windows-latest`

Download the latest build from the [Releases](../../releases) page or the [Actions](../../actions) tab.

### First Time Setup

1. Push code to GitHub
2. Go to **Actions** tab → **"Initialize Flutter Project"** → **"Run workflow"**
3. This generates the platform directories (`android/`, `windows/`)
4. Subsequent pushes will auto-build APK + EXE

## Tech Stack

- **Flutter** — Cross-platform UI framework
- **shelf** — HTTP server for receiving files  
- **Nearby Connections** — Google's P2P API for Android
- **UDP Broadcast** — Device discovery on LAN

## Project Structure

```
lib/
├── main.dart                          # App entry point
├── core/
│   ├── models/
│   │   ├── device_info.dart           # Device discovery model
│   │   └── transfer_request.dart      # Transfer request/response models
│   └── transport/
│       ├── transport_interface.dart    # Abstract transport contract
│       ├── http_transport.dart         # HTTP-based transport (cross-platform)
│       ├── nearby_transport.dart       # Nearby Connections (Android-Android)
│       └── transport_manager.dart      # Smart transport auto-selector
└── ui/
    ├── home_screen.dart               # Main UI screen
    └── widgets/
        ├── device_tile.dart           # Device list item widget
        └── transfer_tile.dart         # Transfer progress widget
```

## License

MIT
