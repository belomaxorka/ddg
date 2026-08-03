#!/usr/bin/env bash
#
# node-setup.sh — развёртывание masquerade-ноды с нуля.
#
#   ./node-setup.sh -d cdn2.pandaonline.org
#   ./node-setup.sh -d example.org -r 2000mbit
#   ./node-setup.sh -d example.org -r 700mbit -p /stream/119857666/voice
#
# Что делает:
#   1. сносит caddy, если он есть
#   2. ставит nginx
#   3. применяет сетевые оптимизации ядра (sysctl, limits, BBR)
#   4. выпускает самоподписанный сертификат
#   5. раскатывает vhost с WebSocket-проксированием на xray
#   6. ставит шейпер исходящей полосы + systemd-юнит
#
# Повторный запуск безопасен: всё перезаписывается идемпотентно.
#
set -euo pipefail

# ── значения по умолчанию ────────────────────────────────────────────────────
DOMAIN=""
RATE="900mbit"
WS_PATH=""                       # пусто = сгенерировать или взять сохранённый
UPSTREAM="127.0.0.1:11443"
IFACE=""
SKIP_SHAPE=0
REGEN_PATH=0
STATE_FILE="/etc/nginx/.node-ws-path"
# ─────────────────────────────────────────────────────────────────────────────

# ── шаблоны WS-путей ─────────────────────────────────────────────────────────
# {id}   — 9 цифр       {hex} — 12 hex-символов
# {node} — имя узла     {ver} — номер версии
PATH_TEMPLATES=(
    "/stream/{id}/voice"
    "/stream/{id}/video"
    "/stream/video/hls"
    "/stream/video/ffmpeg"
    "/stream/audio/opus"
    "/live/{id}/segment"
    "/live/edge/{hex}"
    "/live/{node}/relay"
    "/hls/{id}/index"
    "/hls/{node}/master"
    "/dash/{id}/manifest"
    "/vod/{id}/playlist"
    "/media/{id}/audio"
    "/media/chunks/{hex}"
    "/cdn/assets/{hex}"
    "/cdn/v{ver}/segment/{id}"
    "/api/v{ver}/stream/{id}"
    "/api/v{ver}/media/{node}"
    "/ws/notify/{id}"
    "/ws/events/{hex}"
    "/rtc/session/{id}"
    "/rtc/{node}/peer"
    "/sock/relay/{hex}"
    "/edge/{node}/push"
    "/pull/{id}/track"
    "/mux/{hex}/out"
    "/ingest/{id}/rtmp"
    "/transcode/{node}/job"
    "/thumb/{hex}/preview"
    "/segment/{id}/init"
    "/chunk/{hex}/data"
    "/player/{node}/src"
    "/origin/{id}/fetch"
    "/cache/{hex}/warm"
)

NODE_WORDS=(edge origin relay node cache pop gw front mid core)

# генераторы не зависят от openssl/shuf — скрипт может звать их до apt install
_rand_hex() {
    if [[ -r /dev/urandom ]]; then
        printf '%s' "$(od -An -tx1 -N"${1:-6}" /dev/urandom | tr -d ' \n')"
    else
        printf '%012x' $((RANDOM * RANDOM * RANDOM))
    fi
}
_rand_int() { echo $(( $1 + (RANDOM * 32768 + RANDOM) % ($2 - $1 + 1) )); }

gen_ws_path() {
    local tpl id hex node ver
    tpl="${PATH_TEMPLATES[$((RANDOM % ${#PATH_TEMPLATES[@]}))]}"
    id="$(_rand_int 100000000 999999999)"
    hex="$(_rand_hex 6)"
    node="${NODE_WORDS[$((RANDOM % ${#NODE_WORDS[@]}))]}$(_rand_int 1 9)"
    ver="$(_rand_int 1 3)"
    tpl="${tpl//\{id\}/$id}"
    tpl="${tpl//\{hex\}/$hex}"
    tpl="${tpl//\{node\}/$node}"
    tpl="${tpl//\{ver\}/$ver}"
    printf '%s' "$tpl"
}
# ─────────────────────────────────────────────────────────────────────────────

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
step() { echo -e "\n${C_OK}==>${C_OFF} $*"; }
info() { echo -e "    ${C_DIM}$*${C_OFF}"; }
warn() { echo -e "    ${C_WARN}!${C_OFF} $*"; }
die()  { echo -e "\n${C_ERR}ошибка:${C_OFF} $*" >&2; exit 1; }

usage() {
    cat <<EOF
использование: $0 -d ДОМЕН [опции]

  -d ДОМЕН      домен ноды (обязательно)
  -r ПОЛОСА     лимит исходящей полосы, по умолчанию $RATE
                  примеры: 400mbit, 900mbit, 2000mbit, off
  -p ПУТЬ       WebSocket-путь задать вручную
                  по умолчанию генерируется случайный и сохраняется,
                  при повторном запуске переиспользуется тот же
  -R            перегенерировать путь (туннель придётся перенастроить!)
  -u АДРЕС      upstream xray, по умолчанию $UPSTREAM
  -i ИНТЕРФЕЙС  интерфейс для шейпера, по умолчанию определяется сам
  -h            эта справка

примеры сгенерированных путей:
  /hls/edge3/master        /live/847362915/segment
  /cdn/assets/a3f9c1e07b42 /api/v2/stream/512048873
EOF
    exit 0
}

while getopts "d:r:p:u:i:Rh" opt; do
    case "$opt" in
        d) DOMAIN="$OPTARG" ;;
        r) RATE="$OPTARG" ;;
        p) WS_PATH="$OPTARG" ;;
        u) UPSTREAM="$OPTARG" ;;
        i) IFACE="$OPTARG" ;;
        R) REGEN_PATH=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ $EUID -eq 0 ]] || die "нужны права root"

# ── определение платформы ────────────────────────────────────────────────────
OS_ID=""; OS_LIKE=""
[[ -r /etc/os-release ]] && . /etc/os-release && OS_ID="${ID:-}" && OS_LIKE="${ID_LIKE:-}"

if command -v apt-get >/dev/null; then
    PKG=apt
elif command -v dnf >/dev/null; then
    PKG=dnf
elif command -v yum >/dev/null; then
    PKG=yum
else
    die "не найден поддерживаемый пакетный менеджер (apt/dnf/yum)"
fi

command -v systemctl >/dev/null || die "нужен systemd"

IS_CONTAINER=0
if command -v systemd-detect-virt >/dev/null && systemd-detect-virt -c -q 2>/dev/null; then
    IS_CONTAINER=1
fi

pkg_install() {
    case "$PKG" in
        apt) apt-get install -y -qq "$@" >/dev/null ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
    esac
}
pkg_remove() {
    case "$PKG" in
        apt) apt-get purge -y "$@" >/dev/null 2>&1 || true ;;
        dnf) dnf remove -y -q "$@" >/dev/null 2>&1 || true ;;
        yum) yum remove -y -q "$@" >/dev/null 2>&1 || true ;;
    esac
}
pkg_refresh() {
    case "$PKG" in
        apt) apt-get update -qq ;;
        *)   : ;;
    esac
}
[[ -n "$DOMAIN" ]] || die "не указан домен (-d), см. $0 -h"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "некорректный домен: $DOMAIN"
[[ "$RATE" == "off" ]] && SKIP_SHAPE=1

# ── выбор WS-пути ────────────────────────────────────────────────────────────
# приоритет: явный -p  >  -R (новый)  >  сохранённый  >  новый
PATH_SOURCE=""
if [[ -n "$WS_PATH" ]]; then
    PATH_SOURCE="задан вручную"
elif [[ $REGEN_PATH -eq 1 ]]; then
    WS_PATH="$(gen_ws_path)"; PATH_SOURCE="перегенерирован"
elif [[ -s "$STATE_FILE" ]]; then
    WS_PATH="$(cat "$STATE_FILE")"; PATH_SOURCE="взят сохранённый"
else
    WS_PATH="$(gen_ws_path)"; PATH_SOURCE="сгенерирован"
fi
[[ "$WS_PATH" == /* ]] || die "путь должен начинаться со слэша: $WS_PATH"

export DEBIAN_FRONTEND=noninteractive

echo
echo "  домен:     $DOMAIN"
echo "  ws-путь:   $WS_PATH  ${C_DIM}($PATH_SOURCE)${C_OFF}"
echo "  upstream:  $UPSTREAM"
echo "  шейпер:    $([[ $SKIP_SHAPE -eq 1 ]] && echo "выключен" || echo "$RATE")"


# ─── 1. снос caddy ───────────────────────────────────────────────────────────
step "Проверяю caddy"

if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service' || command -v caddy >/dev/null; then
    warn "caddy найден, удаляю"
    systemctl disable --now caddy 2>/dev/null || true
    pkg_remove caddy
    # caddy часто ставят бинарником мимо пакетов
    rm -f /usr/bin/caddy /usr/local/bin/caddy
    rm -f /etc/systemd/system/caddy.service /lib/systemd/system/caddy.service
    rm -rf /etc/caddy /var/lib/caddy
    rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/yum.repos.d/caddy*.repo
    systemctl daemon-reload
    info "caddy удалён"
else
    info "caddy не установлен, пропускаю"
fi


# ─── 2. установка nginx ──────────────────────────────────────────────────────
step "Устанавливаю nginx"

pkg_refresh
pkg_install nginx openssl iproute2 ca-certificates

command -v nginx >/dev/null || die "nginx не установился"

# ── версия: http2 как отдельная директива только с 1.25.1 ──
NGINX_VER="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
[[ -n "$NGINX_VER" ]] || NGINX_VER="0.0.0"
ver_ge() {  # ver_ge A B  → истина, если A >= B
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}
if ver_ge "$NGINX_VER" "1.25.1"; then
    HTTP2_MODE="directive"      # http2 on;
else
    HTTP2_MODE="listen"         # listen 443 ssl http2;
fi

# ── пользователь: www-data в Debian, nginx в RHEL ──
if id -u www-data >/dev/null 2>&1; then
    NGINX_USER="www-data"
elif id -u nginx >/dev/null 2>&1; then
    NGINX_USER="nginx"
else
    NGINX_USER="nobody"
    warn "не найден ни www-data, ни nginx — ставлю user nobody"
fi

# ── раскладка: sites-enabled есть не везде ──
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
rm -f /etc/nginx/conf.d/default.conf   # RHEL кладёт свой server на :80

info "nginx $NGINX_VER | user $NGINX_USER | http2: $HTTP2_MODE"


# ─── 3. профилирование ноды ──────────────────────────────────────────────────
step "Определяю характеристики ноды"

CORES="$(nproc)"
RAM_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"

[[ -n "$IFACE" ]] || IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[[ -n "$IFACE" ]] || die "не удалось определить интерфейс, задайте -i"
ip link show "$IFACE" >/dev/null 2>&1 || die "интерфейс $IFACE не найден"

NIC_SPEED="$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null || echo "")"
[[ "$NIC_SPEED" =~ ^[0-9]+$ ]] || NIC_SPEED=""

# планируемая полоса = меньшее из лимита шейпера и скорости карты
RATE_MBIT="${RATE%mbit}"
[[ "$RATE_MBIT" =~ ^[0-9]+$ ]] || RATE_MBIT=1000
PLAN_MBIT="$RATE_MBIT"
if [[ -n "$NIC_SPEED" ]] && (( NIC_SPEED > 0 && NIC_SPEED < PLAN_MBIT )); then
    PLAN_MBIT="$NIC_SPEED"
    warn "карта отдаёт ${NIC_SPEED}Mbit — лимит $RATE недостижим физически"
fi

clamp() { local v=$1 lo=$2 hi=$3; (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; echo "$v"; }

# ── буферы TCP: BDP при RTT 200 мс, с потолком по объёму памяти ──
BDP=$(( PLAN_MBIT * 1000000 / 8 / 5 ))
if   (( RAM_MB < 2048 )); then BUF_CAP=$((  8 * 1024 * 1024 )); TIER="малая"
elif (( RAM_MB < 8192 )); then BUF_CAP=$(( 16 * 1024 * 1024 )); TIER="средняя"
else                           BUF_CAP=$(( 32 * 1024 * 1024 )); TIER="крупная"
fi
BUF="$(clamp "$BDP" $((4*1024*1024)) "$BUF_CAP")"

# ── соединения: от объёма памяти, ~64 сокета на мегабайт ──
TOTAL_CONNS="$(clamp $(( RAM_MB * 64 )) 16384 524288)"
WORKER_CONNS="$(clamp $(( TOTAL_CONNS / CORES )) 4096 131072)"
RLIMIT_NOFILE="$(clamp $(( TOTAL_CONNS * 3 )) 65536 2000000)"
FILE_MAX=$(( RLIMIT_NOFILE * 2 ))

# ── conntrack: ~256 записей на мегабайт памяти ──
CONNTRACK="$(clamp $(( RAM_MB * 256 )) 65536 1048576)"

# fs.nr_open — жёсткий потолок для LimitNOFILE; понижать его опасно,
# другие юниты могут не стартовать. Только повышаем.
NR_OPEN_CUR="$(sysctl -n fs.nr_open 2>/dev/null || echo 1048576)"
NR_OPEN="$NR_OPEN_CUR"
(( RLIMIT_NOFILE > NR_OPEN )) && NR_OPEN="$RLIMIT_NOFILE"

# ── очереди: от планируемой полосы ──
if   (( PLAN_MBIT >= 1000 )); then BACKLOG=65535; TXQLEN=10000
elif (( PLAN_MBIT >=  500 )); then BACKLOG=32768; TXQLEN=5000
else                               BACKLOG=16384; TXQLEN=2000
fi
SOMAXCONN="$(clamp $(( TOTAL_CONNS / 8 )) 4096 65535)"

info "система: ${OS_ID:-unknown}${OS_LIKE:+ (${OS_LIKE})} | пакеты: $PKG${IS_CONTAINER:+ | контейнер: $IS_CONTAINER}"
info "ядер: $CORES | память: ${RAM_MB}MB ($TIER) | интерфейс: $IFACE${NIC_SPEED:+ (${NIC_SPEED}Mbit)}"
info "планируемая полоса: ${PLAN_MBIT}Mbit → буфер TCP $(( BUF / 1024 / 1024 ))MB"
info "соединений: $TOTAL_CONNS всего, $WORKER_CONNS на воркер, nofile $RLIMIT_NOFILE"
info "conntrack: $CONNTRACK | backlog: $BACKLOG | somaxconn: $SOMAXCONN"


# ─── 4. оптимизации ядра ─────────────────────────────────────────────────────
step "Применяю сетевые оптимизации"

modprobe tcp_bbr 2>/dev/null || true
grep -qx tcp_bbr /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf

# conntrack-модуль нужен, иначе sysctl по нему молча не применится.
# В LXC/OpenVZ его подгрузить нельзя — тогда просто не пишем эти ключи.
HAS_CONNTRACK=0
modprobe nf_conntrack 2>/dev/null || true
if [[ -d /proc/sys/net/netfilter ]]; then
    HAS_CONNTRACK=1
    echo "options nf_conntrack hashsize=$(( CONNTRACK / 4 ))" > /etc/modprobe.d/nf_conntrack.conf
    # если модуль уже загружен, modprobe.d не подействует — правим на живую
    [[ -w /sys/module/nf_conntrack/parameters/hashsize ]] \
        && echo $(( CONNTRACK / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
else
    warn "conntrack недоступен (контейнер?) — соответствующие лимиты пропускаю"
fi

cat > /etc/sysctl.d/99-max-limits.conf <<EOF
# ============================================================
#  сгенерировано node-setup.sh под эту ноду
#  ${CORES} ядер, ${RAM_MB}MB RAM, полоса ${PLAN_MBIT}Mbit
#  править вручную смысла нет — перезапишется при следующем прогоне
# ============================================================

# --- Файловые лимиты ядра ---
fs.file-max = $FILE_MAX
fs.inotify.max_user_watches = 524288
fs.nr_open = $NR_OPEN

# --- Сетевые очереди ---
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SOMAXCONN

# --- Буферы: BDP для ${PLAN_MBIT}Mbit при RTT 200мс ---
net.core.rmem_max = $BUF
net.core.wmem_max = $BUF
net.ipv4.tcp_rmem = 4096 87380 $BUF
net.ipv4.tcp_wmem = 4096 65536 $BUF

# не копить в сокете больше 16КБ неотправленного — меньше задержка под BBR
net.ipv4.tcp_notsent_lowat = 16384

# --- Порты и соединения ---
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# туннель через CDN режет MTU — без probing получим чёрные дыры PMTU
net.ipv4.tcp_mtu_probing = 1

# --- Keepalive: рвать мёртвые сессии за ~2 минуты ---
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

$( [[ $HAS_CONNTRACK -eq 1 ]] && cat <<CONNTRACK_BLOCK
# --- Conntrack ---
net.netfilter.nf_conntrack_max = $CONNTRACK
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
CONNTRACK_BLOCK
)

# --- Прочее ---
net.core.busy_poll = 0
vm.swappiness = 10

# --- BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

if [[ $IS_CONTAINER -eq 1 ]]; then
    warn "нода в контейнере — часть sysctl доступна только на чтение"
fi
sysctl --system >/dev/null 2>&1 || true

ip link set dev "$IFACE" txqueuelen "$TXQLEN" 2>/dev/null \
    || warn "не удалось выставить txqueuelen на $IFACE"

CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
if [[ "$CC" == "bbr" ]]; then
    info "congestion control: bbr"
else
    warn "congestion control: $CC — bbr не включился, проверьте ядро"
fi

cat > /etc/security/limits.d/99-nofile.conf <<EOF
*    soft nofile $RLIMIT_NOFILE
*    hard nofile $RLIMIT_NOFILE
root soft nofile $RLIMIT_NOFILE
root hard nofile $RLIMIT_NOFILE
*    soft nproc  63000
*    hard nproc  63000
root soft nproc  63000
root hard nproc  63000
EOF

# limits.conf читает PAM при логине и НЕ действует на systemd-сервисы,
# поэтому лимит nginx приходится задавать отдельно через override
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf <<EOF
[Service]
LimitNOFILE=$RLIMIT_NOFILE
LimitNPROC=63000
EOF
systemctl daemon-reload
info "лимиты применены (nofile $RLIMIT_NOFILE, включая systemd-override)"


# ─── 5. конфиг nginx ─────────────────────────────────────────────────────────
step "Настраиваю nginx"

[[ -f /etc/nginx/nginx.conf.orig ]] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig

cat > /etc/nginx/nginx.conf <<EOF
user $NGINX_USER;
worker_processes auto;
worker_rlimit_nofile $RLIMIT_NOFILE;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections $WORKER_CONNS;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    keepalive_timeout 300s;
    keepalive_requests 10000;

    access_log off;
    error_log /var/log/nginx/error.log crit;

    # бинарный WS-поток жать бессмысленно, только жжём CPU
    gzip off;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF


# ─── 6. сертификат ───────────────────────────────────────────────────────────
step "Выпускаю самоподписанный сертификат"

mkdir -p /etc/nginx/ssl
if [[ -f /etc/nginx/ssl/selfsigned.crt ]] \
   && openssl x509 -in /etc/nginx/ssl/selfsigned.crt -noout -checkend 2592000 >/dev/null 2>&1 \
   && openssl x509 -in /etc/nginx/ssl/selfsigned.crt -noout -subject 2>/dev/null | grep -q "CN *= *$DOMAIN"; then
    info "действующий сертификат для $DOMAIN уже есть, пропускаю"
else
    # -addext появился в OpenSSL 1.1.1; на старых собираем через конфиг
    if ! openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/selfsigned.key \
            -out    /etc/nginx/ssl/selfsigned.crt \
            -days 3650 -subj "/CN=$DOMAIN" \
            -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1; then
        warn "openssl без -addext, выпускаю через временный конфиг"
        TMPCNF="$(mktemp)"
        cat > "$TMPCNF" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $DOMAIN
[ext]
subjectAltName = DNS:$DOMAIN
CNF
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/selfsigned.key \
            -out    /etc/nginx/ssl/selfsigned.crt \
            -days 3650 -config "$TMPCNF" >/dev/null 2>&1 \
            || die "не удалось выпустить сертификат"
        rm -f "$TMPCNF"
    fi
    [[ -s /etc/nginx/ssl/selfsigned.crt ]] || die "сертификат не создан"
    chmod 600 /etc/nginx/ssl/selfsigned.key
    info "сертификат выпущен на 10 лет, CN=$DOMAIN"
fi


# ─── 7. заглушка ─────────────────────────────────────────────────────────────
step "Готовлю заглушку"

mkdir -p /var/www/stub
if [[ ! -f /var/www/stub/index.html ]]; then
    cat > /var/www/stub/index.html <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>$DOMAIN</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:20vh auto;padding:0 1rem;color:#333}</style>
</head><body><h1>$DOMAIN</h1><p>Content delivery node.</p></body></html>
EOF
    info "создана /var/www/stub/index.html"
else
    info "заглушка уже есть, не трогаю"
fi
chown -R "$NGINX_USER:$NGINX_USER" /var/www/stub 2>/dev/null || true


# ─── 8. vhost ────────────────────────────────────────────────────────────────
step "Раскатываю vhost"

rm -f /etc/nginx/sites-enabled/default

# запомнить путь, чтобы повторный запуск не сломал уже работающий туннель
printf '%s' "$WS_PATH" > "$STATE_FILE"
chmod 600 "$STATE_FILE"

# директива http2 существует только с nginx 1.25.1; до неё — флаг в listen
if [[ "$HTTP2_MODE" == "directive" ]]; then
    LISTEN_443="listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;"
else
    LISTEN_443="listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;"
fi

cat > /etc/nginx/sites-available/node.conf <<EOF
upstream xray_ws {
    server $UPSTREAM;
    keepalive 512;
}

# Connection ставим только на реальный WS-апгрейд, а не на все запросы.
# map живёт в http-контексте; файл включается внутрь http{} — это корректно.
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;

    root /var/www/stub;
    index index.html;

    location ^~ $WS_PATH {
        proxy_pass http://xray_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_connect_timeout 30s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        access_log off;
    }

    location = / {
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    $LISTEN_443
    server_name $DOMAIN;

    root /var/www/stub;
    index index.html;

    ssl_certificate     /etc/nginx/ssl/selfsigned.crt;
    ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

    location ^~ $WS_PATH {
        proxy_pass http://xray_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_connect_timeout 30s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        access_log off;
    }

    location = / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf /etc/nginx/sites-available/node.conf /etc/nginx/sites-enabled/node.conf

# SELinux на RHEL-семействе иначе запретит nginx подключаться к upstream
if command -v getenforce >/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null \
        && info "SELinux: разрешён исходящий коннект для nginx" \
        || warn "SELinux активен, но setsebool не отработал — проверьте вручную"
fi

nginx -t 2>&1 | sed 's/^/    /' || die "конфиг nginx не проходит проверку, см. вывод выше"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
info "nginx перезапущен"


# ─── 9. шейпер ───────────────────────────────────────────────────────────────
if [[ $SKIP_SHAPE -eq 1 ]]; then
    step "Шейпер отключён (-r off)"
    tc qdisc del dev "$(ip route show default | awk '/default/{print $5; exit}')" root 2>/dev/null || true
else
    step "Настраиваю шейпер исходящей полосы"

    # burst не меньше rate/HZ, иначе HTB недобирает полосу
    if   (( RATE_MBIT > 2400 )); then BURST="4m"
    elif (( RATE_MBIT > 1200 )); then BURST="2m"
    else                              BURST="1m"
    fi

    cat > /usr/local/sbin/node-shape <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFACE="$IFACE"; RATE="$RATE"; BURST="$BURST"
case "\${1:-apply}" in
  apply)
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" root handle 1: htb default 10
    tc class add dev "\$IFACE" parent 1: classid 1:10 htb \\
        rate "\$RATE" ceil "\$RATE" burst "\$BURST" cburst "\$BURST"
    tc qdisc add dev "\$IFACE" parent 1:10 handle 10: fq
    ;;
  clear)  tc qdisc del dev "\$IFACE" root 2>/dev/null || true ;;
  status) tc -s qdisc show dev "\$IFACE"; echo; tc -s class show dev "\$IFACE" ;;
  *) echo "usage: \$0 {apply|clear|status}"; exit 1 ;;
esac
EOF
    chmod +x /usr/local/sbin/node-shape

    cat > /etc/systemd/system/node-shape.service <<EOF
[Unit]
Description=Egress bandwidth limit ($RATE on $IFACE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/node-shape apply
ExecStop=/usr/local/sbin/node-shape clear

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node-shape.service >/dev/null 2>&1
    # именно restart: при повторном прогоне enable --now не переприменит новый rate
    systemctl restart node-shape.service
    info "лимит $RATE на $IFACE (burst $BURST), переживёт перезагрузку"
fi


# ─── 10. верификация ─────────────────────────────────────────────────────────
step "Проверяю, что настройки реально применились"

FAILED=0
check() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        printf '    %-34s %s\n' "$name" "${C_OK}${got}${C_OFF}"
    else
        printf '    %-34s %s %s\n' "$name" "${C_ERR}${got}${C_OFF}" "${C_DIM}(ожидалось $want)${C_OFF}"
        FAILED=1
    fi
}

check "tcp_congestion_control" "bbr"          "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo -)"
check "default_qdisc"          "fq"           "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo -)"
check "somaxconn"              "$SOMAXCONN"   "$(sysctl -n net.core.somaxconn 2>/dev/null || echo -)"
check "wmem_max"               "$BUF"         "$(sysctl -n net.core.wmem_max 2>/dev/null || echo -)"
check "netdev_max_backlog"     "$BACKLOG"     "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo -)"
check "tcp_mtu_probing"        "1"            "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo -)"
[[ $HAS_CONNTRACK -eq 1 ]] && \
  check "nf_conntrack_max"     "$CONNTRACK"   "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo -)"

# главное: лимит дескрипторов у живого процесса nginx, а не в конфиге
NGINX_PID="$(pgrep -f 'nginx: master' | head -1 || true)"
if [[ -n "$NGINX_PID" ]]; then
    ACTUAL_NOFILE="$(awk '/Max open files/ {print $4}' "/proc/$NGINX_PID/limits" 2>/dev/null || echo -)"
    check "nginx nofile (фактический)" "$RLIMIT_NOFILE" "$ACTUAL_NOFILE"
else
    warn "процесс nginx не найден, лимит дескрипторов не проверен"
    FAILED=1
fi

if [[ $SKIP_SHAPE -eq 0 ]]; then
    if tc qdisc show dev "$IFACE" | grep -q htb; then
        printf '    %-34s %s\n' "шейпер на $IFACE" "${C_OK}активен ($RATE)${C_OFF}"
    else
        printf '    %-34s %s\n' "шейпер на $IFACE" "${C_ERR}не активен${C_OFF}"
        FAILED=1
    fi
fi

# доступен ли upstream xray
UP_HOST="${UPSTREAM%:*}"; UP_PORT="${UPSTREAM##*:}"
if timeout 2 bash -c "</dev/tcp/$UP_HOST/$UP_PORT" 2>/dev/null; then
    printf '    %-34s %s\n' "upstream $UPSTREAM" "${C_OK}отвечает${C_OFF}"
else
    printf '    %-34s %s\n' "upstream $UPSTREAM" "${C_WARN}не отвечает${C_OFF} ${C_DIM}(запустите xray)${C_OFF}"
fi

if [[ $FAILED -eq 1 ]]; then
    echo
    warn "часть параметров не применилась — смотрите красные строки выше"
    warn "чаще всего помогает перезагрузка: некоторые лимиты берутся только при старте"
fi

trap - EXIT


# ─── итог ────────────────────────────────────────────────────────────────────
step "Готово"
cat <<EOF

  домен      $DOMAIN
  ws-путь    $WS_PATH
             ^^^ впишите этот путь в узел Remnawave ($PATH_SOURCE)
  upstream   $UPSTREAM
  шейпер     $([[ $SKIP_SHAPE -eq 1 ]] && echo "выключен" || echo "$RATE на $IFACE")

  проверить:
    curl -Ik https://$DOMAIN/
    node-shape status
    systemctl status nginx

  дальше вручную:
    1. в панели DDoS-Guard добавить домен и указать этот IP как origin
    2. в Remnawave проверить, что путь узла совпадает с $WS_PATH
    3. убедиться, что xray слушает $UPSTREAM

EOF

exit $FAILED
