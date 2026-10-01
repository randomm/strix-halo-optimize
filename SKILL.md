---
name: strix-halo-optimize
description: Use when tuning, benchmarking, or diagnosing LLM inference on an AMD Strix Halo (gfx1151, Ryzen AI Max) machine — llama-server or llama.cpp is slow, choosing between ROCm and Vulkan RADV/AMDVLK toolboxes, prefill or decode throughput at long context, parallel agent slots and KV cache budget, GTT/VRAM or kernel boot parameter questions, whether a model or quant fits in unified memory, toolbox refresh decisions, or Unsloth fine-tuning on AMD. Applies to single-flag and single-number questions too.
license: MIT
metadata:
  hardware: "AMD Strix Halo (gfx1151, Ryzen AI Max), 128 GB unified memory"
  host_os: "Fedora, backends in Toolbx containers (kyuz0/amd-strix-halo-toolboxes)"
  primary_workload: ">=4 parallel coding agents, long context, software development"
  facts_snapshot: "2026-08-28"
---

# Strix Halo Full-Stack Optimization

Get maximum LLM inference speed out of a Strix Halo machine by working the whole
stack: BIOS → kernel/firmware → unified memory → toolboxes/drivers →
llama-server → model. This skill encodes a *methodology* plus a *dated snapshot
of current facts*. In this ecosystem the facts rot within months and reputable
sources contradict each other, so the methodology is the durable part.

## The optimization target

Unless the user says otherwise, optimize for the machine's primary workload:
**four or more parallel coding agents with long contexts**. That means, in
priority order:

1. **Prefill throughput at depth** (pp t/s at 8k–64k+ context) — agents re-read
   code and re-send long prompts constantly. This is usually the binding
   constraint, and it is compute-bound.
2. **Generation throughput under concurrency** (tg t/s with `-np 4..8` slots) —
   bandwidth-bound; on this machine ~256 GB/s of unified memory bandwidth is
   the hard ceiling.
3. **KV-cache memory budget** — total context × parallel slots is the scarce
   resource on 128 GB unified memory. A config that is 5% faster but forces
   half the context per slot is usually a regression for this workload.
4. Time-to-first-token under load, and stability over multi-hour runs.

Single-user chat latency is explicitly *not* the default target. When a user
request implies a different profile, say so and adjust.

## Prime directives

1. **Measurements beat documentation.** Every source in this space — including
   this skill — contains advice that was true for some llama.cpp build, ROCm
   version, and kernel, and false for others. Known examples: `iommu=pt` was
   the recommended boot flag until `amd_iommu=off` benchmarked 5–12% faster;
   rocWMMA flash attention was *the* ROCm tip in 2025 and is now explicitly
   discouraged for upstream llama.cpp on ROCm 7.0.2+. Never apply a tuning
   claim without benchmarking it on this machine, on the user's actual models.
2. **Change one variable at a time.** Optimizations stack non-monotonically
   here: a documented case saw ROCm + a fast-prefill patch reach 354 t/s pp,
   then *drop* to 230 t/s after layering hipBLASLt and `-ffast-math` on top.
   One change → one benchmark → keep or revert.
3. **Research live before acting on anything version-sensitive.** Before
   changing kernel params, refreshing toolboxes, choosing a backend, or citing
   a "known issue", check the sources in `references/research-sources.md` for
   movement in the last ~3 months. Treat every dated fact in this skill as a
   hypothesis to verify, not a truth to apply. The facts snapshot date is in
   the frontmatter.
4. **Respect the blast-radius ladder** (see Safety below). Env vars and server
   flags are free; boot parameters, firmware, and BIOS need explicit user
   approval, a written rollback, and a reboot plan.
5. **Journal everything.** Record each change and its measured delta in
   `~/strix-optimize/journal.md` (see Journal below). This is what makes
   multi-session optimization campaigns coherent — and it doubles as raw
   material for the user's write-ups.

## Standard workflow

Run from Claude Code on the host. Commands inside a toolbox run
non-interactively via `toolbox run --container <name> <cmd>`.

1. **Probe.** Run the read-only snapshot:
   ```bash
   ~/.claude/skills/strix-halo-optimize/scripts/probe-system.sh
   ```
   (Substitute the actual install path if different.) This reports kernel,
   firmware, boot params, GTT/TTM state, Mesa, tuned profile, and installed
   toolboxes, and flags known-bad versions. Fix any red flags first — a broken
   firmware or missing kernel param dwarfs all other tuning.
2. **Baseline.** Before touching anything, benchmark the current config on the
   user's actual model(s) with `scripts/bench-sweep.sh` (single-stream depth
   curve) and `scripts/bench-parallel.sh` (parallel slots). No baseline, no
   optimization — read `references/benchmarking.md` first.
3. **Pick the layer** with the best expected return (see layer map) and read
   its reference file.
4. **Research** that layer's current state via `references/research-sources.md`
   if anything version-sensitive is involved.
5. **Change one thing.** Follow the safety ladder.
6. **Re-benchmark** with identical settings, same depths, same repetitions.
7. **Decide**: keep (journal the win) or revert (journal the failure — negative
   results prevent repeat experiments).
8. Repeat, or stop when gains flatten. Tell the user when you believe the
   remaining headroom is small; don't manufacture busywork.

## Layer map

| Layer | Typical impact | Reference |
|---|---|---|
| Kernel, firmware, boot params, BIOS, memory (GTT/TTM), power/thermals | Broken versions: catastrophic. Params: correctness + 5–15% | `references/kernel-and-memory.md` |
| Toolboxes, backends (Vulkan RADV / AMDVLK / ROCm), driver stack | Backend choice: 10–30% on pp or tg, workload-dependent crossover | `references/toolboxes-and-backends.md` |
| llama-server flags: parallel slots, batches, KV cache, spec decoding | Largest lever for the parallel-agent profile; 2× effects possible | `references/llama-server-tuning.md` |
| Benchmarking methodology | Prevents false wins; mandatory before/after | `references/benchmarking.md` |
| Model & quant selection, memory fit, Unsloth fine-tuning on AMD | Model choice dominates everything above; quant sets the bandwidth bill | `references/model-optimization.md` |
| Live research sources and how to use them | Keeps all of the above current | `references/research-sources.md` |

Where to start when the user just says "make it faster": probe → baseline →
verify the non-negotiables (`-fa 1`, `--no-mmap`, `-ngl 999`, kernel params
present, good firmware) → backend comparison on their model at their depths →
llama-server parallel/batch/KV tuning → model/quant reconsideration.

## Safety: the blast-radius ladder

| Tier | Examples | Rules |
|---|---|---|
| 0 — Free | Env vars, llama-server flags, benchmark runs, reading sysfs | Just do it; journal results |
| 1 — Reversible, user-visible | Creating/refreshing toolboxes, tuned profile change, downloading models | Tell the user what and why; proceed unless they object. Pin previous image digests before refreshing |
| 2 — System, reversible with a reboot | Kernel boot params (grubby), TTM modprobe config, kernel/firmware version pins | Explicit user approval. Write the exact rollback command into the journal *before* applying. Claude Code does not survive reboots: stage the change, ask the user to reboot, verify in the next session (the journal carries state across sessions) |
| 3 — Firmware/BIOS | BIOS VRAM carve-out, BIOS updates | Instructions only; the user does it at the console |

Never run two GPU workloads concurrently (benchmarks lie under contention;
serving agents while benchmarking corrupts both). Check for a running
llama-server before benchmarking. Never leave the machine in an unbootable or
unclear state at the end of a session — the journal must always describe the
current config.

## Current facts snapshot (2026-08-28 — verify before relying on)

Each fact is tagged with **how it is known**. Confidence is not uniform, and the
weakest tag is the one most likely to waste your time:

- `[measured]` — benchmarked on a real gfx1151 box; see `FINDINGS.md`
- `[reported]` — from a dated primary source in `references/research-sources.md`
- `[assumed]` — inherited convention, never independently checked here

Facts:

- `[measured]` Fedora 43 on kernel **6.18.16** with **linux-firmware-20260221**
  runs gfx1151 + ROCm stably.
- `[reported]` Kernels **< 6.18.4 have a gfx1151 stability bug** — avoid.
  **linux-firmware-20251125 breaks ROCm** on Strix Halo — avoid.
- `[measured]` Boot params in use on the reference box (124 GiB to iGPU on
  128 GB): `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856`,
  plus `amdgpu.no_system_mem_limit=1 amdgpu.cwsr_enable=0`.
- `[assumed]` Non-negotiable llama.cpp flags on this hardware:
  `-fa 1 --no-mmap -ngl 999` (crashes/slowdowns without them). Widely repeated;
  never A/B'd here.
- `[reported]` Backend crossover: Vulkan RADV strongest for short-context tg and
  overall compatibility; ROCm strongest for prefill and long context; AMDVLK
  fast but ≤2 GiB single-buffer limit blocks some large models. **Not verified
  here** — every filed benchmark ran on `rocm-7.2.4`, so the ranking between
  toolbox tags is untested on this hardware. Note tags differ in llama.cpp build
  as well as ROCm version, so a "backend" comparison is never one variable.
- `[measured]` `-ub 1024` beat the `-ub 512` default by ~22% prefill on a MoE
  model at `rocm-7.2.4`; the curve is model- and backend-specific, so calibrate
  rather than adopting the number.
- `[reported]` MTP speculative decoding is merged into upstream llama.cpp; the
  old `-mtp` toolbox images are deprecated.
- `[reported]` Unsloth officially supports AMD including gfx1151 (Studio +
  notebooks; TheRock gfx1151 nightlies for PyTorch). Working but sharp edges.

When you verify or refute one of these, change its tag, add the evidence to
`FINDINGS.md`, and bump `facts_snapshot` in the frontmatter.

## Scripts

All scripts are safe by default: `probe-system.sh` is read-only;
`bench-*.sh` only run workloads and write results under `~/strix-optimize/`.

- `scripts/probe-system.sh` — full host + GPU + toolbox snapshot with
  known-bad-version flags. Run at the start of every session.
- `scripts/bench-sweep.sh` — llama-bench depth sweep wrapper (single stream),
  JSON results + metadata filed automatically.
- `scripts/bench-parallel.sh` — llama-batched-bench wrapper sweeping parallel
  levels (default 1,2,4,8) to model the multi-agent workload.
- `scripts/engine-ab.py` — engine-neutral live-serving (type 3) A/B over any
  OpenAI-compatible endpoint, measured client-side; use when comparing
  non-llama.cpp engines or serving configs llama-bench cannot model.
- `scripts/lib-provenance.sh` — shared by both bench scripts (not run directly).

Both bench scripts:

- `-e VAR=VAL` sets an env var for the run **and** records it. Use this for
  `ROCBLAS_USE_HIPBLASLT` and friends — running the tool by hand to set a
  variable produces a number with no provenance, which is not evidence.
- `-r N` repeats the sweep and reports per-row spread — the machine's noise
  floor. Deltas below it are unproven.
- Warn loudly when kernel, firmware, boot cmdline, or GPU power state changed
  since the previous run. That means the earlier baseline is void; retake it.
- Write a `FAILED` marker when the workload exits non-zero, so a broken run
  cannot be mistaken for a result.
- Append a journal entry automatically (below).

Scripts pass unknown args through to the underlying tool, because llama.cpp
flags drift; check `--help` inside the toolbox when in doubt.

## Journal

`~/strix-optimize/journal.md`, newest entry on top. The bench scripts prepend a
skeleton entry on every run with the host state pre-filled; your job is to
replace the `TODO` lines while the run is fresh. Read the journal at session
start if it exists, and write entries by hand for changes no script made
(boot params, firmware, BIOS, server config).

```markdown
## 2026-08-27 — ubatch sweep, rocm-7.14, Qwen3.6-27B Q4_K_XL
Change: -ub 512 → 1024 (only change)
Result: pp8192 342→371 t/s (+8.5%), tg@np4 unchanged, +1.9 GiB compute buffers
Decision: keep. Files: results/2026-08-27T.../
Rollback: -ub 512
Current config: [one line: kernel/firmware/params/toolbox digest/server flags]
```

Every tier-2 change gets its rollback line written *before* the change is
applied. Read the journal at session start if it exists.

## Boundaries

- This skill covers inference-stack optimization and local model work on this
  machine. It is not a PyTorch environment-setup skill; for deep PyTorch/ROCm
  validation patterns, ianbarber/strix-halo-skills is the reference.
- Do not modify BIOS, boot parameters, or firmware without explicit approval
  and a written rollback (ladder above).
- Do not present community benchmark numbers as expectations for this machine;
  they are ballparks. Numbers from this machine's journal are the truth.
- When facts here conflict with fresh research or fresh measurements, the
  skill loses. Tell the user the snapshot has rotted and, ideally, update it.
