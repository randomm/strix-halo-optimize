# Findings

Dated measurements from real Strix Halo machines. **Append-only**: entries are
never edited to match later results, because a measurement does not become
wrong — it becomes irrelevant. When a newer entry supersedes an older one, say
so in the newer entry and leave the old one standing.

The facts snapshot in `SKILL.md` is a summary that gets overwritten. This file
is the evidence it summarises. See [CONTRIBUTING.md](CONTRIBUTING.md) for what
an entry needs.

---

## 2026-10-01 — Magnitude 0.2.3 vs llama.cpp b11065 on the same GGUFs

**Machine.** AMD Strix Halo (gfx1151, Ryzen AI Max+ 395), 128 GB unified memory, Fedora 43, kernel
`6.18.16-200.fc43.x86_64`, `linux-firmware-20260221-1.fc43`, Mesa RADV 25.3.6. Boot: `amd_iommu=off
amdgpu.gttsize=126976 ttm.pages_limit=32505856 amdgpu.no_system_mem_limit=1 amdgpu.cwsr_enable=0`. GPU
power level `auto`. Caveat: the kernel was tainted (`D`) by an unrelated amdgpu oops nine days earlier
and had not been rebooted. That applies equally to all three engines.

**Method.** Type 3 (live serving). Each engine served the same file in turn, with nothing else on the
GPU. One client, `scripts/engine-ab.py`, measured all of them the same way:
- streamed time to first token, prompt tokens / TTFT as prefill, and decode rate from the stream;
- distinct prompts, so no prefix-cache wins, at temperature 0 with thinking off, generating 256 tokens;
- 3 reps per point, at about 2k, 8k and 30k tokens of depth, with concurrency 1, 2 and 4;
- a per-request codeword that has to be echoed back, as a correctness check.

Engine settings:
- **llama.cpp:** toolboxes `vulkan-radv` (`sha256:c6b821a9edd5`) and `rocm-10.0` (`sha256:90c5d79b69ad`),
  both b11065. Flags: `-fa 1 --load-mode none --parallel 4 -c 163840 --kv-unified -ctk f16 -ctv f16`, no
  speculation, plus `-ub 2048 -b 2048` for Gemma.
- **Magnitude 0.2.3:** `magnitude serve` (Vulkan) with its catalog's reviewed configuration. One full
  untimed warm-up pass ran first, so on-device kernel tuning was not counted against it.

At concurrency above 1, per-request numbers spread widely because of queueing. Compare aggregate
end-to-end throughput there, which repeated within 0–9% everywhere except the failure noted below.

**Gemma-4 26B-A4B, QAT UD-Q4_K_XL.** Magnitude's configuration has no draft, so there was no speculation
on any side. This is the like-for-like kernel comparison.

| | llama.cpp Vulkan | llama.cpp ROCm | Magnitude |
|---|---|---|---|
| Decode, 1 stream, ~1.9k | 66.9 t/s | 55.2 | **69.3** |
| Prefill, 1 stream, ~1.9k | 1,553 t/s | **1,671** | ~1,100–1,220 |
| TTFT, 1 stream, ~29k | 27.8 s | **27.4** | 30.9 |
| Aggregate, 4 streams, ~1.9k | **73.4 t/s** | 68.0 | 65.0 |
| Aggregate, 4 streams, ~7.4k | **33.4 t/s** | 25.1 | 21.0 |
| TTFT, 4 streams, ~29k | **80 s** | 120 | 138 |
| Codewords | 36/36 | 36/36 | **32/36** |

Magnitude's 32/36: one rep at ~7.4k × 4 returned **four empty streams**, with 0 tokens and no error
after 44.5 s. Its headless server wrote no engine logs (7 startup lines only), so the cause could not be
diagnosed.

**LFM2.5-2.6B Q8_0.** Magnitude ships DSpark drafting for this model and the user can't select the
method. llama.cpp ran without speculation, so this table is product against product, not a kernel
comparison.

| | llama.cpp Vulkan | llama.cpp ROCm | Magnitude (DSpark) |
|---|---|---|---|
| Decode, 1 stream, ~2k | 72.8 t/s | 67.9 | **143.7** |
| Aggregate, 4 streams, ~2k | 137 t/s | **145** | 61 |
| Aggregate, 4 streams, ~7.8k | 63 t/s | **67** | 16.5 |
| TTFT, 4 streams, ~31k | 41 s | **39** | 282 |

**Reading.**
- Magnitude's on-device kernels are at parity on single-stream decode: +3.6% on Gemma, where the
  spread was 0%. They are 25–30% behind on prefill.
- Its 2× on LFM single-stream comes from speculative drafting, not from the kernels.
- Under concurrency, per-request prefill drops by roughly 1/N, which looks like prefill handled one
  request at a time. Aggregate throughput collapses as depth grows.
- For the parallel-agent target, where prefill at depth and throughput under concurrency come first,
  it loses clearly. Not adopted.
- The empty-stream failure deserves a re-check in any later evaluation.

**Side result.** For llama.cpp b11065 on Gemma QAT Q4, Vulkan beat ROCm on decode (66.9 vs 55.2 t/s) and
on 4-stream aggregate at 7.4k (33.4 vs 25.1). ROCm was slightly ahead on 2k prefill. On LFM2.5, ROCm led
prefill (3,703 vs 2,978 t/s) and Vulkan led decode (72.8 vs 67.9). Both models fit the snapshot's
`[reported]` crossover. This is two models on one build, not enough to retag it `[measured]`.

**Setup notes.** Magnitude does not run from an unpacked package ("installation admission is
missing"): it needs its system RPM, which is unsigned. Catalog models found in the local Hugging Face
cache are picked up. Our own cached Q8_0 LFM file was not: its catalog entry pulls its own copy along
with the draft.

---

## 2026-08-28 — behavioural A/B of the fixes made after the run below

Method per [CONTRIBUTING.md](CONTRIBUTING.md): two skill copies (pre-fix and
post-fix), fresh subagent per run, identical prompts, Claude Sonnet, evidence
discoverable in files rather than stated in the prompt. Every response read
manually.

**Scenario 1 — host-state confound.** Two filed runs, `-ub 512` vs `-ub 1024`,
taken either side of a GPU power-state change. "How much did it gain, should I
ship it?"

| | Caught the confound |
|---|---|
| Pre-fix (no `dpm` in `meta.txt`) | **0 / 3** — all three said ship it |
| Post-fix (`dpm` recorded) | **3 / 3** — all three cited it and refused |

**Scenario 2 — a 4% single-run delta**, no confound present. "Did `--prio 2`
help, should I add it to production?"

| | Refused to adopt |
|---|---|
| Pre-fix | **3 / 5** |
| Post-fix | **4 / 5** (one said "adopt provisionally") |

**Scenario 2 shows no reliable improvement, and the honest reading is that the
prose rewrite did not earn its place.** The pre-existing text ("a 3% win inside
run-to-run noise is not a win") already worked most of the time. At n=3 this
looked like a clean 1/3 → 3/3 win; two more reps per side dissolved it. A
useful demonstration of the same rule the benchmarks follow: small samples
manufacture effects.

What did change on scenario 2 is **actionability, not judgement**. Pre-fix
agents advised "re-run 3× to check the noise floor" — while `bench-parallel.sh`
had no repeat flag, so the advice could not be followed. Post-fix agents advise
`bench-parallel.sh -r 3`, which exists.

Caveat: tested on Sonnet for cost, so this measures within-model contrast, not
the model that produced the original field failure.

---

## 2026-08-28 — `-ub` calibration on a 35B MoE, and three levers that didn't pay

**Machine.** AMD Strix Halo (gfx1151, Ryzen AI Max), 128 GB unified memory,
Fedora 43, kernel `6.18.16-200.fc43.x86_64`, `linux-firmware-20260221-1.fc43`.
Boot: `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
amdgpu.no_system_mem_limit=1 amdgpu.cwsr_enable=0`.

**Stack.** Toolbox `kyuz0/amd-strix-halo-toolboxes:rocm-7.2.4`
(digest `6ad4528110a0…`), llama.cpp build **10038** (`a320cbfcb`).
Model Qwen3.6-35B-A3B **Q8_0**. All runs `llama-batched-bench`,
`-fa 1 --no-mmap -ngl 999 -ctk q8_0 -ctv q8_0`, `-npp 2048,8192 -ntg 128
-npl 1,2,4,6`, `-c 53248`.

### ⚠ Read the confound first

These runs are **not** a clean single-variable set. The session was interrupted
by two hard power-loss crashes. As incident response,
`power_dpm_force_performance_level` was changed from a pinned `high` to `auto`
partway through. Runs before the change sit at `high`; runs after sit at `auto`.

The size of that state change was itself measured, because the same `-ub 512`
config was run on both sides of it:

| Row | `-ub 512` @ dpm high | `-ub 512` @ dpm auto | Δ |
|---|---|---|---|
| pp2048 npl1 | 1194.29 | 1165.62 | −2.4% |
| pp2048 npl4 | 1191.93 | 1135.16 | −4.8% |
| pp8192 npl1 | 1099.91 | 1050.33 | −4.5% |
| pp8192 npl2 | 1096.47 | 1042.98 | −4.9% |

**So ~2.4–4.9% of any cross-state comparison below is the power state, not the
lever.** That figure also bounds run-to-run noise from above; the two components
cannot be separated at n=2. Neither run was repeated, so this machine's true
spread is still unmeasured — see *Wanted* in CONTRIBUTING.md.

### `-ub 512` → `-ub 1024`: adopted, ~+22%

Same-state comparison (both at dpm `high`, 3 minutes apart):

| Row | `-ub 512` | `-ub 1024` | Δ S_PP |
|---|---|---|---|
| pp2048 npl1 | 1194.29 | 1457.75 | **+22.1%** |
| pp2048 npl2 | 1198.22 | 1461.71 | **+22.0%** |
| pp2048 npl4 | 1191.93 | 1456.13 | **+22.2%** |
| pp2048 npl6 | 1192.33 | 1458.43 | **+22.3%** |
| pp8192 npl1 | 1099.91 | 1336.24 | **+21.5%** |
| pp8192 npl2 | 1096.47 | 1335.65 | **+21.8%** |

Caveat: the `-ub 512` side is a partial run — the machine died ~60–90 s into it,
so only 6 of 8 rows exist. The completed `-ub 512` run from the next morning
sits on the other side of the dpm change and gives +25% to +29.5%; that number
is inflated by the state change and should not be quoted.

Decode was flat within the state/noise band across every row (0–4% either way).
Adopted into production; live-smoke-tested through the real serving stack.

### `--prio 2`: not adopted, effect not demonstrated

Measured −3.6% to −6.0% prefill against the `-ub 1024` baseline — but the
baseline was at dpm `high` and this run at `auto`. Subtracting the 2.4–4.9%
state delta leaves roughly −1% to −2%, which is inside the band this machine
has not yet shown it can resolve. **This is not evidence that `--prio 2` hurts.**
It is evidence that the test was not controlled. Decode was ~3% *higher*.

### `ROCBLAS_USE_HIPBLASLT=1`: not adopted, probably a real regression

| Row | baseline `-ub 1024` | + hipBLASLt | Δ |
|---|---|---|---|
| pp2048 npl1 | 1457.75 | 1351.79 | −7.3% |
| pp2048 npl4 | 1456.13 | 1341.98 | −7.8% |
| pp8192 npl1 | 1336.24 | 1233.71 | −7.7% |
| pp8192 npl6 | 1339.03 | 1229.92 | −8.2% |

Same dpm caveat: residual after the state delta is roughly −3% to −5%.
Consistent in sign and size across all 8 rows, so more likely real than not —
but it needs a controlled re-run to stand as a number. The skill's existing
"both directions have won depending on build" framing survives; this build is a
"no" on this model.

*Provenance note:* this run was executed by hand rather than through
`bench-parallel.sh`, because the script recorded `ROCBLAS_USE_HIPBLASLT` but had
no way to set it. Its numbers were recovered from a separate log afterwards.
That gap is now closed — `bench-parallel.sh -e VAR=VAL`.

### `-np 8` vs `-np 6`: a tradeoff, not a lever

Swept in one run at `-c 69632`, so internally controlled:

| Row | `-np 6` | `-np 8` |
|---|---|---|
| pp8192 aggregate S_TG | 113.38 t/s | 124.40 t/s |
| pp8192 **per agent** | 18.90 t/s | 15.55 t/s |
| pp2048 aggregate S_TG | 128.17 t/s | 141.44 t/s |
| pp2048 **per agent** | 21.36 t/s | 17.68 t/s |

Aggregate throughput keeps climbing while per-agent speed falls. There is no
"better" here — pick the point where per-agent latency is still acceptable.
Stayed at `-np 6`.

### `--cache-reuse 256`: not measurable with these tools

`llama-batched-bench` rejects the flag outright
(`error: invalid argument: --cache-reuse`). It is a llama-server behaviour over
repeated requests with a growing shared prefix — exactly the coding-agent
pattern — and no script in this repo can currently exercise it. Unverified.

### GPU power state: `high` is not a tune

The box had `power_dpm_force_performance_level` pinned to `high` continuously
via a custom systemd unit, on a stale never-re-verified assumption. Pinned high
means 2900 MHz at idle as well as under load: idle package draw ~27–29 W. On
`auto` it dropped to ~11 W with no measured loss beyond the band above. The
skill already said forcing `high` is a diagnostic, not a tune; this is a
concrete instance.

### What this run changed in the skill

The methodology did not catch its own confound: the session compared across a
power-state change, reported two levers as regressions, and closed by asserting
that its discipline was working. Every failure was a missing mechanism, not
missing prose — `benchmarking.md` already said a 3% win inside noise is not a
win, and `bench-parallel.sh` had no way to repeat a run.

Fixed in response: `-e VAR=VAL` provenance-preserving env passthrough; `-r N`
repeats with per-row spread; an automatic host-state diff that refuses to let a
stale baseline pass silently; `FAILED` markers on crashed runs; and automatic
journal entries.
