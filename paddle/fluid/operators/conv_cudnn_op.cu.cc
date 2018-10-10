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

#include "paddle/fluid/framework/eigen.h"
#include "paddle/fluid/framework/op_registry.h"
#include "paddle/fluid/memory/memory.h"
#include "paddle/fluid/operators/conv_op.h"
#include "paddle/fluid/platform/assert.h"
#include "paddle/fluid/platform/miopen_helper.h"
#include "paddle/fluid/platform/float16.h"

DEFINE_bool(cudnn_deterministic, false,
            "Whether allow using an autotuning algorithm for convolution "
            "operator. The autotuning algorithm may be non-deterministic. If "
            "true, the algorithm is deterministic.");

namespace paddle {
namespace operators {

using Tensor = framework::Tensor;
using ScopedTensorDescriptor = platform::ScopedTensorDescriptor;
using ScopedFilterDescriptor = platform::ScopedFilterDescriptor;
using ScopedConvolutionDescriptor = platform::ScopedConvolutionDescriptor;
using DataLayout = platform::DataLayout;
template <typename T>
using ScalingParamType = typename platform::MIOpenDataType<T>::ScalingParamType;

static constexpr size_t kCONV_CUDNN_WORKSPACE_LIMIT_BYTES =
    static_cast<size_t>(1024) * 1024 * 1024;

template <typename T>
class CUDNNConvOpKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    PADDLE_ENFORCE(platform::is_gpu_place(ctx.GetPlace()),
                   "It must use CUDAPlace.");
    auto* input = ctx.Input<Tensor>("Input");
    auto* filter = ctx.Input<Tensor>("Filter");
    auto* output = ctx.Output<Tensor>("Output");

    std::vector<int> strides = ctx.Attr<std::vector<int>>("strides");
    std::vector<int> paddings = ctx.Attr<std::vector<int>>("paddings");
    std::vector<int> dilations = ctx.Attr<std::vector<int>>("dilations");
    int groups = ctx.Attr<int>("groups");
    int64_t user_workspace_size =
        static_cast<size_t>(ctx.Attr<int>("workspace_size_MB"));

    const T* input_data = input->data<T>();
    const T* filter_data = filter->data<T>();
    T* output_data = output->mutable_data<T>(ctx.GetPlace());

    // ------------------- cudnn descriptors ---------------------
    ScopedTensorDescriptor input_desc;
    ScopedTensorDescriptor output_desc;
    ScopedFilterDescriptor filter_desc;
    ScopedConvolutionDescriptor conv_desc;
    DataLayout layout = DataLayout::kNCHW;
    if (input->dims().size() == 5) {
      layout = DataLayout::kNCDHW;
    }

    miopenConvolutionDescriptor_t cudnn_conv_desc =
        conv_desc.descriptor<T>(paddings, strides, dilations);

#if 1
    PADDLE_ENFORCE(platform::dynload::miopenSetConvolutionGroupCount(	
            cudnn_conv_desc, groups));
    groups = 1;
#endif

    miopenTensorDescriptor_t cudnn_input_desc = input_desc.descriptor<T>(
        layout, framework::vectorize2int(input->dims()), groups);
    miopenTensorDescriptor_t cudnn_output_desc = output_desc.descriptor<T>(
        layout, framework::vectorize2int(output->dims()), groups);
    miopenTensorDescriptor_t cudnn_filter_desc = filter_desc.descriptor<T>(
        layout, framework::vectorize2int(filter->dims()), groups);

    int input_channels = input->dims()[1];
    int input_height, input_width, input_depth;
    if (input->dims().size() == 5) {
      input_depth = input->dims()[2];
      input_height = input->dims()[3];
      input_width = input->dims()[4];
    } else {  // dim size is enforced in InferShape
      input_depth = 1;
      input_height = input->dims()[2];
      input_width = input->dims()[3];
    }
    int output_channels = filter->dims()[0];
    int output_height, output_width, output_depth;
    if (output->dims().size() == 5) {
      output_depth = output->dims()[2];
      output_height = output->dims()[3];
      output_width = output->dims()[4];
    } else {
      output_depth = 1;
      output_height = output->dims()[2];
      output_width = output->dims()[3];
    }

    int group_offset_in =
        input_channels / groups * input_height * input_width * input_depth;
    int group_offset_out =
        output_channels / groups * output_height * output_width * output_depth;
    int group_offset_filter = filter->numel() / groups;
    // ------------------- cudnn conv workspace ---------------------
    void* cudnn_workspace = nullptr;
    size_t workspace_size_in_bytes;  // final workspace to allocate.
    size_t workspace_size_limit = kCONV_CUDNN_WORKSPACE_LIMIT_BYTES;
    if (user_workspace_size > 0) {
      workspace_size_limit = user_workspace_size * 1024 * 1024;
    }
    // ------------------- cudnn conv algorithm ---------------------
    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    auto handle = dev_ctx.miopen_handle();

    // get workspace size able to allocate
    PADDLE_ENFORCE(platform::dynload::miopenConvolutionForwardGetWorkSpaceSize(
        handle, cudnn_filter_desc, cudnn_input_desc, cudnn_conv_desc,
        cudnn_output_desc, &workspace_size_in_bytes));
    PADDLE_ENFORCE_LE(workspace_size_in_bytes, workspace_size_limit,
                      "workspace_size to be allocated exceeds the limit");
    // Allocate on GPU memory
    platform::CUDAPlace gpu = boost::get<platform::CUDAPlace>(ctx.GetPlace());
    cudnn_workspace = paddle::memory::Alloc(gpu, workspace_size_in_bytes);
    ScalingParamType<T> alpha = 1.0f, beta = 0.0f;
    miopenConvAlgoPerf_t perfRes;
    int algoCount = 0;
    for (int i = 0; i < groups; i++) {
      // ------------------- cudnn conv algorithm ---------------------
      PADDLE_ENFORCE(platform::dynload::miopenFindConvolutionForwardAlgorithm(
          handle, cudnn_input_desc, input_data + i * group_offset_in,
          cudnn_filter_desc, filter_data + i * group_offset_filter,
	  cudnn_conv_desc, cudnn_output_desc, output_data + i * group_offset_out,
          1, &algoCount, &perfRes, cudnn_workspace, workspace_size_in_bytes, false));
      // ------------------- cudnn conv forward ---------------------
      PADDLE_ENFORCE(platform::dynload::miopenConvolutionForward(
          handle, &alpha, cudnn_input_desc, input_data + i * group_offset_in,
          cudnn_filter_desc, filter_data + i * group_offset_filter,
          cudnn_conv_desc, perfRes.fwd_algo,
          &beta, cudnn_output_desc, output_data + i * group_offset_out,
          cudnn_workspace, workspace_size_in_bytes));
    }
    // Release the cudnn workspace
    paddle::memory::Free(gpu, cudnn_workspace);
  }
};

template <typename T>
class CUDNNConvGradOpKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    PADDLE_ENFORCE(platform::is_gpu_place(ctx.GetPlace()),
                   "It must use CUDAPlace.");
    auto input = ctx.Input<Tensor>("Input");
    auto filter = ctx.Input<Tensor>("Filter");
    auto output_grad = ctx.Input<Tensor>(framework::GradVarName("Output"));
    auto input_grad = ctx.Output<Tensor>(framework::GradVarName("Input"));
    auto filter_grad = ctx.Output<Tensor>(framework::GradVarName("Filter"));

    const T* input_data = input->data<T>();
    const T* output_grad_data = output_grad->data<T>();
    const T* filter_data = filter->data<T>();

    std::vector<int> strides = ctx.Attr<std::vector<int>>("strides");
    std::vector<int> paddings = ctx.Attr<std::vector<int>>("paddings");
    std::vector<int> dilations = ctx.Attr<std::vector<int>>("dilations");
    int groups = ctx.Attr<int>("groups");
    int64_t user_workspace_size =
        static_cast<size_t>(ctx.Attr<int>("workspace_size_MB"));

    // ------------------- cudnn descriptors ---------------------
    ScopedTensorDescriptor input_desc;
    ScopedTensorDescriptor output_grad_desc;

    ScopedFilterDescriptor filter_desc;
    ScopedFilterDescriptor filter_grad_desc;
    ScopedConvolutionDescriptor conv_desc;
    DataLayout layout = DataLayout::kNCHW;
    if (input->dims().size() == 5) {
      layout = DataLayout::kNCDHW;
    }

    miopenConvolutionDescriptor_t cudnn_conv_desc =
        conv_desc.descriptor<T>(paddings, strides, dilations);

#if 1
    PADDLE_ENFORCE(platform::dynload::miopenSetConvolutionGroupCount(
        cudnn_conv_desc, groups));
    groups = 1;
#endif

    miopenTensorDescriptor_t cudnn_input_desc = input_desc.descriptor<T>(
        layout, framework::vectorize2int(input->dims()), groups);
    miopenTensorDescriptor_t cudnn_output_grad_desc =
        output_grad_desc.descriptor<T>(
            layout, framework::vectorize2int(output_grad->dims()), groups);
    miopenTensorDescriptor_t cudnn_filter_desc = filter_desc.descriptor<T>(
        layout, framework::vectorize2int(filter->dims()), groups);

    int input_channels = input->dims()[1];
    int input_height, input_width, input_depth;
    if (input->dims().size() == 5) {
      input_depth = input->dims()[2];
      input_height = input->dims()[3];
      input_width = input->dims()[4];
    } else {  // dim size is enforced in InferShape
      input_depth = 1;
      input_height = input->dims()[2];
      input_width = input->dims()[3];
    }

    int output_grad_channels = filter->dims()[0];
    int output_grad_height, output_grad_width, output_grad_depth;
    if (input->dims().size() == 5) {
      output_grad_depth = output_grad->dims()[2];
      output_grad_height = output_grad->dims()[3];
      output_grad_width = output_grad->dims()[4];
    } else {
      output_grad_depth = 1;
      output_grad_height = output_grad->dims()[2];
      output_grad_width = output_grad->dims()[3];
    }

    int group_offset_in =
        input_channels / groups * input_height * input_width * input_depth;
    int group_offset_out = output_grad_channels / groups * output_grad_height *
                           output_grad_width * output_grad_depth;
    int group_offset_filter = filter->numel() / groups;
    // ------------------- cudnn backward algorithm ---------------------
    size_t workspace_size_in_bytes = 0, tmp_size = 0;
    size_t workspace_size_limit = kCONV_CUDNN_WORKSPACE_LIMIT_BYTES;
    if (user_workspace_size > 0) {
      workspace_size_limit = user_workspace_size * 1024 * 1024;
    }

    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    auto handle = dev_ctx.miopen_handle();
    if (input_grad) {
      PADDLE_ENFORCE(
          platform::dynload::miopenConvolutionBackwardDataGetWorkSpaceSize(
              handle, cudnn_output_grad_desc, cudnn_filter_desc,
              cudnn_conv_desc, cudnn_input_desc, &tmp_size));
      workspace_size_in_bytes = std::max(workspace_size_in_bytes, tmp_size);
    }

    if (filter_grad) {
      PADDLE_ENFORCE(
          platform::dynload::miopenConvolutionBackwardWeightsGetWorkSpaceSize(
              handle, cudnn_output_grad_desc, cudnn_input_desc, cudnn_conv_desc,
              cudnn_filter_desc, &tmp_size));
      workspace_size_in_bytes = std::max(workspace_size_in_bytes, tmp_size);
    }
    PADDLE_ENFORCE_GT(workspace_size_limit, workspace_size_in_bytes,
        "Required workspace size should be smaller than limit.");
    // ------------------- cudnn conv workspace ---------------------
    // Already on GPU
    void* cudnn_workspace = nullptr;
    platform::CUDAPlace gpu = boost::get<platform::CUDAPlace>(ctx.GetPlace());
    cudnn_workspace = paddle::memory::Alloc(gpu, workspace_size_in_bytes);
    // ------------------- cudnn conv backward data ---------------------
    ScalingParamType<T> alpha = 1.0f, beta = 0.0f;
    miopenConvAlgoPerf_t perfRes;
    int algoCount = 0;
    if (input_grad) {
      T* input_grad_data = input_grad->mutable_data<T>(ctx.GetPlace());
      // Because beta is zero, it is unnecessary to reset input_grad.

      for (int i = 0; i < groups; i++) {
        PADDLE_ENFORCE(platform::dynload::miopenFindConvolutionBackwardDataAlgorithm(
            handle,
            cudnn_output_grad_desc, output_grad_data + i * group_offset_out,
            cudnn_filter_desc, filter_data + i * group_offset_filter,
            cudnn_conv_desc,
            cudnn_input_desc, input_grad_data + i * group_offset_in,
            1, &algoCount, &perfRes, cudnn_workspace, workspace_size_in_bytes, false));
        PADDLE_ENFORCE(platform::dynload::miopenConvolutionBackwardData(
            handle, &alpha,
            cudnn_output_grad_desc, output_grad_data + i * group_offset_out,
            cudnn_filter_desc, filter_data + i * group_offset_filter,
            cudnn_conv_desc, perfRes.bwd_data_algo, &beta,
            cudnn_input_desc, input_grad_data + i * group_offset_in,
            cudnn_workspace, workspace_size_in_bytes));
      }
    }
    // ------------------- cudnn conv backward filter ---------------------
    if (filter_grad) {
      T* filter_grad_data = filter_grad->mutable_data<T>(ctx.GetPlace());
      // Because beta is zero, it is unnecessary to reset filter_grad.
      for (int i = 0; i < groups; i++) {
        PADDLE_ENFORCE(platform::dynload::miopenFindConvolutionBackwardWeightsAlgorithm(
            handle,
            cudnn_output_grad_desc, output_grad_data + i * group_offset_out,
            cudnn_input_desc, input_data + i * group_offset_in,
            cudnn_conv_desc,
            cudnn_filter_desc, filter_grad_data + i * group_offset_filter,
            1, &algoCount, &perfRes,
            cudnn_workspace, workspace_size_in_bytes, false));
        PADDLE_ENFORCE(platform::dynload::miopenConvolutionBackwardWeights(
            handle, &alpha,
            cudnn_output_grad_desc, output_grad_data + i * group_offset_out,
            cudnn_input_desc, input_data + i * group_offset_in,
            cudnn_conv_desc, perfRes.bwd_weights_algo, &beta,
            cudnn_filter_desc, filter_grad_data + i * group_offset_filter,
            cudnn_workspace, workspace_size_in_bytes));
      }
    }
    // Release the cudnn workspace
    paddle::memory::Free(gpu, cudnn_workspace);
  }
};

}  // namespace operators
}  // namespace paddle

namespace plat = paddle::platform;
REGISTER_OP_KERNEL(conv2d, CUDNN, plat::CUDAPlace,
                   paddle::operators::CUDNNConvOpKernel<float>,
                   paddle::operators::CUDNNConvOpKernel<plat::float16>);
REGISTER_OP_KERNEL(conv2d_grad, CUDNN, plat::CUDAPlace,
                   paddle::operators::CUDNNConvGradOpKernel<float>);

REGISTER_OP_KERNEL(conv3d, CUDNN, plat::CUDAPlace,
                   paddle::operators::CUDNNConvOpKernel<float>);
REGISTER_OP_KERNEL(conv3d_grad, CUDNN, plat::CUDAPlace,
                   paddle::operators::CUDNNConvGradOpKernel<float>);
