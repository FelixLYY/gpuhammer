#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/overnight_2g}"
LOG_FILE="$RESULT_DIR/run.log"

MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-6}"
SCAN_RANGE_GIB="${SCAN_RANGE_GIB:-2}"
RUNS="${RUNS:-3}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-28}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"

if [[ "$MEMORY_SIZE_GIB" -le 0 || "$SCAN_RANGE_GIB" -le 0 || "$RUNS" -le 0 ]]; then
  echo "MEMORY_SIZE_GIB, SCAN_RANGE_GIB, and RUNS must all be greater than zero." >&2
  exit 1
fi

if [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniconda3/etc/profile.d/conda.sh"
elif [[ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniforge3/etc/profile.d/conda.sh"
else
  echo "Conda initialization script was not found." >&2
  exit 1
fi

conda activate rmm_dev
mkdir -p "$RESULT_DIR"
export HAMMER_ROOT

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

gpu_state() {
  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG_FILE"
}

run_scans() {
  local run
  for run in $(seq 1 "$RUNS"); do
    local output="$RESULT_DIR/CONF_SET_${THRESHOLD}_run${run}.txt"
    log "===== run=$run/$RUNS start $(date) ====="
    gpu_state

    python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
      --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
      --range $((SCAN_RANGE_GIB * 2 ** 30)) \
      --it "$ITERATIONS" \
      --step "$STEP" \
      --threshold "$THRESHOLD" \
      --trgtBankOfs "$REFERENCE_OFFSET" \
      --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
      --file "$output" \
      2>&1 | tee -a "$LOG_FILE"

    log "Accepted offsets: $(grep -c '[0-9]' "$output" || true)"
    gpu_state
    log "===== run=$run/$RUNS end $(date) ====="
  done
}

extract_common() {
  python3 - "$RESULT_DIR" "$RUNS" "$THRESHOLD" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

directory = Path(sys.argv[1])
runs = int(sys.argv[2])
threshold = sys.argv[3]
sets = []

for run in range(1, runs + 1):
    path = directory / f"CONF_SET_{threshold}_run{run}.txt"
    values = {
        int(line)
        for line in path.read_text().splitlines()
        if line.strip().isdigit()
    }
    sets.append(values)
    print(f"run {run}: {len(values)} offsets")

common = set.intersection(*sets) if sets else set()
output = directory / f"CONF_SET_{threshold}_common_all{runs}.txt"
output.write_text("\n".join(str(value) for value in sorted(common)) + "\n")
print(f"common to all {runs}: {len(common)}")
print(f"saved: {output}")
PY
}

run_row_set() {
  local input="$RESULT_DIR/CONF_SET_${THRESHOLD}_common_all${RUNS}.txt"
  local output="$RESULT_DIR/ROW_SET_${THRESHOLD}_${SCAN_RANGE_GIB}GiB.txt"

  if [[ ! -s "$input" || ! $(grep -c '^[0-9][0-9]*$' "$input") -gt 0 ]]; then
    log "Common conflict set is empty; skipping row_set."
    return
  fi

  log "===== row_set start $(date) ====="
  python3 "$HAMMER_ROOT/util/run_timing_task.py" row_set \
    --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
    --it "$ITERATIONS" \
    --threshold "$THRESHOLD" \
    --trgtBankOfs "$REFERENCE_OFFSET" \
    --max 0 \
    "$input" \
    --outputFile "$output" \
    2>&1 | tee -a "$LOG_FILE"
  log "row_set output: $output"
}

summarize() {
  python3 - "$RESULT_DIR" "$RUNS" "$THRESHOLD" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

directory = Path(sys.argv[1])
runs = int(sys.argv[2])
threshold = sys.argv[3]
row_path = directory / f"ROW_SET_{threshold}_2GiB.txt"

if row_path.exists():
    rows = [
        line.split()
        for line in row_path.read_text().splitlines()
        if line.strip()
    ]
    sizes = [len(row) for row in rows]
    print(
        f"rows={len(rows)} addresses={sum(sizes)} "
        f"min={min(sizes) if sizes else 0} "
        f"median={sorted(sizes)[len(sizes)//2] if sizes else 0} "
        f"max={max(sizes) if sizes else 0} "
        f"groups_of_8={sum(size == 8 for size in sizes)}"
    )

print(f"Finished: {__import__('datetime').datetime.now()}")
PY
}

: > "$LOG_FILE"
log "Started: $(date)"
log "Configuration: allocation=${MEMORY_SIZE_GIB}GiB scan=${SCAN_RANGE_GIB}GiB runs=${RUNS} threshold=${THRESHOLD}ns iterations=${ITERATIONS}"

run_scans
extract_common
run_row_set
summarize
