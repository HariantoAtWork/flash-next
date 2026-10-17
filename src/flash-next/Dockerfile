FROM ubuntu:24.04

# Strix Halo (gfx1151) inference via gufo — fork: github.com/mikealanni/gufo
ARG ROCM_VERSION=7.2.4
ARG TARGET_GFX=gfx1151
ARG GUFO_REPO=https://github.com/mikealanni/gufo.git
# Pin to fork-enhancements tip as of 2026-10-17 (dfb5f578).
# Branch names still work; commit SHAs need fetch (not git clone --branch).
ARG GUFO_REF=dfb5f578eec1f25fc49d6516225a5229f29a90c8
# This fork links NpuGemm at compile time; GPU-only builds fail without NPU enabled.
ARG GUFO_ENABLE_NPU=ON
ARG GUFO_XRT_INCLUDE_DIR=/usr/include
ARG GUFO_XRT_LIB_DIR=/usr/lib/x86_64-linux-gnu
# HIP compiles are memory-heavy; cap parallelism to avoid OOM during docker build.
ARG BUILD_PARALLEL=2

LABEL org.opencontainers.image.title="flash-next" \
      org.opencontainers.image.description="Qwen3.8 Flash-Next via gufo on AMD Strix Halo (gfx1151)" \
      org.opencontainers.image.source="https://github.com/mikealanni/gufo"

ENV DEBIAN_FRONTEND=noninteractive \
    ROCM_VERSION=${ROCM_VERSION} \
    ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    TARGET_GFX=${TARGET_GFX} \
    GUFO_DIR=/opt/gufo \
    GUFO_BIN=/opt/gufo/build/release/gufo \
    PATH="/opt/rocm/bin:/opt/gufo/build/release:${PATH}" \
    LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg2 \
        git \
        cmake \
        ninja-build \
        ccache \
        build-essential \
        pkg-config \
        libicu-dev \
        libcurl4-openssl-dev \
        libpng-dev \
        libjpeg-dev \
        libwebp-dev \
        libssl-dev \
        uuid-dev \
        ffmpeg \
        software-properties-common; \
    add-apt-repository -y ppa:amd-team/xrt; \
    mkdir -p /etc/apt/keyrings; \
    wget -qO- "https://repo.radeon.com/rocm/rocm.gpg.key" \
        | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" \
        > /etc/apt/sources.list.d/rocm.list; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amd-container-toolkit/apt/ noble main" \
        > /etc/apt/sources.list.d/amd-container-toolkit.list; \
    printf '%s\n' \
        'Package: *' \
        'Pin: release o=repo.radeon.com' \
        'Pin-Priority: 600' \
        > /etc/apt/preferences.d/rocm-pin-600; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        rocm-core \
        rocminfo \
        rocm-smi \
        amd-smi-lib \
        rocm-dev \
        hipblas-dev \
        hipblaslt-dev \
        rocblas-dev \
        hipcub-dev \
        rocprim-dev \
        rocwmma-dev \
        amd-container-toolkit \
        libxrt-dev \
        libxrt2; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    git init /opt/gufo; \
    cd /opt/gufo; \
    git remote add origin "${GUFO_REPO}"; \
    git fetch --depth 1 origin "${GUFO_REF}"; \
    git checkout --force FETCH_HEAD; \
    revision="$(git rev-parse --short HEAD)"; \
    # When GUFO_REF is a commit id, refuse a mismatch; branch/tag names skip this.
    if printf '%s' "${GUFO_REF}" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then \
        expected="$(printf '%s' "${GUFO_REF}" | cut -c1-7)"; \
        case "${revision}" in "${expected}"*) ;; *) \
            echo "gufo HEAD ${revision} does not match GUFO_REF ${GUFO_REF}" >&2; \
            exit 1; \
        esac; \
    fi; \
    release="$(tr -d '\n\r' < version.txt 2>/dev/null || echo development)"; \
    if [ "${GUFO_ENABLE_NPU}" = "ON" ]; then \
        if [ -z "${GUFO_XRT_INCLUDE_DIR}" ]; then \
            echo "GUFO_ENABLE_NPU=ON requires GUFO_XRT_INCLUDE_DIR" >&2; \
            exit 1; \
        fi; \
        cmake --preset release \
            -DGUFO_RELEASE_VERSION="${release}" \
            -DGUFO_REVISION="${revision}" \
            -DGUFO_FFMPEG_EXECUTABLE=/usr/bin/ffmpeg \
            -DGUFO_FFPROBE_EXECUTABLE=/usr/bin/ffprobe \
            -DCMAKE_HIP_ARCHITECTURES="${TARGET_GFX}" \
            -DGPU_TARGETS="${TARGET_GFX}" \
            -DGUFO_ENABLE_NPU=ON \
            -DGUFO_XRT_INCLUDE_DIR="${GUFO_XRT_INCLUDE_DIR}" \
            -DGUFO_XRT_LIB_DIR="${GUFO_XRT_LIB_DIR}"; \
    else \
        cmake --preset release \
            -DGUFO_RELEASE_VERSION="${release}" \
            -DGUFO_REVISION="${revision}" \
            -DGUFO_FFMPEG_EXECUTABLE=/usr/bin/ffmpeg \
            -DGUFO_FFPROBE_EXECUTABLE=/usr/bin/ffprobe \
            -DCMAKE_HIP_ARCHITECTURES="${TARGET_GFX}" \
            -DGPU_TARGETS="${TARGET_GFX}"; \
    fi; \
    cmake --build --preset release --parallel "${BUILD_PARALLEL}"; \
    test -x /opt/gufo/build/release/gufo; \
    /opt/gufo/build/release/gufo --help >/dev/null

# xrt-smi (NPU power-mode check/configure). Separate layer so the gufo
# compile above stays cacheable when only utils change.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libxrt-utils \
        libxrt-utils-npu; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /usr/bin/xrt-smi

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker-serve.sh /usr/local/bin/docker-serve.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-serve.sh

WORKDIR /opt/gufo

EXPOSE 8900

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve"]
