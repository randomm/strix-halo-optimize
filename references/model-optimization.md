# Model Selection, Quantization, Memory Fit, and Unsloth on AMD

Model choice dominates every tuning layer below it: no flag recovers the 3×
between a dense 70B and a comparable-quality MoE on bandwidth-bound
generation. Work this layer first when the user is open to it.

## What runs well on this hardware (structural, slow-rotting)

- **MoE models are the sweet spot for tg**: generation touches only active
  parameters, so a 30B-A3B class model generates like a ~3B while 128 GB
  unified memory comfortably holds total weights that would need multi-GPU
  elsewhere. For parallel agents (bandwidth shared across slots), this
  advantage compounds.
- **Dense large models fit but generate slowly** — bandwidth ÷ weight-bytes is
  the ceiling; fitting ≠ fast.
- **Long context shifts the balance**: at 32k+ per slot, KV reads join the
  per-token bandwidth bill and attention joins the compute bill, so weight
  quant matters relatively less and KV quant/FA path matters more.
- **MTP / draft-friendly variants**: code has high speculation acceptance;
  a model family with an MTP head (or a small same-family draft model) is a
  real selection criterion for the agent profile.

## Quantization selection

- Community consensus starting point for coding: Unsloth dynamic quants
  (UD-Q4_K_XL class) balance quality/size well; Q8_0 when quality paranoia
  wins and memory allows; below ~4-bit, code quality degrades fastest of all
  task types — validate on the user's actual agent tasks, not perplexity.
- Bigger quant = more bytes/token = slower tg, but also fewer requant
  artifacts; there is no universal answer — benchmark tg at target depth and
  eyeball agent output quality.
- ROCmFPX toolboxes add FP3–FP8/I4 weight formats (experimental; measure).

## Fit math (do this before every download)

Use the estimator from the kyuz0 repo (`tools/gguf-vram-estimator.py`):

```bash
gguf-vram-estimator.py model.gguf --contexts 32768 131072 262144
```

It reads GGUF metadata (handles multi-shard) and reports weights + KV + typical
overhead per context size. For serving: use *total* context (`-c`, all slots
summed), then add compute buffers (grows with `-ub`) and leave host headroom
(see kernel-and-memory.md — the agents' own toolchain runs on the same RAM).
Ceiling on a 128 GB machine with standard params: ~124 GiB GPU-mappable, and
practically less under a working OS. Verify post-launch:
`cat /sys/class/drm/card*/device/mem_info_gtt_used` under full load.

Multi-shard GGUFs: all shards must sit in one directory; point llama.cpp at
shard 00001.

## Downloading

```bash
HF_XET_HIGH_PERFORMANCE=1 hf download <repo> <file> --local-dir models/<name>/
```

Set `HF_TOKEN` for gated/faster downloads. Keep models on fast local storage;
`--no-mmap` means full load into memory at startup, so disk speed sets restart
time, not inference speed.

## Unsloth on AMD (fine-tuning / model tinkering)

Status (2026-08, moving fast — verify at unsloth.ai/docs/basics/amd before
each campaign): Unsloth officially supports AMD including **gfx1151 (Strix
Halo) listed as fully supported**. Unsloth Studio (the UI) and notebooks work
on Linux; LoRA, QLoRA, full FT, and RL are supported; claimed ~2× speed / ~70%
less VRAM vs baseline. The unified 128 GB is the superpower: fine-tunes that
OOM a 24 GB card (e.g. full-FT of ~12B, LoRA of 27B+) fit on this machine —
the tradeoff is bandwidth, so expect long wall-clock times.

Ground rules learned from community failure reports:

1. **Separate environment, never the serving stack.** Training uses PyTorch +
   TheRock gfx1151 nightlies (`rocm.nightlies.amd.com/v2/gfx1151/`) — install
   torch/torchvision/torchaudio *only* from that index in a dedicated venv or
   container; mixing PyTorch.org ROCm wheels with TheRock packages in one env
   breaks. Studio installs via `curl -fsSL https://unsloth.ai/install.sh | sh`.
2. **Hard gate before any long run:**
   `python -c "import torch; print(torch.tensor([1.0], device='cuda'))"`
   must succeed (exit 0, not segfault), then a 10-step smoke fine-tune
   watching for the known gfx1151 failure class: **NaN loss from step 1**
   (forward-pass NaNs, reported on several model families). NaNs at step 1 =
   stack problem (try a different model family, different torch nightly, or
   check unsloth GitHub issues for the model) — not a hyperparameter problem.
3. **bitsandbytes on ROCm is version-sensitive** (special wheels / build-time
   `BNB_ROCM_VERSION` pinning documented in unsloth's AMD install page). If
   QLoRA imports crash, this is suspect #1.
4. **Training competes with serving for the same physical memory.** Stop the
   agent fleet before training, or cap one of them; the OOM killer does not
   negotiate.
5. **Close the loop**: fine-tune → export GGUF (unsloth supports direct GGUF
   export) → quantize → fit-check with the estimator → benchmark with
   `bench-sweep.sh` → serve. A fine-tune that wins on quality but drops tg 20%
   (bigger quant needed, etc.) should be an explicit tradeoff decision.

Useful deep references when things break: unsloth's AMD docs and GitHub
issues; community Strix-Halo fine-tuning guides (search per
research-sources.md — several maintain patch lists for gfx1151 training
stacks, e.g. bitsandbytes builds, flash-attention alternatives, and
Studio-on-ROCm install fixes).

## Model-level experiments worth journaling

- Same model, two quants, tg + quality on 3 real agent tasks.
- Dense vs MoE at equal "quality feel" for the user's languages/frameworks.
- MTP/spec on vs off at production `-np`.
- A fine-tuned small model vs a prompted big model for a recurring agent role
  (the classic Unsloth-on-this-box payoff).
