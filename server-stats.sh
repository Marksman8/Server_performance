#!/usr/bin/env bash
#
# server-stats.sh - Snapshot of basic Linux server performance stats.
#
# Usage:  ./server-stats.sh [-n|--no-color] [-h|--help] [-v|--version]
# Env:    CPU_SAMPLE_SECS  seconds to sample CPU usage over (default: 1)
#         NO_COLOR         disables colored output when set
#
# Design notes:
#   * Read-only: never modifies the system.
#   * Reads /proc directly instead of parsing `top`/`free` output, whose
#     layout differs between procps versions and distros.
#   * Anything that needs privileges (failed logins) degrades to "N/A"
#     with a hint instead of failing the whole report.

set -u
export LC_ALL=C   # consistent decimal points and sort order

readonly VERSION="1.0.0"
readonly TOP_N=5
CPU_SAMPLE_SECS="${CPU_SAMPLE_SECS:-1}"
USE_COLOR=1

# --------------------------------------------------------------- helpers

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Print a snapshot of server performance stats: CPU, memory, disk,
top processes and general system info.

Options:
  -n, --no-color   Disable colored output
  -h, --help       Show this help and exit
  -v, --version    Show version and exit

Environment:
  CPU_SAMPLE_SECS  Seconds to sample CPU usage over (default: 1)
  NO_COLOR         Disable colors when set

Tip: run with sudo to include failed login attempts.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--no-color) USE_COLOR=0 ;;
      -h|--help)     usage; exit 0 ;;
      -v|--version)  echo "server-stats.sh $VERSION"; exit 0 ;;
      *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

setup_colors() {
  # Colors only when writing to a terminal, so piping to a file stays clean.
  if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
  else
    BOLD=''; DIM=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; RESET=''
  fi
}

have()    { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n%s%s== %s ==%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
kv()      { printf '  %-18s %s\n' "$1" "$2"; }
note()    { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }

# KiB -> human readable, binary units (matches `free -h` / `df -h`)
human_kib() {
  awk -v k="$1" 'BEGIN {
    split("KiB MiB GiB TiB PiB", u, " "); i = 1
    while (k >= 1024 && i < 5) { k /= 1024; i++ }
    printf "%.1f %s", k, u[i] }'
}

# pct PART WHOLE -> "12.3%" or "N/A" when WHOLE is 0
pct() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.1f%%", a * 100 / b; else printf "N/A" }'
}

# Color a "12.3%" string by severity: <70 green, <90 yellow, >=90 red
color_pct() {
  local s=$1 n=${1%\%} c=$GREEN
  case $n in ''|*[!0-9.]*) printf '%s' "$s"; return ;; esac
  if   awk -v n="$n" 'BEGIN { exit !(n >= 90) }'; then c=$RED
  elif awk -v n="$n" 'BEGIN { exit !(n >= 70) }'; then c=$YELLOW
  fi
  printf '%s%s%s' "$c" "$s" "$RESET"
}

cpu_count() {
  if have nproc; then nproc
  else awk '/^processor/ { n++ } END { print n + 0 }' /proc/cpuinfo 2>/dev/null
  fi
}

# --------------------------------------------------------------- system

failed_logins() {
  local f
  # Classic syslog files (Debian/Ubuntu: auth.log, RHEL/Fedora: secure)
  for f in /var/log/auth.log /var/log/secure; do
    if [ -r "$f" ]; then
      printf '%s (in %s)' "$(grep -c 'Failed password' "$f")" "$f"
      return
    fi
  done
  # journald-only systems. Non-root journalctl silently returns only the
  # caller's own entries, which would give a misleading 0, so require root.
  # OpenSSH >= 9.8 logs from "sshd-session", older versions from "sshd".
  if [ "$(id -u)" -eq 0 ] && have journalctl; then
    printf '%s (sshd, last 24h, journald)' "$(
      journalctl -q --no-pager --since '24 hours ago' \
        _COMM=sshd _COMM=sshd-session 2>/dev/null | grep -c 'Failed password')"
    return
  fi
  printf 'N/A (run with sudo)'
}

report_system() {
  section "System"
  local os="" l1 l5 l15 _rest
  if [ -r /etc/os-release ]; then
    os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
  fi
  kv "Hostname:" "$(uname -n)"
  kv "OS:"       "${os:-Unknown}"
  kv "Kernel:"   "$(uname -r) ($(uname -m))"
  kv "Uptime:"   "$(awk '{ s = int($1); printf "%dd %dh %dm", s / 86400, s % 86400 / 3600, s % 3600 / 60 }' /proc/uptime)"

  read -r l1 l5 l15 _rest < /proc/loadavg
  kv "Load average:" "$l1, $l5, $l15  (1/5/15 min, $(cpu_count) CPUs)"

  if have who; then
    local sessions users
    sessions=$(who 2>/dev/null | awk 'END { print NR }')
    users=$(who 2>/dev/null | awk '{ print $1 }' | sort -u |
            awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')
    kv "Logged-in users:" "${sessions} session(s)${users:+: $users}"
  else
    kv "Logged-in users:" "N/A (who not installed)"
  fi

  kv "Failed logins:" "$(failed_logins)"
}

# --------------------------------------------------------------- CPU

# Prints "idle total" jiffies from the aggregate cpu line of /proc/stat.
# Sums fields 2-9 only (user nice system idle iowait irq softirq steal):
# guest/guest_nice are already included in user/nice, so adding them
# would double-count.
read_cpu_times() {
  awk '/^cpu / { t = 0; for (i = 2; i <= 9 && i <= NF; i++) t += $i
                 print $5 + $6, t; exit }' /proc/stat
}

report_cpu() {
  section "CPU"
  if [ ! -r /proc/stat ]; then kv "Usage:" "N/A"; return; fi
  local i1 t1 i2 t2
  read -r i1 t1 <<<"$(read_cpu_times)"
  sleep "$CPU_SAMPLE_SECS"
  read -r i2 t2 <<<"$(read_cpu_times)"
  kv "Usage:" "$(color_pct "$(pct "$(( (t2 - t1) - (i2 - i1) ))" "$(( t2 - t1 ))")")  (sampled over ${CPU_SAMPLE_SECS}s, all cores)"
}

# --------------------------------------------------------------- memory

report_memory() {
  section "Memory"
  if [ ! -r /proc/meminfo ]; then kv "Memory:" "N/A"; return; fi
  local total avail swap_total swap_free used
  # "Free" = MemAvailable: memory actually usable by new programs
  # (free + reclaimable cache). Kernels < 3.14 lack it, so estimate.
  read -r total avail swap_total swap_free <<<"$(awk '
    /^MemTotal:/  { t = $2 }  /^MemFree:/ { f = $2 }  /^MemAvailable:/ { a = $2; ha = 1 }
    /^Buffers:/   { b = $2 }  /^Cached:/  { c = $2 }  /^SReclaimable:/ { s = $2 }
    /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
    END { if (!ha) a = f + b + c + s; print t + 0, a + 0, st + 0, sf + 0 }' /proc/meminfo)"
  used=$(( total - avail ))

  kv "Total:" "$(human_kib "$total")"
  kv "Used:"  "$(human_kib "$used") ($(color_pct "$(pct "$used" "$total")"))"
  kv "Free:"  "$(human_kib "$avail") ($(pct "$avail" "$total"))"
  if [ "$swap_total" -gt 0 ]; then
    local swap_used=$(( swap_total - swap_free ))
    kv "Swap used:" "$(human_kib "$swap_used") of $(human_kib "$swap_total") ($(color_pct "$(pct "$swap_used" "$swap_total")"))"
  else
    kv "Swap:" "not configured"
  fi
}

# --------------------------------------------------------------- disk

report_disk() {
  section "Disk (local filesystems)"
  local rows size used avail sz us av cap mnt
  # df -P: POSIX one-line-per-filesystem output; -k: 1 KiB blocks.
  # Count each real block device once (bind mounts repeat it) and skip
  # loop (snap images) and optical devices, which are always 100% full.
  rows=$(df -Pk 2>/dev/null |
         awk 'NR > 1 && $1 ~ /^\/dev\// && $1 !~ /^\/dev\/(loop|sr)/ && !seen[$1]++')
  # Containers usually have an overlay root and no /dev/* filesystems.
  [ -n "$rows" ] || rows=$(df -Pk / 2>/dev/null | awk 'NR > 1')
  if [ -z "$rows" ]; then kv "Disk:" "N/A"; return; fi

  read -r size used avail <<<"$(awk '{ s += $2; u += $3; a += $4 } END { print s + 0, u + 0, a + 0 }' <<<"$rows")"
  # Percentages use used + avail as the base, exactly like df's Use%.
  # Reserved blocks (e.g. ext4's 5% for root) are why used + avail < size.
  kv "Total size:" "$(human_kib "$size")"
  kv "Used:"       "$(human_kib "$used") ($(color_pct "$(pct "$used" "$(( used + avail ))")"))"
  kv "Free:"       "$(human_kib "$avail") ($(pct "$avail" "$(( used + avail ))"))"

  printf '\n  %s%-22s %11s %11s %11s %5s%s\n' "$BOLD" "MOUNT" "SIZE" "USED" "FREE" "USE%" "$RESET"
  while read -r _ sz us av cap mnt; do
    printf '  %-22s %11s %11s %11s %5s\n' \
      "$mnt" "$(human_kib "$sz")" "$(human_kib "$us")" "$(human_kib "$av")" "$(color_pct "$cap")"
  done <<<"$rows"
}

# --------------------------------------------------------------- processes

# report_top TITLE SORT_COLUMN   (3 = %CPU, 4 = %MEM)
report_top() {
  section "$1"
  local out pid user cpu mem cmd
  # `sort` instead of `ps --sort` so it also works with non-procps-ng ps.
  out=$(ps -eo pid=,user=,pcpu=,pmem=,comm= 2>/dev/null | sort -k"$2,$2nr" | head -n "$TOP_N")
  if [ -z "$out" ]; then kv "Processes:" "N/A (ps -eo unsupported)"; return; fi

  printf '  %s%-8s %-12s %6s %6s  %s%s\n' "$BOLD" "PID" "USER" "%CPU" "%MEM" "COMMAND" "$RESET"
  while read -r pid user cpu mem cmd; do
    printf '  %-8s %-12s %6s %6s  %s\n' "$pid" "${user:0:12}" "$cpu" "$mem" "$cmd"
  done <<<"$out"
}

# --------------------------------------------------------------- main

main() {
  parse_args "$@"
  setup_colors

  if [ "$(uname -s)" != "Linux" ] || [ ! -d /proc ]; then
    echo "server-stats.sh: requires Linux with /proc mounted" >&2
    exit 1
  fi

  printf '%sServer Performance Stats%s  %s @ %s\n' \
    "$BOLD" "$RESET" "$(uname -n)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

  report_system
  report_cpu
  report_memory
  report_disk
  report_top "Top $TOP_N processes by CPU" 3
  note "%CPU is averaged over each process's lifetime (ps semantics)."
  report_top "Top $TOP_N processes by memory" 4
  echo
}

main "$@"
