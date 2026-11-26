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

package org.fogofwarlabs.ctranslate2;

import static org.fogofwarlabs.ctranslate2.global.ctranslate2.BatchType;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.CTRANSLATE2_VERSION;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.ComputeType;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.Device;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.LogLevel;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.compute_type_to_str;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.get_device_count;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.get_log_level;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.mayiuse_int8;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.set_log_level;
import static org.fogofwarlabs.ctranslate2.global.ctranslate2.str_to_compute_type;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Loads the native library and, when the system property {@code ctranslate2.test.model} names a CTranslate2 conversion of
 * NLLB-200 (for example facebook/nllb-200-distilled-600M with int8 quantization), translates two pre-tokenized sentences.
 */
class TranslatorTest {
    /** "게임 배속을 선택하세요!" as SentencePiece pieces of the NLLB-200 vocabulary, with the source language and the end token. */
    private static final String[] KOREAN_SOURCE = {"kor_Hang", "▁게임", "▁배", "속", "을", "▁선택", "하세요", "!", "</s>"};

    /** "Please wait until every player has picked a civilization." in the same form. */
    private static final String[] ENGLISH_SOURCE = {
        "eng_Latn", "▁Please", "▁wait", "▁until", "▁every", "▁player", "▁has", "▁pick", "ed", "▁a", "▁civi", "lization", ".", "</s>"
    };

    @Test
    void loadsTheLibrary() {
        assertEquals("4.9.1", CTRANSLATE2_VERSION);
        assertEquals(ComputeType.INT8_FLOAT32, str_to_compute_type("int8_float32").intern());
        assertEquals("int8", compute_type_to_str(ComputeType.INT8).getString());
        assertEquals(1, get_device_count(Device.CPU));
        assertTrue(mayiuse_int8(Device.CPU));

        LogLevel previous = get_log_level().intern();
        set_log_level(LogLevel.Error);
        assertEquals(LogLevel.Error, get_log_level().intern());
        set_log_level(previous);
    }

    @Test
    void translatesABatch() {
        String model = System.getProperty("ctranslate2.test.model", "");
        assumeTrue(!model.isEmpty() && Files.isRegularFile(Path.of(model, "model.bin")), "no model in ctranslate2.test.model");

        try (ModelLoader loader = new ModelLoader(model);
             ReplicaPoolConfig config = new ReplicaPoolConfig();
             TranslationOptions options = new TranslationOptions();
             StringVectorVector source = new StringVectorVector(new StringVector(KOREAN_SOURCE), new StringVector(ENGLISH_SOURCE));
             StringVectorVector prefix = new StringVectorVector(new StringVector("eng_Latn"), new StringVector("kor_Hang"))) {
            loader.device(Device.CPU).compute_type(ComputeType.INT8).num_replicas_per_device(1);
            config.num_threads_per_replica(4);
            options.beam_size(1).max_decoding_length(2L * ENGLISH_SOURCE.length + 16).return_scores(true);

            try (Translator translator = new Translator(loader, config);
                 TranslationResultVector results = translator.translate_batch(source, prefix, options, 0, BatchType.Examples)) {
                assertEquals(2, results.size());
                List<String> english = tokens(results.get(0).output());
                List<String> korean = tokens(results.get(1).output());
                System.out.println("ko->en: " + english + " score " + results.get(0).score());
                System.out.println("en->ko: " + korean + " score " + results.get(1).score());

                assertEquals(List.of("eng_Latn", "▁Cho", "ose", "▁the", "▁game", "play", "!"), english);
                assertEquals("kor_Hang", korean.get(0));
                assertFalse(korean.size() < 3);
                assertTrue(results.get(0).has_scores());
            }
        }
    }

    private static List<String> tokens(StringVector vector) {
        List<String> tokens = new ArrayList<>();
        for (long index = 0; index < vector.size(); index++) {
            tokens.add(vector.get(index).getString(java.nio.charset.StandardCharsets.UTF_8));
        }
        return tokens;
    }
}
