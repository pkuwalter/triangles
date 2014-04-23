#include "gpu.h"

#include "gpu-thrust.h"
#include "timer.h"

#include <cuda_profiler_api.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <vector>
using namespace std;

#define NUM_THREADS 64
#define NUM_BLOCKS_GENERIC 112
#define NUM_BLOCKS_PER_MP 8

template<bool ZIPPED>
__global__ void CalculateNodePointers(int n, int m, int* edges, int* nodes) {
  int from = blockDim.x * blockIdx.x + threadIdx.x;
  int step = gridDim.x * blockDim.x;
  for (int i = from; i <= m; i += step) {
    int prev = i > 0 ? edges[ZIPPED ? (2 * (i - 1) + 1) : (m + i - 1)] : -1;
    int next = i < m ? edges[ZIPPED ? (2 * i + 1) : (m + i)] : n;
    for (int j = prev + 1; j <= next; ++j)
      nodes[j] = i;
  }
}

__global__ void CalculateFlags(int m, int* edges, int* pointers, bool* flags) {
  int from = blockDim.x * blockIdx.x + threadIdx.x;
  int step = gridDim.x * blockDim.x;
  for (int i = from; i < m; i += step) {
    int a = edges[2 * i];
    int b = edges[2 * i + 1];
    int deg_a = pointers[a + 1] - pointers[a];
    int deg_b = pointers[b + 1] - pointers[b];
    flags[i] = (deg_a < deg_b) || (deg_a == deg_b && a < b);
  }
}

__global__ void UnzipEdges(int m, int* edges, int* unzipped_edges) {
  int from = blockDim.x * blockIdx.x + threadIdx.x;
  int step = gridDim.x * blockDim.x;
  for (int i = from; i < m; i += step) {
    unzipped_edges[i] = edges[2 * i];
    unzipped_edges[m + i] = edges[2 * i + 1];
  }
}

__global__ void CalculateTriangles(
    int m, int* edges, int* pointers, uint64_t* results,
    int deviceCount = 1, int deviceIdx = 0) {
  int from = 
    gridDim.x * blockDim.x * deviceIdx +
    blockDim.x * blockIdx.x +
    threadIdx.x;
  int step = deviceCount * gridDim.x * blockDim.x;
  uint64_t count = 0;

  for (int i = from; i < m; i += step) {
    int u = edges[i], v = edges[m + i];

    int u_it = pointers[u], u_end = pointers[u + 1];
    int v_it = pointers[v], v_end = pointers[v + 1];

    int a = edges[u_it], b = edges[v_it]; 
    while (u_it < u_end && v_it < v_end) {
      int d = a - b;
      if (d <= 0)
        a = edges[++u_it];
      if (d >= 0)
        b = edges[++v_it];
      if (d == 0) 
        ++count;
    }
  }

  results[blockDim.x * blockIdx.x + threadIdx.x] = count;
}

void CudaAssert(cudaError_t status, const char* code, const char* file, int l) {
  if (status == cudaSuccess) return;
  cerr << "Cuda error: " << code << ", file " << file << ", line " << l << endl;
  exit(1);
}

#define CUCHECK(x) CudaAssert(x, #x, __FILE__, __LINE__)

int NumberOfMPs() {
  int dev, val;
  CUCHECK(cudaGetDevice(&dev));
  CUCHECK(cudaDeviceGetAttribute(&val, cudaDevAttrMultiProcessorCount, dev));
  return val;
}

uint64_t MultiGPUCalculateTriangles(
    int n, int m, int* dev_edges, int* dev_nodes, int device_count) {
  vector<int*> multi_dev_edges(device_count);
  vector<int*> multi_dev_nodes(device_count);

  multi_dev_edges[0] = dev_edges;
  multi_dev_nodes[0] = dev_nodes;

  for (int i = 1; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    CUCHECK(cudaMalloc(&multi_dev_edges[i], m * 2 * sizeof(int)));
    CUCHECK(cudaMalloc(&multi_dev_nodes[i], (n + 1) * sizeof(int)));
    int dst = i, src = (i + 1) >> 2;
    CUCHECK(cudaMemcpyPeer(
          multi_dev_edges[dst], dst, multi_dev_edges[src], src,
          m * 2 * sizeof(int)));
    CUCHECK(cudaMemcpyPeer(
          multi_dev_nodes[dst], dst, multi_dev_nodes[src], src,
          (n + 1) * sizeof(int)));
  }

  vector<int> NUM_BLOCKS(device_count);
  vector<uint64_t*> multi_dev_results(device_count); 

  for (int i = 0; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    NUM_BLOCKS[i] = NUM_BLOCKS_PER_MP * NumberOfMPs();
    CUCHECK(cudaMalloc(
          &multi_dev_results[i],
          NUM_BLOCKS[i] * NUM_THREADS * sizeof(uint64_t)));
  }

  for (int i = 0; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    CUCHECK(cudaFuncSetCacheConfig(CalculateTriangles, cudaFuncCachePreferL1));
    CalculateTriangles<<<NUM_BLOCKS[i], NUM_THREADS>>>(
        m, multi_dev_edges[i], multi_dev_nodes[i], multi_dev_results[i],
        device_count, i);
  }

  uint64_t result = 0;

  for (int i = 0; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    CUCHECK(cudaDeviceSynchronize());
    result += SumResults(NUM_BLOCKS[i] * NUM_THREADS, multi_dev_results[i]);
  }

  for (int i = 1; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    CUCHECK(cudaFree(multi_dev_edges[i]));
    CUCHECK(cudaFree(multi_dev_nodes[i]));
  }

  for (int i = 0; i < device_count; ++i) {
    CUCHECK(cudaSetDevice(i));
    CUCHECK(cudaFree(multi_dev_results[i]));
  }

  cudaSetDevice(0);
  return result;
}

uint64_t GpuEdgeIterator(const Edges& unordered_edges) {
  return GpuEdgeIterator(unordered_edges, 1);
}

uint64_t GpuEdgeIterator(const Edges& unordered_edges, int device_count) {
  Timer* timer = Timer::NewTimer();

  const int NUM_BLOCKS = NUM_BLOCKS_PER_MP * NumberOfMPs();

  timer->Done("Query number of MPs");

  int n = NumVertices(unordered_edges);
  int m = unordered_edges.size();

  timer->Done("Calculate number of vertices");

  int* dev_edges;
  bool* dev_flags;
  int* dev_nodes;
  uint64_t* dev_results;

  CUCHECK(cudaMalloc(&dev_edges, m * 2 * sizeof(int)));
  CUCHECK(cudaMalloc(&dev_flags, m * sizeof(bool)));
  CUCHECK(cudaMalloc(&dev_nodes, (n + 1) * sizeof(int)));
  CUCHECK(cudaMalloc(&dev_results, 
        NUM_BLOCKS * NUM_THREADS * sizeof(uint64_t)));

  timer->Done("Malloc");

  CUCHECK(cudaMemcpyAsync(dev_edges, unordered_edges.data(),
                          m * 2 * sizeof(int),
                          cudaMemcpyHostToDevice));
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Memcpy");

  SortEdges(m, dev_edges);
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Sort edges");

  CalculateNodePointers<true><<<NUM_BLOCKS, NUM_THREADS>>>(
      n, m, dev_edges, dev_nodes);
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Calculate node pointers (zipped)");

  CalculateFlags<<<NUM_BLOCKS, NUM_THREADS>>>(
      m, dev_edges, dev_nodes, dev_flags);
  RemoveMarkedEdges(m, dev_edges, dev_flags);
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Remove backward edges");

  m /= 2;
 
  int* dev_edges_unzipped = dev_edges + 2 * m;

  UnzipEdges<<<NUM_BLOCKS, NUM_THREADS>>>(m, dev_edges, dev_edges_unzipped);
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Unzip edges");

  CalculateNodePointers<false><<<NUM_BLOCKS, NUM_THREADS>>>(
      n, m, dev_edges_unzipped, dev_nodes);
  CUCHECK(cudaDeviceSynchronize());
  timer->Done("Calculate node pointers (unzipped)");

  uint64_t result = 0;

  if (device_count == 1) {
    cudaFuncSetCacheConfig(CalculateTriangles, cudaFuncCachePreferL1);
    cudaProfilerStart();
    CalculateTriangles<<<NUM_BLOCKS, NUM_THREADS>>>(
        m, dev_edges_unzipped, dev_nodes, dev_results);
    CUCHECK(cudaDeviceSynchronize());
    cudaProfilerStop();
    timer->Done("Calculate triangles");

    result = SumResults(NUM_BLOCKS * NUM_THREADS, dev_results);
    timer->Done("Reduce");
  } else {
    result = MultiGPUCalculateTriangles(
        n, m, dev_edges_unzipped, dev_nodes, device_count);
    timer->Done("Calculate triangles on multi GPU");
  }

  CUCHECK(cudaFree(dev_edges));
  CUCHECK(cudaFree(dev_flags));
  CUCHECK(cudaFree(dev_nodes));
  CUCHECK(cudaFree(dev_results));
  timer->Done("Free");

  delete timer;

  return result;
}
