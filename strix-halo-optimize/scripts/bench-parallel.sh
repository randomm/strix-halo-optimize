#!/usr/bin/env bash
# Parallel-throughput benchmark wrapper around llama-batched-bench, modelling
# the multi-agent workload: N concurrent sequences, long prompts, measured
# aggregate + per-sequence speeds. Enforces -fa 1 --no-mmap -ngl 999 and files
# results + provenance under ~/strix-optimize/results/.
#
# Usage:
#   bench-parallel.sh -m /path/model.gguf [-C toolbox-name] [-t tag]
#                     [-l npl] [-p npp] [-g ntg] [-c ctx] [-b batch] [-u ubatch]
#                     [--force] [-- extra llama-batched-bench args]
#
# Defaults: npl=1,2,4,8  npp=2048,8192  ntg=128  batch=2048  ubatch=1024
# ctx defaults to max(npl) * (max(npp) + ntg), rounded up — must fit in memory!
#
# Example:
#   bench-parallel.sh -m ~/models/q.gguf -C llama-rocm-7.14 -t agents-knee -l 2,4,6,8

set -euo pipefail

MODEL="" CONTAINER="" TAG="parallel"
NPL="1,2,4,8" NPP="2048,8192" NTG=128 CTX="" BATCH=2048 UBATCH=1024 FORCE=0
OUTROOT="$HOME/strix-optimize/results"
EXTRA=()

usage() { tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) MODEL="$2"; shift 2 ;;
        -C) CONTAINER="$2"; shift 2 ;;
        -t) TAG="$2"; shift 2 ;;
        -l) NPL="$2"; shift 2 ;;
        -p) NPP="$2"; shift 2 ;;
        -g) NTG="$2"; shift 2 ;;
        -c) CTX="$2"; shift 2 ;;
        -b) BATCH="$2"; shift 2 ;;
        -u) UBATCH="$2"; shift 2 ;;
        -o) OUTROOT="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ -n "$MODEL" ]] || { echo "ERROR: -m MODEL is required"; usage; }
[[ -f "$MODEL" ]] || { echo "ERROR: model not found: $MODEL"; exit 1; }

if (( ! FORCE )) && pgrep -f 'llama-server' >/dev/null 2>&1; then
    echo "ERROR: llama-server is running. Stop it first (or --force)."
    exit 1
fi

if [[ -z "$CTX" ]]; then
    max_npl=$(tr ',' '\n' <<<"$NPL" | sort -n | tail -1)
    max_npp=$(tr ',' '\n' <<<"$NPP" | sort -n | tail -1)
    CTX=$(( max_npl * (max_npp + NTG) ))
    # round up to a multiple of 4096
    CTX=$(( (CTX + 4095) / 4096 * 4096 ))
    echo "ctx auto-sized: $CTX (= max_npl * (max_npp + ntg), rounded). Check it fits!"
fi

RUNNER=()
if [[ -n "$CONTAINER" ]]; then
    RUNNER=(toolbox run --container "$CONTAINER")
elif ! command -v llama-batched-bench >/dev/null 2>&1; then
    echo "ERROR: llama-batched-bench not in PATH and no -C toolbox given."
    exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="$OUTROOT/$TS-$TAG"
mkdir -p "$OUTDIR"

CMD=(llama-batched-bench -m "$MODEL" -fa 1 --no-mmap -ngl 999
     -c "$CTX" -b "$BATCH" -ub "$UBATCH"
     -npp "$NPP" -ntg "$NTG" -npl "$NPL")
CMD+=("${EXTRA[@]+"${EXTRA[@]}"}")

{
    echo "date_utc: $TS"
    echo "tag: $TAG"
    echo "model: $MODEL"
    echo "container: ${CONTAINER:-<host PATH>}"
    echo "kernel: $(uname -r)"
    echo "cmdline: $(cat /proc/cmdline)"
    echo "firmware: $(rpm -q linux-firmware 2>/dev/null || echo n/a)"
    echo "ROCBLAS_USE_HIPBLASLT: ${ROCBLAS_USE_HIPBLASLT:-<unset>}"
    if [[ -n "$CONTAINER" ]] && command -v podman >/dev/null 2>&1; then
        podman inspect --format 'image: {{.ImageName}} {{.Image}}' "$CONTAINER" 2>/dev/null || true
    fi
    printf 'command:'; printf ' %q' "${RUNNER[@]+"${RUNNER[@]}"}" "${CMD[@]}"; printf '\n'
} > "$OUTDIR/meta.txt"

echo "Output: $OUTDIR"
echo "Running..."
"${RUNNER[@]+"${RUNNER[@]}"}" "${CMD[@]}" 2>&1 | tee "$OUTDIR/results.log"

echo "Done. Results: $OUTDIR/results.log  Metadata: $OUTDIR/meta.txt"
echo "Read: S_PP/S_TG = aggregate t/s; per-seq speed across the npl rows shows"
echo "the concurrency knee — pick -np where per-agent speed is still acceptable."
echo "Remember: journal this run (~/strix-optimize/journal.md)."
