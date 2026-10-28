#!/usr/bin/env bash
# Runs conf_set scans over increasing ranges, keeping only scans whose
# baseline delay stays inside a fixed window. Rejected scans are retried.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_ROOT="${RESULT_ROOT:-$HAMMER_ROOT/results/guarded_mapping}"
LOG_FILE="$RESULT_ROOT/run.log"

RANGES="${RANGES:-1 2 3}"
MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-4}"
TARGET_RUNS="${TARGET_RUNS:-3}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"
DEADLINE_HOURS="${DEADLINE_HOURS:-9}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-24}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"
MIN_BASE_DELAY="${MIN_BASE_DELAY:-0}"
MAX_BASE_DELAY="${MAX_BASE_DELAY:-0}"
CANARY_BYTES="${CANARY_BYTES:-134217728}"
MIN_REF_JACCARD="${MIN_REF_JACCARD:-0.80}"
RETRY_SLEEP="${RETRY_SLEEP:-60}"
REFERENCE_SET="${REFERENCE_SET:-$HAMMER_ROOT/results/threshold24_1g_validation/CONF_SET_24_common_all3.txt}"

if [[ ! -s "$REFERENCE_SET" ]]; then
  echo "Reference set not found: $REFERENCE_SET" >&2
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

mkdir -p "$RESULT_ROOT"
export HAMMER_ROOT
START_EPOCH="$(date +%s)"
DEADLINE_EPOCH=$((START_EPOCH + DEADLINE_HOURS * 3600))

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

gpu_state() {
  nvidia-smi \
    --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu \
    --format=csv,noheader | tee -a "$LOG_FILE"
}

# Agreement with the validated reference map, restricted to the scanned region.
reference_check() {
  local scan_file="$1" range_bytes="$2"
  python3 - "$scan_file" "$range_bytes" "$REFERENCE_SET" "$MIN_REF_JACCARD" <<'PY' | tee -a "$LOG_FILE"
import sys
from pathlib import Path

scan, range_bytes, reference, minimum = (
    Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3]), float(sys.argv[4]))
limit = min(range_bytes, 2**30)

def load(path):
    return {int(x) for x in path.read_text().split() if x.isdigit()}

found = {v for v in load(scan) if v < limit}
ref = {v for v in load(reference) if v < limit}
union = len(found | ref)
jaccard = len(found & ref) / union if union else 0.0
verdict = "PASS" if jaccard >= minimum else "FAIL"
print(f"reference check: found={len(found)} reference={len(ref)} "
      f"jaccard={jaccard:.4f} min={minimum} -> {verdict}")
sys.exit(0 if verdict == "PASS" else 1)
PY
}

# Runs one scan; returns 0 only if conf_set succeeds and the reference check passes.
attempt_scan() {
  local range_bytes="$1" output="$2" capture="$3"
  local status

  gpu_state
  set +e
  python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
    --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
    --range "$range_bytes" \
    --it "$ITERATIONS" \
    --step "$STEP" \
    --threshold "$THRESHOLD" \
    --trgtBankOfs "$REFERENCE_OFFSET" \
    --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
    --min-base-delay "$MIN_BASE_DELAY" \
    --max-base-delay "$MAX_BASE_DELAY" \
    --file "$output" > "$capture" 2>&1
  status=$?
  set -e
  cat "$capture" | tee -a "$LOG_FILE"
  gpu_state

  if [[ "$status" -ne 0 ]]; then
    log "REJECTED: conf_set exit code $status"
    return 1
  fi

  if ! reference_check "$output" "$range_bytes"; then
    log "REJECTED: scan disagrees with the reference map"
    return 1
  fi
  log "ACCEPTED"
  return 0
}

analyze_range() {
  local dir="$1" range_gib="$2"
  python3 - "$dir" "$range_gib" "$REFERENCE_SET" "$THRESHOLD" <<'PY' | tee -a "$LOG_FILE"
import sys
from itertools import combinations
from pathlib import Path

directory, range_gib, reference, threshold = (
    Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])

def load(path):
    return {int(x) for x in path.read_text().split() if x.isdigit()}

runs = sorted(directory.glob(f"CONF_SET_{threshold}_good*.txt"))
sets = [load(p) for p in runs]
print(f"--- range {range_gib} GiB: {len(sets)} accepted runs ---")
print("counts:", [len(s) for s in sets])
for (i, a), (j, b) in combinations(enumerate(sets, 1), 2):
    print(f"jaccard {i}-{j}: {len(a & b) / len(a | b):.4f}")
common = set.intersection(*sets) if sets else set()
print(f"common: {len(common)}")
out = directory / f"CONF_SET_{threshold}_common.txt"
out.write_text("".join(f"{v}\n" for v in sorted(common)))
if reference.exists():
    ref = load(reference)
    low = {v for v in common if v < 2**30}
    union = len(low | ref)
    print(f"overlap with 1 GiB reference below 1 GiB: "
          f"{len(low & ref)} (jaccard {len(low & ref) / union:.4f})" if union else "")
PY
}

row_set_range() {
  local dir="$1" range_gib="$2"
  local input="$dir/CONF_SET_${THRESHOLD}_common.txt"
  local output="$dir/ROW_SET_${THRESHOLD}_${range_gib}GiB.txt"
  if [[ ! -s "$input" ]]; then
    log "Common set empty; skipping row_set for ${range_gib} GiB."
    return
  fi
  python3 "$HAMMER_ROOT/util/run_timing_task.py" row_set \
    --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
    --it "$ITERATIONS" \
    --threshold "$THRESHOLD" \
    --trgtBankOfs "$REFERENCE_OFFSET" \
    --max 0 \
    "$input" \
    --outputFile "$output" 2>&1 | tee -a "$LOG_FILE" || true
  python3 - "$output" <<'PY' | tee -a "$LOG_FILE"
import sys
from collections import Counte
from pathlib import Path

path = Path(sys.argv[1])
if path.exists():
    sizes = [len(l.split()) for l in path.read_text().splitlines() if l.strip()]
    c = Counter(sizes)
    if sizes:
        print(f"row map: groups={len(sizes)} addresses={sum(sizes)} "
              f"groups_of_8={c[8]} ({100 * c[8] / len(sizes):.1f}%) max={max(sizes)}")
PY
}

: > "$LOG_FILE"
log "Started: $(date)"
log "Config: ranges=[$RANGES] alloc=${MEMORY_SIZE_GIB}GiB target_runs=$TARGET_RUNS threshold=$THRESHOLD canary=${CANARY_BYTES}B min_ref_jaccard=$MIN_REF_JACCARD deadline=${DEADLINE_HOURS}h"

for RANGE_GIB in $RANGES; do
  DIR="$RESULT_ROOT/range${RANGE_GIB}g"
  mkdir -p "$DIR/rejected"
  GOOD=0
  ATTEMPT=0
  while [[ "$GOOD" -lt "$TARGET_RUNS" && "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
    if [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; then
      log "Deadline reached; stopping."
      break 2
    fi
    ATTEMPT=$((ATTEMPT + 1))
    TMP_OUT="$DIR/attempt${ATTEMPT}.txt"
    log "===== range=${RANGE_GIB}GiB attempt=${ATTEMPT} good=${GOOD}/${TARGET_RUNS} $(date) ====="

    log "--- canary scan (${CANARY_BYTES} bytes) ---"
    if ! attempt_scan "$CANARY_BYTES" "$DIR/canary.txt" "$DIR/canary.log"; then
      log "Canary failed; GPU is not in the reference regime. Waiting ${RETRY_SLEEP}s."
      sleep "$RETRY_SLEEP"
      continue
    fi

    if attempt_scan $((RANGE_GIB * 2 ** 30)) "$TMP_OUT" "$DIR/attempt${ATTEMPT}.log"; then
      GOOD=$((GOOD + 1))
      mv "$TMP_OUT" "$DIR/CONF_SET_${THRESHOLD}_good${GOOD}.txt"
    else
      mv "$TMP_OUT" "$DIR/rejected/attempt${ATTEMPT}.txt" 2>/dev/null || true
      sleep "$RETRY_SLEEP"
    fi
  done

  if [[ "$GOOD" -ge 2 ]]; then
    analyze_range "$DIR" "$RANGE_GIB"
    row_set_range "$DIR" "$RANGE_GIB"
  else
    log "Range ${RANGE_GIB}GiB: only $GOOD accepted run(s); skipping analysis."
  fi
done

log "Finished: $(date)"
