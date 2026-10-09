# dell-7567-fanctl

> **Warning: rhythmic fan noise.** This trades acoustics for response speed. With only 3 SMM states (`off/low/max`) and 2s polling plus temp/power kicks, fans step audibly between `0/~2300/~4900 RPM` instead of gliding. Expect repeated spin up/down under bursty loads. If that bothers you, raise `HYST_OFFSET`, `POLL_INTERVAL`, and kick thresholds in `dell-fanctl-fast.conf`, or stay on stock BIOS control.

Fast-transient fan control for Dell Inspiron 14/15 7000 Gaming 7567/7577 (i7-7700HQ + GTX 1050) on Linux. No BIOS/EC flash.

Stock firmware ramps slow (DPTF ~3s poll, 4C hysteresis, 2-10C active steps) and holds fans on after cool-down. This drives both fans from `max(CPU,GPU)` + RAPL package power with derivative + feedforward kicks.

## One-click install

```bash
./one-click-install.sh
```

No prompts (needs passwordless sudo once). Installs `thermald`, `i8kutils`, `dell-bios-fan-control` (via `pacman/yay` on Arch/CachyOS, `apt`/`dnf` elsewhere), `dell-smm-hwmon` opts, fan loop + systemd service + thermald config, enables and verifies live RPM.

## How it works

- `fan-fix/fan-control-fast.sh` — 2s loop, shared heatpipe: both `pwm1+pwm2` follow `max(CPU [coretemp+dell_smm], GPU [dell_smm+nvidia-smi])` + RAPL package power (`intel-rapl:0`, PL1 45W/PL2 60W).
- Thresholds (`fan-fix/dell-fanctl-fast.conf`): off `<=55C`, low from `>=64C`, full blast `>=70C`, temp kick `>+5C/poll`, power kick `>=40W` / jump `>+25W`, power spin-down `<10W` drops max→low before temp falls.
- `fan-fix/dell-fanctl.service` — disables BIOS auto on start (`dell-bios-fan-control 0`), restores on stop.
- `fan-fix/thermald-fast.xml` — 1s sampling, CPU+GPU active trips.
- `fan-fix/NBFC_Dell_Inspiron_7567_7577_fast.xml` — optional NBFC profile (needs EC probe; SMM path is default).
- `fan-fix/ssdt-fanfix.dsl/.aml` — optional initrd `_TSP 1s` override.
- `fan-fix/install-linux.sh` — manual step-by-step installer. `fan-fix/FAN_FIX_GUIDE.md` — full rationale.

## Tune

```bash
sudo nano /usr/local/etc/dell-fanctl.conf
sudo systemctl restart dell-fanctl
journalctl -u dell-fanctl -n 20 --no-pager
```

3 SMM states only: `0/off`, `1/low (~2300 RPM)`, `2/max (~4900 RPM)`.
