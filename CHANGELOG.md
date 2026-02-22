# Changelog — ⚡ tty

All notable changes. Version is defined in `version.py`.

---

## [1.1] — 2026-02-22

### 📱 LAN & Mobile Access

**Added**
- Server binds to `0.0.0.0` by default — accessible from any device on the network
- LAN IP auto-detection and display on startup
- QR code printed in terminal for quick phone scanning (requires `qrcode` package)
- LAN URL shown in web UI header (click to copy)
- Help panel: "Mobile / LAN Access" section with setup steps
- CLI flags: `--host`, `--port`, `--local`, `--no-browser`
- `/api/info` returns `lan_ip` and `port`

**Supported clients**: iOS Safari, Android Chrome, any modern browser on the same network.

---

## [1.0] — 2026-02-22

### 🎉 Initial Release

**Core**
- Web-based serial terminal with script editor and live output
- FastAPI backend with WebSocket for real-time serial data
- Cross-platform: Linux, Windows, MSYS2 UCRT64, Git Bash, WSL, macOS
- Auto-detection of serial ports (COM* on Windows, /dev/tty* on Linux)
- MSYS2/Git Bash port mapping (`/dev/ttyS2` → `COM3`)

**Two Modes**
- **Simple mode** — clean minimal UI: connect, paste, send, done
- **Advanced mode** — full control: profiles, commands, replay, hex, settings

**Bash Launcher (`launch.sh`)**
- Interactive menu with simple/advanced modes
- Auto-detection: environment, Python, pip, dependencies, serial ports
- Self-fixing line endings on first run
- One-click dependency install/uninstall
- Full system status diagnostic
- Colored output (auto-detects terminal support)
- Predefined commands (12 built-in + custom management)
- Profile management: add, switch, delete, export/import
- Settings: connection, line endings, behavior, reconnect, logging
- Session replay in terminal (real-time or sped up)
- Log viewer: full, last 50, errors only, clear, export
- Config export/import
- First-run wizard

**Config System (`ssl.conf`)**
- JSON config, auto-created on first run
- Connection: port, baud, data bits, parity, stop bits, flow control, DTR/RTS, local echo, line delay, line ending mode
- Behavior: auto-execute, auto-open browser, dangerous command guard, dry-run, syntax check
- Reconnect: enabled, interval, max retries, resend on reconnect
- Logging: enabled, format (txt/jsonl), max sessions, max size, auto-cleanup
- Board profiles with per-profile commands
- Last session state persistence
- Deep merge on load

**Backend (`app.py`)**
- Full serial settings: data bits, parity, stop bits, flow control, DTR/RTS
- Auto-reconnect: background task detects cable disconnect, auto-retries
- Connection states broadcast via WebSocket (connected/reconnecting/disconnected)
- Session logging: dual format (plain text + structured JSONL)
- Session replay API
- Config API with deep merge
- Profiles API: list, switch, save, delete
- Commands API: 12 built-in + custom save/run
- Dangerous command guard
- Line ending normalization (auto/force LF/preserve)
- Dry-run mode
- Upload with line ending normalization
- Auto-cleanup of old sessions

**Web UI (`index.html`)**
- Script editor with tab support, drag & drop, file upload
- Live serial terminal with ANSI color parsing
- Hex display toggle (offset + hex bytes + ASCII representation)
- Command input with history (↑/↓)
- Profile dropdown switcher
- Flow control, line delay, remote path, auto-run, dry-run, EOL mode
- Quick command buttons + "More..." dropdown
- Session replay player
- Confirm modal for dangerous commands
- Scrollback limit (10,000 lines)
- Built-in help panel (? button) with 9 sections
- Connection status indicator with reconnect animation
- Mode toggle persisted to config

**Versioning**
- `version.py` — single source of truth for app name, version, icon
- Version displayed in: browser tab, header badge, help panel, bash menus, API, logs
- Zip package named `tty-v{VERSION}.zip`

**Documentation**
- `README.md` — full feature docs, platform support, troubleshooting
- `CHANGELOG.md` — version history
- `CHEATSHEET.md` — quick reference card with all shortcuts, API endpoints, menu map
