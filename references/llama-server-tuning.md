# llama-server Tuning for Parallel Agents + Long Context

The biggest lever after model choice. This reference is organized around the
primary workload: ≥4 coding agents hitting one server with long prompts.
Flags drift between llama.cpp builds — verify against
`toolbox run --container <tb> llama-server --help` when something looks off.

## Non-negotiables on Strix Halo

Every invocation, always: `-fa 1 --no-mmap -ngl 999`. Missing flash attention
or no-mmap causes crashes and severe slowdowns on this hardware; `-ngl 999`
offloads all layers (partial offload on a UMA machine is almost never right).

## Parallel slots: the core of the agent profile

```bash
llama-server -m model.gguf -ngl 999 -fa 1 --no-mmap \
  -c 262144 -np 8 \
  --metrics --host 0.0.0.0 --port 8080
```

- `-np N` (`--parallel`): number of slots. **`-c` is the TOTAL context,
  divided across slots** — `-c 262144 -np 8` gives each agent 32k. This is the
  single most misunderstood flag; an unchanged `-c` with a raised `-np`
  silently shrinks every agent's context.
- Size N to the *concurrent* demand, not the number of agents that exist:
  slots sit in continuous batching, and prefill for one slot competes with
  generation for others. Start at N = number of agents, benchmark N±2.
- Continuous batching is default-on in current builds. `--metrics` exposes
  Prometheus metrics; `GET /slots` shows live per-slot state — use these to
  observe real utilization rather than guessing.
- Generation throughput under concurrency is bandwidth-bound: aggregate tg
  scales sublinearly and per-slot tg drops as N rises. `bench-parallel.sh`
  quantifies the curve; pick the knee that matches acceptable per-agent speed.

## KV cache: where the memory goes

At long context × many slots, KV dwarfs everything but weights.

- **Quantized KV:** `-ctk q8_0 -ctv q8_0` (requires FA, which is on anyway)
  halves KV memory vs f16 with usually negligible quality impact — this often
  buys 2× context per slot, which for this profile beats a small speed win.
  q4_0 KV exists but quality risk rises; benchmark on real agent transcripts
  before adopting.
- **`--cache-reuse 256`:** enables prefix-cache chunk reuse — big TTFT win for
  agent loops that resend growing transcripts with a stable prefix. **Cannot be
  measured with the bench scripts**: it is a llama-server flag and
  `llama-batched-bench` rejects it outright (`error: invalid argument:
  --cache-reuse`). Verifying it needs live-serving measurement (type 3 in
  `benchmarking.md`) against a real server with repeated growing-prefix
  requests. Currently unverified on this hardware.
- **`--cache-ram <MiB>`** (build-dependent): host-side prompt cache budget.
- Slot save/restore endpoints exist for persisting agent KV across restarts —
  niche, check `--help`.

Estimate before launching: `gguf-vram-estimator.py model.gguf --contexts
<total_ctx>` (see `model-optimization.md`), then verify live with
`mem_info_gtt_used` under full load.

## Batch sizes: the prefill lever

- `-b` (logical batch, default 2048) and `-ub` (physical microbatch) govern
  prefill throughput and compute-buffer memory. Prefill-heavy agent workloads
  usually reward larger `-ub` — but the curve is model- and backend-specific
  and non-monotonic.
- Calibrate: sweep `-ub 256,512,1024,2048` across the depth curve
  (`bench-sweep.sh -m model --ub 256,512,1024,2048`). Pick per
  (model, backend) pair and journal it — the kyuz0 benchmarking methodology
  treats ubatch calibration as a first-class step keyed exactly that way.
- Larger `-ub` costs compute-buffer memory; re-check the fit math after.

## Speculative decoding and MTP

Code generation has high draft-acceptance rates, so speculation is unusually
effective for this workload — *when generation, not prefill, is the
bottleneck* (check the benchmark split first; speculation does nothing for
prompt processing).

- MTP models (e.g. Qwen MTP variants): merged into upstream llama.cpp;
  `--spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.75` is a
  community-validated starting point. Flag names are new and may drift.
- Classic draft-model speculation (`-md draft.gguf` + `--draft-max/--draft-min`)
  costs extra memory for the draft model — count it in the budget.
- Interaction warning: speculation × many parallel slots multiplies compute;
  benchmark at the real `-np`, not at `-np 1`.

## ROCm environment toggles

- `ROCBLAS_USE_HIPBLASLT=1` — the one toggle regularly worth testing on ROCm
  backends (both directions have won, depending on build). Set it in the
  server's environment, not globally.
- Resist stacking exotic HSA_*/GGML_* env vars from forum posts; most are
  diagnostics. One at a time, benchmark, journal (prime directives 1–2).

## Quality-of-service and misc

- `--prio 2` raises process priority. Plausible when agents' compilers compete
  for CPU with the server's CPU-side work, but measured **slower** for prefill
  on gfx1151/ROCm in the one filed test (see FINDINGS.md 2026-08-28 — the
  measured deficit was partly confounded, and the residual was inside the
  machine's spread). Treat as untested: A/B it, don't assume it.
- `--jinja` + `--chat-template-file` for models whose templates matter to tool
  calling (they do, for coding agents).
- `--no-warmup` speeds restarts during tuning loops but the first request
  pays; drop it in production configs.
- Router mode (`--models-preset models.ini --models-max 1`) hot-swaps models —
  useful for a big-coder/small-utility split, but a swap evicts everything;
  for a steady agent fleet a single resident model usually wins. Example ini
  in the kyuz0 repo (`docs/models.ini.example`).

## Worked starting point (adapt, then benchmark)

128 GB machine, ~17 GiB Q4_K_XL coder model, 6 agents, 32k each:

```bash
llama-server \
  -m Qwen-coder-Q4_K_XL.gguf -ngl 999 -fa 1 --no-mmap \
  -c 196608 -np 6 -ctk q8_0 -ctv q8_0 \
  -b 2048 -ub 1024 \
  --cache-reuse 256 --metrics \
  --jinja --host 0.0.0.0 --port 8080
```

Deliberately **not** in this baseline: `ROCBLAS_USE_HIPBLASLT=1` and `--prio 2`.
Both are coin flips this file tells you to A/B, and both measured as
regressions the one time they were filed. Add them only after your own
benchmark says they help — `bench-parallel.sh -e ROCBLAS_USE_HIPBLASLT=1`
records the toggle in the run's provenance.

Then: fit check under load → `bench-parallel.sh` at `-npl 4,6,8` → ubatch
sweep → spec-decoding trial if tg-bound. Journal each step.
