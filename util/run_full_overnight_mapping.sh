#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/full_overnight}"
LOG_FILE="$RESULT_DIR/run.log"

MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-4}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-28}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"
RUNS_512="${RUNS_512:-5}"
RUNS_1024="${RUNS_1024:-3}"
RUN_ROW_SET="${RUN_ROW_SET:-1}"

if [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniconda3/etc/profile.d/conda.sh"
elif [[ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniforge3/etc/profile.d/conda.sh"
else
  echo "Conda initialization script was not found." >&2
  exit 1
fi

conda activate rmm_dev
mkdir -p "$RESULT_DIR/512MiB" "$RESULT_DIR/1024MiB" "$RESULT_DIR/row_mapping"
export HAMMER_ROOT

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

gpu_state() {
  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG_FILE"
}

run_conf_sets() {
  local range_mib="$1"
  local runs="$2"
  local output_dir="$RESULT_DIR/${range_mib}MiB"
  local run

  log "===== conf_set phase: range=${range_mib}MiB runs=${runs} ====="
  for run in $(seq 1 "$runs"); do
    local output="$output_dir/CONF_SET_${THRESHOLD}_run${run}.txt"
    log "===== range=${range_mib}MiB run=${run}/${runs} start $(date) ====="
    gpu_state

    python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
      --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
      --range $((range_mib * 2 ** 20)) \
      --it "$ITERATIONS" \
      --step "$STEP" \
      --threshold "$THRESHOLD" \
      --trgtBankOfs "$REFERENCE_OFFSET" \
      --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
      --file "$output" \
      2>&1 | tee -a "$LOG_FILE"

    local count
    count="$(grep -c '[0-9]' "$output" || true)"
    log "Accepted offsets: $count"
    gpu_state
    log "===== range=${range_mib}MiB run=${run}/${runs} end $(date) ====="
  done
}

extract_common_for_threshold() {
  local range_mib="$1"
  local runs="$2"
  local input_dir="$RESULT_DIR/${range_mib}MiB"
  local output="$input_dir/CONF_SET_${THRESHOLD}_common_all${runs}.txt"

  python3 - "$input_dir" "$output" "$runs" "$THRESHOLD" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

input_dir = Path(sys.argv[1])
output = Path(sys.argv[2])
runs = int(sys.argv[3])
threshold = sys.argv[4]
sets = []

for run in range(1, runs + 1):
    path = input_dir / f"CONF_SET_{threshold}_run{run}.txt"
    values = {
        int(line)
        for line in path.read_text().splitlines()
        if line.strip().isdigit()
    }
    sets.append(values)

common = set.intersection(*sets) if sets else set()
output.write_text("\n".join(str(value) for value in sorted(common)) + "\n")
print(f"common offsets: {len(common)}")
print(f"saved: {output}")
PY
}

run_row_mapping() {
  local range_mib="$1"
  local runs="$2"
  local input="$RESULT_DIR/${range_mib}MiB/CONF_SET_${THRESHOLD}_common_all${runs}.txt"
  local output="$RESULT_DIR/row_mapping/ROW_SET_${THRESHOLD}_${range_mib}MiB_all${runs}.txt"

  if [[ "$RUN_ROW_SET" != "1" ]]; then
    log "Skipping row_set because RUN_ROW_SET=$RUN_ROW_SET"
    return
  fi

  if [[ ! -s "$input" ]]; then
    log "Skipping row_set because input is empty: $input"
    return
  fi

  log "===== row_set phase: range=${range_mib}MiB runs=${runs} ====="
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

write_summary() {
  python3 - "$RESULT_DIR" "$THRESHOLD" "$RUNS_512" "$RUNS_1024" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

root = Path(sys.argv[1])
threshold = sys.argv[2]
groups = ((512, int(sys.argv[3])), (1024, int(sys.argv[4])))

print("===== FINAL SUMMARY =====")
for range_mib, runs in groups:
    directory = root / f"{range_mib}MiB"
    counts = []
    for run in range(1, runs + 1):
        path = directory / f"CONF_SET_{threshold}_run{run}.txt"
        values = {
            int(line)
            for line in path.read_text().splitlines()
            if line.strip().isdigit()
        }
        counts.append(len(values))

    common = directory / f"CONF_SET_{threshold}_common_all{runs}.txt"
    common_count = sum(
        1 for line in common.read_text().splitlines() if line.strip().isdigit()
    ) if common.exists() else 0
    print(f"{range_mib}MiB counts: {counts}")
    print(f"{range_mib}MiB common to all {runs}: {common_count}")

    row_path = root / "row_mapping" / f"ROW_SET_{threshold}_{range_mib}MiB_all{runs}.txt"
    if row_path.exists():
        rows = [
            line.split()
            for line in row_path.read_text().splitlines()
            if line.strip()
        ]
        sizes = [len(row) for row in rows]
        print(
            f"{range_mib}MiB rows={len(rows)} addresses={sum(sizes)} "
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
log "Configuration: memory=${MEMORY_SIZE_GIB}GiB threshold=${THRESHOLD}ns iterations=${ITERATIONS} step=${STEP}"

run_conf_sets 512 "$RUNS_512"
extract_common_for_threshold 512 "$RUNS_512"
run_row_mapping 512 "$RUNS_512"

run_conf_sets 1024 "$RUNS_1024"
extract_common_for_threshold 1024 "$RUNS_1024"
run_row_mapping 1024 "$RUNS_1024"

write_summary
