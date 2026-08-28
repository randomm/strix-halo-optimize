# Live Research Sources

This skill's facts snapshot rots. Before acting on anything version-sensitive
(kernel/firmware versions, boot params, backend rankings, build flags, Unsloth
status), spend a few minutes here. Prefer sources with *measurements and
dates* over advice; when two sources conflict, the newer measurement on the
same llama.cpp/ROCm generation wins.

## Primary sources, by what they're authoritative for

| Source | Authoritative for |
|---|---|
| github.com/kyuz0/amd-strix-halo-toolboxes (+ strix-halo-toolboxes.com) | Toolbox tags & their state, blessed kernel/firmware combo ("Stable Configuration"), host boot params, known llama.cpp issues affecting Strix Halo, benchmark methodology. **Check the README + recent issues first for almost any question.** Interactive benchmark viewers: kyuz0.github.io/amd-strix-halo-toolboxes |
| strixhalo.wiki (AI section) | Deep llama.cpp performance practice: ROCm builds, rocWMMA status, hipBLASLt, long-context testing, tuned-build branches |
| github.com/lhl/strix-halo-testing + llm-tracker.info | Rigorous depth-curve benchmark data, backend internals (GEMM/FA paths per architecture), build scripts |
| strixhalo-homelab.d7.wtf | Hardware database, homelab-grade host configs |
| github.com/ggml-org/llama.cpp — issues & PRs | The moving target itself. Search open+recently-merged for: `gfx1151`, `strix halo`, `Vulkan flash attention`, `MUL_MAT_ID`, `hipBLASLt`. A relevant merged PR often obsoletes every guide written before it |
| rocm.docs.amd.com — Strix Halo system optimization page; ROCm/TheRock releases | AMD's official memory/BIOS guidance (amd-ttm), ROCm release state for gfx1151, TheRock nightly index layout |
| unsloth.ai/docs/basics/amd + unslothai/unsloth issues | AMD/gfx1151 training support status, install tracks, bitsandbytes wheels, known model-family failures (NaN classes) |
| Fedora sources (bodhi/koji, fedoraproject wiki) | What kernel/firmware/Mesa an update will actually install — check before `dnf update` on this machine |
| r/LocalLLaMA, level1techs forum | Early signals and repro reports. Treat as hypotheses to verify, never as instructions |

## How to research a tuning question (the loop)

1. **Frame it falsifiably**: "does X improve pp at depth ≥16k on gfx1151 with
   current rocm-7.14 toolbox" — not "is X good".
2. **Check kyuz0 README/issues** — most Strix-Halo-wide facts land there
   within days.
3. **Search fresh** (restrict to ~last 3 months; this ecosystem's half-life is
   about one quarter). Include `gfx1151` or `strix halo` in queries — generic
   llama.cpp advice frequently doesn't transfer to RDNA3.5/UMA.
4. **Date-stamp every claim found** and note its llama.cpp build/ROCm/kernel
   generation. Advice without a version context is unusable.
5. **Reduce to a local experiment** — one variable, benchmarked per
   `benchmarking.md`. The web tells you what to try; only this machine tells
   you what's true.
6. **Journal it**, including dead ends, with source links.

## Standing searches that pay off

- `llama.cpp gfx1151 performance` (new PRs/regressions)
- `strix halo kernel <next version>` before major Fedora kernel updates
- `linux-firmware strix halo regression` before firmware updates
- `unsloth gfx1151 issue` before a training campaign
- kyuz0 repo issues sorted by recent activity

## When this skill and fresh research disagree

The research wins if it's newer and version-matched; then update this skill's
facts snapshot (SKILL.md + affected reference) and bump the
`facts_snapshot` date in the frontmatter — the skill lives in the user's
skills directory and is meant to be maintained like code.
