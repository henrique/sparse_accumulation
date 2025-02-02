#include <torch/extension.h>

#include <cuda.h>
#include <cuda_runtime.h>

#include <iostream>
using namespace torch::indexing;
#define BLOCK_SIZE 16

template <typename scalar_t >
__global__ void sparse_accumulation_cuda_forward_kernel_grpwrites(
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
    
    extern __shared__ char buffer[];
    // offset (in bytes) of the first available slot in the shared memory buffer
    size_t offset = 0;

    scalar_t* buffer_X1 = reinterpret_cast<scalar_t*>(buffer + offset);
    offset += blockDim.x * blockDim.y * X1_third_size * sizeof(scalar_t);

    scalar_t* buffer_X2 = reinterpret_cast<scalar_t*>(buffer + offset);
    offset += blockDim.x * blockDim.y * X2_third_size * sizeof(scalar_t);

    scalar_t* buffer_multipliers = reinterpret_cast<scalar_t*>(buffer + offset);
    offset += nz * sizeof(scalar_t);

    int32_t* buffer_idx_output = reinterpret_cast<int32_t*>(buffer + offset);
    offset += nz * sizeof(int32_t);

    int32_t* buffer_idx_X1 = reinterpret_cast<int32_t*>(buffer + offset);
    offset += nz * sizeof(int32_t);

    int32_t* buffer_idx_X2 = reinterpret_cast<int32_t*>(buffer + offset);
    offset += nz * sizeof(int32_t);
    
    int single_multipliers_block_size = (nz / (blockDim.x * blockDim.y)) + 1;
    int total_thread_idx = threadIdx.x * blockDim.y + threadIdx.y;
    int multipliers_pos_from = total_thread_idx * single_multipliers_block_size;
    int multipliers_pos_to = (total_thread_idx + 1) * single_multipliers_block_size;
    if (multipliers_pos_to > nz) {
        multipliers_pos_to = nz;
    }
    for (int active_index = multipliers_pos_from; active_index < multipliers_pos_to; ++active_index) {
        buffer_multipliers[active_index] = multipliers[active_index];
        buffer_idx_output[active_index] = idx_output[active_index];
        buffer_idx_X1[active_index] = idx_1[active_index];
        buffer_idx_X2[active_index] = idx_2[active_index];
    }
    __syncthreads();

    int delta_buffer_X1 = (blockDim.y * threadIdx.x + threadIdx.y) * X1_third_size;
    int delta_buffer_X2 = (blockDim.y * threadIdx.x + threadIdx.y) * X2_third_size;

    scalar_t* my_buffer_X1 = buffer_X1 + delta_buffer_X1;
    scalar_t* my_buffer_X2 = buffer_X2 + delta_buffer_X2;

    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    int dimension_loop = (nx*ny) / blockDim.x +1 ; 
    
    int init = threadIdx.x * dimension_loop ;

    int output_index_z = blockIdx.x;

    int loopcount = nz/blockDim.x + 1;
    
    int ix, iy;
    int pos_output;
    scalar_t tmp_sum;
    for (int ixy=init ; ixy<init + dimension_loop ; ixy++){
      ix = ixy/(ny) ;
      iy = ixy%(ny);
      if (ix<nx && iy<ny){
        
        const scalar_t* X1_final = X1 + iy*X1_third_size + ix*ny*X1_third_size;
        const scalar_t* X2_final = X2 + iy*X2_third_size + ix*ny*X2_third_size;

        for (int z = 0; z < X1_third_size; ++z) {
          my_buffer_X1[z] = X1_final[z];
        }

        for (int z = 0; z < X2_third_size; ++z) {
          my_buffer_X2[z] = X2_final[z];
        }

        tmp_sum = 0.;
        for (int opz = 0; opz < nz; opz++){
          if (buffer_idx_output[opz]==output_index_z ){
            tmp_sum += my_buffer_X1[buffer_idx_X1[opz]]*my_buffer_X2[buffer_idx_X2[opz]]*buffer_multipliers[opz];
          };
        };

        pos_output = output_index_z+ iy*output_size+  ix*output_size*ny ;
        output[pos_output] += tmp_sum ; 
      };
    };
}



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
    
    int i = threadIdx.x + blockDim.x * blockIdx.x ;
    int j = threadIdx.y + blockDim.y * blockIdx.y ;
    //int z = threadIdx.z + blockDim.z * blockIdx.z ;

    //if (i<nx && j<ny && z<nz) {
    //    int pos = nx*ny*z + nx*j + i;
    //    output[pos] = X1[pos];
    //};

    if (i<nx && j<ny) {
      //printf("in kernel i %d  j %d\n",i,j) ;
      for (int z = 0 ; z < nz ; ++z){
        int z_output = idx_output[z];
        int z_X1 = idx_1[z] ;
        int z_X2 = idx_2[z] ;
        //int pos = nx*ny*z + nx*j + i;
        //int pos_X1 = nx*ny*z_X1 + nx*j + i ;
        //int pos_X2 = nx*ny*z_X2 + nx*j + i ;
        //int pos_output = nx*ny*z_output + nx*j+  i ;

        int pos_X1 = z_X1 + j*X1_third_size + i*ny*X1_third_size ;
        int pos_output = z_output+ j*output_size+  i*output_size*ny ;
        int pos_X2 = z_X2 + j*X2_third_size + i*ny*X2_third_size ;
        //printf("z_output %d \n",z_output) ;
        //printf("z_X1 %d \n",z_X1);
        //printf("z_X2 %d \n",z_X2);
        //printf("pos_X1 %d \n",pos_X1);
        //printf("pos_x2 %d \n",pos_X1);
       //printf("pos_output %d  X1 %f  X2 %f  z %d  multipliers[z] %f \n",pos_output,X1[pos_X1],X2[pos_X2],z,multipliers[z]);
        //printf("pos_output %d \n X1 %f \n X2 %f \n",pos_output,X1[pos_X1],X2[pos_X2]);
        //printf("X1 %f \n",X1[pos_X1]);
        //printf("X2 %f \n",X2[pos_X2]);
        //printf(" i use 2 \n multipliers %f \n",multipliers[z]);
        output[pos_output] += X1[pos_X1]*X2[pos_X2]*multipliers[z];
        //__syncthreads();

        //printf("pos_output %d \n",pos_output);
        //printf("z %d \n",z);
      };
      //output[pos_output] += 1; //multipliers[z];
    };
    //for (int index_first = 0; index_first < output.size(0); ++index_first){
    //    for (int index_second = 0; index_second < output.size(1); ++index_second) {
    //        for (int index = 0; index < idx_output_a.size(0); ++index) {                
    //            auto first = X1_a[index_first][index_second][idx_1_a[index]];
    //            auto second = X2_a[index_first][index_second][idx_2_a[index]];
    //            auto third = multipliers_a[index];
    //            auto contribution = first * second * third;                
    //            output_a[index_first][index_second][idx_output_a[index]] += contribution;
    //        }
    //    }
    //}
  // const int index = blockIdx.x * blockDim.x + threadIdx.x;
  // //printf("hello I am blockIdx %d, blockDim %d, threadIdx %d \n",blockIdx.x , blockDim.x , threadIdx.x);
  // if (index < n) {
  //   //printf("hello inside1 loop I am blockIdx %d, blockDim %d, threadIdx %d \n",blockIdx.x , blockDim.x , threadIdx.x);
  //   output[index] = X1[index];
  // }
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

  int num_threads = BLOCK_SIZE * BLOCK_SIZE;
  int num_blocks = output_size;
  //printf("num_blocks %d \n",num_blocks);

  AT_DISPATCH_FLOATING_TYPES(output.type(), "sparse_accumulation_forward_cuda", ([&] {
  sparse_accumulation_cuda_forward_kernel<scalar_t><<<grid_dim, block_dim>>>(
  //sparse_accumulation_cuda_forward_kernel_grpwrites<scalar_t><<< num_blocks,num_threads, 16384>>>(
  //sparse_accumulation_cuda_forward_kernel_grpwrites<scalar_t><<< num_blocks,num_threads>>>(
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

std::vector<torch::Tensor> sparse_accumulation_cuda_forward_grpwrites(
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

  int num_threads = BLOCK_SIZE * BLOCK_SIZE;
  int num_blocks = output_size;
  //printf("num_blocks %d \n",num_blocks);

  AT_DISPATCH_FLOATING_TYPES(output.type(), "sparse_accumulation_forward_cuda", ([&] {
  //sparse_accumulation_cuda_forward_kernel<scalar_t><<<grid_dim, block_dim>>>(
  //sparse_accumulation_cuda_forward_kernel_grpwrites<scalar_t><<< num_blocks,num_threads, 16384>>>(

   
    size_t X1_buf_size = BLOCK_SIZE * BLOCK_SIZE * X1_third_size * sizeof(scalar_t);
    size_t X2_buf_size = BLOCK_SIZE * BLOCK_SIZE * X2_third_size * sizeof(scalar_t);
    size_t multipliers_size = multipliers.sizes()[0] * sizeof(scalar_t);
    size_t index_size = idx_output.sizes()[0] * sizeof(int32_t);

    size_t total_buf_size = X1_buf_size + X2_buf_size + multipliers_size + index_size * 3;

  sparse_accumulation_cuda_forward_kernel_grpwrites<scalar_t><<< num_blocks,num_threads, total_buf_size>>>(
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


std::vector<torch::Tensor> sparse_accumulation_gpu_forward_grpwrites(
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

  return sparse_accumulation_cuda_forward_grpwrites(X1,X2,idx_output,output_size,idx_1,idx_2,multipliers);
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
    m.def("forward_grpwrites",sparse_accumulation_gpu_forward_grpwrites);
}