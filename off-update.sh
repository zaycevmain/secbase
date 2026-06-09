#!/bin/sh
set -e

echo "== Отключаем unattended-upgrades =="

sudo systemctl disable --now unattended-upgrades 2>/dev/null || true

echo "== Отключаем apt timers =="

sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

echo "== Маскируем службы =="

sudo systemctl mask unattended-upgrades.service \
    apt-daily.timer \
    apt-daily-upgrade.timer 2>/dev/null || true

echo "== Настройка APT автообновлений =="

CONF="/etc/apt/apt.conf.d/20auto-upgrades"

if [ -f "$CONF" ]; then
    sudo sed -i 's/"1"/"0"/g' "$CONF"
else
    echo "Создаём $CONF"
    cat <<EOF | sudo tee "$CONF" >/dev/null
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
fi

echo "== Удаление unattended-upgrades =="

sudo apt purge -y unattended-upgrades 2>/dev/null || true
sudo apt autoremove -y

echo "== Проверка Docker =="

if command -v docker >/dev/null 2>&1; then
    echo "Docker найден"
    sudo systemctl disable --now docker.timer 2>/dev/null || true
fi

echo "== Отключаем snap автообновления =="

if command -v snap >/dev/null 2>&1; then
    sudo systemctl disable --now snapd.refresh.timer 2>/dev/null || true
    sudo systemctl mask snapd.refresh.timer 2>/dev/null || true

    sudo snap set system refresh.disabled=true || true
    sudo snap get system refresh.disabled || true
fi

echo "== Проверка таймеров =="

systemctl list-timers | grep -E "apt|snap|unattended|update|upgrade" || echo "OK: таймеры не найдены"

echo "== Проверка статусов =="

systemctl status unattended-upgrades 2>&1 | grep -E "Active|Loaded" || true
systemctl status apt-daily.timer 2>&1 | grep "Active" || true
systemctl status snapd.refresh.timer 2>&1 | grep "Active" || true

echo "== Готово =="
