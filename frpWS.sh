#!/bin/bash

# FRP Installation Script (WS Version - Fixed)
# Balanced for Iran network stability

show_menu() {
    clear
    echo "=================================="
    echo "     FRP Reverse Tunnel (WS)      "
    echo "=================================="
    echo "1) Install FRP Server (Iran - WS)"
    echo "2) Install FRP Client (Kharej - WS)"
    echo "3) Remove FRP"
    echo "4) Exit"
    echo "=================================="
    read -p "Choose an option [1-4]: " choice
}

install_server() {
    echo "=== Installing FRP Server (frps) on Iran ==="

    curl -L -o /usr/local/bin/frps http://81.12.32.210/downloads/frps
    chmod +x /usr/local/bin/frps

    mkdir -p /root/frp/server

    cat > /root/frp/server/server-3090.toml <<'EOF'
bindAddr = "0.0.0.0"
bindPort = 3090

transport.maxPoolCount = 65535
transport.tcpMux = true

auth.method = "token"
auth.token = "tun100"
EOF

    cat > /etc/systemd/system/frps@.service <<'EOF'
[Unit]
Description=FRP Server (%i)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /root/frp/server/%i.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps@server-3090.service
    systemctl restart frps@server-3090.service

    echo "FRP Server (WS) started on port 3090!"
}

install_client() {
    echo "=== Installing FRP Client (frpc) on Kharej ==="

    curl -L -o /usr/local/bin/frpc https://raw.githubusercontent.com/lostsoul6/frp-file/refs/heads/main/frpc
    chmod +x /usr/local/bin/frpc

    mkdir -p /root/frp/client

    read -p "Enter Iran server IP: " server_addr
    read -p "Enter ports (e.g. 8080 or 443,2053): " ports
    ports=${ports:-8080}

    escaped_ports=$(printf '%s' "$ports" | sed 's/"/\\"/g')

    cat > /root/frp/client/client-3090.toml <<EOF
serverAddr = "$server_addr"
serverPort = 3090

loginFailExit = false

auth.method = "token"
auth.token = "tun100"

# WS Transport Fixes
transport.protocol = "websocket"
transport.tcpMux = true
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.poolCount = 5

{{- range \$_, \$v := parseNumberRangePair "$escaped_ports" "$escaped_ports" }}
[[proxies]]
name = "ws-{{ \$v.First }}"
type = "tcp"
localIP = "127.0.0.1"
localPort = {{ \$v.First }}
remotePort = {{ \$v.Second }}
EOF
# اضافه کردن انتهای فایل به دلیل ساختار template
    echo '{{- end }}' >> /root/frp/client/client-3090.toml

    cat > /etc/systemd/system/frpc@.service <<'EOF'
[Unit]
Description=FRP Client (%i)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /root/frp/client/%i.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frpc@client-3090.service
    systemctl restart frpc@client-3090.service

    echo "FRP Client (WS) started!"
    echo "Check status with: systemctl status frpc@client-3090"
}

remove_frp() {
    systemctl stop frps@server-3090.service frpc@client-3090.service 2>/dev/null
    rm -rf /root/frp /usr/local/bin/frps /usr/local/bin/frpc /etc/systemd/system/frps@.service /etc/systemd/system/frpc@.service
    systemctl daemon-reload
    echo "Cleaned up."
}

while true; do
    show_menu
    case $choice in
        1) install_server ;;
        2) install_client ;;
        3) remove_frp ;;
        4) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    read -p "Press Enter to continue..."
done
