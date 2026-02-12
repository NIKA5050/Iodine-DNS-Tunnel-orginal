#!/bin/bash

# ==============================================================================
#   IODINE DNS TUNNEL MANAGER (FIXED FOR XRAY LOCALHOST + DNS0 REDIRECT)
#
#   CLIENT (Iran):
#     Redirect 127.0.0.1:<ports>  --->  10.50.50.1:<ports> (inside iodine tunnel)
#     via iptables NAT OUTPUT DNAT
#
#   SERVER (Outside):
#     Keep Xray inbounds listening on 127.0.0.1 (NOT 0.0.0.0)
#     Redirect dns0 inbound traffic 10.50.50.1:<ports>  --->  127.0.0.1:<ports>
#     via iptables NAT PREROUTING REDIRECT (interface dns0)
# ==============================================================================

set -euo pipefail

# --- Safety Check: Ensure Root Access ---
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# --- Global Configuration ---
CONF_FILE="/etc/iodine-manager.conf"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="iodine-mgr"
LOG_FILE="/tmp/iodine_install.log"

# Tunnel Configuration
TUN_SERVER_IP_DEFAULT="10.50.50.1"
MTU_SIZE="1200"

# --- Colors & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helper: Progress Bar ---
show_progress() {
    local duration=${1}
    local prefix=${2}
    local block="█"
    local empty="░"
    local width=30
    echo -ne "${prefix} "
    for (( i=0; i<=$width; i++ )); do
        local percent=$(( i * 100 / width ))
        local num_block=$i
        local num_empty=$(( width - i ))
        local bar_str=""
        for (( j=0; j<num_block; j++ )); do bar_str="${bar_str}${block}"; done
        for (( j=0; j<num_empty; j++ )); do bar_str="${bar_str}${empty}"; done
        echo -ne "[${BLUE}${bar_str}${NC}] ${percent}%\r"
        sleep "$duration"
    done
    echo -ne "\n"
}

# --- Helper: Dynamic Header ---
draw_header() {
    clear
    local service_stat="inactive"
    local role="NONE"

    if systemctl is-active --quiet iodine-server; then
        service_stat="${GREEN}RUNNING${NC}"
        role="SERVER"
    elif systemctl is-active --quiet iodine-client; then
        service_stat="${GREEN}RUNNING${NC}"
        role="CLIENT"
    else
        service_stat="${RED}STOPPED${NC}"
    fi

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${BOLD}      I O D I N E   D N S   T U N N E L   M G R       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " Service Status: ${service_stat}"
    echo -e " Current Role:   ${YELLOW}${role}${NC}"

    if [[ "$service_stat" == *"RUNNING"* ]]; then
        local tun_ip
        tun_ip=$(ip -4 addr show dns0 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)
        echo -e " Tunnel IF/IP:   ${BLUE}dns0 / ${tun_ip:-Unknown}${NC}"
    fi
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

# --- Core: Dependency Installation ---
install_deps() {
    echo -e "${YELLOW}>>> Starting Dependency Check & Installation...${NC}"
    show_progress 0.05 "Checking System "

    if ! command -v iodined &> /dev/null || ! command -v iptables &> /dev/null || ! command -v lsof &> /dev/null; then
        echo -e "Installing tools..." >> "$LOG_FILE"
        if [ -f /etc/debian_version ]; then
            apt-get update -q && apt-get install -y -q iodine iproute2 iptables curl lsof >> "$LOG_FILE" 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y -q epel-release >> "$LOG_FILE" 2>&1
            yum install -y -q iodine iproute iptables curl lsof >> "$LOG_FILE" 2>&1
        else
            echo -e "${RED}Unsupported distro. Install iodine/iproute2/iptables/lsof manually.${NC}"
            exit 1
        fi
    fi

    if [[ "$(realpath "$0")" != "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
        cp "$(realpath "$0")" "$INSTALL_DIR/$SCRIPT_NAME"
        chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    fi

    echo -e "${GREEN}>>> Dependencies Ready.${NC}"
    sleep 1
}

# --- CRITICAL: Check Port 53 (Server Only) ---
check_port_53() {
    echo -e "${YELLOW}Checking Port 53 availability...${NC}"
    local occupiers
    occupiers=$(lsof -i :53 -t 2>/dev/null | tr '\n' ' ' || true)

    if [ -n "${occupiers:-}" ]; then
        local first_pid process_name
        first_pid=$(echo "$occupiers" | awk '{print $1}')
        process_name=$(ps -p "$first_pid" -o comm= 2>/dev/null || echo "unknown")

        echo -e "${RED}[WARNING] Port 53 is occupied. Example PID: ${BOLD}${first_pid}${NC} (${process_name})"

        if [[ "$process_name" == "systemd-resolve" || "$process_name" == "systemd-resolved" ]]; then
            echo -e "This prevents Iodine server from starting."
            read -p "Stop systemd-resolved and set /etc/resolv.conf? [y/n]: " fix_dns
            if [[ "$fix_dns" == "y" || "$fix_dns" == "Y" ]]; then
                echo -e "${BLUE}Fixing DNS conflict...${NC}"
                systemctl stop systemd-resolved || true
                systemctl disable systemd-resolved || true
                rm -f /etc/resolv.conf
                {
                  echo "nameserver 8.8.8.8"
                  echo "nameserver 1.1.1.1"
                } > /etc/resolv.conf
                echo -e "${GREEN}Port 53 freed. DNS set to Google/Cloudflare.${NC}"
            else
                echo -e "${RED}Aborting. Iodine server cannot run while Port 53 is busy.${NC}"
                exit 1
            fi
        else
            echo -e "${RED}Unknown process on Port 53. Please free it manually.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Port 53 is free.${NC}"
    fi
}

# --- iptables helpers (idempotent) ---
ipt_add() {
    local table="$1"; shift
    local chain="$1"; shift
    if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        return 0
    fi
    iptables -t "$table" -A "$chain" "$@"
}

ipt_del_if_exists() {
    local table="$1"; shift
    local chain="$1"; shift
    if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        iptables -t "$table" -D "$chain" "$@"
    fi
}

# --- Core: Firewall Logic (CLIENT OUTPUT DNAT + SERVER dns0 REDIRECT) ---
apply_firewall() {
    source "$CONF_FILE" 2>/dev/null || true

    local DEFAULT_IF
    DEFAULT_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)

    # Enable forwarding (harmless on client, useful on server)
    sysctl -w net.ipv4.ip_forward=1 >> "$LOG_FILE" 2>&1 || true

    # NAT masquerade (general)
    if [ -n "${DEFAULT_IF:-}" ]; then
        ipt_add nat POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi
    ipt_add nat POSTROUTING -o dns0 -j MASQUERADE

    # Load tunnel server ip
    TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"

    # Parse ports list once
    local ports_arr=()
    if [ -n "${PORT_LIST:-}" ]; then
        IFS=',' read -ra ports_arr <<< "$PORT_LIST"
    fi

    # -----------------------------
    # CLIENT MODE:
    #  127.0.0.1:port -> 10.50.50.1:port via OUTPUT DNAT
    # -----------------------------
    if [[ "${ROLE:-}" == "client" && -n "${PORT_LIST:-}" ]]; then
        for port in "${ports_arr[@]}"; do
            port=$(echo "$port" | xargs)
            [[ -z "$port" ]] && continue

            ipt_add nat OUTPUT -p tcp -d 127.0.0.1 --dport "$port" -j DNAT --to-destination "$TUN_SERVER_IP:$port"

            if [[ "${REDIRECT_UDP:-0}" == "1" ]]; then
                ipt_add nat OUTPUT -p udp -d 127.0.0.1 --dport "$port" -j DNAT --to-destination "$TUN_SERVER_IP:$port"
            fi
        done
    fi

    # -----------------------------
    # SERVER MODE:
    #  Keep Xray inbounds on 127.0.0.1 and redirect dns0 inbound to local ports:
    #   (dns0 ingress) 10.50.50.1:port  ->  REDIRECT -> 127.0.0.1:port
    # -----------------------------
    if [[ "${ROLE:-}" == "server" && -n "${PORT_LIST:-}" ]]; then
        for port in "${ports_arr[@]}"; do
            port=$(echo "$port" | xargs)
            [[ -z "$port" ]] && continue

            # Only traffic coming from tunnel interface dns0
            ipt_add nat PREROUTING -i dns0 -p tcp --dport "$port" -j REDIRECT --to-ports "$port"

            if [[ "${REDIRECT_UDP:-0}" == "1" ]]; then
                ipt_add nat PREROUTING -i dns0 -p udp --dport "$port" -j REDIRECT --to-ports "$port"
            fi
        done
    fi
}

# --- Logic: Create Systemd Service ---
create_service() {
    local service_name="iodine-${ROLE}"
    local exec_cmd=""

    TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"

    if [ "$ROLE" == "server" ]; then
        exec_cmd="/usr/sbin/iodined -f -c -P $PASSWORD -m $MTU_SIZE $TUN_SERVER_IP $DOMAIN"
    else
        exec_cmd="/usr/sbin/iodine -f -P $PASSWORD -m $MTU_SIZE $DOMAIN"
    fi

    cat <<EOF > "/etc/systemd/system/${service_name}.service"
[Unit]
Description=Iodine DNS Tunnel ($ROLE)
After=network.target

[Service]
ExecStart=$exec_cmd
Restart=always
RestartSec=5
User=root
ExecStartPost=/bin/bash -c '$INSTALL_DIR/$SCRIPT_NAME --apply-fw'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" >> "$LOG_FILE" 2>&1
    systemctl restart "${service_name}"
}

# --- Feature: Status & Ping ---
check_status() {
    draw_header
    echo -e "${BOLD}--- Interface Info (dns0) ---${NC}"
    ip addr show dns0 2>/dev/null | grep inet || echo -e "${RED}Tunnel interface not found! Service might be down.${NC}"

    echo -e "\n${BOLD}--- Connection Test ---${NC}"
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
        TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"

        if [ "${ROLE:-}" == "server" ]; then
            echo -e "Server Mode: Tunnel IP is ${YELLOW}${TUN_SERVER_IP}${NC}"
            echo -e "Tip: On server, make sure Xray listens on 127.0.0.1:<ports> (this script redirects from dns0)."
        else
            echo -e "Pinging Server IP: ${YELLOW}${TUN_SERVER_IP}${NC} ..."
            if ping -c 3 -W 3 "$TUN_SERVER_IP"; then
                echo -e "\n${GREEN}[SUCCESS] Tunnel Connection is Alive!${NC}"
            else
                echo -e "\n${RED}[FAIL] Could not reach server. Check DNS, domain NS, or firewall.${NC}"
            fi
        fi
    fi

    echo -e "\n------------------------------------------------------"
    read -p "Press Enter..."
}

# --- Logic: Setup ---
run_setup() {
    install_deps

    echo -e "${BOLD}Select Installation Role:${NC}"
    echo "1) Server (Outside)  - Keep Xray on 127.0.0.1, redirect from dns0"
    echo "2) Client (Iran)     - Keep Xray outbounds to 127.0.0.1, DNAT into tunnel"
    read -p "Select [1/2]: " opt

    if [ "$opt" == "1" ]; then
        ROLE="server"
        check_port_53

        echo -e "\n${RED}${BOLD}IMPORTANT REQUIREMENT:${NC}"
        echo -e "You must have a real domain."
        echo -e "1) Create an A record (e.g. ${CYAN}tun.domain.com${NC}) to this server IP."
        echo -e "2) Create an NS record (e.g. ${CYAN}t1.domain.com${NC}) -> ${CYAN}tun.domain.com${NC}."
        echo -e "------------------------------------------------------"

        read -p "Enter your NS Subdomain (e.g. t1.domain.com): " DOMAIN
        read -p "Enter Tunnel Password: " PASSWORD
        read -p "Tunnel Server IP [default ${TUN_SERVER_IP_DEFAULT}]: " TUN_SERVER_IP
        TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"

        echo -e "${YELLOW}Enter the SAME 8 ports your Xray inbounds use (to redirect from dns0 to 127.0.0.1).${NC}"
        echo -e "Example: 443,8080,2020,3030,2087,8880,4040,5050"
        read -p "Ports: " PORT_LIST

        read -p "Also redirect UDP for these ports on server? [y/N]: " udp_opt
        if [[ "$udp_opt" == "y" || "$udp_opt" == "Y" ]]; then
            REDIRECT_UDP="1"
        else
            REDIRECT_UDP="0"
        fi

    elif [ "$opt" == "2" ]; then
        ROLE="client"
        read -p "Enter Server NS Subdomain (e.g. t1.domain.com): " DOMAIN
        read -p "Enter Tunnel Password: " PASSWORD
        read -p "Tunnel Server IP [default ${TUN_SERVER_IP_DEFAULT}]: " TUN_SERVER_IP
        TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"

        echo -e "${YELLOW}Ports to redirect from localhost (127.0.0.1) into the tunnel (Comma separated).${NC}"
        echo -e "These should match the 8 ports you use for outside inbounds."
        echo -e "Example: 443,8080,2020,3030,2087,8880,4040,5050"
        read -p "Ports: " PORT_LIST

        read -p "Also redirect UDP for these ports on client? [y/N]: " udp_opt
        if [[ "$udp_opt" == "y" || "$udp_opt" == "Y" ]]; then
            REDIRECT_UDP="1"
        else
            REDIRECT_UDP="0"
        fi
    else
        echo "Invalid option."
        return
    fi

    cat <<EOF > "$CONF_FILE"
ROLE=$ROLE
DOMAIN=$DOMAIN
PASSWORD=$PASSWORD
TUN_SERVER_IP=$TUN_SERVER_IP
PORT_LIST=$PORT_LIST
REDIRECT_UDP=$REDIRECT_UDP
EOF

    systemctl stop iodine-server 2>/dev/null || true
    systemctl stop iodine-client 2>/dev/null || true
    systemctl disable iodine-server 2>/dev/null || true
    systemctl disable iodine-client 2>/dev/null || true

    show_progress 0.05 "Configuring Service"
    create_service

    echo -e "\n${GREEN}[SUCCESS] Iodine $ROLE installed and started!${NC}"

    apply_firewall

    read -p "Do you want to check connection status now? (y/n): " do_check
    if [[ "$do_check" == "y" || "$do_check" == "Y" ]]; then
        check_status
    fi
}

# --- Feature: Uninstall ---
clean_all() {
    echo -e "${RED}>>> WARNING: This will remove Iodine and related Firewall rules.${NC}"
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    systemctl stop iodine-server 2>/dev/null || true
    systemctl stop iodine-client 2>/dev/null || true
    systemctl disable iodine-server 2>/dev/null || true
    systemctl disable iodine-client 2>/dev/null || true

    source "$CONF_FILE" 2>/dev/null || true

    local DEFAULT_IF
    DEFAULT_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    if [ -n "${DEFAULT_IF:-}" ]; then
        ipt_del_if_exists nat POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi
    ipt_del_if_exists nat POSTROUTING -o dns0 -j MASQUERADE

    # Remove per-port rules
    if [ -n "${PORT_LIST:-}" ]; then
        TUN_SERVER_IP="${TUN_SERVER_IP:-$TUN_SERVER_IP_DEFAULT}"
        IFS=',' read -ra ADDR <<< "$PORT_LIST"
        for port in "${ADDR[@]}"; do
            port=$(echo "$port" | xargs)
            [[ -z "$port" ]] && continue

            # Client-style localhost DNAT
            ipt_del_if_exists nat OUTPUT -p tcp -d 127.0.0.1 --dport "$port" -j DNAT --to-destination "$TUN_SERVER_IP:$port"
            ipt_del_if_exists nat OUTPUT -p udp -d 127.0.0.1 --dport "$port" -j DNAT --to-destination "$TUN_SERVER_IP:$port"

            # Server-style dns0 redirect
            ipt_del_if_exists nat PREROUTING -i dns0 -p tcp --dport "$port" -j REDIRECT --to-ports "$port"
            ipt_del_if_exists nat PREROUTING -i dns0 -p udp --dport "$port" -j REDIRECT --to-ports "$port"
        done
    fi

    rm -f "$CONF_FILE" \
          /etc/systemd/system/iodine-server.service \
          /etc/systemd/system/iodine-client.service \
          "$INSTALL_DIR/$SCRIPT_NAME"

    systemctl daemon-reload

    echo -e "${GREEN}[SUCCESS] Removed Successfully.${NC}"
    read -p "Press Enter..."
}

# --- Service Menu ---
service_menu() {
    local svc="iodine-client"
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE" 2>/dev/null || true
        svc="iodine-${ROLE:-client}"
    else
        if systemctl is-active --quiet iodine-server; then svc="iodine-server"; fi
        if systemctl is-active --quiet iodine-client; then svc="iodine-client"; fi
    fi

    while true; do
        draw_header
        echo -e "${BOLD}--- Service Management ($svc) ---${NC}"
        echo "1) View Logs (journalctl)"
        echo "2) Restart Service"
        echo "3) Stop Service"
        echo "4) Back to Main Menu"
        read -p "Select: " s_opt
        case $s_opt in
            1) journalctl -u "$svc" -f -n 50 ;;
            2) systemctl restart "$svc"; echo -e "${GREEN}Restarted.${NC}"; sleep 1 ;;
            3) systemctl stop "$svc"; echo -e "${RED}Stopped.${NC}"; sleep 1 ;;
            4) break ;;
        esac
    done
}

# --- Hidden Flag for Post-Start Firewall ---
if [ "${1:-}" == "--apply-fw" ]; then
    apply_firewall
    exit 0
fi

# --- Main Menu ---
while true; do
    draw_header
    echo "1) Install & Configure"
    echo "2) Service Manager"
    echo "3) Show Status / Ping Test"
    echo "4) Uninstall & Remove"
    echo "5) Exit"
    echo "------------------------------------------------------"
    read -p "Select option: " opt
    case $opt in
        1) run_setup ;;
        2) service_menu ;;
        3) check_status ;;
        4) clean_all ;;
        5) exit 0 ;;
        *) echo "Invalid Option"; sleep 1 ;;
    esac
done
