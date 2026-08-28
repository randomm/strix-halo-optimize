#!/usr/bin/env bash
# Read-only Strix Halo optimization probe: host, memory, GPU, toolboxes.
# Flags known-bad versions and missing config. Changes nothing. Exit code 0
# always; count of warnings printed at the end.

set -uo pipefail

WARNINGS=0
warn() { printf '  [WARN] %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
ok()   { printf '  [ok]   %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
gib()  { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

# Known-bad markers (facts snapshot 2026-08 -- keep in sync with SKILL.md)
MIN_KERNEL="6.18.4"
BAD_FIRMWARE="20251125"
WANT_PARAMS=(amd_iommu amdgpu.gttsize ttm.pages_limit)

printf 'Strix Halo optimization probe (read-only) — %s\n' "$(date -Is)"
printf '=%.0s' {1..64}; printf '\n'

printf '\n## Host\n'
KVER=$(uname -r)
KBASE=${KVER%%-*}
if [[ "$(printf '%s\n%s\n' "$MIN_KERNEL" "$KBASE" | sort -V | head -1)" == "$MIN_KERNEL" ]]; then
    ok "kernel $KVER (>= $MIN_KERNEL)"
else
    warn "kernel $KVER < $MIN_KERNEL — known gfx1151 stability bug, upgrade"
fi

if command -v rpm >/dev/null 2>&1; then
    FW=$(rpm -q linux-firmware 2>/dev/null || true)
    if [[ -n "$FW" ]]; then
        if [[ "$FW" == *"$BAD_FIRMWARE"* ]]; then
            warn "$FW — this firmware breaks ROCm on Strix Halo, up/downgrade"
        else
            ok "$FW"
        fi
        rpm -q mesa-vulkan-drivers 2>/dev/null | sed 's/^/  mesa: /' || true
    else
        info "linux-firmware: not queryable via rpm"
    fi
fi

info "cmdline: $(cat /proc/cmdline)"
for p in "${WANT_PARAMS[@]}"; do
    if grep -qw "$p" /proc/cmdline 2>/dev/null || grep -q "$p=" /proc/cmdline 2>/dev/null; then
        ok "boot param present: $p"
    else
        warn "boot param missing: $p (see references/kernel-and-memory.md)"
    fi
done

awk '/MemTotal/ {printf "  RAM: %.2f GiB\n", $2/1048576}' /proc/meminfo
awk '/MemAvailable/ {printf "  RAM available now: %.2f GiB\n", $2/1048576}' /proc/meminfo

if command -v tuned-adm >/dev/null 2>&1; then
    info "tuned: $(tuned-adm active 2>/dev/null | sed 's/Current active profile: //' || echo unknown)"
fi
GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
[[ -r "$GOV" ]] && info "cpu governor: $(<"$GOV")"

printf '\n## GPU / unified memory\n'
FOUND_GPU=0
for card in /sys/class/drm/card[0-9]*; do
    dev="$card/device"
    [[ -r "$dev/vendor" ]] || continue
    [[ "$(<"$dev/vendor")" == "0x1002" ]] || continue
    FOUND_GPU=1
    name=$(basename "$card")
    devid=$(cat "$dev/device" 2>/dev/null || echo '?')
    info "$name: AMD GPU, device id $devid"
    for f in mem_info_gtt_total mem_info_gtt_used mem_info_vram_total mem_info_vram_used; do
        [[ -r "$dev/$f" ]] && info "  $f: $(gib "$(<"$dev/$f")") GiB"
    done
    dpm="$dev/power_dpm_force_performance_level"
    [[ -r "$dpm" ]] && info "  power_dpm level: $(<"$dpm")"
done
if (( FOUND_GPU == 0 )); then
    warn "no AMD GPU visible in /sys/class/drm — wrong machine, or driver not loaded"
fi
if [[ -r /sys/module/ttm/parameters/pages_limit ]]; then
    PL=$(</sys/module/ttm/parameters/pages_limit)
    PGSZ=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    info "ttm pages_limit: $PL ($(gib $((PL * PGSZ))) GiB)"
fi
info "Reminder: VRAM and GTT are overlapping views of the same RAM. Never sum them."

printf '\n## Toolboxes\n'
if command -v toolbox >/dev/null 2>&1; then
    toolbox list --containers 2>/dev/null | sed 's/^/  /' || info "toolbox list failed"
else
    info "toolbox command not found (fine if benchmarking bare-metal builds)"
fi
if command -v podman >/dev/null 2>&1; then
    IMGS=$(podman images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' 2>/dev/null | grep strix-halo || true)
    if [[ -n "$IMGS" ]]; then
        printf '%s\n' "$IMGS" | sed 's/^/  /'
    else
        info "no strix-halo toolbox images found locally"
    fi
fi

printf '\n## Running GPU workloads\n'
if pgrep -af 'llama-server|llama-bench|llama-batched-bench' >/dev/null 2>&1; then
    pgrep -af 'llama-server|llama-bench|llama-batched-bench' | sed 's/^/  /'
    warn "GPU workload(s) running — do NOT benchmark concurrently"
else
    info "none detected"
fi

if [[ -e /dev/kfd ]]; then ok "/dev/kfd present (ROCm compute path available)"; else info "/dev/kfd absent — ROCm toolboxes won't work"; fi

printf '\n'; printf '=%.0s' {1..64}; printf '\n'
printf 'Probe complete. Warnings: %d. No settings were changed.\n' "$WARNINGS"
[[ -f "$HOME/strix-optimize/journal.md" ]] && printf 'Journal exists: %s — read it before changing anything.\n' "$HOME/strix-optimize/journal.md"
exit 0
