#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/overnight_boundary}"
LOG_FILE="${LOG_FILE:-$RESULT_DIR/run.log}"
THRESHOLDS="${THRESHOLDS:-45 50 55}"
RUNS="${RUNS:-5}"

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

echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "thresholds=$THRESHOLDS runs=$RUNS" | tee -a "$LOG_FILE"

for threshold in $THRESHOLDS; do
  for run in $(seq 1 "$RUNS"); do
    output="$RESULT_DIR/CONF_SET_${threshold}_run${run}.txt"
    echo "===== threshold=$threshold run=$run/$RUNS start $(date) =====" \
      | tee -a "$LOG_FILE"
    nvidia-smi \
      --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
      --format=csv | tee -a "$LOG_FILE"

    python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
      --size $((1 * 2 ** 30)) \
      --range $((256 * 2 ** 20)) \
      --it 15 \
      --step 256 \
      --threshold "$threshold" \
      --trgtBankOfs 0 \
      --self-timing-tolerance 30 \
      --file "$output" \
      2>&1 | tee -a "$LOG_FILE"

    count="$(grep -c '[0-9]' "$output" || true)"
    echo "Accepted offsets: $count" | tee -a "$LOG_FILE"
    nvidia-smi \
      --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
      --format=csv | tee -a "$LOG_FILE"
    echo "===== threshold=$threshold run=$run/$RUNS end $(date) =====" \
      | tee -a "$LOG_FILE"
  done
done

python3 - "$RESULT_DIR" "$THRESHOLDS" "$RUNS" <<'PY' | tee -a "$LOG_FILE"
import sys
from collections import Counter
from pathlib import Path

result_dir = Path(sys.argv[1])
thresholds = sys.argv[2].split()
runs = int(sys.argv[3])

print("===== FINAL OVERLAP SUMMARY =====")
for threshold in thresholds:
    sets = []
    for run in range(1, runs + 1):
        path = result_dir / f"CONF_SET_{threshold}_run{run}.txt"
        values = {
            int(line)
            for line in path.read_text().splitlines()
            if line.strip().isdigit()
        }
        sets.append(values)

    print(f"threshold={threshold}")
    print("  counts=" + ", ".join(str(len(values)) for values in sets))
    appearances = Counter(value for values in sets for value in values)
    for minimum in (runs, max(1, runs - 1)):
        stable = [value for value, count in appearances.items() if count >= minimum]
        print(f"  offsets in >= {minimum}/{runs} runs: {len(stable)}")

print(f"Finished: {__import__('datetime').datetime.now()}")
PY
