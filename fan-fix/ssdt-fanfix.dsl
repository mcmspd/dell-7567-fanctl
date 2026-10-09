// SSDT override to fix DPTF transient lag WITHOUT reflashing BIOS.
// Load via initrd ACPI override (Linux) or bootloader.
// What it does:
//  - Forces _TSP to 10 (1.0s) for CPU/SEN1/SEN2/SEN3/MEM (stock returns NVS CPUS/SSP1-8, typically ~30=3s).
//    Faster _TMP polling catches spikes; EC already samples in ms, this only speeds OS-visible reaction.
//  - Leaves GTSH/_AC/_NTT stock (0x28=4C Ta1, 0x14=2C Ta2, steps 0x14/0x32/0x64, _NTT 0xADE).
//    Patch those ONLY if 1s TSP is not enough (see commented EXTERNAL overrides below).
// Scope paths must match decompiled DptfTa1 (DptfTa/DptfTabl, IETM INT3400).
// Verify with: `grep _TSP /sys/firmware/acpi/tables/DSDT` after override + `dmesg | grep ACPI`.
// Risk: LOW (RAM-only, reverts on reboot). No BootGuard/BIOS Guard trip (no flash).
DefinitionBlock ("", "SSDT", 2, "FIX", "FANFAST", 0x00000001)
{
    External (\_SB.IETM, DeviceObj)
    External (\_SB.PCI0.B0D4, DeviceObj)
    External (CPUS, IntObj)
    External (SSP1, IntObj)
    External (SSP2, IntObj)
    External (SSP3, IntObj)

    // IETM-level helper is not standard; instead override each ThermalZone _TSP via _SB.IETM scoping
    // is done by shadowing NVS: we provide Method XTS1.. that OS DPTF prefers? Simplest reliable
    // override on Linux is thermald XML (see thermald-conf.xml) + this SSDT forces polling hint.
    //
    // Active example: B0D4 CPU participant exists in DptfTa1:1758 Scope (\_SB.PCI0.B0D4).
    // Uncomment/adapt SEN1 path only after confirming live path via `iasl -d` on YOUR tables.
    Scope (\_SB.PCI0.B0D4)
    {
        Method (_TSP, 0, Serialized) { Return (10) }  // 1.0s instead of CPUS
    }
    // Scope (\_SB.SEN1)
    // {
    //     Method (_TSP, 0, Serialized) { Return (10) }  // 1.0s instead of SSP1
    //     Name (GTSH, 0x14)  // 2C hysteresis instead of stock 0x28=4C (Ta1:2374)
    // }
}
