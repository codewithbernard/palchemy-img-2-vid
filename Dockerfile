# Build argument for base image selection
# (CUDA 12.8 + cuDNN runtime + Ubuntu 24.04)
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

ARG TRITON_VERSION=3.5.1
ARG SAGE_WHEEL_URL="https://huggingface.co/datasets/BernardBuilds/sage-wheel/resolve/main/sageattention-2.2.0-cp311-cp311-linux_x86_64.whl?download=true"

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest

ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    software-properties-common \
    ca-certificates \
    gnupg \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3-pip \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv --python /usr/bin/python3.11 /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI (CUDA 12.8)
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall \
        torch==2.9.0 torchvision==0.24.0 torchaudio==2.9.0 \
        --index-url ${PYTORCH_INDEX_URL}; \
    fi

RUN uv pip install "triton==${TRITON_VERSION}" \
    && wget -O /tmp/sageattention-2.2.0-cp311-cp311-linux_x86_64.whl "${SAGE_WHEEL_URL}" \
    && uv pip install /tmp/sageattention-2.2.0-cp311-cp311-linux_x86_64.whl \
    && rm -f /tmp/sageattention-2.2.0-cp311-cp311-linux_x86_64.whl

WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./

WORKDIR /

RUN uv pip install runpod requests websocket-client

ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

ENV PIP_NO_INPUT=1

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]

# Stage 3: Final image
FROM base AS final

# Download custom models
RUN comfy model download --url https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors --relative-path models/diffusion_models --filename Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors
RUN comfy model download --url https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors --relative-path models/diffusion_models --filename Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors

RUN comfy model download --url https://huggingface.co/NSFW-API/NSFW-Wan-UMT5-XXL/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors --relative-path models/text_encoders --filename nsfw_wan_umt5-xxl_fp8_scaled.safetensors

RUN comfy model download --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors --relative-path models/vae --filename wan_2.1_vae.safetensors

RUN comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/blob/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors --relative-path models/loras --filename Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors
RUN comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/blob/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors --relative-path models/loras --filename Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors



# Need to add the custom nodes
RUN comfy-node-install comfyui-kjnodes ComfyUI-WanVideoWrapper comfyui-custom-scripts comfyui-frame-interpolation comfyui-easy-use