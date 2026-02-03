#!/usr/bin/env bash
set -euo pipefail

PROM_VERSION="3.9.1"
INSTALL_DIR="/opt/monitoring"
DOCKER_NET="monitoring"

echo "=== Установка Prometheus monitoring stack (FINAL) ==="

# ---------------- INPUT ----------------
read -r -p "IP сервера, который будет подключаться к Prometheus: " MAIN_IP
if [[ ! "$MAIN_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "❌ Некорректный IP"
  exit 1
fi

read -r -p "Порт Prometheus [9090]: " PROM_PORT
PROM_PORT=${PROM_PORT:-9090}

read -r -p "Xray API адрес [127.0.0.1:54312]: " XRAY_API
XRAY_API=${XRAY_API:-127.0.0.1:54312}

echo

# ---------------- UFW ----------------
echo "👉 Настраиваю UFW..."

if ! command -v ufw >/dev/null; then
  echo "❌ UFW не установлен. Установи ufw и включи его."
  exit 1
fi

# разрешаем доступ к Prometheus только с нужного IP
ufw allow from "${MAIN_IP}" to any port "${PROM_PORT}" proto tcp comment 'Prometheus access (restricted)'

# запрещаем всё лишнее
ufw deny "${PROM_PORT}"
ufw deny 9100
ufw deny 9639

ufw reload
echo "✔ UFW настроен"
echo

# ---------------- DOCKER ----------------
echo "👉 Проверяю Docker..."

if ! command -v docker >/dev/null; then
  echo "👉 Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | sh
fi

if ! command -v docker-compose >/dev/null; then
  echo "👉 Устанавливаю docker-compose..."
  curl -L https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-$(uname -s)-$(uname -m) \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

echo "✔ Docker готов"
echo

# ---------------- FILES ----------------
echo "👉 Создаю конфигурацию..."

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Prometheus config
cat > prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['node_exporter:9100']

  - job_name: xray
    static_configs:
      - targets: ['xray-exporter:9639']
EOF

# docker-compose
cat > docker-compose.yml <<EOF
version: "3.9"

networks:
  ${DOCKER_NET}:
    driver: bridge

services:
  node_exporter:
    image: quay.io/prometheus/node-exporter:latest
    container_name: node_exporter
    restart: unless-stopped
    networks: [${DOCKER_NET}]
    command:
      - '--path.rootfs=/host'
    volumes:
      - '/:/host:ro,rslave'

  xray-exporter:
    image: ghcr.io/compassvpn/xray-exporter:latest
    container_name: xray-exporter
    restart: unless-stopped
    networks: [${DOCKER_NET}]
    command:
      - '-listen=:9639'
      - '-xray=http://${XRAY_API}/stats'

  prometheus:
    image: prom/prometheus:v${PROM_VERSION}
    container_name: prometheus
    restart: unless-stopped
    networks: [${DOCKER_NET}]
    ports:
      - "0.0.0.0:${PROM_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--web.listen-address=0.0.0.0:9090'
EOF

echo "✔ Конфигурация готова"
echo

# ---------------- START ----------------
echo "👉 Запускаю контейнеры..."
docker-compose up -d

echo
echo "✅ УСТАНОВКА ЗАВЕРШЕНА"
echo
echo "Prometheus доступен:"
echo "  http://${MAIN_IP}:${PROM_PORT}"
echo
echo "Доступ:"
echo "  ✔ разрешён ТОЛЬКО с ${MAIN_IP}"
echo "  ✖ exporters извне недоступны"
echo "  ✖ лишние порты закрыты UFW"
echo
echo "Docker network: ${DOCKER_NET}"
echo
