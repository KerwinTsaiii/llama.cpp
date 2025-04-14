ARG UBUNTU_VERSION=24.04

# This needs to generally match the container host's environment.
ARG ROCM_VERSION=6.3.4

# Target the ROCm build image
ARG BASE_ROCM_DEV_CONTAINER=rocm/dev-ubuntu-${UBUNTU_VERSION}:${ROCM_VERSION}-complete
ARG BASE_ROCM_RUNTIME_CONTAINER=rocm/dev-ubuntu-${UBUNTU_VERSION}:${ROCM_VERSION}

### Build image
FROM ${BASE_ROCM_DEV_CONTAINER} AS build

# Unless otherwise specified, we make a fat build.
# List from https://github.com/ggml-org/llama.cpp/pull/1087#issuecomment-1682807878
# This is mostly tied to rocBLAS supported archs.
# gfx803, gfx900, gfx1032, gfx1101, gfx1102,not officialy supported
# gfx906 is deprecated
#check https://rocm.docs.amd.com/projects/install-on-linux/en/docs-6.2.4/reference/system-requirements.html

ARG ROCM_DOCKER_ARCH='gfx803,gfx900,gfx906,gfx908,gfx90a,gfx942,gfx1010,gfx1030,gfx1032,gfx1100,gfx1101,gfx1102'

# Add GGML_HIP_UMA flag (default OFF)
# On Linux it is also possible to use unified memory architecture (UMA) 
# to share main memory between the CPU and integrated GPU by setting -DGGML_HIP_UMA=ON. 
# However, this hurts performance for non-integrated GPUs (but enables working with integrated GPUs).
ARG GGML_HIP_UMA=OFF

# Add GGML_HIP_ROCWMMA_FATTN flag (default OFF)
# To enhance flash attention performance on RDNA3+ or CDNA architectures, 
# you can utilize the rocWMMA library by enabling -DGGML_HIP_ROCWMMA_FATTN=ON. 
# This requires rocWMMA headers to be installed on the build system.
ARG GGML_HIP_ROCWMMA_FATTN=OFF

# Set nvcc architectured
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

# Allow overriding GPU architecture detection
# This can be used to force a specific GPU architecture version
# Example: gfx906, gfx908, gfx90a, gfx1100, etc.

# Enable ROCm
# ENV CC=/opt/rocm/llvm/bin/clang
# ENV CXX=/opt/rocm/llvm/bin/clang++

RUN apt-get update \
    && apt-get install -y \
    build-essential \
    cmake \
    git \
    libcurl4-openssl-dev \
    curl \
    libgomp1

WORKDIR /app

COPY . .

RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build -DGGML_HIP=ON \
                        -DGGML_HIP_UMA=$GGML_HIP_UMA \
                        -DGGML_HIP_ROCWMMA_FATTN=$GGML_HIP_ROCWMMA_FATTN \
                        -DAMDGPU_TARGETS=$ROCM_DOCKER_ARCH \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DLLAMA_CURL=ON \
    && cmake --build build --config Release -j$(nproc)

RUN mkdir -p /app/lib \
    && find build -name "*.so" -exec cp {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

## Base image
FROM ${BASE_ROCM_RUNTIME_CONTAINER} AS runtime

# Pass through HSA_OVERRIDE_GFX_VERSION from build args to runtime environment
ARG HSA_OVERRIDE_GFX_VERSION
ENV HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION}

RUN apt-get update \
    && apt-get install -y \
    libgomp1 curl hipblas\
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

### Full
FROM runtime AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    libgomp1 curl hipblas\
    git \
    python3-pip \
    python3 \
    python3-wheel\
    && pip install --break-system-packages --upgrade setuptools \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM runtime AS light

COPY --from=build /app/full/llama-cli /app

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM runtime AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]