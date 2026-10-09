#!/bin/bash
# One-click self-installer: Dell 7567/7577 fast-transient fan control (Linux, no flash).
# Usage: ./one-click-install.sh   (no prompts; uses sudo -n, requires passwordless sudo once)
# Does: deps (pacman/yay/apt/dnf) + dell-smm-hwmon + i8kutils + dell-bios-fan-control +
#       fan loop + conf + systemd service + thermald. Idempotent.
set -u
REPO="$(cd "$(dirname "$0")" && pwd)"
FIX="$REPO/fan-fix"
die(){ echo "FATAL: $*" >&2; exit 1; }
[ -d "$FIX" ] || die "run from repo root (missing fan-fix/)"
sudo -n true 2>/dev/null || die "need passwordless sudo (see FAN_FIX_GUIDE)"
echo "== deps =="
if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm thermald || true
  command -v yay >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm yay || true
  command -v i8kfan >/dev/null 2>&1 || yay -S --noconfirm --needed i8kutils dell-bios-fan-control-git || true
elif command -v apt >/dev/null 2>&1; then
  sudo apt update -qq && sudo apt install -y -qq i8kutils thermald || true
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y -q i8kutils thermald || true
fi
echo "== driver =="
sudo modprobe dell-smm-hwmon restricted=0 force=1 || true
echo 'dell-smm-hwmon' | sudo tee /etc/modules-load.d/dell-smm.conf >/dev/null
echo 'options dell-smm-hwmon restricted=0 force=1' | sudo tee /etc/modprobe.d/dell-smm.conf >/dev/null
echo "== files =="
sudo install -m 0755 "$FIX/fan-control-fast.sh" /usr/local/bin/fan-control-fast.sh
sudo install -m 0644 "$FIX/dell-fanctl-fast.conf" /usr/local/etc/dell-fanctl.conf
sudo install -m 0644 "$FIX/dell-fanctl.service" /etc/systemd/system/dell-fanctl.service
sudo mkdir -p /etc/thermald
sudo install -m 0644 "$FIX/thermald-fast.xml" /etc/thermald/thermal-conf.xml
sudo systemctl daemon-reload
echo "== start =="
sudo systemctl enable --now dell-fanctl.service
sudo systemctl restart dell-fanctl.service
sudo systemctl restart thermald 2>/dev/null || true
sleep 4
systemctl status dell-fanctl --no-pager --lines=3
echo "--- live ---"
H=$(grep -l dell_smm /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
[ -n "$H" ] && echo "fans: $(cat $H/fan1_input 2>/dev/null) / $(cat $H/fan2_input 2>/dev/null) RPM, pwm $(cat $H/pwm1 2>/dev/null)/$(cat $H/pwm2 2>/dev/null), CPU $(cat $H/temp1_input 2>/dev/null) GPU $(cat $H/temp5_input 2>/dev/null)"
journalctl -u dell-fanctl --no-pager -n 5 | tail -n 5
echo "OK: tune via sudo nano /usr/local/etc/dell-fanctl.conf + sudo systemctl restart dell-fanctl"
