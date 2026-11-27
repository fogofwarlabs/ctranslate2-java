# ctranslate2-java

Java bindings for [CTranslate2](https://github.com/OpenNMT/CTranslate2), generated with [JavaCPP](https://github.com/bytedeco/javacpp) in the style of the JavaCPP presets.

The binding covers translation with sequence-to-sequence models on the CPU: `Translator`, `ModelLoader`, `ReplicaPoolConfig`, `TranslationOptions`, `TranslationResult`, the device and compute types, the log level and the CTranslate2 version.

The classes mirror the C++ API (package `org.fogofwarlabs.ctranslate2`, functions and enums in `org.fogofwarlabs.ctranslate2.global.ctranslate2`).

## Coordinates

```
org.fogofwarlabs:ctranslate2-java:4.9.1-1
org.fogofwarlabs:ctranslate2-java:4.9.1-1:<platform>
org.bytedeco:javacpp:1.5.13:<platform>
```

The version is the CTranslate2 version, then the build number of this binding.

The first artifact holds the Java classes; the classifier `<platform>` holds the native libraries of one platform, and the JavaCPP classifier of the same platform holds the JavaCPP runtime.

## Platforms and backends

| Platform | float32 GEMM | int8 GEMM | Threads |
|---|---|---|---|
| `windows-x86_64` | oneMKL 2025.3.0, oneDNN 3.1.1 | oneMKL 2025.3.0, oneDNN 3.1.1 | Intel OpenMP (`libiomp5md.dll`, in the native jar) |
| `linux-x86_64` | oneMKL 2025.3.0, oneDNN 3.1.1 | oneMKL 2025.3.0, oneDNN 3.1.1 | GNU OpenMP (`libgomp.so.1`, in the native jar) |
| `linux-arm64` | OpenBLAS 0.3.30 | Ruy | GNU OpenMP (`libgomp.so.1`, in the native jar) |
| `macosx-arm64` | Apple Accelerate | Ruy | CTranslate2 thread pool |

The x86_64 platforms are built like the CTranslate2 Python wheels: CTranslate2 uses Intel oneMKL on Intel processors and oneDNN on other processors; the environment variable `CT2_USE_MKL` overrides the choice.

The backends are linked statically into the CTranslate2 library. GPU builds are not provided yet.

## Usage

```java
try (ModelLoader loader = new ModelLoader("nllb-200-distilled-600M-int8");
     ReplicaPoolConfig config = new ReplicaPoolConfig();
     TranslationOptions options = new TranslationOptions()) {
    loader.device(Device.CPU).compute_type(ComputeType.INT8).num_replicas_per_device(1); // inter_threads
    config.num_threads_per_replica(4);                                                   // intra_threads
    options.beam_size(1).max_decoding_length(64);
    try (Translator translator = new Translator(loader, config);
         StringVectorVector source = new StringVectorVector(new StringVector("eng_Latn", "▁Hello", "</s>"));
         StringVectorVector prefix = new StringVectorVector(new StringVector("kor_Hang"));
         TranslationResultVector results = translator.translate_batch(source, prefix, options, 0, BatchType.Examples)) {
        StringVector tokens = results.get(0).output();
    }
}
```

Tokenization (for example SentencePiece) is not part of this binding.

## Building

Requirements: JDK 25 (the classes target Java 17), CMake 3.24 or newer, Git, Bash, curl and unzip; a C++17 compiler (Visual Studio 2022 or newer on Windows, GCC on Linux, Xcode on macOS).

```
./cppbuild.sh <platform>
./gradlew build
```

`cppbuild.sh` downloads the pinned sources and, for x86_64, the pinned Intel oneMKL and Intel OpenMP packages of Intel on PyPI to `cppbuild/src/` and installs the headers and libraries to `cppbuild/<platform>/`. On Windows it runs in Git Bash and uses the Visual Studio generator of CMake; Gradle finds the Visual Studio compiler with `vswhere`.

`./gradlew build` generates the Java classes, compiles the JNI library, runs the tests and assembles `build/libs/ctranslate2-java-<version>.jar` and `build/libs/ctranslate2-java-<version>-<platform>.jar`.

The translation test needs a converted NLLB-200 model and is skipped without it: `./gradlew test -Pctranslate2.test.model=<model directory>` or the environment variable `CTRANSLATE2_TEST_MODEL`.

## Licence

This binding is licensed under the Apache License 2.0 (`LICENSE`).

CTranslate2 is licensed under the MIT License; the bundled libraries and their licences are listed in `NOTICE`, with the texts in `licenses/` and in every native jar.
