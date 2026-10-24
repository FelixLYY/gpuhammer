#!/usr/bin/env bash
set -eo pipefail

cd /mnt/c/Users/felix/Documents/2026-Fall/CSC2237/Project/gpuhammer

source /home/felix/miniconda3/etc/profile.d/conda.sh
conda activate rmm_dev

export HAMMER_ROOT="$PWD"

RESULT_DIR="$HAMMER_ROOT/results/row_sets/overnight_512_validation"
mkdir -p "$RESULT_DIR"

LOG="$RESULT_DIR/run.log"
: > "$LOG"

for run in 1 2 3 4 5; do
  echo "===== run $run start $(date) =====" | tee -a "$LOG"

  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG"

  python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
    --size $((4 * 2 ** 30)) \
    --range $((512 * 2 ** 20)) \
    --it 15 \
    --step 256 \
    --threshold 28 \
    --trgtBankOfs 0 \
    --self-timing-tolerance 30 \
    --file "$RESULT_DIR/CONF_SET_28_run${run}.txt" \
    2>&1 | tee -a "$LOG"

  count=$(grep -c '[0-9]' \
    "$RESULT_DIR/CONF_SET_28_run${run}.txt" || true)

  echo "Accepted offsets: $count" | tee -a "$LOG"

  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG"

  echo "===== run $run end $(date) =====" | tee -a "$LOG"
done

python3 - "$RESULT_DIR" <<'PY' | tee -a "$LOG"
from pathlib import Path
import sys

directory = Path(sys.argv[1])
sets = []

for run in range(1, 6):
    path = directory / f"CONF_SET_28_run{run}.txt"
    values = {
        int(line)
        for line in path.read_text().splitlines()
        if line.strip().isdigit()
    }
    sets.append(values)
    print(f"run {run}: {len(values)} offsets")

common = set.intersection(*sets)
output = directory / "CONF_SET_28_common_all5.txt"
output.write_text("\n".join(map(str, sorted(common))) + "\n")

print(f"common to all five: {len(common)}")
print(f"saved: {output}")
PY

echo "===== conf_set phase complete $(date) =====" | tee -a "$LOG"

python3 "$HAMMER_ROOT/util/run_timing_task.py" row_set \
  --size $((4 * 2 ** 30)) \
  --it 15 \
  --threshold 28 \
  --trgtBankOfs 0 \
  --max 0 \
  "$RESULT_DIR/CONF_SET_28_common_all5.txt" \
  --outputFile "$RESULT_DIR/ROW_SET_28_common_all5.txt" \
  2>&1 | tee -a "$LOG"

echo "===== row_set phase complete $(date) =====" | tee -a "$LOG"
