#include "drama_conflict_prober.cuh"
#include <iostream>

std::string CLI_PREFIX = "(conf-set): ";

int
main (int argc, char *argv[])
{
  uint64_t size = std::stoull (argv[1]);
  uint64_t range = std::stoull (argv[2]);
  uint64_t it = std::stoull (argv[3]);
  uint64_t step = std::stoull (argv[4]);
  uint64_t threshold = std::stoull (argv[5]);

  /* Offset to an address in Target Bank */
  uint64_t offset_to_bank = std::stoull (argv[6]);

  auto output_filename = argv[7];
  uint64_t self_timing_tolerance = argc > 8 ? std::stoull (argv[8]) : 10;

  re_gddr::ConflictProber nc_test (2, size, range, it, step);

  std::ofstream offset_file;
  offset_file.open (output_filename); /* Argument File name */

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
  uint64_t pair_candidates = 0;
  uint64_t accepted_candidates = 0;

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
  std::cout << CLI_PREFIX << "Pair-latency candidates: "
            << pair_candidates << '\n';
  std::cout << CLI_PREFIX << "Accepted candidates: "
            << accepted_candidates << '\n';
  std::cout << CLI_PREFIX << "Self-timing tolerance: "
            << self_timing_tolerance << " ns\n";
  return 0;
}
