#!/usr/bin/env bash
# Downloads and builds CTranslate2 and its CPU backends for one platform.
#
# Usage: ./cppbuild.sh <platform> [extension]
#   platform:  windows-x86_64, linux-x86_64, linux-arm64, macosx-arm64
#   extension: empty for the CPU build; "-gpu" is reserved for a CUDA build.
#
# Sources go to cppbuild/src/, build trees to cppbuild/<platform><extension>/build/ and the installed headers and libraries to
# cppbuild/<platform><extension>/ (include/, lib/, bin/), which the Gradle build passes to JavaCPP.
# Environment: MAKEJ (parallel jobs, default: all processors).
set -euo pipefail

CTRANSLATE2_VERSION=4.9.1
ONEDNN_VERSION=3.1.1
OPENBLAS_VERSION=0.3.30

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <windows-x86_64|linux-x86_64|linux-arm64|macosx-arm64> [extension]" >&2
    exit 1
fi
PLATFORM=$1
EXTENSION=${2:-}

case "$EXTENSION" in
    "") ;;
    -gpu)
        # A CUDA build adds -DWITH_CUDA=ON -DWITH_CUDNN=ON -DCUDA_DYNAMIC_LOADING=ON and the cutlass and thrust submodules.
        echo "The extension -gpu is not supported yet." >&2
        exit 1 ;;
    *)
        echo "Unknown extension: $EXTENSION" >&2
        exit 1 ;;
esac

ROOT=$(cd "$(dirname "$0")" && pwd)
SOURCES=$ROOT/cppbuild/src
PREFIX=$ROOT/cppbuild/$PLATFORM$EXTENSION
BUILD=$PREFIX/build
STAMP="ctranslate2=$CTRANSLATE2_VERSION onednn=$ONEDNN_VERSION openblas=$OPENBLAS_VERSION platform=$PLATFORM$EXTENSION"

if [[ -f "$PREFIX/.cppbuild" && "$(cat "$PREFIX/.cppbuild")" == "$STAMP" ]]; then
    echo "cppbuild/$PLATFORM$EXTENSION is up to date ($STAMP)."
    exit 0
fi

if [[ -z "${MAKEJ:-}" ]]; then
    MAKEJ=$(getconf _NPROCESSORS_ONLN 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)
fi

# CMake on Windows takes mixed paths (D:/x/y); elsewhere the path stays as it is.
native_path() {
    if command -v cygpath > /dev/null; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

download() {
    local url=$1 file=$2
    if [[ ! -f "$file" ]]; then
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
}

mkdir -p "$SOURCES" "$BUILD"
rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin" "$PREFIX/.cppbuild"

# CTranslate2 with the submodules of a CPU build (cpu_features, ruy with cpuinfo, spdlog).
CTRANSLATE2_SOURCE=$SOURCES/CTranslate2-$CTRANSLATE2_VERSION
if [[ ! -f "$CTRANSLATE2_SOURCE/CMakeLists.txt" ]]; then
    rm -rf "$CTRANSLATE2_SOURCE"
    git -c advice.detachedHead=false clone --depth 1 --branch "v$CTRANSLATE2_VERSION" https://github.com/OpenNMT/CTranslate2.git \
        "$CTRANSLATE2_SOURCE"
fi
git -C "$CTRANSLATE2_SOURCE" submodule update --init --depth 1 third_party/cpu_features third_party/ruy third_party/spdlog
git -C "$CTRANSLATE2_SOURCE/third_party/ruy" submodule update --init --depth 1 third_party/cpuinfo

SOURCE_VERSION=$(sed -n 's/^__version__ *= *"\(.*\)"/\1/p' "$CTRANSLATE2_SOURCE/python/ctranslate2/version.py" | tr -d '\r')
if [[ "$SOURCE_VERSION" != "$CTRANSLATE2_VERSION" ]]; then
    echo "The CTranslate2 source has version $SOURCE_VERSION, not $CTRANSLATE2_VERSION." >&2
    exit 1
fi

COMMON_CMAKE_OPTIONS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_INSTALL_PREFIX="$(native_path "$PREFIX")"
    -DCMAKE_PREFIX_PATH="$(native_path "$PREFIX")"
    -DCMAKE_INSTALL_LIBDIR=lib
)
CTRANSLATE2_OPTIONS=(-DBUILD_CLI=OFF -DBUILD_TESTS=OFF -DWITH_MKL=OFF -DWITH_CUDA=OFF -DWITH_CUDNN=OFF)
GENERATOR=()
# Extra compiler flags, passed in CFLAGS and CXXFLAGS so that CMake keeps its default flags (such as /EHsc of MSVC).
CXX_FLAGS=""

case "$PLATFORM" in
    windows-x86_64)
        # CMake picks the newest Visual Studio generator, which needs no developer prompt; -MP compiles the files of one project in
        # parallel (a dash, since Git Bash would turn /MP into a path).
        GENERATOR=(-A x64)
        CXX_FLAGS="-MP$MAKEJ"
        # MSVC OpenMP (vcomp140.dll), which oneDNN uses as well.
        CTRANSLATE2_OPTIONS+=(-DWITH_DNNL=ON -DOPENMP_RUNTIME=COMP)
        BUILD_ONEDNN=1 ;;
    linux-x86_64)
        # GNU OpenMP (libgomp.so.1), which oneDNN uses as well.
        CXX_FLAGS="-msse4.1"
        CTRANSLATE2_OPTIONS+=(-DWITH_DNNL=ON -DOPENMP_RUNTIME=COMP -DCMAKE_INSTALL_RPATH='$ORIGIN')
        BUILD_ONEDNN=1 ;;
    linux-arm64)
        # OpenBLAS for float32 GEMM, Ruy for int8 GEMM, GNU OpenMP.
        CTRANSLATE2_OPTIONS+=(-DWITH_OPENBLAS=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=COMP -DCMAKE_INSTALL_RPATH='$ORIGIN')
        BUILD_OPENBLAS=1 ;;
    macosx-arm64)
        # Apple Accelerate for float32 GEMM, Ruy for int8 GEMM, CTranslate2's own thread pool instead of OpenMP.
        COMMON_CMAKE_OPTIONS+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
        CTRANSLATE2_OPTIONS+=(-DWITH_ACCELERATE=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=NONE -DCMAKE_INSTALL_NAME_DIR=@rpath)
        ;;
    *)
        echo "Unknown platform: $PLATFORM" >&2
        exit 1 ;;
esac

if [[ -n "${BUILD_ONEDNN:-}" ]]; then
    download "https://github.com/uxlfoundation/oneDNN/archive/refs/tags/v$ONEDNN_VERSION.tar.gz" "$SOURCES/oneDNN-$ONEDNN_VERSION.tar.gz"
    rm -rf "$BUILD/oneDNN-$ONEDNN_VERSION"
    tar -xzf "$SOURCES/oneDNN-$ONEDNN_VERSION.tar.gz" -C "$BUILD"
    # The GEMM API (dnnl_sgemm, dnnl_gemm_u8s8s32, dnnl_gemm_s8s8s32) is always built; CTranslate2 uses the convolution primitive for
    # Conv1D layers. The same options as the CTranslate2 Python wheels, without the VTune hooks.
    rm -rf "$BUILD/oneDNN-$ONEDNN_VERSION-build"
    CFLAGS="$CXX_FLAGS" CXXFLAGS="$CXX_FLAGS" cmake -S "$(native_path "$BUILD/oneDNN-$ONEDNN_VERSION")" \
        -B "$(native_path "$BUILD/oneDNN-$ONEDNN_VERSION-build")" ${GENERATOR[@]+"${GENERATOR[@]}"} "${COMMON_CMAKE_OPTIONS[@]}" \
        -DONEDNN_LIBRARY_TYPE=STATIC -DONEDNN_BUILD_EXAMPLES=OFF -DONEDNN_BUILD_TESTS=OFF -DONEDNN_BUILD_DOC=OFF \
        -DONEDNN_ENABLE_WORKLOAD=INFERENCE -DONEDNN_ENABLE_PRIMITIVE="CONVOLUTION;REORDER" -DONEDNN_BUILD_GRAPH=OFF \
        -DONEDNN_ENABLE_JIT_PROFILING=OFF -DONEDNN_ENABLE_ITT_TASKS=OFF
    cmake --build "$(native_path "$BUILD/oneDNN-$ONEDNN_VERSION-build")" --config Release --target install --parallel "$MAKEJ"
fi

if [[ -n "${BUILD_OPENBLAS:-}" ]]; then
    download "https://github.com/OpenMathLib/OpenBLAS/releases/download/v$OPENBLAS_VERSION/OpenBLAS-$OPENBLAS_VERSION.tar.gz" \
        "$SOURCES/OpenBLAS-$OPENBLAS_VERSION.tar.gz"
    rm -rf "$BUILD/OpenBLAS-$OPENBLAS_VERSION"
    tar -xzf "$SOURCES/OpenBLAS-$OPENBLAS_VERSION.tar.gz" -C "$BUILD"
    # Single precision CBLAS only, static, OpenMP, kernels for every ARMv8 core chosen at run time. NUM_THREADS bounds intra_threads.
    OPENBLAS_OPTIONS=(TARGET=ARMV8 DYNAMIC_ARCH=1 NO_SHARED=1 BUILD_SINGLE=1 NO_LAPACK=1 NOFORTRAN=1 ONLY_CBLAS=1 USE_OPENMP=1
                      NUM_THREADS=128 NEED_PIC=1)
    make -C "$BUILD/OpenBLAS-$OPENBLAS_VERSION" -j"$MAKEJ" "${OPENBLAS_OPTIONS[@]}"
    make -C "$BUILD/OpenBLAS-$OPENBLAS_VERSION" "${OPENBLAS_OPTIONS[@]}" PREFIX="$PREFIX" install
fi

rm -rf "$BUILD/CTranslate2-build"
CFLAGS="$CXX_FLAGS" CXXFLAGS="$CXX_FLAGS" cmake -S "$(native_path "$CTRANSLATE2_SOURCE")" -B "$(native_path "$BUILD/CTranslate2-build")" \
    ${GENERATOR[@]+"${GENERATOR[@]}"} "${COMMON_CMAKE_OPTIONS[@]}" "${CTRANSLATE2_OPTIONS[@]}"
cmake --build "$(native_path "$BUILD/CTranslate2-build")" --config Release --target install --parallel "$MAKEJ"

# The static backends are linked into the CTranslate2 library; their headers and archives are not needed by the binding.
rm -rf "$PREFIX/include/oneapi" "$PREFIX/include/dnnl"*.h* "$PREFIX/include/cblas.h" "$PREFIX/include/openblas_config.h" \
    "$PREFIX/include/f77blas.h" "$PREFIX/include/lapack"*.h "$PREFIX/lib/cmake" "$PREFIX/lib/pkgconfig" "$PREFIX/share"
case "$PLATFORM" in
    windows-x86_64) rm -f "$PREFIX/lib/dnnl.lib" ;;
    *)              rm -f "$PREFIX/lib/libdnnl.a" "$PREFIX/lib/libopenblas"*.a ;;
esac

# The OpenMP runtime goes into the native jar next to the CTranslate2 library. On Windows, vcomp140.dll comes with the JavaCPP jar.
case "$PLATFORM" in
    linux-*)
        GOMP=$(${CXX:-g++} -print-file-name=libgomp.so.1)
        cp -L "$GOMP" "$PREFIX/lib/libgomp.so.1" ;;
esac

# The version of CTranslate2 as a header, so the binding has it as a constant.
mkdir -p "$PREFIX/include/ctranslate2-java"
cat > "$PREFIX/include/ctranslate2-java/version.h" << EOF
#pragma once

// The version of the CTranslate2 library of this build.
#define CTRANSLATE2_VERSION "$CTRANSLATE2_VERSION"
EOF

echo "$STAMP" > "$PREFIX/.cppbuild"
echo "Built CTranslate2 $CTRANSLATE2_VERSION for $PLATFORM$EXTENSION in cppbuild/$PLATFORM$EXTENSION."
