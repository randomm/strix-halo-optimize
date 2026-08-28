#!/usr/bin/env bash
# Shared provenance capture, host-state guard, and journal writing for the
# bench-*.sh scripts. Sourced, not executed.
#
# Why this exists: a benchmark number is worthless without the host state it was
# taken on, and a comparison between two numbers is worthless if that state
# changed in between. Both bench scripts used to duplicate the provenance block
# and neither noticed state drift. See FINDINGS.md 2026-08-28 for the run that
# proved it.
#
# Callers set: TS, TAG, MODEL, CONTAINER, OUTDIR, OUTROOT, ENV_VARS[], RUNNER[], CMD[]

# --- host state ---------------------------------------------------------------

sho_dpm_level() {
    local f
    for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [[ -r "$f" ]] || continue
        cat "$f"
        return 0
    done
    echo "n/a"
}

sho_kernel()   { uname -r; }
sho_firmware() { rpm -q linux-firmware 2>/dev/null || echo "n/a"; }
sho_cmdline()  { cat /proc/cmdline 2>/dev/null || echo "n/a"; }

# Effective value of a var: an explicit -e wins, otherwise the ambient value.
sho_env_effective() {
    local name="$1" pair
    for pair in ${ENV_VARS[@]+"${ENV_VARS[@]}"}; do
        case "$pair" in
            "$name"=*) printf '%s\n' "${pair#*=}"; return 0 ;;
        esac
    done
    if [[ -n "${!name:-}" ]]; then printf '%s\n' "${!name}"; else echo "<unset>"; fi
}

# --- meta.txt -----------------------------------------------------------------

sho_write_meta() {
    local outdir="$1"
    {
        echo "date_utc: $TS"
        echo "tag: $TAG"
        echo "model: $MODEL"
        echo "container: ${CONTAINER:-<host PATH>}"
        echo "kernel: $(sho_kernel)"
        echo "cmdline: $(sho_cmdline)"
        echo "firmware: $(sho_firmware)"
        echo "dpm: $(sho_dpm_level)"
        if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
            echo "env: ${ENV_VARS[*]}"
        else
            echo "env: <none>"
        fi
        echo "ROCBLAS_USE_HIPBLASLT: $(sho_env_effective ROCBLAS_USE_HIPBLASLT)"
        if [[ -n "$CONTAINER" ]] && command -v podman >/dev/null 2>&1; then
            podman inspect --format 'image: {{.ImageName}} {{.Image}}' "$CONTAINER" 2>/dev/null || true
        fi
        printf 'command:'
        printf ' %q' ${RUNNER[@]+"${RUNNER[@]}"} "${CMD[@]}"
        printf '\n'
    } > "$outdir/meta.txt"
}

# --- host-state guard ---------------------------------------------------------
# Compares host state against the most recent previous run and warns on drift.
# Deliberately ignores container/image: that is the variable you are usually
# testing. Kernel, firmware, boot cmdline and GPU power state are not — if any
# changed, the older numbers are not a valid baseline.

sho_state_warn() {
    local outroot="$1" outdir="$2"
    local prev field old new drift=0

    # On the first run there is nothing to compare against, and grep exits 1 when
    # it filters everything out — which under `set -e -o pipefail` would abort
    # the whole benchmark. Swallow that.
    prev=$(find "$outroot" -mindepth 2 -maxdepth 2 -name meta.txt 2>/dev/null \
           | grep -v "^$outdir/" | sort | tail -1 || true)
    [[ -n "$prev" ]] || return 0

    for field in kernel firmware cmdline dpm; do
        old=$(grep -m1 "^$field: " "$prev" 2>/dev/null | cut -d' ' -f2-)
        new=$(grep -m1 "^$field: " "$outdir/meta.txt" 2>/dev/null | cut -d' ' -f2-)
        # A previous run from before this field was recorded tells us nothing.
        [[ -n "$old" ]] || continue
        if [[ "$old" != "$new" ]]; then
            if (( drift == 0 )); then
                echo ""
                echo "############################################################"
                echo "## HOST STATE CHANGED since $(dirname "$prev" | xargs basename)"
                drift=1
            fi
            echo "##   $field:"
            echo "##     was: $old"
            echo "##     now: $new"
        fi
    done

    if (( drift )); then
        echo "##"
        echo "## Earlier results are NOT a valid baseline for this run."
        echo "## Re-measure the baseline under current state before trusting"
        echo "## any delta. See references/benchmarking.md."
        echo "############################################################"
        echo ""
    fi
}

# --- failure marking ----------------------------------------------------------
# The results dir and meta.txt are written before the workload starts, so a
# crashed run otherwise leaves a directory indistinguishable from a good one.

sho_mark_failed() {
    local outdir="$1" code="${2:-?}"
    echo "run exited $code — results in this directory are incomplete or invalid" \
        > "$outdir/FAILED"
    echo "MARKED FAILED: $outdir/FAILED"
}

# --- journal ------------------------------------------------------------------
# The skill mandates a journal; prose reminders did not produce one across seven
# runs, so the script writes the entry itself. Newest entry on top, per SKILL.md.

sho_journal_append() {
    local outdir="$1" status="${2:-ok}" journal="$HOME/strix-optimize/journal.md"
    local date_h entry tmp
    date_h=$(date -u +%Y-%m-%d)

    entry="## $date_h — $TAG, ${CONTAINER:-host}, $(basename "$MODEL")
Change: TODO — what varied vs the previous run? (one variable at a time)
Result: TODO — numbers from results$([[ "$status" != "ok" ]] && echo " (RUN FAILED: $status)")
Decision: TODO — keep or revert
Files: $outdir
Rollback: TODO — exact command/flag to undo this
Current config: kernel $(sho_kernel) / firmware $(sho_firmware) / dpm $(sho_dpm_level) / container ${CONTAINER:-host}
"

    mkdir -p "$(dirname "$journal")"
    if [[ -f "$journal" ]]; then
        tmp="$journal.tmp.$$"
        { printf '%s\n' "$entry"; cat "$journal"; } > "$tmp" && mv "$tmp" "$journal"
    else
        { echo "# Strix Halo optimization journal"; echo ""; printf '%s\n' "$entry"; } > "$journal"
    fi
    echo "Journal entry prepended: $journal  (fill in the TODO lines)"
}
