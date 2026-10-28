#!/usr/bin/env bash
# Robust-mode reproducibility test: repeated scans at several ranges, then Jaccard + row_set.
set -eo pipefail
cd "$(dirname "$0")/.."
export HAMMER_ROOT="$PWD"
OUT="${RESULT_DIR:-$PWD/results/robust_overnight}"
ALLOC_GIB="${MEMORY_SIZE_GIB:-4}"
RANGES_MIB="${RANGES_MIB:-128 512 1024}"
RUNS="${RUNS:-3}"
CONFIRM="${CONFIRM_RUNS:-5}"
mkdir -p "$OUT"
SIZE=$((ALLOC_GIB * 1073741824))
echo "Started: $(date)  alloc=${ALLOC_GIB}GiB ranges=${RANGES_MIB} runs=${RUNS} confirm=${CONFIRM}"

for r in $RANGES_MIB; do
  for i in $(seq 1 "$RUNS"); do
    f="$OUT/conf_${r}MiB_run${i}.txt"
    echo "===== range=${r}MiB run=$i $(date) ====="
    nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu --format=csv,noheader || true
    python3 util/run_timing_task.py conf_set --size "$SIZE" --range $((r * 1048576)) \
      --it 15 --step 256 --threshold 24 --trgtBankOfs 0 --self-timing-tolerance 30 \
      --confirm-runs "$CONFIRM" --file "$f" | tee "$OUT/log_${r}MiB_run${i}.txt" \
      | grep -E "Base delay|Final base|refreshes|Control|Accepted"
  done
done

python3 - "$OUT" "$RANGES_MIB" "$RUNS" <<'PY'
import sys
from pathlib import Path
from itertools import combinations
out, ranges, runs = Path(sys.argv[1]), sys.argv[2].split(), int(sys.argv[3])
def load(p):
    return {int(x) for x in Path(p).read_text().split() if x.isdigit()} if Path(p).exists() else set()
for r in ranges:
    sets = [load(out / f"conf_{r}MiB_run{i}.txt") for i in range(1, runs + 1)]
    print(f"\nRange {r} MiB counts:", [len(s) for s in sets])
    for (i, a), (j, b) in combinations(enumerate(sets, 1), 2):
        print(f"  jaccard {i}-{j}: {len(a & b) / len(a | b) if a | b else 0:.3f}")
    common = set.intersection(*sets) if sets and all(sets) else set()
    print(f"  common: {len(common)}")
    (out / f"common_{r}MiB.txt").write_text("\n".join(map(str, sorted(common))) + ("\n" if common else ""))
PY

for r in $RANGES_MIB; do
  c="$OUT/common_${r}MiB.txt"
  if [[ -s "$c" ]]; then
    echo "===== row_set ${r}MiB ====="
    python3 util/run_timing_task.py row_set --size "$SIZE" --it 15 --threshold 24 \
      --trgtBankOfs 0 --max 0 "$c" --outputFile "$OUT/ROW_SET_${r}MiB.txt" \
      > "$OUT/log_row_set_${r}MiB.txt" 2>&1 || echo "row_set failed for ${r}MiB"
  fi
done
echo "Finished: $(date)"
