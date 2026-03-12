#!/bin/bash

# ==============================================================================
# FIVEM PLAYER GATE MANAGER (PLAYER ONLY)
# - Random gate port auto-select in range 30000-39999
# - Port must be unused and not adjacent (+/-1) to existing ports
# - Discord webhook monitor every 5 minutes (systemd timer)
# ==============================================================================

GATE_RANGE_MIN=30000
GATE_RANGE_MAX=39999
MIN_PORT_GAP=25

PLAYER_TARGETS_FILE="/etc/nginx/gate_player_targets.list"
WEBHOOK_CONFIG_FILE="/etc/nginx/gate_webhook.conf"
STREAM_CONF_FILE="/etc/nginx/stream.conf"
NGINX_CONF_FILE="/etc/nginx/nginx.conf"
MONITOR_SCRIPT="/usr/local/bin/fivem_gate_monitor.sh"
MONITOR_SERVICE="/etc/systemd/system/fivem-gate-monitor.service"
MONITOR_TIMER="/etc/systemd/system/fivem-gate-monitor.timer"
MONITOR_STATE_DIR="/var/lib/fivem-gate"

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
    [ -d "$MONITOR_STATE_DIR" ] || mkdir -p "$MONITOR_STATE_DIR"
    [ -f "$PLAYER_TARGETS_FILE" ] || touch "$PLAYER_TARGETS_FILE"
    [ -f "$WEBHOOK_CONFIG_FILE" ] || echo "WEBHOOK_URL=" > "$WEBHOOK_CONFIG_FILE"
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_range_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$GATE_RANGE_MIN" ] && [ "$1" -le "$GATE_RANGE_MAX" ]
}

is_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r a b c d <<< "$1"
    for oct in "$a" "$b" "$c" "$d"; do
        [ "$oct" -ge 0 ] && [ "$oct" -le 255 ] || return 1
    done
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

get_used_gate_ports() {
    awk -F':' 'NF{print $1}' "$PLAYER_TARGETS_FILE" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | uniq
}

port_exists_in_player() {
    local p="$1"
    grep -E "^${p}:" "$PLAYER_TARGETS_FILE" >/dev/null 2>&1
}

is_too_close_to_existing() {
    local p="$1"
    local ep
    while IFS= read -r ep; do
        [ -n "$ep" ] || continue
        local diff=$((p - ep))
        [ "$diff" -lt 0 ] && diff=$((diff * -1))
        if [ "$diff" -lt "$MIN_PORT_GAP" ]; then
            return 0
        fi
    done < <(get_used_gate_ports)
    return 1
}

count_available_random_slots() {
    local c=0
    local p
    for p in $(seq "$GATE_RANGE_MIN" "$GATE_RANGE_MAX"); do
        if ! is_too_close_to_existing "$p"; then
            c=$((c + 1))
        fi
    done
    echo "$c"
}

pick_random_gate_port() {
    local p

    if command -v shuf >/dev/null 2>&1; then
        while IFS= read -r p; do
            if ! is_too_close_to_existing "$p"; then
                echo "$p"
                return 0
            fi
        done < <(seq "$GATE_RANGE_MIN" "$GATE_RANGE_MAX" | shuf)
    fi

    local tries=0
    while [ "$tries" -lt 20000 ]; do
        p=$((RANDOM % (GATE_RANGE_MAX - GATE_RANGE_MIN + 1) + GATE_RANGE_MIN))
        if ! is_too_close_to_existing "$p"; then
            echo "$p"
            return 0
        fi
        tries=$((tries + 1))
    done

    return 1
}

open_gate_ports_in_firewall() {
    local p
    while IFS=':' read -r p _; do
        [ -n "$p" ] || continue
        ufw allow "$p/tcp" >/dev/null 2>&1
        ufw allow "$p/udp" >/dev/null 2>&1
    done < "$PLAYER_TARGETS_FILE"
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

    # format: gate_port:target_ip:target_port:conn_limit:overflow:status:label
    local gp tip tport limit extra status label effective
    while IFS=':' read -r gp tip tport limit extra status label; do
        [ -n "$gp" ] || continue
        [ "$status" = "active" ] || continue

        is_valid_range_port "$gp" || continue
        is_valid_ipv4 "$tip" || continue
        is_valid_port "$tport" || continue
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        [[ "$extra" =~ ^[0-9]+$ ]] || continue

        effective=$((limit + extra))
        [ "$effective" -ge 1 ] || effective=1

        echo "    limit_conn_zone \$server_port zone=gate_conn_${gp}:1m;" >> "$STREAM_CONF_FILE"
        echo "    upstream player_backend_${gp} {" >> "$STREAM_CONF_FILE"
        echo "        server ${tip}:${tport};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${gp};" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass player_backend_${gp};" >> "$STREAM_CONF_FILE"
        echo "        limit_conn gate_conn_${gp} ${effective};" >> "$STREAM_CONF_FILE"
        echo "    }" >> "$STREAM_CONF_FILE"

        echo "    server {" >> "$STREAM_CONF_FILE"
        echo "        listen ${gp} udp reuseport;" >> "$STREAM_CONF_FILE"
        echo "        proxy_pass player_backend_${gp};" >> "$STREAM_CONF_FILE"
        echo "        limit_conn gate_conn_${gp} ${effective};" >> "$STREAM_CONF_FILE"
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

    print_error "Gagal restart Nginx."
    return 1
}

list_player_gates() {
    echo ""
    echo "--- PLAYER GATES (${GATE_RANGE_MIN}-${GATE_RANGE_MAX}) ---"
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

add_player_gate_auto() {
    echo ""
    print_info "Tambah gate player (PORT RANDOM AUTO)"
    read -r -p "Target Backend IP: " tip
    read -r -p "Target Backend Port (default 30120): " tport
    read -r -p "Limit dasar (default 2): " limit
    read -r -p "Overflow toleransi (default 3): " extra
    read -r -p "Label customer (default auto): " label

    tport=${tport:-30120}
    limit=${limit:-2}
    extra=${extra:-3}

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

    local free_count gp
    free_count=$(count_available_random_slots)
    if [ "$free_count" -le 0 ]; then
        print_error "Tidak ada port tersedia di range ${GATE_RANGE_MIN}-${GATE_RANGE_MAX} dengan jarak minimum ${MIN_PORT_GAP}."
        return
    fi

    gp=$(pick_random_gate_port)
    if [ -z "$gp" ]; then
        print_error "Gagal memilih port random."
        return
    fi

    label=${label:-gate_$gp}
    echo "${gp}:${tip}:${tport}:${limit}:${extra}:active:${label}" >> "$PLAYER_TARGETS_FILE"

    if apply_nginx_config; then
        print_success "Gate dibuat: ${gp} -> ${tip}:${tport} (limit ${limit}+${extra})"
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

    local row gp limit extra nlimit nextra
    row=$(awk -F':' -v n="$choice" 'NF{c++; if(c==n){print $0; exit}}' "$PLAYER_TARGETS_FILE")
    [ -n "$row" ] || return

    gp=$(echo "$row" | cut -d':' -f1)
    limit=$(echo "$row" | cut -d':' -f4)
    extra=$(echo "$row" | cut -d':' -f5)

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
        print_success "Gate dihapus: $selected"
    else
        print_error "Hapus tersimpan, tapi apply config gagal."
    fi
}

create_monitor_script() {
    cat <<'EOF' > "$MONITOR_SCRIPT"
#!/bin/bash

PLAYER_TARGETS_FILE="/etc/nginx/gate_player_targets.list"
WEBHOOK_CONFIG_FILE="/etc/nginx/gate_webhook.conf"
STATE_DIR="/var/lib/fivem-gate"
STATE_FILE="${STATE_DIR}/monitor.state"

mkdir -p "$STATE_DIR"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

get_cpu_usage_percent() {
    local c1 c2 idle1 idle2 total1 total2 idle_delta total_delta
    c1=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
    sleep 1
    c2=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)

    read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 <<< "$c1"
    read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 <<< "$c2"

    total1=$((u1+n1+s1+i1+w1+irq1+sirq1+st1))
    total2=$((u2+n2+s2+i2+w2+irq2+sirq2+st2))
    idle1=$((i1+w1))
    idle2=$((i2+w2))

    total_delta=$((total2-total1))
    idle_delta=$((idle2-idle1))
    if [ "$total_delta" -le 0 ]; then
        echo "0.00"
        return
    fi

    awk -v t="$total_delta" -v i="$idle_delta" 'BEGIN { printf "%.2f", ((t-i)*100)/t }'
}

get_ram_usage() {
    local total used pct
    total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
    used=$((total - available))
    if [ "$total" -le 0 ]; then
        echo "0.00|0|0"
        return
    fi
    pct=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.2f", (u*100)/t }')
    echo "${pct}|$((used/1024))|$((total/1024))"
}

detect_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{
        for(i=1;i<=NF;i++){
            if($i=="dev"){print $(i+1); exit}
        }
    }'
}

estimate_connected_players() {
    local ports_csv="$1"
    if [ -z "$ports_csv" ]; then
        echo "0"
        return
    fi

    ss -H -ntu 2>/dev/null | awk -v ports="$ports_csv" '
        BEGIN {
            split(ports, p, ",");
            for (i in p) allow[p[i]] = 1;
        }
        {
            local = $5;
            peer = $6;
            lp = local;
            sub(/^.*:/, "", lp);
            if (allow[lp]) {
                host = peer;
                sub(/:[^:]*$/, "", host);
                gsub(/^\[/, "", host);
                gsub(/\]$/, "", host);
                if (host != "" && host != "*" && host != "127.0.0.1") seen[host] = 1;
            }
        }
        END {
            c = 0;
            for (h in seen) c++;
            print c + 0;
        }'
}

calc_5m_bandwidth() {
    local iface="$1"
    local now rx_now tx_now prev_ts prev_rx prev_tx prev_iface dt drx dtx
    now=$(date +%s)

    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        echo "N/A|N/A|N/A|N/A|N/A"
        return
    fi

    rx_now=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null)
    tx_now=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null)
    [ -n "$rx_now" ] || rx_now=0
    [ -n "$tx_now" ] || tx_now=0

    prev_ts=0
    prev_rx=0
    prev_tx=0
    prev_iface=""
    if [ -f "$STATE_FILE" ]; then
        IFS='|' read -r prev_ts prev_rx prev_tx prev_iface < "$STATE_FILE"
    fi

    echo "${now}|${rx_now}|${tx_now}|${iface}" > "$STATE_FILE"

    if [ "$prev_ts" -le 0 ] || [ "$prev_iface" != "$iface" ]; then
        echo "0 B|0 B|N/A|N/A|N/A"
        return
    fi

    dt=$((now - prev_ts))
    [ "$dt" -gt 0 ] || dt=300
    drx=$((rx_now - prev_rx))
    dtx=$((tx_now - prev_tx))
    [ "$drx" -ge 0 ] || drx=0
    [ "$dtx" -ge 0 ] || dtx=0

    rx_h=$(awk -v b="$drx" 'BEGIN{
        if (b < 1024) printf "%d B", b;
        else if (b < 1048576) printf "%.2f KB", b/1024;
        else if (b < 1073741824) printf "%.2f MB", b/1048576;
        else printf "%.2f GB", b/1073741824;
    }')
    tx_h=$(awk -v b="$dtx" 'BEGIN{
        if (b < 1024) printf "%d B", b;
        else if (b < 1048576) printf "%.2f KB", b/1024;
        else if (b < 1073741824) printf "%.2f MB", b/1048576;
        else printf "%.2f GB", b/1073741824;
    }')

    rx_mbps=$(awk -v b="$drx" -v s="$dt" 'BEGIN { if(s<=0){print "0.00"} else printf "%.2f", (b*8)/(s*1000000) }')
    tx_mbps=$(awk -v b="$dtx" -v s="$dt" 'BEGIN { if(s<=0){print "0.00"} else printf "%.2f", (b*8)/(s*1000000) }')
    window="${dt}s"

    echo "${rx_h}|${tx_h}|${rx_mbps}|${tx_mbps}|${window}"
}

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

total_player=0
active_player=0
if [ -f "$PLAYER_TARGETS_FILE" ]; then
    total_player=$(grep -c '^[0-9]' "$PLAYER_TARGETS_FILE" 2>/dev/null)
    active_player=$(awk -F':' '$6=="active"{c++} END{print c+0}' "$PLAYER_TARGETS_FILE")
fi

listening_total=0
all_ports=$(awk -F':' '$6=="active"{print $1}' "$PLAYER_TARGETS_FILE" 2>/dev/null | sort -n | uniq)
ports_csv=$(echo "$all_ports" | tr '\n' ',' | sed 's/,$//')
for p in $all_ports; do
    if ss -lntu | awk '{print $5}' | grep -E ":${p}$" >/dev/null 2>&1; then
        listening_total=$((listening_total + 1))
    fi
done

estimated_players=$(estimate_connected_players "$ports_csv")
cpu_pct=$(get_cpu_usage_percent)
ram_data=$(get_ram_usage)
ram_pct=$(echo "$ram_data" | cut -d'|' -f1)
ram_used_mb=$(echo "$ram_data" | cut -d'|' -f2)
ram_total_mb=$(echo "$ram_data" | cut -d'|' -f3)

iface=$(detect_iface)
bw_data=$(calc_5m_bandwidth "$iface")
rx_5m=$(echo "$bw_data" | cut -d'|' -f1)
tx_5m=$(echo "$bw_data" | cut -d'|' -f2)
rx_rate=$(echo "$bw_data" | cut -d'|' -f3)
tx_rate=$(echo "$bw_data" | cut -d'|' -f4)
sample_window=$(echo "$bw_data" | cut -d'|' -f5)

status_line="OK"
if [ "$nginx_state" != "UP" ] || [ "$nginx_test" != "OK" ]; then
    status_line="ALERT"
fi

if [ "$status_line" = "OK" ]; then
    color=5763719
else
    color=15548997
fi

now_local=$(date '+%Y-%m-%d %H:%M:%S')
now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

f_status=$(json_escape "Nginx: ${nginx_state} | Config: ${nginx_test}")
f_gates=$(json_escape "Active: ${active_player}/${total_player} | Listening: ${listening_total}")
f_players=$(json_escape "Estimated unique source IP: ${estimated_players}")
f_cpu=$(json_escape "${cpu_pct}%")
f_ram=$(json_escape "${ram_pct}% (${ram_used_mb}MB/${ram_total_mb}MB)")
f_bw=$(json_escape "IN ${rx_5m} (${rx_rate} Mbps avg) | OUT ${tx_5m} (${tx_rate} Mbps avg)")
f_iface=$(json_escape "${iface:-N/A} | Window: ${sample_window}")
f_time=$(json_escape "${now_local}")

payload=$(cat <<JSON
{
  "username": "FiveM Gate Monitor",
  "embeds": [
    {
      "title": "FiveM Player Gate Report",
      "color": ${color},
      "fields": [
        {"name": "Status", "value": "${f_status}", "inline": true},
        {"name": "Gate", "value": "${f_gates}", "inline": true},
        {"name": "Player (Estimate)", "value": "${f_players}", "inline": false},
        {"name": "CPU", "value": "${f_cpu}", "inline": true},
        {"name": "RAM", "value": "${f_ram}", "inline": true},
        {"name": "Bandwidth 5m", "value": "${f_bw}", "inline": false},
        {"name": "Network", "value": "${f_iface}", "inline": true},
        {"name": "Time", "value": "${f_time}", "inline": true}
      ],
      "footer": {"text": "Auto report every 5 minutes"},
      "timestamp": "${now_iso}"
    }
  ]
}
JSON
)

curl -sS -m 15 -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1
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

    local now_local now_iso payload
    now_local=$(date '+%Y-%m-%d %H:%M:%S')
    now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    payload=$(cat <<JSON
{
  "username": "FiveM Gate Monitor",
  "embeds": [
    {
      "title": "Webhook Test",
      "description": "Webhook aktif dan siap menerima report monitor.",
      "color": 3447003,
      "fields": [
        {"name": "Status", "value": "OK", "inline": true},
        {"name": "Time", "value": "${now_local}", "inline": true}
      ],
      "timestamp": "${now_iso}"
    }
  ]
}
JSON
)

    if curl -sS -m 10 -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1; then
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

send_monitor_report_now() {
    create_monitor_script
    if "$MONITOR_SCRIPT"; then
        print_success "Report monitor berhasil dikirim."
    else
        print_error "Gagal mengirim report monitor."
    fi
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

count_player_active_ports() {
    awk -F':' '$6=="active"{print $1}' "$PLAYER_TARGETS_FILE" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | uniq | wc -l
}

show_dashboard() {
    local nginx_state active total timer_state slots
    nginx_state=$(systemctl is-active nginx 2>/dev/null || true)
    active=$(count_player_active_ports)
    total=$(grep -c '^[0-9]' "$PLAYER_TARGETS_FILE" 2>/dev/null)
    timer_state=$(systemctl is-active fivem-gate-monitor.timer 2>/dev/null || true)
    slots=$(count_available_random_slots)

    echo ""
    echo "=============================================="
    echo "        FIVEM PLAYER GATE DASHBOARD"
    echo "=============================================="
    echo "Nginx Status         : ${nginx_state:-unknown}"
    echo "Player Gates         : ${active}/${total} active"
    echo "Discord Monitor      : ${timer_state:-inactive}"
    echo "Range Gate           : ${GATE_RANGE_MIN}-${GATE_RANGE_MAX}"
    echo "Sisa Slot Acak Valid : ${slots}"
    echo "Rule Jarak Port      : minimal jarak ${MIN_PORT_GAP} antar gate"
    echo "=============================================="
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
        echo "6. Kirim Report Sekarang"
        echo "0. Kembali"
        read -r -p "Pilih: " c
        case "$c" in
            1) set_discord_webhook ;;
            2) test_discord_webhook ;;
            3) enable_discord_monitor ;;
            4) disable_discord_monitor ;;
            5) show_discord_monitor_status ;;
            6) send_monitor_report_now ;;
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
        echo "2. Lihat Gate Player"
        echo "3. Tambah Gate Player (AUTO RANDOM)"
        echo "4. Ubah Limit Gate"
        echo "5. Suspend/Active Gate"
        echo "6. Hapus Gate"
        echo "7. Discord Monitor"
        echo "8. Apply/Reload Nginx"
        echo "0. Keluar"
        read -r -p "Pilih menu: " mc

        case "$mc" in
            1)
                install_nginx
                setup_firewall_basic
                cleanup_old_defaults
                apply_nginx_config
                ;;
            2) list_player_gates ;;
            3) add_player_gate_auto ;;
            4) edit_player_gate_limit ;;
            5) toggle_player_gate_status ;;
            6) delete_player_gate ;;
            7) discord_menu ;;
            8) apply_nginx_config ;;
            0) exit 0 ;;
            *) print_error "Pilihan tidak valid." ;;
        esac
    done
}

require_root
ensure_base_files
main_menu
