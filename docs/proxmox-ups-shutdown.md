# Proxmox UPS-Triggered Graceful Shutdown

## Overview

This document covers configuring Network UPS Tools (NUT) on the Proxmox host so that when the CyberPower PR1500RT2UN UPS reaches a critically low battery, NUT gracefully shuts down each Kubernetes VM and then the Proxmox host itself — keeping the ZFS pool intact across a power event.

The visibility side of the UPS integration (Prometheus scraping, Grafana dashboard, Discord alerts) lives in the Kubernetes cluster and is already in place. NUT is the actuator that lives on bare metal, where it needs to live to do its job: the cluster can't shut itself down cleanly through its own VMs.

## Architecture

```
            ┌─────────────────────────────────────────────┐
            │  Proxmox host                                │
            │                                              │
            │  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
            │  │ k8s-0   │  │ k8s-1   │  │ k8s-2   │ VMs  │
            │  │ Talos   │  │ Talos   │  │ Talos   │      │
            │  └─────────┘  └─────────┘  └─────────┘      │
            │                                              │
            │  NUT (upsd + upsmon)                         │
            │     │                                        │
            │     │ SNMP poll                              │
            │     ▼                                        │
            └──── 10.100.1.15 (RMCARD205) ────────────────┘
                          │
                          ▼ on LOWBATT:
                  /etc/nut/shutdown.sh
                       1. qm shutdown each k8s VM
                       2. wait for VMs to stop
                       3. poweroff host
```

NUT polls the UPS independently from the snmp-exporter in the cluster. Both run in parallel — they don't interfere with each other.

## Prerequisites

Already configured on the RMCARD205 (from earlier setup):

- SNMPv1 enabled
- Community `prometheus`, Read-Only, NMS IP `0.0.0.0`
- Static IP `10.100.1.15` on the management VLAN

## Install NUT

On the Proxmox host as root:

```sh
apt update
apt install -y nut nut-snmp
```

That pulls in `nut-client`, `nut-server`, and the SNMP driver.

## Configuration

All paths are on the Proxmox host.

### `/etc/nut/nut.conf`

```ini
MODE=standalone
```

Single-host install, so `standalone` (not `netserver` or `netclient`).

### `/etc/nut/ups.conf`

```ini
[cyberpower]
    driver = snmp-ups
    port = 10.100.1.15
    desc = "CyberPower PR1500RT2UN (RMCARD205)"
    mibs = cyberpower
    snmp_version = v1
    community = prometheus
    pollfreq = 30
```

Driver options:
- `mibs = cyberpower` — use the bundled CyberPower MIB definitions.
- `snmp_version = v1` — RMCARD205 silently drops v2c GETBULK; v1 is the only mode that works reliably. (See `memory/rmcard205_snmp.md` for the full diagnosis.)
- `pollfreq = 30` — 30s is fine; we're not the only thing watching this UPS.

### `/etc/nut/upsd.conf`

```ini
LISTEN 127.0.0.1 3493
```

Bind to localhost only. No reason to expose `upsd` to the network here.

### `/etc/nut/upsd.users`

```ini
[monuser]
    password = <generate-a-random-password>
    upsmon primary
```

This is the local credential `upsmon` uses to talk to `upsd`. Generate with `openssl rand -base64 24`. Stays on this host.

### `/etc/nut/upsmon.conf`

```ini
MONITOR cyberpower@localhost 1 monuser <same-password> primary

MINSUPPLIES 1
SHUTDOWNCMD "/etc/nut/shutdown.sh"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 30
DEADTIME 15

# Trigger early — we want time to cleanly drain VMs.
# Shutdown when remaining runtime drops below 5 minutes (300s).
# This is in addition to the LOWBATT trigger which fires automatically.
FINALDELAY 5
```

The shutdown trigger logic:
1. NUT fires `SHUTDOWNCMD` when the UPS asserts `LOWBATT` (RMCARD-driven, configurable on the device itself in the web UI), OR
2. When `battery.runtime` drops below `ups.delay.shutdown` (see below).

To tune the early-shutdown threshold, set in the RMCARD web UI: *Configuration → UPS → Diagnostics → Low Battery Alarm Time* to e.g. `5 minutes`. That's what the UPS itself reports as `LOWBATT`, and that's what NUT acts on.

### `/etc/nut/shutdown.sh`

```sh
#!/bin/bash
# Triggered by upsmon when the UPS battery is critically low.
# Gracefully stops k8s VMs, then powers down the Proxmox host.

set -u
exec > >(logger -t ups-shutdown -s) 2>&1

echo "UPS shutdown initiated by NUT"

# Find running VMs whose name matches the k8s-* pattern.
# Adjust the pattern if your VM naming scheme differs.
VMIDS=$(qm list | awk '$2 ~ /^k8s-/ && $3 == "running" {print $1}')

if [ -z "$VMIDS" ]; then
    echo "No k8s VMs running; proceeding to host shutdown"
else
    echo "Shutting down VMs: $VMIDS"
    for VMID in $VMIDS; do
        # 90s should be plenty for Talos VMs to drain.
        # --forceStop ensures we don't hang forever if a VM is unresponsive.
        qm shutdown "$VMID" --timeout 90 --forceStop 1 &
    done
    wait
    echo "All VMs reported shut down"
fi

# Brief settle window before the host itself goes down.
sleep 5

echo "Powering off Proxmox host"
/sbin/poweroff
```

Make it executable: `chmod 750 /etc/nut/shutdown.sh && chown root:nut /etc/nut/shutdown.sh`

### File permissions

NUT is picky about config file permissions because they hold credentials:

```sh
chown root:nut /etc/nut/*.conf /etc/nut/*.users
chmod 640 /etc/nut/*.conf /etc/nut/*.users
```

## Enable and start

```sh
systemctl enable --now nut-server nut-monitor
systemctl status nut-server nut-monitor
```

Verify NUT can talk to the UPS:

```sh
upsc cyberpower@localhost
```

You should see a list of variables: `battery.charge`, `battery.runtime`, `ups.status`, etc. If you see `Error: Driver not connected`, check `journalctl -u nut-server` for SNMP-side errors.

## Testing

### Read-only sanity check

```sh
upsc cyberpower@localhost ups.status      # expect "OL" (online)
upsc cyberpower@localhost battery.charge  # expect ~100
upsc cyberpower@localhost battery.runtime # expect ~2940 (seconds)
```

### Dry-run the shutdown script

```sh
# Just confirm it finds the VMs without actually shutting anything down:
qm list | awk '$2 ~ /^k8s-/ && $3 == "running" {print $1}'
```

### Force a fake LOWBATT event (won't actually shut down — use with care)

```sh
# This signals upsmon as if the UPS reported critical battery.
# Comment out the poweroff line in shutdown.sh first if you want a true dry-run.
upsmon -c fsd
```

Watch `journalctl -t ups-shutdown -f` in another terminal to see the script fire.

**Important:** uncomment the `/sbin/poweroff` line again after the dry-run.

### Real test (pulls UPS plug)

Best done at a planned time, with a real workload running, to confirm:
1. RMCARD reports `OB` (on battery) → Discord alert from k8s alertmanager fires.
2. RMCARD reaches LOWBATT threshold → `upsmon` triggers `shutdown.sh`.
3. VMs go down gracefully (visible in `qm list` and `journalctl`).
4. Proxmox host powers off.

When you restore power, the UPS turns its outlets back on automatically; the Proxmox host BIOS should be configured for "Power On After AC Loss" so it boots straight back up.

## Integration with the existing observability

Nothing breaks. The snmp-exporter Pod in the cluster continues polling the RMCARD via v1 SNMP for Prometheus metrics; NUT polls the same UPS via v1 SNMP independently. The RMCARD handles concurrent SNMP queries fine.

You'll continue to see:
- Grafana CyberPower UPS dashboard updating in real-time
- Discord notifications via alertmanager when `UpsOnBattery` / `UpsBatteryCapacityCritical` / `UpsRuntimeCritical` fire

The NUT side gives you the *physical* safety net: even if the cluster is completely broken, NUT on the Proxmox host will still gracefully power things down before the battery dies.

## Why NUT and not a Kubernetes webhook + talosctl

Earlier plans considered triggering shutdown via an alertmanager webhook pointed at a Kubernetes pod that ran `talosctl shutdown`. That approach is wrong for this topology:

- The k8s nodes are VMs; shutting them down still leaves the Proxmox host running on battery.
- The Proxmox host has the ZFS pool that needs a clean shutdown.
- The webhook listener runs inside the cluster it's shutting down — a fragile chicken-and-egg.

NUT lives on the bare metal that needs to die last, doesn't depend on Kubernetes being healthy, and is the standard, well-trodden tool for exactly this job.

## References

- NUT documentation: <https://networkupstools.org/documentation.html>
- `snmp-ups` driver options: <https://networkupstools.org/docs/man/snmp-ups.html>
- Proxmox + NUT community wiki: <https://pve.proxmox.com/wiki/UPS> (older but still accurate)
