#!/bin/bash

# ==========================================
#   ULTIMATE TUNNEL MANAGER (IPv4/IPv6 + FRP)
# ==========================================

# --- Global Configurations ---
GRETAP_IF="gt-l2"
BR_IF="br-l2"
IRAN_TUN_IP="10.10.10.2"
FOREIGN_TUN_IP="10.10.10.1"
RT_TABLE_ID="200"
RT_TABLE_NAME="l2tunnel"
MTU_VAL="1400"
MSS_VAL_V4="1360"
MSS_VAL_V6="1340"
GRE_SERVICE="/etc/systemd/system/l2tunnel.service"
GRE_CONFIG="/etc/l2tunnel.conf"

require_root() {
    [[ $EUID -ne 0 ]] && { echo "❌ Error: Run as root"; exit 1; }
}

# --- Shared Optimization ---
smart_optimize() {
    echo "🔍 Analyzing and Optimizing System..."
    modprobe nf_conntrack 2>/dev/null || true
    modprobe ip_gre 2>/dev/null || true
    modprobe ip6_gre 2>/dev/null || true
    modprobe gretap 2>/dev/null || true
    
    sysctl -w net.core.default_qdisc=fq >/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$MEM_TOTAL" -gt 512 ]; then
            sysctl -w net.netfilter.nf_conntrack_max=131072 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_buckets=32768 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=300 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 >/dev/null
            sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=30 >/dev/null
        fi
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
}

# ==========================================
# PART 1: GRETAP L2 LOGIC
# ==========================================

cleanup_gretap() {
    echo "🧹 Cleaning up GRETAP..."
    systemctl disable l2tunnel --now 2>/dev/null
    iptables -t nat -F; iptables -t mangle -F
    ip rule del table $RT_TABLE_NAME 2>/dev/null || true
    ip route flush table $RT_TABLE_NAME 2>/dev/null || true
    ip link del $GRETAP_IF 2>/dev/null || true
    ip link del $BR_IF 2>/dev/null || true
    rm $GRE_SERVICE$GRE_CONFIG 2>/dev/null
}

setup_l2_gre() {
    local LOCAL_IP=$1; local REMOTE_IP=$2; local BRIDGE_IP=$3; local IP_VER=$4
    
    if [[ "$IP_VER" == "6" ]]; then
        ip link add $GRETAP_IF type ip6gretap local $LOCAL_IP remote$REMOTE_IP
    else
        local PUB_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
        ip link add $GRETAP_IF type gretap local$LOCAL_IP remote $REMOTE_IP dev$PUB_IF
    fi
    
    ip link add $BR_IF type bridge
    ip link set $GRETAP_IF master$BR_IF
    ip addr add $BRIDGE_IP/30 dev$BR_IF
    ip link set $GRETAP_IF mtu$MTU_VAL up
    ip link set $BR_IF mtu$MTU_VAL up
}

setup_iran_gre() {
    local PORTS=$1; local ACTIVE_MSS=$2
    if ! grep -q "$RT_TABLE_ID$RT_TABLE_NAME" /etc/iproute2/rt_tables; then
        echo "$RT_TABLE_ID$RT_TABLE_NAME" >> /etc/iproute2/rt_tables
    fi
    ip route add default via $FOREIGN_TUN_IP dev $BR_IF table$RT_TABLE_NAME 2>/dev/null || true
    ip rule add from $IRAN_TUN_IP table$RT_TABLE_NAME priority 100 2>/dev/null || true
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $ACTIVE_MSS
    for p in $(echo "$PORTS" | tr ',' ' '); do
        p=$(echo $p \vert{} xargs); [[ -z "$p" ]] && continue
        iptables -t nat -A PREROUTING -p tcp --dport $p -j DNAT --to-destination$FOREIGN_TUN_IP
        iptables -t nat -A PREROUTING -p udp --dport $p -j DNAT --to-destination$FOREIGN_TUN_IP
    done
    iptables -t nat -A POSTROUTING -o $BR_IF -j MASQUERADE
}

setup_foreign_gre() {
    local ACTIVE_MSS=$1
    local PUB_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $ACTIVE_MSS
    iptables -t nat -A POSTROUTING -o $PUB_IF -j MASQUERADE
}

run_gretap_menu() {
    while true; do
        clear
        echo "🔵 GRETAP L2 TUNNEL SECTION"
        echo "--------------------------"
        echo "1) Setup IRAN Server"
        echo "2) Setup FOREIGN Server"
        echo "3) Remove GRETAP ONLY"
        echo "4) Back to Main Menu"
        read -p "Selection: " gchoice
        
        case $gchoice in
            1|2)
                echo -e "\nSelect IP Protocol for Tunnel:"
                echo "4) IPv4"
                echo "6) IPv6"
                read -p "IP Version (4/6): " IP_VER
                
                if [[ "$IP_VER" != "4" && "$IP_VER" != "6" ]]; then
                    echo "❌ Invalid IP version. Please enter 4 or 6."
                    sleep 2; continue
                fi
                
                read -p "Enter Local IP(v$IP_VER): " LOCAL
                read -p "Enter Remote IP(v$IP_VER): " REMOTE
                
                [[ $gchoice == 1 ]] && read -p "VPN Ports (e.g. 443,9010): " PORTS
                cleanup_gretap; smart_optimize
                
                local CURRENT_MSS=$MSS_VAL_V4
                [[ "$IP_VER" == "6" ]] && CURRENT_MSS=$MSS_VAL_V6
                
                if [[ $gchoice == 1 ]]; then
                    setup_l2_gre $LOCAL$REMOTE $IRAN_TUN_IP$IP_VER
                    setup_iran_gre "$PORTS" "$CURRENT_MSS"
                    MODE="IRAN"
                else
                    setup_l2_gre $LOCAL$REMOTE $FOREIGN_TUN_IP$IP_VER
                    setup_foreign_gre "$CURRENT_MSS"
                    MODE="FOREIGN"
                fi
                
                read -p "Enable autostart? (y/n): " PERSIST
                if [[ $PERSIST == "y" ]]; then
                    echo -e "MODE=$MODE\nIP_VER=$IP_VER\nLOCAL=$LOCAL\nREMOTE=$REMOTE\nPORTS='$PORTS'\nCURRENT_MSS=$CURRENT_MSS" > $GRE_CONFIG
                    cat <<EOF > $GRE_SERVICE
[Unit]
Description=L2Tunnel GRETAP Service
After=network.target
[Service]
Type=oneshot
ExecStart=$(readlink -f "$0") --start-gre
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload; systemctl enable l2tunnel
                fi
                echo "✅ GRETAP Established!"; read -p "Press Enter..." ;;
            3) cleanup_gretap; read -p "GRETAP Removed. Press Enter..." ;;
            4) break ;;
        esac
    done
}

# ==========================================
# PART 2: FRP REVERSE LOGIC (RESTORED TO ORIGINAL)
# ==========================================

cleanup_frp() {
    echo "🧹 Removing FRP..."
    systemctl stop frps@server-3090.service frpc@client-3090.service 2>/dev/null || true
    systemctl disable frps@server-3090.service frpc@client-3090.service 2>/dev/null || true
    rm -f /
