# modules/base/pytorch-cuda/Dockerfile
# Common base image for all AI inference modules. Module images build ON this
# so common CUDA/ffmpeg layers are shared and cached once.
#
#   docker build -t manifestai/base:pytorch-cuda-2.4.0 modules/base/pytorch-cuda
FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    git \
    curl \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1
