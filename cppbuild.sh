#!/usr/bin/env bash
# Downloads and builds CTranslate2 and its CPU backends for one platform. The x86_64 platforms follow the CTranslate2 Python wheels:
# Intel oneMKL and oneDNN linked statically, Intel OpenMP on Windows and GNU OpenMP on Linux.
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
# Intel oneMKL and Intel OpenMP, from Intel's packages on PyPI (the wheels are zip files).
MKL_VERSION=2025.3.0
INTEL_OPENMP_VERSION=2025.3.0
PYPI=https://files.pythonhosted.org/packages

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
STAMP="ctranslate2=$CTRANSLATE2_VERSION onednn=$ONEDNN_VERSION openblas=$OPENBLAS_VERSION mkl=$MKL_VERSION"
STAMP="$STAMP intel-openmp=$INTEL_OPENMP_VERSION platform=$PLATFORM$EXTENSION"

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

# Downloads a file and checks its SHA-256 digest.
download_verified() {
    local url=$1 file=$2 sha256=$3
    download "$url" "$file"
    local actual
    actual=$(sha256sum "$file" | cut -d ' ' -f 1)
    if [[ "$actual" != "$sha256" ]]; then
        rm -f "$file"
        echo "The SHA-256 digest of $file is $actual, not $sha256." >&2
        exit 1
    fi
}

# Downloads a wheel to cppbuild/src/intel/ and extracts the given members (paths in the wheel) flat into a directory.
extract_wheel() {
    local url=$1 sha256=$2 directory=$3
    shift 3
    local file
    file=$SOURCES/intel/$(basename "$url")
    mkdir -p "$SOURCES/intel" "$directory"
    download_verified "$url" "$file" "$sha256"
    unzip -q -o -j "$file" "$@" -d "$directory"
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
CTRANSLATE2_OPTIONS=(-DBUILD_CLI=OFF -DBUILD_TESTS=OFF -DWITH_CUDA=OFF -DWITH_CUDNN=OFF)
GENERATOR=()
# Extra compiler flags, passed in CFLAGS and CXXFLAGS so that CMake keeps its default flags (such as /EHsc of MSVC).
CXX_FLAGS=""

case "$PLATFORM" in
    windows-x86_64)
        # CMake picks the newest Visual Studio generator, which needs no developer prompt; -MP compiles the files of one project in
        # parallel (a dash, since Git Bash would turn /MP into a path).
        GENERATOR=(-A x64)
        CXX_FLAGS="-MP$MAKEJ"
        # oneMKL on Intel CPUs and oneDNN on the others, with Intel OpenMP (libiomp5md.dll), which takes the place of MSVC OpenMP
        # (vcomp140.dll) for oneDNN too.
        MKL_LIBRARIES=(mkl_core.lib mkl_intel_ilp64.lib mkl_intel_thread.lib)
        CTRANSLATE2_OPTIONS+=(-DWITH_MKL=ON -DWITH_DNNL=ON -DOPENMP_RUNTIME=INTEL)
        BUILD_ONEDNN=1 ;;
    linux-x86_64)
        # oneMKL on Intel CPUs and oneDNN on the others, with GNU OpenMP (libgomp.so.1). The base x86-64 target with SSE4.1, also
        # where the compiler targets a newer level by default: CTranslate2 compiles its AVX, AVX2 and AVX-512 kernels separately and
        # picks one at run time, and the base kernels must not be AVX2 kernels as well.
        CXX_FLAGS="-march=x86-64 -mtune=generic -msse4.1"
        MKL_LIBRARIES=(libmkl_core.a libmkl_intel_ilp64.a libmkl_gnu_thread.a)
        CTRANSLATE2_OPTIONS+=(-DWITH_MKL=ON -DWITH_DNNL=ON -DOPENMP_RUNTIME=COMP -DCMAKE_INSTALL_RPATH='$ORIGIN')
        BUILD_ONEDNN=1 ;;
    linux-arm64)
        # OpenBLAS for float32 GEMM, Ruy for int8 GEMM, GNU OpenMP.
        CTRANSLATE2_OPTIONS+=(-DWITH_MKL=OFF -DWITH_OPENBLAS=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=COMP -DCMAKE_INSTALL_RPATH='$ORIGIN')
        BUILD_OPENBLAS=1 ;;
    macosx-arm64)
        # Apple Accelerate for float32 GEMM, Ruy for int8 GEMM, CTranslate2's own thread pool instead of OpenMP.
        COMMON_CMAKE_OPTIONS+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
        CTRANSLATE2_OPTIONS+=(-DWITH_MKL=OFF -DWITH_ACCELERATE=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=NONE -DCMAKE_INSTALL_NAME_DIR=@rpath)
        ;;
    *)
        echo "Unknown platform: $PLATFORM" >&2
        exit 1 ;;
esac

# The static oneMKL libraries, the oneMKL headers and, on Windows, Intel OpenMP go to build/intel/, where CMake finds them.
if [[ -n "${MKL_LIBRARIES:-}" ]]; then
    INTEL=$BUILD/intel
    rm -rf "$INTEL"
    # Packages of other versions, as a restored CI cache may hold.
    for wheel in "$SOURCES"/intel/*.whl; do
        case "$(basename "$wheel")" in
            "*.whl" | mkl_*-"$MKL_VERSION"-* | intel_openmp-"$INTEL_OPENMP_VERSION"-*) ;;
            *) rm -f "$wheel" ;;
        esac
    done
    case "$PLATFORM" in
        windows-x86_64)
            extract_wheel "$PYPI/9c/22/c099498c3294381349265dad4b1715edd8b739b6392c3076aa2a68231ae2/mkl_static-$MKL_VERSION-py2.py3-none-win_amd64.whl" \
                2ff574382d21968e9ec1a45c067258c053588179e741a1983cda7f47587ac181 "$INTEL/lib" \
                "${MKL_LIBRARIES[@]/#/mkl_static-$MKL_VERSION.data/data/Library/lib/}"
            extract_wheel "$PYPI/b9/d7/0445e80511e70b653291daaac068712a780ee0e00bb791d047eed0053c4b/mkl_include-$MKL_VERSION-py2.py3-none-win_amd64.whl" \
                d8efcf39c37767c65abdf42976189475bab36f456e5e7e53bab00bc35c6a3209 "$INTEL/include" \
                "mkl_include-$MKL_VERSION.data/data/Library/include/*.h"
            extract_wheel "$PYPI/79/69/05addedd727061b61a85b4fd989754edb628b5be1cd5d161727f98cf4d86/intel_openmp-$INTEL_OPENMP_VERSION-py2.py3-none-win_amd64.whl" \
                8ff899d01a41b92ffe0e618b221ea633127d16df726086082d381c431c31339d "$INTEL/lib" \
                "intel_openmp-$INTEL_OPENMP_VERSION.data/data/Library/lib/libiomp5md.lib" \
                "intel_openmp-$INTEL_OPENMP_VERSION.data/data/Library/bin/libiomp5md.dll"
            CTRANSLATE2_OPTIONS+=(-DIOMP5_LIBRARY="$(native_path "$INTEL/lib/libiomp5md.lib")") ;;
        linux-x86_64)
            extract_wheel "$PYPI/a3/f3/9c18b8c144cfe9d99052c5aec77a19711f146cea97b2161a813ee9f96d7e/mkl_static-$MKL_VERSION-py2.py3-none-manylinux_2_28_x86_64.whl" \
                f05594dbe568b4fd6ff65fb7283631c78388d5ac4e6917cbf25dfd7dd37f6ed0 "$INTEL/lib" \
                "${MKL_LIBRARIES[@]/#/mkl_static-$MKL_VERSION.data/data/lib/}"
            extract_wheel "$PYPI/d3/e7/5f8f78044b421f859f1a9f6aa4cc957c4733bee3e716a1d54b79797f241c/mkl_include-$MKL_VERSION-py2.py3-none-manylinux_2_28_x86_64.whl" \
                8fd38f51f543ce7031cf454a199529986277eeaf5b0e6a9ff8bbe27757b017e6 "$INTEL/include" \
                "mkl_include-$MKL_VERSION.data/data/include/*.h" ;;
    esac
    CTRANSLATE2_OPTIONS+=(-DMKL_ROOT="$(native_path "$INTEL")")
fi

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

# The OpenMP runtime goes into the native jar next to the CTranslate2 library.
case "$PLATFORM" in
    windows-x86_64)
        cp "$INTEL/lib/libiomp5md.dll" "$PREFIX/bin/libiomp5md.dll" ;;
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
