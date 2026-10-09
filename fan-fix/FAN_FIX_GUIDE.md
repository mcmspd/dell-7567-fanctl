# Fan transient fix — Dell Inspiron 7567/7577 (BIOS 1.15.0), Linux

Symptom: slow climb (spike before ramp) + slow spin-down (fan stays high after cool).
Generated: `fan-fix/` in this repo. Validated: `xmllint` NBFC/thermald OK, `bash -n` OK, `iasl` SSDT OK.

## Root cause (from decompile)

- `ThermalZone THM` in DSDT has only `_CRT/_TMP` (`/tmp/acpi/DSDT.dsl:35979`), no `_ACx/_PSV`. Active cooling is EC autonomous + DPTF, not legacy ACPI.
- DPTF `DptfTa1/2/Sds` (`/tmp/acpi/dptf/*.dsl`): `_TSP=CPUS/SSP1-8` (tenths-sec, NVS, typically ~3s), `_NTT=0x0ADE`, `GTSH=0x28=4C` (Ta1:2374) vs `0x14=2C` (Ta2/Sds), `_AC` ladder `0x14=2C / 0x32=5C / 0x64=10C`. Each fan step needs +2-10C sustained; notify only on 5C delta with `LSTM` guard. This is the slow-climb ladder.
- `GTSH` holds fan ON 2-4C below trip (anti-flap). This is the slow spin-down hold.
- Path is `sensor -> EC (ms) -> SMI 0xE0 GENS 0x16/0x07/0x08 -> _TMP/KDRT -> DPTF poll -> EC PWM`. SMI roundtrip + `SMIX/ECMX` mutex + EC slew limit dominate ms-scale lag. See `DSDT:32818 GENS, 32895 ASMI (SCMD=0xE0)`.
- EC firmware `pfs/*EC v1.0.12.bin` (327680B, FV `_FVH` x1, RAW `05CA0203...` at `0xFE8`) payload starts `PHCM` at `0x1000`, entropy 7.94, `MZ 0, ITE 0`, no `FAN/PWM` strings. EC tables are encrypted/compressed — no patchable plaintext curve was found. `Setup` PE `899407d7...` (875KB) has zero `fan/thermal/cool/pwm` UTF-16 hits — no BIOS menu to tune.
- Result: cannot fix by simple EC byte-tweak. Fix at OS/DPTF layer (no flash) or full BIOS+EC reflash with re-sign (blocked, see Option B).

## Option A — OS-level, no flash (recommended)

Pick one primary. A2 (SMM) is most reliable on Dell; A1 (NBFC) needs EC probe.

### A1. NBFC fast profile (you asked first)

File: `fan-fix/NBFC_Dell_Inspiron_7567_7577_fast.xml` (`EcPollInterval 500`, kick at 50C, 3C down-hysteresis, 100% at 80C, critical 95C).

1. Build NBFC for Linux per wiki, install config to `~/nbfc/Configs/`, select it.
2. Probe EC first — stock registers `148/149/147` are Dell 7348 heritage, NOT verified on 7567 (custom EC ports `0x930/0x934` in `DSDT:34009`, not `0x62/0x66`). Run NBFC `ec-probe`, watch `Read 149` vs `sensors` RPM. If stuck at 0/FF, STOP and use A2.
3. Validate: `stress-ng --cpu 8` spike 55->85C should step 25->100% within 2-3 polls (1-1.5s), drop 80->70C should step down within 2 polls. Adjust `Up/DownThreshold` ±2C for acoustics vs response.
4. Rollback: set NBFC to Auto or `ResetValue 14`.

Why these numbers: 50C kick beats stock passive (~65-70C EC auto); 5C steps beat stock 5-10C `_AC` ladder; 3C down beats stock 4C `GTSH` hold; 500ms beats stock ~3s `_TSP`.

### A2. SMM direct (most reliable on Dell Linux)

Uses `dell-smm-hwmon` (`0x00a3/0x01a3` fan 0-2, `0x10a3` temp) + `dell-bios-fan-control` + `fan-fix/fan-control-fast.sh`.

```
sudo modprobe dell-smm-hwmon restricted=0 force=1
sudo apt install i8kutils
# dell-bios-fan-control: disable BIOS auto at boot (restores on stop)
sudo cp fan-fix/dell-fanctl-fast.conf /usr/local/etc/dell-fanctl.conf
sudo ./fan-fix/fan-control-fast.sh /usr/local/etc/dell-fanctl.conf
# test: i8kfan 2 2  -> max, i8kfan 0 0 -> off, sensors | grep -i fan
```

Script logic: poll 2s, `TEMP_LOW 50 / HIGH 80 / HYST 3`, derivative kick `+6C/poll -> +1 state`. Fixes climb (early + kick) and spin-down (3C vs 4C). Tune `DERIV_KICK 4-8`, `POLL 1-3`. Run as systemd service; stop restores BIOS auto. Known Dell caveat: only 3 states (0/1/2), SMM call ~ms, `0x30a3/0x34a3` auto-disable codes vary by whitelist — test `pwm1_enable` presence.

### A3. thermald (DPTF assist, keep with A1/A2)

File: `fan-fix/thermald-fast.xml` -> `/etc/thermald/thermal-conf.xml`. Forces 1s sampling, passive 70C, active 50/55C FAN. `sudo systemctl restart thermald; thermald --loglevel=debug`. Prevents CPU throttling from masking fan lag. Keep `Preference QUIET` or switch to `PERFORMANCE` for faster ramp.

### A4. SSDT `_TSP` override (RAM-only ACPI, no flash)

Files: `fan-fix/ssdt-fanfix.dsl/.aml` (compiled, 130B, 1 opcode). Overrides `\_SB.PCI0.B0D4._TSP -> 10 (1.0s)` vs stock `CPUS`.

```
# verify live path matches DptfTa1:1750 first:
sudo acpidump -b -n DSDT -o live.dat; iasl -d live.dat; grep -n "_TSP" live.dsl
# if B0D4 present, add aml to initrd (dracut/acpi_override) or grub `acpi /ssdt-fanfix.aml`
dmesg | grep -i acpi  # check override loaded, no AE_NOT_FOUND
```

Extends to `SEN1/SSP1 GTSH 0x14` only after confirming live `SEN1` path (template commented). Reverts on reboot. No BootGuard trip.

Start order: A2 + A3 today, add A1 if EC probe succeeds, add A4 if `_TSP` still slow.

## Option B — BIOS/EC reflash (full detail, NOT recommended)

What would be patched:

1. DPTF AML in `firmware_parser/.../file-ea13f678.../section0.raw` (Ta1 17753B), `.../ea139578...` (Ta2 40621B): `GTSH 0x28->0x14/0x0A`, `_TSP Return(CPUS)->Return(10)`, `_ACx -0x32/-0x64 -> -0x14` steps, `_NTT 0x0ADE` lower. Recompile with `iasl`, replace FFS `section0.raw`, fix FFS/LZMA lengths + FV checksums.
2. EC `pfs/*EC*.bin` PWM table: would lower mid-trip PWMs, hysteresis `3->1C`, ramp `% per 100ms` up. BUT table not located — `PHCM` encrypted, entropy 7.94, no monotonic `28..5A` temp runs found. Requires ITE key or EC RAM live patch (`ec-probe` writes to `0x200-0x2FF` shadow, lost on reboot).
3. SMM handler (`file-04eaaaa1...` 108KB, `file-6d4baa0b...` 86KB candidates): would shorten `0xE0` smoothing. Requires Ghidra reverse + re-sign.

Why blocked:

- BootGuard verified boot: FIT at `0x690100`, ACM (02/2016), Key Manifest hash `3443F58B...`, Boot Policy enforced (`uefiextract/bios.bin.report.txt` tail, `decompiled/analysis/fit.txt`). Modded IBB fails ACM hash -> no boot.
- BIOS Guard: `pfs/*BIOS*.meta.bin` (300B `PMIM/PM_K/PM_C` script) + 256B RSA `*.data.sig`. Flash tool verifies sig; modded image rejected unless Guard disabled in Setup (no option exposed) + descriptor unlocked.
- EC: `PHCM` + Dell RSA `*.data.sig`. EC flash via Dell updater verifies; direct SPI (CH341A/SOIC8) bypasses sig but still needs decrypted image + BootGuard will still fail on BIOS side.
- Flash procedure (if you accept brick risk): SPI dump (2x, `flashrom -r`), patch, `UEFIExtract` replace + `EDK2 GenFv` rebuild, reflash via hardware programmer only, EC separately. No software re-sign possible without Dell private keys.

Verdict: do Option A. Option B is documented for completeness; do not flash modded image on BootGuard machine without external programmer + recovery image + willingness to brick.

## Tune for your symptom

- Slow climb: lower `UpThreshold` 50->45C, `POLL 2->1s`, `DERIV 6->4`, thermald active 55->50C, SSDT `_TSP 10->5`.
- Slow spin-down: reduce `Down` gap 3->2C (risks flap), raise `TEMP_LOW` 50->55C, keep `GTSH` small. If oscillation, increase gap to 4C.
- Validate with: `sensors; i8kctl temp; watch -n1 sensors` + `stress-ng --cpu 8 --timeout 60s` up-spike + idle down-tail. Log RPM vs temp, aim <2s kick, <4s step, <6s spin-down per 5C.

Files: `NBFC_*.xml`, `fan-control-fast.sh`, `dell-fanctl-fast.conf`, `thermald-fast.xml`, `ssdt-fanfix.dsl/.aml` (all validated).
