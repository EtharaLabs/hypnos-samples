/*
 * Copyright (C) 2015 Red Hat, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.fabric8.kubernetes.client.utils;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import tools.jackson.core.JsonGenerator;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.module.SimpleModule;
import tools.jackson.databind.ser.std.StdSerializer;

import java.time.Month;
import java.time.Year;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * A mapper the caller passes to KubernetesSerialization keeps its own handling of the JDK types: only
 * {@code new KubernetesSerialization()} restores their Jackson 2 form, callers who build their own mapper add the
 * module themselves.
 */
class KubernetesSerializationCallerMapperTest {

  private static Map<String, Object> jdkTypes() {
    final Map<String, Object> values = new LinkedHashMap<>();
    values.put("year", Year.of(2024));
    values.put("month", Month.JANUARY);
    values.put("locale", Locale.forLanguageTag("zh-Hant-TW"));
    values.put("localeKeys", Map.of(Locale.forLanguageTag("zh-Hant-TW"), "zh"));
    return values;
  }

  @Test
  @DisplayName("a caller-supplied Jackson 3 mapper keeps writing Year, Month and Locale the way it does on its own")
  void callerMapperKeepsItsJdkTypeFormats() {
    final ObjectMapper mapper = JsonMapper.builder().build();
    // KubernetesSerialization always writes dates as strings, which doesn't change these types
    final String own = mapper.rebuild().disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).build()
        .writeValueAsString(jdkTypes());

    assertThat(new KubernetesSerialization(mapper, false).asJson(jdkTypes())).isEqualTo(own);
  }

  @Test
  @DisplayName("a caller-supplied mapper with Jackson 2 defaults keeps writing Year, Month and Locale the way it does on its own")
  void callerJackson2DefaultsMapperKeepsItsJdkTypeFormats() {
    final ObjectMapper mapper = JsonMapper.builderWithJackson2Defaults().build();
    final String own = mapper.rebuild().disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).build()
        .writeValueAsString(jdkTypes());

    assertThat(new KubernetesSerialization(mapper, false).asJson(jdkTypes())).isEqualTo(own);
  }

  @Test
  @DisplayName("a serializer the caller registered for a JDK type keeps writing it")
  void callerSerializerWins() {
    final SimpleModule own = new SimpleModule().addSerializer(Locale.class, new StdSerializer<>(Locale.class) {
      @Override
      public void serialize(Locale value, JsonGenerator gen, SerializationContext provider) {
        gen.writeString("tag:" + value.toLanguageTag());
      }
    });
    final ObjectMapper mapper = JsonMapper.builderWithJackson2Defaults().addModule(own).build();

    assertThat(new KubernetesSerialization(mapper, false).asJson(Map.of("locale", Locale.forLanguageTag("zh-Hant-TW"))))
        .isEqualTo("{\"locale\":\"tag:zh-Hant-TW\"}");
  }
}
