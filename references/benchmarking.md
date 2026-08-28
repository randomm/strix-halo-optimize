# Benchmarking Methodology

Benchmarks are the skill's ground truth. A sloppy benchmark is worse than none
— it launders noise into "results" that misdirect weeks of tuning. The wrapper
scripts encode most of this; read this file to know *why*, and for the manual
techniques the scripts don't cover.

## The three benchmark types

1. **Depth sweep, single stream** (`bench-sweep.sh`, wraps `llama-bench`):
   pp and tg at increasing context depth (`-d`). Answers: how does this
   (model × backend × flags) degrade as context grows? This is the workhorse
   for backend comparisons and ubatch calibration.
2. **Parallel sweep** (`bench-parallel.sh`, wraps `llama-batched-bench`):
   throughput at parallel levels 1,2,4,8. Answers: what does each additional
   agent cost? Where's the knee? This is the one that models the real
   workload.
3. **Live serving measurement**: run the actual `llama-server` config with
   `--metrics`, drive realistic concurrent requests, read TTFT and per-slot
   rates from `/metrics` and `/slots`. Use for final validation of a config,
   because llama-bench cannot capture slot scheduling, cache-reuse, or
   speculation effects.

## Rules that make results comparable

- **One GPU workload at a time.** Check nothing is being served
  (`pgrep -af llama-server`) before benchmarking. Agents hammering the server
  during a bench invalidates both.
- **Fix everything except the variable under test** — model file, depths,
  reps, flags, toolbox digest. The kyuz0 campaign methodology fixes: FA on,
  mmap off, ngl 99+, KV quant off (for comparability), pp 2048, tg 128,
  reps 3, cooldown between runs. Deviate deliberately, not accidentally.
  Note: benchmark comparisons run KV quant off even though production configs
  use `-ctk/-ctv q8_0` — benchmark the production config separately as type 3.
- **Know this machine's spread before believing any delta.** Measure it once:
  `bench-parallel.sh -r 3` (or `bench-sweep.sh -r 3`) reruns the sweep and
  prints per-row spread. That percentage is the machine's floor. A delta counts
  as real when it is larger than the spread; below it, the honest report is
  "unproven", not "small win". Re-measure the spread after any host change.
  Cooldown (~10 s+) between heavy runs for thermal comparability; for
  sustained-load truth, note results at thermal steady state (30 min in).
- **A host state change voids your baseline.** Kernel, firmware, boot
  parameters, and GPU power state
  (`power_dpm_force_performance_level`) all move the numbers. If any changed
  since the baseline was taken, the old numbers are not a comparison — retake
  the baseline under current state first. The bench scripts capture these into
  `meta.txt` and print a loud banner when they differ from the previous run;
  that banner means stop and re-baseline, not proceed carefully.
- **Record provenance with every result**: date, toolbox tag + image digest,
  llama.cpp build (printed in bench output), kernel, relevant env vars
  (`ROCBLAS_USE_HIPBLASLT`...), and the exact command. The scripts capture
  most of this into a metadata file automatically.
- Results live under `~/strix-optimize/results/<timestamp>-<tag>/`; the
  journal links to them.

## llama-bench essentials

```bash
toolbox run --container llama-rocm-7.14 llama-bench \
  -m model.gguf -fa 1 --mmap 0 -ngl 999 \
  -d 0,8192,16384,32768,65536 -p 2048 -n 128 -r 3 -o json
```

- `-d` sets the KV depth at which pp/tg are measured — the depth curve is the
  whole point on this hardware; a 0-depth-only result is marketing.
- `-p 2048` (prefill chunk) and `-n 128` (gen tokens) are the standard probe
  sizes; `-ub 256,512,1024,2048` sweeps microbatch in one invocation.
- `-o json` for machine-readable results (the scripts do this and also keep
  the human-readable table).
- Full nine-depth curves (0..65536 step 8192) × 4 ubatches on a big model run
  for hours. Scope sweeps to the decision at hand; launch long campaigns
  detached (`nohup ... &`) and check in later rather than polling.

## llama-batched-bench essentials

```bash
toolbox run --container llama-rocm-7.14 llama-batched-bench \
  -m model.gguf -fa 1 --no-mmap -ngl 999 \
  -c 262144 -b 2048 -ub 1024 \
  -npp 2048,8192 -ntg 128 -npl 1,2,4,8
```

- `-npl` is the parallel level (concurrent sequences); `-npp`/`-ntg` per-seq
  prompt/gen sizes. `-c` must fit `npl_max × (npp_max + ntg)` — under-sizing
  it fails or silently truncates the top rows.
- Read `S_PP` (aggregate prefill t/s), `S_TG` (aggregate gen t/s), and per-seq
  speeds across `-npl` rows: aggregate should rise while per-seq falls; the
  knee where per-seq drops below what an agent tolerates is your `-np` answer.

## Interpreting pp vs tg on this hardware

- **tg is bandwidth-bound** (~256 GB/s ceiling): tg t/s ≈ bandwidth ÷ bytes
  touched per token (active weights + KV). That's why quantization and MoE
  (small active-parameter sets) move tg, and why compute-side tuning barely
  does.
- **pp is compute-bound**: batch sizes, backend GEMM paths (hipBLASLt), and FA
  implementation move it. This is where the agent profile has the most
  tunable headroom.
- A change that helps one and hurts the other is normal; judge against the
  workload priority order in SKILL.md.

## Community baselines (calibration, not truth)

kyuz0's interactive viewers (kyuz0.github.io/amd-strix-halo-toolboxes —
per-toolbox depth curves), lhl's strix-halo-testing sweeps, and the
strixhalo.wiki performance pages give ballpark expectations per model class.
Use them to detect "this machine is 2× slower than it should be" (config bug)
— never as a substitute for local measurement.
