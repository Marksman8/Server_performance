# Server Performance Stats

A Bash script that analyses basic performance stats on any Linux server.

Built as a solution to the [Server Performance Stats](https://roadmap.sh/projects/server-stats) project on roadmap.sh.

## Features

**Core stats**
- Total CPU usage (sampled over 1 second, all cores)
- Total memory usage: used vs free, with percentages (plus swap)
- Total disk usage: used vs free, with percentages, and a per-mount breakdown
- Top 5 processes by CPU usage
- Top 5 processes by memory usage

**Extra stats**
- OS version, kernel and architecture
- Uptime
- Load average (1/5/15 min) with CPU count
- Logged-in users
- Failed SSH login attempts (needs `sudo`)

## Usage

```bash
git clone https://github.com/Marksman8/Server_performance.git
cd Server_performance
chmod +x server-stats.sh
./server-stats.sh
```

Run with `sudo` to include failed login attempts:

```bash
sudo ./server-stats.sh
```

### Options

| Option | Description |
|---|---|
| `-n`, `--no-color` | Disable colored output |
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |

| Environment variable | Description |
|---|---|
| `CPU_SAMPLE_SECS` | Seconds to sample CPU usage over (default `1`) |
| `NO_COLOR` | Disable colors when set |

Colors are turned off automatically when output is piped or redirected, so `./server-stats.sh > report.txt` gives a clean text file.

## Sample output

```
Server Performance Stats  vm @ 2026-10-01 08:47:00 UTC

== System ==
  Hostname:          vm
  OS:                Ubuntu 24.04.4 LTS
  Kernel:            6.18.44 (x86_64)
  Uptime:            0d 0h 0m
  Load average:      0.08, 0.02, 0.01  (1/5/15 min, 1 CPUs)
  Logged-in users:   0 session(s)
  Failed logins:     0 (sshd, last 24h, journald)

== CPU ==
  Usage:             0.0%  (sampled over 1s, all cores)

== Memory ==
  Total:             3.9 GiB
  Used:              257.6 MiB (6.4%)
  Free:              3.7 GiB (93.6%)
  Swap:              not configured

== Disk (local filesystems) ==
  Total size:        252.0 GiB
  Used:              8.6 GiB (46.2%)
  Free:              10.0 GiB (53.8%)

  MOUNT                         SIZE        USED        FREE  USE%
  /                        252.0 GiB     8.6 GiB    10.0 GiB   47%

== Top 5 processes by CPU ==
  PID      USER           %CPU   %MEM  COMMAND
  1        root            1.4    0.1  process_api
  ...
```

## How it works

- **CPU** is calculated from two readings of `/proc/stat` taken one second apart, rather than parsing `top`, whose output format varies between versions.
- **Memory** "free" means `MemAvailable` from `/proc/meminfo` (memory actually usable by new programs, including reclaimable cache), the same value as the `available` column of `free`.
- **Disk** totals count each real block device once, skipping bind mounts, loop devices (e.g. snap images) and tmpfs. Percentages match `df`'s `Use%`. Inside containers it falls back to the root filesystem.
- **Processes** come from `ps`. Note that `ps` reports `%CPU` as an average over each process's lifetime.
- **Failed logins** are read from `/var/log/auth.log` (Debian/Ubuntu), `/var/log/secure` (RHEL/Fedora), or journald, whichever exists.

## Requirements

- Linux with `/proc` (any distro, including WSL and containers)
- Bash, coreutils, awk and procps (`ps`), all preinstalled on standard distributions

The script is read-only and makes no changes to the system.

## License

[Apache 2.0](LICENSE)
