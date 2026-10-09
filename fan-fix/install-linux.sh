#!/bin/bash
# Install software-level fan fix on Dell 7567/7577 Linux. No BIOS/EC flash.
# Supports Arch/CachyOS (pacman/yay), Debian (apt), Fedora (dnf). Idempotent.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "== 1/5 dell-smm-hwmon =="
sudo modprobe dell-smm-hwmon restricted=0 force=1 || true
echo 'dell-smm-hwmon' | sudo tee /etc/modules-load.d/dell-smm.conf >/dev/null
echo 'options dell-smm-hwmon restricted=0 force=1' | sudo tee /etc/modprobe.d/dell-smm.conf >/dev/null
ls /sys/class/hwmon/hwmon*/name 2>/dev/null | head
grep -l dell_smm /sys/class/hwmon/hwmon*/name 2>/dev/null || true
echo "== 2/5 tools (best effort, sysfs fallback works without i8kfan) =="
if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm thermald || true
  (command -v i8kfan >/dev/null 2>&1 || yay -S --noconfirm i8kutils dell-bios-fan-control-git || true)
elif command -v apt >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y i8kutils thermald || true
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y i8kutils thermald || true
fi
command -v i8kfan >/dev/null 2>&1 && { i8kfan 0 0 || true; sleep 1; i8kctl temp || true; } || echo "i8kfan absent, using /sys/class/hwmon sysfs pwm (hwmon with name dell_smm)"
cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -n 5 || true
echo "== 3/5 fan loop =="
sudo install -m 0755 fan-fix/fan-control-fast.sh /usr/local/bin/fan-control-fast.sh
sudo install -m 0644 fan-fix/dell-fanctl-fast.conf /usr/local/etc/dell-fanctl.conf
sudo install -m 0644 fan-fix/dell-fanctl.service /etc/systemd/system/dell-fanctl.service
sudo systemctl daemon-reload
echo "== 4/5 thermald =="
sudo mkdir -p /etc/thermald
sudo install -m 0644 fan-fix/thermald-fast.xml /etc/thermald/thermal-conf.xml
sudo systemctl restart thermald || echo "thermald not running, skipped"
echo "== 5/5 enable (starts on boot, BIOS auto restored on stop) =="
sudo systemctl enable --now dell-fanctl.service
echo "Check: sensors | grep -i fan; i8kctl temp; systemctl status dell-fanctl --no-pager"
echo "Tune: sudo nano /usr/local/etc/dell-fanctl.conf (LOW/HIGH/HYST/POLL/DERIV), sudo systemctl restart dell-fanctl"
echo "NBFC optional: copy fan-fix/NBFC_Dell_Inspiron_7567_7577_fast.xml to NBFC Configs only after ec-probe validates 148/149/147."
echo "SSDT optional: see fan-fix/ssdt-fanfix.dsl, initrd acpi_override only if _TSP still slow."
