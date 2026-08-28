#!/usr/bin/env bash
# Depth-sweep benchmark wrapper around llama-bench for Strix Halo.
# Enforces the non-negotiable flags (-fa 1 --mmap 0 -ngl 999), files JSON
# results + provenance metadata under ~/strix-optimize/results/.
#
# Usage:
#   bench-sweep.sh -m /path/model.gguf [-C toolbox-name] [-t tag]
#                  [-d depths] [-u ubatches] [-r reps] [-o outdir] [--force]
#                  [-- extra llama-bench args passed through verbatim]
#
# Examples:
#   bench-sweep.sh -m ~/models/q.gguf -C llama-rocm-7.14 -t rocm714-baseline
#   bench-sweep.sh -m ~/models/q.gguf -C llama-vulkan-radv -u 256,512,1024,2048 -t radv-ubsweep

set -euo pipefail

MODEL="" CONTAINER="" TAG="run"
DEPTHS="0,8192,16384,32768,65536"
UBATCH="" REPS=3 FORCE=0
OUTROOT="$HOME/strix-optimize/results"
EXTRA=()

usage() { tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) MODEL="$2"; shift 2 ;;
        -C) CONTAINER="$2"; shift 2 ;;
        -t) TAG="$2"; shift 2 ;;
        -d) DEPTHS="$2"; shift 2 ;;
        -u) UBATCH="$2"; shift 2 ;;
        -r) REPS="$2"; shift 2 ;;
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
    echo "ERROR: llama-server is running. Concurrent GPU workloads corrupt benchmarks."
    echo "Stop it, or pass --force if you know what you're doing."
    exit 1
fi

RUNNER=()
if [[ -n "$CONTAINER" ]]; then
    RUNNER=(toolbox run --container "$CONTAINER")
elif ! command -v llama-bench >/dev/null 2>&1; then
    echo "ERROR: llama-bench not in PATH and no -C toolbox given."
    echo "Hint: -C llama-rocm-7.14  (see: toolbox list)"
    exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="$OUTROOT/$TS-$TAG"
mkdir -p "$OUTDIR"

CMD=(llama-bench -m "$MODEL" -fa 1 --mmap 0 -ngl 999
     -d "$DEPTHS" -p 2048 -n 128 -r "$REPS" -o json)
[[ -n "$UBATCH" ]] && CMD+=(-ub "$UBATCH")
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
echo "Running (this can take a long time at high depths)..."
"${RUNNER[@]+"${RUNNER[@]}"}" "${CMD[@]}" > "$OUTDIR/results.json" 2> >(tee "$OUTDIR/stderr.log" >&2)

echo "Done. Results: $OUTDIR/results.json  Metadata: $OUTDIR/meta.txt"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$OUTDIR/results.json" <<'PY' || true
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"(summary skipped: {e})")
print(f"{'test':>10} {'depth':>7} {'ub':>5} {'t/s':>10} {'±':>7}")
for r in rows:
    name = r.get("test", "?")
    print(f"{name:>10} {r.get('n_depth', 0):>7} {r.get('n_ubatch', ''):>5} "
          f"{r.get('avg_ts', 0):>10.2f} {r.get('stddev_ts', 0):>7.2f}")
PY
fi
echo "Remember: journal this run (~/strix-optimize/journal.md)."
