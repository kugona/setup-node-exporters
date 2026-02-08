#!/usr/bin/env bash
set -e

echo "🚀 Полная оптимизация сервера (VPN + Fail2Ban)"
echo "🖥️ ОС: $(. /etc/os-release && echo $PRETTY_NAME)"
echo "🧠 Ядро: $(uname -r)"
echo

# ----------------------
# 0️⃣ Проверка root
# ----------------------
if [[ $EUID -ne 0 ]]; then
  echo "❌ Запусти скрипт от root"
  exit 1
fi

# ----------------------
# 1️⃣ TCP / VPN оптимизация
# ----------------------
echo "🔧 Настраиваю TCP параметры (BBR, буферы, TIME_WAIT)"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-opt.conf"

cat <<EOF > "$SYSCTL_FILE"
# === VPN / TCP optimization ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# buffers
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# connections
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_syncookies=1
EOF

sysctl --system > /dev/null
echo "✅ TCP параметры применены"
echo

# ----------------------
# 2️⃣ Файловые дескрипторы
# ----------------------
echo "📂 Увеличиваю лимиты файловых дескрипторов"

cat <<EOF > /etc/security/limits.d/99-vpn.conf
* soft nofile 1048576
* hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d
cat <<EOF > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
EOF

systemctl daemon-reexec
echo "✅ Лимиты файловых дескрипторов настроены"
echo

# ----------------------
# 3️⃣ CPU governor
# ----------------------
echo "🔥 Проверяю CPU governor"
if ! command -v cpupower >/dev/null 2>&1; then
  echo "📦 Устанавливаю cpupower..."
  apt update -y > /dev/null
  apt install -y cpupower > /dev/null || true
fi

if command -v cpupower >/dev/null 2>&1; then
  if cpupower frequency-info 2>/dev/null | grep -q "performance"; then
    cpupower frequency-set -g performance > /dev/null 2>&1 || true
    echo "✅ CPU governor: performance"
  else
    echo "⚠️ Performance governor недоступен (нормально для VPS)"
  fi
else
  echo "⚠️ cpupower недоступен (пропускаю)"
fi
echo

# ----------------------
# 4️⃣ Отключение лишних сервисов
# ----------------------
echo "🧹 Отключаем systemd-resolved и firewalld"
systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true
echo "✅ Лишние сервисы отключены"
echo

# ----------------------
# 5️⃣ nf_conntrack tuning
# ----------------------
echo "⚡ Настройка nf_conntrack"
cat <<EOF > /etc/sysctl.d/99-vpn-conntrack.conf
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
EOF

sysctl --system > /dev/null
echo "✅ nf_conntrack оптимизирован"
echo

# ----------------------
# 6️⃣ Установка Fail2Ban
# ----------------------
echo "📦 Устанавливаем и настраиваем Fail2Ban"
apt update -y
apt install -y fail2ban

JAIL_LOCAL="/etc/fail2ban/jail.local"
echo "📝 Настраиваем jail.local (3 попытки, бан 1 час)"
cat <<EOF > "$JAIL_LOCAL"
[DEFAULT]
maxretry = 3
bantime = 3600
findtime = 600
logtarget = SYSLOG
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
EOF

echo "🔄 Перезапускаем fail2ban"
systemctl enable --now fail2ban

# ----------------------
# 7️⃣ Итог
# ----------------------
echo
echo "🎉 Оптимизация завершена!"
echo "🔍 Проверка:"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  ulimit -n"
echo "  ss -s"
echo "  fail2ban-client status"
echo "  fail2ban-client status sshd"
echo
echo "🔁 Рекомендуется перезагрузка сервера"
