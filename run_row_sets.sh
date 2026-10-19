#!/bin/bash

echo ""
echo "-------------------------------------------"
echo ""
echo "[INFO] Starting Generation of Row Sets"

# These values must be calibrated on the target GPU. They are intentionally
# conservative for an RTX 4060 Laptop GPU and should not be replaced with the
# A6000 values without measurement.
memory_size_gib=${MEMORY_SIZE_GIB:-5}
scan_step=${SCAN_STEP:-256}
timing_iterations=${TIMING_ITERATIONS:-15}
conflict_threshold=${CONFLICT_THRESHOLD:-27}

# Start with bank 0. After running bank_set, add discovered offsets here and
# assign each one a stable output label.
bank_offsets=(0)
bank_labels=(0)
memory_size=$((memory_size_gib * (2 ** 30)))

mkdir -p "$HAMMER_ROOT/results/row_sets"

for i in "${!bank_offsets[@]}"; do
  val=${bank_offsets[$i]}
  label=${bank_labels[$i]}
  python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
    --range "$memory_size" --size "$memory_size" \
    --it "$timing_iterations" --step "$scan_step" \
    --threshold "$conflict_threshold" \
    --file "$HAMMER_ROOT/results/row_sets/CONF_SET_${label}.txt" \
    --trgtBankOfs "$val"
  sleep 3s
  python3 "$HAMMER_ROOT/util/run_timing_task.py" row_set \
    --size "$memory_size" --it "$timing_iterations" \
    --threshold "$conflict_threshold" --trgtBankOfs "$val" \
    --outputFile "$HAMMER_ROOT/results/row_sets/ROW_SET_${label}.txt" \
    "$HAMMER_ROOT/results/row_sets/CONF_SET_${label}.txt"
  sleep 3s
done

echo "[INFO] Done. Row Sets are stored in 'results/row_sets'"