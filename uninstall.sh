#!/usr/bin/env bash
# Remove files, services and the DKMS module installed by install.sh.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "[ugreen-leds] stopping services"
systemctl disable --now ugreen-diskiomon.service 2>/dev/null || true
systemctl disable --now ugreen-power-led.service 2>/dev/null || true
systemctl disable --now ugreen-probe-leds.service 2>/dev/null || true
systemctl disable --now ugreen-netdevmon-multi.service 2>/dev/null || true
systemctl list-units --type=service --all 'ugreen-netdevmon@*' --no-legend \
    | awk '{print $1}' \
    | while read -r unit; do
        [ -n "$unit" ] && systemctl disable --now "$unit" 2>/dev/null || true
    done

echo "[ugreen-leds] unloading module"
modprobe -r led-ugreen 2>/dev/null || true

echo "[ugreen-leds] removing DKMS module"
for ver in 0.3.1 0.3 0.1; do
    dkms remove "led-ugreen/${ver}" --all 2>/dev/null || true
    rm -rf "/usr/src/led-ugreen-${ver}"
done

echo "[ugreen-leds] removing files"
rm -f /usr/bin/ugreen_leds_cli \
      /usr/bin/ugreen-blink-disk \
      /usr/bin/ugreen-check-standby \
      /usr/bin/ugreen-diskiomon \
      /usr/bin/ugreen-netdevmon \
      /usr/bin/ugreen-netdevmon-multi \
      /usr/bin/ugreen-power-led \
      /usr/bin/ugreen-probe-leds \
      /usr/bin/ugreen-detect-disks \
      /usr/bin/ugreen-detect-network \
      /usr/bin/ugreen-leds-status
rm -f /etc/systemd/system/ugreen-diskiomon.service \
      /etc/systemd/system/ugreen-netdevmon-multi.service \
      /etc/systemd/system/ugreen-netdevmon@.service \
      /etc/systemd/system/ugreen-power-led.service \
      /etc/systemd/system/ugreen-probe-leds.service
rm -f /etc/modules-load.d/ugreen-led.conf
systemctl daemon-reload

echo "[ugreen-leds] left in place (edit by hand if you want it gone): /etc/ugreen-leds.conf"
echo "[ugreen-leds] uninstall complete"
