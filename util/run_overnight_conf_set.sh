#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_DIR="${RESULT_DIR:-$HAMMER_ROOT/results/row_sets/overnight}"
LOG_DIR="${LOG_DIR:-$HAMMER_ROOT/results/logs}"
PID_FILE="${PID_FILE:-$LOG_DIR/overnight_conf_set.pid}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/overnight_conf_set.log}"

MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-1}"
SCAN_RANGE_MIB="${SCAN_RANGE_MIB:-256}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"
THRESHOLDS="${THRESHOLDS:-35 40 45}"
RUNS="${RUNS:-5}"

usage() {
  cat <<EOF
Usage: $(basename "$0") {start|stop|status}

Environment overrides:
  MEMORY_SIZE_GIB=$MEMORY_SIZE_GIB
  SCAN_RANGE_MIB=$SCAN_RANGE_MIB
  ITERATIONS=$ITERATIONS
  STEP=$STEP
  SELF_TIMING_TOLERANCE=$SELF_TIMING_TOLERANCE
  REFERENCE_OFFSET=$REFERENCE_OFFSET
  THRESHOLDS="$THRESHOLDS"
  RUNS=$RUNS
EOF
}

read_pid() {
  if [[ -f "$PID_FILE" ]]; then
    tr -d '[:space:]' < "$PID_FILE"
  fi
}

is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

start_job() {
  mkdir -p "$RESULT_DIR" "$LOG_DIR"

  local existing_pid
  existing_pid="$(read_pid || true)"
  if [[ -n "$existing_pid" ]] && is_running "$existing_pid"; then
    echo "Already running with PID $existing_pid"
    echo "Log: $LOG_FILE"
    exit 1
  fi
  rm -f "$PID_FILE"

  nohup bash -c '
    set -eo pipefail

    if command -v conda >/dev/null 2>&1; then
      eval "$(conda shell.bash hook)"
    elif [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
      source "$HOME/miniconda3/etc/profile.d/conda.sh"
    elif [[ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]]; then
      source "$HOME/miniforge3/etc/profile.d/conda.sh"
    else
      echo "Conda was not found." >&2
      exit 1
    fi
    conda activate rmm_dev

    cd "$1"
    export HAMMER_ROOT="$1"

    echo "Started: $(date)"
    echo "GPU configuration:"
    nvidia-smi --query-gpu=name,clocks.current.graphics,clocks.current.memory,temperature.gpu,pstate --format=csv

    for threshold in $2; do
      for run in $(seq 1 "$3"); do
        output="$4/CONF_SET_${threshold}_run${run}.txt"
        echo
        echo "===== threshold=$threshold run=$run started: $(date) ====="
        nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory,temperature.gpu,pstate --format=csv

        python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
          --size $(( $5 * 2 ** 30 )) \
          --range $(( $6 * 2 ** 20 )) \
          --it "$7" \
          --step "$8" \
          --threshold "$threshold" \
          --trgtBankOfs "$9" \
          --self-timing-tolerance "${10}" \
          --file "$output"

        count="$(grep -c "[0-9]" "$output" || true)"
        echo "Accepted offsets: $count"
        echo "===== threshold=$threshold run=$run finished: $(date) ====="
      done
    done

    echo
    echo "===== FINAL SUMMARY ====="
    for threshold in $2; do
      for file in "$4"/CONF_SET_${threshold}_run*.txt; do
        [[ -f "$file" ]] || continue
        printf "%s: " "$file"
        grep -c "[0-9]" "$file" || true
      done
    done
    echo "Finished: $(date)"
  ' bash "$HAMMER_ROOT" "$THRESHOLDS" "$RUNS" "$RESULT_DIR" \
    "$MEMORY_SIZE_GIB" "$SCAN_RANGE_MIB" "$ITERATIONS" "$STEP" \
    "$REFERENCE_OFFSET" "$SELF_TIMING_TOLERANCE" \
    >> "$LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Started overnight conf_set job with PID $pid"
  echo "Log: $LOG_FILE"
  echo "Results: $RESULT_DIR"
}

stop_job() {
  local pid
  pid="$(read_pid || true)"
  if [[ -z "$pid" ]] || ! is_running "$pid"; then
    echo "No running job found."
    rm -f "$PID_FILE"
    return
  fi

  kill -TERM "$pid"
  for _ in 1 2 3 4 5; do
    sleep 1
    is_running "$pid" || break
  done

  if is_running "$pid"; then
    kill -KILL "$pid"
  fi
  rm -f "$PID_FILE"
  echo "Stopped job PID $pid"
}

status_job() {
  local pid
  pid="$(read_pid || true)"
  if [[ -n "$pid" ]] && is_running "$pid"; then
    echo "Running: PID $pid"
    echo "Log: $LOG_FILE"
    tail -n 20 "$LOG_FILE" 2>/dev/null || true
  else
    echo "Not running"
    [[ -f "$LOG_FILE" ]] && echo "Last log: $LOG_FILE"
  fi
}

case "${1:-}" in
  start) start_job ;;
  stop) stop_job ;;
  status) status_job ;;
  *) usage; exit 2 ;;
esac
