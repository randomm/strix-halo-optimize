# strix-halo-optimize

A Claude Code skill for full-stack LLM inference tuning on AMD Strix Halo
(gfx1151, Ryzen AI Max) machines running Fedora — kernel boot parameters,
unified memory (GTT/TTM), Toolbx backend containers (Vulkan RADV/AMDVLK,
ROCm), `llama-server` configuration, benchmarking, model and quant selection,
and Unsloth fine-tuning on AMD.

It optimizes for a target almost nobody else benchmarks: **several parallel
coding agents with long contexts**, served from one `llama-server`. Prefill
throughput at depth first, generation under concurrency second, KV-cache
budget as the scarce resource. Single-user chat latency is explicitly not the
goal. The skill says so openly and adjusts when you ask for a different
profile.

## What happened when we actually ran it

On 2026-08-27/28 this skill ran unsupervised on its target hardware against a
35B MoE model. It found a real **+22% prefill win** (`-ub 512 → 1024`).

It also produced two false findings, and closed by telling the user its
discipline was "doing its job, not just theater." It wasn't. A GPU power-state
change had slipped between the baseline and the follow-up tests — incident
response to a hard crash — and nothing in the skill or its tooling noticed. Two
levers got written up as regressions on evidence that couldn't support the
claim.

Every one of those failures was a **missing mechanism, not missing prose**. The
skill already said to journal every run; seven runs produced no journal. It
already said a 3% win inside noise is not a win; the parallel benchmark had no
way to repeat a run. It already said to A/B the one ROCm env toggle; the script
recorded that variable but gave you no way to set it, so the test got run by
hand and its provenance was lost.

So the scripts changed:

- `-e VAR=VAL` sets an env var **and** records it — no reason left to run the
  tool by hand and lose the trail
- `-r N` repeats the sweep and prints per-row spread, so you know your
  machine's noise floor before believing a delta
- every run's host fingerprint (kernel, firmware, boot cmdline, GPU power
  state) is compared against the previous one, and a changed state prints a
  banner saying the old baseline is void
- failed runs get a `FAILED` marker instead of a directory that looks like a
  result
- the journal entry the skill demands is now written by the script

The full measurements, including the confound, are in
[FINDINGS.md](FINDINGS.md).

## Why a skill instead of a web search

Strix Halo tuning knowledge rots within months, and reputable sources
contradict each other:

- `iommu=pt` was the recommended boot flag until `amd_iommu=off` benchmarked
  5–12% faster.
- rocWMMA flash attention was *the* ROCm tip in 2025; for upstream llama.cpp
  on ROCm 7.0.2+ it is now explicitly discouraged.
- Optimizations stack non-monotonically: one documented case lost a third of
  its prefill speed by layering two individually "good" tweaks.

So the durable part is the methodology it enforces: **probe → baseline →
research live sources → change one variable → benchmark → keep or revert →
journal.** Facts are included, but each is tagged with how it is known —
`[measured]` here, `[reported]` by a dated source, or `[assumed]` — because
they do not deserve equal confidence.

## What's inside

```text
SKILL.md                          # methodology, workflow, safety ladder, facts snapshot
references/
├── kernel-and-memory.md          # version gates, boot params (grubby), GTT/TTM math, host state
├── toolboxes-and-backends.md     # kyuz0 toolboxes, backend crossover, update discipline
├── llama-server-tuning.md        # parallel slots, KV cache, batch calibration, MTP speculation
├── benchmarking.md               # depth sweeps, parallel sweeps, rules that keep results honest
├── model-optimization.md         # quant selection, memory fit, Unsloth-on-AMD ground rules
└── research-sources.md           # where each kind of fact lives, and how to date-stamp claims
scripts/
├── probe-system.sh               # read-only host/GPU/toolbox snapshot with known-bad-version flags
├── bench-sweep.sh                # llama-bench depth-sweep wrapper, files results + provenance
├── bench-parallel.sh             # llama-batched-bench wrapper for the concurrency knee
└── lib-provenance.sh             # shared provenance capture, state-diff guard, journal append
FINDINGS.md                       # dated log of measurements from real machines
```

Results and an optimization journal accumulate under `~/strix-optimize/` on
the machine. The journal carries state across sessions (Claude Code does not
survive reboots) and doubles as raw material for write-ups.

## Assumptions

- AMD Strix Halo (gfx1151); developed against a 128 GB machine, memory math
  generalizes to other sizes.
- Fedora host with backends in Toolbx containers from
  [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes).
  Bare-metal llama.cpp builds work with the same methodology; the container
  conveniences (`-C` flag in the bench scripts) assume Toolbx.
- Claude Code running on the machine itself, so it can probe, benchmark, and
  apply changes directly.

## Install

Clone straight into your Claude Code skills directory:

```bash
git clone https://github.com/randomm/strix-halo-optimize.git \
  ~/.claude/skills/strix-halo-optimize
chmod +x ~/.claude/skills/strix-halo-optimize/scripts/*.sh
```

That's the whole install — `SKILL.md` lives at the repo root, so the clone *is*
the skill. Update with `git pull`. Because the copy you run is a git checkout
with the remote configured, fixing a rotted fact and opening a PR is editing the
files you're already using (see [CONTRIBUTING.md](CONTRIBUTING.md)).

No git? Use GitHub's **Code → Download ZIP**, then extract and rename the
`strix-halo-optimize-main/` folder to `~/.claude/skills/strix-halo-optimize/`.

Then just talk to Claude Code about performance. Good first prompts:

- "Run the Strix Halo probe and tell me what's wrong with this machine."
- "My six agents feel slow against llama-server — fix it."
- "Should I move from vulkan-radv to rocm-7.14 for this model at 32k context?"

The scripts also work standalone, without Claude:

```bash
~/.claude/skills/strix-halo-optimize/scripts/probe-system.sh
~/.claude/skills/strix-halo-optimize/scripts/bench-sweep.sh \
  -m ~/models/model.gguf -C llama-rocm-7.14 -t rocm-baseline
```

## Safety model

- `probe-system.sh` is strictly read-only. The bench scripts only run
  workloads and write results under `~/strix-optimize/`; they refuse to run
  while a `llama-server` is live (benchmarks under contention lie).
- The skill enforces a blast-radius ladder: environment variables and server
  flags are free; toolbox refreshes are announced (with image digests pinned
  first); **kernel boot parameters, TTM config, and version pins require
  explicit user approval with the rollback command written into the journal
  before the change is applied**; BIOS and firmware changes are
  instructions-only.

## Facts snapshot and maintenance

Version-sensitive facts (blessed kernel/firmware combo, boot parameters,
backend rankings, Unsloth AMD status) are stamped **2026-08-27** in the
`facts_snapshot` frontmatter field. The skill instructs Claude to check the
sources in `references/research-sources.md` before acting on anything
version-sensitive, and to update the snapshot in place — and bump the date —
when fresh research or fresh measurements win. Treat the skill like code:
if you find a rotted fact, a PR that fixes it and bumps the date is the
ideal contribution.

Validation state: the scripts' guard rails, result filing, and provenance
capture are tested (including graceful degradation on non-Strix hardware);
the GPU paths follow documented llama.cpp behavior but flag names drift
between builds — the scripts pass unknown arguments through verbatim and the
skill tells Claude to check `--help` inside the toolbox when in doubt.

## Scope and non-goals

In scope: inference-stack performance on this hardware, benchmarking
discipline, model/quant selection, and the local fine-tune → GGUF → serve
loop with Unsloth.

Not in scope: PyTorch environment setup and validation (see
[ianbarber/strix-halo-skills](https://github.com/ianbarber/strix-halo-skills),
which also inspired this skill's structure), Windows, distributed multi-node
serving beyond pointers, and generic LLM advice that isn't
Strix-Halo-specific.

## Sources and credits

Built on the work of the Strix Halo community:

- [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) — toolboxes, host configuration, benchmark methodology
- [strixhalo.wiki](https://strixhalo.wiki) and [lhl/strix-halo-testing](https://github.com/lhl/strix-halo-testing) — deep llama.cpp performance research
- [ianbarber/strix-halo-skills](https://github.com/ianbarber/strix-halo-skills) — the skill-design inspiration
- [AMD ROCm Strix Halo system optimization](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html) and [Unsloth AMD documentation](https://unsloth.ai/docs/basics/amd)

## License

MIT.
