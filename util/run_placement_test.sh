#!/usr/bin/env bash
# Placement test: does the same 128 MiB scan reproduce across allocation sizes and (via TAG/COMPARE_TAG) across WSL restarts?
set -eo pipefail
cd "$(dirname "$0")/.."
export HAMMER_ROOT="$PWD"
TAG="${TAG:-session1}"
COMPARE_TAG="${COMPARE_TAG:-}"
BASE="${RESULT_DIR:-$PWD/results/placement}"
OUT="$BASE/$TAG"
ALLOCS="${ALLOC_GIBS:-4 5}"
RUNS="${RUNS:-3}"
RANGE_MIB="${RANGE_MIB:-128}"
mkdir -p "$OUT"
echo "Started: $(date) tag=$TAG allocs=$ALLOCS runs=$RUNS range=${RANGE_MIB}MiB compare=${COMPARE_TAG:-none}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader || true

for a in $ALLOCS; do
  for i in $(seq 1 "$RUNS"); do
    f="$OUT/conf_a${a}_run${i}.txt"
    [[ -s "$f" ]] && { echo "skip $f"; continue; }
    echo "===== alloc=${a}GiB run=$i $(date) ====="
    nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory,pstate,temperature.gpu --format=csv,noheader || true
    python3 util/run_timing_task.py conf_set --size $((a * 1073741824)) --range $((RANGE_MIB * 1048576)) \
      --it 15 --step 256 --threshold 24 --trgtBankOfs 0 --self-timing-tolerance 30 \
      --confirm-runs 5 --file "$f" > "$OUT/log_a${a}_run${i}.txt" 2>&1 || echo "conf_set failed"
    grep -E "Base delay|Control|Accepted" "$OUT/log_a${a}_run${i}.txt" || true
  done
done

python3 - "$BASE" "$TAG" "$COMPARE_TAG" "$ALLOCS" "$RUNS" <<'PY'
import sys
from pathlib import Path
from collections import Counter
base, tag, cmp_tag, allocs, runs = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4].split(), int(sys.argv[5])
def load(p):
    return {int(x) for x in Path(p).read_text().split() if x.isdigit()} if Path(p).exists() else set()
def jac(a, b): return len(a & b) / len(a | b) if a | b else 0.0
def vote(sets):
    sets = [s for s in sets if s]
    need = max(1, -(-len(sets) * 2 // 3))
    c = Counter(x for s in sets for x in s)
    return {x for x, n in c.items() if n >= need}
out = base / tag
voted = {}
print("\n== Within this session: per-run sets ==")
named = []
for a in allocs:
    sets = [load(out / f"conf_a{a}_run{i}.txt") for i in range(1, runs + 1)]
    for i, s in enumerate(sets, 1):
        named.append((f"a{a}r{i}", s))
    voted[a] = vote(sets)
    (out / f"vote_a{a}.txt").write_text("\n".join(map(str, sorted(voted[a]))) + "\n")
    print(f"alloc {a}GiB counts {[len(s) for s in sets]} voted {len(voted[a])}")
names = [n for n, _ in named]
print("Jaccard matrix:")
print("        " + " ".join(f"{n:>6}" for n in names))
for n, s in named:
    print(f"{n:>7} " + " ".join(f"{jac(s, t):6.2f}" for _, t in named))
if len(allocs) > 1:
    print("\nVoted set overlap between allocation sizes:")
    for i, a in enumerate(allocs):
        for b in allocs[i + 1:]:
            print(f"  {a}GiB vs {b}GiB: jaccard {jac(voted[a], voted[b]):.3f}")
if cmp_tag:
    print(f"\n== Versus session {cmp_tag} ==")
    for a in allocs:
        for b in allocs:
            p = base / cmp_tag / f"vote_a{b}.txt"
            if p.exists():
                print(f"  {tag} {a}GiB vs {cmp_tag} {b}GiB: jaccard {jac(voted[a], load(p)):.3f}")

# Row-address structure: relative offsets inside complete 8-groups.
print("\n== Row-group structure (from voted set of first allocation) ==")
first = voted[allocs[0]]
rows = {}
import re
for x in sorted(first):
    rows.setdefault(x >> 14, []).append(x)
pat = Counter()
for g in rows.values():
    if len(g) == 8:
        pat[tuple(v - g[0] for v in g)] += 1
print(f"offset>>14 buckets with exactly 8 members: {sum(pat.values())} of {len(rows)}")
for p, n in pat.most_common(5):
    print(f"  {n:5d} x relative offsets {list(p)}")
PY
echo "Finished: $(date)"
