#include "drama_conflict_prober.cuh"
#include <rh_utils.cuh>
#include <algorithm>
#include <iostream>
#include <vector>
namespace re_gddr
{

ConflictProber::ConflictProber (uint64_t n, uint64_t size, uint64_t range, uint64_t it,
                        uint64_t step)
    : m_n{ n }, m_size{ size }, m_range{ range }, m_it{ it }, m_step{ step }
{
  gpuErrchk (cudaMalloc (&mp_addr_layout, m_size));
  gpuErrchk (cudaMalloc (&mp_time_arr_device,
                         sizeof (uint64_t) * m_it * m_n));
  gpuErrchk (cudaMalloc (&mp_addr_lst_device, m_n * sizeof (uint8_t *)));
  mp_addr_lst_host = new uint8_t *[m_n];
  mp_time_arr_host = new uint64_t[m_it * m_n];
}

ConflictProber::~ConflictProber ()
{
  cudaFree (mp_addr_layout);
  cudaFree (mp_time_arr_device);
  cudaFree (mp_addr_lst_device);
  delete[] mp_addr_lst_host;
  delete[] mp_time_arr_host;
}

uint64_t
ConflictProber::get_addr_lst_elm (uint64_t idx)
{
  if (idx >= m_n)
    throw std::out_of_range ("Index greater than address list size");

  return mp_addr_lst_host[idx] - mp_addr_layout;
}

void
ConflictProber::set_addr_lst_host (uint64_t idx, uint64_t ofs)
{
  if (idx >= m_n)
    throw std::out_of_range ("Index greater than address list size");

  mp_addr_lst_host[idx] = mp_addr_layout + ofs;
}

uint64_t
ConflictProber::repeat_n_addr_exp (std::ofstream *file, int modifier)
{
  /* Copy the addresses to GPU usable memory */
  gpuErrchk (cudaMemcpy (mp_addr_lst_device, mp_addr_lst_host,
                         m_n * sizeof (uint8_t *),
                         cudaMemcpyHostToDevice));

  /* Run experiment EXP_IT times to avoid noise */
  for (uint64_t i = 0; i < m_it; i++)
      n_address_conflict_kernel<<<1, m_n>>> (
          mp_addr_lst_device, mp_time_arr_device + i * m_n, modifier);
  gpuErrchk (cudaGetLastError ());
  gpuErrchk (cudaDeviceSynchronize ());

  /* Copy the time values from GPU to HOST usable memory */
  gpuErrchk (cudaMemcpy (mp_time_arr_host, mp_time_arr_device,
                         sizeof (uint64_t) * m_it * m_n,
                         cudaMemcpyDeviceToHost));

  /*
   * Reduce repetitions independently for each address.  The old global
   * minimum mixed all addresses and repetitions, so one unusually fast
   * sample could hide a conflict.  A lower median rejects isolated timing
   * spikes while preserving delays that persist across repetitions.  Return
   * the larger address median so a conflict on either address is retained.
   */
  uint64_t robust_delay = 0;
  std::vector<uint64_t> samples (m_it);
  for (uint64_t address = 0; address < m_n; address++)
    {
      for (uint64_t iteration = 0; iteration < m_it; iteration++)
        samples[iteration] = mp_time_arr_host[iteration * m_n + address];

      std::sort (samples.begin (), samples.end ());
      uint64_t address_delay = samples[(m_it - 1) / 2];
      robust_delay = std::max (robust_delay, address_delay);
    }

  uint64_t delay = toNS (robust_delay);

  if (file)
    *file << delay << '\n';

  return delay;
}

/**
 * @brief Stores the time of uncached access of addr_access in time_arr.
 * This function requires synchronized access with __syncthreads, please
 * make sure no divergence happends on places where this function is called.
 *
 * @param addr_access address top access
 * @param time_arr place to store timing valueW
 */
__forceinline__ __device__ void
uncached_access_timing_device(uint8_t *addr_access, uint64_t *time_arr, int modifier)
{
  uint64_t temp __attribute__((unused)), clock_start, clock_end;
  asm volatile("{\n\t"
               "discard.global.L2 [%0], 128;\n\t"
               "}" ::"l"(addr_access));
  switch (modifier)
  {
    case 0:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
    case 1:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global.ca %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
    case 2:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global.cg %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
    case 3:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global.cs %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
    case 4:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global.cv %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
    case 5:
      clock_start = clock64();
      asm volatile("{\n\t"
                  "ld.u8.global.volatile %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_access));
      clock_end = clock64();
      break;
  }
  *addr_access = temp;
  *time_arr = clock_end - clock_start;
}

__global__ void n_address_conflict_kernel(uint8_t **addr_arr,
                                          uint64_t *time_arr,
                                          int modifier)
{
  uncached_access_timing_device(*(addr_arr + threadIdx.x),
                                time_arr + threadIdx.x,
                                modifier);
}

} // namespace re_gddr
