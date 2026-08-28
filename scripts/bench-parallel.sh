#!/usr/bin/env bash
# Parallel-throughput benchmark wrapper around llama-batched-bench, modelling
# the multi-agent workload: N concurrent sequences, long prompts, measured
# aggregate + per-sequence speeds. Enforces -fa 1 --no-mmap -ngl 999 and files
# results + provenance under ~/strix-optimize/results/.
#
# Usage:
#   bench-parallel.sh -m /path/model.gguf [-C toolbox-name] [-t tag]
#                     [-l npl] [-p npp] [-g ntg] [-c ctx] [-b batch] [-u ubatch]
#                     [-r reps] [-e VAR=VAL] [--force]
#                     [-- extra llama-batched-bench args]
#
# Defaults: npl=1,2,4,8  npp=2048,8192  ntg=128  batch=2048  ubatch=1024  reps=1
# ctx defaults to max(npl) * (max(npp) + ntg), rounded up — must fit in memory!
#
#   -e VAR=VAL   set an env var for the run and record it (repeatable).
#                Use this instead of hand-running the tool: it is the only way
#                the value reaches inside the toolbox AND lands in meta.txt.
#   -r N         repeat the whole sweep N times and report per-row spread.
#                Do this once per machine: deltas smaller than your spread are
#                not measurable. See references/benchmarking.md.
#
# Example:
#   bench-parallel.sh -m ~/models/q.gguf -C llama-rocm-7.14 -t agents-knee -l 2,4,6,8
#   bench-parallel.sh -m ~/models/q.gguf -C llama-rocm-7.14 -t hipblaslt \
#                     -e ROCBLAS_USE_HIPBLASLT=1

set -euo pipefail

# shellcheck source=lib-provenance.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-provenance.sh"

MODEL="" CONTAINER="" TAG="parallel"
NPL="1,2,4,8" NPP="2048,8192" NTG=128 CTX="" BATCH=2048 UBATCH=1024 REPS=1 FORCE=0
OUTROOT="$HOME/strix-optimize/results"
EXTRA=()
ENV_VARS=()

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
        -r) REPS="$2"; shift 2 ;;
        -e) ENV_VARS+=("$2"); shift 2 ;;
        -o) OUTROOT="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ -n "$MODEL" ]] || { echo "ERROR: -m MODEL is required"; usage; }
[[ -f "$MODEL" ]] || { echo "ERROR: model not found: $MODEL"; exit 1; }
if ! [[ "$REPS" =~ ^[0-9]+$ ]] || (( REPS < 1 )); then
    echo "ERROR: -r must be an integer >= 1"; exit 1
fi
for pair in ${ENV_VARS[@]+"${ENV_VARS[@]}"}; do
    [[ "$pair" == *=* ]] || { echo "ERROR: -e expects VAR=VAL, got: $pair"; exit 1; }
done

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
# env must run inside the toolbox, so it prefixes the command rather than the runner
if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    CMD=(env "${ENV_VARS[@]}" "${CMD[@]}")
fi

sho_write_meta "$OUTDIR"
sho_state_warn "$OUTROOT" "$OUTDIR"

echo "Output: $OUTDIR"
rc=0
for (( i = 1; i <= REPS; i++ )); do
    (( REPS > 1 )) && echo "Running rep $i/$REPS..." || echo "Running..."
    {
        echo ""
        echo "=== rep $i/$REPS ==="
    } >> "$OUTDIR/results.log"
    set +e
    "${RUNNER[@]+"${RUNNER[@]}"}" "${CMD[@]}" 2>&1 | tee -a "$OUTDIR/results.log"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc != 0 )); then
        echo "ERROR: run exited $rc — stopping."
        break
    fi
done

if (( rc != 0 )); then
    sho_mark_failed "$OUTDIR" "$rc"
    sho_journal_append "$OUTDIR" "exit $rc"
    exit "$rc"
fi

echo "Done. Results: $OUTDIR/results.log  Metadata: $OUTDIR/meta.txt"

if command -v python3 >/dev/null 2>&1; then
    python3 - "$OUTDIR/results.log" "$REPS" <<'PY' || true
import re, sys
from collections import defaultdict

rows = defaultdict(lambda: {"pp": [], "tg": []})
row_re = re.compile(r"^\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|" + r"[^|]*\|" * 2 +
                    r"\s*([\d.]+)\s*\|[^|]*\|\s*([\d.]+)\s*\|")
for line in open(sys.argv[1]):
    m = row_re.match(line)
    if m:
        pp, _tg, b, s_pp, s_tg = m.groups()
        rows[(int(pp), int(b))]["pp"].append(float(s_pp))
        rows[(int(pp), int(b))]["tg"].append(float(s_tg))

reps = int(sys.argv[2])
if not rows:
    sys.exit(0)

def spread(v):
    return 0.0 if len(v) < 2 or not sum(v) else (max(v) - min(v)) / (sum(v) / len(v)) * 100

print()
hdr = f"{'PP':>6} {'npl':>4} {'S_PP t/s':>10} {'S_TG t/s':>10}"
if reps > 1:
    hdr += f" {'PP spread':>10} {'TG spread':>10}"
print(hdr)
worst = 0.0
for (pp, b) in sorted(rows):
    v = rows[(pp, b)]
    mean_pp = sum(v["pp"]) / len(v["pp"])
    mean_tg = sum(v["tg"]) / len(v["tg"])
    line = f"{pp:>6} {b:>4} {mean_pp:>10.2f} {mean_tg:>10.2f}"
    if reps > 1:
        s_pp, s_tg = spread(v["pp"]), spread(v["tg"])
        worst = max(worst, s_pp, s_tg)
        line += f" {s_pp:>9.1f}% {s_tg:>9.1f}%"
    print(line)

if reps > 1:
    print()
    print(f"Worst per-row spread across {reps} reps: {worst:.1f}%")
    print(f"Treat any delta smaller than {worst:.1f}% as unproven on this machine.")
else:
    print()
    print("Single rep: no spread measured, so no delta is proven yet.")
    print("Run once with -r 3 to learn this machine's spread, then compare against it.")
PY
fi

sho_journal_append "$OUTDIR"
echo "Read: S_PP/S_TG = aggregate t/s; per-seq speed across the npl rows shows"
echo "the concurrency knee — pick -np where per-agent speed is still acceptable."
