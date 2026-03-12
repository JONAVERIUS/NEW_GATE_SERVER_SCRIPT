#!/bin/bash

# ==============================================================================
# FIVEM GATEWAY MANAGER
# - Mode Owner Server (load-balance mapping)
# - Mode Player Limited (soft connection cap)
# - Discord Webhook Monitor (5-minute heartbeat via systemd timer)
# ==============================================================================

OWNER_TARGETS_FILE="/etc/nginx/gate_owner_targets.list"
LEGACY_TARGETS_FILE="/etc/nginx/gate_targets.list"
PLAYER_TARGETS_FILE="/etc/nginx/gate_player_targets.list"
WEBHOOK_CONFIG_FILE="/etc/nginx/gate_webhook.conf"
STREAM_CONF_FILE="/etc/nginx/stream.conf"
NGINX_CONF_FILE="/etc/nginx/nginx.conf"
MONITOR_SCRIPT="/usr/local/bin/fivem_gate_monitor.sh"
MONITOR_SERVICE="/etc/systemd/system/fivem-gate-monitor.service"
MONITOR_TIMER="/etc/systemd/system/fivem-gate-monitor.timer"

print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
print_success() { echo -e "\e[32m[SUKSES]\e[0m $1"; }
print_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
print_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }
print_fatal() { echo -e "\e[31m[FATAL]\e[0m $1"; exit 1; }

require_root() {
    [ "$(id -u)" = "0" ] || print_fatal "Script harus dijalankan sebagai root."
}

ensure_base_files() {
    [ -d "/etc/nginx" ] || mkdir -p /etc/nginx
    [ -d "/etc/nginx/ssl" ] || mkdir -p /etc/nginx/ssl
    [ -f "$OWNER_TARGETS_FILE" ] || touch "$OWNER_TARGETS_FILE"
    [ -f "$PLAYER_TARGETS_FILE" ] || touch "$PLAYER_TARGETS_FILE"
    [ -f "$WEBHOOK_CONFIG_FILE" ] || echo "WEBHOOK_URL=" > "$WEBHOOK_CONFIG_FILE"
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r a b c d <<< "$1"
    for oct in "$a" "$b" "$c" "$d"; do
        [ "$oct" -ge 0 ] && [ "$oct" -le 255 ] || return 1
    done
}

port_exists_in_owner() {
    local p="$1"
    grep -E "^${p}:" "$OWNER_TARGETS_FILE" >/dev/null 2>&1
}

port_exists_in_player() {
    local p="$1"
    grep -E "^${p}:" "$PLAYER_TARGETS_FILE" >/dev/null 2>&1
}

port_in_use_any_mode() {
    local p="$1"
    port_exists_in_owner "$p" || port_exists_in_player "$p"
}

install_nginx() {
    print_info "Memulai instalasi Nginx..."
    apt-get update >/dev/null 2>&1
    apt-get install -y gnupg2 lsb-release software-properties-common wget curl >/dev/null 2>&1

    local os_codename
    os_codename=$(lsb_release -cs)

    curl -fsSL http://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu/ ${os_codename} nginx" | tee /etc/apt/sources.list.d/nginx.list >/dev/null

    apt-get update >/dev/null 2>&1
    apt-get install -y nginx >/dev/null 2>&1
    systemctl enable nginx >/dev/null 2>&1
    systemctl start nginx >/dev/null 2>&1
    print_success "Instalasi Nginx selesai."
}

setup_firewall_basic() {
    print_info "Mengkonfigurasi firewall dasar (SSH, HTTP, HTTPS)..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    print_success "Firewall dasar selesai."
}

cleanup_old_defaults() {
    print_info "Membersihkan konfigurasi default Nginx..."
    rm -f /etc/nginx/conf.d/default.conf
    [ -d "/etc/nginx/ssl" ] || mkdir -p /etc/nginx/ssl
}

migrate_legacy_owner_targets() {
    if [ -s "$LEGACY_TARGETS_FILE" ] && [ ! -s "$OWNER_TARGETS_FILE" ]; then
        cp "$LEGACY_TARGETS_FILE" "$OWNER_TARGETS_FILE"
        print_success "Data legacy dimigrasikan ke mode Owner Server."
    fi
}

open_gate_ports_in_firewall() {
    local p
    while IFS=':' read -r p _; do
        [ -n "$p" ] || continue
        ufw allow "$p/tcp" >/dev/null 2>&1
        ufw allow "$p/udp" >/dev/null 2>&1
    done < <(
        {
            cut -d':' -f1 "$OWNER_TARGETS_FILE" 2>/dev/null
            awk -F':' '{print $1}' "$PLAYER_TARGETS_FILE" 2>/dev/null
        } | sort -n | uniq
    )
}

write_main_nginx_conf() {
    cat <<'EOF' > "$NGINX_CONF_FILE"
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 65535;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    keepalive_timeout 65;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
}

include /etc/nginx/stream.conf;
EOF
}

generate_stream_conf() {
    echo "stream {" > "$STREAM_CONF_FILE"

    # ----------------------
    # Mode Owner Server
    # ----------------------
    local owner_ports=()
    local line gp tip tport

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        gp=$(echo "$line" | cut -d':' -f1)
        is_valid_port "$gp" || continue
        if [[ ! " ${owner_ports[*]} " =~ " ${gp} " ]]; then
            owner_ports+=("$gp")
        fi
    done < "$OWNER_TARGETS_FILE"

    local port entry
    for port in "${owner_ports[@]}"; do
        echo "    upstream owner_backend_${port} {" >> "$STREAM_CONF_FILE"
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            gp=$(echo "$entry" | cut -d':' -f1)
            tip=$(echo "$entry" | cut -d':' -f2)
            tport=$(echo "$entry" | cut -d':' -f3)
            [ "$gp" = "$port" ] || continue
            is_valid_ipv4 "$tip" || continue
            is_valid_port "$tport" || continue
            echo "        server ${tip}:${tport};" >> "$STREAM_CONF_FILE"
        done < "$OWNER_TARGETS_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${port};" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass owner_backend_${port};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${port} udp reuseport;" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass owner_backend_${port};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"
    done

    # ----------------------
    # Mode Player Limited
    # format: gate_port:target_ip:target_port:conn_limit:overflow:status:label
    # ----------------------
    local pgate pip pbackend plimit poverflow pstatus plabel effective
    while IFS=':' read -r pgate pip pbackend plimit poverflow pstatus plabel; do
        [ -n "$pgate" ] || continue
        [ "$pstatus" = "active" ] || continue

        is_valid_port "$pgate" || continue
        is_valid_ipv4 "$pip" || continue
        is_valid_port "$pbackend" || continue
        [[ "$plimit" =~ ^[0-9]+$ ]] || continue
        [[ "$poverflow" =~ ^[0-9]+$ ]] || continue

        effective=$((plimit + poverflow))
        [ "$effective" -ge 1 ] || effective=1

        echo "    limit_conn_zone \$server_port zone=gate_conn_${pgate}:1m;" >> "$STREAM_CONF_FILE"
        echo "    upstream player_backend_${pgate} {" >> "$STREAM_CONF_FILE"
        echo "        server ${pip}:${pbackend};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${pgate};" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass player_backend_${pgate};" >> "$STREAM_CONF_FILE"
        echo "        limit_conn gate_conn_${pgate} ${effective};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${pgate} udp reuseport;" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass player_backend_${pgate};" >> "$STREAM_CONF_FILE"
        echo "        limit_conn gate_conn_${pgate} ${effective};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"
    done < "$PLAYER_TARGETS_FILE"

    echo "}" >> "$STREAM_CONF_FILE"
}

apply_nginx_config() {
    ensure_base_files
    write_main_nginx_conf
    generate_stream_conf
    open_gate_ports_in_firewall

    print_info "Validasi konfigurasi Nginx..."
    if ! nginx -t >/dev/null 2>&1; then
        print_error "Konfigurasi Nginx tidak valid."
        nginx -t
        return 1
    fi

    print_info "Reload Nginx..."
    if systemctl restart nginx >/dev/null 2>&1; then
        print_success "Nginx berhasil direfresh."
        return 0
    fi

    print_error "Gagal me-restart Nginx."
    return 1
}

list_owner_targets() {
    echo ""
    echo "--- Mode Owner Server ---"
    if [ ! -s "$OWNER_TARGETS_FILE" ]; then
        echo "(Kosong)"
        return
    fi

    printf "%-4s | %-10s | %-16s | %-10s\n" "No" "Gate" "Target IP" "Port"
    echo "------------------------------------------------"

    local i=0
    while IFS=':' read -r gp tip tport; do
        [ -n "$gp" ] || continue
        i=$((i + 1))
        printf "%-4s | %-10s | %-16s | %-10s\n" "$i" "$gp" "$tip" "$tport"
    done < "$OWNER_TARGETS_FILE"
}

add_owner_target() {
    echo ""
    print_info "Tambah mapping Owner Server"
    read -r -p "Gate Port (contoh 30120): " gp
    read -r -p "Target Backend IP: " tip
    read -r -p "Target Backend Port (default 30120): " tport
    tport=${tport:-30120}

    if ! is_valid_port "$gp"; then
        print_error "Gate port tidak valid."
        return
    fi
    if ! is_valid_ipv4 "$tip"; then
        print_error "IP backend tidak valid (IPv4)."
        return
    fi
    if ! is_valid_port "$tport"; then
        print_error "Port backend tidak valid."
        return
    fi

    if port_exists_in_player "$gp"; then
        print_error "Port ${gp} sudah dipakai mode Player. Gunakan port lain."
        return
    fi

    echo "${gp}:${tip}:${tport}" >> "$OWNER_TARGETS_FILE"
    if apply_nginx_config; then
        print_success "Mapping owner ditambahkan: ${gp} -> ${tip}:${tport}"
    else
        print_error "Mapping tersimpan, tapi apply config gagal."
    fi
}

delete_owner_target() {
    list_owner_targets
    [ -s "$OWNER_TARGETS_FILE" ] || return

    read -r -p "Nomor yang ingin dihapus (0=batal): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -ge 1 ] || return

    local selected
    selected=$(awk -F':' -v n="$choice" 'NF{c++; if(c==n){print $0; exit}}' "$OWNER_TARGETS_FILE")
    [ -n "$selected" ] || return

    awk -F':' -v n="$choice" 'NF{c++; if(c!=n) print $0}' "$OWNER_TARGETS_FILE" > "${OWNER_TARGETS_FILE}.tmp"
    mv "${OWNER_TARGETS_FILE}.tmp" "$OWNER_TARGETS_FILE"

    if apply_nginx_config; then
        print_success "Mapping owner dihapus: $selected"
    else
        print_error "Hapus tersimpan, tapi apply config gagal."
    fi
}

list_player_gates() {
    echo ""
    echo "--- Mode Player Limited ---"
    if [ ! -s "$PLAYER_TARGETS_FILE" ]; then
        echo "(Kosong)"
        return
    fi

    printf "%-4s | %-10s | %-16s | %-6s | %-5s | %-8s | %-10s\n" "No" "Gate" "Backend" "Limit" "Extra" "Status" "Label"
    echo "--------------------------------------------------------------------------------"

    local i=0
    while IFS=':' read -r gp tip tport limit extra status label; do
        [ -n "$gp" ] || continue
        i=$((i + 1))
        printf "%-4s | %-10s | %-16s | %-6s | %-5s | %-8s | %-10s\n" "$i" "$gp" "${tip}:${tport}" "$limit" "$extra" "$status" "${label:-gate_$gp}"
    done < "$PLAYER_TARGETS_FILE"
}

add_player_gate() {
    echo ""
    print_info "Tambah gate Player (limited)"
    read -r -p "Gate Port customer: " gp
    read -r -p "Target Backend IP: " tip
    read -r -p "Target Backend Port (default 30120): " tport
    read -r -p "Limit dasar (default 2): " limit
    read -r -p "Overflow toleransi (default 3): " extra
    read -r -p "Label customer (default gate_<port>): " label

    tport=${tport:-30120}
    limit=${limit:-2}
    extra=${extra:-3}
    label=${label:-gate_$gp}

    if ! is_valid_port "$gp"; then
        print_error "Gate port tidak valid."
        return
    fi
    if ! is_valid_ipv4 "$tip"; then
        print_error "IP backend tidak valid (IPv4)."
        return
    fi
    if ! is_valid_port "$tport"; then
        print_error "Port backend tidak valid."
        return
    fi
    [[ "$limit" =~ ^[0-9]+$ ]] || { print_error "Limit harus angka."; return; }
    [[ "$extra" =~ ^[0-9]+$ ]] || { print_error "Overflow harus angka."; return; }

    if port_exists_in_owner "$gp"; then
        print_error "Port ${gp} sudah dipakai mode Owner. Gunakan port lain."
        return
    fi
    if port_exists_in_player "$gp"; then
        print_error "Port ${gp} sudah ada di mode Player."
        return
    fi

    echo "${gp}:${tip}:${tport}:${limit}:${extra}:active:${label}" >> "$PLAYER_TARGETS_FILE"
    if apply_nginx_config; then
        print_success "Gate player ditambahkan: ${gp} -> ${tip}:${tport} (limit ${limit}+${extra})"
    else
        print_error "Gate tersimpan, tapi apply config gagal."
    fi
}

edit_player_gate_limit() {
    list_player_gates
    [ -s "$PLAYER_TARGETS_FILE" ] || return

    read -r -p "Nomor gate yang ingin diubah: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -ge 1 ] || return

    local row
    row=$(awk -F':' -v n="$choice" 'NF{c++; if(c==n){print $0; exit}}' "$PLAYER_TARGETS_FILE")
    [ -n "$row" ] || return

    local gp tip tport limit extra status label
    IFS=':' read -r gp tip tport limit extra status label <<< "$row"

    read -r -p "Limit dasar baru (sekarang $limit): " nlimit
    read -r -p "Overflow baru (sekarang $extra): " nextra
    nlimit=${nlimit:-$limit}
    nextra=${nextra:-$extra}

    [[ "$nlimit" =~ ^[0-9]+$ ]] || { print_error "Limit harus angka."; return; }
    [[ "$nextra" =~ ^[0-9]+$ ]] || { print_error "Overflow harus angka."; return; }

    awk -F':' -v n="$choice" -v nl="$nlimit" -v ne="$nextra" 'BEGIN{OFS=":"}
        NF{
            c++
            if(c==n){$4=nl; $5=ne}
            print
        }' "$PLAYER_TARGETS_FILE" > "${PLAYER_TARGETS_FILE}.tmp"
    mv "${PLAYER_TARGETS_FILE}.tmp" "$PLAYER_TARGETS_FILE"

    if apply_nginx_config; then
        print_success "Limit gate ${gp} diperbarui menjadi ${nlimit}+${nextra}."
    else
        print_error "Update tersimpan, tapi apply config gagal."
    fi
}

toggle_player_gate_status() {
    list_player_gates
    [ -s "$PLAYER_TARGETS_FILE" ] || return

    read -r -p "Nomor gate yang ingin suspend/active: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -ge 1 ] || return

    local row status new_status gp
    row=$(awk -F':' -v n="$choice" 'NF{c++; if(c==n){print $0; exit}}' "$PLAYER_TARGETS_FILE")
    [ -n "$row" ] || return

    gp=$(echo "$row" | cut -d':' -f1)
    status=$(echo "$row" | cut -d':' -f6)
    if [ "$status" = "active" ]; then
        new_status="suspend"
    else
        new_status="active"
    fi

    awk -F':' -v n="$choice" -v ns="$new_status" 'BEGIN{OFS=":"}
        NF{
            c++
            if(c==n){$6=ns}
            print
        }' "$PLAYER_TARGETS_FILE" > "${PLAYER_TARGETS_FILE}.tmp"
    mv "${PLAYER_TARGETS_FILE}.tmp" "$PLAYER_TARGETS_FILE"

    if apply_nginx_config; then
        print_success "Status gate ${gp} menjadi ${new_status}."
    else
        print_error "Status tersimpan, tapi apply config gagal."
    fi
}

delete_player_gate() {
    list_player_gates
    [ -s "$PLAYER_TARGETS_FILE" ] || return

    read -r -p "Nomor gate yang ingin dihapus (0=batal): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -ge 1 ] || return

    local selected
    selected=$(awk -F':' -v n="$choice" 'NF{c++; if(c==n){print $0; exit}}' "$PLAYER_TARGETS_FILE")
    [ -n "$selected" ] || return

    awk -F':' -v n="$choice" 'NF{c++; if(c!=n) print $0}' "$PLAYER_TARGETS_FILE" > "${PLAYER_TARGETS_FILE}.tmp"
    mv "${PLAYER_TARGETS_FILE}.tmp" "$PLAYER_TARGETS_FILE"

    if apply_nginx_config; then
        print_success "Gate player dihapus: $selected"
    else
        print_error "Hapus tersimpan, tapi apply config gagal."
    fi
}

create_monitor_script() {
    cat <<'EOF' > "$MONITOR_SCRIPT"
#!/bin/bash

OWNER_TARGETS_FILE="/etc/nginx/gate_owner_targets.list"
PLAYER_TARGETS_FILE="/etc/nginx/gate_player_targets.list"
WEBHOOK_CONFIG_FILE="/etc/nginx/gate_webhook.conf"

[ -f "$WEBHOOK_CONFIG_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$WEBHOOK_CONFIG_FILE"
[ -n "$WEBHOOK_URL" ] || exit 0

nginx_state="DOWN"
nginx_test="FAIL"
if systemctl is-active --quiet nginx; then
    nginx_state="UP"
fi
if nginx -t >/dev/null 2>&1; then
    nginx_test="OK"
fi

total_owner=0
[ -f "$OWNER_TARGETS_FILE" ] && total_owner=$(grep -c '^[0-9]' "$OWNER_TARGETS_FILE" 2>/dev/null)

total_player=0
active_player=0
if [ -f "$PLAYER_TARGETS_FILE" ]; then
    total_player=$(grep -c '^[0-9]' "$PLAYER_TARGETS_FILE" 2>/dev/null)
    active_player=$(awk -F':' '$6=="active"{c++} END{print c+0}' "$PLAYER_TARGETS_FILE")
fi

listening_total=0
all_ports=$( {
    [ -f "$OWNER_TARGETS_FILE" ] && cut -d':' -f1 "$OWNER_TARGETS_FILE"
    [ -f "$PLAYER_TARGETS_FILE" ] && awk -F':' '$6=="active"{print $1}' "$PLAYER_TARGETS_FILE"
} | sort -n | uniq )

for p in $all_ports; do
    if ss -lntu | awk '{print $5}' | grep -E ":${p}$" >/dev/null 2>&1; then
        listening_total=$((listening_total + 1))
    fi
done

status_line="OK"
if [ "$nginx_state" != "UP" ] || [ "$nginx_test" != "OK" ]; then
    status_line="ALERT"
fi

now=$(date '+%Y-%m-%d %H:%M:%S')
msg="[$status_line] FiveM Gate Monitor\nTime: $now\nNginx: $nginx_state (config: $nginx_test)\nOwner gates: $total_owner\nPlayer gates: $active_player/$total_player active\nListening gates: $listening_total"

escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
escaped=$(printf '%s' "$escaped" | sed ':a;N;$!ba;s/\n/\\n/g')

curl -sS -m 10 -H "Content-Type: application/json" -d "{\"content\":\"$escaped\"}" "$WEBHOOK_URL" >/dev/null 2>&1
EOF

    chmod +x "$MONITOR_SCRIPT"
}

create_monitor_systemd_units() {
    cat <<EOF > "$MONITOR_SERVICE"
[Unit]
Description=FiveM Gate Monitor (Discord Webhook)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MONITOR_SCRIPT}
User=root

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > "$MONITOR_TIMER"
[Unit]
Description=Run FiveM Gate Monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=fivem-gate-monitor.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
}

set_discord_webhook() {
    read -r -p "Masukkan Discord Webhook URL: " hook
    if [[ -z "$hook" ]]; then
        print_error "Webhook URL tidak boleh kosong."
        return
    fi
    echo "WEBHOOK_URL=\"$hook\"" > "$WEBHOOK_CONFIG_FILE"
    print_success "Webhook URL tersimpan."
}

test_discord_webhook() {
    [ -f "$WEBHOOK_CONFIG_FILE" ] || { print_error "Webhook belum diset."; return; }
    # shellcheck disable=SC1090
    source "$WEBHOOK_CONFIG_FILE"
    [ -n "$WEBHOOK_URL" ] || { print_error "Webhook kosong."; return; }

    local msg esc
    msg="[TEST] FiveM Gate webhook aktif ($(date '+%Y-%m-%d %H:%M:%S'))"
    esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if curl -sS -m 10 -H "Content-Type: application/json" -d "{\"content\":\"$esc\"}" "$WEBHOOK_URL" >/dev/null 2>&1; then
        print_success "Pesan test terkirim ke Discord."
    else
        print_error "Gagal kirim test webhook."
    fi
}

enable_discord_monitor() {
    create_monitor_script
    create_monitor_systemd_units
    systemctl enable --now fivem-gate-monitor.timer >/dev/null 2>&1
    print_success "Monitor Discord aktif (interval 5 menit)."
}

disable_discord_monitor() {
    systemctl disable --now fivem-gate-monitor.timer >/dev/null 2>&1
    print_success "Monitor Discord dimatikan."
}

show_discord_monitor_status() {
    local timer_state svc_state
    timer_state=$(systemctl is-active fivem-gate-monitor.timer 2>/dev/null || true)
    svc_state=$(systemctl is-active fivem-gate-monitor.service 2>/dev/null || true)

    echo ""
    echo "--- Status Monitor Discord ---"
    echo "Timer : ${timer_state:-unknown}"
    echo "Service: ${svc_state:-unknown}"
    if [ -f "$WEBHOOK_CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$WEBHOOK_CONFIG_FILE"
        if [ -n "$WEBHOOK_URL" ]; then
            echo "Webhook: sudah diset"
        else
            echo "Webhook: belum diset"
        fi
    else
        echo "Webhook: belum diset"
    fi
    echo ""
}

count_owner_unique_ports() {
    cut -d':' -f1 "$OWNER_TARGETS_FILE" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | uniq | wc -l
}

count_player_active_ports() {
    awk -F':' '$6=="active"{print $1}' "$PLAYER_TARGETS_FILE" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | uniq | wc -l
}

show_dashboard() {
    local nginx_state owner_count player_active player_total timer_state
    nginx_state=$(systemctl is-active nginx 2>/dev/null || true)
    owner_count=$(count_owner_unique_ports)
    player_active=$(count_player_active_ports)
    player_total=$(grep -c '^[0-9]' "$PLAYER_TARGETS_FILE" 2>/dev/null)
    timer_state=$(systemctl is-active fivem-gate-monitor.timer 2>/dev/null || true)

    echo ""
    echo "=============================================="
    echo "          FIVEM GATEWAY DASHBOARD"
    echo "=============================================="
    echo "Nginx Status      : ${nginx_state:-unknown}"
    echo "Owner Gate Ports  : ${owner_count}"
    echo "Player Gates      : ${player_active}/${player_total} active"
    echo "Discord Monitor   : ${timer_state:-inactive}"
    echo "=============================================="
}

owner_menu() {
    while true; do
        echo ""
        echo "--- MODE OWNER SERVER ---"
        echo "1. Lihat Mapping"
        echo "2. Tambah Mapping"
        echo "3. Hapus Mapping"
        echo "4. Apply/Reload Nginx"
        echo "0. Kembali"
        read -r -p "Pilih: " c
        case "$c" in
            1) list_owner_targets ;;
            2) add_owner_target ;;
            3) delete_owner_target ;;
            4) apply_nginx_config ;;
            0) return ;;
            *) print_error "Pilihan tidak valid." ;;
        esac
    done
}

player_menu() {
    while true; do
        echo ""
        echo "--- MODE PLAYER LIMITED ---"
        echo "1. Lihat Gate"
        echo "2. Tambah Gate"
        echo "3. Ubah Limit"
        echo "4. Suspend/Active Gate"
        echo "5. Hapus Gate"
        echo "6. Apply/Reload Nginx"
        echo "0. Kembali"
        read -r -p "Pilih: " c
        case "$c" in
            1) list_player_gates ;;
            2) add_player_gate ;;
            3) edit_player_gate_limit ;;
            4) toggle_player_gate_status ;;
            5) delete_player_gate ;;
            6) apply_nginx_config ;;
            0) return ;;
            *) print_error "Pilihan tidak valid." ;;
        esac
    done
}

discord_menu() {
    while true; do
        echo ""
        echo "--- DISCORD MONITOR ---"
        echo "1. Set Webhook URL"
        echo "2. Test Webhook"
        echo "3. Enable Monitor 5 Menit"
        echo "4. Disable Monitor"
        echo "5. Status Monitor"
        echo "0. Kembali"
        read -r -p "Pilih: " c
        case "$c" in
            1) set_discord_webhook ;;
            2) test_discord_webhook ;;
            3) enable_discord_monitor ;;
            4) disable_discord_monitor ;;
            5) show_discord_monitor_status ;;
            0) return ;;
            *) print_error "Pilihan tidak valid." ;;
        esac
    done
}

main_menu() {
    while true; do
        show_dashboard
        echo ""
        echo "1. Setup Awal Nginx + Firewall"
        echo "2. Mode Owner Server"
        echo "3. Mode Player Limited"
        echo "4. Discord Monitor"
        echo "5. Apply/Reload Nginx"
        echo "0. Keluar"
        read -r -p "Pilih menu: " mc

        case "$mc" in
            1)
                install_nginx
                setup_firewall_basic
                cleanup_old_defaults
                apply_nginx_config
                ;;
            2) owner_menu ;;
            3) player_menu ;;
            4) discord_menu ;;
            5) apply_nginx_config ;;
            0) exit 0 ;;
            *) print_error "Pilihan tidak valid." ;;
        esac
    done
}

require_root
ensure_base_files
migrate_legacy_owner_targets
main_menu