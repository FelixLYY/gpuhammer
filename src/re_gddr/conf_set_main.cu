#include "drama_conflict_prober.cuh"
#include <algorithm>
#include <iostream>
#include <sstream>
#include <stdexcept>

std::string CLI_PREFIX = "(conf-set): ";

// Avoids strtoull, which links to __isoc23_strtoull and fails with conda's ld.
static uint64_t
parse_u64 (const char *s)
{
  std::istringstream is (s);
  uint64_t v;
  if (!(is >> v))
    throw std::invalid_argument ("bad numeric argument");
  return v;
}

int
main (int argc, char *argv[])
{
  uint64_t size = parse_u64 (argv[1]);
  uint64_t range = parse_u64 (argv[2]);
  uint64_t it = parse_u64 (argv[3]);
  uint64_t step = parse_u64 (argv[4]);
  uint64_t threshold = parse_u64 (argv[5]);

  /* Offset to an address in Target Bank */
  uint64_t offset_to_bank = parse_u64 (argv[6]);

  auto output_filename = argv[7];
  uint64_t self_timing_tolerance = argc > 8 ? parse_u64 (argv[8]) : 10;

  /* Accepted base-delay window in ns; max of 0 disables the guard */
  uint64_t min_base_delay = argc > 9 ? parse_u64 (argv[9]) : 0;
  uint64_t max_base_delay = argc > 10 ? parse_u64 (argv[10]) : 0;
  auto base_delay_in_window = [&] (uint64_t delay) {
    return max_base_delay == 0
           || (delay >= min_base_delay && delay <= max_base_delay);
  };

  re_gddr::ConflictProber nc_test (2, size, range, it, step);

  std::ofstream offset_file;
  offset_file.open (output_filename); /* Argument File name */
  if (!offset_file.is_open ())
    {
      std::cerr << CLI_PREFIX << "Unable to open output file: "
                << output_filename << '\n';
      return 1;
    }

  /* Initialize address pairs */
  nc_test.set_addr_lst_host (0, offset_to_bank);
  nc_test.set_addr_lst_host (1, offset_to_bank);

  uint64_t base_delay = nc_test.repeat_n_addr_exp ();

  // warm-up GPU clock if cannot set to fixed rate.
  for (int i = 0; i < 100000; i++)
    base_delay = nc_test.repeat_n_addr_exp ();
  cudaDeviceSynchronize ();

  // Minimum delay to be considered a conflict
  uint64_t conflict_delay = base_delay + threshold;
  std::cout << CLI_PREFIX << "Base delay: "
            << base_delay << " ns\n";
  std::cout << CLI_PREFIX << "Conflict cutoff: "
            << conflict_delay << " ns\n";
  if (!base_delay_in_window (base_delay))
    {
      std::cerr << CLI_PREFIX << "Base delay " << base_delay
                << " ns outside window [" << min_base_delay << ", "
                << max_base_delay << "] ns; aborting.\n";
      offset_file.close ();
      return 3;
    }
  uint64_t pair_candidates = 0;
  uint64_t accepted_candidates = 0;

  /* Robust mode: the baseline is refreshed every refresh_interval candidates
     and each candidate is re-tested confirm_runs times against a baseline
     measured immediately before it, so clock changes cancel out. */
  uint64_t confirm_runs = argc > 11 ? parse_u64 (argv[11]) : 0;
  uint64_t refresh_interval = argc > 12 ? parse_u64 (argv[12]) : 512;
  uint64_t confirm_percent = argc > 13 ? parse_u64 (argv[13]) : 80;
  uint64_t needed_confirms = (confirm_runs * confirm_percent + 99) / 100;
  uint64_t scanned = 0, refreshes = 0;
  uint64_t control_trials = 0, control_false_positives = 0;
  uint64_t min_local_base = UINT64_MAX, max_local_base = 0;

  auto measure_ref_pair = [&] (uint64_t other) {
    nc_test.set_addr_lst_host (0, offset_to_bank);
    nc_test.set_addr_lst_host (1, other);
    return nc_test.repeat_n_addr_exp ();
  };

  if (confirm_runs > 0)
    {
      uint64_t local_base = base_delay;
      nc_test.loop_range ([&] (uint64_t cand) {
        if (scanned++ % refresh_interval == 0)
          {
            local_base = measure_ref_pair (offset_to_bank);
            refreshes++;
            min_local_base = std::min (min_local_base, local_base);
            max_local_base = std::max (max_local_base, local_base);

            /* Control: two identical baseline measurements must agree */
            uint64_t again = measure_ref_pair (offset_to_bank);
            control_trials++;
            if (again > local_base + threshold)
              control_false_positives++;
          }

        if (cand == offset_to_bank)
          return;

        if (measure_ref_pair (cand) <= local_base + threshold)
          return;
        pair_candidates++;

        uint64_t confirms = 0;
        for (uint64_t r = 0; r < confirm_runs; r++)
          {
            uint64_t b = measure_ref_pair (offset_to_bank);
            uint64_t p = measure_ref_pair (cand);
            nc_test.set_addr_lst_host (0, cand);
            nc_test.set_addr_lst_host (1, cand);
            uint64_t s = nc_test.repeat_n_addr_exp ();
            uint64_t diff = s > b ? s - b : b - s;
            if (p > b + threshold && diff <= self_timing_tolerance)
              confirms++;
          }
        if (confirms >= needed_confirms)
          {
            offset_file << cand << '\n';
            accepted_candidates++;
          }
        nc_test.set_addr_lst_host (0, offset_to_bank);
      });
    }

  if (confirm_runs == 0)
  nc_test.loop_range ([&] (uint64_t step) {
    nc_test.set_addr_lst_host (1, step);

    /* Found conflict */
    if (conflict_delay < nc_test.repeat_n_addr_exp ())
      {
        pair_candidates++;

        /* Prepare for run of 'step' with itself */
        nc_test.set_addr_lst_host (0, step);

        /* Should be in reasonable range of base_delay as in same bank chip */
        uint64_t candidate_self_timing = nc_test.repeat_n_addr_exp ();
        uint64_t self_timing_difference =
            candidate_self_timing > base_delay
                ? candidate_self_timing - base_delay
                : base_delay - candidate_self_timing;
        if (self_timing_difference <= self_timing_tolerance)
          {
            offset_file << step << '\n';
            accepted_candidates++;
          }

        /* Reset [0] */
        nc_test.set_addr_lst_host (0, offset_to_bank);
      }
  });

  offset_file.close ();

  /* Re-measure the baseline to detect clock drift during the scan */
  nc_test.set_addr_lst_host (0, offset_to_bank);
  nc_test.set_addr_lst_host (1, offset_to_bank);
  uint64_t final_base_delay = 0;
  for (int i = 0; i < 100000; i++)
    final_base_delay = nc_test.repeat_n_addr_exp ();
  std::cout << CLI_PREFIX << "Final base delay: "
            << final_base_delay << " ns\n";

  if (confirm_runs > 0)
    {
      std::cout << CLI_PREFIX << "Baseline refreshes: " << refreshes
                << " (local base " << min_local_base << ".." << max_local_base
                << " ns)\n";
      std::cout << CLI_PREFIX << "Control false positives: "
                << control_false_positives << "/" << control_trials << '\n';
      std::cout << CLI_PREFIX << "Confirmations required: "
                << needed_confirms << "/" << confirm_runs << '\n';
    }

  std::cout << CLI_PREFIX << "Pair-latency candidates: "
            << pair_candidates << '\n';
  std::cout << CLI_PREFIX << "Accepted candidates: "
            << accepted_candidates << '\n';
  std::cout << CLI_PREFIX << "Self-timing tolerance: "
            << self_timing_tolerance << " ns\n";
  if (!base_delay_in_window (final_base_delay))
    std::cerr << CLI_PREFIX << "Warning: final base delay outside window.\n";
  return 0;
}
