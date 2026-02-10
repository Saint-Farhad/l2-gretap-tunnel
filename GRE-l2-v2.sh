#!/bin/bash

# Configuration
GRETAP_IF="gt-l2"
BR_IF="br-l2"
IRAN_TUN_IP="10.10.10.2"
FOREIGN_TUN_IP="10.10.10.1"
RT_TABLE_ID="200"
RT_TABLE_NAME="l2tunnel"
MTU_VAL="1400"
MSS_VAL="1360"
SERVICE_FILE="/etc/systemd/system/l2tunnel.service"
CONFIG_FILE="/etc/l2tunnel.conf"

require_root() {
    [[ $EUID -ne 0 ]] && { echo "❌ Error: Run as root"; exit 1; }
}

smart_kernel_optimize() {
    echo "🔍 Analyzing system for network optimization..."
    
    # 1. Ensure conntrack module is loaded
    modprobe nf_conntrack 2>/dev/null || true
    
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
        local CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
        local CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
        
        echo "📊 Current Connections: $CONN_COUNT / $CONN_MAX"
        
        # 2. Safety Check: Only increase if RAM > 512MB
        if [ "$MEM_TOTAL" -gt 512 ]; then
            echo "🚀 RAM is sufficient ($MEM_TOTAL MB). Applying high-performance tweaks..."
            
            sysctl -w net.netfilter.nf_conntrack_max=131072 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_buckets=32768 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=300 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=30 >/dev/null
            
            # Save for persistence
            cat <<EOF > /etc/sysctl.d/99-tunnel-optimize.conf
net.netfilter.nf_conntrack_max=131072
net.netfilter.nf_conntrack_buckets=32768
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=30
EOF
        else
            echo "⚠️ Low RAM detected ($MEM_TOTAL MB). Skipping aggressive optimizations for safety."
        fi
    else
        echo "ℹ️ Conntrack not supported or not loaded. Skipping."
    fi
}

optimize_system() {
    echo "🔧 Basic System Optimization..."
    modprobe ip_gre 2>/dev/null || true
    modprobe gretap 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
    
    # Call our new smart function
    smart_kernel_optimize
}

cleanup() {
    echo "🧹 Cleaning up existing configurations..."
    iptables -t nat -F
    iptables -t mangle -F
    ip rule del table $RT_TABLE_NAME 2>/dev/null || true
    ip route flush table $RT_TABLE_NAME 2>/dev/null || true
    ip link del $GRETAP_IF 2>/dev/null || true
    ip link del $BR_IF 2>/dev/null || true
    rm /etc/sysctl.d/99-tunnel-optimize.conf 2>/dev/null || true
}

setup_l2() {
    local LOCAL_IP=$1
    local REMOTE_IP=$2
    local BRIDGE_IP=$3
    local PUB_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

    echo "🏗 Creating Interface: $GRETAP_IF on $PUB_IF"
    ip link add $GRETAP_IF type gretap local $LOCAL_IP remote $REMOTE_IP dev $PUB_IF
    ip link add $BR_IF type bridge
    ip link set $GRETAP_IF master $BR_IF
    ip addr add $BRIDGE_IP/30 dev $BR_IF
    ip link set $GRETAP_IF mtu $MTU_VAL up
    ip link set $BR_IF mtu $MTU_VAL up
}

setup_iran() {
    local PORTS=$1
    echo "🇮🇷 Applying Iran Rules..."
    if ! grep -q "$RT_TABLE_ID $RT_TABLE_NAME" /etc/iproute2/rt_tables; then
        echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables
    fi
    ip route add default via $FOREIGN_TUN_IP dev $BR_IF table $RT_TABLE_NAME 2>/dev/null || true
    ip rule add from $IRAN_TUN_IP table $RT_TABLE_NAME priority 100 2>/dev/null || true
    
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
    for p in $(echo "$PORTS" | tr ',' ' '); do
        p=$(echo $p | xargs)
        [[ -z "$p" ]] && continue
        iptables -t nat -A PREROUTING -p tcp --dport $p -j DNAT --to-destination $FOREIGN_TUN_IP
        iptables -t nat -A PREROUTING -p udp --dport $p -j DNAT --to-destination $FOREIGN_TUN_IP
    done
    iptables -t nat -A POSTROUTING -o $BR_IF -j MASQUERADE
}

setup_foreign() {
    echo "🇪🇺 Applying Foreign Rules..."
    local PUB_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
    iptables -t nat -A POSTROUTING -o $PUB_IF -j MASQUERADE
}

# --- Management Scripts for Service ---
if [[ "$1" == "--start" ]]; then
    source $CONFIG_FILE
    optimize_system
    if [[ "$MODE" == "IRAN" ]]; then
        setup_l2 $LOCAL $REMOTE $IRAN_TUN_IP
        setup_iran "$PORTS"
    else
        setup_l2 $LOCAL $REMOTE $FOREIGN_TUN_IP
        setup_foreign
    fi
    exit 0
fi

# --- Main Menu ---
require_root
clear
echo "=============================="
echo "    L2 GRETAP TUNNEL FIX + OPT"
echo "=============================="
echo "1) Setup IRAN Server"
echo "2) Setup FOREIGN Server"
echo "3) Remove All & Disable Autostart"
echo "4) Exit"
read -p "Selection: " CHOICE

case $CHOICE in
    1|2)
        read -p "Local Public IP: " LOCAL
        read -p "Remote Public IP: " REMOTE
        [[ $CHOICE == 1 ]] && read -p "VPN Ports (e.g. 443,9010): " PORTS
        
        cleanup
        optimize_system
        
        if [[ $CHOICE == 1 ]]; then
            setup_l2 $LOCAL $REMOTE $IRAN_TUN_IP
            setup_iran "$PORTS"
            MODE="IRAN"
        else
            setup_l2 $LOCAL $REMOTE $FOREIGN_TUN_IP
            setup_foreign
            MODE="FOREIGN"
        fi

        # Persistence Question
        read -p "Enable autostart on boot? (y/n): " PERSIST
        if [[ $PERSIST == "y" ]]; then
            echo -e "MODE=$MODE\nLOCAL=$LOCAL\nREMOTE=$REMOTE\nPORTS='$PORTS'" > $CONFIG_FILE
            cat <<EOF > $SERVICE_FILE
[Unit]
Description=L2Tunnel Service
After=network.target

[Service]
Type=oneshot
ExecStart=$(readlink -f "$0") --start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable l2tunnel
        fi
        echo "✅ Done! Kernel optimized and Tunnel established."
        ;;
    3)
        systemctl disable l2tunnel 2>/dev/null
        rm $SERVICE_FILE $CONFIG_FILE /etc/sysctl.d/99-tunnel-optimize.conf 2>/dev/null
        cleanup
        echo "🧹 Everything cleaned."
        ;;
    4) exit 0 ;;
esac
