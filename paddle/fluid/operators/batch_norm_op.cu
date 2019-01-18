/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <algorithm>
#include <cfloat>
#include <string>
#include <vector>
#if defined(PADDLE_WITH_CUDA)
#include <cub/cub.cuh>
namespace gpuprim = ::cub;
#elif defined(PADDLE_WITH_HIP)
#include <hipcub/hipcub.hpp>
namespace gpuprim = ::hipcub;
#endif
#include "paddle/fluid/framework/data_layout.h"
#include "paddle/fluid/operators/batch_norm_op.h"
#include "paddle/fluid/operators/math/math_function.h"
#include "paddle/fluid/platform/miopen_helper.h"
#include "paddle/fluid/platform/float16.h"

namespace paddle {
namespace operators {

using Tensor = framework::Tensor;
using DataLayout = framework::DataLayout;
template <typename T>
using MIOpenDataType = platform::MIOpenDataType<T>;
template <typename T>
using BatchNormParamType = typename MIOpenDataType<T>::BatchNormParamType;

void ExtractNCWHD(const framework::DDim &dims, const DataLayout &data_layout,
                  int *N, int *C, int *H, int *W, int *D) {
  *N = dims[0];
  if (dims.size() == 2) {
    *C = dims[1];
    *H = 1;
    *W = 1;
    *D = 1;
  } else {
    *C = data_layout == DataLayout::kNCHW ? dims[1] : dims[dims.size() - 1];
    *H = data_layout == DataLayout::kNCHW ? dims[2] : dims[1];
    *W = dims.size() > 3
             ? (data_layout == DataLayout::kNCHW ? dims[3] : dims[2])
             : 1;
    *D = dims.size() > 4
             ? (data_layout == DataLayout::kNCHW ? dims[4] : dims[3])
             : 1;
  }
}

template <typename T>
class BatchNormKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    PADDLE_ENFORCE(platform::is_gpu_place(ctx.GetPlace()),
                   "It must use CUDAPlace.");
    double epsilon = static_cast<double>(ctx.Attr<float>("epsilon"));
    const float momentum = ctx.Attr<float>("momentum");
    const bool is_test = ctx.Attr<bool>("is_test");
    const bool use_global_stats = ctx.Attr<bool>("use_global_stats");
    const std::string data_layout_str = ctx.Attr<std::string>("data_layout");
    const DataLayout data_layout =
        framework::StringToDataLayout(data_layout_str);

    // Get the size for each dimension.
    // NCHW [batch_size, in_channels, in_height, in_width]
    const auto *x = ctx.Input<Tensor>("X");
    const auto &x_dims = x->dims();
    PADDLE_ENFORCE(x_dims.size() >= 2 && x_dims.size() <= 5,
                   "The Input dim size should be between 2 and 5");
    int N, C, H, W, D;
    ExtractNCWHD(x_dims, data_layout, &N, &C, &H, &W, &D);

    auto *y = ctx.Output<Tensor>("Y");
    y->mutable_data<T>(ctx.GetPlace());

    // ------------------- cudnn descriptors ---------------------
    miopenTensorDescriptor_t data_desc_;
    miopenTensorDescriptor_t bn_param_desc_;
    miopenBatchNormMode_t mode_ = miopenBNSpatial;

    PADDLE_ENFORCE(platform::dynload::miopenCreateTensorDescriptor(&data_desc_));
    PADDLE_ENFORCE(
        platform::dynload::miopenCreateTensorDescriptor(&bn_param_desc_));

    VLOG(3) << "Setting descriptors.";
    std::vector<int> dims;
    std::vector<int> strides;
    if (data_layout == DataLayout::kNCHW) {
      dims = {N, C, H, W, D};
      strides = {C * H * W * D, H * W * D, W * D, D, 1};
    } else {
      dims = {N, C, H, W, D};
      strides = {H * W * D * C, 1, W * D * C, D * C, C};
    }

    if (x_dims.size() > 4)
    {
        PADDLE_THROW("miopen only supports 4D tensors, dim=%d not allowed", dims.size());
    }
    // Need review.
    PADDLE_ENFORCE(platform::dynload::miopenSet4dTensorDescriptor(
        data_desc_, MIOpenDataType<T>::type,
        dims.data()[0], dims.data()[1], dims.data()[2], dims.data()[3]));
    // Note: PERSISTENT not implemented for inference
    PADDLE_ENFORCE(platform::dynload::miopenDeriveBNTensorDescriptor(
        bn_param_desc_, data_desc_, mode_));

    const auto *scale = ctx.Input<Tensor>("Scale");
    const auto *bias = ctx.Input<Tensor>("Bias");

    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();

    auto handle = dev_ctx.miopen_handle();

    // Now, depending on whether we are running test or not, we have two paths.
    if (is_test || use_global_stats) {
      // only when test we use input to do computation.
      const auto *est_mean = ctx.Input<Tensor>("Mean");
      const auto *est_var = ctx.Input<Tensor>("Variance");
      // Run inference mode.
      PADDLE_ENFORCE_EQ(est_mean->dims().size(), 1UL);
      PADDLE_ENFORCE_EQ(est_var->dims().size(), 1UL);
      PADDLE_ENFORCE_EQ(est_mean->dims()[0], C);
      PADDLE_ENFORCE_EQ(est_var->dims()[0], C);

      // Need review
      PADDLE_ENFORCE(platform::dynload::miopenBatchNormalizationForwardInference(
          handle,
          // Note: PERSISTENT not implemented for inference
          miopenBNSpatial, (void*)MIOpenDataType<T>::kOne(),
          (void*)MIOpenDataType<T>::kZero(), data_desc_, (const void*)x->template data<T>(),
          data_desc_, (void*)y->template mutable_data<T>(ctx.GetPlace()),
          bn_param_desc_, (void*)scale->template data<BatchNormParamType<T>>(),
          (void*)bias->template data<BatchNormParamType<T>>(),
          (void*)est_mean->template data<BatchNormParamType<T>>(),
          (void*)est_var->template data<BatchNormParamType<T>>(), epsilon));
    } else {
      // Run training mode.
      // obtain running mean and running inv var, and see if we need to
      // initialize them.

      auto *mean_out = ctx.Output<Tensor>("MeanOut");
      auto *variance_out = ctx.Output<Tensor>("VarianceOut");
      mean_out->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());
      variance_out->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());

      auto *saved_mean = ctx.Output<Tensor>("SavedMean");
      auto *saved_variance = ctx.Output<Tensor>("SavedVariance");
      saved_mean->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());
      saved_variance->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());
      math::SetConstant<platform::CUDADeviceContext, BatchNormParamType<T>>
          functor;
      functor(dev_ctx, saved_mean, static_cast<BatchNormParamType<T>>(0));
      functor(dev_ctx, saved_variance, static_cast<BatchNormParamType<T>>(0));

      if ((N * H * W * D) == 1) {
        LOG(WARNING) << "Only 1 element in normalization dimension, "
                     << "we skip the batch norm calculation, let y = x.";
        framework::TensorCopy(*x, ctx.GetPlace(), y);
      } else {
        double this_factor = 1. - momentum;

        PADDLE_ENFORCE(platform::dynload::miopenBatchNormalizationForwardTraining(
            handle, mode_, (void*)MIOpenDataType<T>::kOne(), (void*)MIOpenDataType<T>::kZero(),
            data_desc_, (const void*)x->template data<T>(), data_desc_,
            (void*)y->template mutable_data<T>(ctx.GetPlace()), bn_param_desc_,
            (void*)scale->template data<BatchNormParamType<T>>(),
            (void*)bias->template data<BatchNormParamType<T>>(), this_factor,
            (void*)mean_out->template mutable_data<BatchNormParamType<T>>(
                ctx.GetPlace()),
            (void*)variance_out->template mutable_data<BatchNormParamType<T>>(
                ctx.GetPlace()),
            epsilon, (void*)saved_mean->template mutable_data<BatchNormParamType<T>>(
                         ctx.GetPlace()),
            (void*)saved_variance->template mutable_data<BatchNormParamType<T>>(
                ctx.GetPlace())));
      }
    }

    // clean when exit.
    PADDLE_ENFORCE(platform::dynload::miopenDestroyTensorDescriptor(data_desc_));
    PADDLE_ENFORCE(
        platform::dynload::miopenDestroyTensorDescriptor(bn_param_desc_));
  }
};

template <typename T, framework::DataLayout layout>
static __global__ void KeBNBackwardData(const T *dy,
                                        const BatchNormParamType<T> *scale,
                                        const BatchNormParamType<T> *variance,
                                        const double epsilon, const int C,
                                        const int HxW, const int num, T *dx) {
  int gid = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int i = gid; i < num; i += stride) {
    const int c = layout == framework::DataLayout::kNCHW ? i / HxW % C : i % C;
    BatchNormParamType<T> inv_var = 1.0 / sqrt(variance[c] + epsilon);
    dx[i] = static_cast<T>(static_cast<BatchNormParamType<T>>(dy[i]) *
                           scale[c] * inv_var);
  }
}

template <typename T, int BlockDim, framework::DataLayout layout>
static __global__ void KeBNBackwardScaleBias(
    const T *dy, const T *x, const BatchNormParamType<T> *mean,
    const BatchNormParamType<T> *variance, const double epsilon, const int N,
    const int C, const int HxW, BatchNormParamType<T> *dscale,
    BatchNormParamType<T> *dbias) {
  const int outer_size = C;
  const int inner_size = N * HxW;
  typedef gpuprim::BlockReduce<BatchNormParamType<T>, BlockDim> BlockReduce;
  __shared__ typename BlockReduce::TempStorage ds_storage;
  __shared__ typename BlockReduce::TempStorage db_storage;

  for (int i = blockIdx.x; i < outer_size; i += gridDim.x) {
    BatchNormParamType<T> ds_sum = static_cast<BatchNormParamType<T>>(0);
    BatchNormParamType<T> db_sum = static_cast<BatchNormParamType<T>>(0);

    BatchNormParamType<T> inv_var_i = 1.0 / sqrt(variance[i] + epsilon);
    BatchNormParamType<T> mean_i = mean[i];
    for (int j = threadIdx.x; j < inner_size; j += blockDim.x) {
      const int index = layout == framework::DataLayout::kNCHW
                            ? (j / HxW * C + i) * HxW + j % HxW
                            : j * outer_size + i;
      ds_sum += static_cast<BatchNormParamType<T>>(dy[index]) *
                (static_cast<BatchNormParamType<T>>(x[index]) - mean_i);
      db_sum += static_cast<BatchNormParamType<T>>(dy[index]);
    }
    ds_sum = BlockReduce(ds_storage).Reduce(ds_sum, gpuprim::Sum());
    db_sum = BlockReduce(db_storage).Reduce(db_sum, gpuprim::Sum());
    if (threadIdx.x == 0) {
      dscale[i] = ds_sum * inv_var_i;
      dbias[i] = db_sum;
    }
    __syncthreads();
  }
}

template <typename T>
class BatchNormGradKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    PADDLE_ENFORCE(platform::is_gpu_place(ctx.GetPlace()),
                   "It must use CUDAPlace.");
    double epsilon = static_cast<double>(ctx.Attr<float>("epsilon"));
    const std::string data_layout_str = ctx.Attr<std::string>("data_layout");
    const bool use_global_stats = ctx.Attr<bool>("use_global_stats");

    const DataLayout data_layout =
        framework::StringToDataLayout(data_layout_str);
    const auto *x = ctx.Input<Tensor>("X");
    const auto *d_y = ctx.Input<Tensor>(framework::GradVarName("Y"));
    const auto *scale = ctx.Input<Tensor>("Scale");

    const auto &x_dims = x->dims();

    PADDLE_ENFORCE(x_dims.size() >= 2 && x_dims.size() <= 5,
                   "The Input dim size should be between 2 and 5");
    int N, C, H, W, D;
    ExtractNCWHD(x_dims, data_layout, &N, &C, &H, &W, &D);

    // init output
    auto *d_x = ctx.Output<Tensor>(framework::GradVarName("X"));
    auto *d_scale = ctx.Output<Tensor>(framework::GradVarName("Scale"));
    auto *d_bias = ctx.Output<Tensor>(framework::GradVarName("Bias"));

    d_x->mutable_data<T>(ctx.GetPlace());
    if (d_scale && d_bias) {
      d_scale->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());
      d_bias->mutable_data<BatchNormParamType<T>>(ctx.GetPlace());
    }
    PADDLE_ENFORCE_EQ(scale->dims().size(), 1UL);
    PADDLE_ENFORCE_EQ(scale->dims()[0], C);


    std::vector<int> dims;
    std::vector<int> strides;
    if (data_layout == DataLayout::kNCHW) {
      dims = {N, C, H, W, D};
      strides = {C * H * W * D, H * W * D, W * D, D, 1};
    } else {
      dims = {N, C, H, W, D};
      strides = {H * W * C * D, 1, W * D * C, D * C, C};
    }

    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    if (!use_global_stats) {
      if ((N * H * W * D) == 1) {
        framework::TensorCopy(*d_y, ctx.GetPlace(), d_x);
        math::SetConstant<platform::CUDADeviceContext, BatchNormParamType<T>>
            functor;
        functor(dev_ctx, d_scale, static_cast<BatchNormParamType<T>>(0));
        functor(dev_ctx, d_bias, static_cast<BatchNormParamType<T>>(0));
        return;
      }
      // ------------------- cudnn descriptors ---------------------
      miopenTensorDescriptor_t data_desc_;
      miopenTensorDescriptor_t bn_param_desc_;
      miopenBatchNormMode_t mode_ = miopenBNSpatial;

      PADDLE_ENFORCE(platform::dynload::miopenCreateTensorDescriptor(&data_desc_));
      PADDLE_ENFORCE(
          platform::dynload::miopenCreateTensorDescriptor(&bn_param_desc_));

      if (x_dims.size() > 4)
      {
          PADDLE_THROW("miopen only supports 4D tensors, dim=%d not allowed", dims.size());
      }
      PADDLE_ENFORCE(platform::dynload::miopenSet4dTensorDescriptor(
          data_desc_, MIOpenDataType<T>::type,
          dims.data()[0], dims.data()[1], dims.data()[2], dims.data()[3]));

      PADDLE_ENFORCE(platform::dynload::miopenDeriveBNTensorDescriptor(
          bn_param_desc_, data_desc_, mode_));

      const auto *saved_mean = ctx.Input<Tensor>("SavedMean");
      const auto *saved_var = ctx.Input<Tensor>("SavedVariance");
      const void *saved_mean_data =
          saved_mean->template data<BatchNormParamType<T>>();
      const void *saved_var_data =
          saved_var->template data<BatchNormParamType<T>>();

      PADDLE_ENFORCE(platform::dynload::miopenBatchNormalizationBackward(
          dev_ctx.miopen_handle(), mode_, MIOpenDataType<T>::kOne(),
          MIOpenDataType<T>::kZero(), MIOpenDataType<T>::kOne(),
          MIOpenDataType<T>::kZero(), data_desc_, x->template data<T>(),
          data_desc_, d_y->template data<T>(), data_desc_,
          d_x->template mutable_data<T>(ctx.GetPlace()), bn_param_desc_,
          scale->template data<BatchNormParamType<T>>(),
          d_scale->template mutable_data<BatchNormParamType<T>>(ctx.GetPlace()),
          d_bias->template mutable_data<BatchNormParamType<T>>(ctx.GetPlace()),
          epsilon, saved_mean_data, saved_var_data));

      // clean when exit.
      PADDLE_ENFORCE(platform::dynload::miopenDestroyTensorDescriptor(data_desc_));
      PADDLE_ENFORCE(
          platform::dynload::miopenDestroyTensorDescriptor(bn_param_desc_));
    } else {
      const auto *running_mean = ctx.Input<Tensor>("Mean");
      const auto *running_var = ctx.Input<Tensor>("Variance");

      const auto *running_mean_data =
          running_mean->template data<BatchNormParamType<T>>();
      const auto *running_var_data =
          running_var->template data<BatchNormParamType<T>>();

      const int num = x->numel();
      const int block = 512;
      int max_threads = dev_ctx.GetMaxPhysicalThreadCount();
      const int max_blocks = std::max(max_threads / block, 1);
      int grid1 = (num + block - 1) / block;
      int grid2 = std::min(C, max_blocks);

      if (data_layout == framework::DataLayout::kNCHW) {
        if (d_x) {
          hipLaunchKernelGGL(KeBNBackwardData<T, framework::DataLayout::kNCHW>,
              grid1, block, 0, dev_ctx.stream(),
              d_y->data<T>(), scale->data<BatchNormParamType<T>>(),
              running_var_data, epsilon, C, H * W, num, d_x->data<T>());
        }
        if (d_scale && d_bias) {
          hipLaunchKernelGGL(KeBNBackwardScaleBias<T, block, framework::DataLayout::kNCHW>,
              grid2, block, 0, dev_ctx.stream(),
              d_y->data<T>(), x->data<T>(), running_mean_data, running_var_data,
              epsilon, C, H * W, num, d_scale->data<BatchNormParamType<T>>(),
              d_bias->data<BatchNormParamType<T>>());
        }
      } else {
        if (d_x) {
          hipLaunchKernelGGL(KeBNBackwardData<T, framework::DataLayout::kNHWC>,
              grid1, block, 0, dev_ctx.stream(),
              d_y->data<T>(), scale->data<BatchNormParamType<T>>(),
              running_var_data, epsilon, C, H * W, num, d_x->data<T>());
        }
        if (d_scale && d_bias) {
          hipLaunchKernelGGL(KeBNBackwardScaleBias<T, block, framework::DataLayout::kNCHW>,
              grid2, block, 0, dev_ctx.stream(),
              d_y->data<T>(), x->data<T>(), running_mean_data, running_var_data,
              epsilon, C, H * W, num, d_scale->data<BatchNormParamType<T>>(),
              d_bias->data<BatchNormParamType<T>>());
        }
      }
    }
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
namespace plat = paddle::platform;
REGISTER_OP_CUDA_KERNEL(
    batch_norm, ops::BatchNormKernel<plat::CUDADeviceContext, float>,
    ops::BatchNormKernel<plat::CUDADeviceContext, plat::float16>);
REGISTER_OP_CUDA_KERNEL(
    batch_norm_grad, ops::BatchNormGradKernel<plat::CUDADeviceContext, float>,
    ops::BatchNormGradKernel<plat::CUDADeviceContext, plat::float16>);
