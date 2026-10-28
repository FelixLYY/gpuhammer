#include "drama_conflict_prober.cuh"

#include <algorithm>
#include <charconv>
#include <filesystem>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

std::string CLI_PREFIX = "(same-allocation-map): ";

namespace
{
constexpr uint64_t confirmations = 5;
constexpr uint64_t required = 4;
constexpr uint64_t tolerance = 30;
constexpr uint64_t refresh_interval = 512;

uint64_t
parse_number (const char *text, const char *name)
{
  std::string input (text);
  uint64_t value = 0;
  auto result = std::from_chars (input.data (), input.data () + input.size (),
                                 value);
  if (result.ec != std::errc () || result.ptr != input.data () + input.size ())
    throw std::invalid_argument (std::string ("invalid ") + name + ": " + input);
  return value;
}

std::ofstream
open_output (const fs::path &path)
{
  std::ofstream out (path);
  if (!out)
    throw std::runtime_error ("cannot open output: " + path.string ());
  out.exceptions (std::ios::badbit | std::ios::failbit);
  return out;
}

enum class Relation
{
  conflict,
  no_conflict,
  uncertain
};

const char *
relation_name (Relation relation)
{
  switch (relation)
    {
    case Relation::conflict:
      return "conflict";
    case Relation::no_conflict:
      return "no_conflict";
    case Relation::uncertain:
      return "uncertain";
    }
  throw std::logic_error ("invalid relation");
}

struct Bank
{
  uint64_t reference;
  uint64_t partner;
};

class Experiment
{
  re_gddr::ConflictProber &probe;
  const uint64_t range;
  const uint64_t step;
  const uint64_t threshold;

  uint64_t
  measure (uint64_t a, uint64_t b)
  {
    probe.set_addr_lst_host (0, a);
    probe.set_addr_lst_host (1, b);
    return probe.repeat_n_addr_exp ();
  }

  bool
  above_cutoff (uint64_t pair, uint64_t baseline) const
  {
    return pair > baseline && pair - baseline > threshold;
  }

public:
  Experiment (re_gddr::ConflictProber &p, uint64_t r, uint64_t s, uint64_t t)
      : probe (p), range (r), step (s), threshold (t)
  {
  }

  uint64_t
  self (uint64_t a)
  {
    return measure (a, a);
  }

  Relation
  classify (uint64_t a, uint64_t b)
  {
    if (a == b)
      return Relation::no_conflict;
    uint64_t conflicts = 0, nonconflicts = 0;
    for (uint64_t i = 0; i < confirmations; ++i)
      {
        uint64_t baseline = self (a);
        uint64_t pair = measure (a, b);
        uint64_t other_self = self (b);
        uint64_t difference = baseline > other_self ? baseline - other_self
                                                     : other_self - baseline;
        if (difference > tolerance)
          continue;
        if (above_cutoff (pair, baseline))
          ++conflicts;
        else
          ++nonconflicts;
      }
    if (conflicts >= required)
      return Relation::conflict;
    if (nonconflicts >= required)
      return Relation::no_conflict;
    return Relation::uncertain;
  }

  bool
  find_partner (uint64_t reference, uint64_t &partner)
  {
    uint64_t baseline = self (reference);
    uint64_t scanned = 0;
    for (uint64_t candidate = 0; candidate < range; candidate += step)
      {
        if (scanned++ % refresh_interval == 0)
          baseline = self (reference);
        if (candidate == reference
            || !above_cutoff (measure (reference, candidate), baseline))
          continue;
        if (classify (reference, candidate) == Relation::conflict)
          {
            partner = candidate;
            return true;
          }
      }
    return false;
  }

  std::vector<Bank>
  discover (uint64_t max_banks, uint64_t search_range)
  {
    std::vector<Bank> banks;
    uint64_t uncertain = 0, no_partner = 0;
    for (uint64_t candidate = 0;
         candidate < search_range && banks.size () < max_banks;
         candidate += step)
      {
        bool seen = false, ambiguous = false;
        for (const auto &bank : banks)
          {
            Relation first = classify (candidate, bank.reference);
            Relation second = classify (candidate, bank.partner);
            if (first == Relation::conflict || second == Relation::conflict)
              {
                seen = true;
                break;
              }
            if (first == Relation::uncertain || second == Relation::uncertain)
              ambiguous = true;
          }
        if (seen)
          continue;
        if (ambiguous)
          {
            ++uncertain;
            continue;
          }
        uint64_t partner;
        if (!find_partner (candidate, partner))
          {
            ++no_partner;
            continue;
          }
        banks.push_back ({ candidate, partner });
        std::cout << "candidate bank " << banks.size () << ": reference="
                  << candidate << " partner=" << partner << std::endl;
      }
    std::cout << "discovery uncertain=" << uncertain
              << " without_partner=" << no_partner << std::endl;
    return banks;
  }

  std::vector<uint64_t>
  scan (uint64_t reference, unsigned run)
  {
    std::vector<uint64_t> offsets;
    uint64_t baseline = self (reference);
    uint64_t scanned = 0, candidates = 0, controls = 0, control_spikes = 0;
    uint64_t min_base = std::numeric_limits<uint64_t>::max (), max_base = 0;
    for (uint64_t candidate = 0; candidate < range; candidate += step)
      {
        if (scanned++ % refresh_interval == 0)
          {
            baseline = self (reference);
            min_base = std::min (min_base, baseline);
            max_base = std::max (max_base, baseline);
            ++controls;
            if (above_cutoff (self (reference), baseline))
              ++control_spikes;
          }
        if (candidate == reference
            || !above_cutoff (measure (reference, candidate), baseline))
          continue;
        ++candidates;
        if (classify (reference, candidate) == Relation::conflict)
          offsets.push_back (candidate);
      }
    std::cout << "reference=" << reference << " scan=" << run
              << " candidates=" << candidates << " accepted=" << offsets.size ()
              << " local_base_ns=" << min_base << ".." << max_base
              << " self_control_spikes=" << control_spikes << "/" << controls
              << std::endl;
    return offsets;
  }

  void
  rows (const std::vector<uint64_t> &offsets, const fs::path &row_path,
        const fs::path &uncertain_path)
  {
    std::vector<std::vector<uint64_t>> groups;
    auto uncertain_file = open_output (uncertain_path);
    for (uint64_t offset : offsets)
      {
        bool placed = false, uncertain = false;
        size_t examined = 0;
        for (auto it = groups.rbegin (); it != groups.rend () && examined < 5;
             ++it, ++examined)
          {
            Relation relation = classify (offset, it->front ());
            if (relation == Relation::no_conflict)
              {
                it->push_back (offset);
                placed = true;
                break;
              }
            if (relation == Relation::uncertain)
              uncertain = true;
          }
        if (!placed && uncertain)
          uncertain_file << offset << '\n';
        else if (!placed)
          groups.push_back ({ offset });
      }
    auto out = open_output (row_path);
    std::map<size_t, size_t> sizes;
    for (const auto &group : groups)
      {
        ++sizes[group.size ()];
        for (uint64_t offset : group)
          out << offset << '\t';
        out << '\n';
      }
    std::cout << "rows=" << groups.size () << " group_sizes";
    for (const auto &entry : sizes)
      std::cout << " " << entry.first << ":" << entry.second;
    std::cout << std::endl;
  }
};

void
write_offsets (const fs::path &path, const std::vector<uint64_t> &offsets)
{
  auto out = open_output (path);
  for (uint64_t value : offsets)
    out << value << '\n';
}
}

int
main (int argc, char **argv)
{
  try
    {
      if (argc != 9)
        {
          std::cerr << "usage: same_allocation_map SIZE RANGE ITERATIONS STEP "
                       "THRESHOLD MAX_BANKS DISCOVERY_RANGE OUTPUT_DIR\n";
          return 2;
        }
      uint64_t size = parse_number (argv[1], "size");
      uint64_t range = parse_number (argv[2], "range");
      uint64_t iterations = parse_number (argv[3], "iterations");
      uint64_t step = parse_number (argv[4], "step");
      uint64_t threshold = parse_number (argv[5], "threshold");
      uint64_t max_banks = parse_number (argv[6], "max banks");
      uint64_t discovery_range = parse_number (argv[7], "discovery range");
      if (size < 128 || size % 128 != 0 || range == 0 || range > size || iterations == 0
          || step < 128 || step % 128 != 0 || threshold == 0 || max_banks == 0
          || discovery_range == 0 || discovery_range > range
          || size > std::numeric_limits<uint64_t>::max () - step
          || iterations > std::numeric_limits<uint64_t>::max () / 16)
        throw std::invalid_argument ("invalid size, range, iterations, step, threshold, bank count, or discovery range");
      fs::path output (argv[8]);
      if (fs::exists (output) && !fs::is_empty (output))
        throw std::runtime_error ("output directory is not empty: " + output.string ());
      fs::create_directories (output);
      re_gddr::ConflictProber probe (2, size, range, iterations, step);
      Experiment experiment (probe, range, step, threshold);
      uint64_t baseline = 0;
      for (int i = 0; i < 100000; ++i)
        baseline = experiment.self (0);
      std::cout << "one allocation, size=" << size << " range=" << range
                << " step=" << step << " threshold=" << threshold
                << " warmup_base_ns=" << baseline << std::endl;
      auto banks = experiment.discover (max_banks, discovery_range);
      if (banks.empty ())
        throw std::runtime_error ("no candidate bank with a confirmed conflict partner found");
      auto bank_file = open_output (output / "banks.txt");
      for (const auto &bank : banks)
        bank_file << bank.reference << '\t' << bank.partner << '\n';
      bank_file.close ();
      for (size_t i = 0; i < banks.size (); ++i)
        for (size_t j = i + 1; j < banks.size (); ++j)
          std::cout << "cross_reference=" << banks[i].reference << ","
                    << banks[j].reference << " result="
                    << relation_name (experiment.classify (
                           banks[i].reference, banks[j].reference))
                    << " (not an independently verified negative control)"
                    << std::endl;
      for (const auto &bank : banks)
        {
          std::string prefix = std::to_string (bank.reference);
          auto first = experiment.scan (bank.reference, 1);
          auto second = experiment.scan (bank.reference, 2);
          write_offsets (output / ("conf_" + prefix + "_run1.txt"), first);
          write_offsets (output / ("conf_" + prefix + "_run2.txt"), second);
          size_t intersection = 0;
          for (uint64_t value : first)
            if (std::binary_search (second.begin (), second.end (), value))
              ++intersection;
          size_t union_size = first.size () + second.size () - intersection;
          std::cout << "reference=" << bank.reference << " intersection="
                    << intersection << " union=" << union_size << " jaccard=";
          if (union_size)
            std::cout << static_cast<double> (intersection) / union_size;
          else
            std::cout << "undefined";
          std::cout << " partner_retest="
                    << relation_name (
                           experiment.classify (bank.reference, bank.partner))
                    << std::endl;
          if (first.empty ())
            throw std::runtime_error ("empty conflict set for reference " + prefix);
          experiment.rows (first, output / ("rows_" + prefix + ".txt"),
                           output / ("uncertain_" + prefix + ".txt"));
        }
      std::cout << "complete; outputs: " << output.string () << std::endl;
      return 0;
    }
  catch (const std::exception &error)
    {
      std::cerr << "same_allocation_map: " << error.what () << '\n';
      return 1;
    }
}
