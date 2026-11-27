/*
 * Copyright 2026 Fog of War Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.fogofwarlabs.ctranslate2.presets;

import org.bytedeco.javacpp.annotation.Platform;
import org.bytedeco.javacpp.annotation.Properties;
import org.bytedeco.javacpp.presets.javacpp;
import org.bytedeco.javacpp.tools.Info;
import org.bytedeco.javacpp.tools.InfoMap;
import org.bytedeco.javacpp.tools.InfoMapper;

/**
 * The JavaCPP preset of CTranslate2: the headers and mappings that the classes of {@code org.fogofwarlabs.ctranslate2} are generated
 * from. It covers loading a sequence-to-sequence model into a {@code Translator} and translating batches of tokens.
 */
@Properties(
    inherit = javacpp.class,
    value = {
        @Platform(
            value = {"windows-x86_64", "linux-x86_64", "linux-arm64", "macosx-arm64"},
            compiler = "cpp17",
            include = {
                "ctranslate2-java/version.h",
                "ctranslate2/logging.h",
                "ctranslate2/devices.h",
                "ctranslate2/types.h",
                "ctranslate2/batch_reader.h",
                "ctranslate2/models/model.h",
                "ctranslate2/replica_pool.h",
                "ctranslate2/translation.h",
                "ctranslate2/translator.h"
            }
        ),
        @Platform(value = {"linux", "macosx"}, link = "ctranslate2@.4"),
        // The OpenMP runtime, bundled in the native jar: Intel OpenMP on Windows, GNU OpenMP on Linux; macOS uses no OpenMP.
        @Platform(value = "windows", link = "ctranslate2", preload = "libiomp5md"),
        @Platform(value = "linux", preload = "gomp@.1")
    },
    target = "org.fogofwarlabs.ctranslate2",
    global = "org.fogofwarlabs.ctranslate2.global.ctranslate2"
)
public class ctranslate2 implements InfoMapper {
    /** The constructors that {@code Translator} inherits from {@code ReplicaPool} (a C++ using-declaration). */
    private static final String TRANSLATOR_CONSTRUCTORS = """
            public Translator(@Const @ByRef ModelLoader model_loader, @Const @ByRef ReplicaPoolConfig config) {
                super((Pointer) null);
                allocate(model_loader, config);
            }
            private native void allocate(@Const @ByRef ModelLoader model_loader, @Const @ByRef ReplicaPoolConfig config);
            public Translator(@Const @ByRef ModelLoader model_loader) {
                super((Pointer) null);
                allocate(model_loader);
            }
            private native void allocate(@Const @ByRef ModelLoader model_loader);
            public Translator(@StdString String model_path, Device device, ComputeType compute_type) {
                super((Pointer) null);
                allocate(model_path, device, compute_type);
            }
            private native void allocate(@StdString String model_path, Device device, ComputeType compute_type);
        """;

    @Override public void map(InfoMap infoMap) {
        infoMap.put(new Info("CT2_WITH_TENSOR_PARALLEL").define(false))
               // Standard containers of the translation API.
               .put(new Info("std::vector<std::string>").pointerTypes("StringVector").define())
               .put(new Info("std::vector<std::vector<std::string> >").pointerTypes("StringVectorVector").define())
               .put(new Info("std::vector<float>").pointerTypes("FloatVector").define())
               .put(new Info("std::vector<int>").pointerTypes("IntVector").define())
               .put(new Info("std::vector<ctranslate2::TranslationResult>").pointerTypes("TranslationResultVector").define())
               .put(new Info("ctranslate2::dim_t").cast().valueTypes("long").pointerTypes("LongPointer", "LongBuffer", "long[]"))
               .put(new Info("ctranslate2::Device", "ctranslate2::ComputeType", "ctranslate2::DataType", "ctranslate2::LogLevel",
                             "ctranslate2::BatchType", "ctranslate2::models::QUANTIZATION_TYPE").enumerate())

               // Device management beyond the device type and count (multi-process, CUDA streams).
               .put(new Info("ctranslate2::ScopedDeviceSetter", "ctranslate2::ScopedMPISetter", "ctranslate2::my_rank",
                             "ctranslate2::local_rank", "ctranslate2::n_ranks", "ctranslate2::synchronize_device",
                             "ctranslate2::synchronize_stream", "ctranslate2::synchronize_stream_nothrow").skip())
               .put(new Info("ctranslate2::float16_t", "half_float::half", "ctranslate2::compute_type_to_data_type").skip())

               // Batching internals: only BatchType is part of the translation API.
               .put(new Info("ctranslate2::Example", "ctranslate2::BatchReader", "ctranslate2::TextLineReader",
                             "ctranslate2::VectorReader", "ctranslate2::ParallelBatchReader", "ctranslate2::Batch",
                             "ctranslate2::load_examples", "ctranslate2::rebatch_input").skip())

               // Models: only the loader, which sets the device, the compute type and the number of replicas.
               .put(new Info("ctranslate2::models::Model", "ctranslate2::models::ModelReplica", "ctranslate2::models::ModelReader",
                             "ctranslate2::models::SequenceToSequenceReplica", "ctranslate2::models::SequenceGeneratorReplica",
                             "ctranslate2::models::SequenceEncoderReplica",
                             "ctranslate2::models::Model::get_attribute_with_default<std::string>",
                             "ctranslate2::models::ModelLoader::model_reader", "ctranslate2::models::ModelLoader::load",
                             "std::shared_ptr<ctranslate2::models::ModelReader>").skip())
               .put(new Info("ctranslate2::models::ModelLoader::ModelLoader(const std::shared_ptr<ctranslate2::models::ModelReader>&)")
                            .skip())

               // Replica pools: the configuration only; Translator gets the inherited constructors.
               .put(new Info("ctranslate2::CallingThreadContextGuard").skip())
               .put(new Info("ctranslate2::ReplicaPool<ctranslate2::models::SequenceToSequenceReplica>").pointerTypes("Pointer"))
               .put(new Info("ctranslate2::ReplicaPool<ctranslate2::models::SequenceToSequenceReplica>::ReplicaPool",
                             "ctranslate2::ReplicaPool::ReplicaPool", "ReplicaPool::ReplicaPool").javaText(TRANSLATOR_CONSTRUCTORS))

               // Translation: synchronous batches; no futures, scoring, files, callbacks, attention or logits.
               .put(new Info("ctranslate2::TranslationOptions::end_token", "ctranslate2::TranslationOptions::callback",
                             "ctranslate2::TranslationResult::attention", "ctranslate2::TranslationResult::logits").skip())
               .put(new Info("std::vector<std::vector<std::vector<float> > >", "std::vector<std::vector<ctranslate2::StorageView> >").skip())
               .put(new Info("ctranslate2::run_scoring", "ctranslate2::run_translation", "ctranslate2::Translator::translate_batch_async",
                             "ctranslate2::Translator::score_batch", "ctranslate2::Translator::score_batch_async",
                             "ctranslate2::Translator::translate_text_file", "ctranslate2::Translator::score_text_file").skip());
    }
}
