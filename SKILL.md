---
name: strix-halo-optimize
description: Full-stack performance optimization for an AMD Strix Halo (gfx1151, Ryzen AI Max) machine running Fedora with Toolbx containers — kernel boot parameters, unified memory (GTT/TTM), Vulkan/ROCm toolboxes, llama.cpp/llama-server tuning, benchmarking, model and quant selection, and Unsloth fine-tuning on AMD. Use whenever the user wants to speed up, tune, benchmark, diagnose, or configure LLM inference on this machine — "why is llama-server slow", "which toolbox/backend should I use", "tune for parallel agents", "does this model fit in memory", kernel parameter or GTT/VRAM questions, toolbox refresh decisions, backend comparisons, or fine-tuning/quantizing models locally with Unsloth. Trigger even for single-layer questions (one flag, one kernel param, one memory number) — the methodology and dated facts snapshot here prevent stale or contradictory advice, which is common in this fast-moving space.
license: MIT
metadata:
  hardware: "AMD Strix Halo (gfx1151, Ryzen AI Max), 128 GB unified memory"
  host_os: "Fedora, backends in Toolbx containers (kyuz0/amd-strix-halo-toolboxes)"
  primary_workload: ">=4 parallel coding agents, long context, software development"
  facts_snapshot: "2026-08-27"
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

## Current facts snapshot (2026-08 — verify before relying on)

- Stable host: Fedora 43, kernel 6.18.9. Kernels **< 6.18.4 have a gfx1151
  stability bug** — avoid. **linux-firmware-20251125 breaks ROCm** on Strix
  Halo — avoid; 20260110 known good.
- Boot params (124 GiB to iGPU on a 128 GB machine):
  `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856`
- Non-negotiable llama.cpp flags on this hardware: `-fa 1 --no-mmap -ngl 999`
  (crashes/slowdowns without them).
- Backend crossover: Vulkan RADV strongest for short-context tg and overall
  compatibility; ROCm (7.14) strongest for prefill and long context; AMDVLK
  fast but ≤2 GiB single-buffer limit blocks some large models. Experimental
  tags (`rocm-7.14-performance`, `vulkan-radv-performance`, `rocmfpx`) exist —
  measure, don't assume.
- MTP speculative decoding is merged into upstream llama.cpp; the old `-mtp`
  toolbox images are deprecated.
- Unsloth officially supports AMD including gfx1151 (Studio + notebooks;
  TheRock gfx1151 nightlies for PyTorch). Working but with sharp edges.

## Scripts

All scripts are safe by default: `probe-system.sh` is read-only;
`bench-*.sh` only run workloads and write results under `~/strix-optimize/`.

- `scripts/probe-system.sh` — full host + GPU + toolbox snapshot with
  known-bad-version flags. Run at the start of every session.
- `scripts/bench-sweep.sh` — llama-bench depth sweep wrapper (single stream),
  JSON results + metadata filed automatically.
- `scripts/bench-parallel.sh` — llama-batched-bench wrapper sweeping parallel
  levels (default 1,2,4,8) to model the multi-agent workload.

Scripts pass unknown args through to the underlying tool, because llama.cpp
flags drift; check `--help` inside the toolbox when in doubt.

## Journal

Keep `~/strix-optimize/journal.md`, newest entry on top:

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
