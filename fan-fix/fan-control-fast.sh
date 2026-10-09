#!/bin/bash
# Dell 7567/7577 fast-transient fan loop (SMM path, no EC flash).
# Requires: dell-smm-hwmon (modprobe), i8kutils, dell-bios-fan-control (to disable BIOS auto).
# Why this fixes lag: stock DPTF _TSP=CPUS/SSP1-8 (~3s) + _NTT=0xADE + GTSH=4C + _AC steps 2/5/10C
# hold fan low through a spike and high after cool-down. This loop polls 2s, kicks early at 50C,
# uses 3C down-hysteresis for fast spin-down, and forces max on dT/dt spike (derivative kick).
# Source: DSDT GENS/SMI 0xE0 path, DptfTa1/2 _TSP/_AC/GTSH, EC PHCM encrypted (no direct EC table mod).
set -u
CONF="${1:-/usr/local/etc/dell-fanctl.conf}"
[ -f "$CONF" ] && source "$CONF"
TEMP_LOW=${TEMP_LOW:-58}
TEMP_HIGH=${TEMP_HIGH:-70}
TEMP_LOW_GPU=${TEMP_LOW_GPU:-58}
TEMP_HIGH_GPU=${TEMP_HIGH_GPU:-70}
HYST_OFFSET=${HYST_OFFSET:-3}
POLL_INTERVAL=${POLL_INTERVAL:-2}
DERIV_KICK=${DERIV_KICK:-6}   # temp rise C/poll -> full blast immediately
POWER_HIGH=${POWER_HIGH:-40}   # package W >= this -> full blast (7700HQ PL1 45W/PL2 60W; 40W catches turbo early, steadier than freq)
POWER_DELTA=${POWER_DELTA:-25} # package W jump/poll -> full blast (25W ignores idle 10-25W wobble, catches 10->40W bursts)
POWER_LOW=${POWER_LOW:-10}     # package W below this -> workload over, drop max->1 even before temp falls
MAX_STATE=${MAX_STATE:-2}      # i8k states 0/1/2 (3=auto on some, do NOT use here)

prev=0
prev_power=0
state=0
first_run=1
# Disable BIOS auto once at start (EC fights sysfs pwm otherwise -> snaps back to 0).
# Service also does ExecStartPre/ExecStopPost, this is belt-and-suspenders for manual runs.
command -v dell-bios-fan-control >/dev/null 2>&1 && dell-bios-fan-control 0 >/dev/null 2>&1 || true
# Resolve hwmon paths dynamically (numbering shifts across reboots)
DELL_HWMON="$(grep -l dell_smm /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo /sys/class/hwmon/hwmon4)"
CORE_HWMON="$(grep -l coretemp /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo /sys/class/hwmon/hwmon5)"
set_fan() {
  # Shared cooler: $1 = 0,1,2 drives BOTH Processor + Video fans together.
  # Try i8kfan first (sets fan 0+1), fallback to sysfs pwm 0/120/255 on both pwm1+pwm2.
  if command -v i8kfan >/dev/null 2>&1; then
    i8kfan "$1" "$1" >/dev/null 2>&1 && return
  fi
  pwm_val=0; [ "$1" -eq 1 ] && pwm_val=120; [ "$1" -ge 2 ] && pwm_val=255
  for f in "$DELL_HWMON"/pwm1 "$DELL_HWMON"/pwm2; do
    [ -w "$f" ] && echo "$pwm_val" > "$f" 2>/dev/null || sudo sh -c "echo $pwm_val > $f" 2>/dev/null || true
  done
}
read_temps() {
  # Shared heatpipe: control on max(CPU, GPU). Ignore nvme/pch/acpitz/ambient.
  # CPU: max(coretemp Package/Core, dell_smm CPU temp1)
  # GPU: max(dell_smm GPU temp5, nvidia-smi)
  cpu_coretemp=$(cat "$CORE_HWMON"/temp*_input 2>/dev/null | sort -n | tail -1)
  [ -z "${cpu_coretemp:-}" ] && cpu_coretemp=0
  cpu_coretemp=$((cpu_coretemp/1000))
  dell_cpu=$(cat "$DELL_HWMON/temp1_input" 2>/dev/null || echo 0); dell_cpu=$((dell_cpu/1000))
  dell_gpu=$(cat "$DELL_HWMON/temp5_input" 2>/dev/null || echo 0); dell_gpu=$((dell_gpu/1000))
  nv_gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || echo 0)
  [ -z "${nv_gpu:-}" ] && nv_gpu=0
  cpu=$cpu_coretemp; [ "$dell_cpu" -gt "$cpu" ] && cpu=$dell_cpu
  gpu=$dell_gpu; [ "$nv_gpu" -gt "$gpu" ] && gpu=$nv_gpu
  # Shared cooler: hottest die drives BOTH fans
  cur=$cpu; src="CPU"; [ "$gpu" -gt "$cur" ] && { cur=$gpu; src="GPU"; }
  echo "$cur $cpu $gpu $src"
}
echo "dell-fanctl fast shared-cooler: CPU LOW=$TEMP_LOW HIGH=$TEMP_HIGH / GPU LOW=$TEMP_LOW_GPU HIGH=$TEMP_HIGH_GPU HYST=$HYST_OFFSET POLL=$POLL_INTERVAL tempKICK>$DERIV_KICK power>=$POWER_HIGH/jump>$POWER_DELTA W max(CPU,GPU,power)->both fans"
prev_energy=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo 0)
prev_energy_max=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null || echo 262143328850)
while true; do
  read cur cpu gpu src <<< $(read_temps)
  # Package power from RAPL delta since last poll (service is root; manual runs may need sudo)
  cur_energy=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo 0)
  if [ "$cur_energy" -ge "$prev_energy" ]; then d_e=$((cur_energy-prev_energy)); else d_e=$((prev_energy_max-prev_energy+cur_energy)); fi
  power=$((d_e/POLL_INTERVAL/1000000))
  [ "$power" -lt 0 ] && power=0; [ "$power" -gt 200 ] && power=200
  if [ "$first_run" -eq 1 ]; then prev=$cur; prev_power=$power; dpower=0; dt=0; first_run=0; fi
  # Per-die thresholds: GPU trips 5C lower (shared pipe, GTX1050 soaks fast)
  if [ "$src" = "GPU" ]; then low=$TEMP_LOW_GPU; high=$TEMP_HIGH_GPU; else low=$TEMP_LOW; high=$TEMP_HIGH; fi
  mid=$(( (low+high)/2 ))
  dt=$((cur - prev))
  dpower=$((power - prev_power))
  # Temp delta kick: rise >5C/poll on EITHER die -> full blast immediately
  # Power feedforward: package burst means heat is incoming before temp follows (steadier than freq)
  if { [ "$dt" -gt 5 ] || [ "$power" -ge "$POWER_HIGH" ] || [ "$dpower" -ge "$POWER_DELTA" ]; } && [ "$state" -lt "$MAX_STATE" ]; then
    state=$MAX_STATE
    set_fan "$state"
    echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W dT=+${dt} dP=+${dpower} KICK -> both fans $state (full blast)"
  elif [ "$cur" -ge "$high" ]; then
    [ "$state" -ne "$MAX_STATE" ] && { state=$MAX_STATE; set_fan "$state"; echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) >=HIGH($high) -> both fans $state"; }
  elif [ "$cur" -ge "$mid" ] && [ "$state" -eq 0 ]; then
    state=1; set_fan "$state"; echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) mid($mid) -> both fans $state"
  elif [ "$cur" -le "$((low-HYST_OFFSET))" ]; then
    [ "$state" -ne 0 ] && { state=0; set_fan "$state"; echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) <=LOW-HYST($((low-HYST_OFFSET))) -> both fans $state"; }
  elif [ "$power" -lt "$POWER_LOW" ] && [ "$state" -eq "$MAX_STATE" ]; then
    state=1; set_fan "$state"; echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W<LOW($POWER_LOW) workload over -> both fans $state"
  elif [ "$cur" -le "$((high-HYST_OFFSET))" ] && [ "$state" -eq "$MAX_STATE" ]; then
    state=1; set_fan "$state"; echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W <=HIGH-HYST($((high-HYST_OFFSET))) -> both fans $state"
  fi
  prev=$cur
  prev_power=$power
  prev_energy=$cur_energy
  sleep "$POLL_INTERVAL"
done
