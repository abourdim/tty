#!/usr/bin/env bash
# ══════════════════════════════════════════════════
# ⚡ tty — launch.sh
# Menu-based launcher — version read from version.py
# Works on: Linux, MSYS2 UCRT64, Git Bash, WSL, macOS
# ══════════════════════════════════════════════════

set -euo pipefail

# --- Self-fix line endings ---
if head -1 "$0" | grep -q $'\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null || tr -d '\r' < "$0" > "$0.tmp" && mv "$0.tmp" "$0"
    echo "Fixed line endings in launch.sh. Please re-run."
    exit 0
fi

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/ssl.conf"
COMMANDS_FILE="$SCRIPT_DIR/commands.conf"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/ssl.log"
APP_FILE="$SCRIPT_DIR/app.py"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
VERSION_FILE="$SCRIPT_DIR/version.py"

# ── App identity (read from version.py) ──
APP_NAME="tty"
APP_VERSION="0.0.0"
APP_ICON="⚡"
read_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        APP_NAME=$(grep 'APP_NAME' "$VERSION_FILE" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
        APP_VERSION=$(grep 'APP_VERSION' "$VERSION_FILE" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
        APP_ICON=$(grep 'APP_ICON' "$VERSION_FILE" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    fi
}
read_version
APP_TAG="${APP_ICON} ${APP_NAME} v${APP_VERSION}"

# ── Defaults ──
DEFAULT_BAUD=115200
DEFAULT_PORT=""
DEFAULT_MODE="simple"
MAX_LOG_SIZE=1048576  # 1MB

# ── Runtime state ──
ENV_TYPE=""
PYTHON_CMD=""
PIP_CMD=""
PYTHON_VERSION=""
DEPS_INSTALLED=0
DEPS_TOTAL=4
PORTS_FOUND=0
ACTIVE_PROFILE="default"
CURRENT_MODE="$DEFAULT_MODE"
COLOR_SUPPORT=true

# ── Colors ──
setup_colors() {
    if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
        COLOR_SUPPORT=true
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_RED="\033[31m"
        C_GREEN="\033[32m"
        C_YELLOW="\033[33m"
        C_BLUE="\033[34m"
        C_CYAN="\033[36m"
        C_WHITE="\033[97m"
        C_BG_BLUE="\033[44m"
        C_TICK="${C_GREEN}✓${C_RESET}"
        C_CROSS="${C_RED}✗${C_RESET}"
        C_WARN="${C_YELLOW}⚠${C_RESET}"
        C_BOLT="${C_YELLOW}⚡${C_RESET}"
    else
        COLOR_SUPPORT=false
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
        C_BLUE="" C_CYAN="" C_WHITE="" C_BG_BLUE=""
        C_TICK="[OK]" C_CROSS="[FAIL]" C_WARN="[WARN]" C_BOLT="[*]"
    fi
}

# ── Logging ──
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$LOG_DIR"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    # Rotate if too large
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
}

# ── Helpers ──
print_line() { printf "${C_DIM}%-40s${C_RESET}\n" "────────────────────────────────────────"; }
print_box_top() { printf "${C_DIM}╔══════════════════════════════════════════╗${C_RESET}\n"; }
print_box_mid() { printf "${C_DIM}╠══════════════════════════════════════════╣${C_RESET}\n"; }
print_box_bot() { printf "${C_DIM}╚══════════════════════════════════════════╝${C_RESET}\n"; }
print_box_line() { printf "${C_DIM}║${C_RESET} %-40s ${C_DIM}║${C_RESET}\n" "$1"; }
print_box_empty() { printf "${C_DIM}║${C_RESET} %-40s ${C_DIM}║${C_RESET}\n" ""; }

pause() {
    echo ""
    read -rp "  Press Enter to continue..." _
}

confirm() {
    local msg="${1:-Continue?}"
    read -rp "  $msg [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Environment Detection ──
detect_environment() {
    local system
    system="$(uname -s 2>/dev/null || echo unknown)"
    case "$system" in
        Linux)
            if [[ -f /proc/version ]] && grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null; then
                ENV_TYPE="wsl"
            else
                ENV_TYPE="linux"
            fi
            ;;
        MINGW*|MSYS*)
            if [[ -n "${MSYSTEM:-}" ]]; then
                ENV_TYPE="msys2-$(echo "$MSYSTEM" | tr '[:upper:]' '[:lower:]')"
            else
                ENV_TYPE="msys2"
            fi
            ;;
        CYGWIN*) ENV_TYPE="cygwin" ;;
        Darwin)  ENV_TYPE="macos" ;;
        *)       ENV_TYPE="unknown" ;;
    esac
    log "INFO" "Environment detected: $ENV_TYPE"
}

# ── Python Detection ──
detect_python() {
    PYTHON_CMD=""
    PYTHON_VERSION=""
    local candidates=("python3" "python" "python3.12" "python3.11" "python3.10")
    for cmd in "${candidates[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver="$($cmd --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)"
            if [[ -n "$ver" ]]; then
                local major minor
                major="${ver%%.*}"
                minor="${ver#*.}"; minor="${minor%%.*}"
                if [[ "$major" -ge 3 ]] && [[ "$minor" -ge 8 ]]; then
                    PYTHON_CMD="$cmd"
                    PYTHON_VERSION="$ver"
                    log "INFO" "Python found: $cmd ($ver)"
                    return 0
                fi
            fi
        fi
    done
    log "ERROR" "No suitable Python found (need 3.8+)"
    return 1
}

# ── Pip Detection ──
detect_pip() {
    PIP_CMD=""
    local candidates=("pip3" "pip" "${PYTHON_CMD} -m pip")
    for cmd in "${candidates[@]}"; do
        if $cmd --version &>/dev/null 2>&1; then
            PIP_CMD="$cmd"
            log "INFO" "Pip found: $cmd"
            return 0
        fi
    done
    log "WARN" "Pip not found"
    return 1
}

# ── Dependency Check ──
check_dependencies() {
    DEPS_INSTALLED=0
    DEPS_TOTAL=4
    local deps=("fastapi" "uvicorn" "serial" "multipart")
    local imports=("fastapi" "uvicorn" "serial" "multipart")
    for mod in "${imports[@]}"; do
        if $PYTHON_CMD -c "import $mod" &>/dev/null 2>&1; then
            ((DEPS_INSTALLED++))
        fi
    done
    log "INFO" "Dependencies: $DEPS_INSTALLED/$DEPS_TOTAL installed"
}

# ── Serial Port Scan ──
scan_serial_ports() {
    PORTS_FOUND=0
    SERIAL_PORTS=()
    # pyserial scan
    if $PYTHON_CMD -c "import serial" &>/dev/null 2>&1; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                SERIAL_PORTS+=("$line")
                ((PORTS_FOUND++))
            fi
        done < <($PYTHON_CMD -c "
import serial.tools.list_ports
for p in serial.tools.list_ports.comports():
    print(f'{p.device}|{p.description}')
" 2>/dev/null)
    fi
    # Also scan /dev on Linux/MSYS2
    if [[ "$ENV_TYPE" == "linux" || "$ENV_TYPE" == "wsl" || "$ENV_TYPE" == msys2* ]]; then
        for dev in /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyS*; do
            if [[ -e "$dev" ]]; then
                local already=false
                for existing in "${SERIAL_PORTS[@]:-}"; do
                    [[ "$existing" == "$dev|"* ]] && already=true
                done
                if ! $already; then
                    SERIAL_PORTS+=("$dev|$dev")
                    ((PORTS_FOUND++))
                fi
            fi
        done
    fi
    log "INFO" "Serial ports found: $PORTS_FOUND"
}

# ── Config ──
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Read mode from config
        CURRENT_MODE=$($PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
    print(c.get('mode', 'simple'))
except:
    print('simple')
" 2>/dev/null || echo "simple")
        ACTIVE_PROFILE=$($PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
    print(c.get('active_profile', 'default'))
except:
    print('default')
" 2>/dev/null || echo "default")
        log "INFO" "Config loaded: mode=$CURRENT_MODE profile=$ACTIVE_PROFILE"
    else
        CURRENT_MODE="$DEFAULT_MODE"
        ACTIVE_PROFILE="default"
        log "INFO" "No config found, using defaults"
    fi
}

save_mode() {
    if [[ -f "$CONFIG_FILE" ]] && $PYTHON_CMD -c "import json" &>/dev/null 2>&1; then
        $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
c['mode'] = '$CURRENT_MODE'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
" 2>/dev/null
    fi
    log "INFO" "Mode saved: $CURRENT_MODE"
}

# ── Status Indicators ──
python_status() {
    if [[ -n "$PYTHON_CMD" ]]; then
        echo -e "Python: ${C_GREEN}${PYTHON_VERSION}${C_RESET} ${C_TICK}"
    else
        echo -e "Python: ${C_RED}not found${C_RESET} ${C_CROSS}"
    fi
}

deps_status() {
    if [[ $DEPS_INSTALLED -eq $DEPS_TOTAL ]]; then
        echo -e "Dependencies: ${C_GREEN}${DEPS_INSTALLED}/${DEPS_TOTAL}${C_RESET} ${C_TICK}"
    elif [[ $DEPS_INSTALLED -gt 0 ]]; then
        echo -e "Dependencies: ${C_YELLOW}${DEPS_INSTALLED}/${DEPS_TOTAL}${C_RESET} ${C_WARN}"
    else
        echo -e "Dependencies: ${C_RED}${DEPS_INSTALLED}/${DEPS_TOTAL}${C_RESET} ${C_CROSS}"
    fi
}

ports_status() {
    if [[ $PORTS_FOUND -gt 0 ]]; then
        echo -e "Serial ports: ${C_GREEN}${PORTS_FOUND} found${C_RESET}"
    else
        echo -e "Serial ports: ${C_YELLOW}none found${C_RESET}"
    fi
}

# ════════════════════════════════════════════
# ── SIMPLE MODE MENU ──
# ════════════════════════════════════════════
menu_simple() {
    clear
    print_box_top
    print_box_line "${C_BOLT} ${C_BOLD}${APP_NAME}${C_RESET} ${C_DIM}v${APP_VERSION}${C_RESET}"
    if [[ $PORTS_FOUND -gt 0 ]]; then
        local first_port="${SERIAL_PORTS[0]%%|*}"
        print_box_line "${first_port} @ ${DEFAULT_BAUD}"
    fi
    print_box_line "$(python_status)"
    print_box_line "$(deps_status)"
    print_box_mid
    print_box_empty
    print_box_line "  ${C_BOLD}1${C_RESET}) Launch web app"
    print_box_line "  ${C_BOLD}2${C_RESET}) Send script"
    print_box_line "  ${C_BOLD}3${C_RESET}) Quick command"
    print_box_line "  ${C_BOLD}4${C_RESET}) Switch to ${C_CYAN}advanced${C_RESET} mode"
    print_box_line "  ${C_BOLD}q${C_RESET}) Quit"
    print_box_empty
    print_box_bot
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        1) do_launch ;;
        2) do_send_script_simple ;;
        3) do_quick_command_simple ;;
        4) CURRENT_MODE="advanced"; save_mode; log "INFO" "Switched to advanced mode" ;;
        q|Q) do_quit ;;
        *) ;;
    esac
}

# ════════════════════════════════════════════
# ── ADVANCED MODE MENU ──
# ════════════════════════════════════════════
menu_advanced() {
    clear
    print_box_top
    print_box_line "${C_BOLT} ${C_BOLD}${APP_NAME}${C_RESET} ${C_DIM}v${APP_VERSION}${C_RESET}"
    print_box_line "Profile: ${C_CYAN}${ACTIVE_PROFILE}${C_RESET}"
    print_box_line "Environment: ${C_CYAN}${ENV_TYPE}${C_RESET}"
    print_box_line "$(python_status)"
    print_box_line "$(deps_status)"
    print_box_line "$(ports_status)"
    print_box_mid
    print_box_empty
    print_box_line "  ${C_BOLD}1${C_RESET}) Launch web app"
    print_box_line "  ${C_BOLD}2${C_RESET}) Install / update dependencies"
    print_box_line "  ${C_BOLD}3${C_RESET}) Check system status"
    print_box_line "  ${C_BOLD}4${C_RESET}) List serial ports"
    print_box_line "  ${C_BOLD}5${C_RESET}) Predefined commands"
    print_box_line "  ${C_BOLD}6${C_RESET}) Profiles"
    print_box_line "  ${C_BOLD}7${C_RESET}) Settings"
    print_box_line "  ${C_BOLD}8${C_RESET}) Session replay"
    print_box_line "  ${C_BOLD}9${C_RESET}) View logs"
    print_box_line "  ${C_BOLD}0${C_RESET}) Uninstall dependencies"
    print_box_line "  ${C_BOLD}s${C_RESET}) Switch to ${C_CYAN}simple${C_RESET} mode"
    print_box_line "  ${C_BOLD}q${C_RESET}) Quit"
    print_box_empty
    print_box_bot
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        1) do_launch ;;
        2) do_install_deps ;;
        3) do_system_status ;;
        4) do_list_ports ;;
        5) menu_predefined_commands ;;
        6) menu_profiles ;;
        7) menu_settings ;;
        8) menu_session_replay ;;
        9) menu_logs ;;
        0) do_uninstall_deps ;;
        s|S) CURRENT_MODE="simple"; save_mode; log "INFO" "Switched to simple mode" ;;
        q|Q) do_quit ;;
        *) ;;
    esac
}

# ════════════════════════════════════════════
# ── ACTIONS ──
# ════════════════════════════════════════════

# ── Launch Web App ──
do_launch() {
    if [[ -z "$PYTHON_CMD" ]]; then
        echo -e "\n  ${C_CROSS} Python not found. Install Python 3.8+ first."
        pause; return
    fi
    if [[ $DEPS_INSTALLED -lt $DEPS_TOTAL ]]; then
        echo -e "\n  ${C_WARN} Missing dependencies."
        if confirm "Install now?"; then
            do_install_deps
        else
            return
        fi
    fi
    if [[ ! -f "$APP_FILE" ]]; then
        echo -e "\n  ${C_CROSS} app.py not found at $APP_FILE"
        pause; return
    fi

    # Detect LAN IP
    local lan_ip
    lan_ip=$($PYTHON_CMD -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
    s.close()
except:
    print('127.0.0.1')
" 2>/dev/null || echo "127.0.0.1")

    echo -e "\n  ${C_BOLT} Starting ${APP_NAME} v${APP_VERSION}..."
    echo -e "  ${C_DIM}Press Ctrl+C to stop and return to menu${C_RESET}"
    echo ""
    echo -e "  Local:  ${C_GREEN}http://127.0.0.1:8000${C_RESET}"
    if [[ "$lan_ip" != "127.0.0.1" ]]; then
        echo -e "  LAN:    ${C_GREEN}http://${lan_ip}:8000${C_RESET}"
        echo -e "  ${C_DIM}→ Open this URL on your phone/tablet${C_RESET}"
    fi
    echo ""
    log "INFO" "Launching web app (LAN: $lan_ip)"

    cd "$SCRIPT_DIR"
    $PYTHON_CMD "$APP_FILE" || true
    log "INFO" "Web app stopped"
    pause
}

# ── Install Dependencies ──
do_install_deps() {
    if [[ -z "$PYTHON_CMD" ]]; then
        echo -e "\n  ${C_CROSS} Python not found."
        pause; return
    fi
    if ! detect_pip; then
        echo -e "\n  ${C_CROSS} pip not found. Try: ${C_BOLD}${PYTHON_CMD} -m ensurepip${C_RESET}"
        pause; return
    fi

    echo -e "\n  Installing dependencies...\n"
    log "INFO" "Installing dependencies"

    local pip_flags=""
    # Detect if --break-system-packages is needed (Debian 12+, Ubuntu 23.04+)
    if $PIP_CMD install --help 2>&1 | grep -q 'break-system-packages'; then
        pip_flags="--break-system-packages"
    fi

    if [[ -f "$REQUIREMENTS_FILE" ]]; then
        $PIP_CMD install -r "$REQUIREMENTS_FILE" $pip_flags 2>&1 | while read -r line; do
            echo "  $line"
            log "INFO" "pip: $line"
        done
    else
        $PIP_CMD install fastapi uvicorn pyserial python-multipart $pip_flags 2>&1 | while read -r line; do
            echo "  $line"
            log "INFO" "pip: $line"
        done
    fi

    check_dependencies
    echo ""
    echo -e "  $(deps_status)"
    pause
}

# ── Uninstall Dependencies ──
do_uninstall_deps() {
    echo ""
    if ! confirm "Uninstall fastapi, uvicorn, pyserial, python-multipart?"; then
        return
    fi

    local pip_flags=""
    if $PIP_CMD install --help 2>&1 | grep -q 'break-system-packages'; then
        pip_flags="--break-system-packages"
    fi

    echo ""
    $PIP_CMD uninstall -y fastapi uvicorn pyserial python-multipart $pip_flags 2>&1 | while read -r line; do
        echo "  $line"
    done
    log "INFO" "Dependencies uninstalled"
    check_dependencies
    echo ""
    echo -e "  $(deps_status)"
    pause
}

# ── System Status ──
do_system_status() {
    clear
    echo -e "\n  ${C_BOLD}System Status${C_RESET} — ${C_DIM}${APP_TAG}${C_RESET}\n"
    print_line

    echo -e "  OS:           $(uname -s) $(uname -r)"
    echo -e "  Environment:  ${C_CYAN}${ENV_TYPE}${C_RESET}"
    echo -e "  $(python_status)"
    if [[ -n "$PYTHON_CMD" ]]; then
        echo -e "  Python path:  $(command -v $PYTHON_CMD)"
    fi
    if [[ -n "${PIP_CMD:-}" ]]; then
        echo -e "  Pip:          ${C_TICK} $($PIP_CMD --version 2>&1 | head -1)"
    else
        echo -e "  Pip:          ${C_CROSS} not found"
    fi

    print_line
    echo -e "  $(deps_status)"
    local deps_map=("fastapi:fastapi" "uvicorn:uvicorn" "pyserial:serial" "python-multipart:multipart")
    for entry in "${deps_map[@]}"; do
        local pkg="${entry%%:*}"
        local mod="${entry##*:}"
        if $PYTHON_CMD -c "import $mod" &>/dev/null 2>&1; then
            echo -e "    $pkg  ${C_TICK}"
        else
            echo -e "    $pkg  ${C_CROSS}"
        fi
    done

    print_line
    echo -e "  $(ports_status)"
    if [[ $PORTS_FOUND -gt 0 ]]; then
        for p in "${SERIAL_PORTS[@]}"; do
            local dev="${p%%|*}"
            local desc="${p##*|}"
            echo -e "    ${C_CYAN}${dev}${C_RESET}  ${C_DIM}${desc}${C_RESET}"
        done
    fi

    print_line
    echo -e "  Config:       ${CONFIG_FILE}"
    echo -e "  Log:          ${LOG_FILE}"
    echo -e "  Mode:         ${CURRENT_MODE}"
    echo -e "  Profile:      ${ACTIVE_PROFILE}"

    log "INFO" "System status displayed"
    pause
}

# ── List Serial Ports ──
do_list_ports() {
    echo -e "\n  ${C_BOLD}Serial Ports${C_RESET}\n"
    scan_serial_ports
    if [[ $PORTS_FOUND -eq 0 ]]; then
        echo -e "  ${C_WARN} No serial ports found."
        echo -e "  ${C_DIM}Check cable connection and drivers.${C_RESET}"
    else
        for i in "${!SERIAL_PORTS[@]}"; do
            local p="${SERIAL_PORTS[$i]}"
            local dev="${p%%|*}"
            local desc="${p##*|}"
            echo -e "  ${C_BOLD}$((i+1)))${C_RESET} ${C_CYAN}${dev}${C_RESET}"
            echo -e "     ${C_DIM}${desc}${C_RESET}"
        done
    fi
    pause
}

# ── Send Script (Simple) ──
do_send_script_simple() {
    if [[ -z "$PYTHON_CMD" ]] || [[ $DEPS_INSTALLED -lt $DEPS_TOTAL ]]; then
        echo -e "\n  ${C_CROSS} Dependencies not installed. Use option 4 → advanced → install."
        pause; return
    fi

    echo -e "\n  ${C_BOLD}Send Script${C_RESET}\n"

    # Pick port
    scan_serial_ports
    if [[ $PORTS_FOUND -eq 0 ]]; then
        echo -e "  ${C_CROSS} No serial ports found."
        pause; return
    elif [[ $PORTS_FOUND -eq 1 ]]; then
        local port="${SERIAL_PORTS[0]%%|*}"
        echo -e "  Auto-selected: ${C_CYAN}${port}${C_RESET}"
    else
        echo "  Select port:"
        for i in "${!SERIAL_PORTS[@]}"; do
            local dev="${SERIAL_PORTS[$i]%%|*}"
            echo "    $((i+1))) $dev"
        done
        read -rp "  Port [1]: " pnum
        pnum="${pnum:-1}"
        local port="${SERIAL_PORTS[$((pnum-1))]%%|*}"
    fi

    # Get script file
    read -rp "  Script file path: " script_path
    if [[ ! -f "$script_path" ]]; then
        echo -e "  ${C_CROSS} File not found: $script_path"
        pause; return
    fi

    echo -e "\n  Sending ${C_BOLD}${script_path}${C_RESET} to ${C_CYAN}${port}${C_RESET}..."
    log "INFO" "Sending script $script_path to $port"

    $PYTHON_CMD -c "
import serial, time, sys

port = '$port'
baud = $DEFAULT_BAUD
script_path = '$script_path'

try:
    ser = serial.Serial(port, baud, timeout=0.1, write_timeout=5)
    time.sleep(0.5)

    with open(script_path, 'r') as f:
        lines = f.readlines()

    ser.write(b\"cat > /tmp/script.sh << 'ENDOFSCRIPT'\n\")
    time.sleep(0.1)

    for line in lines:
        line = line.rstrip('\r\n') + '\n'
        ser.write(line.encode())
        time.sleep(0.05)

    ser.write(b'ENDOFSCRIPT\n')
    time.sleep(0.3)
    ser.write(b\"sed -i 's/\r//' /tmp/script.sh\n\")
    time.sleep(0.2)
    ser.write(b'bash /tmp/script.sh\n')

    print('  Script sent and executed.')
    time.sleep(2)
    while ser.in_waiting:
        print(ser.read(ser.in_waiting).decode(errors='replace'), end='')
    ser.close()
except Exception as e:
    print(f'  Error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1

    log "INFO" "Script sent"
    pause
}

# ── Quick Command (Simple) ──
do_quick_command_simple() {
    if [[ -z "$PYTHON_CMD" ]] || [[ $DEPS_INSTALLED -lt $DEPS_TOTAL ]]; then
        echo -e "\n  ${C_CROSS} Dependencies not installed."
        pause; return
    fi

    echo -e "\n  ${C_BOLD}Quick Command${C_RESET}\n"
    echo -e "  ${C_BOLD}1${C_RESET}) Board info     ${C_DIM}(uname -a)${C_RESET}"
    echo -e "  ${C_BOLD}2${C_RESET}) Disk usage      ${C_DIM}(df -h)${C_RESET}"
    echo -e "  ${C_BOLD}3${C_RESET}) Memory          ${C_DIM}(free -h)${C_RESET}"
    echo -e "  ${C_BOLD}4${C_RESET}) Uptime          ${C_DIM}(uptime)${C_RESET}"
    echo -e "  ${C_BOLD}5${C_RESET}) Custom command"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice

    local cmd=""
    case "$choice" in
        1) cmd="uname -a && cat /etc/os-release" ;;
        2) cmd="df -h" ;;
        3) cmd="free -h" ;;
        4) cmd="uptime" ;;
        5) read -rp "  Command: " cmd ;;
        b|B) return ;;
        *) return ;;
    esac

    if [[ -z "$cmd" ]]; then return; fi

    # Pick port
    scan_serial_ports
    if [[ $PORTS_FOUND -eq 0 ]]; then
        echo -e "  ${C_CROSS} No serial ports found."
        pause; return
    fi
    local port="${SERIAL_PORTS[0]%%|*}"

    echo -e "\n  Running on ${C_CYAN}${port}${C_RESET}: ${C_BOLD}${cmd}${C_RESET}\n"
    log "INFO" "Quick command: $cmd on $port"

    $PYTHON_CMD -c "
import serial, time
ser = serial.Serial('$port', $DEFAULT_BAUD, timeout=1, write_timeout=5)
time.sleep(0.3)
ser.write(b'$cmd\n')
time.sleep(2)
while ser.in_waiting:
    print(ser.read(ser.in_waiting).decode(errors='replace'), end='')
ser.close()
" 2>&1 || echo -e "  ${C_CROSS} Failed to execute"

    pause
}

# ════════════════════════════════════════════
# ── PREDEFINED COMMANDS SUB-MENU ──
# ════════════════════════════════════════════
menu_predefined_commands() {
    clear
    echo -e "\n  ${C_BOLD}Predefined Commands${C_RESET}\n"
    print_line
    echo -e "  ${C_DIM}System Info:${C_RESET}"
    echo -e "   ${C_BOLD}1${C_RESET}) Board info         ${C_DIM}uname -a && cat /etc/os-release${C_RESET}"
    echo -e "   ${C_BOLD}2${C_RESET}) Disk usage          ${C_DIM}df -h${C_RESET}"
    echo -e "   ${C_BOLD}3${C_RESET}) Memory usage        ${C_DIM}free -h${C_RESET}"
    echo -e "   ${C_BOLD}4${C_RESET}) CPU info            ${C_DIM}cat /proc/cpuinfo | head -20${C_RESET}"
    echo -e "   ${C_BOLD}5${C_RESET}) Uptime & load       ${C_DIM}uptime${C_RESET}"
    echo ""
    echo -e "  ${C_DIM}Network:${C_RESET}"
    echo -e "   ${C_BOLD}6${C_RESET}) IP addresses        ${C_DIM}ip addr show${C_RESET}"
    echo -e "   ${C_BOLD}7${C_RESET}) Network interfaces  ${C_DIM}ip link show${C_RESET}"
    echo -e "   ${C_BOLD}8${C_RESET}) Active connections   ${C_DIM}ss -tulnp${C_RESET}"
    echo ""
    echo -e "  ${C_DIM}Services:${C_RESET}"
    echo -e "   ${C_BOLD}9${C_RESET}) Running processes   ${C_DIM}ps aux | head -20${C_RESET}"
    echo -e "  ${C_BOLD}10${C_RESET}) Systemd services    ${C_DIM}systemctl list-units --type=service --state=running${C_RESET}"
    echo -e "  ${C_BOLD}11${C_RESET}) Kernel log          ${C_DIM}dmesg | tail -30${C_RESET}"
    echo ""
    echo -e "  ${C_DIM}Actions:${C_RESET}"
    echo -e "  ${C_BOLD}12${C_RESET}) Reboot board        ${C_RED}⚠ requires confirm${C_RESET}"
    echo -e "  ${C_BOLD}13${C_RESET}) Shutdown board      ${C_RED}⚠ requires confirm${C_RESET}"
    echo -e "  ${C_BOLD}14${C_RESET}) Sync filesystems    ${C_DIM}sync${C_RESET}"
    echo ""
    echo -e "  ${C_DIM}Custom:${C_RESET}"
    echo -e "  ${C_BOLD}15${C_RESET}) Run custom command"
    echo -e "  ${C_BOLD}16${C_RESET}) Manage saved commands"
    echo -e "   ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice

    local cmd=""
    local need_confirm=false
    case "$choice" in
        1)  cmd="uname -a && cat /etc/os-release" ;;
        2)  cmd="df -h" ;;
        3)  cmd="free -h" ;;
        4)  cmd="cat /proc/cpuinfo | head -20" ;;
        5)  cmd="uptime" ;;
        6)  cmd="ip addr show" ;;
        7)  cmd="ip link show" ;;
        8)  cmd="ss -tulnp" ;;
        9)  cmd="ps aux | head -20" ;;
        10) cmd="systemctl list-units --type=service --state=running" ;;
        11) cmd="dmesg | tail -30" ;;
        12) cmd="reboot"; need_confirm=true ;;
        13) cmd="shutdown -h now"; need_confirm=true ;;
        14) cmd="sync" ;;
        15) read -rp "  Command: " cmd ;;
        16) menu_manage_commands; return ;;
        b|B) return ;;
        *) return ;;
    esac

    if [[ -z "$cmd" ]]; then return; fi
    if $need_confirm; then
        echo ""
        if ! confirm "${C_RED}Really run '${cmd}' on the board?${C_RESET}"; then
            return
        fi
    fi

    run_serial_command "$cmd"
    pause
}

# ── Run Command Over Serial ──
run_serial_command() {
    local cmd="$1"
    scan_serial_ports
    if [[ $PORTS_FOUND -eq 0 ]]; then
        echo -e "  ${C_CROSS} No serial ports found."
        return 1
    fi

    local port="${SERIAL_PORTS[0]%%|*}"
    echo -e "\n  ${C_DIM}→ ${port}:${C_RESET} ${C_BOLD}${cmd}${C_RESET}\n"
    log "INFO" "Running: $cmd on $port"

    $PYTHON_CMD -c "
import serial, time
try:
    ser = serial.Serial('$port', $DEFAULT_BAUD, timeout=1, write_timeout=5)
    time.sleep(0.3)
    cmd = '''$cmd'''
    ser.write((cmd + '\n').encode())
    time.sleep(2)
    while ser.in_waiting:
        print(ser.read(ser.in_waiting).decode(errors='replace'), end='')
    print()
    ser.close()
except Exception as e:
    print(f'  Error: {e}')
" 2>&1
}

# ── Manage Saved Commands ──
menu_manage_commands() {
    clear
    echo -e "\n  ${C_BOLD}Manage Saved Commands${C_RESET}\n"

    # Load commands
    if [[ -f "$COMMANDS_FILE" ]]; then
        echo -e "  ${C_DIM}Current commands:${C_RESET}"
        local i=1
        while IFS='=' read -r name cmd_val; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            echo -e "    ${C_BOLD}${i}${C_RESET}) ${C_CYAN}${name}${C_RESET} = ${C_DIM}${cmd_val}${C_RESET}"
            ((i++))
        done < "$COMMANDS_FILE"
    else
        echo -e "  ${C_DIM}No saved commands yet.${C_RESET}"
    fi

    echo ""
    echo -e "  ${C_BOLD}a${C_RESET}) Add command"
    echo -e "  ${C_BOLD}d${C_RESET}) Delete command"
    echo -e "  ${C_BOLD}e${C_RESET}) Edit raw file"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        a|A)
            read -rp "  Name: " name
            read -rp "  Command: " cmd_val
            echo "${name}=${cmd_val}" >> "$COMMANDS_FILE"
            echo -e "  ${C_TICK} Saved"
            log "INFO" "Command added: $name=$cmd_val"
            pause
            ;;
        d|D)
            read -rp "  Name to delete: " name
            if [[ -f "$COMMANDS_FILE" ]]; then
                sed -i "/^${name}=/d" "$COMMANDS_FILE"
                echo -e "  ${C_TICK} Deleted"
                log "INFO" "Command deleted: $name"
            fi
            pause
            ;;
        e|E)
            ${EDITOR:-nano} "$COMMANDS_FILE" 2>/dev/null || vi "$COMMANDS_FILE"
            ;;
        b|B) return ;;
    esac
}

# ════════════════════════════════════════════
# ── PROFILES SUB-MENU ──
# ════════════════════════════════════════════
menu_profiles() {
    clear
    echo -e "\n  ${C_BOLD}Profiles${C_RESET}\n"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "  ${C_DIM}No config file. Launch the app once to create defaults.${C_RESET}"
        pause; return
    fi

    # List profiles
    $PYTHON_CMD -c "
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
profiles = c.get('profiles', {})
active = c.get('active_profile', 'default')
if not profiles:
    print('  No profiles configured.')
else:
    for name, p in profiles.items():
        marker = ' [active]' if name == active else ''
        port = p.get('port', '?')
        baud = p.get('baudrate', '?')
        print(f'  {name}{marker}')
        print(f'    {port} @ {baud}')
" 2>/dev/null

    echo ""
    echo -e "  ${C_BOLD}s${C_RESET}) Switch profile"
    echo -e "  ${C_BOLD}a${C_RESET}) Add profile"
    echo -e "  ${C_BOLD}d${C_RESET}) Delete profile"
    echo -e "  ${C_BOLD}e${C_RESET}) Edit raw config"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        s|S)
            read -rp "  Profile name: " pname
            $PYTHON_CMD -c "
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if '$pname' in c.get('profiles', {}):
    c['active_profile'] = '$pname'
    conn = c['profiles']['$pname']
    c['connection'] = {**c.get('connection', {}), **conn}
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(c, f, indent=2)
    print('  Switched to $pname')
else:
    print('  Profile not found')
" 2>/dev/null
            ACTIVE_PROFILE="$pname"
            log "INFO" "Profile switched: $pname"
            pause
            ;;
        a|A)
            read -rp "  Profile name: " pname
            read -rp "  Port: " pport
            read -rp "  Baud rate [115200]: " pbaud
            pbaud="${pbaud:-115200}"
            $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
c.setdefault('profiles', {})
c['profiles']['$pname'] = {'port': '$pport', 'baudrate': $pbaud}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Profile added: $pname')
" 2>/dev/null
            log "INFO" "Profile added: $pname"
            pause
            ;;
        d|D)
            read -rp "  Profile to delete: " pname
            $PYTHON_CMD -c "
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
c.get('profiles', {}).pop('$pname', None)
if c.get('active_profile') == '$pname':
    c['active_profile'] = 'default'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Deleted: $pname')
" 2>/dev/null
            log "INFO" "Profile deleted: $pname"
            pause
            ;;
        e|E)
            ${EDITOR:-nano} "$CONFIG_FILE" 2>/dev/null || vi "$CONFIG_FILE"
            ;;
        b|B) return ;;
    esac
}

# ════════════════════════════════════════════
# ── SETTINGS SUB-MENU ──
# ════════════════════════════════════════════
menu_settings() {
    clear
    echo -e "\n  ${C_BOLD}Settings${C_RESET}\n"
    echo -e "  ${C_BOLD}1${C_RESET}) Connection defaults (port, baud, flow control)"
    echo -e "  ${C_BOLD}2${C_RESET}) Line ending mode"
    echo -e "  ${C_BOLD}3${C_RESET}) Behavior flags"
    echo -e "  ${C_BOLD}4${C_RESET}) Reconnect settings"
    echo -e "  ${C_BOLD}5${C_RESET}) Logging settings"
    echo -e "  ${C_BOLD}6${C_RESET}) Reset to defaults"
    echo -e "  ${C_BOLD}7${C_RESET}) Export config"
    echo -e "  ${C_BOLD}8${C_RESET}) Import config"
    echo -e "  ${C_BOLD}9${C_RESET}) Edit raw config (json)"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        1) settings_connection ;;
        2) settings_line_ending ;;
        3) settings_behavior ;;
        4) settings_reconnect ;;
        5) settings_logging ;;
        6)
            if confirm "Reset all settings to defaults?"; then
                rm -f "$CONFIG_FILE"
                echo -e "  ${C_TICK} Config reset"
                log "INFO" "Config reset to defaults"
            fi
            pause
            ;;
        7)
            local export_path="${HOME}/ssl_config_export.json"
            cp "$CONFIG_FILE" "$export_path" 2>/dev/null
            echo -e "  ${C_TICK} Exported to: $export_path"
            log "INFO" "Config exported to $export_path"
            pause
            ;;
        8)
            read -rp "  Import file path: " import_path
            if [[ -f "$import_path" ]]; then
                cp "$import_path" "$CONFIG_FILE"
                load_config
                echo -e "  ${C_TICK} Config imported"
                log "INFO" "Config imported from $import_path"
            else
                echo -e "  ${C_CROSS} File not found"
            fi
            pause
            ;;
        9)
            ${EDITOR:-nano} "$CONFIG_FILE" 2>/dev/null || vi "$CONFIG_FILE"
            load_config
            ;;
        b|B) return ;;
    esac
}

settings_connection() {
    echo ""
    echo -e "  ${C_BOLD}Connection Defaults${C_RESET}"
    echo ""
    read -rp "  Port (current: auto): " val
    read -rp "  Baud rate (current: $DEFAULT_BAUD): " baud_val
    read -rp "  Flow control [none/rtscts/xonxoff]: " flow_val
    read -rp "  Data bits [5/6/7/8]: " data_val
    read -rp "  Parity [none/odd/even]: " parity_val
    read -rp "  Stop bits [1/1.5/2]: " stop_val

    $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
conn = c.setdefault('connection', {})
if '$val': conn['port'] = '$val'
if '$baud_val': conn['baudrate'] = int('${baud_val:-115200}')
if '$flow_val': conn['flow_control'] = '$flow_val'
if '$data_val': conn['data_bits'] = int('${data_val:-8}')
if '$parity_val': conn['parity'] = '$parity_val'
if '$stop_val': conn['stop_bits'] = float('${stop_val:-1}')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Settings saved')
" 2>/dev/null
    log "INFO" "Connection settings updated"
    pause
}

settings_line_ending() {
    echo ""
    echo -e "  ${C_BOLD}Line Ending Mode${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}1${C_RESET}) Auto (detect & fix)"
    echo -e "  ${C_BOLD}2${C_RESET}) Force LF (strip all \\r)"
    echo -e "  ${C_BOLD}3${C_RESET}) Preserve (send as-is)"
    echo ""
    read -rp "  Choose [1]: " choice
    local mode="auto"
    case "$choice" in
        2) mode="lf" ;;
        3) mode="preserve" ;;
        *) mode="auto" ;;
    esac

    $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
c.setdefault('connection', {})['line_ending'] = '$mode'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Line ending mode: $mode')
" 2>/dev/null
    log "INFO" "Line ending mode: $mode"
    pause
}

settings_behavior() {
    echo ""
    echo -e "  ${C_BOLD}Behavior Flags${C_RESET}"
    echo ""
    echo -e "  Toggle each flag (y/n):"
    echo ""
    local flags=("auto_execute" "auto_open_browser" "dangerous_cmd_guard" "dry_run" "syntax_check")
    for flag in "${flags[@]}"; do
        read -rp "  $flag [y/n/skip]: " val
        if [[ "$val" == "y" || "$val" == "n" ]]; then
            local bool_val="true"
            [[ "$val" == "n" ]] && bool_val="false"
            $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
c.setdefault('behavior', {})['$flag'] = $bool_val
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
" 2>/dev/null
        fi
    done
    echo -e "  ${C_TICK} Behavior flags saved"
    log "INFO" "Behavior flags updated"
    pause
}

settings_reconnect() {
    echo ""
    echo -e "  ${C_BOLD}Reconnect Settings${C_RESET}"
    echo ""
    read -rp "  Enable auto-reconnect [y/n]: " enabled
    read -rp "  Retry interval (seconds) [3]: " interval
    read -rp "  Max retries (0=unlimited) [0]: " retries
    read -rp "  Resend script on reconnect [y/n]: " resend

    $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
r = c.setdefault('reconnect', {})
r['enabled'] = '${enabled:-y}' == 'y'
r['interval_seconds'] = int('${interval:-3}')
r['max_retries'] = int('${retries:-0}')
r['resend_on_reconnect'] = '${resend:-n}' == 'y'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Reconnect settings saved')
" 2>/dev/null
    log "INFO" "Reconnect settings updated"
    pause
}

settings_logging() {
    echo ""
    echo -e "  ${C_BOLD}Logging Settings${C_RESET}"
    echo ""
    read -rp "  Enable session logging [y/n]: " enabled
    read -rp "  Max sessions to keep [50]: " max_sess
    read -rp "  Max total size MB [100]: " max_size

    $PYTHON_CMD -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
except:
    c = {}
l = c.setdefault('logging', {})
l['enabled'] = '${enabled:-y}' == 'y'
l['max_sessions'] = int('${max_sess:-50}')
l['max_size_mb'] = int('${max_size:-100}')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print('  Logging settings saved')
" 2>/dev/null
    log "INFO" "Logging settings updated"
    pause
}

# ════════════════════════════════════════════
# ── SESSION REPLAY SUB-MENU ──
# ════════════════════════════════════════════
menu_session_replay() {
    clear
    echo -e "\n  ${C_BOLD}Session Replay${C_RESET}\n"

    # List sessions
    local sessions=()
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && sessions+=("$f")
        done < <(find "$LOG_DIR" -name "session_*.jsonl" -type f | sort -r | head -10)
    fi

    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo -e "  ${C_DIM}No recorded sessions found.${C_RESET}"
        echo -e "  ${C_DIM}Sessions are recorded when using the web app.${C_RESET}"
        pause; return
    fi

    for i in "${!sessions[@]}"; do
        local f="${sessions[$i]}"
        local fname="$(basename "$f")"
        local lines=$(wc -l < "$f")
        local size=$(du -h "$f" | cut -f1)
        echo -e "  ${C_BOLD}$((i+1))${C_RESET}) ${C_CYAN}${fname}${C_RESET}  ${C_DIM}(${lines} events, ${size})${C_RESET}"
    done

    echo ""
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Select session: " choice

    [[ "$choice" == "b" || "$choice" == "B" ]] && return
    local idx=$((choice - 1))
    if [[ $idx -lt 0 || $idx -ge ${#sessions[@]} ]]; then return; fi

    local session_file="${sessions[$idx]}"
    echo ""
    echo -e "  ${C_BOLD}1${C_RESET}) Play in terminal (real-time)"
    echo -e "  ${C_BOLD}2${C_RESET}) Play at 5x speed"
    echo -e "  ${C_BOLD}3${C_RESET}) View as plain text"
    echo -e "  ${C_BOLD}4${C_RESET}) Search in session"
    echo -e "  ${C_BOLD}5${C_RESET}) Delete session"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " subchoice
    case "$subchoice" in
        1) replay_session "$session_file" 1 ;;
        2) replay_session "$session_file" 5 ;;
        3)
            local txt_file="${session_file%.jsonl}.log"
            if [[ -f "$txt_file" ]]; then
                less "$txt_file"
            else
                echo -e "  ${C_WARN} No plain text log for this session"
                pause
            fi
            ;;
        4)
            read -rp "  Search term: " term
            grep -i "$term" "$session_file" | head -20
            pause
            ;;
        5)
            if confirm "Delete this session?"; then
                rm -f "$session_file" "${session_file%.jsonl}.log"
                echo -e "  ${C_TICK} Deleted"
                log "INFO" "Session deleted: $(basename "$session_file")"
            fi
            pause
            ;;
    esac
}

replay_session() {
    local file="$1"
    local speed="${2:-1}"
    echo -e "\n  ${C_BOLD}Replaying at ${speed}x...${C_RESET} (Ctrl+C to stop)\n"
    $PYTHON_CMD -c "
import json, time, sys

speed = $speed
prev_t = 0
try:
    with open('$file') as f:
        for line in f:
            ev = json.loads(line.strip())
            t = ev.get('t', 0)
            delay = (t - prev_t) / speed
            if delay > 0 and delay < 10:
                time.sleep(delay)
            prev_t = t
            etype = ev.get('type', '')
            data = ev.get('data', '')
            if etype == 'tx':
                sys.stdout.write('\033[34m' + data + '\033[0m')
            elif etype == 'rx':
                sys.stdout.write('\033[32m' + data + '\033[0m')
            elif etype in ('connect', 'disconnect', 'reconnect'):
                reason = ev.get('reason', '')
                sys.stdout.write(f'\033[33m[{etype}] {reason}\033[0m\n')
            sys.stdout.flush()
except KeyboardInterrupt:
    print('\n\n  Replay stopped.')
" 2>&1
    pause
}

# ════════════════════════════════════════════
# ── LOGS SUB-MENU ──
# ════════════════════════════════════════════
menu_logs() {
    clear
    echo -e "\n  ${C_BOLD}View Logs${C_RESET}\n"
    echo -e "  ${C_BOLD}1${C_RESET}) View full log"
    echo -e "  ${C_BOLD}2${C_RESET}) View last 50 lines"
    echo -e "  ${C_BOLD}3${C_RESET}) Errors only"
    echo -e "  ${C_BOLD}4${C_RESET}) Clear log"
    echo -e "  ${C_BOLD}5${C_RESET}) Export log"
    echo -e "  ${C_BOLD}b${C_RESET}) Back"
    echo ""
    read -rp "  Choose: " choice
    case "$choice" in
        1)
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                echo -e "  ${C_DIM}No log file yet.${C_RESET}"
                pause
            fi
            ;;
        2)
            if [[ -f "$LOG_FILE" ]]; then
                tail -50 "$LOG_FILE"
            else
                echo -e "  ${C_DIM}No log file yet.${C_RESET}"
            fi
            pause
            ;;
        3)
            if [[ -f "$LOG_FILE" ]]; then
                grep -i '\[ERROR\]\|\[WARN\]' "$LOG_FILE" | tail -30 || echo "  No errors found"
            else
                echo -e "  ${C_DIM}No log file yet.${C_RESET}"
            fi
            pause
            ;;
        4)
            if confirm "Clear log file?"; then
                > "$LOG_FILE"
                echo -e "  ${C_TICK} Log cleared"
                log "INFO" "Log cleared by user"
            fi
            pause
            ;;
        5)
            local export_path="${HOME}/ssl_log_export.log"
            cp "$LOG_FILE" "$export_path" 2>/dev/null
            echo -e "  ${C_TICK} Exported to: $export_path"
            pause
            ;;
        b|B) return ;;
    esac
}

# ════════════════════════════════════════════
# ── FIRST RUN ──
# ════════════════════════════════════════════
first_run() {
    clear
    echo ""
    echo -e "  ${C_BOLT} ${C_BOLD}Welcome to ${APP_NAME} v${APP_VERSION}!${C_RESET}"
    echo ""
    echo -e "  Choose your mode:"
    echo ""
    echo -e "  ${C_BOLD}1${C_RESET}) ${C_GREEN}Simple${C_RESET}  — Quick and clean. Connect, send, done."
    echo -e "  ${C_BOLD}2${C_RESET}) ${C_CYAN}Advanced${C_RESET} — Full control. Profiles, replay, settings."
    echo ""
    read -rp "  Choose [1]: " choice
    case "$choice" in
        2) CURRENT_MODE="advanced" ;;
        *) CURRENT_MODE="simple" ;;
    esac

    # Create default config
    mkdir -p "$LOG_DIR"
    $PYTHON_CMD -c "
import json
config = {
    'mode': '$CURRENT_MODE',
    'active_profile': 'default',
    'connection': {
        'port': '',
        'baudrate': 115200,
        'data_bits': 8,
        'parity': 'none',
        'stop_bits': 1,
        'flow_control': 'none',
        'dtr': None,
        'rts': None,
        'local_echo': False,
        'line_delay_ms': 50,
        'line_ending': 'auto'
    },
    'behavior': {
        'auto_execute': True,
        'auto_open_browser': True,
        'dangerous_cmd_guard': True,
        'dry_run': False,
        'syntax_check': True
    },
    'reconnect': {
        'enabled': True,
        'interval_seconds': 3,
        'max_retries': 0,
        'resend_on_reconnect': False
    },
    'logging': {
        'enabled': True,
        'directory': 'logs',
        'format': ['txt', 'jsonl'],
        'max_sessions': 50,
        'max_size_mb': 100,
        'auto_cleanup': True
    },
    'paths': {
        'remote_script_path': '/tmp/script.sh',
        'watch_folder': None,
        'log_file': 'ssl.log'
    },
    'scrollback': {
        'max_lines': 10000
    },
    'profiles': {
        'default': {
            'port': '',
            'baudrate': 115200
        }
    },
    'last_session': {
        'last_port': '',
        'last_script': '',
        'last_connected': ''
    }
}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null

    save_mode
    log "INFO" "First run completed. Mode: $CURRENT_MODE"

    # Auto-install if needed
    if [[ $DEPS_INSTALLED -lt $DEPS_TOTAL ]]; then
        echo ""
        echo -e "  ${C_WARN} Some dependencies are missing."
        if confirm "Install them now?"; then
            do_install_deps
        fi
    fi
}

# ── Quit ──
do_quit() {
    echo ""
    echo -e "  ${C_DIM}Goodbye!${C_RESET}"
    log "INFO" "Quit"
    exit 0
}

# ════════════════════════════════════════════
# ── MAIN ──
# ════════════════════════════════════════════
main() {
    setup_colors

    # Startup checks
    detect_environment
    detect_python || true
    detect_pip || true
    if [[ -n "$PYTHON_CMD" ]]; then
        check_dependencies
        scan_serial_ports
    fi

    # First run?
    if [[ ! -f "$CONFIG_FILE" ]]; then
        first_run
    else
        load_config
    fi

    log "INFO" "${APP_TAG} started (mode=$CURRENT_MODE, env=$ENV_TYPE)"

    # Main loop
    while true; do
        if [[ "$CURRENT_MODE" == "simple" ]]; then
            menu_simple
        else
            menu_advanced
        fi
    done
}

main "$@"
