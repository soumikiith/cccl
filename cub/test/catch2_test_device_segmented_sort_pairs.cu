/******************************************************************************
 * Copyright (c) 2011-2024, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/
#include "catch2_radix_sort_helper.cuh"
// above header needs to be included first

#include <c2h/catch2_test_helper.h>
#include <catch2_segmented_sort_helper.cuh>

// FIXME: Graph launch disabled, algorithm syncs internally. WAR exists for device-launch, figure out how to enable for
// graph launch.

// TODO replace with DeviceSegmentedSort::SortPairs interface once https://github.com/NVIDIA/cccl/issues/50 is addressed
// Temporary wrapper that allows specializing the DeviceSegmentedSort algorithm for different offset types
template <bool IS_DESCENDING,
          typename KeyT,
          typename ValueT,
          typename BeginOffsetIteratorT,
          typename EndOffsetIteratorT,
          typename NumItemsT>
CUB_RUNTIME_FUNCTION _CCCL_FORCEINLINE static cudaError_t dispatch_segmented_sort_pairs_wrapper(
  void* d_temp_storage,
  size_t& temp_storage_bytes,
  const KeyT* d_keys_in,
  KeyT* d_keys_out,
  const ValueT* d_values_in,
  ValueT* d_values_out,
  NumItemsT num_items,
  NumItemsT num_segments,
  BeginOffsetIteratorT d_begin_offsets,
  EndOffsetIteratorT d_end_offsets,
  bool* selector,
  bool is_overwrite   = false,
  cudaStream_t stream = 0)
{
  cub::DoubleBuffer<KeyT> d_keys(const_cast<KeyT*>(d_keys_in), d_keys_out);
  cub::DoubleBuffer<ValueT> d_values(const_cast<ValueT*>(d_values_in), d_values_out);

  auto status = cub::
    DispatchSegmentedSort<IS_DESCENDING, KeyT, ValueT, NumItemsT, BeginOffsetIteratorT, EndOffsetIteratorT>::Dispatch(
      d_temp_storage,
      temp_storage_bytes,
      d_keys,
      d_values,
      num_items,
      num_segments,
      d_begin_offsets,
      d_end_offsets,
      is_overwrite,
      stream);
  if (status != cudaSuccess)
  {
    return status;
  }
  if (is_overwrite)
  {
    // Only write to selector in the DoubleBuffer invocation
    *selector = d_keys.Current() != d_keys_out;
  }
  return cudaSuccess;
}

// %PARAM% TEST_LAUNCH lid 0:1

DECLARE_LAUNCH_WRAPPER(dispatch_segmented_sort_pairs_wrapper<true>, dispatch_segmented_sort_pairs_descending);
DECLARE_LAUNCH_WRAPPER(dispatch_segmented_sort_pairs_wrapper<false>, dispatch_segmented_sort_pairs);

using pair_types =
  c2h::type_list<c2h::type_list<bool, std::uint8_t>,
                 c2h::type_list<std::int8_t, std::uint64_t>,
                 c2h::type_list<double, float>
#if TEST_HALF_T
                 ,
                 c2h::type_list<half_t, std::int8_t>
#endif
#if TEST_BF_T
                 ,
                 c2h::type_list<bfloat16_t, float>
#endif
                 >;

C2H_TEST("DeviceSegmentedSortPairs: No segments", "[pairs][segmented][sort][device]")
{
  // Type doesn't affect the escape logic, so it should be fine
  // to test only one set of types here.

  using KeyT   = std::uint8_t;
  using ValueT = std::uint8_t;

  const bool stable_sort     = GENERATE(unstable, stable);
  const bool sort_descending = GENERATE(ascending, descending);
  const bool sort_buffer     = GENERATE(pointers, double_buffer);

  cub::DoubleBuffer<KeyT> keys_buffer(nullptr, nullptr);
  cub::DoubleBuffer<ValueT> values_buffer(nullptr, nullptr);
  values_buffer.selector = 1;

  call_cub_segmented_sort_api(
    sort_descending,
    sort_buffer,
    stable_sort,
    static_cast<KeyT*>(nullptr),
    static_cast<KeyT*>(nullptr),
    static_cast<ValueT*>(nullptr),
    static_cast<ValueT*>(nullptr),
    int{},
    int{},
    nullptr,
    &keys_buffer.selector,
    &values_buffer.selector);

  REQUIRE(keys_buffer.selector == 0);
  REQUIRE(values_buffer.selector == 1);
}

C2H_TEST("DeviceSegmentedSortPairs: Empty segments", "[pairs][segmented][sort][device]")
{
  // Type doesn't affect the escape logic, so it should be fine
  // to test only one set of types here.

  using KeyT   = std::uint8_t;
  using ValueT = std::uint8_t;

  const int num_segments     = GENERATE(take(2, random(1 << 2, 1 << 22)));
  const bool sort_stable     = GENERATE(unstable, stable);
  const bool sort_descending = GENERATE(ascending, descending);
  const bool sort_buffer     = GENERATE(pointers, double_buffer);

  c2h::device_vector<int> offsets(num_segments + 1, int{});
  const int* d_offsets = thrust::raw_pointer_cast(offsets.data());

  cub::DoubleBuffer<KeyT> keys_buffer(nullptr, nullptr);
  cub::DoubleBuffer<ValueT> values_buffer(nullptr, nullptr);
  values_buffer.selector = 1;

  call_cub_segmented_sort_api(
    sort_descending,
    sort_buffer,
    sort_stable,
    static_cast<KeyT*>(nullptr),
    static_cast<KeyT*>(nullptr),
    static_cast<ValueT*>(nullptr),
    static_cast<ValueT*>(nullptr),
    int{},
    num_segments,
    d_offsets,
    &keys_buffer.selector,
    &values_buffer.selector);

  REQUIRE(keys_buffer.selector == 0);
  REQUIRE(values_buffer.selector == 1);
}

C2H_TEST("DeviceSegmentedSortPairs: Same size segments, derived keys/values",
         "[pairs][segmented][sort][device]",
         pair_types)
{
  using PairT  = c2h::get<0, TestType>;
  using KeyT   = c2h::get<0, PairT>;
  using ValueT = c2h::get<1, PairT>;

  const int segment_size = GENERATE_COPY(
    take(2, random(1 << 0, 1 << 5)), //
    take(2, random(1 << 5, 1 << 10)),
    take(2, random(1 << 10, 1 << 15)));

  const int segments = GENERATE_COPY(take(2, random(1 << 0, 1 << 5)), //
                                     take(2, random(1 << 5, 1 << 10)));

  test_same_size_segments_derived<KeyT, ValueT>(segment_size, segments);
}

C2H_TEST("DeviceSegmentedSortPairs: Randomly sized segments, derived keys/values",
         "[pairs][segmented][sort][device]",
         pair_types)
{
  using PairT  = c2h::get<0, TestType>;
  using KeyT   = c2h::get<0, PairT>;
  using ValueT = c2h::get<1, PairT>;

  const int max_items   = 1 << 22;
  const int max_segment = 6000;

  const int segments = GENERATE_COPY(
    take(2, random(1 << 0, 1 << 5)), //
    take(2, random(1 << 5, 1 << 10)),
    take(2, random(1 << 10, 1 << 15)),
    take(2, random(1 << 15, 1 << 20)));

  test_random_size_segments_derived<KeyT, ValueT>(C2H_SEED(1), max_items, max_segment, segments);
}

C2H_TEST("DeviceSegmentedSortPairs: Randomly sized segments, random keys/values",
         "[pairs][segmented][sort][device]",
         pair_types)
{
  using PairT  = c2h::get<0, TestType>;
  using KeyT   = c2h::get<0, PairT>;
  using ValueT = c2h::get<1, PairT>;

  const int max_items   = 1 << 22;
  const int max_segment = 6000;

  const int segments = GENERATE_COPY(take(2, random(1 << 15, 1 << 20)));

  test_random_size_segments_random<KeyT, ValueT>(C2H_SEED(1), max_items, max_segment, segments);
}

C2H_TEST("DeviceSegmentedSortPairs: Edge case segments, random keys/values",
         "[pairs][segmented][sort][device]",
         pair_types)
{
  using PairT  = c2h::get<0, TestType>;
  using KeyT   = c2h::get<0, PairT>;
  using ValueT = c2h::get<1, PairT>;

  test_edge_case_segments_random<KeyT, ValueT>(C2H_SEED(4));
}

C2H_TEST("DeviceSegmentedSortPairs: Unspecified segments, random key/values",
         "[pairs][segmented][sort][device]",
         pair_types)
{
  using PairT  = c2h::get<0, TestType>;
  using KeyT   = c2h::get<0, PairT>;
  using ValueT = c2h::get<1, PairT>;

  test_unspecified_segments_random<KeyT, ValueT>(C2H_SEED(4));
}

#if defined(CCCL_TEST_ENABLE_LARGE_SEGMENTED_SORT)

// we can reuse the same structure of DeviceSegmentedRadixSortPairs for simplicity
C2H_TEST("DeviceSegmentedSortPairs: very large num. items and num. segments",
         "[pairs][segmented][sort][device]",
         all_offset_types)
try
{
  using key_t                      = cuda::std::uint8_t; // minimize memory footprint to support a wider range of GPUs
  using value_t                    = cuda::std::uint8_t;
  using offset_t                   = c2h::get<0, TestType>;
  constexpr std::size_t Step       = 500;
  using segment_iterator_t         = segment_iterator<offset_t, Step>;
  constexpr std::size_t uint32_max = ::cuda::std::numeric_limits<std::uint32_t>::max();
  constexpr int num_key_seeds      = 1;
  constexpr int num_value_seeds    = 1;
  const bool is_descending         = GENERATE(false, true);
  const bool is_overwrite          = GENERATE(false, true);
  constexpr std::size_t num_items =
    (sizeof(offset_t) == 8) ? uint32_max + (1 << 20) : ::cuda::std::numeric_limits<offset_t>::max();
  const std::size_t num_segments = ::cuda::ceil_div(num_items, Step);
  CAPTURE(c2h::type_name<offset_t>(), num_items, num_segments, is_descending, is_overwrite);

  c2h::device_vector<key_t> in_keys(num_items);
  c2h::device_vector<value_t> in_values(num_items);
  c2h::gen(C2H_SEED(num_key_seeds), in_keys);
  c2h::gen(C2H_SEED(num_value_seeds), in_values);

  // Initialize the output vectors by copying the inputs since not all items may belong to a segment.
  c2h::device_vector<key_t> out_keys(num_items);
  c2h::device_vector<value_t> out_values(num_items);
  auto offsets =
    thrust::make_transform_iterator(thrust::make_counting_iterator(std::size_t{0}), segment_iterator_t{num_items});
  auto offsets_plus_1 = offsets + 1;
  bool* selector_ptr  = nullptr;
  if (is_overwrite)
  {
    REQUIRE(cudaSuccess == cudaMallocHost(&selector_ptr, sizeof(*selector_ptr)));
  }

  auto refs = segmented_radix_sort_reference(in_keys, in_values, is_descending, num_segments, offsets, offsets_plus_1);
  auto& ref_keys      = refs.first;
  auto& ref_values    = refs.second;
  auto out_keys_ptr   = thrust::raw_pointer_cast(out_keys.data());
  auto out_values_ptr = thrust::raw_pointer_cast(out_values.data());
  if (is_descending)
  {
    dispatch_segmented_sort_pairs_descending(
      thrust::raw_pointer_cast(in_keys.data()),
      out_keys_ptr,
      thrust::raw_pointer_cast(in_values.data()),
      out_values_ptr,
      static_cast<offset_t>(num_items),
      static_cast<offset_t>(num_segments),
      offsets,
      offsets_plus_1,
      selector_ptr,
      is_overwrite);
  }
  else
  {
    dispatch_segmented_sort_pairs(
      thrust::raw_pointer_cast(in_keys.data()),
      out_keys_ptr,
      thrust::raw_pointer_cast(in_values.data()),
      out_values_ptr,
      static_cast<offset_t>(num_items),
      static_cast<offset_t>(num_segments),
      offsets,
      offsets_plus_1,
      selector_ptr,
      is_overwrite);
  }
  if (is_overwrite)
  {
    if (*selector_ptr)
    {
      std::swap(out_keys, in_keys);
      std::swap(out_values, in_values);
    }
    REQUIRE(cudaFreeHost(selector_ptr) == cudaSuccess);
  }
  REQUIRE(ref_keys == out_keys);
  REQUIRE(ref_values == out_values);
}
catch (std::bad_alloc& e)
{
  std::cerr << "Skipping segmented sort test, insufficient GPU memory. " << e.what() << "\n";
}

C2H_TEST("DeviceSegmentedSort::SortPairs: very large segments", "[pairs][segmented][sort][device]", all_offset_types)
try
{
  using key_t                      = cuda::std::uint8_t; // minimize memory footprint to support a wider range of GPUs
  using value_t                    = cuda::std::uint8_t;
  using offset_t                   = c2h::get<0, TestType>;
  constexpr std::size_t uint32_max = ::cuda::std::numeric_limits<std::uint32_t>::max();
  constexpr int num_key_seeds      = 1;
  constexpr int num_value_seeds    = 1;
  const bool is_descending         = GENERATE(false, true);
  const bool is_overwrite          = GENERATE(false, true);
  constexpr std::size_t num_items =
    (sizeof(offset_t) == 8) ? uint32_max + (1 << 20) : ::cuda::std::numeric_limits<offset_t>::max();
  constexpr std::size_t num_segments = 2;
  CAPTURE(c2h::type_name<offset_t>(), num_items, is_descending, is_overwrite);

  c2h::device_vector<key_t> in_keys(num_items);
  c2h::device_vector<value_t> in_values(num_items);
  c2h::device_vector<key_t> out_keys(num_items);
  c2h::gen(C2H_SEED(num_key_seeds), in_keys);
  c2h::gen(C2H_SEED(num_value_seeds), in_values);
  c2h::device_vector<value_t> out_values(num_items);
  c2h::device_vector<offset_t> offsets(num_segments + 1);
  offsets[0]         = 0;
  offsets[1]         = static_cast<offset_t>(num_items);
  offsets[2]         = static_cast<offset_t>(num_items);
  bool* selector_ptr = nullptr;
  if (is_overwrite)
  {
    REQUIRE(cudaSuccess == cudaMallocHost(&selector_ptr, sizeof(*selector_ptr)));
  }

  auto refs = segmented_radix_sort_reference(
    in_keys, in_values, is_descending, num_segments, offsets.cbegin(), offsets.cbegin() + 1);
  auto& ref_keys      = refs.first;
  auto& ref_values    = refs.second;
  auto out_keys_ptr   = thrust::raw_pointer_cast(out_keys.data());
  auto out_values_ptr = thrust::raw_pointer_cast(out_values.data());
  if (is_descending)
  {
    dispatch_segmented_sort_pairs_descending(
      thrust::raw_pointer_cast(in_keys.data()),
      out_keys_ptr,
      thrust::raw_pointer_cast(in_values.data()),
      out_values_ptr,
      static_cast<offset_t>(num_items),
      static_cast<offset_t>(num_segments),
      thrust::raw_pointer_cast(offsets.data()),
      offsets.cbegin() + 1,
      selector_ptr,
      is_overwrite);
  }
  else
  {
    dispatch_segmented_sort_pairs(
      thrust::raw_pointer_cast(in_keys.data()),
      out_keys_ptr,
      thrust::raw_pointer_cast(in_values.data()),
      out_values_ptr,
      static_cast<offset_t>(num_items),
      static_cast<offset_t>(num_segments),
      thrust::raw_pointer_cast(offsets.data()),
      offsets.cbegin() + 1,
      selector_ptr,
      is_overwrite);
  }
  if (is_overwrite)
  {
    if (*selector_ptr)
    {
      std::swap(out_keys, in_keys);
      std::swap(out_values, in_values);
    }
    REQUIRE(cudaFreeHost(selector_ptr) == cudaSuccess);
  }
  REQUIRE(ref_keys == out_keys);
  REQUIRE(ref_values == out_values);
}
catch (std::bad_alloc& e)
{
  std::cerr << "Skipping segmented sort test, insufficient GPU memory. " << e.what() << "\n";
}

#endif // defined(CCCL_TEST_ENABLE_LARGE_SEGMENTED_SORT)
