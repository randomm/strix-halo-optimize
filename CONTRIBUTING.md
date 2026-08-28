# Contributing

This skill's facts rot by design. Kernel versions, firmware regressions, backend
rankings, and llama.cpp flag behaviour all move within a quarter, and reputable
sources in this space contradict each other. **The most valuable contribution is
one that un-rots a fact**, with evidence attached.

You install this repo by cloning it into `~/.claude/skills/`, so the copy you
run is a git checkout with the remote configured. Fixing something is editing
the files you are already using.

## Every PR shows a before/after

That's the whole rule. What counts as "before/after" depends on what you claim:

| Your claim | What the PR needs |
|---|---|
| **Performance** — "`-ub 1024` is faster" | Numbers from the bench scripts, one variable changed. Paste the journal entry the script wrote, plus your hardware/version line. |
| **Fact refresh** — "6.19.2 is the stable kernel now" | A dated, version-matched source from `references/research-sources.md`. Say if you haven't verified it on your own machine — that's fine, it just changes the tag. |
| **Behaviour** — "Claude keeps recommending X" | The session where it went wrong, and what it does after your change. |

Not accepted: undated advice, forum reports with no reproduction, and numbers
from another architecture presented as gfx1151.

### Performance claims: the two rules that actually bite

Both of these were learned the hard way — see the 2026-08-28 entry in
[FINDINGS.md](FINDINGS.md), where a real session reported two levers as
regressions that its own data could not support.

1. **Measure your machine's spread first.** Run `bench-parallel.sh -r 3` once.
   It prints per-row spread. A delta counts as real when it is *larger than that
   spread*. Below it, the honest word is "unproven" — not "small win".
2. **A host state change voids your baseline.** Kernel, firmware, boot params,
   GPU power state. The scripts record these into `meta.txt` and print a banner
   when they differ from your previous run. That banner means stop and
   re-baseline, not proceed carefully.

## The journal entry is the unit of contribution

The bench scripts prepend a skeleton entry to `~/strix-optimize/journal.md` on
every run, with host state pre-filled and `TODO` where judgement is needed. Fill
in the TODOs, paste the entry into your PR body. That's the whole format — no
separate template to learn, and the artifact already exists because the tool
made it.

## Where things go

- **A fact changed** → update the bullet in `SKILL.md`'s facts snapshot, change
  its `[measured]`/`[reported]`/`[assumed]` tag, fix the matching file in
  `references/`, and bump `facts_snapshot` in the frontmatter.
- **A measurement** → append to `FINDINGS.md`. Never edit an existing entry to
  match new results; add a new one that supersedes it. Measurements don't become
  wrong, they become irrelevant.
- **Depth** → `references/`, not `SKILL.md`. `SKILL.md` loads whenever the skill
  triggers, so its token budget is real. Keep the frontmatter under 1024
  characters and the description to triggering conditions only.
- **No narrative in `SKILL.md`.** "In session 2026-08-28 we found…" belongs in
  `FINDINGS.md`. The skill states rules in general form.

## The scripts' safety contract

Do not regress these:

- `probe-system.sh` is strictly read-only.
- Bench scripts write only under `~/strix-optimize/`.
- They refuse to run while a `llama-server` is live — benchmarks under
  contention lie.
- They degrade gracefully off-Strix (this is testable on any laptop, so
  "I don't have the hardware" is not a reason to skip testing).
- They pass unknown args through verbatim, because llama.cpp flags drift.
- They mark failed runs `FAILED` rather than filing a directory that looks like
  a result.
- `shellcheck` and `bash -n` clean.

## Out of scope

Declined quickly and without prejudice: PyTorch environment setup (see
[ianbarber/strix-halo-skills](https://github.com/ianbarber/strix-halo-skills)),
Windows, distributed multi-node serving, and generic LLM advice that isn't
Strix-Halo-specific.

## Wanted

Concrete things this repo needs, roughly in order of value:

1. **`bench-server-reuse.sh`** — a live-serving measurement script. Method 3 in
   `references/benchmarking.md` has no tooling, which means `--cache-reuse`,
   slot scheduling, and speculation effects cannot currently be measured at all.
   Launch a real `llama-server`, send N requests with a growing shared prefix,
   measure TTFT with and without the flag.
2. **A real repeat-spread measurement.** Run the same config 5× on a stable box
   and publish the spread. Nobody in this space publishes the noise floor of the
   measurement, and every tuning guide reports 3–5% wins as fact. This needs no
   special insight — just a machine that isn't crashing.
3. **A controlled `--prio 2` and `ROCBLAS_USE_HIPBLASLT` re-test**, same host
   state throughout. The existing numbers are confounded.
4. **Backend comparison on current toolbox tags.** Every filed benchmark here
   ran on `rocm-7.2.4`; the snapshot's backend ranking is `[reported]`, not
   measured. Note that tags differ in llama.cpp build as well as ROCm version,
   so this is never a single-variable comparison — say so in your entry.
5. **Non-128 GB machines.** The memory math should generalise; nobody has
   checked.

## License

MIT. Contributions are accepted under the same license.
