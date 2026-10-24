#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/one_hour_test}"
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

LOG_FILE="$RESULT_DIR/run.log"
: > "$LOG_FILE"

echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "Runs: $RUNS, threshold: 50 ns" | tee -a "$LOG_FILE"

for run in $(seq 1 "$RUNS"); do
  output="$RESULT_DIR/CONF_SET_50_run${run}.txt"

  echo "===== RUN $run/$RUNS START $(date) =====" | tee -a "$LOG_FILE"
  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG_FILE"

  python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
    --size $((1 * 2 ** 30)) \
    --range $((256 * 2 ** 20)) \
    --it 15 \
    --step 256 \
    --threshold 50 \
    --trgtBankOfs 0 \
    --self-timing-tolerance 30 \
    --file "$output" \
    2>&1 | tee -a "$LOG_FILE"

  count="$(grep -c '[0-9]' "$output" || true)"
  echo "Accepted offsets: $count" | tee -a "$LOG_FILE"

  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv | tee -a "$LOG_FILE"
  echo "===== RUN $run/$RUNS END $(date) =====" | tee -a "$LOG_FILE"
done

python3 - "$RESULT_DIR" "$RUNS" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

directory = Path(sys.argv[1])
runs = int(sys.argv[2])
sets = []

print("===== OVERLAP SUMMARY =====")
for run in range(1, runs + 1):
    path = directory / f"CONF_SET_50_run{run}.txt"
    values = {
        int(line.strip())
        for line in path.read_text().splitlines()
        if line.strip().isdigit()
    }
    sets.append(values)
    print(f"run {run}: {len(values)} offsets")

for left in range(runs):
    for right in range(left + 1, runs):
        common = sets[left] & sets[right]
        union = sets[left] | sets[right]
        jaccard = len(common) / len(union) if union else 0.0
        print(
            f"runs {left + 1}/{right + 1}: "
            f"common={len(common)} union={len(union)} "
            f"Jaccard={jaccard:.4f}"
        )

common_all = set.intersection(*sets) if sets else set()
stable = directory / "CONF_SET_50_common_all.txt"
stable.write_text("\n".join(str(value) for value in sorted(common_all)) + "\n")

print(f"common to all {runs}: {len(common_all)}")
print(f"stable set saved to: {stable}")
print(f"Finished: {__import__('datetime').datetime.now()}")
PY
