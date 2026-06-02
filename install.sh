#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║              GhostWave — Unified Installer v1.1                        ║
# ║              Единый установщик Panel + Node                            ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -uo pipefail
# НАМЕРЕННО без -e: ask_yn возвращает 1 при "n" — это нормально,
# но с -e скрипт бы убивался. Ошибки команд проверяем вручную.

# ─────────────────────────────────────────────────────────────────────────────
# ЦВЕТА И ФОРМАТИРОВАНИЕ
# ─────────────────────────────────────────────────────────────────────────────

R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2m'
NC='\033[0m'
BOLD='\033[1m'
CHECK="${G}✔${NC}"
CROSS="${R}✘${NC}"
ARROW="${C}›${NC}"
WARN="${Y}⚠${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# ─────────────────────────────────────────────────────────────────────────────

INSTALL_MODE=""
INSTALL_DIR=""
SERVER_IP=""
REPLY=""

PANEL_DOMAIN=""
ADMIN_USER=""
ADMIN_PASS=""
DB_PASSWORD=""
JWT_SECRET=""
SECRET_KEY=""
NODE_API_KEY=""
REDIS_PASSWORD=""
TG_TOKEN=""
TG_ADMIN_IDS="[]"

NODE_ID=""
NODE_PANEL_URL=""
NODE_PANEL_KEY=""
NODE_GN_DOMAIN=""
NODE_GN_PORT="443"
NODE_GN_SECRET=""
NODE_AGENT_PORT="2095"

# ─────────────────────────────────────────────────────────────────────────────
# УТИЛИТЫ
# ─────────────────────────────────────────────────────────────────────────────

log_step()  { echo -e "\n${BOLD}${C}══ $1 ${NC}"; }
log_ok()    { echo -e "  ${CHECK} $1"; }
log_err()   { echo -e "  ${CROSS} ${R}$1${NC}"; }
log_warn()  { echo -e "  ${WARN} ${Y}$1${NC}"; }
log_info()  { echo -e "  ${ARROW} ${D}$1${NC}"; }
log_val()   { echo -e "  ${C}$1${NC} ${W}$2${NC}"; }

separator() {
    echo -e "\n${D}────────────────────────────────────────────────────────────────${NC}\n"
}

pause() {
    echo ""
    read -rp "$(echo -e "  ${D}Нажмите Enter для продолжения...${NC}")" _
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${D}[${default}]${NC}"
    echo -ne "  ${ARROW} ${W}${prompt}${NC}${hint}: "
    REPLY=""
    read -r REPLY || REPLY=""
    # Убираем \r (Windows/SSH терминалы)
    REPLY="${REPLY//$'\r'/}"
    [[ -z "$REPLY" && -n "$default" ]] && REPLY="$default"
}

ask_secret() {
    local prompt="$1"
    echo -ne "  ${ARROW} ${W}${prompt}${NC}: "
    REPLY=""
    read -rs REPLY || REPLY=""
    REPLY="${REPLY//$'\r'/}"
    echo ""
}

# ВАЖНО: возвращает 0 (true) для y/Y, 1 (false) для n/N
# НЕ используем set -e именно из-за этой функции
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint
    if [[ "$default" == "y" ]]; then
        hint="${G}Y${NC}/${D}n${NC}"
    else
        hint="${D}y${NC}/${G}N${NC}"
    fi
    echo -ne "  ${ARROW} ${W}${prompt}${NC} [${hint}]: "
    REPLY=""
    read -r REPLY || REPLY="$default"
    REPLY="${REPLY//$'\r'/}"
    REPLY="${REPLY:-$default}"
    if [[ "${REPLY,,}" == "y" ]]; then
        return 0
    else
        return 1
    fi
}

gen_secret() {
    python3 -c "import secrets; print(secrets.token_hex(32))"
}

gen_password() {
    python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%'
print(''.join(secrets.choice(chars) for _ in range(24)))
"
}

spinner() {
    local pid=$1
    local msg="$2"
    local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C}${sp:i++%${#sp}:1}${NC} ${D}%s${NC}" "$msg"
        sleep 0.08
    done
    tput cnorm 2>/dev/null || true
    printf "\r  ${CHECK} %s\n" "$msg"
}

run_bg() {
    local msg="$1"; shift
    "$@" &>/tmp/gw_install_last.log &
    local pid=$!
    spinner "$pid" "$msg"
    local rc=0
    wait "$pid" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "Ошибка при: $msg"
        echo -e "  ${D}$(tail -5 /tmp/gw_install_last.log 2>/dev/null)${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# БАННЕР
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    clear
    echo -e "${C}"
    cat << 'EOF'

   ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
  ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
  ██║  ███╗███████║██║   ██║███████╗   ██║
  ██║   ██║██╔══██║██║   ██║╚════██║   ██║
  ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝

  ██╗    ██╗ █████╗ ██╗   ██╗███████╗
  ██║    ██║██╔══██╗██║   ██║██╔════╝
  ██║ █╗ ██║███████║██║   ██║█████╗
  ██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝
  ╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗
   ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝

EOF
    echo -e "${NC}"
    echo -e "  ${W}Unified Installer v1.1${NC}  ${D}— Panel & Node${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 0: ПРОВЕРКА СИСТЕМЫ
# ─────────────────────────────────────────────────────────────────────────────

check_system() {
    log_step "Проверка системы"

    if [[ $EUID -ne 0 ]]; then
        log_err "Установщик должен быть запущен от root"
        echo -e "\n  Используйте: ${W}sudo bash install.sh${NC}\n"
        exit 1
    fi
    log_ok "Запущен от root"

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            log_ok "ОС: $PRETTY_NAME"
        else
            log_warn "ОС $PRETTY_NAME не тестировалась. Продолжаем на свой риск."
        fi
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]]; then
        log_ok "Архитектура: $ARCH"
    else
        log_err "Неподдерживаемая архитектура: $ARCH"
        exit 1
    fi

    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if (( RAM_MB < 450 )); then
        log_err "Недостаточно RAM: ${RAM_MB}MB (нужно минимум 512MB)"
        exit 1
    fi
    log_ok "RAM: ${RAM_MB}MB"

    DISK_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    if (( DISK_GB < 5 )); then
        log_warn "Свободного места: ${DISK_GB}GB (рекомендуется 10GB+)"
    else
        log_ok "Свободное место: ${DISK_GB}GB"
    fi

    local inet_ok=0
    curl -sf --max-time 5 https://google.com >/dev/null 2>&1 && inet_ok=1 || true
    if [[ $inet_ok -eq 1 ]]; then
        log_ok "Интернет-соединение: OK"
    else
        log_err "Нет доступа к интернету"
        exit 1
    fi

    SERVER_IP=""
    SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null) || true
    fi
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || SERVER_IP="unknown"
    fi
    log_ok "IP сервера: ${W}${SERVER_IP}${NC}"

    if command -v python3 &>/dev/null; then
        PYTHON_VER=$(python3 --version 2>&1 | awk '{print $2}')
        log_ok "Python3: $PYTHON_VER"
    else
        log_err "Python3 не найден"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 1: ВЫБОР РЕЖИМА
# ─────────────────────────────────────────────────────────────────────────────

choose_mode() {
    separator
    log_step "Выбор действия"
    echo ""
    echo -e "  ${W}1)${NC} ${G}Установить Panel${NC}   — управляющий сервер (API, БД, Telegram бот)"
    echo -e "           Один на всю инфраструктуру. Не обязательно вне РФ.\n"
    echo -e "  ${W}2)${NC} ${C}Установить Node${NC}    — VPN-сервер (GhostNet daemon + агент)"
    echo -e "           По одному на каждый VPN-сервер. Желательно за рубежом.\n"
    echo -e "  ${W}3)${NC} ${Y}Установить Panel + Node${NC} — всё на одном сервере (тест/мелкий прод)\n"
    echo -e "  ${W}4)${NC} ${R}Удалить${NC}            — удалить Panel / Node / всё\n"
    echo -e "  ${W}5)${NC} Перезапустить       — перезапустить Panel / Node\n"

    while true; do
        ask "Ваш выбор" "1"
        case "$REPLY" in
            1) INSTALL_MODE="panel";      break ;;
            2) INSTALL_MODE="node";       break ;;
            3) INSTALL_MODE="panel+node"; break ;;
            4) INSTALL_MODE="uninstall";  break ;;
            5) INSTALL_MODE="restart";    break ;;
            *) log_warn "Введите 1–5" ;;
        esac
    done

    case "$INSTALL_MODE" in
        panel)      log_ok "Действие: ${G}Установка Panel${NC}" ;;
        node)       log_ok "Действие: ${C}Установка Node${NC}" ;;
        panel+node) log_ok "Действие: ${Y}Установка Panel + Node${NC}" ;;
        uninstall)  log_ok "Действие: ${R}Удаление${NC}" ;;
        restart)    log_ok "Действие: Перезапуск" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 2: ЗАВИСИМОСТИ
# ─────────────────────────────────────────────────────────────────────────────

install_deps() {
    separator
    log_step "Установка зависимостей"

    run_bg "Обновление пакетов" apt-get update -qq

    run_bg "Установка базовых утилит" \
        apt-get install -y -qq curl wget git ufw net-tools dnsutils

    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
        log_ok "Docker уже установлен: $DOCKER_VER"
    else
        run_bg "Установка Docker" bash -c "curl -fsSL https://get.docker.com | sh"
        run_bg "Запуск Docker daemon" bash -c "systemctl enable docker && systemctl start docker"
        log_ok "Docker установлен"
    fi

    local compose_ok=0
    docker compose version &>/dev/null 2>&1 && compose_ok=1 || true
    if [[ $compose_ok -eq 1 ]]; then
        log_ok "Docker Compose v2: $(docker compose version --short 2>/dev/null || echo 'ok')"
    else
        run_bg "Установка Docker Compose" apt-get install -y -qq docker-compose-plugin
        log_ok "Docker Compose установлен"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        run_bg "Установка сетевых инструментов (TUN/iptables)" \
            apt-get install -y -qq iproute2 iptables
        log_ok "Сетевые инструменты установлены"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 3: ФАЙРВОЛ
# ─────────────────────────────────────────────────────────────────────────────

setup_firewall() {
    separator
    log_step "Настройка файрвола (ufw)"

    ufw allow 22/tcp comment "SSH" >/dev/null 2>&1 || true
    log_ok "Порт 22 (SSH) — открыт"

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        ufw allow 80/tcp  comment "HTTP (Caddy ACME)"  >/dev/null 2>&1 || true
        ufw allow 443/tcp comment "HTTPS Panel"        >/dev/null 2>&1 || true
        log_ok "Порты 80, 443 (Panel HTTPS) — открыты"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        local gn_port="${NODE_GN_PORT:-443}"
        local agent_port="${NODE_AGENT_PORT:-2095}"

        ufw allow "${gn_port}/tcp" comment "GhostNet VPN" >/dev/null 2>&1 || true
        log_ok "Порт ${gn_port} (GhostNet) — открыт"

        # Ограничиваем агент-порт только для IP Panel (если знаем)
        local panel_ip=""
        if [[ -n "${NODE_PANEL_URL:-}" ]]; then
            local panel_host
            panel_host=$(echo "$NODE_PANEL_URL" | sed 's~https\?://~~' | cut -d/ -f1)
            panel_ip=$(dig +short "$panel_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1) || panel_ip=""
        fi

        if [[ -n "$panel_ip" ]]; then
            ufw delete allow "${agent_port}/tcp" >/dev/null 2>&1 || true
            ufw allow from "$panel_ip" to any port "$agent_port" proto tcp \
                comment "Node Agent (Panel only)" >/dev/null 2>&1 || true
            log_ok "Порт ${agent_port} (Agent) — только с IP Panel ($panel_ip)"
        else
            ufw allow "${agent_port}/tcp" comment "Node Agent" >/dev/null 2>&1 || true
            log_ok "Порт ${agent_port} (Node Agent) — открыт"
        fi
    fi

    ufw --force enable >/dev/null 2>&1 || true
    log_ok "Файрвол активирован"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 4 (PANEL): СБОР ДАННЫХ
# ─────────────────────────────────────────────────────────────────────────────

collect_panel_config() {
    separator
    log_step "Конфигурация Panel"

    # ── Домен ────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${W}Домен панели${NC}"
    echo -e "  ${D}Нужна A-запись: panel.yourdomain.com → ${SERVER_IP}${NC}"
    echo ""

    while true; do
        ask "Домен панели (например panel.example.com)"
        PANEL_DOMAIN="$REPLY"

        if [[ -z "$PANEL_DOMAIN" ]]; then
            log_warn "Домен не может быть пустым"
            continue
        fi

        echo -ne "  ${ARROW} ${D}Проверяем DNS для ${PANEL_DOMAIN}...${NC}"
        local resolved=""
        resolved=$(dig +short "$PANEL_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1) || resolved=""

        if [[ -z "$resolved" ]]; then
            echo -e "\r  ${CROSS} ${R}DNS не разрешается для ${PANEL_DOMAIN}${NC}"
            echo ""
            echo -e "  ${Y}Добавьте A-запись:${NC}"
            echo -e "  ${W}Имя:${NC} $PANEL_DOMAIN  ${W}Тип:${NC} A  ${W}Значение:${NC} ${SERVER_IP}"
            echo ""
            if ask_yn "Уже добавили? Попробовать снова?" "y"; then
                continue
            else
                if ask_yn "Продолжить без проверки DNS?" "n"; then
                    log_warn "Продолжаем без проверки DNS"
                    break
                fi
            fi
        elif [[ "$resolved" == "$SERVER_IP" ]]; then
            echo -e "\r  ${CHECK} DNS: ${PANEL_DOMAIN} → ${G}${resolved}${NC} ✓"
            break
        else
            echo -e "\r  ${WARN} ${Y}DNS: ${PANEL_DOMAIN} → ${resolved} (ожидалось ${SERVER_IP})${NC}"
            if ask_yn "Продолжить несмотря на расхождение IP?" "n"; then
                log_warn "Продолжаем с расхождением DNS"
                break
            fi
        fi
    done

    # ── Telegram ──────────────────────────────────────────────────────────
    separator
    echo -e "  ${W}Telegram бот${NC} ${D}(опционально)${NC}"
    echo ""
    echo -e "  ${D}1. Написать @BotFather → /newbot → скопировать токен${NC}"
    echo ""

    if ask_yn "Настроить Telegram бота сейчас?" "y"; then
        ask "Токен бота (@BotFather)" ""
        TG_TOKEN="$REPLY"

        if [[ -n "$TG_TOKEN" ]]; then
            echo -ne "  ${ARROW} ${D}Проверяем токен...${NC}"
            local bot_check=""
            bot_check=$(curl -sf --max-time 5 \
                "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null) || bot_check=""

            local check_ok=0
            echo "$bot_check" | grep -q '"ok":true' && check_ok=1 || true

            if [[ $check_ok -eq 1 ]]; then
                local bot_name=""
                bot_name=$(echo "$bot_check" | python3 -c \
                    "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null) || bot_name="?"
                echo -e "\r  ${CHECK} Бот проверен: ${G}@${bot_name}${NC}"
            else
                echo -e "\r  ${WARN} ${Y}Не удалось проверить токен${NC}"
            fi

            echo ""
            ask "Ваш Telegram ID (@userinfobot)" ""
            if [[ -n "$REPLY" ]]; then
                TG_ADMIN_IDS="[${REPLY}]"
                log_ok "Telegram ID: ${REPLY}"
            fi
        fi
    else
        TG_TOKEN=""
        TG_ADMIN_IDS="[]"
        log_info "Telegram пропущен. Настроите позже в .env"
    fi

    # ── Администратор ─────────────────────────────────────────────────────
    separator
    echo -e "  ${W}Учётная запись администратора${NC}"
    echo ""

    ask "Логин администратора" "admin"
    ADMIN_USER="$REPLY"

    while true; do
        ask_secret "Пароль (минимум 8 символов)"
        local pass1="$REPLY"
        if [[ ${#pass1} -lt 8 ]]; then
            log_warn "Пароль слишком короткий (минимум 8 символов)"
            continue
        fi
        ask_secret "Повторите пароль"
        if [[ "$pass1" == "$REPLY" ]]; then
            ADMIN_PASS="$pass1"
            log_ok "Пароль установлен"
            break
        else
            log_warn "Пароли не совпадают"
        fi
    done

    # ── Генерация ключей ──────────────────────────────────────────────────
    separator
    echo -e "  ${W}Генерация криптографических ключей${NC}"
    echo ""

    printf "  ${ARROW} ${D}Генерируем DB_PASSWORD...${NC}"
    DB_PASSWORD=$(gen_password)
    printf "\r  ${CHECK} DB_PASSWORD    ${D}(24 символа)${NC}\n"

    printf "  ${ARROW} ${D}Генерируем JWT_SECRET...${NC}"
    JWT_SECRET=$(gen_secret)
    printf "\r  ${CHECK} JWT_SECRET     ${D}(64 hex)${NC}\n"

    printf "  ${ARROW} ${D}Генерируем SECRET_KEY...${NC}"
    SECRET_KEY=$(gen_secret)
    printf "\r  ${CHECK} SECRET_KEY     ${D}(64 hex)${NC}\n"

    printf "  ${ARROW} ${D}Генерируем NODE_API_KEY...${NC}"
    NODE_API_KEY=$(gen_secret)
    printf "\r  ${CHECK} NODE_API_KEY   ${D}(64 hex)${NC}\n"

    printf "  ${ARROW} ${D}Генерируем REDIS_PASSWORD...${NC}"
    REDIS_PASSWORD=$(gen_password)
    printf "\r  ${CHECK} REDIS_PASSWORD ${D}(24 символа)${NC}\n"

    log_ok "Все ключи сгенерированы"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 4 (NODE): СБОР ДАННЫХ
# ─────────────────────────────────────────────────────────────────────────────

collect_node_config() {
    separator
    log_step "Конфигурация Node"

    echo ""
    echo -e "  ${W}Подключение к Panel${NC}"
    echo ""

    while true; do
        ask "URL панели (например https://panel.example.com)"
        NODE_PANEL_URL="${REPLY%/}"

        if [[ "$NODE_PANEL_URL" != https://* && "$NODE_PANEL_URL" != http://* ]]; then
            log_warn "URL должен начинаться с https:// или http://"
            continue
        fi

        echo -ne "  ${ARROW} ${D}Проверяем доступность панели...${NC}"
        local health=""
        health=$(curl -sf --max-time 8 "${NODE_PANEL_URL}/health" 2>/dev/null) || health=""

        local panel_ok=0
        echo "$health" | grep -q '"status":"ok"' && panel_ok=1 || true

        if [[ $panel_ok -eq 1 ]]; then
            local pver=""
            pver=$(echo "$health" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null) || pver="?"
            echo -e "\r  ${CHECK} Панель доступна (v${pver})"
            break
        else
            echo -e "\r  ${CROSS} ${R}Панель недоступна: ${NODE_PANEL_URL}${NC}"
            if ask_yn "Попробовать другой URL?" "y"; then
                continue
            else
                log_warn "Продолжаем без проверки панели"
                break
            fi
        fi
    done

    echo ""
    echo -e "  ${D}NODE_API_KEY находится на Panel-сервере:${NC}"
    echo -e "  ${D}grep NODE_API_KEY /opt/ghostwave/.env${NC}"
    echo ""

    while true; do
        ask "NODE_API_KEY с Panel-сервера"
        NODE_PANEL_KEY="$REPLY"
        if [[ ${#NODE_PANEL_KEY} -ge 32 ]]; then
            log_ok "NODE_API_KEY принят"
            break
        else
            log_warn "Ключ слишком короткий (ожидается 64 символа)"
            if ask_yn "Продолжить с этим ключом?" "n"; then
                break
            fi
        fi
    done

    # ── Создание ноды в Panel ────────────────────────────────────────────
    separator
    echo -e "  ${W}Регистрация ноды в Panel${NC}"
    echo ""

    if ask_yn "Создать ноду в панели автоматически через API?" "y"; then
        _create_node_via_api
    else
        ask "NODE_ID (число из панели)" "1"
        NODE_ID="$REPLY"
    fi

    # ── GhostNet параметры ───────────────────────────────────────────────
    separator
    echo -e "  ${W}GhostNet параметры${NC}"
    echo ""
    echo -e "  ${D}Домен маскировки — сервер будет выглядеть как этот сайт.${NC}"
    echo -e "  ${D}A-запись должна указывать на IP этого сервера.${NC}"
    echo ""

    while true; do
        ask "Домен маскировки (например news.example.com)"
        NODE_GN_DOMAIN="$REPLY"

        if [[ -z "$NODE_GN_DOMAIN" ]]; then
            log_warn "Домен не может быть пустым"
            continue
        fi

        echo -ne "  ${ARROW} ${D}Проверяем DNS для ${NODE_GN_DOMAIN}...${NC}"
        local gn_resolved=""
        gn_resolved=$(dig +short "$NODE_GN_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1) || gn_resolved=""

        if [[ -z "$gn_resolved" ]]; then
            echo -e "\r  ${WARN} ${Y}DNS не разрешается для ${NODE_GN_DOMAIN}${NC}"
            if ask_yn "Всё равно использовать?" "y"; then break; fi
        elif [[ "$gn_resolved" == "$SERVER_IP" ]]; then
            echo -e "\r  ${CHECK} DNS: ${NODE_GN_DOMAIN} → ${G}${gn_resolved}${NC} ✓"
            break
        else
            echo -e "\r  ${WARN} ${Y}${NODE_GN_DOMAIN} → ${gn_resolved} (не совпадает с ${SERVER_IP})${NC}"
            if ask_yn "Всё равно использовать?" "y"; then break; fi
        fi
    done

    ask "Порт GhostNet (рекомендуется 443)" "443"
    NODE_GN_PORT="$REPLY"

    ask "Порт Node Agent API" "2095"
    NODE_AGENT_PORT="$REPLY"

    printf "  ${ARROW} ${D}Генерируем GhostNet secret...${NC}"
    NODE_GN_SECRET=$(gen_secret)
    printf "\r  ${CHECK} GhostNet secret сгенерирован\n"

    log_ok "Конфигурация ноды собрана"
}

_create_node_via_api() {
    echo ""
    ask "Логин администратора Panel" "admin"
    local api_user="$REPLY"
    ask_secret "Пароль администратора Panel"
    local api_pass="$REPLY"

    echo ""
    echo -ne "  ${ARROW} ${D}Получаем JWT токен...${NC}"
    local token_resp=""
    token_resp=$(curl -sf --max-time 10 \
        -X POST "${NODE_PANEL_URL}/api/auth/login" \
        -F "username=${api_user}" \
        -F "password=${api_pass}" 2>/dev/null) || token_resp=""

    local jwt_ok=0
    echo "$token_resp" | grep -q '"access_token"' && jwt_ok=1 || true

    if [[ $jwt_ok -eq 0 ]]; then
        echo -e "\r  ${CROSS} ${R}Не удалось авторизоваться${NC}"
        ask "Введите NODE_ID вручную" "1"
        NODE_ID="$REPLY"
        return
    fi

    local jwt_token=""
    jwt_token=$(echo "$token_resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || jwt_token=""
    echo -e "\r  ${CHECK} JWT токен получен"

    ask "Название ноды" "🌐 Node #1"
    local node_name="$REPLY"
    ask "Страна (DE, NL, FI...)" "XX"
    local node_country="$REPLY"
    ask "Город" "Unknown"
    local node_city="$REPLY"

    local tmp_secret
    tmp_secret=$(gen_secret)

    local agent_p="${NODE_AGENT_PORT:-2095}"

    echo -ne "  ${ARROW} ${D}Создаём ноду в панели...${NC}"
    local create_resp=""
    create_resp=$(curl -sf --max-time 10 \
        -X POST "${NODE_PANEL_URL}/api/nodes" \
        -H "Authorization: Bearer ${jwt_token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${node_name}\",
            \"address\": \"${SERVER_IP}\",
            \"port\": ${agent_p},
            \"country\": \"${node_country}\",
            \"city\": \"${node_city}\",
            \"ghostnet_port\": 443,
            \"ghostnet_domain\": \"\",
            \"ghostnet_secret\": \"${tmp_secret}\"
        }" 2>/dev/null) || create_resp=""

    local create_ok=0
    echo "$create_resp" | grep -q '"id"' && create_ok=1 || true

    if [[ $create_ok -eq 1 ]]; then
        NODE_ID=$(echo "$create_resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null) || NODE_ID="1"
        echo -e "\r  ${CHECK} Нода создана. ${G}NODE_ID = ${NODE_ID}${NC}"
    else
        echo -e "\r  ${WARN} ${Y}Не удалось создать ноду через API${NC}"
        ask "Введите NODE_ID вручную" "1"
        NODE_ID="$REPLY"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# УДАЛЕНИЕ
# ─────────────────────────────────────────────────────────────────────────────

uninstall() {
    separator
    log_step "Удаление GhostWave"
    echo ""
    echo -e "  ${R}${BOLD}ВНИМАНИЕ: Это удалит все данные без возможности восстановления!${NC}"
    echo ""
    echo -e "  ${W}1)${NC} Удалить только Panel"
    echo -e "  ${W}2)${NC} Удалить только Node"
    echo -e "  ${W}3)${NC} Удалить всё (Panel + Node)"
    echo -e "  ${W}4)${NC} Отмена"
    echo ""

    while true; do
        ask "Ваш выбор" "4"
        case "$REPLY" in
            1) _uninstall_panel; break ;;
            2) _uninstall_node;  break ;;
            3) _uninstall_panel; _uninstall_node; break ;;
            4) log_info "Удаление отменено"; exit 0 ;;
            *) log_warn "Введите 1, 2, 3 или 4" ;;
        esac
    done

    echo ""
    log_ok "Удаление завершено"
}

_uninstall_panel() {
    echo ""
    log_step "Удаление Panel"

    if [[ ! -f /opt/ghostwave/docker/docker-compose.yml ]]; then
        log_warn "Panel не найдена (/opt/ghostwave не существует)"
        return
    fi

    if ask_yn "Удалить данные PostgreSQL (база пользователей)?" "n"; then
        run_bg "Остановка и удаление контейнеров + volumes" \
            bash -c "cd /opt/ghostwave/docker && docker compose down -v --remove-orphans"
        log_ok "Контейнеры и данные удалены"
    else
        run_bg "Остановка контейнеров (данные сохранены)" \
            bash -c "cd /opt/ghostwave/docker && docker compose down --remove-orphans"
        log_ok "Контейнеры остановлены (postgres-data volume сохранён)"
    fi

    if ask_yn "Удалить Docker образ ghostwave-panel?" "y"; then
        docker rmi ghostwave-panel:latest &>/dev/null || true
        log_ok "Образ удалён"
    fi

    if ask_yn "Удалить файлы /opt/ghostwave?" "y"; then
        rm -rf /opt/ghostwave
        log_ok "/opt/ghostwave удалён"
    fi

    # Закрываем порты Panel в файрволе
    ufw delete allow 80/tcp  >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    log_ok "Порты 80/443 закрыты в файрволе"
}

_uninstall_node() {
    echo ""
    log_step "Удаление Node"

    if [[ ! -f /opt/ghostwave-node/docker-compose.yml ]]; then
        log_warn "Node не найдена (/opt/ghostwave-node не существует)"
        return
    fi

    run_bg "Остановка Node Agent" \
        bash -c "cd /opt/ghostwave-node && docker compose down --remove-orphans"

    if ask_yn "Удалить Docker образ ghostwave-node?" "y"; then
        docker rmi ghostwave-node:latest &>/dev/null || true
        log_ok "Образ удалён"
    fi

    if ask_yn "Удалить файлы /opt/ghostwave-node и /etc/ghostnet?" "y"; then
        rm -rf /opt/ghostwave-node /etc/ghostnet
        log_ok "Файлы ноды удалены"
    fi

    # Закрываем порты ноды
    local agent_port="2095"
    [[ -f /opt/ghostwave-node/.env.node ]] && \
        agent_port=$(grep AGENT_PORT /opt/ghostwave-node/.env.node 2>/dev/null | cut -d= -f2 || echo "2095")
    ufw delete allow "${agent_port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "443/tcp"           >/dev/null 2>&1 || true
    ufw delete allow "8443/tcp"          >/dev/null 2>&1 || true
    log_ok "Порты ноды закрыты в файрволе"
}

# ─────────────────────────────────────────────────────────────────────────────
# ОБНОВЛЕНИЕ (перезапуск с пересборкой)
# ─────────────────────────────────────────────────────────────────────────────

do_restart() {
    separator
    log_step "Перезапуск / обновление"
    echo ""
    echo -e "  ${W}1)${NC} Перезапустить Panel"
    echo -e "  ${W}2)${NC} Перезапустить Node"
    echo -e "  ${W}3)${NC} Перезапустить всё"
    echo ""

    while true; do
        ask "Ваш выбор" "3"
        case "$REPLY" in
            1|3)
                if [[ -f /opt/ghostwave/docker/docker-compose.yml ]]; then
                    run_bg "Перезапуск Panel" \
                        bash -c "cd /opt/ghostwave/docker && docker compose restart"
                    log_ok "Panel перезапущена"
                else
                    log_warn "Panel не установлена"
                fi
                [[ "$REPLY" == "1" ]] && break ;;& # fallthrough для 3
            2|3)
                if [[ -f /opt/ghostwave-node/docker-compose.yml ]]; then
                    run_bg "Перезапуск Node" \
                        bash -c "cd /opt/ghostwave-node && docker compose restart"
                    log_ok "Node перезапущена"
                else
                    log_warn "Node не установлена"
                fi
                break ;;
            *) log_warn "Введите 1, 2 или 3" ;;
        esac
    done
}

show_summary() {
    separator
    log_step "Итоговая конфигурация"
    echo ""

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${W}═══ PANEL ═══${NC}"
        log_val "Директория:"   "/opt/ghostwave"
        log_val "Домен:"        "${PANEL_DOMAIN:-не задан}"
        log_val "Admin логин:"  "${ADMIN_USER:-admin}"
        log_val "Admin пароль:" "${ADMIN_PASS:0:3}****${ADMIN_PASS: -2}"
        log_val "Telegram:"     "${TG_TOKEN:0:10}… ID: ${TG_ADMIN_IDS}"
        log_val "NODE_API_KEY:" "${NODE_API_KEY:0:8}…"
        echo ""
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${W}═══ NODE ═══${NC}"
        log_val "Директория:"     "/opt/ghostwave-node"
        log_val "NODE_ID:"        "${NODE_ID:-?}"
        log_val "Panel URL:"      "${NODE_PANEL_URL:-?}"
        log_val "GhostNet домен:" "${NODE_GN_DOMAIN:-?}"
        log_val "GhostNet порт:"  "${NODE_GN_PORT:-443}"
        log_val "Agent порт:"     "${NODE_AGENT_PORT:-2095}"
        log_val "GN Secret:"      "${NODE_GN_SECRET:0:8}…"
        echo ""
    fi

    echo -e "  ${Y}Будет установлено через Docker.${NC}"
    echo ""

    if ask_yn "Всё верно? Начать установку?" "y"; then
        return 0
    else
        echo ""
        log_warn "Установка отменена"
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 6: ЗАПИСЬ КОНФИГОВ
# ─────────────────────────────────────────────────────────────────────────────

write_panel_configs() {
    log_step "Запись конфигурации Panel"
    mkdir -p /opt/ghostwave/docker
    mkdir -p /opt/ghostwave/panel

    # ── .env ──────────────────────────────────────────────────────────────
    cat > /opt/ghostwave/.env << EOF
# GhostWave Panel — $(date '+%Y-%m-%d %H:%M:%S')
DB_PASSWORD=${DB_PASSWORD}
JWT_SECRET=${JWT_SECRET}
SECRET_KEY=${SECRET_KEY}
NODE_API_KEY=${NODE_API_KEY}
ADMIN_USERNAME=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASS}
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ADMIN_IDS=${TG_ADMIN_IDS}
SUB_BASE_URL=https://${PANEL_DOMAIN}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
    chmod 600 /opt/ghostwave/.env
    log_ok ".env создан (chmod 600)"

    # ── requirements.txt (pip install через файл — надёжнее bash -c "...") ─
    cat > /opt/ghostwave/panel/requirements.txt << 'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
sqlalchemy[asyncio]==2.0.35
asyncpg==0.29.0
pydantic==2.9.2
pydantic-settings==2.5.2
bcrypt==4.2.0
pyjwt==2.9.0
redis[asyncio]==5.1.1
httpx==0.27.2
aiogram==3.13.0
psutil==6.0.0
cryptography==43.0.1
alembic==1.13.3
EOF
    log_ok "requirements.txt создан"

    # ── Dockerfile Panel ──────────────────────────────────────────────────
    cat > /opt/ghostwave/panel/Dockerfile << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 3000
CMD ["python", "main.py"]
EOF
    log_ok "Dockerfile создан"

    # ── Caddyfile ─────────────────────────────────────────────────────────
    cat > /opt/ghostwave/docker/Caddyfile << EOF
${PANEL_DOMAIN} {
    reverse_proxy /api/*  ghostwave-panel:3000
    reverse_proxy /sub/*  ghostwave-panel:3000
    reverse_proxy /health ghostwave-panel:3000
    reverse_proxy /*      ghostwave-panel:3000
    log {
        output file /var/log/caddy/access.log
        format json
    }
}
EOF
    log_ok "Caddyfile создан"

    # ── docker-compose.yml ────────────────────────────────────────────────
    # ВАЖНО: используем EOF без кавычек чтобы раскрыть переменные Shell
    # Но внутри YAML ${} нужно экранировать как $${} для Docker Compose
    cat > /opt/ghostwave/docker/docker-compose.yml << EOF
services:
  panel:
    build:
      context: /opt/ghostwave/panel
      dockerfile: Dockerfile
    image: ghostwave-panel:latest
    container_name: ghostwave-panel
    restart: unless-stopped
    environment:
      DATABASE_URL: "postgresql+asyncpg://ghostwave:${DB_PASSWORD}@postgres:5432/ghostwave"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@redis:6379/0"
      JWT_SECRET: "${JWT_SECRET}"
      SECRET_KEY: "${SECRET_KEY}"
      NODE_API_KEY: "${NODE_API_KEY}"
      ADMIN_USERNAME: "${ADMIN_USER}"
      ADMIN_PASSWORD: "${ADMIN_PASS}"
      TELEGRAM_BOT_TOKEN: "${TG_TOKEN}"
      TELEGRAM_ADMIN_IDS: "${TG_ADMIN_IDS}"
      SUB_BASE_URL: "https://${PANEL_DOMAIN}"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - ghostwave-net

  postgres:
    image: postgres:16-alpine
    container_name: ghostwave-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ghostwave
      POSTGRES_USER: ghostwave
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - ghostwave-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ghostwave"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: ghostwave-redis
    restart: unless-stopped
    command: redis-server --requirepass "${REDIS_PASSWORD}"
    networks:
      - ghostwave-net
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  caddy:
    image: caddy:2-alpine
    container_name: ghostwave-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/ghostwave/docker/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - ghostwave-net
    depends_on:
      - panel

volumes:
  postgres-data:
  caddy-data:
  caddy-config:

networks:
  ghostwave-net:
    driver: bridge
EOF
    log_ok "docker-compose.yml создан"
}

write_node_configs() {
    log_step "Запись конфигурации Node"
    mkdir -p /opt/ghostwave-node/node
    mkdir -p /etc/ghostnet

    # В режиме panel+node порт 443 уже занят Caddy — используем 8443
    local effective_gn_port="${NODE_GN_PORT:-443}"
    if [[ "$INSTALL_MODE" == "panel+node" && "$effective_gn_port" == "443" ]]; then
        effective_gn_port="8443"
        log_warn "Режим panel+node: порт 443 занят Caddy, GhostNet переключён на 8443"
        NODE_GN_PORT="8443"
        # Открываем новый порт в файрволе
        ufw allow 8443/tcp comment "GhostNet VPN (panel+node)" >/dev/null 2>&1 || true
    fi

    # ── .env.node ─────────────────────────────────────────────────────────
    cat > /opt/ghostwave-node/.env.node << EOF
# GhostWave Node — $(date '+%Y-%m-%d %H:%M:%S')
NODE_ID=${NODE_ID}
NODE_API_KEY=${NODE_PANEL_KEY:-${NODE_API_KEY}}
PANEL_URL=${NODE_PANEL_URL:-https://${PANEL_DOMAIN}}
AGENT_PORT=${NODE_AGENT_PORT}
AGENT_HOST=0.0.0.0
GHOSTNET_PORT=${effective_gn_port}
GHOSTNET_DOMAIN=${NODE_GN_DOMAIN}
GHOSTNET_SECRET=${NODE_GN_SECRET}
HEARTBEAT_INTERVAL=15
TRAFFIC_REPORT_INTERVAL=60
EOF
    chmod 600 /opt/ghostwave-node/.env.node
    log_ok ".env.node создан (chmod 600)"

    # ── GhostNet config ────────────────────────────────────────────────────
    cat > /etc/ghostnet/config.json << EOF
{
  "secret":        "${NODE_GN_SECRET}",
  "domain":        "${NODE_GN_DOMAIN}",
  "port":          ${effective_gn_port},
  "allowed_users": [],
  "tun_network":   "10.8.0.0/24",
  "time_window":   30,
  "log_level":     "info"
}
EOF
    chmod 600 /etc/ghostnet/config.json
    log_ok "/etc/ghostnet/config.json создан"

    # ── requirements.txt для агента ───────────────────────────────────────
    cat > /opt/ghostwave-node/node/requirements.txt << 'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
pydantic==2.9.2
pydantic-settings==2.5.2
psutil==6.0.0
cryptography==43.0.1
EOF

    # ── Dockerfile Node ───────────────────────────────────────────────────
    cat > /opt/ghostwave-node/node/Dockerfile << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc iproute2 iptables && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EOF
    log_ok "Dockerfile для агента создан"

    # ── docker-compose.yml ────────────────────────────────────────────────
    local agent_port="${NODE_AGENT_PORT:-2095}"
    cat > /opt/ghostwave-node/docker-compose.yml << EOF
services:
  node-agent:
    build:
      context: /opt/ghostwave-node/node
      dockerfile: Dockerfile
    image: ghostwave-node:latest
    container_name: ghostwave-node
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    working_dir: /app
    command: uvicorn agent:agent_app --host 0.0.0.0 --port ${agent_port}
    environment:
      NODE_ID: "${NODE_ID}"
      NODE_API_KEY: "${NODE_PANEL_KEY:-${NODE_API_KEY}}"
      PANEL_URL: "${NODE_PANEL_URL:-https://${PANEL_DOMAIN}}"
      AGENT_PORT: "${agent_port}"
      GHOSTNET_PORT: "${effective_gn_port}"
      GHOSTNET_DOMAIN: "${NODE_GN_DOMAIN}"
      GHOSTNET_SECRET: "${NODE_GN_SECRET}"
    volumes:
      - /etc/ghostnet:/etc/ghostnet
EOF
    log_ok "docker-compose.yml для ноды создан"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 7: ЗАПУСК
# ─────────────────────────────────────────────────────────────────────────────

start_panel_services() {
    log_step "Запуск сервисов Panel"
    cd /opt/ghostwave/docker

    # Сборка образа Panel (pip install происходит здесь, один раз)
    run_bg "Сборка образа Panel (установка зависимостей)" \
        docker compose build panel

    run_bg "Загрузка образов PostgreSQL, Redis, Caddy" \
        docker compose pull postgres redis caddy

    run_bg "Запуск PostgreSQL + Redis" \
        docker compose up -d postgres redis

    echo -ne "  ${ARROW} ${D}Ожидание готовности PostgreSQL...${NC}"
    local attempts=0
    while (( attempts < 30 )); do
        local pg_ok=0
        docker exec ghostwave-postgres pg_isready -U ghostwave &>/dev/null \
            && pg_ok=1 || true
        if [[ $pg_ok -eq 1 ]]; then
            echo -e "\r  ${CHECK} PostgreSQL готов                    "
            break
        fi
        sleep 2
        (( attempts++ )) || true
        printf "\r  ${C}⠋${NC} ${D}Ожидание PostgreSQL... %ds${NC}" "$((attempts * 2))"
    done

    run_bg "Запуск Panel + Caddy" \
        docker compose up -d panel caddy

    echo -ne "  ${ARROW} ${D}Ожидание запуска Panel...${NC}"
    attempts=0
    while (( attempts < 40 )); do
        local panel_ok=0
        curl -sf --max-time 2 http://localhost:3000/health &>/dev/null \
            && panel_ok=1 || true
        if [[ $panel_ok -eq 1 ]]; then
            echo -e "\r  ${CHECK} Panel запущена                      "
            break
        fi
        sleep 3
        (( attempts++ )) || true
        printf "\r  ${C}⠋${NC} ${D}Ожидание Panel... %ds${NC}" "$((attempts * 3))"
    done
    if (( attempts >= 40 )); then
        echo -e "\r  ${WARN} ${Y}Panel не ответила за 120с — проверьте логи${NC}"
    fi
}

start_node_services() {
    log_step "Запуск Node Agent"
    cd /opt/ghostwave-node

    run_bg "Сборка образа Node Agent" docker compose build node-agent
    run_bg "Запуск Node Agent"        docker compose up -d

    local agent_port="${NODE_AGENT_PORT:-2095}"
    echo -ne "  ${ARROW} ${D}Ожидание Node Agent...${NC}"
    local attempts=0
    while (( attempts < 30 )); do
        local agent_ok=0
        curl -sf --max-time 2 "http://localhost:${agent_port}/health" &>/dev/null \
            && agent_ok=1 || true
        if [[ $agent_ok -eq 1 ]]; then
            echo -e "\r  ${CHECK} Node Agent запущен                  "
            break
        fi
        sleep 3
        (( attempts++ )) || true
        printf "\r  ${C}⠋${NC} ${D}Ожидание агента... %ds${NC}" "$((attempts * 3))"
    done
    if (( attempts >= 30 )); then
        echo -e "\r  ${WARN} ${Y}Node Agent не ответил — проверьте docker logs ghostwave-node${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 8: ФИНАЛЬНАЯ ПРОВЕРКА И ОТЧЁТ
# ─────────────────────────────────────────────────────────────────────────────

final_checks() {
    separator
    log_step "Финальная проверка"
    echo ""

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        local h=""
        h=$(curl -sf --max-time 5 "http://localhost:3000/health" 2>/dev/null) || h=""
        if echo "$h" | grep -q '"ok"'; then
            log_ok "Panel API (localhost:3000): ${G}OK${NC}"
        else
            log_warn "Panel API: не отвечает — проверьте docker logs ghostwave-panel"
        fi

        local hh=""
        hh=$(curl -sf --max-time 8 "https://${PANEL_DOMAIN}/health" 2>/dev/null) || hh=""
        if echo "$hh" | grep -q '"ok"'; then
            log_ok "HTTPS (${PANEL_DOMAIN}): ${G}OK${NC}"
        else
            log_warn "HTTPS: ещё не готов (SSL получается, подождите ~1 минуту)"
        fi

        local pg_ok=0
        docker exec ghostwave-postgres pg_isready -U ghostwave &>/dev/null && pg_ok=1 || true
        [[ $pg_ok -eq 1 ]] && log_ok "PostgreSQL: ${G}OK${NC}" || log_warn "PostgreSQL: нет ответа"

        local redis_ok=0
        docker exec ghostwave-redis redis-cli -a "$REDIS_PASSWORD" ping &>/dev/null && redis_ok=1 || true
        [[ $redis_ok -eq 1 ]] && log_ok "Redis: ${G}OK${NC}" || log_warn "Redis: нет ответа"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        local agent_port="${NODE_AGENT_PORT:-2095}"
        local ah=""
        ah=$(curl -sf --max-time 5 "http://localhost:${agent_port}/health" 2>/dev/null) || ah=""
        if echo "$ah" | grep -q '"ok"'; then
            log_ok "Node Agent (порт ${agent_port}): ${G}OK${NC}"
        else
            log_warn "Node Agent: не отвечает — проверьте docker logs ghostwave-node"
        fi
    fi
}

show_final_summary() {
    separator
    echo ""
    echo -e "${G}${BOLD}"
    cat << 'EOF'
   ╔═══════════════════════════════════════╗
   ║   Установка успешно завершена! ✓     ║
   ╚═══════════════════════════════════════╝
EOF
    echo -e "${NC}"

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${W}════ PANEL ════${NC}\n"
        log_val "🌐 URL:"             "https://${PANEL_DOMAIN}"
        log_val "📖 API Docs:"        "https://${PANEL_DOMAIN}/api/docs"
        log_val "👤 Логин:"           "$ADMIN_USER"
        log_val "🔑 Пароль:"          "$ADMIN_PASS"
        echo ""
        echo -e "  ${Y}NODE_API_KEY (сохраните для нод):${NC}"
        echo -e "  ${W}${NODE_API_KEY}${NC}"
        echo ""
        echo -e "  ${D}Конфиг:  /opt/ghostwave/.env${NC}"
        echo -e "  ${D}Логи:    docker logs ghostwave-panel -f${NC}"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo ""
        echo -e "  ${W}════ NODE ════${NC}\n"
        log_val "🖥️  NODE_ID:"    "$NODE_ID"
        log_val "📡 Agent:"       "http://${SERVER_IP}:${NODE_AGENT_PORT}"
        log_val "🔒 GN домен:"    "$NODE_GN_DOMAIN"
        log_val "⚙️  GN порт:"    "$NODE_GN_PORT"
        echo ""
        echo -e "  ${D}Конфиг:  /opt/ghostwave-node/.env.node${NC}"
        echo -e "  ${D}Логи:    docker logs ghostwave-node -f${NC}"
    fi

    separator

    # Сохраняем отчёт
    local REPORT_FILE="/root/ghostwave-install-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "GhostWave Installation Report"
        echo "Date: $(date)"
        echo "Mode: $INSTALL_MODE"
        echo "Server IP: $SERVER_IP"
        echo ""
        if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
            echo "[PANEL]"
            echo "URL: https://${PANEL_DOMAIN}"
            echo "Admin: $ADMIN_USER / $ADMIN_PASS"
            echo "NODE_API_KEY: $NODE_API_KEY"
            echo "DB_PASSWORD: $DB_PASSWORD"
            echo "JWT_SECRET: $JWT_SECRET"
            echo "REDIS_PASSWORD: $REDIS_PASSWORD"
        fi
        if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
            echo ""
            echo "[NODE]"
            echo "NODE_ID: $NODE_ID"
            echo "NODE_API_KEY used: $NODE_PANEL_KEY"
            echo "GhostNet domain: $NODE_GN_DOMAIN"
            echo "GhostNet secret: $NODE_GN_SECRET"
        fi
    } > "$REPORT_FILE"
    chmod 600 "$REPORT_FILE"

    echo -e "  ${CHECK} Отчёт сохранён: ${W}${REPORT_FILE}${NC}"
    echo -e "  ${Y}Храните его в безопасном месте!${NC}"
    echo ""

    echo -e "  ${D}Полезные команды:${NC}"
    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${C}docker compose -f /opt/ghostwave/docker/docker-compose.yml logs -f${NC}"
        echo -e "  ${C}docker compose -f /opt/ghostwave/docker/docker-compose.yml restart${NC}"
    fi
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${C}docker logs ghostwave-node -f${NC}"
        echo -e "  ${C}docker restart ghostwave-node${NC}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ГЛАВНЫЙ ПОТОК
# ─────────────────────────────────────────────────────────────────────────────

main() {
    show_banner
    check_system
    pause
    choose_mode

    # Короткий путь для удаления и перезапуска
    if [[ "$INSTALL_MODE" == "uninstall" ]]; then
        uninstall
        exit 0
    fi
    if [[ "$INSTALL_MODE" == "restart" ]]; then
        do_restart
        exit 0
    fi

    # Зависимости
    separator
    if ask_yn "Установить/обновить зависимости (Docker и др.)?" "y"; then
        install_deps
    else
        log_info "Пропуск установки зависимостей"
    fi

    # Сбор конфигурации в зависимости от режима
    if [[ "$INSTALL_MODE" == "panel" ]]; then
        collect_panel_config

    elif [[ "$INSTALL_MODE" == "node" ]]; then
        collect_node_config

    elif [[ "$INSTALL_MODE" == "panel+node" ]]; then
        collect_panel_config

        separator
        log_step "Конфигурация Node (локальная)"
        echo ""
        echo -e "  ${D}Нода будет подключена к только что настроенной Panel.${NC}"
        echo ""

        NODE_PANEL_URL="https://${PANEL_DOMAIN}"
        NODE_PANEL_KEY="$NODE_API_KEY"
        NODE_ID="1"

        while true; do
            ask "Домен маскировки GhostNet (например news.${PANEL_DOMAIN})"
            NODE_GN_DOMAIN="$REPLY"
            [[ -n "$NODE_GN_DOMAIN" ]] && break
            log_warn "Домен не может быть пустым"
        done

        ask "Порт GhostNet (443 будет заменён на 8443, т.к. занят Caddy)" "443"
        NODE_GN_PORT="$REPLY"

        ask "Порт Node Agent" "2095"
        NODE_AGENT_PORT="$REPLY"

        printf "  ${ARROW} ${D}Генерируем GhostNet secret...${NC}"
        NODE_GN_SECRET=$(gen_secret)
        printf "\r  ${CHECK} GhostNet secret сгенерирован\n"
    fi

    # Файрвол
    setup_firewall

    # Подтверждение
    show_summary

    # Запись конфигов
    separator
    log_step "Создание файлов конфигурации"

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        write_panel_configs
    fi
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        write_node_configs
    fi

    # Запуск
    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        start_panel_services
    fi
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        start_node_services
    fi

    # Проверка и итог
    final_checks
    show_final_summary
}

main "$@"
