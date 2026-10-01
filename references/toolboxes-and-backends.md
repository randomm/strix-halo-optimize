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

## Non-llama.cpp engines (watch list, not recommendations)

Engines that claim to beat llama.cpp appear often. Treat each as a hypothesis:
check model coverage first (most of them do not cover the newest architectures),
then measure on this machine with the procedure above. Facts dated per entry.

- **Magnitude** (github.com/magnitudedev/magnitude, Apache 2.0) `[reported]`,
  checked 2026-10-01 at commit `7280034`. Rust engine that compiles and autotunes
  its kernels on the device; OpenAI-compatible API; Linux x64 CLI releases.
  - AMD support is **Vulkan/RADV only** (no ROCm). It requires
    `VK_KHR_cooperative_matrix`; its own RDNA3 setup guide asks for Mesa RADV
    26.2+, but RADV 25.3 already exposes the extension on gfx1151 (seen on one
    Fedora 43 host).
  - Published speedups ("up to 2x faster than llama.cpp") are **Metal and CUDA
    only**. Its AMD validation host is a discrete RDNA3 card (Radeon PRO V710);
    there are no published gfx1151 or Vulkan-vs-llama.cpp numbers. Not verified
    on gfx1151.
  - Model coverage is per-family hand-written kernels (`inference/catalog/models.json`).
    At this commit Qwen3.8-Flash-Next (qwen4exp) is `disabled`
    ("hyper-connections and QSA attention are not implemented yet"); Gemma-4
    26B-A4B is supported only as the QAT Q4 GGUF, with no MTP draft (separate
    drafts are DFlash/DSpark/DFlash2 only).
  - Hosts with a BIOS VRAM carve-out may see only OS-visible RAM (issue #44,
    fix in PR #124, both open at this date). Hosts using the GTT-based memory
    setup (`kernel-and-memory.md`) are not affected.
  - **Re-check when:** the catalog enables a model you serve, it gains MTP for
    a family you run with MTP, or it publishes Vulkan/AMD benchmarks.
  - **Fair test:** the same GGUF in Magnitude and in the `vulkan-radv` and
    `rocm-*` toolboxes, speculative decoding off on both sides, same depths
    and slot counts. `bench-sweep.sh` / `bench-parallel.sh` drive llama.cpp
    only, so Magnitude needs live-serving measurement (`benchmarking.md`,
    method 3).

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
