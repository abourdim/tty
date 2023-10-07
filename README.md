# ⚡ tty

> **Version**: see `version.py` — single source of truth for app name & version.

A web-based tool to send and execute bash scripts on a Linux board over serial — no network required. Includes a terminal menu launcher, live serial terminal, session recording, hex display, profiles, and more.

Works on **Linux**, **Windows** (cmd/PowerShell), **MSYS2 UCRT64**, **Git Bash**, **WSL**, and **macOS**.

---

## Quick Start

### Option 1: Launcher (recommended)

```bash
bash launch.sh
```

First run walks you through setup: picks your mode, detects Python, installs dependencies automatically.

### Option 2: Direct

```bash
pip install -r requirements.txt
python app.py
```

Browser opens at **http://localhost:8000**.

---

## Versioning

All version info lives in one place:

```python
# version.py
APP_NAME = "tty"
APP_VERSION = "1.3"
APP_ICON = "⚡"
```

This is read by:
- `app.py` — imports directly, serves via `/api/info`
- `launch.sh` — parses on startup, shows in all menus and logs
- `index.html` — fetches from `/api/info`, sets title, header, and help panel

To bump the version, edit **only** `version.py`. Everything else updates automatically.

---

## Two Modes

### Simple

Minimal UI. Connect a port, paste a script, click Send & Run. No clutter.

Best for: quick one-off tasks, beginners, embedded devs who just need to push a script.

### Advanced

Full control. Profiles, predefined commands, session replay, hex display, flow control, dry-run, line ending config, and more.

Best for: multi-board workflows, debugging protocols, production setups.

Switch anytime from the web UI (gear icon) or the bash menu.

---

## Features

### Core

- **Script editor** — paste, type, or drag & drop `.sh` files
- **Live serial terminal** — real-time output via WebSocket
- **Command input** — type commands directly, with history (↑/↓ arrows)
- **Hex display** — toggle HEX button to see raw bytes as hex dump
- **Drag & drop** — drop `.sh` files into the editor
- **Tab key** — inserts spaces in the editor (not focus change)
- **Built-in help** — `? Help` button with keyboard shortcuts, feature reference, troubleshooting

### Connection

- **Port auto-detection** — scans COM ports (Windows) and /dev/tty* (Linux)
- **Baud rate** — configurable, default 115200
- **Flow control** — None, RTS/CTS, XON/XOFF, DSR/DTR (advanced)
- **Data bits / Parity / Stop bits** — full serial config (advanced)
- **DTR/RTS line control** — for boards that use DTR to reset (advanced)
- **Auto-reconnect** — detects cable disconnect, retries automatically
- **Local echo** — configurable (advanced)

### Script Transfer

- **Line-by-line send** — configurable delay to prevent garbled characters
- **Line ending normalization** — auto-fixes CRLF → LF, configurable
- **Remote path** — choose where the script is saved on the board
- **Auto-run toggle** — send only or send + execute
- **Dry-run mode** — sends script but doesn't execute (advanced)
- **Dangerous command guard** — blocks `rm -rf /`, `mkfs`, `reboot` etc. with confirmation

### Profiles

- Save connection settings per board (port, baud, custom commands)
- Switch profiles instantly from the web UI or bash menu
- Export/import profiles across machines

### Predefined Commands

12 built-in + unlimited custom:

| Command | What it runs |
|---|---|
| board_info | `uname -a && cat /etc/os-release` |
| disk | `df -h` |
| memory | `free -h` |
| cpu | `cat /proc/cpuinfo \| head -20` |
| uptime | `uptime` |
| ip_addr | `ip addr show` |
| interfaces | `ip link show` |
| connections | `ss -tulnp` |
| processes | `ps aux \| head -20` |
| services | `systemctl list-units --type=service --state=running` |
| kernel_log | `dmesg \| tail -30` |
| sync | `sync` |

Add custom commands via `commands.conf` or the web UI.

### Session Logging & Replay

- Every session logged in dual format:
  - `.log` — human-readable plain text with timestamps
  - `.jsonl` — structured events with millisecond precision (for replay)
- Replay sessions in the terminal (real-time or sped up) or web UI
- Search within sessions
- Auto-cleanup: configurable max sessions and max size

### Hex Display

Toggle the HEX button to switch between text and hex view:

```
00000000  68 65 6c 6c 6f 20 77 6f  72 6c 64 0a 72 6f 6f 74  |hello world·root|
00000010  40 62 6f 61 72 64 3a 7e  23 20                      |@board:~#       |
```

- Offset (gray) | Hex bytes (blue, 8+8) | ASCII (green, non-printable as ·)
- Switch back and forth without losing data (64KB raw buffer)
- CR/LF highlighted in amber

---

## Mobile / LAN Access

The server binds to `0.0.0.0` by default, making the UI accessible from any device on the same network — including phones and tablets.

### Setup

1. Run `bash launch.sh` or `python app.py` on the machine with the serial cable
2. Note the **LAN URL** shown in the terminal (e.g. `http://192.168.1.42:8000`)
3. Scan the **QR code** printed in the terminal, or type the URL on your phone
4. Use the full UI from your phone — send scripts, view output, run commands

### CLI Flags

```bash
python app.py                    # default: 0.0.0.0:8000 (LAN accessible)
python app.py --local            # localhost only (127.0.0.1)
python app.py --port 9000        # custom port
python app.py --host 10.0.0.5    # bind to specific interface
python app.py --no-browser       # don't auto-open browser
```

### Platform Support

| Device | Status |
|---|---|
| iOS Safari | ✓ Full UI (as remote client) |
| Android Chrome | ✓ Full UI (as remote client) |
| Any modern browser | ✓ |
| Android (Termux) | ✓ Can also run the server |
| iOS | ✗ Cannot run the server |

The web UI is fully responsive — switches to stacked layout on screens under 900px.

---

## Bash Launcher (launch.sh)

Interactive menu with auto-checks. Reads app name and version from `version.py`:

```
╔══════════════════════════════════════════╗
║   ⚡ tty v1.3                            ║
║   Profile: raspberrypi                   ║
║   Environment: linux                     ║
║   Python: 3.12.3 ✓                       ║
║   Dependencies: 4/4 installed ✓          ║
║   Serial ports: 2 found                  ║
╠══════════════════════════════════════════╣
║   1) Launch web app                      ║
║   2) Install / update dependencies       ║
║   3) Check system status                 ║
║   ...                                    ║
╚══════════════════════════════════════════╝
```

Features: environment detection, dependency management, serial port scanning, profile management, predefined commands over serial, session replay in terminal, log viewer, settings editor, config export/import.

---

## Configuration (ssl.conf)

Auto-created on first run. JSON format. Key sections:

```json
{
  "mode": "simple",
  "active_profile": "default",
  "connection": { "port": "", "baudrate": 115200, "flow_control": "none", ... },
  "behavior": { "auto_execute": true, "dangerous_cmd_guard": true, "dry_run": false, ... },
  "reconnect": { "enabled": true, "interval_seconds": 3, ... },
  "logging": { "enabled": true, "max_sessions": 50, "max_size_mb": 100, ... },
  "profiles": { "default": { "port": "", "baudrate": 115200 } },
  "last_session": { "last_port": "", "last_script": "", ... }
}
```

Edit via the bash menu (Settings → Edit raw config) or directly.

---

## Platform Support

| Environment | Serial Ports | Notes |
|---|---|---|
| Linux | `/dev/ttyUSB*`, `/dev/ttyACM*`, `/dev/ttyAMA*` | Native support |
| Windows (cmd) | `COM3`, `COM4`, etc. | Via pyserial |
| MSYS2 UCRT64 | `COM*` or `/dev/ttyS*` | Auto-mapped (`/dev/ttyS2` → `COM3`) |
| Git Bash | `COM*` or `/dev/ttyS*` | Auto-mapped |
| WSL | `/dev/ttyS*` | Needs `usbipd` for USB serial |
| macOS | `/dev/tty.usbserial-*` | Via pyserial |

---

## File Structure

```
serial-web/
├── version.py             App name + version (single source of truth)
├── launch.sh              Bash menu launcher
├── app.py                 FastAPI backend
├── templates/
│   └── index.html         Web UI (simple + advanced modes)
├── ssl.conf               Config (auto-created)
├── commands.conf           Custom commands (user-editable)
├── logs/
│   ├── ssl.log            App log
│   ├── session_*.log      Session logs (plain text)
│   └── session_*.jsonl    Session logs (structured, for replay)
├── requirements.txt       Python dependencies
├── CHANGELOG.md           Version history
├── CHEATSHEET.md          Quick reference
└── README.md              This file
```

---

## Requirements

- Python 3.8+
- pip
- Dependencies: `fastapi`, `uvicorn`, `pyserial`, `python-multipart`, `qrcode` (optional, for terminal QR code)

---

## Troubleshooting

### No serial ports found

- Check cable is connected
- Check drivers installed (CH340, CP2102, FTDI, PL2303)
- On Linux: check permissions (`sudo usermod -aG dialout $USER`, then re-login)
- On WSL: use `usbipd` to attach USB devices

### Garbled output

- Lower the baud rate to match the board
- Increase line delay (50ms → 100ms → 200ms)
- Check flow control settings match the board
- Check data bits / parity / stop bits

### Script fails on board

- Check `sed -i 's/\r//'` ran (fixes Windows line endings)
- Check the script has `#!/bin/bash` shebang
- Try Send Only (don't auto-execute), then run manually on the board
- Check remote path is writable

### Connection drops randomly

- Auto-reconnect should handle this (enabled by default)
- Try a different USB cable (data, not charge-only)
- Try a different USB port (avoid hubs)
- Check dmesg on host for USB errors

### Browser doesn't open

- Manually navigate to http://localhost:8000
- Disable `auto_open_browser` in settings if it causes issues

---

## License

MIT
