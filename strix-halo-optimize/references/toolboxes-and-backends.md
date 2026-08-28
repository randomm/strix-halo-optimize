# Toolboxes, Backends, and the Driver Stack

The machine runs llama.cpp inside Fedora Toolbx containers from
`kyuz0/amd-strix-halo-toolboxes` (Docker Hub: `kyuz0/amd-strix-halo-toolboxes`,
site: strix-halo-toolboxes.com). Each container is a complete backend stack
(Vulkan or ROCm userspace + llama.cpp built against it), rebuilt automatically
when llama.cpp master moves. The host only provides the kernel, amdgpu driver,
firmware, and (for Vulkan) Mesa. Facts dated 2026-08.

## Operating toolboxes from Claude Code

```bash
toolbox list                                   # what exists
toolbox run --container llama-rocm-7.14 llama-bench --help   # non-interactive exec
podman images --digests | grep strix-halo     # exact image versions (journal these!)
```

Creation (device flags matter — ROCm needs /dev/kfd):

```bash
# Vulkan
toolbox create llama-vulkan-radv \
  --image docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv \
  -- --device /dev/dri --group-add video --security-opt seccomp=unconfined

# ROCm
toolbox create llama-rocm-7.14 \
  --image docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.14 \
  -- --device /dev/dri --device /dev/kfd --group-add video --group-add render \
     --group-add sudo --security-opt seccomp=unconfined
```

Sanity check inside any toolbox: `llama-cli --list-devices`.

## Backend selection (the crossover)

| Tag | Stack | Character |
|---|---|---|
| `vulkan-radv` | Mesa RADV | Most stable/compatible; historically strongest short-context tg |
| `vulkan-amdvlk` | AMDVLK | Often fastest Vulkan, but ≤2 GiB single-buffer allocation limit — some large models won't load |
| `rocm-7.14` | ROCm 7.14 | Strongest prefill and long-context; AMD's supported gfx1151 package set |
| `rocm-6.4.4` | ROCm 6.4.4 | Conservative fallback, patched for kernel 6.18.4+ |

Experimental tags (measure, never assume): `rocm-7.14-performance` (community
fork with Strix-Halo perf work), `vulkan-radv-performance` (FA/KV-cache/MoE
work), `rocm-7.14-rocmfpx` / `vulkan-rocmfpx` (custom FP3–FP8/I4 weight
formats + MTP presets), `therock-nightly` (TheRock nightly ROCm).

**The crossover rule for the parallel-agent profile:** prefill dominates agent
workloads, and prefill favors ROCm; but the *right* answer moves with every
llama.cpp build and every model architecture. The decision procedure is
always: run `bench-sweep.sh` on the same model at the same depths in 2–3
candidate toolboxes, then `bench-parallel.sh` in the finalists. One hour of
benchmarking settles what forum threads argue about for weeks.

ROCm env toggle worth including in any ROCm comparison:
`ROCBLAS_USE_HIPBLASLT=1` (test with and without — it has been both a win and
a regression depending on build; see prime directive 2).

### rocWMMA — a case study in fact rot

2025 advice: build ROCm llama.cpp with `-DGGML_HIP_ROCWMMA_FATTN=ON` for a big
FA win. Current (ROCm 7.0.2+) advice from strixhalo.wiki: **do not use
rocWMMA** with upstream llama.cpp — it is slower as depth grows and
unmaintained pending a rewrite. If research surfaces rocWMMA tips, check their
date and the ROCm version before acting.

## Update discipline (tier 1)

Toolbox images track llama.cpp master, and per-build performance swings of
±10–25% on specific paths are normal (documented case: a single llama.cpp
update moved Vulkan tg +25%). Therefore:

1. Before refreshing, journal the current digests (`podman images --digests`).
2. Refresh: `./refresh-toolboxes.sh all` (script in the kyuz0 repo checkout)
   or recreate from a pulled tag.
3. Re-run the standard baseline benches. Keep results filed per digest.
4. If the refresh regressed the metric that matters, recreate the toolbox from
   the previous digest (`docker.io/kyuz0/amd-strix-halo-toolboxes@sha256:...`)
   and report upstream — regressions reported with depth curves get fixed.

Never mix "toolbox refreshed" with any other change in one benchmark cycle.

## Known quirks and patches (dated 2026-08 — recheck)

- The ROCm images carry a patch for llama.cpp issue #25992 (ROCm host-buffer
  selection on iGPUs breaking inference) pending an upstream fix. If building
  llama.cpp manually in a ROCm environment, check whether #25992 is resolved
  upstream first.
- MTP speculative decoding merged into llama.cpp master; the old `-mtp` tagged
  images are deprecated — use standard tags.
- llama.cpp RPC in these images supports RDMA (RoCEv2) for multi-node; on
  Toolbx, `refresh-toolboxes.sh` auto-adds `/dev/infiniband` when present.

## Building custom (when a PR matters before it merges)

The kyuz0 repo's `toolboxes/` directory has the Dockerfiles; `docs/building.md`
covers local builds. Typical reason: llama.cpp has an unmerged PR with
gfx1151-relevant gains (check `research-sources.md` → llama.cpp PR search).
Building bare-metal instead is documented at strixhalo.wiki
("llama.cpp with ROCm") — needed only when containers genuinely block
something. Prefer containers: reproducibility is worth more than the last 1%.

## When the GPU misbehaves

Order of suspicion after a crash/hang during inference: (1) firmware version
(the 20251125 class of problem), (2) kernel < 6.18.4, (3) missing `-fa 1` or
`--no-mmap`, (4) memory over-commit (check `mem_info_gtt_used` vs limit and
dmesg for amdgpu/TTM errors), (5) the specific toolbox build — try the same
run in `vulkan-radv`, which is the stability reference. `sudo dmesg | grep -iE
'amdgpu|kfd|ttm' | tail -50` after any GPU incident, and journal the
signature. Firmware-related instability has its own doc in the kyuz0 repo
(`docs/troubleshooting-firmware.md`).
