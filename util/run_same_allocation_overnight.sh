#!/usr/bin/env bash
# Repeated same-allocation conflict-set runs across several candidate bank
# references, to assess which references are reproducible enough to use as
# aggressor-row candidates. Each iteration holds ONE allocation for its whole
# discovery+scan+row pass (see src/re_gddr/same_allocation_map.cu), then exits
# and a fresh iteration starts a new allocation.
set -eo pipefail
cd "$(dirname "$0")/.."
export HAMMER_ROOT="$PWD"

ALLOC_GIB="${ALLOC_GIB:-5}"
RANGE_MIB="${RANGE_MIB:-128}"
DISCOVERY_MIB="${DISCOVERY_MIB:-4}"
MAX_BANKS="${MAX_BANKS:-6}"
RUNS="${RUNS:-5}"
IT="${IT:-15}"
STEP="${STEP:-256}"
THRESHOLD="${THRESHOLD:-24}"
MIN_FREE_MIB="${MIN_FREE_MIB:-1024}"

OUT="${RESULT_DIR:-$PWD/results/same_allocation_overnight}"
mkdir -p "$OUT"

SIZE=$((ALLOC_GIB * 1073741824))
RANGE=$((RANGE_MIB * 1048576))
DISCOVERY=$((DISCOVERY_MIB * 1048576))

echo "Started: $(date) alloc=${ALLOC_GIB}GiB range=${RANGE_MIB}MiB discovery=${DISCOVERY_MIB}MiB max_banks=$MAX_BANKS runs=$RUNS"

if [[ ! -x src/out/build/same_allocation_map ]]; then
  echo "Missing src/out/build/same_allocation_map; build it first:" >&2
  echo "  cmake --build src/out/build --target same_allocation_map -j4" >&2
  exit 1
fi

for i in $(seq 1 "$RUNS"); do
  free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits)
  echo "===== run $i/$RUNS $(date)  free_vram=${free_mib}MiB ====="
  if (( free_mib < ALLOC_GIB * 1024 + MIN_FREE_MIB )); then
    echo "Skipping run $i: only ${free_mib} MiB free, need ~$((ALLOC_GIB * 1024 + MIN_FREE_MIB)) MiB" | tee -a "$OUT/run${i}.log"
    continue
  fi
  run_dir="$OUT/run${i}_$(date +%H%M%S)"
  src/out/build/same_allocation_map \
    "$SIZE" "$RANGE" "$IT" "$STEP" "$THRESHOLD" "$MAX_BANKS" "$DISCOVERY" "$run_dir" \
    2>&1 | tee "$OUT/run${i}.log" || echo "run $i failed (see log)"
done

python3 - "$OUT" "$RUNS" <<'PY'
import re, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])

bank_re = re.compile(r"candidate bank \d+: reference=(\d+) partner=(\d+)")
scan_re = re.compile(r"reference=(\d+) intersection=(\d+) union=(\d+) jaccard=([\d.]+) partner_retest=(\w+)")
row_re = re.compile(r"reference=(\d+).*?rows=(\d+) group_sizes (.+)")

print(f"\n{'run':>4} {'ref':>10} {'partner':>10} {'jaccard':>8} {'retest':>10} {'rows':>6} {'g8_pct':>7}")
summary = {}
for i in range(1, runs + 1):
    log = out / f"run{i}.log"
    if not log.exists():
        continue
    text = log.read_text()
    banks = dict(bank_re.findall(text))
    scans = {m.group(1): m for m in scan_re.finditer(text)}
    # row lines directly follow each reference's "intersection=" line
    for ref, m in scans.items():
        jaccard = float(m.group(4))
        retest = m.group(5)
        row_m = re.search(rf"reference={ref} intersection=.*?\nrows=(\d+) group_sizes ([^\n]+)", text)
        rows = g8 = total = 0
        if row_m:
            rows = int(row_m.group(1))
            for size_s, cnt_s in re.findall(r"(\d+):(\d+)", row_m.group(2)):
                size, cnt = int(size_s), int(cnt_s)
                total += cnt
                if size == 8:
                    g8 = cnt
        pct = 100 * g8 / total if total else 0.0
        print(f"{i:>4} {ref:>10} {banks.get(ref,'?'):>10} {jaccard:>8.3f} {retest:>10} {rows:>6} {pct:>6.1f}%")
        summary.setdefault(ref, []).append(jaccard)

print("\nPer-reference offset, across runs where it reappeared (placement differs run-to-run,")
print("so the SAME offset reappearing is itself informative):")
for ref, js in sorted(summary.items(), key=lambda kv: -len(kv[1])):
    seen = len(js)
    tag = "repeated across runs" if seen > 1 else "seen once"
    print(f"  ref {ref}: seen in {seen}/{runs} runs, jaccard {min(js):.3f}-{max(js):.3f} ({tag})")
PY

echo "Finished: $(date)"
