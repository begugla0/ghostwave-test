#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║              GhostWave — Unified Installer v1.0                        ║
# ║              Единый установщик Panel + Node                            ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Использование:
#   bash install.sh
#
# Поддерживаемые ОС: Ubuntu 20.04+, Debian 11+

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# ЦВЕТА И ФОРМАТИРОВАНИЕ
# ─────────────────────────────────────────────────────────────────────────────

R='\033[0;31m'   # Red
G='\033[0;32m'   # Green
Y='\033[0;33m'   # Yellow
B='\033[0;34m'   # Blue
C='\033[0;36m'   # Cyan
W='\033[1;37m'   # White bold
D='\033[2m'      # Dim
NC='\033[0m'     # Reset
BOLD='\033[1m'
CHECK="${G}✔${NC}"
CROSS="${R}✘${NC}"
ARROW="${C}›${NC}"
WARN="${Y}⚠${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (заполняются по ходу установки)
# ─────────────────────────────────────────────────────────────────────────────

INSTALL_MODE=""          # "panel" или "node"
INSTALL_DIR=""
SERVER_IP=""

# Panel vars
PANEL_DOMAIN=""
ADMIN_USER=""
ADMIN_PASS=""
DB_PASSWORD=""
JWT_SECRET=""
SECRET_KEY=""
NODE_API_KEY=""
REDIS_PASSWORD=""
TG_TOKEN=""
TG_ADMIN_IDS=""

# Node vars
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
    # ask "Вопрос" "default" → в $REPLY
    local prompt="$1"
    local default="${2:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${D}[${default}]${NC}"
    echo -ne "  ${ARROW} ${W}${prompt}${NC}${hint}: "
    read -r REPLY
    [[ -z "$REPLY" && -n "$default" ]] && REPLY="$default"
}

ask_secret() {
    local prompt="$1"
    echo -ne "  ${ARROW} ${W}${prompt}${NC}: "
    read -rs REPLY
    echo ""
}

ask_yn() {
    # ask_yn "Вопрос" "y" → 0=yes 1=no
    local prompt="$1"
    local default="${2:-y}"
    local hint
    [[ "$default" == "y" ]] && hint="${G}Y${NC}/${D}n${NC}" || hint="${D}y${NC}/${G}N${NC}"
    echo -ne "  ${ARROW} ${W}${prompt}${NC} [${hint}]: "
    read -r REPLY
    REPLY="${REPLY:-$default}"
    [[ "${REPLY,,}" == "y" ]]
}

gen_secret() {
    python3 -c "import secrets; print(secrets.token_hex(32))"
}

gen_password() {
    python3 -c "import secrets,string; chars=string.ascii_letters+string.digits+'!@#\$%'; print(''.join(secrets.choice(chars) for _ in range(24)))"
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
    # run_bg "сообщение" команда...
    local msg="$1"; shift
    "$@" &>/tmp/gw_install_last.log &
    local pid=$!
    spinner "$pid" "$msg"
    wait "$pid" || {
        log_err "Ошибка при: $msg"
        echo -e "  ${D}Подробности: $(cat /tmp/gw_install_last.log | tail -5)${NC}"
        exit 1
    }
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
    echo -e "  ${W}Unified Installer v1.0${NC}  ${D}— Panel & Node${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 0: ПРОВЕРКА СИСТЕМЫ
# ─────────────────────────────────────────────────────────────────────────────

check_system() {
    log_step "Проверка системы"

    # Root
    if [[ $EUID -ne 0 ]]; then
        log_err "Установщик должен быть запущен от root"
        echo -e "\n  Используйте: ${W}sudo bash install.sh${NC}\n"
        exit 1
    fi
    log_ok "Запущен от root"

    # ОС
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$ID"
        OS_VER="$VERSION_ID"
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            log_ok "ОС: $PRETTY_NAME"
        else
            log_warn "ОС $PRETTY_NAME не тестировалась. Продолжаем на свой риск."
        fi
    else
        log_warn "Не удалось определить ОС"
    fi

    # Архитектура
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]]; then
        log_ok "Архитектура: $ARCH"
    else
        log_err "Неподдерживаемая архитектура: $ARCH"
        exit 1
    fi

    # RAM
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if (( RAM_MB < 450 )); then
        log_err "Недостаточно RAM: ${RAM_MB}MB (нужно минимум 512MB)"
        exit 1
    fi
    log_ok "RAM: ${RAM_MB}MB"

    # Диск
    DISK_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    if (( DISK_GB < 5 )); then
        log_warn "Свободного места: ${DISK_GB}GB (рекомендуется 10GB+)"
    else
        log_ok "Свободное место: ${DISK_GB}GB"
    fi

    # Интернет
    if curl -sf --max-time 5 https://google.com >/dev/null 2>&1; then
        log_ok "Интернет-соединение: OK"
    else
        log_err "Нет доступа к интернету"
        exit 1
    fi

    # Определяем IP сервера
    SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')
    log_ok "IP сервера: ${W}${SERVER_IP}${NC}"

    # Python3
    if command -v python3 &>/dev/null; then
        PYTHON_VER=$(python3 --version 2>&1 | awk '{print $2}')
        log_ok "Python3: $PYTHON_VER"
    else
        log_err "Python3 не найден (нужен для генерации ключей)"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 1: ВЫБОР РЕЖИМА УСТАНОВКИ
# ─────────────────────────────────────────────────────────────────────────────

choose_mode() {
    separator
    log_step "Выбор режима установки"
    echo ""
    echo -e "  Что устанавливаем на этот сервер?\n"
    echo -e "  ${W}1)${NC} ${G}Panel${NC}   — управляющий сервер (API, база данных, Telegram бот)"
    echo -e "           Один на всю инфраструктуру. Не обязательно вне РФ.\n"
    echo -e "  ${W}2)${NC} ${C}Node${NC}    — VPN-сервер (GhostNet daemon + агент)"
    echo -e "           По одному на каждый VPN-сервер. Желательно за рубежом.\n"
    echo -e "  ${W}3)${NC} ${Y}Panel + Node${NC} — всё на одном сервере (для тестирования)\n"

    while true; do
        ask "Ваш выбор" "1"
        case "$REPLY" in
            1) INSTALL_MODE="panel";      break ;;
            2) INSTALL_MODE="node";       break ;;
            3) INSTALL_MODE="panel+node"; break ;;
            *) log_warn "Введите 1, 2 или 3" ;;
        esac
    done

    case "$INSTALL_MODE" in
        panel)      log_ok "Режим: ${G}Panel${NC}" ;;
        node)       log_ok "Режим: ${C}Node${NC}" ;;
        panel+node) log_ok "Режим: ${Y}Panel + Node${NC}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 2: УСТАНОВКА ЗАВИСИМОСТЕЙ
# ─────────────────────────────────────────────────────────────────────────────

install_deps() {
    separator
    log_step "Установка зависимостей"

    # apt update
    run_bg "Обновление пакетов" apt-get update -qq

    # Базовые утилиты
    run_bg "Установка базовых утилит" \
        apt-get install -y -qq curl wget git ufw net-tools dnsutils

    # Docker
    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
        log_ok "Docker уже установлен: $DOCKER_VER"
    else
        run_bg "Установка Docker" bash -c "curl -fsSL https://get.docker.com | sh"
        run_bg "Запуск Docker" bash -c "systemctl enable docker && systemctl start docker"
        log_ok "Docker установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
    fi

    # Docker Compose v2
    if docker compose version &>/dev/null 2>&1; then
        log_ok "Docker Compose v2: $(docker compose version --short)"
    else
        run_bg "Установка Docker Compose" \
            apt-get install -y -qq docker-compose-plugin
        log_ok "Docker Compose установлен"
    fi

    # Для node: iproute2 и iptables для TUN
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        run_bg "Установка сетевых инструментов (TUN)" \
            apt-get install -y -qq iproute2 iptables
        log_ok "Сетевые инструменты установлены"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 3: НАСТРОЙКА ФАЙРВОЛА
# ─────────────────────────────────────────────────────────────────────────────

setup_firewall() {
    separator
    log_step "Настройка файрвола (ufw)"

    # Разрешаем SSH (не закрываем сами себя!)
    ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
    log_ok "Порт 22 (SSH) — открыт"

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        ufw allow 80/tcp  comment "HTTP (Caddy ACME)" >/dev/null 2>&1
        ufw allow 443/tcp comment "HTTPS (Panel)" >/dev/null 2>&1
        log_ok "Порты 80, 443 (Panel HTTPS) — открыты"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        ufw allow "${NODE_GN_PORT}/tcp"   comment "GhostNet VPN" >/dev/null 2>&1
        ufw allow "${NODE_AGENT_PORT}/tcp" comment "GhostWave Node Agent" >/dev/null 2>&1
        log_ok "Порт ${NODE_GN_PORT} (GhostNet) — открыт"
        log_ok "Порт ${NODE_AGENT_PORT} (Node Agent) — открыт"

        if [[ -n "${NODE_PANEL_URL:-}" ]]; then
            # Пытаемся ограничить агент-порт только для IP панели
            PANEL_HOST=$(echo "$NODE_PANEL_URL" | sed 's~https\?://~~' | cut -d/ -f1)
            PANEL_IP=$(dig +short "$PANEL_HOST" 2>/dev/null | head -1)
            if [[ -n "$PANEL_IP" ]]; then
                ufw delete allow "${NODE_AGENT_PORT}/tcp" >/dev/null 2>&1 || true
                ufw allow from "$PANEL_IP" to any port "$NODE_AGENT_PORT" proto tcp \
                    comment "GhostWave Agent (Panel only)" >/dev/null 2>&1
                log_ok "Порт ${NODE_AGENT_PORT} ограничен: только с IP Panel ($PANEL_IP)"
            fi
        fi
    fi

    # Включаем ufw
    ufw --force enable >/dev/null 2>&1
    log_ok "Файрвол активирован"

    echo ""
    ufw status numbered 2>/dev/null | grep -v "^Status\|^To\|^--" | \
        while IFS= read -r line; do echo -e "  ${D}$line${NC}"; done
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 4 (PANEL): СБОР ДАННЫХ ДЛЯ ПАНЕЛИ
# ─────────────────────────────────────────────────────────────────────────────

collect_panel_config() {
    separator
    log_step "Конфигурация Panel"

    # ── Домен ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${W}Домен панели${NC}"
    echo -e "  ${D}Нужна A-запись в DNS: panel.yourdomain.com → ${SERVER_IP}${NC}"
    echo ""

    while true; do
        ask "Домен панели (например panel.example.com)"
        PANEL_DOMAIN="$REPLY"

        if [[ -z "$PANEL_DOMAIN" ]]; then
            log_warn "Домен не может быть пустым"
            continue
        fi

        # Проверка DNS
        echo -ne "  ${ARROW} ${D}Проверяем DNS для ${PANEL_DOMAIN}...${NC}"
        RESOLVED_IP=$(dig +short "$PANEL_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)

        if [[ -z "$RESOLVED_IP" ]]; then
            echo -e "\r  ${CROSS} ${R}DNS не разрешается. Не найдена A-запись для ${PANEL_DOMAIN}${NC}"
            echo ""
            echo -e "  ${Y}Добавьте A-запись в панели вашего DNS-провайдера:${NC}"
            echo -e "  ${W}Имя:${NC} $PANEL_DOMAIN  ${W}Тип:${NC} A  ${W}Значение:${NC} ${SERVER_IP}"
            echo ""
            if ask_yn "Уже добавили? Попробовать снова?" "y"; then
                continue
            else
                if ask_yn "Продолжить без проверки DNS (небезопасно)?" "n"; then
                    log_warn "Продолжаем без проверки DNS"
                    break
                fi
                continue
            fi
        elif [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
            echo -e "\r  ${CHECK} DNS проверен: ${PANEL_DOMAIN} → ${G}${RESOLVED_IP}${NC} ✓"
            break
        else
            echo -e "\r  ${WARN} ${Y}DNS указывает на ${RESOLVED_IP}, а не на ${SERVER_IP}${NC}"
            echo ""
            echo -e "  Возможные причины:"
            echo -e "  ${D}• DNS ещё не обновился (подождите 1-5 минут)${NC}"
            echo -e "  ${D}• A-запись указывает на другой IP${NC}"
            echo ""
            if ask_yn "Продолжить несмотря на расхождение IP?" "n"; then
                log_warn "Продолжаем с расхождением DNS (Caddy может не получить SSL)"
                break
            fi
            continue
        fi
    done

    # ── Telegram Bot ───────────────────────────────────────────────────────
    separator
    echo -e "  ${W}Telegram бот${NC} ${D}(опционально, можно настроить позже)${NC}"
    echo ""
    echo -e "  ${D}Как получить токен:${NC}"
    echo -e "  ${D}1. Написать @BotFather в Telegram${NC}"
    echo -e "  ${D}2. /newbot → придумать имя → скопировать токен${NC}"
    echo ""

    if ask_yn "Настроить Telegram бота сейчас?" "y"; then
        ask "Токен бота (@BotFather)" ""
        TG_TOKEN="$REPLY"

        if [[ -n "$TG_TOKEN" ]]; then
            # Проверка токена
            echo -ne "  ${ARROW} ${D}Проверяем токен бота...${NC}"
            BOT_CHECK=$(curl -sf --max-time 5 \
                "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo "")
            if echo "$BOT_CHECK" | grep -q '"ok":true'; then
                BOT_NAME=$(echo "$BOT_CHECK" | python3 -c \
                    "import sys,json; d=json.load(sys.stdin); print(d['result']['username'])" 2>/dev/null || echo "?")
                echo -e "\r  ${CHECK} Бот проверен: ${G}@${BOT_NAME}${NC}"
            else
                echo -e "\r  ${WARN} ${Y}Не удалось проверить токен. Проверьте правильность.${NC}"
            fi

            echo ""
            echo -e "  ${D}Ваш Telegram ID (узнать: написать @userinfobot):${NC}"
            ask "Ваш Telegram ID (Admin ID)" ""
            TG_ADMIN_IDS="[${REPLY}]"
            log_ok "Telegram ID: ${REPLY}"
        fi
    else
        TG_TOKEN=""
        TG_ADMIN_IDS="[]"
        log_info "Telegram пропущен. Настроите позже в .env"
    fi

    # ── Администратор ──────────────────────────────────────────────────────
    separator
    echo -e "  ${W}Учётная запись администратора панели${NC}"
    echo ""

    ask "Логин администратора" "admin"
    ADMIN_USER="$REPLY"

    while true; do
        ask_secret "Пароль администратора (минимум 8 символов)"
        ADMIN_PASS_1="$REPLY"
        if [[ ${#ADMIN_PASS_1} -lt 8 ]]; then
            log_warn "Пароль слишком короткий (минимум 8 символов)"
            continue
        fi
        ask_secret "Повторите пароль"
        if [[ "$ADMIN_PASS_1" == "$REPLY" ]]; then
            ADMIN_PASS="$ADMIN_PASS_1"
            log_ok "Пароль установлен"
            break
        else
            log_warn "Пароли не совпадают, попробуйте снова"
        fi
    done

    # ── Генерация секретов ─────────────────────────────────────────────────
    separator
    echo -e "  ${W}Генерация криптографических ключей${NC}"
    echo ""

    echo -ne "  ${ARROW} ${D}Генерируем DB_PASSWORD...${NC}"
    DB_PASSWORD=$(gen_password)
    echo -e "\r  ${CHECK} DB_PASSWORD    ${D}(32 символа)${NC}"

    echo -ne "  ${ARROW} ${D}Генерируем JWT_SECRET...${NC}"
    JWT_SECRET=$(gen_secret)
    echo -e "\r  ${CHECK} JWT_SECRET     ${D}(64 hex символа)${NC}"

    echo -ne "  ${ARROW} ${D}Генерируем SECRET_KEY...${NC}"
    SECRET_KEY=$(gen_secret)
    echo -e "\r  ${CHECK} SECRET_KEY     ${D}(64 hex символа)${NC}"

    echo -ne "  ${ARROW} ${D}Генерируем NODE_API_KEY...${NC}"
    NODE_API_KEY=$(gen_secret)
    echo -e "\r  ${CHECK} NODE_API_KEY   ${D}(64 hex символа)${NC}"

    echo -ne "  ${ARROW} ${D}Генерируем REDIS_PASSWORD...${NC}"
    REDIS_PASSWORD=$(gen_password)
    echo -e "\r  ${CHECK} REDIS_PASSWORD ${D}(32 символа)${NC}"

    log_ok "Все ключи сгенерированы"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 4 (NODE): СБОР ДАННЫХ ДЛЯ НОДЫ
# ─────────────────────────────────────────────────────────────────────────────

collect_node_config() {
    separator
    log_step "Конфигурация Node"

    # ── Данные Panel ───────────────────────────────────────────────────────
    echo ""
    echo -e "  ${W}Подключение к Panel${NC}"
    echo -e "  ${D}Эти данные берутся из установленной Panel${NC}"
    echo ""

    while true; do
        ask "URL панели (например https://panel.example.com)"
        NODE_PANEL_URL="${REPLY%/}"  # убираем trailing slash

        if [[ "$NODE_PANEL_URL" != https://* && "$NODE_PANEL_URL" != http://* ]]; then
            log_warn "URL должен начинаться с https:// или http://"
            continue
        fi

        # Проверка доступности панели
        echo -ne "  ${ARROW} ${D}Проверяем доступность панели...${NC}"
        HEALTH=$(curl -sf --max-time 8 "${NODE_PANEL_URL}/health" 2>/dev/null || echo "")
        if echo "$HEALTH" | grep -q '"status":"ok"'; then
            PANEL_VER=$(echo "$HEALTH" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
            echo -e "\r  ${CHECK} Панель доступна: ${G}${NODE_PANEL_URL}${NC} (v${PANEL_VER})"
            break
        else
            echo -e "\r  ${CROSS} ${R}Панель недоступна: ${NODE_PANEL_URL}${NC}"
            log_info "Убедитесь что Panel запущена и домен правильный"
            if ask_yn "Попробовать другой URL?" "y"; then
                continue
            else
                log_warn "Продолжаем без проверки панели"
                break
            fi
        fi
    done

    # NODE_API_KEY
    echo ""
    echo -e "  ${D}NODE_API_KEY можно найти в файле /opt/ghostwave/.env на сервере панели${NC}"
    while true; do
        ask "NODE_API_KEY с Panel-сервера"
        NODE_PANEL_KEY="$REPLY"
        if [[ ${#NODE_PANEL_KEY} -ge 32 ]]; then
            log_ok "NODE_API_KEY принят"
            break
        else
            log_warn "Ключ слишком короткий (ожидается 64 символа hex)"
            if ask_yn "Продолжить с этим ключом?" "n"; then break; fi
        fi
    done

    # NODE_ID (нужно создать ноду в панели)
    separator
    echo -e "  ${W}Регистрация ноды в Panel${NC}"
    echo ""
    echo -e "  Создайте ноду в панели с помощью API или Telegram бота,"
    echo -e "  затем введите полученный NODE_ID."
    echo ""
    echo -e "  ${D}Или создадим сейчас через API Panel:${NC}"
    echo ""

    if ask_yn "Создать ноду в панели автоматически?" "y"; then
        _create_node_via_api
    else
        ask "NODE_ID (число из панели)" "1"
        NODE_ID="$REPLY"
    fi

    # ── GhostNet параметры ─────────────────────────────────────────────────
    separator
    echo -e "  ${W}GhostNet параметры${NC}"
    echo ""
    echo -e "  ${D}Домен для маскировки — сервер будет прикидываться этим сайтом.${NC}"
    echo -e "  ${D}Должен быть реальный домен с A-записью на IP этого сервера.${NC}"
    echo ""

    while true; do
        ask "Домен для маскировки (например news.example.com)"
        NODE_GN_DOMAIN="$REPLY"

        if [[ -z "$NODE_GN_DOMAIN" ]]; then
            log_warn "Домен не может быть пустым"
            continue
        fi

        # Проверка DNS
        echo -ne "  ${ARROW} ${D}Проверяем DNS для ${NODE_GN_DOMAIN}...${NC}"
        GN_RESOLVED=$(dig +short "$NODE_GN_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)

        if [[ -z "$GN_RESOLVED" ]]; then
            echo -e "\r  ${WARN} ${Y}DNS не разрешается для ${NODE_GN_DOMAIN}${NC}"
            if ask_yn "Всё равно использовать этот домен?" "y"; then break; fi
            continue
        elif [[ "$GN_RESOLVED" == "$SERVER_IP" ]]; then
            echo -e "\r  ${CHECK} DNS: ${NODE_GN_DOMAIN} → ${G}${GN_RESOLVED}${NC} ✓"
            break
        else
            echo -e "\r  ${WARN} ${Y}${NODE_GN_DOMAIN} → ${GN_RESOLVED} (не совпадает с ${SERVER_IP})${NC}"
            log_info "Для полной маскировки домен должен указывать на этот сервер"
            if ask_yn "Всё равно использовать?" "y"; then break; fi
            continue
        fi
    done

    # Порт GhostNet
    ask "Порт GhostNet (рекомендуется 443)" "443"
    NODE_GN_PORT="$REPLY"

    # Порт агента
    ask "Порт Node Agent API (для связи с Panel)" "2095"
    NODE_AGENT_PORT="$REPLY"

    # Генерация GhostNet секрета
    echo ""
    echo -ne "  ${ARROW} ${D}Генерируем GhostNet shared secret...${NC}"
    NODE_GN_SECRET=$(gen_secret)
    echo -e "\r  ${CHECK} GhostNet secret сгенерирован"

    log_ok "Конфигурация ноды собрана"
}

_create_node_via_api() {
    # Создаём ноду через REST API Panel
    echo ""
    ask "Логин администратора Panel" "admin"
    local api_user="$REPLY"
    ask_secret "Пароль администратора Panel"
    local api_pass="$REPLY"

    echo ""
    echo -ne "  ${ARROW} ${D}Получаем JWT токен...${NC}"
    local token_resp
    token_resp=$(curl -sf --max-time 10 \
        -X POST "${NODE_PANEL_URL}/api/auth/login" \
        -F "username=${api_user}" \
        -F "password=${api_pass}" 2>/dev/null || echo "")

    if ! echo "$token_resp" | grep -q '"access_token"'; then
        echo -e "\r  ${CROSS} ${R}Не удалось авторизоваться в панели${NC}"
        ask "Введите NODE_ID вручную" "1"
        NODE_ID="$REPLY"
        return
    fi

    local jwt_token
    jwt_token=$(echo "$token_resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)
    echo -e "\r  ${CHECK} JWT токен получен"

    # Имя ноды
    ask "Название ноды (например 🇩🇪 Germany #1)" "🌐 Node #1"
    local node_name="$REPLY"
    ask "Страна (код, например DE, NL, FI)" "XX"
    local node_country="$REPLY"
    ask "Город" "Unknown"
    local node_city="$REPLY"

    local tmp_secret
    tmp_secret=$(gen_secret)

    echo -ne "  ${ARROW} ${D}Создаём ноду в панели...${NC}"
    local create_resp
    create_resp=$(curl -sf --max-time 10 \
        -X POST "${NODE_PANEL_URL}/api/nodes" \
        -H "Authorization: Bearer ${jwt_token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${node_name}\",
            \"address\": \"${SERVER_IP}\",
            \"port\": ${NODE_AGENT_PORT:-2095},
            \"country\": \"${node_country}\",
            \"city\": \"${node_city}\",
            \"ghostnet_port\": 443,
            \"ghostnet_domain\": \"\",
            \"ghostnet_secret\": \"${tmp_secret}\"
        }" 2>/dev/null || echo "")

    if echo "$create_resp" | grep -q '"id"'; then
        NODE_ID=$(echo "$create_resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "1")
        echo -e "\r  ${CHECK} Нода создана. ${G}NODE_ID = ${NODE_ID}${NC}"
    else
        echo -e "\r  ${WARN} ${Y}Не удалось создать ноду через API${NC}"
        ask "Введите NODE_ID вручную" "1"
        NODE_ID="$REPLY"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 5: ПОДТВЕРЖДЕНИЕ
# ─────────────────────────────────────────────────────────────────────────────

show_summary() {
    separator
    log_step "Итоговая конфигурация"
    echo ""

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${W}═══ PANEL ═══${NC}"
        log_val "Директория:"     "/opt/ghostwave"
        log_val "Домен:"          "$PANEL_DOMAIN"
        log_val "Admin логин:"    "$ADMIN_USER"
        log_val "Admin пароль:"   "${ADMIN_PASS:0:3}****${ADMIN_PASS: -2}"
        log_val "Telegram бот:"   "${TG_TOKEN:0:10}…  ID: $TG_ADMIN_IDS"
        log_val "DB_PASSWORD:"    "${DB_PASSWORD:0:6}…"
        log_val "NODE_API_KEY:"   "${NODE_API_KEY:0:8}…"
        echo ""
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo -e "  ${W}═══ NODE ═══${NC}"
        log_val "Директория:"       "/opt/ghostwave-node"
        log_val "NODE_ID:"          "$NODE_ID"
        log_val "Panel URL:"        "$NODE_PANEL_URL"
        log_val "GhostNet домен:"   "$NODE_GN_DOMAIN"
        log_val "GhostNet порт:"    "$NODE_GN_PORT"
        log_val "Agent порт:"       "$NODE_AGENT_PORT"
        log_val "GN Secret:"        "${NODE_GN_SECRET:0:8}…"
        echo ""
    fi

    echo -e "  ${Y}Будет установлено и запущено через Docker.${NC}"
    echo ""

    if ! ask_yn "Всё верно? Начать установку?" "y"; then
        echo ""
        log_warn "Установка отменена пользователем"
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 6: ЗАПИСЬ КОНФИГОВ
# ─────────────────────────────────────────────────────────────────────────────

write_panel_configs() {
    log_step "Запись конфигурации Panel"

    INSTALL_DIR="/opt/ghostwave"
    mkdir -p "$INSTALL_DIR"/{docker,panel/api/{routers,models,schemas,services,core}}

    # ── .env ──────────────────────────────────────────────────────────────
    cat > "${INSTALL_DIR}/.env" << EOF
# GhostWave Panel — автоматически сгенерировано $(date '+%Y-%m-%d %H:%M:%S')

# База данных
DB_PASSWORD=${DB_PASSWORD}

# Безопасность
JWT_SECRET=${JWT_SECRET}
SECRET_KEY=${SECRET_KEY}
NODE_API_KEY=${NODE_API_KEY}

# Администратор
ADMIN_USERNAME=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASS}

# Telegram
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ADMIN_IDS=${TG_ADMIN_IDS}

# Subscription URL
SUB_BASE_URL=https://${PANEL_DOMAIN}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
    chmod 600 "${INSTALL_DIR}/.env"
    log_ok ".env создан (права 600)"

    # ── Caddyfile ─────────────────────────────────────────────────────────
    cat > "${INSTALL_DIR}/docker/Caddyfile" << EOF
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

    # ── docker-compose.yml ─────────────────────────────────────────────────
    cat > "${INSTALL_DIR}/docker/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  panel:
    image: python:3.12-slim
    container_name: ghostwave-panel
    restart: unless-stopped
    working_dir: /app
    command: >
      bash -c "pip install -q fastapi uvicorn[standard] sqlalchemy[asyncio]
               asyncpg alembic pydantic pydantic-settings bcrypt pyjwt
               redis httpx aiogram psutil cryptography &&
               uvicorn main:app --host 0.0.0.0 --port 3000"
    environment:
      - DATABASE_URL=postgresql+asyncpg://ghostwave:${DB_PASSWORD}@postgres:5432/ghostwave
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - JWT_SECRET=${JWT_SECRET}
      - SECRET_KEY=${SECRET_KEY}
      - ADMIN_USERNAME=${ADMIN_USERNAME}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
      - TELEGRAM_ADMIN_IDS=${TELEGRAM_ADMIN_IDS}
      - NODE_API_KEY=${NODE_API_KEY}
      - SUB_BASE_URL=${SUB_BASE_URL}
    volumes:
      - /opt/ghostwave/panel:/app
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
      POSTGRES_DB:       ghostwave
      POSTGRES_USER:     ghostwave
      POSTGRES_PASSWORD: ${DB_PASSWORD}
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
    command: redis-server --requirepass ${REDIS_PASSWORD}
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

    local NODE_DIR="/opt/ghostwave-node"
    mkdir -p "$NODE_DIR"
    mkdir -p /etc/ghostnet

    # ── .env.node ─────────────────────────────────────────────────────────
    cat > "${NODE_DIR}/.env.node" << EOF
# GhostWave Node — автоматически сгенерировано $(date '+%Y-%m-%d %H:%M:%S')
NODE_ID=${NODE_ID}
NODE_API_KEY=${NODE_PANEL_KEY}
PANEL_URL=${NODE_PANEL_URL}
AGENT_PORT=${NODE_AGENT_PORT}
AGENT_HOST=0.0.0.0
GHOSTNET_PORT=${NODE_GN_PORT}
GHOSTNET_DOMAIN=${NODE_GN_DOMAIN}
GHOSTNET_SECRET=${NODE_GN_SECRET}
HEARTBEAT_INTERVAL=15
TRAFFIC_REPORT_INTERVAL=60
EOF
    chmod 600 "${NODE_DIR}/.env.node"
    log_ok ".env.node создан (права 600)"

    # ── GhostNet config ────────────────────────────────────────────────────
    cat > /etc/ghostnet/config.json << EOF
{
  "secret":      "${NODE_GN_SECRET}",
  "domain":      "${NODE_GN_DOMAIN}",
  "port":        ${NODE_GN_PORT},
  "allowed_users": [],
  "tun_network": "10.8.0.0/24",
  "time_window": 30,
  "log_level":   "info"
}
EOF
    chmod 600 /etc/ghostnet/config.json
    log_ok "/etc/ghostnet/config.json создан"

    # ── docker-compose.node.yml ───────────────────────────────────────────
    cat > "${NODE_DIR}/docker-compose.yml" << EOF
version: "3.9"

services:
  node-agent:
    image: python:3.12-slim
    container_name: ghostwave-node
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    working_dir: /app
    command: >
      bash -c "pip install -q fastapi uvicorn[standard] httpx pydantic
               pydantic-settings psutil cryptography &&
               uvicorn agent.agent:agent_app --host 0.0.0.0 --port ${NODE_AGENT_PORT}"
    environment:
      - NODE_ID=${NODE_ID}
      - NODE_API_KEY=${NODE_PANEL_KEY}
      - PANEL_URL=${NODE_PANEL_URL}
      - AGENT_PORT=${NODE_AGENT_PORT}
      - GHOSTNET_PORT=${NODE_GN_PORT}
      - GHOSTNET_DOMAIN=${NODE_GN_DOMAIN}
      - GHOSTNET_SECRET=${NODE_GN_SECRET}
    volumes:
      - /opt/ghostwave/node:/app
      - /etc/ghostnet:/etc/ghostnet
EOF
    log_ok "docker-compose.yml для ноды создан"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 7: ЗАПУСК СЕРВИСОВ
# ─────────────────────────────────────────────────────────────────────────────

start_panel_services() {
    log_step "Запуск сервисов Panel"

    cd /opt/ghostwave/docker

    # Скачиваем образы
    run_bg "Загрузка Docker образов" \
        docker compose --env-file /opt/ghostwave/.env pull

    # Запускаем PostgreSQL и Redis первыми
    run_bg "Запуск PostgreSQL" \
        docker compose --env-file /opt/ghostwave/.env up -d postgres redis

    # Ждём healthcheck
    echo -ne "  ${ARROW} ${D}Ожидание готовности базы данных...${NC}"
    local attempts=0
    while (( attempts < 30 )); do
        if docker compose --env-file /opt/ghostwave/.env \
            exec -T postgres pg_isready -U ghostwave &>/dev/null; then
            echo -e "\r  ${CHECK} PostgreSQL готов${NC}"
            break
        fi
        sleep 2
        (( attempts++ ))
        printf "\r  ${C}⠋${NC} ${D}Ожидание PostgreSQL... %ds${NC}" "$((attempts * 2))"
    done

    if (( attempts >= 30 )); then
        log_err "PostgreSQL не запустился за 60 секунд"
        exit 1
    fi

    # Запускаем Panel и Caddy
    run_bg "Запуск Panel и Caddy" \
        docker compose --env-file /opt/ghostwave/.env up -d panel caddy

    # Ждём Panel
    echo -ne "  ${ARROW} ${D}Ожидание запуска Panel...${NC}"
    attempts=0
    while (( attempts < 40 )); do
        if curl -sf --max-time 2 http://localhost:3000/health &>/dev/null; then
            echo -e "\r  ${CHECK} Panel запущена и отвечает${NC}"
            break
        fi
        sleep 3
        (( attempts++ ))
        printf "\r  ${C}⠋${NC} ${D}Ожидание Panel... %ds${NC}" "$((attempts * 3))"
    done

    if (( attempts >= 40 )); then
        log_warn "Panel не ответила за 120 секунд (проверьте логи)"
    fi
}

start_node_services() {
    log_step "Запуск Node Agent"

    cd /opt/ghostwave-node

    run_bg "Загрузка Docker образа" \
        docker compose pull

    run_bg "Запуск Node Agent" \
        docker compose up -d

    # Ждём агента
    echo -ne "  ${ARROW} ${D}Ожидание запуска Node Agent...${NC}"
    local attempts=0
    while (( attempts < 30 )); do
        if curl -sf --max-time 2 "http://localhost:${NODE_AGENT_PORT}/health" &>/dev/null; then
            echo -e "\r  ${CHECK} Node Agent запущен${NC}"
            break
        fi
        sleep 3
        (( attempts++ ))
        printf "\r  ${C}⠋${NC} ${D}Ожидание агента... %ds${NC}" "$((attempts * 3))"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 8: ПРОВЕРКА И ФИНАЛЬНЫЙ ОТЧЁТ
# ─────────────────────────────────────────────────────────────────────────────

final_checks() {
    separator
    log_step "Финальная проверка"
    echo ""

    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        # Проверка локально
        local health
        health=$(curl -sf --max-time 5 "http://localhost:3000/health" 2>/dev/null || echo "")
        if echo "$health" | grep -q '"ok"'; then
            log_ok "Panel API: ${G}OK${NC} (localhost:3000)"
        else
            log_warn "Panel API: не отвечает на localhost:3000"
        fi

        # Проверка через домен (SSL может занять время)
        local https_health
        https_health=$(curl -sf --max-time 8 "https://${PANEL_DOMAIN}/health" 2>/dev/null || echo "")
        if echo "$https_health" | grep -q '"ok"'; then
            log_ok "HTTPS: ${G}OK${NC} (${PANEL_DOMAIN})"
        else
            log_warn "HTTPS ещё не готов (SSL-сертификат получается, подождите 1-2 минуты)"
        fi

        # Проверка PostgreSQL
        if docker exec ghostwave-postgres pg_isready -U ghostwave &>/dev/null; then
            log_ok "PostgreSQL: ${G}OK${NC}"
        else
            log_warn "PostgreSQL: нет ответа"
        fi

        # Проверка Redis
        if docker exec ghostwave-redis redis-cli -a "$REDIS_PASSWORD" ping &>/dev/null; then
            log_ok "Redis: ${G}OK${NC}"
        else
            log_warn "Redis: нет ответа"
        fi
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        local agent_health
        agent_health=$(curl -sf --max-time 5 \
            "http://localhost:${NODE_AGENT_PORT}/health" 2>/dev/null || echo "")
        if echo "$agent_health" | grep -q '"ok"'; then
            log_ok "Node Agent: ${G}OK${NC} (порт ${NODE_AGENT_PORT})"
        else
            log_warn "Node Agent: не отвечает (проверьте: docker logs ghostwave-node)"
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
        log_val "🌐 URL панели:"        "https://${PANEL_DOMAIN}"
        log_val "📖 API документация:"  "https://${PANEL_DOMAIN}/api/docs"
        log_val "👤 Логин:"             "$ADMIN_USER"
        log_val "🔑 Пароль:"            "$ADMIN_PASS"
        echo ""
        log_val "🤖 Telegram бот:"      "${TG_TOKEN:+(настроен) @id: $TG_ADMIN_IDS}"
        echo ""
        echo -e "  ${Y}Сохраните NODE_API_KEY для установки нод:${NC}"
        echo -e "  ${W}${NODE_API_KEY}${NC}"
        echo ""
        echo -e "  ${D}Конфиг: /opt/ghostwave/.env${NC}"
        echo -e "  ${D}Логи:   docker logs ghostwave-panel -f${NC}"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        echo ""
        echo -e "  ${W}════ NODE ════${NC}\n"
        log_val "🖥️  NODE_ID:"          "$NODE_ID"
        log_val "📡 Agent API:"         "http://${SERVER_IP}:${NODE_AGENT_PORT}"
        log_val "🔒 GhostNet домен:"    "$NODE_GN_DOMAIN"
        log_val "⚙️  GhostNet порт:"    "$NODE_GN_PORT"
        echo ""
        echo -e "  ${D}Конфиг: /opt/ghostwave-node/.env.node${NC}"
        echo -e "  ${D}Логи:   docker logs ghostwave-node -f${NC}"
    fi

    separator

    # Сохраняем итоговый отчёт в файл
    local REPORT_FILE="/root/ghostwave-install-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "GhostWave Installation Report"
        echo "Generated: $(date)"
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
        fi
        if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
            echo ""
            echo "[NODE]"
            echo "NODE_ID: $NODE_ID"
            echo "NODE_API_KEY: $NODE_PANEL_KEY"
            echo "GhostNet domain: $NODE_GN_DOMAIN"
            echo "GhostNet secret: $NODE_GN_SECRET"
        fi
    } > "$REPORT_FILE"
    chmod 600 "$REPORT_FILE"

    echo -e "  ${CHECK} Отчёт об установке сохранён: ${W}${REPORT_FILE}${NC}"
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
# ОБРАБОТКА ОШИБОК
# ─────────────────────────────────────────────────────────────────────────────

handle_error() {
    local line="$1"
    echo ""
    echo -e "  ${CROSS} ${R}Критическая ошибка в строке ${line}${NC}"
    echo -e "  ${D}Последний вывод:${NC}"
    [[ -f /tmp/gw_install_last.log ]] && \
        cat /tmp/gw_install_last.log | tail -10 | while IFS= read -r l; do
            echo -e "  ${D}$l${NC}"
        done
    echo ""
    echo -e "  Для диагностики: ${C}cat /tmp/gw_install_last.log${NC}"
    echo ""
    exit 1
}
trap 'handle_error $LINENO' ERR

# ─────────────────────────────────────────────────────────────────────────────
# ГЛАВНЫЙ ПОТОК
# ─────────────────────────────────────────────────────────────────────────────

main() {
    show_banner

    # 0. Проверка системы
    check_system
    pause

    # 1. Выбор режима
    choose_mode

    # 2. Зависимости
    separator
    if ask_yn "Установить/обновить зависимости (Docker и др.)?" "y"; then
        install_deps
    else
        log_info "Пропуск установки зависимостей"
    fi

    # 3. Сбор конфигурации
    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        collect_panel_config
    fi
    if [[ "$INSTALL_MODE" == "node" ]]; then
        # Для ноды нужно сначала спросить PANEL_URL чтобы ограничить файрвол
        collect_node_config
    fi
    if [[ "$INSTALL_MODE" == "panel+node" ]]; then
        # Panel+Node — данные ноды берём из сгенерированных данных панели
        NODE_PANEL_URL="https://${PANEL_DOMAIN}"
        NODE_PANEL_KEY="$NODE_API_KEY"
        NODE_ID="1"
        separator
        log_step "Конфигурация Node (локальная нода)"
        ask "Домен для маскировки GhostNet" ""
        NODE_GN_DOMAIN="$REPLY"
        ask "Порт GhostNet" "443"
        NODE_GN_PORT="$REPLY"
        ask "Порт Node Agent" "2095"
        NODE_AGENT_PORT="$REPLY"
        NODE_GN_SECRET=$(gen_secret)
        log_ok "GhostNet secret сгенерирован"
    fi

    # 4. Файрвол
    setup_firewall

    # 5. Подтверждение
    show_summary

    # 6. Запись конфигов
    separator
    log_step "Создание файлов конфигурации"
    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        write_panel_configs
    fi
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        write_node_configs
    fi

    # 7. Запуск
    if [[ "$INSTALL_MODE" == "panel" || "$INSTALL_MODE" == "panel+node" ]]; then
        start_panel_services
    fi
    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        start_node_services
    fi

    # 8. Проверка и итог
    final_checks
    show_final_summary
}

main "$@"
