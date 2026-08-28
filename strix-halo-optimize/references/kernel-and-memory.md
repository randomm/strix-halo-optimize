# Kernel, Firmware, Unified Memory, and Host State

The foundation layer. Errors here are either catastrophic (crashes, broken
ROCm) or silently expensive (GPU limited to half the RAM). Fix this layer
before tuning anything above it. Facts dated 2026-08 — verify per
`research-sources.md`.

## Version gates (check first, every session)

`probe-system.sh` checks these automatically.

- **Kernel ≥ 6.18.4.** Older kernels have a gfx1151 stability bug. Known-good
  reference: 6.18.9 (Fedora 43). Newer is usually fine but check the kyuz0
  repo's "Stable Configuration" section for the currently blessed combo before
  major version jumps.
- **linux-firmware: never 20251125.** That release breaks ROCm on Strix Halo
  (instability/crashes). 20260110 known good. Check: `rpm -q linux-firmware`.
- Fedora ships fresh kernels via normal updates; `dnf history` tells you what
  a recent update changed if performance suddenly shifted. To hold a known-good
  pair while experimenting: `sudo dnf install python3-dnf-plugin-versionlock`
  then `sudo dnf versionlock add kernel linux-firmware` (tier 2: tell the user,
  journal it, remember to unlock).

## Boot parameters (tier 2 — approval + rollback required)

Current known-good set for a 128 GB machine, giving the iGPU up to 124 GiB and
reserving 4 GiB minimum for the OS:

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

| Param | Purpose | Notes |
|---|---|---|
| `amd_iommu=off` | Disables AMD IOMMU | Benchmarked 5–12% faster than the previously recommended `iommu=pt` (kyuz0 issue #66, urbanswelt's measurements). **Tradeoff:** no IOMMU means no VFIO/PCIe passthrough and weaker DMA isolation. If the user runs VMs with passthrough, discuss; `iommu=pt` is the fallback |
| `amdgpu.gttsize=126976` | Caps GPU-mappable unified memory, MiB | 126976/1024 = 124 GiB |
| `ttm.pages_limit=32505856` | Caps pinnable pages | 32505856 × 4 KiB = 124 GiB. Keep consistent with gttsize |

Scale for other RAM sizes: pick `RAM_GiB - 4` (minimum OS reserve; more if the
host does real CPU work — for parallel coding agents whose *tools* (compilers,
test suites) run on the CPU side, consider reserving 8–16 GiB instead).
`gttsize = GiB × 1024`; `pages_limit = GiB × 262144`.

### Applying on Fedora

Fedora's native tool is grubby (handles BLS entries correctly):

```bash
# Journal the rollback line FIRST, then:
sudo grubby --update-kernel=ALL --args="amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856"
# Verify staged: sudo grubby --info=ALL | grep -m1 args
# Ask the user to reboot. Next session: cat /proc/cmdline to confirm live.
```

Rollback:

```bash
sudo grubby --update-kernel=ALL --remove-args="amd_iommu amdgpu.gttsize ttm.pages_limit"
```

Alternative (what kyuz0 documents): edit `GRUB_CMDLINE_LINUX` in
`/etc/default/grub`, then `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`. Use
one method consistently; mixing them confuses later diffs.

An alternative to raw params for the TTM limit is AMD's helper
(`pipx install amd-debug-tools; amd-ttm --set <GiB>`), which writes
`/etc/modprobe.d/ttm.conf` (`amd-ttm --clear` reverts). Don't combine both
mechanisms.

## BIOS (tier 3 — user does it)

Set the dedicated VRAM carve-out ("UMA Frame Buffer Size") to its minimum
(typically 512 MB). The carve-out is a *guaranteed minimum*, not the budget —
the real budget comes from GTT. A large carve-out just steals RAM from the OS
permanently. 512 MB + the boot params above is the standard config.

## Understanding unified memory (avoid the classic mistakes)

Strix Halo has one physical memory pool. `mem_info_vram_total` and
`mem_info_gtt_total` are **overlapping accounting views — never sum them**.
GTT is a mapping limit, not a reservation: GPU and CPU allocations compete for
the same physical RAM dynamically.

Inspect:

```bash
awk '/MemTotal/ {printf "RAM: %.1f GiB\n", $2/1048576}' /proc/meminfo
cat /sys/class/drm/card*/device/mem_info_gtt_total   # bytes
cat /sys/class/drm/card*/device/mem_info_vram_total  # bytes
cat /sys/module/ttm/parameters/pages_limit           # × 4 KiB
cat /proc/cmdline
```

`mem_info_gtt_used` / `mem_info_vram_used` show live pressure during serving —
useful when deciding whether another parallel slot fits.

### Memory budget for the parallel-agent profile

Everything must fit in 128 GB *once*:

```
weights + KV_cache(total_ctx = per_slot_ctx × n_slots) + compute buffers
+ CPU side: OS (~4 GiB) + agents' toolchain (compilers/tests/editors!) + page cache
```

Use `gguf-vram-estimator.py` (from the kyuz0 repo, see
`model-optimization.md`) for the weights+KV side. The CPU side is easy to
forget: >4 coding agents running builds can eat tens of GiB. If the machine
swaps or the OOM killer visits during serving, the GTT limit is too generous
for the actual workload — that's a config bug, not bad luck.

## Host performance state

Worth checking once, then leaving alone (tier 1):

- **tuned profile:** `tuned-adm active`. `throughput-performance` (or
  `accelerator-performance`) suits a headless inference box; the default
  `balanced` costs a few percent under sustained load.
- **CPU governor/EPP** matter mainly for the CPU-resident parts (sampling,
  batch scheduling, agents' tools): `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`.
- **GPU power state:** `/sys/class/drm/card*/device/power_dpm_force_performance_level`
  — leave `auto` unless diagnosing; forcing `high` is a diagnostic, not a tune.
- **Thermals decide sustained throughput.** A benchmark on a cold machine
  overstates steady-state by whatever the cooling can't hold. For multi-hour
  agent sessions, verify clocks at the 30-minute mark (`sensors`,
  `amdgpu_top` if installed). Framework Desktop users can use kyuz0's
  `gpu-workload-watch` systemd unit to switch tuned profiles/fan curves on GPU
  activity.

## Experiment candidates (unproven — benchmark before believing)

- Transparent hugepages policy (`/sys/kernel/mm/transparent_hugepage/enabled`)
  interacts with `--no-mmap` allocation; community results are mixed.
- `ttm.page_pool_size` tuning beyond defaults.
- Kernel version A/B when a new major lands (keep the old kernel installed;
  Fedora retains 3 by default — boot menu selection makes this a cheap test).

Journal outcomes either way so the next session doesn't repeat the experiment.
