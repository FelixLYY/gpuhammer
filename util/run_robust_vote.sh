#!/usr/bin/env bash
# Stricter robust scans (more confirmations) + cross-run voting + row_set quality per vote level.
set -eo pipefail
cd "$(dirname "$0")/.."
export HAMMER_ROOT="$PWD"
OUT="${RESULT_DIR:-$PWD/results/robust_vote}"
ALLOC_GIB="${MEMORY_SIZE_GIB:-4}"
RANGES_MIB="${RANGES_MIB:-512 1024}"
RUNS="${RUNS:-5}"
CONFIRM="${CONFIRM_RUNS:-9}"
PERCENT="${CONFIRM_PERCENT:-90}"
VOTES="${VOTE_PERCENTS:-40 60 80 100}"
mkdir -p "$OUT"
SIZE=$((ALLOC_GIB * 1073741824))
echo "Started: $(date) alloc=${ALLOC_GIB}GiB ranges=${RANGES_MIB} runs=${RUNS} confirm=${CONFIRM}@${PERCENT}%"

for r in $RANGES_MIB; do
  for i in $(seq 1 "$RUNS"); do
    f="$OUT/conf_${r}MiB_run${i}.txt"
    [[ -s "$f" ]] && { echo "skip existing $f"; continue; }
    echo "===== range=${r}MiB run=$i $(date) ====="
    nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu --format=csv,noheader || true
    python3 util/run_timing_task.py conf_set --size "$SIZE" --range $((r * 1048576)) \
      --it 15 --step 256 --threshold 24 --trgtBankOfs 0 --self-timing-tolerance 30 \
      --confirm-runs "$CONFIRM" --confirm-percent "$PERCENT" --file "$f" \
      > "$OUT/log_${r}MiB_run${i}.txt" 2>&1 || echo "conf_set failed (run $i)"
    grep -E "Base delay|Final base|refreshes|Control|Accepted" "$OUT/log_${r}MiB_run${i}.txt" || true
  done
done

python3 - "$OUT" "$RANGES_MIB" "$RUNS" "$VOTES" <<'PY'
import sys
from pathlib import Path
from itertools import combinations
from collections import Counter
out, ranges, runs, votes = Path(sys.argv[1]), sys.argv[2].split(), int(sys.argv[3]), [int(v) for v in sys.argv[4].split()]
def load(p):
    return {int(x) for x in Path(p).read_text().split() if x.isdigit()} if Path(p).exists() else set()
for r in ranges:
    sets = [load(out / f"conf_{r}MiB_run{i}.txt") for i in range(1, runs + 1)]
    sets = [s for s in sets if s]
    print(f"\nRange {r} MiB counts: {[len(s) for s in sets]}")
    js = [len(a & b) / len(a | b) for a, b in combinations(sets, 2)]
    if js:
        print(f"  jaccard min/mean/max: {min(js):.3f}/{sum(js)/len(js):.3f}/{max(js):.3f}")
    cnt = Counter(x for s in sets for x in s)
    for v in votes:
        need = -(-len(sets) * v // 100)
        kept = sorted(x for x, c in cnt.items() if c >= need)
        print(f"  vote>={v}% ({need}/{len(sets)}): {len(kept)} offsets")
        (out / f"vote_{r}MiB_{v}.txt").write_text("\n".join(map(str, kept)) + ("\n" if kept else ""))
PY

for r in $RANGES_MIB; do
  for v in $VOTES; do
    c="$OUT/vote_${r}MiB_${v}.txt"
    [[ -s "$c" ]] || continue
    echo "===== row_set ${r}MiB vote${v} $(date) ====="
    python3 util/run_timing_task.py row_set --size "$SIZE" --it 15 --threshold 24 \
      --trgtBankOfs 0 --max 0 "$c" --outputFile "$OUT/ROW_SET_${r}MiB_${v}.txt" \
      > "$OUT/log_row_set_${r}MiB_${v}.txt" 2>&1 || echo "row_set failed"
  done
done

python3 - "$OUT" "$RANGES_MIB" "$VOTES" <<'PY'
import sys, re
from pathlib import Path
from collections import Counter
out, ranges, votes = Path(sys.argv[1]), sys.argv[2].split(), sys.argv[3].split()
print("\nRow-set quality (range, vote%, rows, groups of 8, pct of rows):")
for r in ranges:
    for v in votes:
        p = out / f"ROW_SET_{r}MiB_{v}.txt"
        if not p.exists():
            continue
        sizes = Counter(len([x for x in re.split(r"\s+", l) if x.isdigit()]) for l in p.read_text().splitlines())
        sizes.pop(0, None)
        n = sum(sizes.values())
        print(f"  {r}MiB vote{v}: rows={n} g8={sizes[8]} ({100*sizes[8]/n if n else 0:.1f}%) top={sizes.most_common(4)}")
PY
echo "Finished: $(date)"
