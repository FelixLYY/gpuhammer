#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/repeatability}"
MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-1}"
SCAN_RANGE_MIB="${SCAN_RANGE_MIB:-256}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"
THRESHOLDS="${THRESHOLDS:-35 40 45 50 55}"
RUNS="${RUNS:-5}"

usage() {
  cat <<EOF
Usage: $(basename "$0") {run|analyze}

Defaults:
  THRESHOLDS="$THRESHOLDS"
  RUNS=$RUNS
  MEMORY_SIZE_GIB=$MEMORY_SIZE_GIB
  SCAN_RANGE_MIB=$SCAN_RANGE_MIB
  ITERATIONS=$ITERATIONS
  STEP=$STEP
  SELF_TIMING_TOLERANCE=$SELF_TIMING_TOLERANCE
  REFERENCE_OFFSET=$REFERENCE_OFFSET
  RESULT_DIR=$RESULT_DIR
EOF
}

activate_environment() {
  if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
  elif [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
    source "$HOME/miniconda3/etc/profile.d/conda.sh"
  elif [[ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]]; then
    source "$HOME/miniforge3/etc/profile.d/conda.sh"
  else
    echo "Conda was not found." >&2
    return 1
  fi
  conda activate rmm_dev
}

run_tests() {
  activate_environment
  mkdir -p "$RESULT_DIR"
  export HAMMER_ROOT

  for threshold in $THRESHOLDS; do
    for run in $(seq 1 "$RUNS"); do
      output="$RESULT_DIR/CONF_SET_${threshold}_run${run}.txt"
      echo "===== threshold=$threshold run=$run/$RUNS started: $(date) ====="
      python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
        --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
        --range $((SCAN_RANGE_MIB * 2 ** 20)) \
        --it "$ITERATIONS" \
        --step "$STEP" \
        --threshold "$threshold" \
        --trgtBankOfs "$REFERENCE_OFFSET" \
        --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
        --file "$output"
      count="$(grep -c '[0-9]' "$output" || true)"
      echo "Accepted offsets: $count"
      echo "===== threshold=$threshold run=$run/$RUNS finished: $(date) ====="
    done
  done
}

analyze_results() {
  RESULT_DIR="$RESULT_DIR" THRESHOLDS="$THRESHOLDS" RUNS="$RUNS" python3 - <<'PY'
import os
from collections import Counter
from pathlib import Path

result_dir = Path(os.environ["RESULT_DIR"])
thresholds = os.environ["THRESHOLDS"].split()
runs = int(os.environ["RUNS"])

for threshold in thresholds:
    sets = []
    for run in range(1, runs + 1):
        path = result_dir / f"CONF_SET_{threshold}_run{run}.txt"
        if not path.exists():
            continue
        values = {
            int(line)
            for line in path.read_text().splitlines()
            if line.strip().isdigit()
        }
        sets.append(values)

    print(f"threshold={threshold}")
    if not sets:
        print("  no result files found")
        continue

    print("  counts=" + ", ".join(str(len(values)) for values in sets))
    for left in range(len(sets)):
        for right in range(left + 1, len(sets)):
            common = sets[left] & sets[right]
            union = sets[left] | sets[right]
            jaccard = len(common) / len(union) if union else 0.0
            print(
                f"  runs {left + 1}/{right + 1}: "
                f"common={len(common)} union={len(union)} "
                f"Jaccard={jaccard:.4f}"
            )

    appearances = Counter(value for values in sets for value in values)
    for minimum in (len(sets), max(1, len(sets) - 1)):
        stable = sorted(value for value, count in appearances.items() if count >= minimum)
        print(
            f"  offsets in >= {minimum}/{len(sets)} runs: {len(stable)}"
        )
        if stable:
            print("  first offsets: " + ", ".join(map(str, stable[:20])))
PY
}

case "${1:-}" in
  run) run_tests ;;
  analyze) analyze_results ;;
  *) usage; exit 2 ;;
esac
