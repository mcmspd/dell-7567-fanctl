#!/bin/bash
# Dell 7567/7577 fast-transient fan loop (SMM path, no EC flash).
# Requires: dell-smm-hwmon (modprobe), i8kutils, dell-bios-fan-control (to disable BIOS auto).
# Why this fixes lag: stock DPTF _TSP=CPUS/SSP1-8 (~3s) + _NTT=0xADE + GTSH=4C + _AC steps 2/5/10C
# hold fan low through a spike and high after cool-down. This loop polls 2s, stages 0->1
# on sustained kick/mid-level, promotes 1->2 only on confirmed heavy load, steps down
# with dwell (never cuts out), and uses 3C down-hysteresis for spin-down.
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
DERIV_KICK=${DERIV_KICK:-8}   # temp rise C/poll -> stage-one kick (needs KICK_SUSTAIN consecutive polls)
POWER_HIGH=${POWER_HIGH:-45}   # package W >= this + temp>=LOW -> stage-one kick (7700HQ PL1 45W/PL2 60W; 45W ignores trivial turbo bursts)
POWER_DELTA=${POWER_DELTA:-30} # package W jump/poll + temp>=LOW -> stage-one kick (30W ignores idle 10-25W wobble, catches sustained bursts)
POWER_LOW=${POWER_LOW:-10}     # package W below this counts as cool (step 2->1) even before temp falls
KICK_SUSTAIN=${KICK_SUSTAIN:-2} # consecutive kick polls required before 0->1 (kills single-poll sensor/RAPL noise)
PROMOTE_SUSTAIN=${PROMOTE_SUSTAIN:-3} # consecutive heavy polls in state 1 before 1->2 (heavy = temp>=HIGH, or temp>=mid with power>=POWER_HIGH)
DOWN_SUSTAIN=${DOWN_SUSTAIN:-3} # consecutive cool polls required before stepping down 2->1 or 1->0 (no abrupt cut, no flap)
EMERG_HIGH=${EMERG_HIGH:-85}   # thermal safety net: temp>=this -> immediate MAX from any state (25C below 95C critical)
MAX_STATE=${MAX_STATE:-2}      # i8k states 0/1/2 (3=auto on some, do NOT use here)

prev=0
prev_power=0
kick_hits=0
heavy_hits=0
cool_hits=0
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
echo "dell-fanctl staged shared-cooler: CPU LOW=$TEMP_LOW HIGH=$TEMP_HIGH EMERG=$EMERG_HIGH / GPU LOW=$TEMP_LOW_GPU HIGH=$TEMP_HIGH_GPU HYST=$HYST_OFFSET POLL=$POLL_INTERVAL kick>=${DERIV_KICK}C/${POWER_HIGH}W/Δ${POWER_DELTA}W x${KICK_SUSTAIN}->1, heavy x${PROMOTE_SUSTAIN}->2, cool x${DOWN_SUSTAIN} steps down"
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
  # Staged ramp with confirmation (anti-flap):
  #   0->1 on sustained kick or instant mid-level (fast to LOW, NEVER straight to MAX).
  #   1->2 only after PROMOTE_SUSTAIN consecutive heavy polls
  #       (heavy = temp>=HIGH, or temp>=mid with power>=POWER_HIGH, or fast temp rise).
  #   2->1 / 1->0 only after DOWN_SUSTAIN consecutive cool polls (steps down, never cuts out).
  #   temp>=EMERG_HIGH -> immediate MAX from any state (thermal safety net).
  kick_want=0; kick_reason=""
  if [ "$dt" -ge "$DERIV_KICK" ]; then
    kick_want=1; kick_reason="dT=+${dt}>=${DERIV_KICK}"
  elif [ "$cur" -ge "$low" ] && { [ "$power" -ge "$POWER_HIGH" ] || [ "$dpower" -ge "$POWER_DELTA" ]; }; then
    kick_want=1; kick_reason="power=${power}W dP=+${dpower}"
  fi
  if [ "$kick_want" -eq 1 ]; then kick_hits=$((kick_hits+1)); else kick_hits=0; fi
  heavy=0
  if [ "$cur" -ge "$high" ] || { [ "$cur" -ge "$mid" ] && [ "$power" -ge "$POWER_HIGH" ]; } || [ "$dt" -ge "$DERIV_KICK" ]; then heavy=1; fi
  if [ "$state" -eq 1 ] && [ "$heavy" -eq 1 ]; then heavy_hits=$((heavy_hits+1)); else heavy_hits=0; fi
  want_cool=0
  if [ "$state" -eq "$MAX_STATE" ]; then
    { [ "$cur" -le "$((high-HYST_OFFSET))" ] || [ "$power" -lt "$POWER_LOW" ]; } && want_cool=1
  elif [ "$state" -eq 1 ]; then
    [ "$cur" -le "$((low-HYST_OFFSET))" ] && want_cool=1
  fi
  if [ "$want_cool" -eq 1 ]; then cool_hits=$((cool_hits+1)); else cool_hits=0; fi
  reset_counts() { kick_hits=0; heavy_hits=0; cool_hits=0; }
  if [ "$cur" -ge "$EMERG_HIGH" ]; then
    if [ "$state" -ne "$MAX_STATE" ]; then
      state=$MAX_STATE; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) >=EMERG($EMERG_HIGH) -> both fans $state"
    fi
    reset_counts
  elif [ "$state" -eq 0 ]; then
    if [ "$kick_hits" -ge "$KICK_SUSTAIN" ]; then
      reset_counts; state=1; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W ${kick_reason} sustained=${KICK_SUSTAIN} STAGE-ONE -> both fans $state"
    elif [ "$cur" -ge "$mid" ]; then
      reset_counts; state=1; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) mid($mid) -> both fans $state"
    fi
  elif [ "$state" -eq 1 ]; then
    if [ "$heavy_hits" -ge "$PROMOTE_SUSTAIN" ]; then
      reset_counts; state=$MAX_STATE; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W heavy x${PROMOTE_SUSTAIN} CONFIRMED -> both fans $state"
    elif [ "$cool_hits" -ge "$DOWN_SUSTAIN" ]; then
      reset_counts; state=0; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) cool x${DOWN_SUSTAIN} <=LOW-HYST($((low-HYST_OFFSET))) -> both fans $state"
    fi
  elif [ "$state" -eq "$MAX_STATE" ]; then
    if [ "$cool_hits" -ge "$DOWN_SUSTAIN" ]; then
      reset_counts; state=1; set_fan "$state"
      echo "$(date +%T) max=${cur}C(CPU=${cpu} GPU=${gpu} src=${src}) power=${power}W cool x${DOWN_SUSTAIN} -> both fans $state"
    fi
  fi
  prev=$cur
  prev_power=$power
  prev_energy=$cur_energy
  sleep "$POLL_INTERVAL"
done
