#include <torch/extension.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <alloca.h>

#include <iostream>
using namespace torch::indexing;

#define BLOCK_SIZE 8

template <typename scalar_t >
__global__ void sparse_accumulation_cuda_forward_kernel(
    scalar_t* __restrict__ output,
    const scalar_t* __restrict__ X1,
    const scalar_t* __restrict__ X2,
    const int64_t* __restrict__ idx_output,
    const int64_t* __restrict__ idx_1,
    const int64_t* __restrict__ idx_2,
    const scalar_t* __restrict__ multipliers,
    const int output_size,
    const int X1_third_size,
    const int X2_third_size,
    const int nx,
    const int ny,
    const int nz) {


    extern __shared__ float buffer_multipliers[];
    //float* buffer_multipliers = buffer_initial + BLOCK_SIZE * BLOCK_SIZE * output_size + BLOCK_SIZE * BLOCK_SIZE * X1_third_size + BLOCK_SIZE * BLOCK_SIZE * X2_third_size;
    float* buffer_idx_output_raw = buffer_multipliers + nz;
    int* buffer_idx_output = reinterpret_cast<int*>(buffer_idx_output_raw);
    int* buffer_idx_X1 = buffer_idx_output + nz;
    int* buffer_idx_X2 = buffer_idx_X1 + nz;

    int i = threadIdx.x + blockDim.x * blockIdx.x;
    int j = threadIdx.y + blockDim.y * blockIdx.y;
    
    int single_multipliers_block_size = (nz / (BLOCK_SIZE * BLOCK_SIZE)) + 1;
    int total_thread_idx = threadIdx.x * BLOCK_SIZE + threadIdx.y;
    int multipliers_pos_from = total_thread_idx * single_multipliers_block_size;
    int multipliers_pos_to = (total_thread_idx + 1) * single_multipliers_block_size;
    if (multipliers_pos_to > nz) {
      multipliers_pos_to = nz;
    }

    int delta_now_X1 = j*X1_third_size + i*ny*X1_third_size;
    int delta_now_output =  j*output_size+  i*output_size*ny;
    int delta_now_X2 = j*X2_third_size + i*ny*X2_third_size;
    
    int delta_buffer_output = (BLOCK_SIZE * threadIdx.x + threadIdx.y) * output_size;
    int delta_buffer_X1 = (BLOCK_SIZE * threadIdx.x + threadIdx.y) * X1_third_size;
    int delta_buffer_X2 = (BLOCK_SIZE * threadIdx.x + threadIdx.y) * X2_third_size;
    
    for (int active_index = multipliers_pos_from; active_index < multipliers_pos_to; ++active_index) {
        buffer_multipliers[active_index] = multipliers[active_index];
        buffer_idx_output[active_index] = idx_output[active_index];
        buffer_idx_X1[active_index] = idx_1[active_index];
        buffer_idx_X2[active_index] = idx_2[active_index];
    }
   

    auto output_final = output + delta_now_output;
    auto X1_final = X1 + delta_now_X1;
    auto X2_final = X2 + delta_now_X2;
    __syncthreads();

   
    float buffer_output_final[17];
    float buffer_X1_final[17];
    float buffer_X2_final[17];
   
    if (i<nx && j<ny) {
      //printf("in kernel i %d  j %d\n",i,j) ;
      for (int z_output = 0; z_output < output_size; ++z_output) {
        buffer_output_final[z_output] = 0.0;
      }
      
      for (int X1_index = 0; X1_index < X1_third_size; ++X1_index) {
        buffer_X1_final[X1_index] = X1_final[X1_index];
      }

      for (int X2_index = 0; X2_index < X2_third_size; ++X2_index) {
        buffer_X2_final[X2_index] = X2_final[X2_index];
      }

     
      int z_output, z_X1, z_X2;
      for (int z = 0 ; z < nz ; ++z){
        z_output = buffer_idx_output[z];
        z_X1 = buffer_idx_X1[z];
        z_X2 = buffer_idx_X2[z];
        buffer_output_final[z_output] += buffer_X1_final[z_X1]*\
                                buffer_X2_final[z_X2]*buffer_multipliers[z];
        
      };
      
      for (int z_output = 0; z_output < output_size; ++z_output) {
        output_final[z_output] = buffer_output_final[z_output];
      };
    };
}

template <typename scalar_t>
__global__ void sparse_accumulation_cuda_backward_kernel(
    scalar_t* __restrict__ d_X1,
    scalar_t* __restrict__ d_X2,
    const scalar_t* __restrict__ d_output,
    const scalar_t* __restrict__ X1,
    const scalar_t* __restrict__ X2,
    const int64_t* __restrict__ idx_output,
    const int64_t* __restrict__ idx_1,
    const int64_t* __restrict__ idx_2,
    const scalar_t* __restrict__ multipliers,
    const int output_size,
    const int X1_third_size,
    const int X2_third_size,
    const int nx,
    const int ny,
    const int nz
    ) {
    int i = threadIdx.x + blockDim.x * blockIdx.x ;
    int j = threadIdx.y + blockDim.y * blockIdx.y ;

    if (i<nx && j<ny) {
      for (auto z = 0 ; z < nz ; ++z){
        int z_output = idx_output[z];
        int z_X1 = idx_1[z] ;
        int z_X2 = idx_2[z] ;

        int pos_X1 = z_X1 + j*X1_third_size + i*ny*X1_third_size ;
        int pos_output = z_output+ j*output_size+  i*output_size*ny ;
        int pos_X2 = z_X2 + j*X2_third_size + i*ny*X2_third_size ;
        auto grad_multi = d_output[pos_output] * multipliers[z];
        d_X1[pos_X1] += grad_multi*X2[pos_X2]; 
        d_X2[pos_X2] += grad_multi*X1[pos_X1];
      };
    };
  }


std::vector<torch::Tensor> sparse_accumulation_cuda_forward(
    torch::Tensor X1,
    torch::Tensor X2,
    torch::Tensor idx_output,
    int output_size,
    torch::Tensor idx_1,
    torch::Tensor idx_2,
    torch::Tensor multipliers)
    {
  //auto output = torch::zeros_like(X1);
  auto output = torch::zeros({X1.sizes()[0], X1.sizes()[1], output_size}, 
            torch::TensorOptions()
            .dtype(X1.dtype())
            .device(X1.device())); 

  auto X1_third_size = X1.sizes()[2]; 
  auto X2_third_size = X2.sizes()[2]; 
  const auto batch_sizex = output.sizes()[0];
  const auto batch_sizey = output.sizes()[1];
  const auto batch_sizez = idx_output.sizes()[0];

  auto nx = batch_sizex ; 
  auto ny = batch_sizey ; 
  auto nz = batch_sizez ; 
  auto threads = 124;
  //const dim3 blocks((n+threads-1)/threads, batch_size);
  //auto blocks = (n+threads-1)/threads;

  //AT_DISPATCH_FLOATING_TYPES(output.type(), "sparse_accumulation_forward_cuda", ([&] {
  //  sparse_accumulation_cuda_forward_kernel<scalar_t><<<blocks, threads>>>(
  //      output.data<scalar_t>(),
  //      X1.data<scalar_t>(),
  //      n1,
  //      n2,
  //      );
  //}));

  auto find_num_blocks = [](int x, int bdim) {return (x+bdim-1)/bdim;};
  dim3 block_dim(BLOCK_SIZE, BLOCK_SIZE);
  int nbx = find_num_blocks(nx, block_dim.x);
  int nby = find_num_blocks(ny, block_dim.y);
  int nbz = find_num_blocks(nz, block_dim.z);
  dim3 grid_dim(nbx, nby);


  int multipliers_size = multipliers.sizes()[0] * sizeof(float);
  int index_size = idx_output.sizes()[0] * sizeof(int);

  int total_buf_size = multipliers_size + index_size * 3;
  
  AT_DISPATCH_FLOATING_TYPES(output.type(), "sparse_accumulation_forward_cuda", ([&] {
  sparse_accumulation_cuda_forward_kernel<scalar_t><<<grid_dim, block_dim, total_buf_size>>>(
      output.data<scalar_t>(),
      X1.data<scalar_t>(),
      X2.data<scalar_t>(),
      idx_output.data<int64_t>(),
      idx_1.data<int64_t>(),
      idx_2.data<int64_t>(),
      multipliers.data<scalar_t>(),
      output_size,
      X1_third_size,
      X2_third_size,
      nx,
      ny,
      nz
      );
  }));

  return {output};
}

std::vector<torch::Tensor> sparse_accumulation_cuda_backward(
    torch::Tensor d_output,
    torch::Tensor X1,
    torch::Tensor X2,
    torch::Tensor idx_output,
    torch::Tensor idx_1,
    torch::Tensor idx_2, 
    torch::Tensor multipliers)
    {
    auto d_X1 = torch::zeros_like(X1);
    auto d_X2 = torch::zeros_like(X2); 

    auto X1_third_size = X1.sizes()[2]; 
    auto X2_third_size = X2.sizes()[2]; 
    const auto nx = d_output.sizes()[0]    ;
    const auto ny = d_output.sizes()[1]    ;
    const auto output_size = d_output.sizes()[2] ;
    const auto nz = idx_output.sizes()[0];

    auto find_num_blocks = [](int x, int bdim) {return (x+bdim-1)/bdim;};
    dim3 block_dim(BLOCK_SIZE, BLOCK_SIZE);
    int nbx = find_num_blocks(nx, block_dim.x);
    int nby = find_num_blocks(ny, block_dim.y);
    dim3 grid_dim(nbx, nby);



    AT_DISPATCH_FLOATING_TYPES(X1.type(), "sparse_accumulation_backward_cuda", ([&] {
      sparse_accumulation_cuda_backward_kernel<scalar_t><<<grid_dim, block_dim>>>(
        d_X1.data<scalar_t>(),
        d_X2.data<scalar_t>(),
        d_output.data<scalar_t>(),
        X1.data<scalar_t>(),
        X2.data<scalar_t>(),
        idx_output.data<int64_t>(),
        idx_1.data<int64_t>(),
        idx_2.data<int64_t>(),
        multipliers.data<scalar_t>(),
        output_size,
        X1_third_size,
        X2_third_size,
        nx,
        ny,
        nz
        );
    }));
    return {d_X1, d_X2};

}

#define CHECK_CUDA(x) TORCH_CHECK(x.device().is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) TORCH_CHECK(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) CHECK_CUDA(x); CHECK_CONTIGUOUS(x)

std::vector<torch::Tensor> sparse_accumulation_gpu_forward(
      torch::Tensor X1,
      torch::Tensor X2,
      torch::Tensor idx_output,
      int64_t output_size,
      torch::Tensor idx_1,
      torch::Tensor idx_2,
      torch::Tensor multipliers){

  CHECK_INPUT(X1);
  CHECK_INPUT(X2);
  CHECK_INPUT(idx_output);
  //CHECK_INPUT(output_size);
  CHECK_INPUT(idx_1);
  CHECK_INPUT(idx_2);
  CHECK_INPUT(multipliers);

  return sparse_accumulation_cuda_forward(X1,X2,idx_output,output_size,idx_1,idx_2,multipliers);
}

std::vector<torch::Tensor> sparse_accumulation_gpu_backward(
  torch::Tensor d_output,
  torch::Tensor X1,
  torch::Tensor X2,
  torch::Tensor idx_output,
  torch::Tensor idx_1,
  torch::Tensor idx_2, 
  torch::Tensor multipliers
    ) {
  CHECK_INPUT(d_output);
  CHECK_INPUT(X1);
  CHECK_INPUT(X2);
  CHECK_INPUT(idx_output);
  CHECK_INPUT(idx_1);
  CHECK_INPUT(idx_2 );
  CHECK_INPUT(multipliers);

  return sparse_accumulation_cuda_backward(d_output,X1,X2,idx_output,idx_1,idx_2,multipliers);
}

//PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
//  m.def("forward", &sparse_accumulation_gpu_forward,  "Sparse Accumulation forward (CUDA)");
//  m.def("backward", &sparse_accumulation_gpu_forward, "Sparse Accumulation backward (CUDA)");
//}

TORCH_LIBRARY(sparse_accumulation_cuda, m) {
    m.def("forward", sparse_accumulation_gpu_forward);
    m.def("backward", sparse_accumulation_gpu_backward);
}