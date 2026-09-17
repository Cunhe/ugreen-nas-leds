#!/bin/bash
# Decorative white LEDs when the SATA HBA is PCI-passthrough (vfio-pci).
# When the HBA is host-owned (ahci / other), exit without touching LEDs so
# ugreen-diskiomon keeps full status logic (R/W blink, standby, SMART, etc.).
#
# Optional env (systemd Environment= or /etc/default/ugreen-passthrough-leds):
#   UGREEN_HBA_PCI=01:00.0                 # PCI BDF of the ASM116x / SATA HBA
#   UGREEN_PASSTHROUGH_BAYS="disk1 disk2 disk3 disk4"
#   UGREEN_PASSTHROUGH_COLOR="255 255 255"  # RGB
set -euo pipefail

[ -r /etc/default/ugreen-passthrough-leds ] && . /etc/default/ugreen-passthrough-leds

HBA_PCI="${UGREEN_HBA_PCI:-01:00.0}"
BAYS="${UGREEN_PASSTHROUGH_BAYS:-disk1 disk2 disk3 disk4}"
COLOR="${UGREEN_PASSTHROUGH_COLOR:-255 255 255}"

# Let probe / diskiomon settle first (oneshot also After= those units).
sleep 2

driver="$(lspci -k -s "$HBA_PCI" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2; exit}')"

if [ "$driver" = "vfio-pci" ]; then
  for d in $BAYS; do
    [ -e "/sys/class/leds/$d" ] || continue
    echo none > "/sys/class/leds/$d/trigger" 2>/dev/null || true
    echo "$COLOR" > "/sys/class/leds/$d/color" 2>/dev/null || true
    [ -e "/sys/class/leds/$d/multi_intensity" ] && echo "$COLOR" > "/sys/class/leds/$d/multi_intensity" 2>/dev/null || true
    echo 255 > "/sys/class/leds/$d/brightness" 2>/dev/null || true
  done
  logger -t ugreen-passthrough-leds "HBA $HBA_PCI is vfio-pci: set $BAYS to decorative white"
  exit 0
fi

logger -t ugreen-passthrough-leds "HBA $HBA_PCI driver=${driver:-unknown}: skip override (host monitoring owns LEDs)"
exit 0
