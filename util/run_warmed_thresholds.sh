#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/warmed_thresholds}"
THRESHOLDS="${THRESHOLDS:-50 75 100 125}"
RUNS="${RUNS:-3}"

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

log="$RESULT_DIR/run.log"
nvidia-smi \
  --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
  --format=csv | tee -a "$log"

for threshold in $THRESHOLDS; do
  for run in $(seq 1 "$RUNS"); do
    echo "===== threshold=$threshold run=$run/$RUNS start $(date) =====" \
      | tee -a "$log"
    nvidia-smi \
      --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
      --format=csv | tee -a "$log"

    python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
      --size $((1 * 2 ** 30)) \
      --range $((256 * 2 ** 20)) \
      --it 15 \
      --step 256 \
      --threshold "$threshold" \
      --trgtBankOfs 0 \
      --self-timing-tolerance 30 \
      --file "$RESULT_DIR/CONF_SET_${threshold}_run${run}.txt" \
      2>&1 | tee -a "$log"

    nvidia-smi \
      --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
      --format=csv | tee -a "$log"
    echo "===== threshold=$threshold run=$run/$RUNS end $(date) =====" \
      | tee -a "$log"
  done
done
