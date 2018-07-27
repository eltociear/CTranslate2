#include "ctranslate2/primitives/gpu_cuda.h"

#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <thrust/device_vector.h>

#include "ctranslate2/types.h"
#include "ctranslate2/cuda/utils.h"

namespace ctranslate2 {

  template <typename T, typename UnaryFunction>
  void unary_transform(const T* x, T* y, size_t size, UnaryFunction op) {
    thrust::transform(thrust::cuda::par.on(cuda::get_cuda_stream()), x, x + size, y, op);
  }

  template <typename T, typename BinaryFunction>
  void binary_transform(const T* a, const T* b, T* c, size_t size, BinaryFunction op) {
    thrust::transform(thrust::cuda::par.on(cuda::get_cuda_stream()), a, a + size, b, c, op);
  }

  // perm_fun is a functor that takes the index in the permuted iterator and
  // return the index in the original iterator.
  template <typename T, typename PermFunction>
  void permute(const T* x, T* y, size_t size, PermFunction perm_fun) {
    auto ind_it = thrust::counting_iterator<size_t>(0);
    auto perm_ind_it = thrust::make_transform_iterator(ind_it, perm_fun);
    auto perm_it = thrust::make_permutation_iterator(x, perm_ind_it);
    thrust::copy_n(thrust::cuda::par.on(cuda::get_cuda_stream()), perm_it, size, y);
  }


  template<>
  void* primitives<Device::CUDA>::alloc_data(size_t size) {
    void* data = nullptr;
    CUDA_CHECK(cudaMalloc(&data, size));
    return data;
  }

  template<>
  void primitives<Device::CUDA>::free_data(void* data) {
    CUDA_CHECK(cudaFree(data));
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::fill(T* x, T a, size_t size) {
    thrust::fill_n(thrust::cuda::par.on(cuda::get_cuda_stream()), x, size, a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T),
                               cudaMemcpyDeviceToDevice, cuda::get_cuda_stream()));
  }

  template<>
  template <typename T>
  T primitives<Device::CUDA>::sum(const T* array, size_t size) {
    return thrust::reduce(thrust::cuda::par.on(cuda::get_cuda_stream()), array, array + size);
  }

  template<>
  template <typename T>
  size_t primitives<Device::CUDA>::max_element(const T* array, size_t size) {
    const auto* max = thrust::max_element(thrust::cuda::par.on(cuda::get_cuda_stream()),
                                          array, array + size);
    return static_cast<size_t>(max - array);
  }

  template<>
  template <typename T>
  T primitives<Device::CUDA>::max(const T* array, size_t size) {
    thrust::device_ptr<const T> array_ptr(array);
    return *thrust::max_element(thrust::cuda::par.on(cuda::get_cuda_stream()),
                                array_ptr, array_ptr + size);
  }

  template<>
  template <typename T, typename I>
  void primitives<Device::CUDA>::topk(const T* x, T* val, I* ind, size_t k, size_t size) {
    static thread_local T* keys = nullptr;
    static thread_local I* values = nullptr;
    static thread_local size_t alloc_size = 0;

    if (size > alloc_size) {
      CUDA_CHECK(cudaFree(keys));
      CUDA_CHECK(cudaMalloc(&keys, size * sizeof (T)));
      CUDA_CHECK(cudaFree(values));
      CUDA_CHECK(cudaMalloc(&values, size * sizeof (I)));
      alloc_size = size;
    }

    copy(x, keys, size);
    thrust::sequence(thrust::cuda::par.on(cuda::get_cuda_stream()), values, values + size);
    thrust::sort_by_key(thrust::cuda::par.on(cuda::get_cuda_stream()),
                        keys, keys + size, values, thrust::greater<T>());
    copy(keys, val, k);
    copy(values, ind, k);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add(T a, const T* x, T* y, size_t size) {
    unary_transform(x, y, size, thrust::placeholders::_1 + a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::plus<T>());
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::sub(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::minus<T>());
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul(T a, const T* x, T* y, size_t size) {
    unary_transform(x, y, size, thrust::placeholders::_1 * a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::multiplies<T>());
  }

  struct relu_func : public thrust::unary_function<float, float> {
    __host__ __device__
    float operator()(float x) { return fmaxf(x, 0); }
  };

  template<>
  template<>
  void primitives<Device::CUDA>::relu(const float* x, float* y, size_t size) {
    unary_transform(x, y, size, relu_func());
  }

  template <typename T>
  struct perm_indices_2d : public thrust::unary_function<T, T> {
    T _rows, _cols;
    perm_indices_2d(T rows, T cols)
      : _rows(rows)
      , _cols(cols) {
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _rows;
      const T i1 = i % _rows;
      return i1 * _cols + i0;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_2d(const DataType* a, const IndexType* dims, DataType* b) {
    permute(a, b, dims[0] * dims[1], perm_indices_2d<IndexType>(dims[0], dims[1]));
  }

  template <typename T>
  struct perm_indices_3d : public thrust::unary_function<T, T> {
    T _a_ps0, _a_ps1, _a_ps2; // Permuted strides of the original array.
    T _b_d0, _b_d1, _b_d2;    // Dimension of the permutated array.
    T _b_s0, _b_s1, _b_s2;    // Strides of the permutated array.
    perm_indices_3d(const T* dims, const T* perm) {
      const size_t a_stride[3] = {dims[1] * dims[2], dims[2], 1};
      _a_ps0 = a_stride[perm[0]];
      _a_ps1 = a_stride[perm[1]];
      _a_ps2 = a_stride[perm[2]];
      _b_d0 = dims[perm[0]];
      _b_d1 = dims[perm[1]];
      _b_d2 = dims[perm[2]];
      _b_s0 = _b_d1 * _b_d2;
      _b_s1 = _b_d2;
      _b_s2 = 1;
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _b_s0;
      const T i1 = i / _b_s1 % _b_d1;
      const T i2 = i % _b_d2;
      return i0 * _a_ps0 + i1 * _a_ps1 + i2 * _a_ps2;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_3d(const DataType* a,
                                              const IndexType* dims,
                                              const IndexType* perm,
                                              DataType* b) {
    permute(a, b, dims[0] * dims[1] * dims[2], perm_indices_3d<IndexType>(dims, perm));
  }

  template <typename T>
  struct perm_indices_4d : public thrust::unary_function<T, T> {
    T _a_ps0, _a_ps1, _a_ps2, _a_ps3; // Permuted strides of the original array.
    T _b_d0, _b_d1, _b_d2, _b_d3;    // Dimension of the permutated array.
    T _b_s0, _b_s1, _b_s2, _b_s3;    // Strides of the permutated array.
    perm_indices_4d(const T* dims, const T* perm) {
      const size_t a_stride[4] = {dims[1] * dims[2] * dims[3], dims[2] * dims[3], dims[3], 1};
      _a_ps0 = a_stride[perm[0]];
      _a_ps1 = a_stride[perm[1]];
      _a_ps2 = a_stride[perm[2]];
      _a_ps3 = a_stride[perm[3]];
      _b_d0 = dims[perm[0]];
      _b_d1 = dims[perm[1]];
      _b_d2 = dims[perm[2]];
      _b_d3 = dims[perm[3]];
      _b_s0 = _b_d1 * _b_d2 * _b_d3;
      _b_s1 = _b_d2 * _b_d3;
      _b_s2 = _b_d3;
      _b_s3 = 1;
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _b_s0;
      const T i1 = i / _b_s1 % _b_d1;
      const T i2 = i / _b_s2 % _b_d2;
      const T i3 = i % _b_d3;
      return i0 * _a_ps0 + i1 * _a_ps1 + i2 * _a_ps2 * i3 * _a_ps3;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_4d(const DataType* a,
                                              const IndexType* dims,
                                              const IndexType* perm,
                                              DataType* b) {
    permute(a, b, dims[0] * dims[1] * dims[2] * dims[3], perm_indices_4d<IndexType>(dims, perm));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm(const float* a, const float* b,
                                      bool transpose_a, bool transpose_b,
                                      size_t m, size_t n, size_t k,
                                      float alpha, float beta,
                                      float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    CUBLAS_CHECK(cublasSgemm(cuda::get_cublas_handle(),
                             transb, transa,
                             n, m, k,
                             &alpha,
                             b, ldb,
                             a, lda,
                             &beta,
                             c, ldc));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm_batch(const float* a, const float* b,
                                            bool transpose_a, bool transpose_b,
                                            size_t batch_size,
                                            size_t m, size_t n, size_t k,
                                            float alpha, float beta,
                                            float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    const float** a_array = new const float*[batch_size];
    const float** b_array = new const float*[batch_size];
    float** c_array = new float*[batch_size];

    for (size_t i = 0; i < batch_size; ++i) {
      a_array[i] = a + (i * m * k);
      b_array[i] = b + (i * k * n);
      c_array[i] = c + (i * m * n);
    }

    static thread_local const float** a_array_device = nullptr;
    static thread_local const float** b_array_device = nullptr;
    static thread_local float** c_array_device = nullptr;
    static thread_local size_t alloc_size = 0;

    const size_t array_size = batch_size * sizeof (float*);

    if (array_size > alloc_size) {
      CUDA_CHECK(cudaFree(a_array_device));
      CUDA_CHECK(cudaFree(b_array_device));
      CUDA_CHECK(cudaFree(c_array_device));
      CUDA_CHECK(cudaMalloc(&a_array_device, array_size));
      CUDA_CHECK(cudaMalloc(&b_array_device, array_size));
      CUDA_CHECK(cudaMalloc(&c_array_device, array_size));
      alloc_size = array_size;
    }

    cross_device_primitives<Device::CPU, Device::CUDA>::copy(a_array, a_array_device, batch_size);
    cross_device_primitives<Device::CPU, Device::CUDA>::copy(b_array, b_array_device, batch_size);
    cross_device_primitives<Device::CPU, Device::CUDA>::copy(c_array, c_array_device, batch_size);

    delete [] a_array;
    delete [] b_array;
    delete [] c_array;

    CUBLAS_CHECK(cublasSgemmBatched(cuda::get_cublas_handle(),
                                    transb, transa,
                                    n, m, k,
                                    &alpha,
                                    b_array_device, ldb,
                                    a_array_device, lda,
                                    &beta,
                                    c_array_device, ldc,
                                    batch_size));
  }

  struct exp_func : public thrust::unary_function<float, float> {
    __host__ __device__
    float operator()(float x) { return expf(x); }
  };

  template<>
  template<>
  void primitives<Device::CUDA>::exp(const float* x, float* y, size_t size) {
    unary_transform(x, y, size, exp_func());
  }

  struct pow_func : public thrust::unary_function<float, float> {
    float _power;
    pow_func(float power)
      : _power(power) {
    }
    __host__ __device__
    float operator()(float x) { return powf(x, _power); }
  };

  template<>
  template<>
  void primitives<Device::CUDA>::pow(const float* x, float* y, float power, size_t size) {
    unary_transform(x, y, size, pow_func(power));
  }


  template<>
  template <typename T>
  void cross_device_primitives<Device::CPU, Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyHostToDevice, cuda::get_cuda_stream()));
  }

  template<>
  template <typename T>
  void cross_device_primitives<Device::CUDA, Device::CPU>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyDeviceToHost, cuda::get_cuda_stream()));
  }

#define DECLARE_IMPL(T)                                                 \
  template void                                                         \
  primitives<Device::CUDA>::fill(T* x, T a, size_t size);               \
  template void                                                         \
  primitives<Device::CUDA>::copy<T>(const T* x, T* y, size_t size);     \
  template T                                                            \
  primitives<Device::CUDA>::sum(const T* array, size_t size);           \
  template size_t                                                       \
  primitives<Device::CUDA>::max_element(const T* array, size_t size);   \
  template T                                                            \
  primitives<Device::CUDA>::max(const T* array, size_t size);           \
  template void                                                         \
  primitives<Device::CUDA>::topk(const T* x, T* values, int* indices, size_t k, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::add(T a, const T* x, T* y, size_t size);    \
  template void                                                         \
  primitives<Device::CUDA>::add(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::sub(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::mul(T a, const T* x, T* y, size_t size);    \
  template void                                                         \
  primitives<Device::CUDA>::mul(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::transpose_2d(const T* a, const size_t* dims, T* b); \
  template void                                                         \
  primitives<Device::CUDA>::transpose_3d(const T* a,                    \
                                         const size_t* dims,            \
                                         const size_t* perm,            \
                                         T* b);                         \
  template void                                                         \
  primitives<Device::CUDA>::transpose_4d(const T* a,                    \
                                         const size_t* dims,            \
                                         const size_t* perm,            \
                                         T* b);                         \
  template void                                                         \
  cross_device_primitives<Device::CPU, Device::CUDA>::copy<T>(const T*, T*, size_t); \
  template void                                                         \
  cross_device_primitives<Device::CUDA, Device::CPU>::copy<T>(const T*, T*, size_t);

  DECLARE_ALL_TYPES(DECLARE_IMPL)

}
