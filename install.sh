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
        ufw allow 443/tcp comment "HTTPS Panel+Caddy"  >/dev/null 2>&1 || true
        log_ok "Порты 80, 443 (Panel HTTPS/Caddy) — открыты"
    fi

    if [[ "$INSTALL_MODE" == "node" || "$INSTALL_MODE" == "panel+node" ]]; then
        local agent_port="${NODE_AGENT_PORT:-2095}"

        # В режиме panel+node порт 443 занят Caddy — GhostNet уйдёт на 8443
        local effective_gn_port="${NODE_GN_PORT:-443}"
        if [[ "$INSTALL_MODE" == "panel+node" && "$effective_gn_port" == "443" ]]; then
            effective_gn_port="8443"
        fi

        if [[ "$effective_gn_port" != "443" ]]; then
            ufw allow "${effective_gn_port}/tcp" comment "GhostNet VPN" >/dev/null 2>&1 || true
            log_ok "Порт ${effective_gn_port} (GhostNet) — открыт"
        fi
        # Порт 443 для node в режиме только-node
        if [[ "$INSTALL_MODE" == "node" ]]; then
            ufw allow "${effective_gn_port}/tcp" comment "GhostNet VPN" >/dev/null 2>&1 || true
            log_ok "Порт ${effective_gn_port} (GhostNet) — открыт"
        fi

        # Ограничиваем агент-порт только для IP Panel (если знаем)
        local panel_ip=""
        if [[ -n "${NODE_PANEL_URL:-}" ]]; then
            local panel_host
            panel_host=$(echo "$NODE_PANEL_URL" | sed 's~https\?://~~' | cut -d/ -f1)
            panel_ip=$(dig +short "$panel_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1) || panel_ip=""
        elif [[ -n "${PANEL_DOMAIN:-}" ]]; then
            panel_ip=$(dig +short "$PANEL_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1) || panel_ip=""
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

    if [[ ! -f /opt/ghostwave/docker-compose.yml ]]; then
        log_warn "Panel не найдена (/opt/ghostwave не существует)"
        return
    fi

    if ask_yn "Удалить данные PostgreSQL (база пользователей)?" "n"; then
        run_bg "Остановка и удаление контейнеров + volumes" \
            bash -c "cd /opt/ghostwave && docker compose down -v --remove-orphans"
        log_ok "Контейнеры и данные удалены"
    else
        run_bg "Остановка контейнеров (данные сохранены)" \
            bash -c "cd /opt/ghostwave && docker compose down --remove-orphans"
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
                if [[ -f /opt/ghostwave/docker-compose.yml ]]; then
                    run_bg "Перезапуск Panel" \
                        bash -c "cd /opt/ghostwave && docker compose restart"
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

# ─────────────────────────────────────────────────────────────────────────────
# ГЕНЕРАЦИЯ PYTHON ФАЙЛОВ
# ─────────────────────────────────────────────────────────────────────────────

_write_agent_py() {
    cat > /opt/ghostwave-node/agent.py << 'PYEOF'
"""GhostWave Node Agent — самодостаточный, без субмодулей."""
import asyncio, json, logging, os, psutil, secrets, time
from contextlib import asynccontextmanager
from typing import Optional
import httpx
from fastapi import FastAPI, HTTPException, Header, Depends
from pydantic import BaseModel
from pydantic_settings import BaseSettings

log = logging.getLogger("ghostwave.node")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s: %(message)s")

class NodeSettings(BaseSettings):
    NODE_ID:                  int = 1
    NODE_API_KEY:             str = ""
    PANEL_URL:                str = "https://panel.example.com"
    AGENT_PORT:               int = 2095
    AGENT_HOST:               str = "0.0.0.0"
    GHOSTNET_PORT:            int = 443
    GHOSTNET_DOMAIN:          str = ""
    GHOSTNET_SECRET:          str = ""
    HEARTBEAT_INTERVAL:       int = 15
    TRAFFIC_REPORT_INTERVAL:  int = 60
    class Config:
        env_file = ".env.node"

cfg   = NodeSettings()
state = type("State", (), {
    "allowed_uuids": set(),
    "traffic_delta": {},
    "active_sessions": {},
    "ghostnet_proc": None,
    "started_at": time.time(),
})()

def sys_stats():
    return {"load_avg": psutil.cpu_percent(0.1), "memory_usage": psutil.virtual_memory().percent}

def verify_key(x_node_key: str = Header(...)):
    if x_node_key != cfg.NODE_API_KEY:
        raise HTTPException(401, "Invalid key")

async def write_ghostnet_cfg(allowed: list):
    os.makedirs("/etc/ghostnet", exist_ok=True)
    with open("/etc/ghostnet/config.json", "w") as f:
        json.dump({"secret": cfg.GHOSTNET_SECRET, "domain": cfg.GHOSTNET_DOMAIN,
                   "port": cfg.GHOSTNET_PORT, "allowed_users": allowed,
                   "tun_network": "10.8.0.0/24"}, f, indent=2)

async def start_ghostnet():
    bin_path = "/usr/local/bin/ghostnet-server"
    if not os.path.exists(bin_path):
        log.warning("GhostNet binary not found (demo mode)")
        return
    if state.ghostnet_proc and state.ghostnet_proc.returncode is None:
        return
    state.ghostnet_proc = await asyncio.create_subprocess_exec(
        bin_path, "--config", "/etc/ghostnet/config.json",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    log.info(f"GhostNet daemon started (pid={state.ghostnet_proc.pid})")

async def heartbeat_loop():
    while True:
        await asyncio.sleep(cfg.HEARTBEAT_INTERVAL)
        stats = sys_stats()
        payload = {"node_id": cfg.NODE_ID, "status": "online",
                   "load_avg": stats["load_avg"], "memory_usage": stats["memory_usage"],
                   "online_users": len(state.active_sessions)}
        try:
            async with httpx.AsyncClient(timeout=10, verify=False) as c:
                r = await c.post(f"{cfg.PANEL_URL}/api/node/heartbeat", json=payload)
            if r.status_code == 200:
                new = set(r.json().get("active_users", []))
                if new != state.allowed_uuids:
                    state.allowed_uuids.clear(); state.allowed_uuids.update(new)
                    await write_ghostnet_cfg(list(new))
                    log.info(f"Allowed users: {len(new)}")
        except Exception as e:
            log.warning(f"Heartbeat: {e}")

async def traffic_loop():
    while True:
        await asyncio.sleep(cfg.TRAFFIC_REPORT_INTERVAL)
        delta = [(k, v) for k, v in state.traffic_delta.items() if v["up"] + v["down"] > 0]
        if not delta: continue
        traffic = [{"user_uuid": k, "up_bytes": v["up"], "down_bytes": v["down"]} for k, v in delta]
        state.traffic_delta.clear()
        try:
            async with httpx.AsyncClient(timeout=10, verify=False) as c:
                await c.post(f"{cfg.PANEL_URL}/api/node/traffic",
                             json={"node_id": cfg.NODE_ID, "traffic": traffic})
        except Exception as e:
            log.warning(f"Traffic report: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"Node Agent starting (node_id={cfg.NODE_ID})")
    await write_ghostnet_cfg([])
    await start_ghostnet()
    tasks = [asyncio.create_task(heartbeat_loop()), asyncio.create_task(traffic_loop())]
    log.info("Node Agent ready.")
    yield
    for t in tasks: t.cancel()
    if state.ghostnet_proc: state.ghostnet_proc.terminate()

agent_app = FastAPI(title="GhostWave Node Agent", lifespan=lifespan)

@agent_app.get("/health")
async def health():
    return {"status": "ok", "node_id": cfg.NODE_ID,
            "online_users": len(state.active_sessions),
            "uptime": int(time.time() - state.started_at), **sys_stats()}

@agent_app.get("/status", dependencies=[Depends(verify_key)])
async def status():
    return {"node_id": cfg.NODE_ID, "allowed_users": len(state.allowed_uuids),
            "ghostnet_port": cfg.GHOSTNET_PORT, **sys_stats()}

@agent_app.post("/traffic/ingest", dependencies=[Depends(verify_key)])
async def ingest_traffic(entries: list):
    for e in entries:
        uuid = e.get("user_uuid", "")
        if uuid in state.allowed_uuids:
            if uuid not in state.traffic_delta:
                state.traffic_delta[uuid] = {"up": 0, "down": 0}
            state.traffic_delta[uuid]["up"]   += e.get("up_bytes", 0)
            state.traffic_delta[uuid]["down"] += e.get("down_bytes", 0)
            state.active_sessions[uuid] = time.time()
    return {"ok": True}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(agent_app, host=cfg.AGENT_HOST, port=cfg.AGENT_PORT)
PYEOF
}


_write_main_py() {
    cat > /opt/ghostwave/main.py << 'PYEOF'
"""
GhostWave Panel — самодостаточный main.py
Всё в одном файле, никаких субмодулей.
"""
import os
import secrets
import asyncio
import logging
from datetime import datetime, timezone, timedelta
from contextlib import asynccontextmanager
from typing import Optional

import jwt
import bcrypt
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy import text

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s"
)
log = logging.getLogger("ghostwave.panel")

# ─── Config (из env) ──────────────────────────────────────────────────────────
DB_URL         = os.environ["DATABASE_URL"]
REDIS_URL      = os.environ.get("REDIS_URL", "")
JWT_SECRET     = os.environ.get("JWT_SECRET", secrets.token_hex(32))
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "changeme")
NODE_API_KEY   = os.environ.get("NODE_API_KEY", "")
SUB_BASE_URL   = os.environ.get("SUB_BASE_URL", "https://example.com")
TG_TOKEN       = os.environ.get("TELEGRAM_BOT_TOKEN", "")
VERSION        = "1.0.0"

# ─── Database ─────────────────────────────────────────────────────────────────
engine       = create_async_engine(DB_URL, pool_pre_ping=True, echo=False)
AsyncSession_ = async_sessionmaker(engine, expire_on_commit=False)
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")

SCHEMA_SQL = """
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS admins (
    id               SERIAL PRIMARY KEY,
    username         VARCHAR(64)  UNIQUE NOT NULL,
    hashed_password  VARCHAR(256) NOT NULL,
    telegram_id      BIGINT       UNIQUE,
    created_at       TIMESTAMPTZ  DEFAULT NOW(),
    last_login       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS nodes (
    id               SERIAL PRIMARY KEY,
    name             VARCHAR(128) NOT NULL,
    address          VARCHAR(256) NOT NULL,
    port             INTEGER      DEFAULT 2095,
    api_key          VARCHAR(128),
    country          VARCHAR(64)  DEFAULT '',
    city             VARCHAR(64)  DEFAULT '',
    flag_emoji       VARCHAR(8)   DEFAULT '🌐',
    is_enabled       BOOLEAN      DEFAULT TRUE,
    status           VARCHAR(32)  DEFAULT 'offline',
    load_avg         FLOAT        DEFAULT 0,
    memory_usage     FLOAT        DEFAULT 0,
    online_users     INTEGER      DEFAULT 0,
    last_seen        TIMESTAMPTZ,
    ghostnet_port    INTEGER      DEFAULT 443,
    ghostnet_domain  VARCHAR(256) DEFAULT '',
    ghostnet_secret  VARCHAR(256) DEFAULT '',
    created_at       TIMESTAMPTZ  DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
    id                SERIAL PRIMARY KEY,
    uuid              VARCHAR(36)  UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
    username          VARCHAR(128) UNIQUE NOT NULL,
    status            VARCHAR(32)  DEFAULT 'active',
    traffic_limit     BIGINT       DEFAULT 0,
    traffic_used_up   BIGINT       DEFAULT 0,
    traffic_used_down BIGINT       DEFAULT 0,
    expires_at        TIMESTAMPTZ,
    sub_token         VARCHAR(64)  UNIQUE NOT NULL,
    telegram_id       BIGINT       UNIQUE,
    telegram_username VARCHAR(128),
    note              TEXT         DEFAULT '',
    created_at        TIMESTAMPTZ  DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  DEFAULT NOW(),
    last_online       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS user_nodes (
    id            SERIAL  PRIMARY KEY,
    user_id       INTEGER REFERENCES users(id) ON DELETE CASCADE,
    node_id       INTEGER REFERENCES nodes(id) ON DELETE CASCADE,
    is_enabled    BOOLEAN DEFAULT TRUE,
    traffic_up    BIGINT  DEFAULT 0,
    traffic_down  BIGINT  DEFAULT 0,
    last_connected TIMESTAMPTZ,
    UNIQUE(user_id, node_id)
);

CREATE TABLE IF NOT EXISTS traffic_logs (
    id           SERIAL  PRIMARY KEY,
    user_id      INTEGER REFERENCES users(id) ON DELETE CASCADE,
    node_id      INTEGER,
    traffic_up   BIGINT  DEFAULT 0,
    traffic_down BIGINT  DEFAULT 0,
    recorded_at  TIMESTAMPTZ DEFAULT NOW()
);
"""

async def get_db():
    async with AsyncSession_() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise

# ─── Auth helpers ─────────────────────────────────────────────────────────────
def make_jwt(admin_id: int) -> str:
    return jwt.encode(
        {"sub": str(admin_id),
         "exp": datetime.now(timezone.utc) + timedelta(hours=24)},
        JWT_SECRET, algorithm="HS256"
    )

async def get_current_admin(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db)
):
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        admin_id = int(payload["sub"])
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
    row = (await db.execute(
        text("SELECT id, username FROM admins WHERE id = :id"), {"id": admin_id}
    )).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Admin not found")
    return {"id": row[0], "username": row[1]}

# ─── Lifespan ─────────────────────────────────────────────────────────────────
async def _scheduler():
    """Периодически помечает expired пользователей и offline ноды."""
    while True:
        await asyncio.sleep(30)
        try:
            async with AsyncSession_() as db:
                await db.execute(text("""
                    UPDATE users SET status='expired'
                    WHERE expires_at < NOW() AND status = 'active'
                """))
                await db.execute(text("""
                    UPDATE nodes SET status='offline'
                    WHERE last_seen < NOW() - INTERVAL '60 seconds'
                      AND status = 'online'
                """))
                await db.commit()
        except Exception as e:
            log.error(f"Scheduler error: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"GhostWave Panel v{VERSION} starting…")

    # Инициализируем схему БД
    async with engine.begin() as conn:
        await conn.execute(text(SCHEMA_SQL))
    log.info("Database schema ready")

    # Создаём admin если нет
    async with AsyncSession_() as db:
        row = (await db.execute(
            text("SELECT id FROM admins WHERE username = :u"), {"u": ADMIN_USERNAME}
        )).fetchone()
        if not row:
            hp = bcrypt.hashpw(ADMIN_PASSWORD.encode(), bcrypt.gensalt()).decode()
            await db.execute(text(
                "INSERT INTO admins(username, hashed_password) VALUES(:u, :p)"
            ), {"u": ADMIN_USERNAME, "p": hp})
            await db.commit()
            log.info(f"Admin '{ADMIN_USERNAME}' created")

    scheduler_task = asyncio.create_task(_scheduler())

    # Telegram bot (если токен задан)
    bot_task = None
    if TG_TOKEN:
        try:
            from telegram_bot import start_bot
            bot_task = asyncio.create_task(start_bot())
            log.info("Telegram bot started")
        except ImportError:
            log.warning("telegram_bot.py not found, bot disabled")

    log.info("Panel ready.")
    yield

    scheduler_task.cancel()
    if bot_task:
        bot_task.cancel()
    log.info("Panel shutdown.")

# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="GhostWave Panel",
    version=VERSION,
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Healthcheck ──────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "version": VERSION}

# ─── Auth ─────────────────────────────────────────────────────────────────────
@app.post("/api/auth/login")
async def login(
    form: OAuth2PasswordRequestForm = Depends(),
    db: AsyncSession = Depends(get_db)
):
    row = (await db.execute(
        text("SELECT id, hashed_password FROM admins WHERE username = :u"),
        {"u": form.username}
    )).fetchone()
    if not row or not bcrypt.checkpw(form.password.encode(), row[1].encode()):
        raise HTTPException(status_code=401, detail="Wrong credentials")
    await db.execute(
        text("UPDATE admins SET last_login = NOW() WHERE id = :id"), {"id": row[0]}
    )
    return {"access_token": make_jwt(row[0]), "token_type": "bearer"}

@app.get("/api/auth/me")
async def me(admin=Depends(get_current_admin)):
    return admin

# ─── Nodes ────────────────────────────────────────────────────────────────────
class NodeCreate(BaseModel):
    name:            str
    address:         str
    port:            int = 2095
    country:         str = ""
    city:            str = ""
    flag_emoji:      str = "🌐"
    ghostnet_port:   int = 443
    ghostnet_domain: str = ""
    ghostnet_secret: str = ""

class NodeUpdate(BaseModel):
    name:            Optional[str]  = None
    address:         Optional[str]  = None
    port:            Optional[int]  = None
    country:         Optional[str]  = None
    city:            Optional[str]  = None
    flag_emoji:      Optional[str]  = None
    is_enabled:      Optional[bool] = None
    ghostnet_port:   Optional[int]  = None
    ghostnet_domain: Optional[str]  = None
    ghostnet_secret: Optional[str]  = None

@app.get("/api/nodes")
async def list_nodes(db: AsyncSession = Depends(get_db), _=Depends(get_current_admin)):
    rows = (await db.execute(text(
        "SELECT * FROM nodes ORDER BY name"
    ))).mappings().all()
    return [dict(r) for r in rows]

@app.post("/api/nodes", status_code=201)
async def create_node(
    data: NodeCreate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    api_key = secrets.token_hex(32)
    gn_secret = data.ghostnet_secret or secrets.token_hex(32)
    row = (await db.execute(text("""
        INSERT INTO nodes
          (name, address, port, api_key, country, city, flag_emoji,
           ghostnet_port, ghostnet_domain, ghostnet_secret)
        VALUES
          (:name, :address, :port, :api_key, :country, :city, :flag_emoji,
           :ghostnet_port, :ghostnet_domain, :ghostnet_secret)
        RETURNING id, name, address, status, api_key, ghostnet_secret
    """), {
        "name": data.name, "address": data.address, "port": data.port,
        "api_key": api_key, "country": data.country, "city": data.city,
        "flag_emoji": data.flag_emoji, "ghostnet_port": data.ghostnet_port,
        "ghostnet_domain": data.ghostnet_domain, "ghostnet_secret": gn_secret,
    })).mappings().fetchone()
    return dict(row)

@app.get("/api/nodes/{node_id}")
async def get_node(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    row = (await db.execute(
        text("SELECT * FROM nodes WHERE id = :id"), {"id": node_id}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Node not found")
    return dict(row)

@app.patch("/api/nodes/{node_id}")
async def update_node(
    node_id: int,
    data: NodeUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    fields = {k: v for k, v in data.model_dump().items() if v is not None}
    if not fields:
        raise HTTPException(400, "Nothing to update")
    sets = ", ".join(f"{k} = :{k}" for k in fields)
    fields["id"] = node_id
    row = (await db.execute(
        text(f"UPDATE nodes SET {sets} WHERE id = :id RETURNING *"), fields
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Node not found")
    return dict(row)

@app.delete("/api/nodes/{node_id}", status_code=204)
async def delete_node(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("DELETE FROM nodes WHERE id = :id"), {"id": node_id})

@app.get("/api/nodes/{node_id}/users")
async def node_users(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    rows = (await db.execute(text("""
        SELECT u.uuid FROM users u
        JOIN user_nodes un ON un.user_id = u.id
        WHERE un.node_id = :nid AND un.is_enabled = TRUE AND u.status = 'active'
    """), {"nid": node_id})).fetchall()
    uuids = [r[0] for r in rows]
    return {"node_id": node_id, "allowed_users": uuids, "count": len(uuids)}

# ─── Users ────────────────────────────────────────────────────────────────────
class UserCreate(BaseModel):
    username:      str
    traffic_limit: int = 0
    expires_at:    Optional[str] = None
    note:          str = ""
    node_ids:      list[int] = []
    telegram_id:   Optional[int] = None

class UserUpdate(BaseModel):
    status:        Optional[str] = None
    traffic_limit: Optional[int] = None
    expires_at:    Optional[str] = None
    note:          Optional[str] = None
    node_ids:      Optional[list[int]] = None

@app.get("/api/users")
async def list_users(
    offset: int = 0,
    limit:  int = 50,
    status: Optional[str] = None,
    search: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    where = "WHERE 1=1"
    params: dict = {}
    if status:
        where += " AND status = :status"
        params["status"] = status
    if search:
        where += " AND username ILIKE :search"
        params["search"] = f"%{search}%"
    total = (await db.execute(text(f"SELECT COUNT(*) FROM users {where}"), params)).scalar()
    params["limit"] = limit
    params["offset"] = offset
    rows = (await db.execute(
        text(f"SELECT * FROM users {where} ORDER BY created_at DESC LIMIT :limit OFFSET :offset"),
        params
    )).mappings().all()
    return {"total": total, "users": [dict(r) for r in rows]}

@app.post("/api/users", status_code=201)
async def create_user(
    data: UserCreate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    existing = (await db.execute(
        text("SELECT id FROM users WHERE username = :u"), {"u": data.username}
    )).fetchone()
    if existing:
        raise HTTPException(400, f"User '{data.username}' already exists")

    sub_token = secrets.token_urlsafe(32)
    row = (await db.execute(text("""
        INSERT INTO users(username, traffic_limit, expires_at, note, telegram_id, sub_token)
        VALUES(:username, :traffic_limit, :expires_at, :note, :telegram_id, :sub_token)
        RETURNING *
    """), {
        "username": data.username, "traffic_limit": data.traffic_limit,
        "expires_at": data.expires_at, "note": data.note,
        "telegram_id": data.telegram_id, "sub_token": sub_token,
    })).mappings().fetchone()
    user_id = row["id"]

    # Привязываем к нодам
    if data.node_ids:
        for nid in data.node_ids:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": nid})
    else:
        # Все активные ноды
        nodes = (await db.execute(
            text("SELECT id FROM nodes WHERE is_enabled = TRUE")
        )).fetchall()
        for n in nodes:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": n[0]})

    return dict(row)

@app.get("/api/users/{user_id}")
async def get_user(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    row = (await db.execute(
        text("SELECT * FROM users WHERE id = :id"), {"id": user_id}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "User not found")
    return dict(row)

@app.patch("/api/users/{user_id}")
async def update_user(
    user_id: int,
    data: UserUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    fields = {k: v for k, v in data.model_dump().items()
              if v is not None and k != "node_ids"}
    if fields:
        fields["updated_at"] = datetime.now(timezone.utc).isoformat()
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        fields["id"] = user_id
        await db.execute(text(f"UPDATE users SET {sets} WHERE id = :id"), fields)
    if data.node_ids is not None:
        await db.execute(
            text("DELETE FROM user_nodes WHERE user_id = :id"), {"id": user_id}
        )
        for nid in data.node_ids:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": nid})
    row = (await db.execute(
        text("SELECT * FROM users WHERE id = :id"), {"id": user_id}
    )).mappings().fetchone()
    return dict(row)

@app.delete("/api/users/{user_id}", status_code=204)
async def delete_user(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("DELETE FROM users WHERE id = :id"), {"id": user_id})

@app.post("/api/users/{user_id}/reset-traffic")
async def reset_traffic(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("""
        UPDATE users
        SET traffic_used_up = 0, traffic_used_down = 0, updated_at = NOW()
        WHERE id = :id
    """), {"id": user_id})
    return {"ok": True, "user_id": user_id}

@app.post("/api/users/{user_id}/revoke-sub")
async def revoke_sub(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    new_token = secrets.token_urlsafe(32)
    await db.execute(text(
        "UPDATE users SET sub_token = :t WHERE id = :id"
    ), {"t": new_token, "id": user_id})
    return {"ok": True, "sub_token": new_token}

# ─── Stats ────────────────────────────────────────────────────────────────────
@app.get("/api/stats")
async def stats(db: AsyncSession = Depends(get_db), _=Depends(get_current_admin)):
    r = lambda q: db.execute(text(q))
    total_users   = (await r("SELECT COUNT(*) FROM users")).scalar()
    active_users  = (await r("SELECT COUNT(*) FROM users WHERE status='active'")).scalar()
    expired_users = (await r("SELECT COUNT(*) FROM users WHERE status='expired'")).scalar()
    limited_users = (await r("SELECT COUNT(*) FROM users WHERE status='limited'")).scalar()
    total_nodes   = (await r("SELECT COUNT(*) FROM nodes")).scalar()
    online_nodes  = (await r("SELECT COUNT(*) FROM nodes WHERE status='online'")).scalar()
    total_traffic = (await r(
        "SELECT COALESCE(SUM(traffic_used_up + traffic_used_down), 0) FROM users"
    )).scalar()
    return {
        "total_users": total_users, "active_users": active_users,
        "expired_users": expired_users, "limited_users": limited_users,
        "total_nodes": total_nodes, "online_nodes": online_nodes,
        "total_traffic": total_traffic,
    }

# ─── Subscription ─────────────────────────────────────────────────────────────
@app.get("/sub/{token}/info")
async def sub_info(token: str, db: AsyncSession = Depends(get_db)):
    row = (await db.execute(
        text("SELECT * FROM users WHERE sub_token = :t"), {"t": token}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Not found")
    sub_url = f"{SUB_BASE_URL}/sub/{token}"
    return {
        "username":          row["username"],
        "status":            row["status"],
        "traffic_limit":     row["traffic_limit"],
        "traffic_used":      row["traffic_used_up"] + row["traffic_used_down"],
        "traffic_remaining": max(0, row["traffic_limit"] - row["traffic_used_up"] - row["traffic_used_down"])
                             if row["traffic_limit"] > 0 else -1,
        "expires_at":        str(row["expires_at"]) if row["expires_at"] else None,
        "sub_links": {
            "json": f"{sub_url}?fmt=json",
            "uri":  f"{sub_url}?fmt=uri",
        },
    }

@app.get("/sub/{token}")
async def subscription(
    token: str,
    fmt:   str = "json",
    db: AsyncSession = Depends(get_db)
):
    user = (await db.execute(
        text("SELECT * FROM users WHERE sub_token = :t"), {"t": token}
    )).mappings().fetchone()
    if not user:
        raise HTTPException(404, "Not found")
    if user["status"] != "active":
        raise HTTPException(403, "Subscription expired or disabled")

    nodes = (await db.execute(text("""
        SELECT n.address, n.ghostnet_port, n.ghostnet_domain,
               n.ghostnet_secret, n.name, n.flag_emoji
        FROM nodes n
        JOIN user_nodes un ON un.node_id = n.id
        WHERE un.user_id = :uid AND un.is_enabled = TRUE AND n.is_enabled = TRUE
    """), {"uid": user["id"]})).mappings().all()

    configs = [{
        "protocol":      "ghostnet",
        "server_host":   n["address"],
        "server_port":   n["ghostnet_port"],
        "domain":        n["ghostnet_domain"],
        "shared_secret": n["ghostnet_secret"],
        "user_uuid":     user["uuid"],
        "remarks":       f"{n['flag_emoji']} {n['name']}",
    } for n in nodes]

    if fmt == "uri":
        import base64, json
        uris = [
            "ghostnet://" + base64.urlsafe_b64encode(
                json.dumps(c, separators=(",", ":")).encode()
            ).decode() + f"#{c['remarks']}"
            for c in configs
        ]
        import base64 as b64
        return __import__("fastapi").Response(
            content=b64.b64encode("\n".join(uris).encode()).decode(),
            media_type="text/plain"
        )

    return {"user": user["username"], "status": user["status"], "configs": configs}

# ─── Node Agent API ───────────────────────────────────────────────────────────
@app.post("/api/node/heartbeat")
async def node_heartbeat(data: dict, db: AsyncSession = Depends(get_db)):
    nid = data.get("node_id")
    if not nid:
        raise HTTPException(400, "node_id required")
    await db.execute(text("""
        UPDATE nodes
        SET status = 'online',
            load_avg     = :la,
            memory_usage = :mu,
            online_users = :ou,
            last_seen    = NOW()
        WHERE id = :id
    """), {
        "la": data.get("load_avg", 0),
        "mu": data.get("memory_usage", 0),
        "ou": data.get("online_users", 0),
        "id": nid,
    })
    rows = (await db.execute(text("""
        SELECT u.uuid FROM users u
        JOIN user_nodes un ON un.user_id = u.id
        WHERE un.node_id = :nid AND un.is_enabled = TRUE AND u.status = 'active'
    """), {"nid": nid})).fetchall()
    return {"ok": True, "active_users": [r[0] for r in rows]}

@app.post("/api/node/traffic")
async def node_traffic(data: dict, db: AsyncSession = Depends(get_db)):
    for entry in data.get("traffic", []):
        await db.execute(text("""
            UPDATE users
            SET traffic_used_up   = traffic_used_up   + :up,
                traffic_used_down = traffic_used_down + :dn,
                last_online       = NOW()
            WHERE uuid = :uuid
        """), {
            "up":   entry.get("up_bytes", 0),
            "dn":   entry.get("down_bytes", 0),
            "uuid": entry.get("user_uuid", ""),
        })
        # Обновляем трафик на конкретной ноде
        await db.execute(text("""
            UPDATE user_nodes un
            SET traffic_up   = traffic_up   + :up,
                traffic_down = traffic_down + :dn,
                last_connected = NOW()
            FROM users u
            WHERE un.user_id = u.id
              AND u.uuid = :uuid
              AND un.node_id = :nid
        """), {
            "up":   entry.get("up_bytes", 0),
            "dn":   entry.get("down_bytes", 0),
            "uuid": entry.get("user_uuid", ""),
            "nid":  data.get("node_id", 0),
        })
    return {"ok": True, "processed": len(data.get("traffic", []))}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=3000)
PYEOF
}
write_panel_configs() {
    log_step "Запись конфигурации Panel"

    # ── Клонируем репо (или обновляем) ────────────────────────────────────
    local REPO="https://github.com/begugla0/ghostwave-test.git"
    if [[ -d /opt/ghostwave/.git ]]; then
        run_bg "Обновление репозитория" bash -c "cd /opt/ghostwave && git pull"
    else
        run_bg "Клонирование репозитория" \
            git clone --depth=1 "$REPO" /opt/ghostwave
    fi
    log_ok "Код приложения получен из GitHub"

    # ── .env (все секреты) ────────────────────────────────────────────────
    cat > /opt/ghostwave/.env << EOF
# GhostWave Panel — $(date '+%Y-%m-%d %H:%M:%S')
DATABASE_URL=postgresql+asyncpg://ghostwave:${DB_PASSWORD}@postgres:5432/ghostwave
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

    # ── Caddyfile ─────────────────────────────────────────────────────────
    cat > /opt/ghostwave/Caddyfile << EOF
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

    # ── Перезаписываем docker-compose.yml и Dockerfile ────────────────────
    # Это нужно т.к. в репо старые файлы с неверными путями
    cat > /opt/ghostwave/Dockerfile << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 3000
CMD ["python", "main.py"]
EOF
    log_ok "Dockerfile создан"

    cat > /opt/ghostwave/requirements.txt << 'EOF'
fastapi
uvicorn[standard]
sqlalchemy[asyncio]
asyncpg
pydantic<2.14
pydantic-settings<2.14
bcrypt
pyjwt
redis[asyncio]
httpx
aiogram
psutil
cryptography
python-multipart
EOF
    log_ok "requirements.txt создан"

    cat > /opt/ghostwave/docker-compose.yml << EOF
services:
  panel:
    build:
      context: /opt/ghostwave
      dockerfile: Dockerfile
    image: ghostwave-panel:latest
    container_name: ghostwave-panel
    restart: unless-stopped
    env_file: /opt/ghostwave/.env
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
      - /opt/ghostwave/Caddyfile:/etc/caddy/Caddyfile:ro
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

    # ── main.py — перезаписываем (в репо старая версия с субмодулями) ─────
    _write_main_py
    log_ok "main.py создан (самодостаточный, без субмодулей)"
}

write_node_configs() {
    log_step "Запись конфигурации Node"
    mkdir -p /opt/ghostwave-node
    mkdir -p /etc/ghostnet

    # В режиме panel+node порт 443 уже занят Caddy — используем 8443
    local effective_gn_port="${NODE_GN_PORT:-443}"
    if [[ "$INSTALL_MODE" == "panel+node" && "$effective_gn_port" == "443" ]]; then
        effective_gn_port="8443"
        NODE_GN_PORT="8443"
        log_warn "Режим panel+node: порт 443 занят Caddy, GhostNet переключён на 8443"
        ufw allow 8443/tcp comment "GhostNet VPN" >/dev/null 2>&1 || true
    fi

    local panel_url="${NODE_PANEL_URL:-https://${PANEL_DOMAIN}}"
    local panel_key="${NODE_PANEL_KEY:-${NODE_API_KEY}}"
    local agent_port="${NODE_AGENT_PORT:-2095}"

    # ── .env.node ─────────────────────────────────────────────────────────
    cat > /opt/ghostwave-node/.env.node << EOF
# GhostWave Node — $(date '+%Y-%m-%d %H:%M:%S')
NODE_ID=${NODE_ID}
NODE_API_KEY=${panel_key}
PANEL_URL=${panel_url}
AGENT_PORT=${agent_port}
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

    # ── agent.py — копируем из репо или создаём ───────────────────────────
    if [[ -f /opt/ghostwave/agent.py ]]; then
        cp /opt/ghostwave/agent.py /opt/ghostwave-node/agent.py
        log_ok "agent.py скопирован из Panel репо"
    else
        _write_agent_py
        log_ok "agent.py создан"
    fi

    # ── Dockerfile.node ───────────────────────────────────────────────────
    cat > /opt/ghostwave-node/Dockerfile.node << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc iproute2 iptables && \
    rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi "uvicorn[standard]" httpx \
    "pydantic<2.14" "pydantic-settings<2.14" \
    psutil cryptography
COPY agent.py .
CMD ["python", "agent.py"]
EOF
    log_ok "Dockerfile.node создан"

    # ── docker-compose.node.yml ───────────────────────────────────────────
    cat > /opt/ghostwave-node/docker-compose.yml << EOF
services:
  node-agent:
    build:
      context: /opt/ghostwave-node
      dockerfile: Dockerfile.node
    image: ghostwave-node:latest
    container_name: ghostwave-node
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      NODE_ID:                 "${NODE_ID}"
      NODE_API_KEY:            "${panel_key}"
      PANEL_URL:               "${panel_url}"
      AGENT_PORT:              "${agent_port}"
      AGENT_HOST:              "0.0.0.0"
      GHOSTNET_PORT:           "${effective_gn_port}"
      GHOSTNET_DOMAIN:         "${NODE_GN_DOMAIN}"
      GHOSTNET_SECRET:         "${NODE_GN_SECRET}"
      HEARTBEAT_INTERVAL:      "15"
      TRAFFIC_REPORT_INTERVAL: "60"
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

    # ── Убиваем старые контейнеры по имени напрямую ───────────────────────
    # docker compose down не работает если CWD неверный — убиваем явно
    for cname in ghostwave-panel ghostwave-caddy ghostwave-postgres ghostwave-redis; do
        if docker inspect "$cname" &>/dev/null; then
            docker rm -f "$cname" &>/dev/null || true
            log_info "Удалён старый контейнер: $cname"
        fi
    done

    # Если пароль БД изменился — удаляем volume (postgres хранит пароль в данных)
    # Проверяем через наличие label в volume или просто всегда при переустановке
    if docker volume inspect ghostwave_postgres-data &>/dev/null; then
        log_warn "Найден старый postgres volume — удаляем для чистой установки"
        docker volume rm ghostwave_postgres-data &>/dev/null || true
    fi

    cd /opt/ghostwave

    # ── Сборка и запуск ───────────────────────────────────────────────────
    run_bg "Сборка образа Panel" docker compose build panel

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
    if (( attempts >= 30 )); then
        echo -e "\r  ${CROSS} PostgreSQL не поднялся"
        log_info "Логи: docker logs ghostwave-postgres --tail 20"
        return
    fi

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
        echo -e "\r  ${WARN} ${Y}Panel не ответила за 120с${NC}"
        log_info "Логи: docker logs ghostwave-panel --tail 30"
    fi
}

start_node_services() {
    log_step "Запуск Node Agent"

    # Убиваем старый контейнер по имени
    if docker inspect ghostwave-node &>/dev/null; then
        docker rm -f ghostwave-node &>/dev/null || true
        log_info "Удалён старый контейнер: ghostwave-node"
    fi

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
        echo -e "\r  ${WARN} ${Y}Node Agent не ответил${NC}"
        log_info "Логи: docker logs ghostwave-node --tail 30"
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
        echo -e "  ${C}docker compose -f /opt/ghostwave/docker-compose.yml logs -f${NC}"
        echo -e "  ${C}docker compose -f /opt/ghostwave/docker-compose.yml restart${NC}"
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
