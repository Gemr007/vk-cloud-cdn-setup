#!/usr/bin/env bash
#
# setup-cdn-bridge.sh — настройка серверной части CDN-моста
# (Remnawave + XHTTP + сторонний CDN) по этапам.
#
# Каждый этап спрашивает только то, что нужно именно ему, и может
# запускаться отдельно (удобно, если что-то пошло не так и нужно
# перезапустить только один шаг, не проходя всё заново).
#
# Использование:
#   sudo bash setup-cdn-bridge.sh           # меню, выбрать этап вручную
#   sudo bash setup-cdn-bridge.sh all        # пройти все этапы подряд
#   sudo bash setup-cdn-bridge.sh nginx      # только настройка nginx
#   sudo bash setup-cdn-bridge.sh node       # только установка ноды
#   sudo bash setup-cdn-bridge.sh files      # только генерация JSON для панели
#   sudo bash setup-cdn-bridge.sh check      # только проверка
#
set -euo pipefail

STATE_DIR="/root/.cdn-bridge"
STATE_FILE="${STATE_DIR}/state.env"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

# ============================================================
# Вывод и утилиты
# ============================================================

c_green() { echo -e "\033[0;32m$*\033[0m"; }
c_yellow() { echo -e "\033[0;33m$*\033[0m"; }
c_red() { echo -e "\033[0;31m$*\033[0m"; }
c_bold() { echo -e "\033[1m$*\033[0m"; }
header() { echo; c_bold "════════════════════════════════════════════════"; c_bold "  $*"; c_bold "════════════════════════════════════════════════"; }
step() { echo; c_green "-> $*"; }
warn() { c_yellow "!! $*"; }
die() { c_red "ОШИБКА: $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
}

# Читает значение из state-файла, если есть
state_get() {
    grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# Пишет/обновляет значение в state-файле
state_set() {
    local key="$1" val="$2"
    grep -vE "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    echo "${key}=${val}" >> "$STATE_FILE"
}

# Спрашивает значение, предлагая уже сохранённое (из прошлого запуска) как дефолт
ask() {
    local prompt="$1" key="$2" default_val="${3:-}"
    local saved
    saved=$(state_get "$key")
    local shown_default="${saved:-$default_val}"
    local answer
    if [[ -n "$shown_default" ]]; then
        read -rp "$prompt [$shown_default]: " answer
        answer="${answer:-$shown_default}"
    else
        read -rp "$prompt: " answer
    fi
    echo "$answer"
}

domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
validate_domain() {
    [[ "$1" =~ $domain_regex ]] || die "'$1' не похож на домен (без http://, без пути, без пробелов)"
}

# ============================================================
# ЭТАП 1 — nginx (домены, путь, секрет)
# ============================================================

stage_nginx() {
    header "ЭТАП 1: настройка nginx на origin-сервере"

    require_root

    if ! command -v nginx &>/dev/null; then
        step "Устанавливаю nginx и базовые пакеты"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl wget nginx ufw ca-certificates dnsutils > /dev/null
    fi

    echo
    echo "Нужны домены. Origin-домен — это адрес ЭТОГО сервера, должен уже"
    echo "резолвиться A-записью на его IP. CDN-домен настраивается позже,"
    echo "отдельно, в веб-консоли CDN-провайдера — сейчас он не нужен."
    echo

    ORIGIN_DOMAIN=$(ask "Домен origin-сервера (например origin.example.com)" ORIGIN_DOMAIN)
    [[ -z "$ORIGIN_DOMAIN" ]] && die "Домен обязателен"
    validate_domain "$ORIGIN_DOMAIN"

    XHTTP_PATH=$(ask "Путь XHTTP-инбаунда" XHTTP_PATH "/api/upload/chunk")
    [[ "$XHTTP_PATH" != /* ]] && die "Путь должен начинаться с /"

    XRAY_LOCAL_PORT=$(ask "Локальный порт Xray-инбаунда" XRAY_LOCAL_PORT "5447")

    EXISTING_SECRET=$(state_get ORIGIN_SECRET)
    if [[ -n "$EXISTING_SECRET" ]]; then
        warn "Секретный токен уже был сгенерирован раньше: $EXISTING_SECRET"
        read -rp "Оставить его как есть? [Y/n]: " keep
        if [[ "$keep" == "n" || "$keep" == "N" ]]; then
            ORIGIN_SECRET=$(openssl rand -hex 24)
            warn "Сгенерирован новый секрет — не забудь обновить его везде, где старый уже был прописан (CDN, панель)!"
        else
            ORIGIN_SECRET="$EXISTING_SECRET"
        fi
    else
        ORIGIN_SECRET=$(openssl rand -hex 24)
        c_green "Сгенерирован секретный токен: $ORIGIN_SECRET"
    fi

    state_set ORIGIN_DOMAIN "$ORIGIN_DOMAIN"
    state_set XHTTP_PATH "$XHTTP_PATH"
    state_set XRAY_LOCAL_PORT "$XRAY_LOCAL_PORT"
    state_set ORIGIN_SECRET "$ORIGIN_SECRET"

    step "Проверяю DNS"
    RESOLVED_IP=$(dig +short "$ORIGIN_DOMAIN" A 2>/dev/null | tail -n1 || true)
    MY_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "")
    if [[ -z "$RESOLVED_IP" ]]; then
        warn "$ORIGIN_DOMAIN пока не резолвится. Настройка nginx продолжится,"
        warn "но проверка в конце этого этапа, скорее всего, не пройдёт, пока не поправишь DNS."
    elif [[ -n "$MY_IP" && "$RESOLVED_IP" != "$MY_IP" ]]; then
        warn "$ORIGIN_DOMAIN -> $RESOLVED_IP, а внешний IP этого сервера видится как $MY_IP"
        warn "Если это не ожидаемо (NAT и т.п.) — проверь DNS отдельно."
    else
        c_green "DNS в порядке: $ORIGIN_DOMAIN -> $RESOLVED_IP"
    fi

    step "Настраиваю firewall"
    ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
    ufw allow 80/tcp comment 'HTTP для CDN' 2>/dev/null || true
    ufw status | grep -q "Status: active" || ufw --force enable

    step "Пишу конфиг nginx"
    cat > /etc/nginx/sites-available/origin << EOF
server {
    listen 80;
    server_name ${ORIGIN_DOMAIN};

    if (\$http_x_origin_secret != "${ORIGIN_SECRET}") { return 403; }

    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
        chunked_transfer_encoding on;
    }

    location / { return 404; }
}
EOF
    ln -sf /etc/nginx/sites-available/origin /etc/nginx/sites-enabled/origin
    rm -f /etc/nginx/sites-enabled/default

    if ! nginx -t 2>&1 | grep -q "syntax is ok"; then
        nginx -t
        die "nginx -t провалился — смотри вывод выше, конфиг НЕ применён"
    fi
    systemctl reload nginx
    c_green "nginx настроен и перезагружен"

    step "Локальная проверка (Xray ещё не поднят — это следующий этап)"
    echo -n "Без секрета (ждём 403): "
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${ORIGIN_DOMAIN}${XHTTP_PATH}" || echo "000")
    [[ "$CODE" == "403" ]] && c_green "$CODE — верно" || warn "$CODE — ожидался 403, проверь DNS и порт 80 снаружи"

    echo -n "С секретом (ждём 502 — бэкенда ещё нет, это нормально): "
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Origin-Secret: ${ORIGIN_SECRET}" "http://${ORIGIN_DOMAIN}${XHTTP_PATH}" || echo "000")
    c_yellow "$CODE"

    state_set STAGE_NGINX_DONE "yes"
    header "ЭТАП 1 завершён"
    echo "Секрет сохранён, при следующем запуске скрипт предложит его переиспользовать."
}

# ============================================================
# ЭТАП 2 — установка ноды remnanode (Docker + SECRET_KEY)
# ============================================================

stage_node() {
    header "ЭТАП 2: установка ноды Remnawave (remnanode)"

    require_root

    if [[ "$(state_get STAGE_NGINX_DONE)" != "yes" ]]; then
        warn "Похоже, этап nginx ещё не проходили в этом скрипте."
        warn "Нода без nginx перед ней технически поднимется, но мост работать не будет."
        read -rp "Продолжить всё равно? [y/N]: " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && { echo "Отменено, сначала: $0 nginx"; return 1; }
    fi

    if ! command -v docker &>/dev/null; then
        step "Устанавливаю Docker"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker

    NODE_PORT=$(ask "NODE_PORT (порт, которым панель управляет нодой)" NODE_PORT "2222")
    state_set NODE_PORT "$NODE_PORT"

    echo
    echo "SECRET_KEY выдаётся панелью Remnawave при добавлении ноды:"
    echo "  Панель -> Nodes -> Add Node -> указать адрес этого сервера"
    echo "  и порт ${NODE_PORT} -> панель покажет SECRET_KEY один раз."
    echo
    warn "Если ноду в панели ещё не создавал(а) — сделай это сейчас в другой"
    warn "вкладке браузера, потом вернись сюда и вставь SECRET_KEY."
    echo
    read -rp "SECRET_KEY (можно оставить пустым и вписать позже вручную): " NODE_SECRET_KEY

    mkdir -p /opt/remnanode /var/log/remnanode

    SECRET_KEY_LINE='SECRET_KEY="PASTE_SECRET_KEY_HERE"'
    if [[ -n "$NODE_SECRET_KEY" ]]; then
        SECRET_KEY_LINE="SECRET_KEY=\"${NODE_SECRET_KEY}\""
    fi

    cat > /opt/remnanode/docker-compose.yml << EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - ${SECRET_KEY_LINE}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

    if [[ -n "$NODE_SECRET_KEY" ]]; then
        step "Запускаю remnanode"
        (cd /opt/remnanode && docker compose up -d)
        sleep 3
        if docker ps --filter "name=remnanode" --filter "status=running" | grep -q remnanode; then
            c_green "Контейнер remnanode запущен. Проверь в панели, что нода перешла в статус online (обычно 1-2 минуты)."
            state_set STAGE_NODE_DONE "yes"
        else
            warn "Контейнер не в статусе running — смотри логи: docker logs remnanode"
        fi
    else
        warn "SECRET_KEY не указан — контейнер НЕ запущен."
        echo "Когда получишь SECRET_KEY из панели:"
        echo "  1) впиши его в /opt/remnanode/docker-compose.yml вместо PASTE_SECRET_KEY_HERE"
        echo "  2) выполни: cd /opt/remnanode && docker compose up -d"
        echo "  или просто перезапусти: $0 node"
    fi

    IP_FOR_HINT=$(curl -s -4 ifconfig.me 2>/dev/null || echo "<IP этого сервера>")
    echo
    warn "Порт ${NODE_PORT} стоит открыть в ufw только для IP панели, не для всех:"
    echo "    ufw allow from <IP_ПАНЕЛИ> to any port ${NODE_PORT} proto tcp"
    echo "(если панель и нода на одном сервере — не нужно, доступ и так через 127.0.0.1)"

    header "ЭТАП 2 завершён"
}

# ============================================================
# ЭТАП 3 — генерация JSON-файлов для панели
# ============================================================

stage_files() {
    header "ЭТАП 3: генерация JSON для панели Remnawave"

    ORIGIN_DOMAIN=$(state_get ORIGIN_DOMAIN)
    XHTTP_PATH=$(state_get XHTTP_PATH)
    XRAY_LOCAL_PORT=$(state_get XRAY_LOCAL_PORT)
    ORIGIN_SECRET=$(state_get ORIGIN_SECRET)

    if [[ -z "$ORIGIN_DOMAIN" || -z "$ORIGIN_SECRET" ]]; then
        die "Не хватает данных из этапа nginx. Сначала запусти: $0 nginx"
    fi

    CDN_FRONT_HOST=$(ask "Домен CDN-фронта (Персональный домен из VK Cloud CDN)" CDN_FRONT_HOST)
    [[ -z "$CDN_FRONT_HOST" ]] && die "CDN-домен обязателен для генерации Host-файла"
    validate_domain "$CDN_FRONT_HOST"
    state_set CDN_FRONT_HOST "$CDN_FRONT_HOST"

    cat > "${STATE_DIR}/config-profile-inbound.json" << EOF
{
  "tag": "RU-XHTTP-CDN",
  "port": ${XRAY_LOCAL_PORT},
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "mode": "packet-up",
      "path": "${XHTTP_PATH}",
      "extra": {
        "uplinkHTTPMethod": "GET",
        "noSSEHeader": true,
        "xPaddingKey": "hash",
        "xPaddingHeader": "X-Client-Version",
        "xPaddingMethod": "tokenish",
        "xPaddingObfsMode": true,
        "xPaddingPlacement": "queryInHeader",
        "scMaxBufferedPosts": 30,
        "scMaxEachPostBytes": 1000000,
        "scMinPostsIntervalMs": 30,
        "xmux": {
          "cMaxReuseTimes": 1000,
          "maxConcurrency": "16-32",
          "maxConnections": 0,
          "hKeepAlivePeriod": 20000,
          "hMaxRequestTimes": "600-900",
          "hMaxReusableSecs": "1800-3000"
        }
      }
    }
  }
}
EOF

    cat > "${STATE_DIR}/host-xhttp-extra.json" << EOF
{
  "path": "${XHTTP_PATH}",
  "uplinkHTTPMethod": "GET",
  "noSSEHeader": true,
  "headers": { "X-Origin-Secret": "${ORIGIN_SECRET}" },
  "xPaddingKey": "hash",
  "xPaddingHeader": "X-Client-Version",
  "xPaddingMethod": "tokenish",
  "xPaddingObfsMode": true,
  "xPaddingPlacement": "queryInHeader",
  "xmux": {
    "cMaxReuseTimes": 1000,
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "hKeepAlivePeriod": 20000,
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000"
  }
}
EOF

    cat > "${STATE_DIR}/routing-outbound-direct.json" << 'EOF'
{
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" },
      { "inboundTag": ["RU-XHTTP-CDN"], "outboundTag": "DIRECT" }
    ]
  }
}
EOF

    c_green "Файлы готовы в ${STATE_DIR}/:"
    echo "  - config-profile-inbound.json  (вставить в inbounds Config Profile)"
    echo "  - host-xhttp-extra.json         (вставить в xHTTP extra params хоста)"
    echo "  - routing-outbound-direct.json  (вставить в outbounds/routing профиля)"

    state_set STAGE_FILES_DONE "yes"
    header "ЭТАП 3 завершён"
}

# ============================================================
# ЭТАП 4 — финальная проверка + чеклист ручных шагов
# ============================================================

stage_check() {
    header "ЭТАП 4: проверка и чеклист ручных шагов"

    ORIGIN_DOMAIN=$(state_get ORIGIN_DOMAIN)
    CDN_FRONT_HOST=$(state_get CDN_FRONT_HOST)
    XHTTP_PATH=$(state_get XHTTP_PATH)
    ORIGIN_SECRET=$(state_get ORIGIN_SECRET)

    [[ -z "$ORIGIN_DOMAIN" ]] && die "Нет данных, пройди этапы nginx/node/files сначала"

    step "Проверка origin напрямую"
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Origin-Secret: ${ORIGIN_SECRET}" "http://${ORIGIN_DOMAIN}${XHTTP_PATH}" || echo "000")
    if [[ "$CODE" == "502" ]]; then
        warn "$CODE — Xray-инбаунд ещё не поднят на этой ноде (Config Profile не применён/не reload)"
    elif [[ "$CODE" == "000" ]]; then
        warn "Нет ответа вообще — проверь nginx (systemctl status nginx) и firewall"
    else
        c_green "$CODE — origin отвечает"
    fi

    if [[ -n "$CDN_FRONT_HOST" ]]; then
        step "Проверка через CDN"
        CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CDN_FRONT_HOST}${XHTTP_PATH}" || echo "000")
        c_yellow "HTTP $CODE (интерпретация — см. таблицу ниже)"
    fi

    cat << 'EOF'

────────────────────────────────────────────────────────────
ЧЕКЛИСТ РУЧНЫХ ШАГОВ (то, что скрипт сделать не может)
────────────────────────────────────────────────────────────

1) VK CLOUD CDN — создать/проверить ресурс:
   консоль VK Cloud -> CDN -> Создать ресурс (если ещё нет)

   Шаг «Настройка доступа и протокола»:
     - Доступ к контенту конечным пользователям: ВКЛЮЧИТЬ
     - Протокол взаимодействия с источником:      HTTP

   Шаг «Конфигурация источников и доменов»:
EOF
    echo "     - Источник контента:      http://${ORIGIN_DOMAIN}"
    echo "     - Персональный домен:     ${CDN_FRONT_HOST:-<впиши на этапе files>}"
    echo "     - Изменение заголовка Host: Кастомный -> ${ORIGIN_DOMAIN}"
    cat << 'EOF'
     (после ввода домена появится CNAME вида
      cl-XXXXXXXX.service.cdn.msk.vkcs.cloud — прописать в DNS)

   Шаг «Настройки шифрования»:
     - SSL-сертификат: Let's Encrypt

   Если есть шаг «Заголовки к источнику»:
EOF
    echo "     X-Origin-Secret: ${ORIGIN_SECRET}"
    cat << 'EOF'

2) DNS:
EOF
    echo "     ${CDN_FRONT_HOST:-<CDN-домен>}  CNAME  <значение из VK Cloud>"
    cat << 'EOF'
     Proxy/облако у записи — ВЫКЛЮЧЕНО (DNS only)

3) ПАНЕЛЬ REMNAWAVE:
   a) Nodes -> Add Node (если ещё нет) -> SECRET_KEY -> см. этап node
   b) Config Profiles -> вставить содержимое:
EOF
    echo "        ${STATE_DIR}/config-profile-inbound.json"
    echo "        ${STATE_DIR}/routing-outbound-direct.json"
    cat << 'EOF'
      -> Сохранить -> RELOAD/RESTART ноды (обязательно!)
   c) Hosts -> Add Host, xHTTP extra params — вставить:
EOF
    echo "        ${STATE_DIR}/host-xhttp-extra.json"
    cat << 'EOF'
   d) Users -> Create User -> служебный юзер (unlimited, без squad клиентов)
      Для тестов брать поле vlessUuid, НЕ uuid аккаунта.

4) Финальная проверка вручную:
EOF
    echo "     curl -v https://${CDN_FRONT_HOST:-<CDN-домен>}${XHTTP_PATH}"
    echo "   (ждём НЕ 502 и не страницу-заглушку CDN)"
    echo
    echo "Таблица кодов на этом сервере:"
    echo "  403 без секрета     — нормально"
    echo "  502 с секретом      — Xray-инбаунд ещё не поднят/не reload"
    echo "  404 с секретом      — Xray поднят и отвечает, это нормальный ответ на голый curl"
    echo "────────────────────────────────────────────────────────────"

    header "ЭТАП 4 завершён"
}

# ============================================================
# Меню / диспетчер
# ============================================================

run_all() {
    stage_nginx
    stage_node
    stage_files
    stage_check
}

show_menu() {
    header "setup-cdn-bridge.sh — настройка CDN-моста"
    echo "Выбери этап (можно проходить по одному, состояние сохраняется в ${STATE_FILE}):"
    echo
    echo "  1) nginx  — домены, путь, секрет, конфиг nginx"
    echo "  2) node   — установка remnanode (Docker + SECRET_KEY)"
    echo "  3) files  — генерация JSON для панели (Config Profile / Host)"
    echo "  4) check  — проверка + чеклист ручных шагов"
    echo "  5) all    — пройти всё по порядку"
    echo "  0) выход"
    echo
    read -rp "Выбор: " choice
    case "$choice" in
        1) stage_nginx ;;
        2) stage_node ;;
        3) stage_files ;;
        4) stage_check ;;
        5) run_all ;;
        0) exit 0 ;;
        *) die "Не понял выбор" ;;
    esac
}

case "${1:-menu}" in
    nginx) stage_nginx ;;
    node) stage_node ;;
    files) stage_files ;;
    check) stage_check ;;
    all) run_all ;;
    menu) show_menu ;;
    *) die "Неизвестный аргумент: $1 (доступно: nginx, node, files, check, all)" ;;
esac
