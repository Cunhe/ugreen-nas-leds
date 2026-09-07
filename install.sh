#!/usr/bin/env bash
# One-shot installer for UGREEN DX/DXP front-panel LEDs on Debian-based hosts.
# Target: Proxmox VE 8 (Debian 12) and other Debian/Ubuntu hosts running on the bare metal.

set -euo pipefail

VERSION="$(cat "$(cd "$(dirname "$0")" && pwd)/VERSION" 2>/dev/null || echo 0.3.1-debian)"
DKMS_VER="0.3.1"
ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_PREFIX="[ugreen-leds]"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/miskcoo/ugreen_leds_controller.git}"

NETIF="${NETIF:-}"
MAPPING_METHOD="${MAPPING_METHOD:-ata}"
SKIP_APT="${SKIP_APT:-0}"
ENABLE_SERVICES="${ENABLE_SERVICES:-1}"

usage() {
    cat <<EOF
UGREEN NAS LED installer ${VERSION}

Must run as root on the physical host (PVE / Debian), not in a VM or LXC.

Usage:
  sudo bash install.sh
  sudo NETIF=enp3s0 bash install.sh
  sudo MAPPING_METHOD=serial bash install.sh
  sudo bash install.sh --status
  sudo bash install.sh --uninstall
EOF
}

log()  { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
err()  { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash install.sh"
}

not_container() {
    if [ -f /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ | grep -q '^container='; then
        die "this looks like an LXC/container. Install on the PVE/Debian HOST."
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt --container 2>/dev/null || true)"
        if [ -n "$virt" ] && [ "$virt" != "none" ]; then
            die "container detected (${virt}). Install on the physical host."
        fi
    fi
}

detect_distro() {
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}-${ID_LIKE:-}" in
        debian*|ubuntu*|*-debian*|*-ubuntu*) ;;
        *) log "warning: ID=${ID:-unknown} is not Debian-like; continuing anyway" ;;
    esac
    IS_PVE=0
    if command -v pveversion >/dev/null 2>&1 || [ -e /etc/pve ]; then
        IS_PVE=1
    fi
}

install_packages() {
    [ "$SKIP_APT" = "1" ] && { log "SKIP_APT=1, not installing packages"; return; }
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential dkms gcc g++ make git \
        i2c-tools smartmontools kmod \
        ca-certificates pciutils
    kver="$(uname -r)"
    if [ ! -d "/lib/modules/${kver}/build" ]; then
        log "kernel headers missing for ${kver}, installing..."
        if [ "$IS_PVE" -eq 1 ]; then
            apt-get install -y "proxmox-headers-${kver}" \
                || apt-get install -y "pve-headers-${kver}" \
                || apt-get install -y proxmox-default-headers \
                || die "cannot install PVE headers for ${kver}. Enable the pve-no-subscription repo and retry."
        else
            apt-get install -y "linux-headers-${kver}" \
                || apt-get install -y linux-headers-amd64 \
                || die "cannot install linux-headers for ${kver}"
        fi
    fi
    [ -d "/lib/modules/${kver}/build" ] || die "headers still missing: /lib/modules/${kver}/build"
}

ensure_vendor() {
    local need=0
    [ -f "${ROOT}/kmod/led-ugreen.c" ] || need=1
    [ -f "${ROOT}/cli/ugreen_leds_cli.cpp" ] || need=1
    [ -f "${ROOT}/scripts/ugreen-diskiomon" ] || need=1
    [ -f "${ROOT}/scripts/ugreen-netdevmon" ] || need=1
    [ -f "${ROOT}/scripts/ugreen-leds.conf" ] || need=1
    [ -f "${ROOT}/scripts/check-standby.cpp" ] || need=1
    [ "$need" -eq 0 ] && return 0

    log "some vendor sources are missing; cloning ${UPSTREAM_REPO}"
    command -v git >/dev/null 2>&1 || die "git is required to fetch upstream sources"
    local tmp
    tmp="$(mktemp -d)"
    git clone --depth 1 "$UPSTREAM_REPO" "$tmp/src"
    mkdir -p "${ROOT}/kmod" "${ROOT}/cli" "${ROOT}/scripts/systemd"
    cp -n "$tmp/src/kmod/led-ugreen.c" "${ROOT}/kmod/" 2>/dev/null || cp "$tmp/src/kmod/led-ugreen.c" "${ROOT}/kmod/"
    cp -n "$tmp/src/kmod/led-ugreen.h" "${ROOT}/kmod/" 2>/dev/null || true
    cp -n "$tmp/src/kmod/Makefile" "${ROOT}/kmod/" 2>/dev/null || true
    cp -n "$tmp/src/cli/"*.cpp "$tmp/src/cli/"*.h "$tmp/src/cli/Makefile" "${ROOT}/cli/" 2>/dev/null || true
    cp -n "$tmp/src/scripts/ugreen-diskiomon" "$tmp/src/scripts/ugreen-netdevmon" \
          "$tmp/src/scripts/ugreen-netdevmon-multi" "$tmp/src/scripts/ugreen-leds.conf" \
          "$tmp/src/scripts/blink-disk.cpp" "$tmp/src/scripts/check-standby.cpp" \
          "$tmp/src/scripts/ugreen-probe-leds" "$tmp/src/scripts/ugreen-power-led" \
          "${ROOT}/scripts/" 2>/dev/null || true
    rm -rf "$tmp"
    [ -f "${ROOT}/kmod/led-ugreen.c" ] || die "failed to obtain kmod/led-ugreen.c"
    [ -f "${ROOT}/scripts/ugreen-diskiomon" ] || die "failed to obtain scripts/ugreen-diskiomon"
}

ensure_i2c() {
    modprobe i2c-dev || true
    modprobe i2c-i801 || true
    if ! i2cdetect -l 2>/dev/null | grep -q "SMBus I801 adapter"; then
        die "SMBus I801 adapter not found. This board is not a supported UGREEN DX/DXP LED path."
    fi
    bus_num="$(i2cdetect -l | awk '/SMBus I801 adapter/{print $1; exit}')"
    bus_num="${bus_num#i2c-}"
    log "I801 adapter is i2c-${bus_num}"
    scan="$(i2cdetect -y "${bus_num}" 2>/dev/null || true)"
    if ! printf '%s' "$scan" | grep -Eq '(^|[[:space:]])3a([[:space:]]|$)'; then
        err "address 0x3a not visible on i2c-${bus_num}."
        printf '%s\n' "$scan"
        die "LED MCU not detected. Stop here rather than installing a dead module."
    fi
    log "LED MCU 0x3a detected"
}

pick_netif() {
    if [ -n "$NETIF" ]; then
        [ -d "/sys/class/net/${NETIF}" ] || die "NETIF=${NETIF} does not exist"
        return
    fi
    local iface state
    for iface in /sys/class/net/*; do
        iface="$(basename "$iface")"
        case "$iface" in
            lo|docker*|veth*|fwbr*|fwln*|fwpr*|tap*|tun*|bonding_masters) continue ;;
        esac
        if [ -d "/sys/class/net/${iface}/bridge" ]; then
            continue
        fi
        state="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo down)"
        if [ "$state" = "up" ]; then
            NETIF="$iface"
            break
        fi
    done
    if [ -z "$NETIF" ]; then
        NETIF="$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
    [ -n "$NETIF" ] || {
        log "warning: no NIC detected; netdev LED service will not be enabled"
        return
    }
    log "netdev LED will follow ${NETIF}"
}

install_kmod() {
    local src="/usr/src/led-ugreen-${DKMS_VER}"
    if dkms status led-ugreen 2>/dev/null | grep -q .; then
        log "removing previous DKMS led-ugreen builds"
        dkms remove led-ugreen/"${DKMS_VER}" --all 2>/dev/null || true
        dkms remove led-ugreen/0.3 --all 2>/dev/null || true
        dkms remove led-ugreen/0.1 --all 2>/dev/null || true
    fi
    rm -rf "$src"
    mkdir -p "$src"
    cp -a "${ROOT}/kmod/." "$src/"
    dkms add -m led-ugreen -v "${DKMS_VER}"
    dkms build -m led-ugreen -v "${DKMS_VER}" -k "$(uname -r)"
    dkms install -m led-ugreen -v "${DKMS_VER}" -k "$(uname -r)"
    log "DKMS led-ugreen/${DKMS_VER} installed for $(uname -r)"
}

install_cli_and_helpers() {
    log "building CLI"
    make -C "${ROOT}/cli" clean >/dev/null 2>&1 || true
    make -C "${ROOT}/cli" -j"$(nproc)"
    install -m 0755 "${ROOT}/cli/ugreen_leds_cli" /usr/bin/ugreen_leds_cli
    if command -v g++ >/dev/null 2>&1; then
        log "building optional disk helpers"
        g++ -std=c++17 -O2 "${ROOT}/scripts/blink-disk.cpp" -o /usr/bin/ugreen-blink-disk
        g++ -std=c++17 -O2 "${ROOT}/scripts/check-standby.cpp" -o /usr/bin/ugreen-check-standby
    fi
    local f
    for f in ugreen-diskiomon ugreen-netdevmon ugreen-netdevmon-multi \
             ugreen-power-led ugreen-probe-leds ugreen-detect-disks \
             ugreen-detect-network ugreen-leds-status; do
        [ -f "${ROOT}/scripts/${f}" ] || continue
        install -m 0755 "${ROOT}/scripts/${f}" "/usr/bin/${f}"
    done
}

install_config() {
    mkdir -p /etc
    if [ ! -f /etc/ugreen-leds.conf ]; then
        install -m 0644 "${ROOT}/scripts/ugreen-leds.conf" /etc/ugreen-leds.conf
    else
        log "keeping existing /etc/ugreen-leds.conf"
    fi
    if grep -q '^MAPPING_METHOD=' /etc/ugreen-leds.conf; then
        sed -i "s/^MAPPING_METHOD=.*/MAPPING_METHOD=${MAPPING_METHOD}/" /etc/ugreen-leds.conf
    fi
    cat > /etc/modules-load.d/ugreen-led.conf <<'EOF'
i2c-dev
i2c-i801
led-ugreen
ledtrig-oneshot
ledtrig-netdev
EOF
    install -m 0644 "${ROOT}/scripts/systemd/"*.service /etc/systemd/system/
}

load_and_probe() {
    modprobe ledtrig-oneshot || true
    modprobe ledtrig-netdev || true
    modprobe led-ugreen || die "modprobe led-ugreen failed"
    /usr/bin/ugreen-probe-leds
    if [ ! -e /sys/class/leds/power ]; then
        die "probe finished but /sys/class/leds/power is missing"
    fi
    log "LEDs registered:"
    ls -1 /sys/class/leds | awk '/^(power|netdev|disk[0-9]+)$/{print "  "$0}'
}

enable_services() {
    systemctl daemon-reload
    systemctl enable --now ugreen-probe-leds.service
    systemctl enable --now ugreen-diskiomon.service
    systemctl enable --now ugreen-power-led.service
    if [ -n "${NETIF}" ]; then
        systemctl enable --now "ugreen-netdevmon@${NETIF}.service"
    fi
}

print_next() {
    cat <<EOF

${LOG_PREFIX} install complete.

  DMI     : $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)
  kernel  : $(uname -r)
  mapping : ${MAPPING_METHOD}
  netif   : ${NETIF:-none}

Useful commands:
  ugreen-leds-status
  ugreen-detect-disks ${MAPPING_METHOD}
  ls /sys/class/leds
  journalctl -u ugreen-diskiomon -u ugreen-probe-leds -f

If a disk LED does not match the physical bay:
  1) run: ugreen-detect-disks ata
  2) edit /etc/ugreen-leds.conf
  3) systemctl restart ugreen-diskiomon

To uninstall:
  sudo bash ${ROOT}/uninstall.sh
EOF
}

do_status() {
    if [ -x /usr/bin/ugreen-leds-status ]; then
        /usr/bin/ugreen-leds-status
    else
        "${ROOT}/scripts/ugreen-leds-status"
    fi
}

do_uninstall() {
    exec bash "${ROOT}/uninstall.sh"
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --status) need_root; do_status; exit 0 ;;
        --uninstall) need_root; do_uninstall ;;
        ""|--install) ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    need_root
    not_container
    detect_distro
    log "installing ugreen-nas-leds ${VERSION} on $(uname -r) (pve=${IS_PVE})"
    install_packages
    ensure_vendor
    ensure_i2c
    pick_netif
    install_kmod
    install_cli_and_helpers
    install_config
    load_and_probe
    if [ "$ENABLE_SERVICES" = "1" ]; then
        enable_services
    else
        log "ENABLE_SERVICES=0, units installed but not started"
    fi
    print_next
}

main "$@"
