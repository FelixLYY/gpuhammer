#!/usr/bin/env bash
# Runs many conf_set scans per range and keeps offsets by vote frequency.
# Random false positives rarely repeat; true conflicts do. No base-delay
# window is needed, and the validated 1 GiB map is used to score each vote level.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_ROOT="${RESULT_ROOT:-$HAMMER_ROOT/results/consensus}"
LOG_FILE="$RESULT_ROOT/run.log"

RANGES_MIB="${RANGES_MIB:-128 512 1024}"
RUNS_PER_RANGE="${RUNS_PER_RANGE:-12 8 6}"
MEMORY_SIZE_GIB="${MEMORY_SIZE_GIB:-4}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-24}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
REFERENCE_OFFSET="${REFERENCE_OFFSET:-0}"
REFERENCE_SET="${REFERENCE_SET:-$HAMMER_ROOT/results/threshold24_1g_validation/CONF_SET_24_common_all3.txt}"
DEADLINE_HOURS="${DEADLINE_HOURS:-9}"

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
DEADLINE_EPOCH=$(( $(date +%s) + DEADLINE_HOURS * 3600 ))

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

gpu_state() {
  nvidia-smi --query-gpu=clocks.gr,clocks.mem,pstate,temperature.gpu \
    --format=csv,noheader,nounits | tr -d ' ' | tr ',' '/'
}

scan_vs_reference() {
  python3 - "$1" "$2" "$REFERENCE_SET" <<'PY'
import sys
from pathlib import Path

scan, range_mib, reference = Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3])
limit = min(range_mib * 2**20, 2**30)

def load(path):
    return {int(x) for x in path.read_text().split() if x.isdigit()}

if not scan.exists() or not reference.exists():
    print("NA")
else:
    found = {v for v in load(scan) if v < limit}
    ref = {v for v in load(reference) if v < limit}
    union = len(found | ref)
    print(f"{len(found & ref) / union:.4f}" if union else "NA")
PY
}

analyze() {
  local dir="$1" range_mib="$2"
  python3 - "$dir" "$range_mib" "$REFERENCE_SET" "$THRESHOLD" <<'PY' | tee -a "$LOG_FILE"
import sys
from collections import Counter
from pathlib import Path

directory, range_mib, reference, threshold = (
    Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])

def load(path):
    return {int(x) for x in path.read_text().split() if x.isdigit()}

scans = [load(p) for p in sorted(directory.glob(f"scan*.txt"))]
n = len(scans)
print(f"--- range {range_mib} MiB: {n} scans, counts={[len(s) for s in scans]} ---")
if n < 2:
    sys.exit(0)

votes = Counter(v for s in scans for v in s)
limit = min(range_mib * 2**20, 2**30)
ref = {v for v in load(reference) if v < limit} if reference.exists() else set()
print(f"reference offsets in range: {len(ref)}")
print("vote level | kept | jaccard vs reference | precision | recall")
best = None
for pct in (30, 50, 60, 70, 80, 90, 100):
    need = max(1, -(-n * pct // 100))
    kept = {v for v, c in votes.items() if c >= need}
    inter = len(kept & ref)
    union = len(kept | ref)
    jac = inter / union if union else 0.0
    prec = inter / len(kept) if kept else 0.0
    rec = inter / len(ref) if ref else 0.0
    print(f">={pct:3d}% ({need}/{n}) | {len(kept):7d} | {jac:.4f} | {prec:.3f} | {rec:.3f}")
    out = directory / f"CONF_SET_{threshold}_vote{pct}.txt"
    out.write_text("".join(f"{v}\n" for v in sorted(kept)))
    if best is None or jac > best[0]:
        best = (jac, pct)
if ref:
    print(f"best vote level by reference jaccard: >={best[1]}% (jaccard {best[0]:.4f})")
PY
}

row_maps() {
  local dir="$1" range_mib="$2"
  local input="$dir/CONF_SET_${THRESHOLD}_vote${ROW_VOTE:-70}.txt"
  local output="$dir/ROW_SET_${THRESHOLD}_${range_mib}MiB_vote${ROW_VOTE:-70}.txt"
  if [[ ! -s "$input" ]]; then
    log "Vote set empty for ${range_mib} MiB; skipping row_set."
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
from collections import Counter
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
log "Config: ranges_mib=[$RANGES_MIB] runs=[$RUNS_PER_RANGE] alloc=${MEMORY_SIZE_GIB}GiB threshold=$THRESHOLD"
echo "range_mib,scan,start_gr/mem/pstate/temp,end_gr/mem/pstate/temp,base_delay,final_base_delay,accepted,ref_jaccard" > "$RESULT_ROOT/telemetry.csv"

read -r -a RANGE_ARR <<< "$RANGES_MIB"
read -r -a RUNS_ARR <<< "$RUNS_PER_RANGE"

for idx in "${!RANGE_ARR[@]}"; do
  RANGE_MIB="${RANGE_ARR[$idx]}"
  RUNS="${RUNS_ARR[$idx]:-6}"
  DIR="$RESULT_ROOT/range${RANGE_MIB}m"
  mkdir -p "$DIR"

  for scan in $(seq 1 "$RUNS"); do
    if [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; then
      log "Deadline reached; stopping."
      break 2
    fi
    OUT="$DIR/scan${scan}.txt"
    CAP="$DIR/scan${scan}.log"
    START_STATE="$(gpu_state)"
    log "===== range=${RANGE_MIB}MiB scan=${scan}/${RUNS} $(date) state=$START_STATE ====="

    set +e
    python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
      --size $((MEMORY_SIZE_GIB * 2 ** 30)) \
      --range $((RANGE_MIB * 2 ** 20)) \
      --it "$ITERATIONS" \
      --step "$STEP" \
      --threshold "$THRESHOLD" \
      --trgtBankOfs "$REFERENCE_OFFSET" \
      --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
      --file "$OUT" > "$CAP" 2>&1
    STATUS=$?
    set -e
    cat "$CAP" >> "$LOG_FILE"

    END_STATE="$(gpu_state)"
    BASE="$(sed -n 's/.*Base delay: \([0-9]*\) ns.*/\1/p' "$CAP" | head -1)"
    FINAL="$(sed -n 's/.*Final base delay: \([0-9]*\) ns.*/\1/p' "$CAP" | head -1)"
    ACC="$(sed -n 's/.*Accepted candidates: \([0-9]*\).*/\1/p' "$CAP" | head -1)"
    REF_JAC="$(scan_vs_reference "$OUT" "$RANGE_MIB")"
    echo "$RANGE_MIB,$scan,$START_STATE,$END_STATE,$BASE,$FINAL,$ACC,$REF_JAC" >> "$RESULT_ROOT/telemetry.csv"
    log "scan summary: start=$START_STATE end=$END_STATE base=$BASE final=$FINAL accepted=$ACC ref_jaccard=$REF_JAC"
    if [[ "$STATUS" -ne 0 ]]; then
      log "scan failed with exit code $STATUS; discarding"
      rm -f "$OUT"
    fi
  done

  analyze "$DIR" "$RANGE_MIB"
  row_maps "$DIR" "$RANGE_MIB"
done

log "Finished: $(date)"
