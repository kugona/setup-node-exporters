#!/usr/bin/env bash
set -euo pipefail

NODE_EXPORTER_VER="1.10.2"
PROMETHEUS_VER="3.9.1"
XRAY_EXPORTER_REPO="compassvpn/xray-exporter"
XRAY_EXPORTER_VER="latest"

INSTALL_DIR="/opt/monitoring"
SYSTEMD_DIR="/etc/systemd/system"

NODE_PORT=9100
XRAY_PORT=9639
PROM_PORT=9090

read -r -p "IP основного сервера с Prometheus/Grafana: " MAIN_PROM_IP
if [[ ! "$MAIN_PROM_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Некорректный IP"
    exit 1
fi

read -r -p "Порт основного Prometheus [9090]: " MAIN_PROM_PORT
MAIN_PROM_PORT=${MAIN_PROM_PORT:-9090}

read -r -p "Xray API адрес:порт [127.0.0.1:54312]: " XRAY_API_ADDR
XRAY_API_ADDR=${XRAY_API_ADDR:-"127.0.0.1:54312"}

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz"
tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz" --strip-components=1
rm "node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz"
ln -sf "$INSTALL_DIR/node_exporter" /usr/local/bin/node_exporter

if [[ "$XRAY_EXPORTER_VER" == "latest" ]]; then
    ASSET_URL=$(curl -s "https://api.github.com/repos/${XRAY_EXPORTER_REPO}/releases/latest" | grep "browser_download_url.*linux-amd64.*tar.gz" | cut -d '"' -f 4 | head -n1)
else
    ASSET_URL="https://github.com/${XRAY_EXPORTER_REPO}/releases/download/${XRAY_EXPORTER_VER}/xray-exporter-${XRAY_EXPORTER_VER}.linux-amd64.tar.gz"
fi

wget -q "$ASSET_URL" -O xray.tar.gz
tar -xzf xray.tar.gz --strip-components=1 || tar -xzf xray.tar.gz
chmod +x xray-exporter
rm xray.tar.gz
ln -sf "$INSTALL_DIR/xray-exporter" /usr/local/bin/xray-exporter

wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VER}/prometheus-${PROMETHEUS_VER}.linux-amd64.tar.gz"
tar -xzf "prometheus-${PROMETHEUS_VER}.linux-amd64.tar.gz" --strip-components=1
rm "prometheus-${PROMETHEUS_VER}.linux-amd64.tar.gz"
ln -sf "$INSTALL_DIR/prometheus" /usr/local/bin/prometheus
ln -sf "$INSTALL_DIR/promtool" /usr/local/bin/promtool

cat > prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:${NODE_PORT}']
  - job_name: xray
    static_configs:
      - targets: ['127.0.0.1:${XRAY_PORT}']

remote_write:
  - url: http://${MAIN_PROM_IP}:${MAIN_PROM_PORT}/api/v1/write
EOF

chown -R nobody:nogroup "$INSTALL_DIR" 2>/dev/null || true

cat > "${SYSTEMD_DIR}/node-exporter.service" <<EOF
[Unit]
Description=Node Exporter
After=network.target
[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:${NODE_PORT}
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > "${SYSTEMD_DIR}/xray-exporter.service" <<EOF
[Unit]
Description=Xray Exporter
After=network.target
[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/xray-exporter -listen :${XRAY_PORT} -xray http://${XRAY_API_ADDR}/stats
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > "${SYSTEMD_DIR}/prometheus.service" <<EOF
[Unit]
Description=Prometheus
After=network.target
[Service]
User=nobody
Group=nogroup
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/local/bin/prometheus \
  --config.file=${INSTALL_DIR}/prometheus.yml \
  --storage.tsdb.path=${INSTALL_DIR}/data \
  --web.listen-address=0.0.0.0:${PROM_PORT} \
  --web.enable-lifecycle
Restart=always
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

for svc in node-exporter xray-exporter prometheus; do
    systemctl enable --now "$svc" >/dev/null 2>&1
done

echo "Установка завершена"
echo "Prometheus: http://<IP>:${PROM_PORT}"
echo "Метрики: :${NODE_PORT}/metrics   :${XRAY_PORT}/metrics"
echo "remote_write → ${MAIN_PROM_IP}:${MAIN_PROM_PORT}"