#!/bin/bash
# GhostWave Panel — быстрая установка
# Запуск: bash install-panel.sh

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo -e "${BOLD}"
cat << 'EOF'
   ____  _               _    __        __
  / ___|| |__   ___  ___| |_  \ \      / /_ ___   _____
 | |  _ | '_ \ / _ \/ __| __|  \ \ /\ / / _` \ \ / / _ \
 | |_| || | | | (_) \__ \ |_    \ V  V / (_| |\ V /  __/
  \____||_| |_|\___/|___/\__|    \_/\_/ \__,_| \_/ \___|

  Panel v1.0 — Installation Script
EOF
echo -e "${NC}"

# Проверки
[[ $EUID -ne 0 ]] && error "Запускайте от root (sudo bash install-panel.sh)"
command -v docker    &>/dev/null || error "Docker не найден. Установите: https://docs.docker.com/engine/install/"
command -v docker compose &>/dev/null || error "Docker Compose v2 не найден"

INSTALL_DIR="/opt/ghostwave"
info "Директория установки: $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Генерируем секреты
gen_secret() { python3 -c "import secrets; print(secrets.token_hex(32))"; }

if [ ! -f .env ]; then
    info "Создаём .env файл..."

    read -rp "$(echo -e "${BOLD}Домен панели${NC} (например panel.example.com): ")" PANEL_DOMAIN
    read -rp "$(echo -e "${BOLD}Admin username${NC} [admin]: ")" ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -rsp "$(echo -e "${BOLD}Admin password${NC}: ")" ADMIN_PASS; echo
    read -rp "$(echo -e "${BOLD}Telegram Bot Token${NC} (оставьте пустым если нет): ")" TG_TOKEN
    read -rp "$(echo -e "${BOLD}Ваш Telegram ID${NC} (оставьте пустым): ")" TG_ID

    DB_PASS=$(gen_secret)
    JWT_SECRET=$(gen_secret)
    SECRET_KEY=$(gen_secret)
    NODE_API_KEY=$(gen_secret)

    cat > .env << EOF
DB_PASSWORD=$DB_PASS
JWT_SECRET=$JWT_SECRET
SECRET_KEY=$SECRET_KEY
NODE_API_KEY=$NODE_API_KEY
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASS
TELEGRAM_BOT_TOKEN=$TG_TOKEN
TELEGRAM_ADMIN_IDS=[${TG_ID:-}]
SUB_BASE_URL=https://$PANEL_DOMAIN
REDIS_PASSWORD=$(gen_secret)
EOF

    success ".env создан"
else
    warn ".env уже существует, пропускаем"
fi

# Копируем docker-compose если не существует
if [ ! -f docker-compose.yml ]; then
    # В реальном деплое здесь wget/curl из репозитория
    error "docker-compose.yml не найден. Скопируйте из репозитория."
fi

info "Запускаем сервисы..."
docker compose pull
docker compose up -d

info "Ждём запуска базы данных..."
sleep 5

success "GhostWave Panel установлен!"
echo ""
echo -e "${BOLD}=== Итог ===${NC}"
source .env
echo -e "🌐 Панель:       ${CYAN}https://$PANEL_DOMAIN${NC}"
echo -e "🔑 API Docs:     ${CYAN}https://$PANEL_DOMAIN/api/docs${NC}"
echo -e "👤 Admin login:  ${BOLD}$ADMIN_USERNAME${NC}"
echo -e "🔒 NODE_API_KEY: ${YELLOW}$NODE_API_KEY${NC}"
echo ""
echo -e "${YELLOW}Сохраните NODE_API_KEY — он понадобится при установке нод!${NC}"
echo ""
echo -e "Установка ноды на VPN-сервере:"
echo -e "  ${CYAN}bash install-node.sh${NC}"
