"""
⚡ tty — Web UI
Sends bash scripts to a Linux board over serial and displays live output.
Works on: Windows (cmd/PowerShell), Linux, MSYS2 UCRT64, Git Bash, WSL, macOS.
Run: python app.py
Open: http://localhost:8000
"""

import asyncio
import glob
import json
import os
import platform
import sys
import time
import webbrowser
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

import serial
import serial.tools.list_ports
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse

from version import APP_NAME, APP_VERSION, APP_ICON, APP_FULL, APP_TAG


# ── LAN Helpers ──

def get_lan_ip() -> str:
    """Get the machine's LAN IP address."""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def generate_qr_terminal(url: str) -> str:
    """Generate a QR code as ASCII art for the terminal."""
    try:
        import qrcode
        qr = qrcode.QRCode(box_size=1, border=1, error_correction=qrcode.constants.ERROR_CORRECT_L)
        qr.add_data(url)
        qr.make(fit=True)
        lines = []
        matrix = qr.get_matrix()
        for row in matrix:
            line = ""
            for cell in row:
                line += "██" if cell else "  "
            lines.append(line)
        return "\n".join(lines)
    except ImportError:
        return ""

# ── Paths ──
BASE_DIR = Path(__file__).parent
TEMPLATES_DIR = BASE_DIR / "templates"
CONFIG_FILE = BASE_DIR / "ssl.conf"
COMMANDS_FILE = BASE_DIR / "commands.conf"
LOG_DIR = BASE_DIR / "logs"

# ── Global State ──
serial_conn: serial.Serial | None = None
serial_lock = asyncio.Lock()
connected_clients: list[WebSocket] = []
connection_state = "disconnected"
reconnect_task: asyncio.Task | None = None
session_log_txt = None
session_log_jsonl = None
session_start_time: float = 0
current_config: dict = {}

# ── Default Config ──
DEFAULT_CONFIG = {
    "mode": "simple",
    "active_profile": "default",
    "connection": {
        "port": "",
        "baudrate": 115200,
        "data_bits": 8,
        "parity": "none",
        "stop_bits": 1,
        "flow_control": "none",
        "dtr": None,
        "rts": None,
        "local_echo": False,
        "line_delay_ms": 50,
        "line_ending": "auto",
    },
    "behavior": {
        "auto_execute": True,
        "auto_open_browser": True,
        "dangerous_cmd_guard": True,
        "dry_run": False,
        "syntax_check": True,
    },
    "reconnect": {
        "enabled": True,
        "interval_seconds": 3,
        "max_retries": 0,
        "resend_on_reconnect": False,
    },
    "logging": {
        "enabled": True,
        "directory": "logs",
        "format": ["txt", "jsonl"],
        "max_sessions": 50,
        "max_size_mb": 100,
        "auto_cleanup": True,
    },
    "paths": {
        "remote_script_path": "/tmp/script.sh",
    },
    "scrollback": {"max_lines": 10000},
    "profiles": {"default": {"port": "", "baudrate": 115200}},
    "last_session": {"last_port": "", "last_script": "", "last_connected": ""},
}


# ════════════════════════════════════════
# ── Config ──
# ════════════════════════════════════════

def deep_merge(base: dict, override: dict) -> dict:
    result = base.copy()
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result


def load_config() -> dict:
    global current_config
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE) as f:
                current_config = deep_merge(DEFAULT_CONFIG, json.load(f))
        except Exception:
            current_config = DEFAULT_CONFIG.copy()
    else:
        current_config = DEFAULT_CONFIG.copy()
        save_config()
    return current_config


def save_config():
    with open(CONFIG_FILE, "w") as f:
        json.dump(current_config, f, indent=2)


# ════════════════════════════════════════
# ── Environment ──
# ════════════════════════════════════════

def detect_environment() -> str:
    system = platform.system().lower()
    if system == "linux":
        try:
            with open("/proc/version") as f:
                ver = f.read().lower()
            if "microsoft" in ver or "wsl" in ver:
                return "wsl"
        except FileNotFoundError:
            pass
        return "linux"
    elif system == "windows":
        msystem = os.environ.get("MSYSTEM", "")
        if msystem:
            return f"msys2-{msystem.lower()}"
        shell = os.environ.get("SHELL", "")
        if "bash" in shell.lower():
            return "gitbash"
        return "windows"
    elif system == "darwin":
        return "macos"
    return system


def discover_serial_ports() -> list[dict]:
    ports = []
    seen = set()
    for p in serial.tools.list_ports.comports():
        if p.device not in seen:
            ports.append({"device": p.device, "description": p.description or p.device})
            seen.add(p.device)
    env = detect_environment()
    if env in ("linux", "wsl") or env.startswith("msys2"):
        for pattern in ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/ttyS*", "/dev/ttyAMA*"]:
            for dev in sorted(glob.glob(pattern)):
                if dev not in seen:
                    ports.append({"device": dev, "description": dev})
                    seen.add(dev)
    return ports


def resolve_serial_port(port: str) -> str:
    env = detect_environment()
    if env.startswith("msys2") or env == "gitbash":
        if port.startswith("/dev/ttyS"):
            try:
                num = int(port.replace("/dev/ttyS", ""))
                return f"COM{num + 1}"
            except ValueError:
                pass
    return port


# ════════════════════════════════════════
# ── Line Endings ──
# ════════════════════════════════════════

def normalize_line_endings(text: str, mode: str = "auto") -> str:
    if mode == "preserve":
        return text
    return text.replace("\r\n", "\n").replace("\r", "\n")


# ════════════════════════════════════════
# ── Session Logging ──
# ════════════════════════════════════════

def start_session_log(port: str, baudrate: int):
    global session_log_txt, session_log_jsonl, session_start_time
    if not current_config.get("logging", {}).get("enabled", True):
        return
    LOG_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session_start_time = time.time()
    log_cfg = current_config.get("logging", {})
    formats = log_cfg.get("format", ["txt", "jsonl"])
    if "txt" in formats:
        session_log_txt = open(LOG_DIR / f"session_{ts}.log", "w", buffering=1)
        session_log_txt.write(f"[{datetime.now().isoformat()}] CONNECTED {port} @ {baudrate}\n")
    if "jsonl" in formats:
        session_log_jsonl = open(LOG_DIR / f"session_{ts}.jsonl", "w", buffering=1)
        log_event("connect", port=port, baud=baudrate)
    cleanup_old_sessions()


def stop_session_log():
    global session_log_txt, session_log_jsonl
    if session_log_txt:
        session_log_txt.write(f"[{datetime.now().isoformat()}] DISCONNECTED\n")
        session_log_txt.close()
        session_log_txt = None
    if session_log_jsonl:
        log_event("disconnect")
        session_log_jsonl.close()
        session_log_jsonl = None


def log_event(event_type: str, data: str = "", **kwargs):
    if session_log_jsonl:
        ev = {"t": round(time.time() - session_start_time, 3), "type": event_type}
        if data:
            ev["data"] = data
        ev.update(kwargs)
        session_log_jsonl.write(json.dumps(ev) + "\n")
    if session_log_txt and data:
        direction = ">>>" if event_type in ("tx", "command", "script") else "<<<"
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        for line in data.splitlines():
            session_log_txt.write(f"[{ts}] {direction} {line}\n")


def cleanup_old_sessions():
    log_cfg = current_config.get("logging", {})
    if not log_cfg.get("auto_cleanup", True):
        return
    max_sessions = log_cfg.get("max_sessions", 50)
    max_size_mb = log_cfg.get("max_size_mb", 100)
    sessions = sorted(LOG_DIR.glob("session_*.jsonl"), key=lambda f: f.stat().st_mtime)
    while len(sessions) > max_sessions:
        old = sessions.pop(0)
        old.unlink(missing_ok=True)
        old.with_suffix(".log").unlink(missing_ok=True)
    total_size = sum(f.stat().st_size for f in LOG_DIR.glob("session_*")) / (1024 * 1024)
    while total_size > max_size_mb and sessions:
        old = sessions.pop(0)
        total_size -= old.stat().st_size / (1024 * 1024)
        old.unlink(missing_ok=True)
        txt = old.with_suffix(".log")
        if txt.exists():
            total_size -= txt.stat().st_size / (1024 * 1024)
            txt.unlink(missing_ok=True)


# ════════════════════════════════════════
# ── Commands ──
# ════════════════════════════════════════

def load_commands() -> dict:
    commands = {
        "board_info": "uname -a && cat /etc/os-release",
        "disk": "df -h",
        "memory": "free -h",
        "cpu": "cat /proc/cpuinfo | head -20",
        "uptime": "uptime",
        "ip_addr": "ip addr show",
        "interfaces": "ip link show",
        "connections": "ss -tulnp",
        "processes": "ps aux | head -20",
        "services": "systemctl list-units --type=service --state=running",
        "kernel_log": "dmesg | tail -30",
        "sync": "sync",
    }
    if COMMANDS_FILE.exists():
        for line in COMMANDS_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                name, cmd = line.split("=", 1)
                commands[name.strip()] = cmd.strip()
    profile = current_config.get("active_profile", "default")
    profile_cmds = current_config.get("profiles", {}).get(profile, {}).get("commands", {})
    commands.update(profile_cmds)
    return commands


# ════════════════════════════════════════
# ── Serial Helpers ──
# ════════════════════════════════════════

PARITY_MAP = {"none": serial.PARITY_NONE, "odd": serial.PARITY_ODD, "even": serial.PARITY_EVEN, "mark": serial.PARITY_MARK, "space": serial.PARITY_SPACE}
STOPBITS_MAP = {1: serial.STOPBITS_ONE, 1.5: serial.STOPBITS_ONE_POINT_FIVE, 2: serial.STOPBITS_TWO}
BYTESIZE_MAP = {5: serial.FIVEBITS, 6: serial.SIXBITS, 7: serial.SEVENBITS, 8: serial.EIGHTBITS}


def open_serial(port: str, conn_cfg: dict) -> serial.Serial:
    port = resolve_serial_port(port)
    ser = serial.Serial(
        port=port,
        baudrate=int(conn_cfg.get("baudrate", 115200)),
        bytesize=BYTESIZE_MAP.get(int(conn_cfg.get("data_bits", 8)), serial.EIGHTBITS),
        parity=PARITY_MAP.get(conn_cfg.get("parity", "none"), serial.PARITY_NONE),
        stopbits=STOPBITS_MAP.get(float(conn_cfg.get("stop_bits", 1)), serial.STOPBITS_ONE),
        xonxoff=(conn_cfg.get("flow_control") == "xonxoff"),
        rtscts=(conn_cfg.get("flow_control") == "rtscts"),
        dsrdtr=(conn_cfg.get("flow_control") == "dsrdtr"),
        timeout=0.1,
        write_timeout=5,
    )
    dtr = conn_cfg.get("dtr")
    rts = conn_cfg.get("rts")
    if dtr is not None:
        ser.dtr = bool(dtr)
    if rts is not None:
        ser.rts = bool(rts)
    return ser


# ════════════════════════════════════════
# ── WebSocket Broadcast ──
# ════════════════════════════════════════

async def broadcast(msg: dict):
    text = json.dumps(msg)
    for client in connected_clients[:]:
        try:
            await client.send_text(text)
        except Exception:
            if client in connected_clients:
                connected_clients.remove(client)


# ════════════════════════════════════════
# ── Auto-Reconnect ──
# ════════════════════════════════════════

async def reconnect_loop():
    global serial_conn, connection_state
    while True:
        await asyncio.sleep(2)
        cfg = current_config.get("reconnect", {})
        if not cfg.get("enabled", True) or connection_state != "connected":
            continue
        try:
            if serial_conn and serial_conn.is_open:
                serial_conn.in_waiting
            else:
                raise Exception("closed")
        except Exception:
            connection_state = "reconnecting"
            await broadcast({"type": "status", "state": "reconnecting"})
            log_event("disconnect", reason="cable")
            conn_cfg = current_config.get("connection", {})
            port = conn_cfg.get("port", "")
            interval = cfg.get("interval_seconds", 3)
            max_retries = cfg.get("max_retries", 0)
            retries = 0
            while True:
                retries += 1
                if 0 < max_retries < retries:
                    connection_state = "disconnected"
                    await broadcast({"type": "status", "state": "disconnected", "reason": "max_retries"})
                    break
                await asyncio.sleep(interval)
                try:
                    async with serial_lock:
                        serial_conn = open_serial(port, conn_cfg)
                    connection_state = "connected"
                    log_event("reconnect")
                    await broadcast({"type": "status", "state": "connected", "message": "Reconnected"})
                    break
                except Exception:
                    await broadcast({"type": "status", "state": "reconnecting", "retry": retries})


# ════════════════════════════════════════
# ── FastAPI App ──
# ════════════════════════════════════════

@asynccontextmanager
async def lifespan(app: FastAPI):
    global reconnect_task
    load_config()
    reconnect_task = asyncio.create_task(reconnect_loop())
    yield
    if reconnect_task:
        reconnect_task.cancel()
    stop_session_log()
    if serial_conn and serial_conn.is_open:
        serial_conn.close()


app = FastAPI(lifespan=lifespan)


@app.get("/", response_class=HTMLResponse)
async def index():
    return (TEMPLATES_DIR / "index.html").read_text(encoding="utf-8")


@app.get("/api/info")
async def system_info():
    return {
        "app_name": APP_NAME,
        "app_version": APP_VERSION,
        "app_tag": APP_TAG,
        "platform": platform.system(),
        "environment": detect_environment(),
        "python": sys.version,
        "connection_state": connection_state,
        "lan_ip": get_lan_ip(),
        "port": current_config.get("server", {}).get("port", 8000),
    }


@app.get("/api/ports")
async def list_ports():
    return discover_serial_ports()


@app.post("/api/connect")
async def connect_serial_route(config: dict):
    global serial_conn, connection_state
    async with serial_lock:
        if serial_conn and serial_conn.is_open:
            stop_session_log()
            serial_conn.close()
        try:
            port = config.get("port", "")
            conn_cfg = deep_merge(current_config.get("connection", {}), config)
            serial_conn = open_serial(port, conn_cfg)
            current_config.setdefault("connection", {})["port"] = port
            if "baudrate" in config:
                current_config["connection"]["baudrate"] = int(config["baudrate"])
            current_config["last_session"]["last_port"] = port
            current_config["last_session"]["last_connected"] = datetime.now().isoformat()
            save_config()
            connection_state = "connected"
            start_session_log(port, int(conn_cfg.get("baudrate", 115200)))
            await broadcast({"type": "status", "state": "connected"})
            return {"status": "connected", "port": resolve_serial_port(port)}
        except Exception as e:
            serial_conn = None
            connection_state = "disconnected"
            return {"status": "error", "message": str(e)}


@app.post("/api/disconnect")
async def disconnect_serial_route():
    global serial_conn, connection_state
    async with serial_lock:
        stop_session_log()
        if serial_conn and serial_conn.is_open:
            serial_conn.close()
        serial_conn = None
        connection_state = "disconnected"
    await broadcast({"type": "status", "state": "disconnected"})
    return {"status": "disconnected"}


@app.post("/api/send")
async def send_script(payload: dict):
    global serial_conn
    if not serial_conn or not serial_conn.is_open:
        return {"status": "error", "message": "Not connected"}
    script = payload.get("script", "")
    line_delay = float(payload.get("line_delay", 0.05))
    execute = payload.get("execute", True)
    remote_path = payload.get("remote_path", current_config.get("paths", {}).get("remote_script_path", "/tmp/script.sh"))
    le_mode = current_config.get("connection", {}).get("line_ending", "auto")
    script = normalize_line_endings(script, le_mode)
    if current_config.get("behavior", {}).get("dry_run", False):
        execute = False
    try:
        async with serial_lock:
            cmd = f"cat > {remote_path} << 'ENDOFSCRIPT'\n"
            serial_conn.write(cmd.encode())
            log_event("tx", cmd)
            await asyncio.sleep(0.1)
            for line in script.splitlines():
                data = line + "\n"
                serial_conn.write(data.encode())
                log_event("tx", data)
                await asyncio.sleep(line_delay)
            serial_conn.write(b"ENDOFSCRIPT\n")
            log_event("tx", "ENDOFSCRIPT\n")
            await asyncio.sleep(0.3)
            fix_cmd = f"sed -i 's/\\r//' {remote_path}\n"
            serial_conn.write(fix_cmd.encode())
            log_event("tx", fix_cmd)
            await asyncio.sleep(0.2)
            if execute:
                run_cmd = f"bash {remote_path}\n"
                serial_conn.write(run_cmd.encode())
                log_event("script", script, path=remote_path)
        current_config["last_session"]["last_script"] = script
        save_config()
        is_dry = current_config.get("behavior", {}).get("dry_run", False)
        msg = "Script sent" + (" and executed" if execute else " (dry-run)" if is_dry else "")
        return {"status": "ok", "message": msg}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@app.post("/api/command")
async def send_command(payload: dict):
    global serial_conn
    if not serial_conn or not serial_conn.is_open:
        return {"status": "error", "message": "Not connected"}
    cmd = payload.get("command", "")
    if current_config.get("behavior", {}).get("dangerous_cmd_guard", True):
        dangerous = ["rm -rf /", "mkfs", "dd if=", "shutdown", "reboot", "halt"]
        for d in dangerous:
            if d in cmd:
                return {"status": "warning", "message": f"Dangerous: '{d}'. Confirm?", "dangerous": True}
    try:
        async with serial_lock:
            serial_conn.write((cmd + "\n").encode())
            log_event("command", cmd + "\n")
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@app.post("/api/upload")
async def upload_script(file: UploadFile = File(...)):
    content = await file.read()
    text = content.decode(errors="replace")
    le_mode = current_config.get("connection", {}).get("line_ending", "auto")
    text = normalize_line_endings(text, le_mode)
    return {"filename": file.filename, "content": text}


@app.get("/api/config")
async def get_config():
    return current_config


@app.post("/api/config")
async def update_config(payload: dict):
    global current_config
    current_config = deep_merge(current_config, payload)
    save_config()
    return {"status": "ok", "config": current_config}


@app.get("/api/profiles")
async def get_profiles():
    return {"profiles": current_config.get("profiles", {}), "active": current_config.get("active_profile", "default")}


@app.post("/api/profiles/switch")
async def switch_profile(payload: dict):
    name = payload.get("name", "")
    profiles = current_config.get("profiles", {})
    if name not in profiles:
        return {"status": "error", "message": f"Profile '{name}' not found"}
    current_config["active_profile"] = name
    current_config["connection"] = deep_merge(current_config.get("connection", {}), profiles[name])
    save_config()
    return {"status": "ok", "active": name, "connection": current_config["connection"]}


@app.post("/api/profiles/save")
async def save_profile(payload: dict):
    name = payload.get("name", "")
    data = payload.get("data", {})
    if not name:
        return {"status": "error", "message": "Name required"}
    current_config.setdefault("profiles", {})[name] = data
    save_config()
    return {"status": "ok"}


@app.post("/api/profiles/delete")
async def delete_profile(payload: dict):
    name = payload.get("name", "")
    current_config.get("profiles", {}).pop(name, None)
    if current_config.get("active_profile") == name:
        current_config["active_profile"] = "default"
    save_config()
    return {"status": "ok"}


@app.get("/api/commands")
async def get_commands():
    return load_commands()


@app.post("/api/commands/save")
async def save_command_route(payload: dict):
    name = payload.get("name", "")
    cmd = payload.get("command", "")
    if name and cmd:
        with open(COMMANDS_FILE, "a") as f:
            f.write(f"{name}={cmd}\n")
        return {"status": "ok"}
    return {"status": "error", "message": "Name and command required"}


@app.post("/api/commands/run")
async def run_command_route(payload: dict):
    return await send_command({"command": payload.get("command", "")})


@app.get("/api/sessions")
async def list_sessions():
    sessions = []
    if LOG_DIR.exists():
        for f in sorted(LOG_DIR.glob("session_*.jsonl"), key=lambda x: x.stat().st_mtime, reverse=True)[:20]:
            st = f.stat()
            sessions.append({
                "id": f.stem, "filename": f.name, "size": st.st_size,
                "lines": sum(1 for _ in open(f)),
                "modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
            })
    return sessions


@app.get("/api/sessions/{session_id}")
async def get_session(session_id: str):
    f = LOG_DIR / f"{session_id}.jsonl"
    if not f.exists():
        return {"status": "error", "message": "Not found"}
    events = []
    for line in open(f):
        try:
            events.append(json.loads(line.strip()))
        except json.JSONDecodeError:
            pass
    return {"id": session_id, "events": events}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    connected_clients.append(ws)
    await ws.send_text(json.dumps({
        "type": "status", "state": connection_state,
        "config": {"mode": current_config.get("mode", "simple"), "active_profile": current_config.get("active_profile", "default")}
    }))
    try:
        while True:
            if serial_conn and serial_conn.is_open:
                try:
                    if serial_conn.in_waiting:
                        data = serial_conn.read(serial_conn.in_waiting)
                        text = data.decode(errors="replace")
                        log_event("rx", text)
                        await broadcast({"type": "output", "data": text})
                except Exception:
                    pass
            try:
                await asyncio.wait_for(ws.receive_text(), timeout=0.05)
            except asyncio.TimeoutError:
                pass
            except WebSocketDisconnect:
                break
    except WebSocketDisconnect:
        pass
    finally:
        if ws in connected_clients:
            connected_clients.remove(ws)


if __name__ == "__main__":
    import argparse
    import uvicorn

    parser = argparse.ArgumentParser(description=APP_TAG)
    parser.add_argument("--host", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="Port (default: 8000)")
    parser.add_argument("--local", action="store_true", help="Bind to localhost only (127.0.0.1)")
    parser.add_argument("--no-browser", action="store_true", help="Don't auto-open browser")
    args = parser.parse_args()

    load_config()
    env = detect_environment()
    host = "127.0.0.1" if args.local else args.host
    port = args.port
    lan_ip = get_lan_ip()
    local_url = f"http://127.0.0.1:{port}"
    lan_url = f"http://{lan_ip}:{port}"

    print(f"\n  {APP_TAG}")
    print(f"  Environment: {env}")
    print(f"  Mode: {current_config.get('mode', 'simple')}")
    print()
    print(f"  Local:  {local_url}")
    if host == "0.0.0.0" and lan_ip != "127.0.0.1":
        print(f"  LAN:    {lan_url}")
        print(f"  → Open this URL on your phone/tablet")
        qr = generate_qr_terminal(lan_url)
        if qr:
            print()
            for line in qr.split("\n"):
                print(f"    {line}")
            print()
        else:
            print(f"  (install 'qrcode' for QR: pip install qrcode)")
            print()
    else:
        print()

    if not args.no_browser and current_config.get("behavior", {}).get("auto_open_browser", True):
        try:
            webbrowser.open(local_url)
        except Exception:
            pass

    uvicorn.run(app, host=host, port=port)
