# ⚡ tty — Cheat Sheet

> Version defined in `version.py`. Run `python -c "from version import *; print(APP_TAG)"` to check.

## Start

```bash
bash launch.sh          # interactive menu (reads version.py)
python app.py           # direct launch → http://localhost:8000 + LAN
python app.py --local   # localhost only (no LAN access)
python app.py --port 9000  # custom port
```

## Mobile / LAN Access

```bash
# Server binds to 0.0.0.0 by default — phone/tablet can connect
# 1. Check the LAN URL printed on startup (e.g. http://192.168.1.42:8000)
# 2. Scan the QR code or type the URL on your phone
# 3. Full UI works on iOS Safari, Android Chrome, any browser

python app.py              # LAN accessible (default)
python app.py --local      # localhost only
python app.py --host X     # bind to specific IP
python app.py --no-browser # skip auto-open
```

## Web UI Keyboard Shortcuts

| Key | Action |
|---|---|
| `Tab` | Insert 4 spaces (in editor) |
| `Enter` | Send command (in command bar) |
| `↑` / `↓` | Command history (in command bar) |
| Drag & drop | Load `.sh` file into editor |
| Right-click paste | Paste from clipboard |

## Web UI Buttons

| Button | What it does |
|---|---|
| **▶ Send & Run** | Transfer script + execute on board |
| **Send Only** | Transfer without executing (advanced) |
| **HEX** | Toggle hex dump view in terminal |
| **⚙ Advanced / ◉ Simple** | Switch UI mode |
| **↻ Ports** | Rescan serial ports |
| **⏮ Replay** | Browse and replay past sessions (advanced) |
| **📂 Open** | Open `.sh` file from disk |
| **Clear** | Clear editor or terminal |
| **Copy** | Copy terminal output to clipboard |

## Common Baud Rates

| Rate | Common use |
|---|---|
| 9600 | Arduino default, slow devices |
| 38400 | Some embedded boards |
| 115200 | Most Linux boards (RPi, BBB, STM32MP) |
| 921600 | ESP32, fast debug |
| 1500000 | Some SoCs |

## launch.sh Menu Map

```
Main Menu
├── 1) Launch web app
├── 2) Install / update dependencies
├── 3) Check system status
├── 4) List serial ports
├── 5) Predefined commands
│   ├── 1-5)   System (board info, disk, memory, cpu, uptime)
│   ├── 6-8)   Network (IPs, interfaces, connections)
│   ├── 9-11)  Services (processes, systemd, kernel log)
│   ├── 12-14) Actions (reboot⚠, shutdown⚠, sync)
│   ├── 15)    Custom command
│   └── 16)    Manage saved commands
├── 6) Profiles
│   ├── s) Switch profile
│   ├── a) Add profile
│   ├── d) Delete profile
│   └── e) Edit raw config
├── 7) Settings
│   ├── 1) Connection defaults
│   ├── 2) Line ending mode
│   ├── 3) Behavior flags
│   ├── 4) Reconnect settings
│   ├── 5) Logging settings
│   ├── 6) Reset to defaults
│   ├── 7) Export config
│   ├── 8) Import config
│   └── 9) Edit raw JSON
├── 8) Session replay
├── 9) View logs
│   ├── 1) Full log
│   ├── 2) Last 50 lines
│   ├── 3) Errors only
│   ├── 4) Clear log
│   └── 5) Export log
├── 0) Uninstall dependencies
├── s) Switch mode (simple ↔ advanced)
└── q) Quit
```

## API Endpoints

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | Web UI |
| GET | `/api/info` | System info + app name, version, environment |
| GET | `/api/ports` | List serial ports |
| POST | `/api/connect` | Connect `{port, baudrate, flow_control}` |
| POST | `/api/disconnect` | Disconnect |
| POST | `/api/send` | Send script `{script, execute, line_delay, remote_path}` |
| POST | `/api/command` | Send command `{command}` |
| POST | `/api/upload` | Upload `.sh` file |
| GET | `/api/config` | Get config |
| POST | `/api/config` | Update config (deep merge) |
| GET | `/api/profiles` | List profiles |
| POST | `/api/profiles/switch` | Switch `{name}` |
| POST | `/api/profiles/save` | Save `{name, data}` |
| POST | `/api/profiles/delete` | Delete `{name}` |
| GET | `/api/commands` | List all commands |
| POST | `/api/commands/save` | Save `{name, command}` |
| POST | `/api/commands/run` | Run `{command}` |
| GET | `/api/sessions` | List recorded sessions |
| GET | `/api/sessions/{id}` | Get session events |
| WS | `/ws` | Live serial output + status |

## Version Management

```bash
# Check current version
python -c "from version import *; print(APP_TAG)"

# Bump version — edit ONLY version.py:
# APP_VERSION = "2.4.0"
# Everything else updates automatically (app.py, launch.sh, web UI)
```

## Config Quick Edit

```bash
# View current config
cat ssl.conf | python -m json.tool

# Change baud rate
python -c "
import json
c = json.load(open('ssl.conf'))
c['connection']['baudrate'] = 9600
json.dump(c, open('ssl.conf','w'), indent=2)
"

# Add a profile
python -c "
import json
c = json.load(open('ssl.conf'))
c['profiles']['myboard'] = {'port':'/dev/ttyUSB0','baudrate':115200}
json.dump(c, open('ssl.conf','w'), indent=2)
"
```

## Custom Commands (commands.conf)

```bash
# One command per line: name=command
gpio_status=cat /sys/class/gpio/*/value
wifi_scan=iwlist wlan0 scan | grep ESSID
temp=cat /sys/class/thermal/thermal_zone0/temp
deploy=cd /opt/app && git pull && systemctl restart myapp
```

## Troubleshooting Quick Fixes

```bash
# Permission denied on /dev/ttyUSB0
sudo usermod -aG dialout $USER   # then re-login

# Check port exists
ls -la /dev/ttyUSB* /dev/ttyACM*

# Test port manually
stty -F /dev/ttyUSB0 115200
echo "hello" > /dev/ttyUSB0

# Kill stuck process on port
fuser -k /dev/ttyUSB0

# Reset USB device
echo "1-1" | sudo tee /sys/bus/usb/drivers/usb/unbind
echo "1-1" | sudo tee /sys/bus/usb/drivers/usb/bind
```

## Line Ending Modes

| Mode | Behavior |
|---|---|
| **Auto** | Detect and strip `\r` (recommended) |
| **Force LF** | Strip all `\r`, ensure `\n` only |
| **Preserve** | Send as-is (for binary protocols) |

## Session Log Format (JSONL)

```json
{"t": 0.000, "type": "connect", "port": "/dev/ttyUSB0", "baud": 115200}
{"t": 0.102, "type": "tx", "data": "echo hello\n"}
{"t": 1.340, "type": "rx", "data": "hello\r\n"}
{"t": 43.00, "type": "disconnect", "reason": "cable"}
{"t": 46.10, "type": "reconnect"}
```

Event types: `connect`, `disconnect`, `reconnect`, `tx`, `rx`, `command`, `script`
