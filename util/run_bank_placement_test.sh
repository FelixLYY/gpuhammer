#!/usr/bin/env bash
# Bank-placement test: does the conflict set depend on the reference offset,
# the allocation size, or the process launch?
# Scans several reference offsets (offset 0 plus members of the old reference
# set and of the new voted set), repeated across fresh launches and two
# allocation sizes, then prints a Jaccard matrix of the voted sets.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULT_ROOT="${RESULT_ROOT:-$HAMMER_ROOT/results/bank_placement}"
LOG_FILE="$RESULT_ROOT/run.log"

RANGE_MIB="${RANGE_MIB:-128}"
REPEATS="${REPEATS:-5}"
ALLOC_GIBS="${ALLOC_GIBS:-4 5}"
ITERATIONS="${ITERATIONS:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-24}"
SELF_TIMING_TOLERANCE="${SELF_TIMING_TOLERANCE:-30}"
VOTE_FRACTION="${VOTE_FRACTION:-0.7}"
DEADLINE_HOURS="${DEADLINE_HOURS:-8}"
OLD_REFERENCE="${OLD_REFERENCE:-$HAMMER_ROOT/results/threshold24_1g_validation/CONF_SET_24_common_all3.txt}"
NEW_VOTED="${NEW_VOTED:-$HAMMER_ROOT/results/consensus/range128m/CONF_SET_24_vote70.txt}"

if [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniconda3/etc/profile.d/conda.sh"
elif [[ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]]; then
  source "$HOME/miniforge3/etc/profile.d/conda.sh"
else
  echo "Conda initialization script was not found." >&2
  exit 1
fi
conda activate rmm_dev

for f in "$OLD_REFERENCE" "$NEW_VOTED"; do
  [[ -s "$f" ]] || { echo "Missing input: $f" >&2; exit 1; }
done

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

# Reference offsets: name:value pairs, all below the scanned range.
REFS="$(python3 - "$OLD_REFERENCE" "$NEW_VOTED" "$RANGE_MIB" <<'PY'
import sys
from pathlib import Path

limit = int(sys.argv[3]) * 2**20

def load(path):
    return sorted(v for v in (int(x) for x in Path(path).read_text().split()
                              if x.isdigit()) if v < limit)

old, new = load(sys.argv[1]), load(sys.argv[2])
refs = [("zero", 0), ("arbitrary", 4096)]
if old:
    refs += [("old_first", old[0]), ("old_mid", old[len(old) // 2])]
if new:
    refs += [("new_first", new[0]), ("new_mid", new[len(new) // 2])]
print(" ".join(f"{n}:{v}" for n, v in refs))
PY
)"

analyze() {
  python3 - "$RESULT_ROOT" "$OLD_REFERENCE" "$NEW_VOTED" "$VOTE_FRACTION" "$RANGE_MIB" <<'PY' | tee -a "$LOG_FILE"
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

root, old_path, new_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
fraction, limit = float(sys.argv[4]), int(sys.argv[5]) * 2**20

def load(path):
    return {int(x) for x in Path(path).read_text().split() if x.isdigit()}

groups = defaultdict(list)
for p in sorted(root.glob("alloc*/ref_*/scan*.txt")):
    groups[(p.parts[-3], p.parts[-2])].append(load(p))

voted = {}
print("--- per-configuration vote sets ---")
for key, scans in sorted(groups.items()):
    need = max(1, math.ceil(len(scans) * fraction))
    votes = Counter(v for s in scans for v in s)
    kept = {v for v, c in votes.items() if c >= need}
    voted[f"{key[0]}/{key[1]}"] = kept
    print(f"{key[0]}/{key[1]}: scans={len(scans)} counts={[len(s) for s in scans]} voted={len(kept)}")

voted["OLD_REF"] = {v for v in load(old_path) if v < limit}
voted["NEW_VOTED"] = {v for v in load(new_path) if v < limit}
names = list(voted)

def jac(a, b):
    union = len(a | b)
    return len(a & b) / union if union else 0.0

print("--- Jaccard matrix (rows/cols in this order) ---")
for i, n in enumerate(names):
    print(f"[{i}] {n} ({len(voted[n])})")
print("     " + " ".join(f"{i:5d}" for i in range(len(names))))
for i, a in enumerate(names):
    print(f"[{i:2d}] " + " ".join(f"{jac(voted[a], voted[b]):5.2f}" for b in names))

print("--- clusters (Jaccard >= 0.5 with first member) ---")
clusters = []
for n in names:
    for c in clusters:
        if jac(voted[n], voted[c[0]]) >= 0.5:
            c.append(n)
            break
    else:
        clusters.append([n])
for i, c in enumerate(clusters, 1):
    print(f"cluster {i}: {c}")
PY
}

: > "$LOG_FILE"
log "Started: $(date)"
log "Config: range=${RANGE_MIB}MiB repeats=$REPEATS allocs=[$ALLOC_GIBS] refs=[$REFS] threshold=$THRESHOLD"
echo "alloc_gib,ref,ref_offset,repeat,start_state,end_state,base_delay,final_base_delay,accepted" > "$RESULT_ROOT/telemetry.csv"

for ALLOC in $ALLOC_GIBS; do
  for pair in $REFS; do
    NAME="${pair%%:*}"
    OFS="${pair##*:}"
    DIR="$RESULT_ROOT/alloc${ALLOC}g/ref_${NAME}"
    mkdir -p "$DIR"
    for rep in $(seq 1 "$REPEATS"); do
      if [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; then
        log "Deadline reached; stopping."
        break 3
      fi
      OUT="$DIR/scan${rep}.txt"
      CAP="$DIR/scan${rep}.log"
      START_STATE="$(gpu_state)"
      log "===== alloc=${ALLOC}GiB ref=${NAME}(${OFS}) repeat=${rep}/${REPEATS} $(date) ====="

      set +e
      python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
        --size $((ALLOC * 2 ** 30)) \
        --range $((RANGE_MIB * 2 ** 20)) \
        --it "$ITERATIONS" \
        --step "$STEP" \
        --threshold "$THRESHOLD" \
        --trgtBankOfs "$OFS" \
        --self-timing-tolerance "$SELF_TIMING_TOLERANCE" \
        --file "$OUT" > "$CAP" 2>&1
      STATUS=$?
      set -e
      cat "$CAP" >> "$LOG_FILE"

      END_STATE="$(gpu_state)"
      BASE="$(sed -n 's/.*Base delay: \([0-9]*\) ns.*/\1/p' "$CAP" | head -1)"
      FINAL="$(sed -n 's/.*Final base delay: \([0-9]*\) ns.*/\1/p' "$CAP" | head -1)"
      ACC="$(sed -n 's/.*Accepted candidates: \([0-9]*\).*/\1/p' "$CAP" | head -1)"
      echo "$ALLOC,$NAME,$OFS,$rep,$START_STATE,$END_STATE,$BASE,$FINAL,$ACC" >> "$RESULT_ROOT/telemetry.csv"
      if [[ "$STATUS" -ne 0 ]]; then
        log "scan failed with exit code $STATUS; discarding"
        rm -f "$OUT"
      fi
    done
  done
done

analyze
log "Finished: $(date)"
