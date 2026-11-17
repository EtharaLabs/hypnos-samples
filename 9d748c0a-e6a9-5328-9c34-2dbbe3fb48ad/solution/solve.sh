#!/bin/bash
set -euo pipefail
cd /app
# The fix is a git diff: git apply when the patch tool is absent, as in the environment image.
if command -v patch >/dev/null 2>&1; then apply() { patch -p1 --fuzz=0; }; else apply() { git apply -p1 --whitespace=nowarn; }; fi
apply <<'PATCH'
diff --git a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractCustomResourceHandler.java b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractCustomResourceHandler.java
index c4d15c5fb..193f35995 100644
--- a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractCustomResourceHandler.java
+++ b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractCustomResourceHandler.java
@@ -64,12 +64,12 @@ public abstract class AbstractCustomResourceHandler {
         PrinterColumn printerColumn = ((PrinterColumn) property.annotation);
         String column = printerColumn.name();
         String format = printerColumn.format().getValue();
+        // dates stay strings: the API server renders a date column as the age of an RFC 3339 timestamp, so yyyy-MM-dd
+        // shows <invalid>, and so would a future date-time. @AdditionalPrinterColumn(type = DATE) declares an age column
         String type = property.schema.getType();
         if ("object".equals(type) || "array".equals(type)) {
           logger.warn("Printer column '{}' has a type '{}' that is not allowed, will use string instead", column, type);
           type = "string";
-        } else if ("string".equals(type) && "date".equals(property.schema.getFormat())) {
-          type = "date";
         }
         int priority = printerColumn.priority();
 
diff --git a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractJsonSchema.java b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractJsonSchema.java
index ceebb2d3b..ce45557be 100644
--- a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractJsonSchema.java
+++ b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/AbstractJsonSchema.java
@@ -55,9 +55,12 @@ import tools.jackson.databind.BeanDescription;
 import tools.jackson.databind.BeanProperty;
 import tools.jackson.databind.JavaType;
 import tools.jackson.databind.JsonNode;
+import tools.jackson.databind.ValueSerializer;
+import tools.jackson.databind.annotation.JsonSerialize;
 import tools.jackson.databind.node.JsonNodeFactory;
 import tools.jackson.databind.node.ObjectNode;
 import tools.jackson.databind.ser.BeanPropertyWriter;
+import tools.jackson.databind.util.Converter;
 import tools.jackson.module.jsonSchema.JsonSchema;
 import tools.jackson.module.jsonSchema.types.ArraySchema;
 import tools.jackson.module.jsonSchema.types.ArraySchema.Items;
@@ -75,6 +78,7 @@ import java.lang.reflect.AnnotatedParameterizedType;
 import java.lang.reflect.AnnotatedType;
 import java.lang.reflect.Field;
 import java.lang.reflect.Method;
+import java.nio.ByteBuffer;
 import java.time.Instant;
 import java.time.LocalDate;
 import java.time.OffsetDateTime;
@@ -93,12 +97,19 @@ import java.util.Map;
 import java.util.Map.Entry;
 import java.util.Objects;
 import java.util.Optional;
+import java.util.OptionalInt;
+import java.util.OptionalLong;
 import java.util.Set;
 import java.util.TreeMap;
+import java.util.concurrent.atomic.AtomicInteger;
+import java.util.concurrent.atomic.AtomicLong;
 import java.util.function.Consumer;
+import java.util.function.UnaryOperator;
 import java.util.stream.Collectors;
 import java.util.stream.Stream;
 
+import javax.xml.namespace.QName;
+
 import static java.util.Optional.ofNullable;
 
 /**
@@ -183,7 +194,7 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
       return resolveObject(new LinkedHashMap<>(), schemaSwaps, schema, null, "kind", "apiVersion", "metadata");
     }
     return resolveProperty(new LinkedHashMap<>(), schemaSwaps, null,
-        resolvingContext.objectMapper.serializationConfig().constructType(definition), schema, null, null);
+        resolvingContext.objectMapper.serializationConfig().constructType(definition), schema, null, null, false);
   }
 
   /**
@@ -308,10 +319,14 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
         pattern = ofNullable(beanProperty.getAnnotation(Pattern.class)).map(Pattern::value)
             .or(() -> ofNullable(stringSchema.getPattern()))
             .orElse(null);
-        minLength = findMinInSizeAnnotation(beanProperty)
+        // @Size counts the bytes of a binary type, the API server validates the length of their base64 string
+        final UnaryOperator<Long> length = value instanceof Base64Schema
+            ? AbstractJsonSchema::base64Length
+            : UnaryOperator.identity();
+        minLength = findMinInSizeAnnotation(beanProperty).map(length)
             .or(() -> ofNullable(stringSchema.getMinLength()).map(Integer::longValue))
             .orElse(null);
-        maxLength = findMaxInSizeAnnotation(beanProperty)
+        maxLength = findMaxInSizeAnnotation(beanProperty).map(length)
             .or(() -> ofNullable(stringSchema.getMaxLength()).map(Integer::longValue))
             .orElse(null);
       } else if (value.isIntegerSchema()) {
@@ -458,7 +473,10 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
       schema.setMaxProperties(maxProperties);
 
       schema.setPattern(pattern);
-      schema.setFormat(format);
+      if (format != null) {
+        // otherwise keep the one resolveProperty derived from the type
+        schema.setFormat(format);
+      }
       if (preserveUnknownFields) {
         schema.setXKubernetesPreserveUnknownFields(true);
       }
@@ -544,7 +562,8 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
         continue;
       }
 
-      JsonSchema propertySchema = property.getValue();
+      boolean ownSerializer = hasOwnSerializer(beanProperty);
+      JsonSchema propertySchema = wireSchema(beanProperty.getType(), property.getValue(), ownSerializer);
       PropertyMetadata propertyMetadata = new PropertyMetadata(propertySchema, beanProperty);
 
       if (propertyMetadata.required) {
@@ -562,10 +581,12 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
         }
         propertySchema = resolvingContext.toJsonSchema(propertyMetadata.schemaFrom);
         type = resolvingContext.objectMapper.serializationConfig().constructType(propertyMetadata.schemaFrom);
+        // Jackson's own serializers describe that type
+        ownSerializer = false;
       }
 
       T schema = resolveProperty(visited, schemaSwaps, name, type, propertySchema, beanProperty,
-          beanProperty.getAnnotation(JsonTypeInfo.class));
+          beanProperty.getAnnotation(JsonTypeInfo.class), ownSerializer);
 
       propertyMetadata.updateSchema(schema);
 
@@ -632,12 +653,17 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
 
   /**
    * @param valueTypeInfo the property's {@link JsonTypeInfo}, which applies to its value, or to the elements of a container
+   * @param ownSerializer whether the value is written by a serializer of the property, whose schema is kept as reported
    */
   private T resolveProperty(LinkedHashMap<String, String> visited, InternalSchemaSwaps schemaSwaps, String name,
-      JavaType type, JsonSchema jacksonSchema, BeanProperty beanProperty, JsonTypeInfo valueTypeInfo) {
+      JavaType type, JsonSchema jacksonSchema, BeanProperty beanProperty, JsonTypeInfo valueTypeInfo,
+      boolean ownSerializer) {
 
     // the schema Jackson generated is the referenced type's, so resolve it with that type
     type = unwrapReferenceType(type);
+    jacksonSchema = wireSchema(type, jacksonSchema, ownSerializer);
+    final String integerFormat = integerFormat(type, ownSerializer);
+    final boolean ownContentSerializer = ownSerializer || hasOwnContentSerializer(beanProperty);
 
     if (jacksonSchema.isArraySchema()) {
       Items items = jacksonSchema.asArraySchema().getItems();
@@ -649,11 +675,14 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
       }
       JsonSchema arraySchema = jacksonSchema.asArraySchema().getItems().asSingleItems().getSchema();
       final T schema = resolveProperty(visited, schemaSwaps, name, type.getContentType(), arraySchema, null,
-          valueTypeInfo);
+          valueTypeInfo, ownContentSerializer);
       handleTypeAnnotations(schema, beanProperty, List.class, 0);
       return arrayLikeProperty(schema);
-    } else if (jacksonSchema.isIntegerSchema()) {
-      return singleProperty("integer");
+    } else if (jacksonSchema.isIntegerSchema() || (jacksonSchema.isNumberSchema() && integerFormat != null)) {
+      // Jackson describes the items of a long[] as numbers
+      final T schema = singleProperty("integer");
+      schema.setFormat(integerFormat);
+      return schema;
     } else if (jacksonSchema.isNumberSchema()) {
       return singleProperty("number");
     } else if (jacksonSchema.isBooleanSchema()) {
@@ -670,7 +699,11 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
             .toArray(JsonNode[]::new);
         return enumProperty(enumValues);
       }
-      return singleProperty("string");
+      final T schema = singleProperty("string");
+      if (jacksonSchema instanceof Base64Schema) {
+        schema.setFormat("byte");
+      }
+      return schema;
     } else if (jacksonSchema.isNullSchema()) {
       return singleProperty("object"); // TODO: this may not be the right choice, but rarely will someone be using Void
     } else if (jacksonSchema.isAnySchema()) {
@@ -708,7 +741,8 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
 
       JsonSchema mapValueSchema = ((SchemaAdditionalProperties) ((ObjectSchema) jacksonSchema).getAdditionalProperties())
           .getJsonSchema();
-      T component = resolveProperty(visited, schemaSwaps, name, valueType, mapValueSchema, null, valueTypeInfo);
+      T component = resolveProperty(visited, schemaSwaps, name, valueType, mapValueSchema, null, valueTypeInfo,
+          ownContentSerializer);
       handleTypeAnnotations(component, beanProperty, Map.class, 1);
       return mapLikeProperty(component);
     }
@@ -766,14 +800,20 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
             ofNullable(at.getAnnotation(Pattern.class))
                 .ifPresent(a -> schema.setPattern(a.value()));
 
+            // see PropertyMetadata
+            final UnaryOperator<Long> length = "byte".equals(schema.getFormat())
+                ? AbstractJsonSchema::base64Length
+                : UnaryOperator.identity();
             ofNullable(at.getAnnotation(Size.class))
                 .map(Size::min)
                 .filter(v -> v > 0)
+                .map(length)
                 .ifPresent(schema::setMinLength);
 
             ofNullable(at.getAnnotation(Size.class))
                 .map(Size::max)
                 .filter(v -> v < Long.MAX_VALUE)
+                .map(length)
                 .ifPresent(schema::setMaxLength);
 
           } else if ("number".equals(schema.getType()) || "integer".equals(schema.getType())) {
@@ -824,11 +864,88 @@ public abstract class AbstractJsonSchema<T extends KubernetesJSONSchemaProps, V
       case "date-time" -> type == Instant.class || type == OffsetDateTime.class || type == ZonedDateTime.class
           || Calendar.class.isAssignableFrom(type)
           || (Date.class.isAssignableFrom(type) && type != java.sql.Time.class);
-      case "date" -> type == LocalDate.class;
+      // java.sql.Date only reports date with Jackson2JdkTypesModule, which writes it as yyyy-MM-dd
+      case "date" -> type == LocalDate.class || type == java.sql.Date.class;
       default -> false;
     };
   }
 
+  /**
+   * Jackson's serializers describe {@code byte[]} and {@code ByteBuffer} as arrays of integers and {@code char[]} and
+   * {@code QName} as an array and an object (or a reference to the first QName), but write them as strings (base64 for
+   * the binary types). Only these default descriptions are replaced, a value with its own serializer keeps its schema.
+   */
+  private static JsonSchema wireSchema(JavaType type, JsonSchema schema, boolean ownSerializer) {
+    final JavaType valueType = unwrapReferenceType(type);
+    if (valueType == null || ownSerializer) {
+      return schema;
+    }
+    if (schema.isArraySchema() && isBinary(valueType)) {
+      return new Base64Schema();
+    }
+    if ((schema.isArraySchema() && valueType.hasRawClass(char[].class))
+        || ((schema.isObjectSchema() || schema instanceof ReferenceSchema) && valueType.hasRawClass(QName.class))) {
+      return new StringSchema();
+    }
+    return schema;
+  }
+
+  /**
+   * Whether the value is written by a serializer or converter of the property, the content ones apply to the value of an
+   * {@code Optional} and the other reference types.
+   */
+  private static boolean hasOwnSerializer(BeanProperty beanProperty) {
+    final JsonSerialize serialize = beanProperty == null ? null : beanProperty.getAnnotation(JsonSerialize.class);
+    return serialize != null && (serialize.using() != ValueSerializer.None.class
+        || serialize.converter() != Converter.None.class
+        || (beanProperty.getType().isReferenceType() && hasOwnContentSerializer(beanProperty)));
+  }
+
+  /**
+   * Whether the items or values of the property are written by a serializer or converter of the property.
+   */
+  private static boolean hasOwnContentSerializer(BeanProperty beanProperty) {
+    final JsonSerialize serialize = beanProperty == null ? null : beanProperty.getAnnotation(JsonSerialize.class);
+    return serialize != null && (serialize.contentUsing() != ValueSerializer.None.class
+        || serialize.contentConverter() != Converter.None.class);
+  }
+
+  /**
+   * A binary type Jackson writes as a base64 string, see {@link #wireSchema}.
+   */
+  private static final class Base64Schema extends StringSchema {
+  }
+
+  /**
+   * The format controller-gen gives the Go counterpart ({@code int32}, {@code int64}), which the API server
+   * range-checks. {@code short}, {@code byte} and {@code BigInteger} get none, like Go's {@code int16} and {@code int8},
+   * and neither does a value with its own serializer, which may write something else.
+   */
+  private static String integerFormat(JavaType type, boolean ownSerializer) {
+    if (type == null || ownSerializer) {
+      return null;
+    }
+    final Class<?> raw = type.getRawClass();
+    if (raw == int.class || raw == Integer.class || raw == OptionalInt.class || raw == AtomicInteger.class) {
+      return "int32";
+    }
+    if (raw == long.class || raw == Long.class || raw == OptionalLong.class || raw == AtomicLong.class) {
+      return "int64";
+    }
+    return null;
+  }
+
+  /**
+   * Written as base64, like Go's {@code []byte}. {@code Byte[]} and {@code List<Byte>} are written as arrays of numbers.
+   */
+  private static boolean isBinary(JavaType type) {
+    return type != null && (type.hasRawClass(byte[].class) || ByteBuffer.class.isAssignableFrom(type.getRawClass()));
+  }
+
+  private static long base64Length(long bytes) {
+    return 4 * ((bytes + 2) / 3);
+  }
+
   /**
    * Jackson describes {@code Optional<X>} and the other reference types with the schema of {@code X}.
    */
diff --git a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/ResolvingContext.java b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/ResolvingContext.java
index 736cf0b5e..f2ecb0431 100644
--- a/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/ResolvingContext.java
+++ b/crd-generator/api-v2/src/main/java/io/fabric8/crdv2/generator/ResolvingContext.java
@@ -19,6 +19,7 @@ package io.fabric8.crdv2.generator;
 import io.fabric8.kubernetes.client.utils.KubernetesSerialization;
 import io.fabric8.kubernetes.client.utils.YamlDumpSettings;
 import io.fabric8.kubernetes.client.utils.YamlDumpSettingsBuilder;
+import io.fabric8.kubernetes.model.jackson.Jackson2JdkTypesModule;
 import tools.jackson.databind.BeanProperty;
 import tools.jackson.databind.JavaType;
 import tools.jackson.databind.ObjectMapper;
@@ -104,7 +105,9 @@ public class ResolvingContext {
   public static ResolvingContext defaultResolvingContext(boolean implicitPreserveUnknownFields,
       YamlDumpSettings yamlDumpSettings) {
     if (OBJECT_MAPPER == null) {
+      // the same JDK type formats as new KubernetesSerialization(), which configures its own copy of this mapper
       OBJECT_MAPPER = JsonMapper.builderWithJackson2Defaults()
+          .addModule(new Jackson2JdkTypesModule())
           .disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS)
           .disable(DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS)
           .build();
diff --git a/generator-annotations/src/main/java/io/fabric8/generator/annotation/Size.java b/generator-annotations/src/main/java/io/fabric8/generator/annotation/Size.java
index e56550511..09079fb21 100644
--- a/generator-annotations/src/main/java/io/fabric8/generator/annotation/Size.java
+++ b/generator-annotations/src/main/java/io/fabric8/generator/annotation/Size.java
@@ -26,6 +26,8 @@ import java.lang.annotation.Target;
  * The annotation can be used on strings, list/arrays and maps and will result in an appropriate JSON Schema constraint:
  * <ul>
  * <li>{@code minLength} and/or {@code maxLength} for a String</li>
+ * <li>{@code minLength} and/or {@code maxLength} of the base64 string for a {@code byte[]} or {@code ByteBuffer}, which
+ * encodes 3 bytes per 4 characters, so the limits are only exact for multiples of 3 bytes</li>
  * <li>{@code minItems} and/or {@code maxItems} for a list/array</li>
  * <li>{@code minProperties} and/or {@code maxProperties} for a map</li>
  * </ul>
diff --git a/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/KubernetesSerialization.java b/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/KubernetesSerialization.java
index 06faef48f..74164f8e5 100644
--- a/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/KubernetesSerialization.java
+++ b/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/KubernetesSerialization.java
@@ -23,6 +23,7 @@ import io.fabric8.kubernetes.api.model.runtime.RawExtension;
 import io.fabric8.kubernetes.client.KubernetesClientException;
 import io.fabric8.kubernetes.internal.KubernetesDeserializer;
 import io.fabric8.kubernetes.model.jackson.GoCompatibilityModule;
+import io.fabric8.kubernetes.model.jackson.Jackson2JdkTypesModule;
 import io.fabric8.kubernetes.model.jackson.UnmatchedFieldTypeModule;
 import org.snakeyaml.engine.v2.api.Dump;
 import org.snakeyaml.engine.v2.api.DumpSettings;
@@ -74,19 +75,19 @@ public class KubernetesSerialization {
 
   /**
    * Creates a new instance with a fresh ObjectMapper using Jackson 2.x compatible defaults
-   * ({@link JsonMapper#builderWithJackson2Defaults()}), so user types keep their 2.x wire format
-   * (property order, enum names, null primitives, getter-only collections...).
+   * ({@link JsonMapper#builderWithJackson2Defaults()} and the {@link Jackson2JdkTypesModule}), so user types keep their
+   * 2.x wire format (property order, enum names, null primitives, getter-only collections, JDK types...).
    */
   public KubernetesSerialization() {
-    this(JsonMapper.builderWithJackson2Defaults().build(), true);
+    this(JsonMapper.builderWithJackson2Defaults().addModule(new Jackson2JdkTypesModule()).build(), true);
   }
 
   /**
    * Creates a new instance configured for kubernetes resource serialization / deserialization based on a copy
    * of the given ObjectMapper (Jackson 3 mappers are immutable, the given instance is not modified).
    * <p>
-   * The rest of the mapper settings are preserved, use {@link JsonMapper#builderWithJackson2Defaults()} to match the
-   * defaults of {@link #KubernetesSerialization()}.
+   * The rest of the mapper settings are preserved, use {@link JsonMapper#builderWithJackson2Defaults()} and the
+   * {@link Jackson2JdkTypesModule} to match the defaults of {@link #KubernetesSerialization()}.
    *
    * @param mapper the ObjectMapper to use.
    * @param searchClassloaders if {@link KubernetesResource} should be automatically discovered via {@link ServiceLoader}.
@@ -99,8 +100,8 @@ public class KubernetesSerialization {
    * Creates a new instance configured for kubernetes resource serialization / deserialization based on a copy
    * of the given ObjectMapper (Jackson 3 mappers are immutable, the given instance is not modified).
    * <p>
-   * The rest of the mapper settings are preserved, use {@link JsonMapper#builderWithJackson2Defaults()} to match the
-   * defaults of {@link #KubernetesSerialization()}.
+   * The rest of the mapper settings are preserved, use {@link JsonMapper#builderWithJackson2Defaults()} and the
+   * {@link Jackson2JdkTypesModule} to match the defaults of {@link #KubernetesSerialization()}.
    *
    * @param mapper the ObjectMapper to use.
    * @param searchClassloaders if {@link KubernetesResource} should be automatically discovered via {@link ServiceLoader}.
diff --git a/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/Serialization.java b/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/Serialization.java
index e7b4e55d8..1cbac75af 100644
--- a/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/Serialization.java
+++ b/kubernetes-client-api/src/main/java/io/fabric8/kubernetes/client/utils/Serialization.java
@@ -17,6 +17,7 @@ package io.fabric8.kubernetes.client.utils;
 
 import io.fabric8.kubernetes.api.model.KubernetesResource;
 import io.fabric8.kubernetes.model.jackson.GoCompatibilityModule;
+import io.fabric8.kubernetes.model.jackson.Jackson2JdkTypesModule;
 import io.fabric8.kubernetes.model.jackson.UnmatchedFieldTypeModule;
 import tools.jackson.core.type.TypeReference;
 import tools.jackson.databind.ObjectMapper;
@@ -92,6 +93,7 @@ public class Serialization {
           YAML_MAPPER = YAMLMapper.builder(
               YAMLFactory.builder().configureForJackson2().disable(YAMLWriteFeature.USE_NATIVE_TYPE_ID).build())
               .configureForJackson2()
+              .addModule(new Jackson2JdkTypesModule())
               .addModule(new GoCompatibilityModule())
               .addModule(UNMATCHED_FIELD_TYPE_MODULE)
               .build();
diff --git a/kubernetes-model-generator/kubernetes-model-common/src/main/java/io/fabric8/kubernetes/model/jackson/Jackson2JdkTypesModule.java b/kubernetes-model-generator/kubernetes-model-common/src/main/java/io/fabric8/kubernetes/model/jackson/Jackson2JdkTypesModule.java
new file mode 100644
index 000000000..e0695b636
--- /dev/null
+++ b/kubernetes-model-generator/kubernetes-model-common/src/main/java/io/fabric8/kubernetes/model/jackson/Jackson2JdkTypesModule.java
@@ -0,0 +1,302 @@
+/*
+ * Copyright (C) 2015 Red Hat, Inc.
+ *
+ * Licensed under the Apache License, Version 2.0 (the "License");
+ * you may not use this file except in compliance with the License.
+ * You may obtain a copy of the License at
+ *
+ *         http://www.apache.org/licenses/LICENSE-2.0
+ *
+ * Unless required by applicable law or agreed to in writing, software
+ * distributed under the License is distributed on an "AS IS" BASIS,
+ * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
+ * See the License for the specific language governing permissions and
+ * limitations under the License.
+ */
+package io.fabric8.kubernetes.model.jackson;
+
+import com.fasterxml.jackson.annotation.JsonFormat;
+import tools.jackson.core.JsonGenerator;
+import tools.jackson.core.JsonParser;
+import tools.jackson.core.JsonToken;
+import tools.jackson.databind.BeanDescription;
+import tools.jackson.databind.DeserializationContext;
+import tools.jackson.databind.JavaType;
+import tools.jackson.databind.SerializationConfig;
+import tools.jackson.databind.SerializationContext;
+import tools.jackson.databind.ValueDeserializer;
+import tools.jackson.databind.ValueSerializer;
+import tools.jackson.databind.cfg.DateTimeFeature;
+import tools.jackson.databind.deser.jdk.JDKFromStringDeserializer;
+import tools.jackson.databind.deser.jdk.JDKKeyDeserializer;
+import tools.jackson.databind.ext.javatime.ser.YearSerializer;
+import tools.jackson.databind.ext.sql.JavaSqlDateDeserializer;
+import tools.jackson.databind.ext.sql.JavaSqlDateSerializer;
+import tools.jackson.databind.jsonFormatVisitors.JsonFormatVisitorWrapper;
+import tools.jackson.databind.jsonFormatVisitors.JsonValueFormat;
+import tools.jackson.databind.module.SimpleModule;
+import tools.jackson.databind.ser.Serializers;
+import tools.jackson.databind.ser.jdk.EnumSerializer;
+import tools.jackson.databind.ser.std.ToStringSerializer;
+
+import java.net.MalformedURLException;
+import java.net.UnknownHostException;
+import java.text.DateFormat;
+import java.time.LocalDate;
+import java.time.Month;
+import java.time.Year;
+import java.time.format.DateTimeFormatter;
+import java.time.format.DateTimeParseException;
+import java.util.IllformedLocaleException;
+import java.util.Locale;
+import java.util.StringJoiner;
+
+/**
+ * Writes the JDK types whose format changed with Jackson 3 as Jackson 2 did: {@link Year} as {@code "2024"} (not
+ * {@code 2024}), {@link Month} as {@code "JANUARY"} (not {@code 0}), {@link java.sql.Date} as {@code "2024-01-15"} (not a
+ * UTC date-time) and {@link Locale} as {@link Locale#toString()} ({@code "zh_TW_#Hant"}, not {@code "zh-Hant-TW"}).
+ * {@code @JsonFormat} and {@link DateTimeFeature#WRITE_DATES_AS_TIMESTAMPS} apply as they did in Jackson 2.
+ * <p>
+ * Both forms are read. A {@code yyyy-MM-dd} {@link java.sql.Date} is read as a local date, so it keeps its day in any
+ * timezone (Jackson 2 read it as UTC midnight).
+ * <p>
+ * {@code new KubernetesSerialization()} registers it. Mappers you build yourself need it to keep the Jackson 2 format.
+ */
+public class Jackson2JdkTypesModule extends SimpleModule {
+
+  /**
+   * Optional, like for Jackson: runtimes without the java.sql module (e.g. jlink images) have no java.sql.Date.
+   */
+  private static final boolean JAVA_SQL = isPresent("java.sql.Date");
+
+  @SuppressWarnings({ "unchecked", "rawtypes" }) // Jackson's JDK deserializers are typed as Object
+  public Jackson2JdkTypesModule() {
+    addSerializer(Year.class, new Jackson2YearSerializer());
+    if (JAVA_SQL) {
+      addSerializer(java.sql.Date.class, new Jackson2SqlDateSerializer());
+      addDeserializer(java.sql.Date.class, new Jackson2SqlDateDeserializer());
+    }
+    addSerializer(Locale.class, ToStringSerializer.instance);
+    addDeserializer(Locale.class, (ValueDeserializer) new Jackson2LocaleDeserializer());
+    addKeyDeserializer(Locale.class, new Jackson2LocaleKeyDeserializer());
+  }
+
+  @Override
+  public void setupModule(SetupContext context) {
+    super.setupModule(context);
+    context.addSerializers(new Jackson2MonthSerializers());
+  }
+
+  private static boolean isPresent(String className) {
+    try {
+      Class.forName(className, false, Jackson2JdkTypesModule.class.getClassLoader());
+      return true;
+    } catch (ClassNotFoundException | LinkageError e) {
+      return false;
+    }
+  }
+
+  /**
+   * Parses the {@link Locale#toString()} of a locale with a script or extensions, the form Jackson 2 wrote:
+   * {@code language_REGION_variant_#script_extensions}. Jackson 3 doesn't know the {@code _#} marker and reads the
+   * script and extensions as part of the variant, it reads the rest of the Jackson 2 forms like Jackson 2 did, except a
+   * language that isn't valid BCP 47 (see {@link Jackson2LocaleDeserializer}).
+   */
+  private static Locale fromLocaleString(String value) {
+    final int marker = value.indexOf("_#");
+    final String[] base = value.substring(0, marker).split("_", 3);
+    final String suffix = value.substring(marker + 2);
+    final int separator = suffix.indexOf('_');
+    String script = "";
+    String extensions = "";
+    if (separator >= 0) {
+      script = suffix.substring(0, separator);
+      extensions = suffix.substring(separator + 1);
+    } else if (suffix.indexOf('-') >= 0) {
+      extensions = suffix;
+    } else {
+      script = suffix;
+    }
+    final StringJoiner tag = new StringJoiner("-");
+    tag.add(base[0].isEmpty() ? "und" : base[0]);
+    addIfPresent(tag, script);
+    addIfPresent(tag, base.length > 1 ? base[1] : "");
+    addIfPresent(tag, extensions);
+    if (base.length > 2 && !base[2].isEmpty()) {
+      // the private use form of the variant, which also takes the legacy variants BCP 47 doesn't (e.g. ja_JP_JP)
+      final boolean hasPrivateUse = extensions.startsWith("x-") || extensions.contains("-x-");
+      tag.add((hasPrivateUse ? "lvariant-" : "x-lvariant-") + base[2].replace('_', '-'));
+    }
+    return Locale.forLanguageTag(tag.toString());
+  }
+
+  private static void addIfPresent(StringJoiner tag, String subtags) {
+    if (!subtags.isEmpty()) {
+      tag.add(subtags);
+    }
+  }
+
+  /**
+   * Jackson 3 always writes a {@link Year} as a number unless the shape says otherwise, Jackson 2 followed
+   * {@link DateTimeFeature#WRITE_DATES_AS_TIMESTAMPS}.
+   */
+  static final class Jackson2YearSerializer extends YearSerializer {
+
+    Jackson2YearSerializer() {
+      super(null);
+    }
+
+    private Jackson2YearSerializer(Jackson2YearSerializer base, DateTimeFormatter dtf, Boolean useTimestamp) {
+      super(base, dtf, useTimestamp);
+    }
+
+    @Override
+    protected Jackson2YearSerializer withFormat(DateTimeFormatter dtf, Boolean useTimestamp, JsonFormat.Shape shape) {
+      return new Jackson2YearSerializer(this, dtf, useTimestamp);
+    }
+
+    @Override
+    protected boolean useTimestampFromGlobalDefaults(SerializationContext ctxt) {
+      return ctxt != null && ctxt.isEnabled(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS);
+    }
+
+    @Override
+    public void acceptJsonFormatVisitor(JsonFormatVisitorWrapper visitor, JavaType typeHint) {
+      if (useTimestamp(visitor.getContext())) {
+        super.acceptJsonFormatVisitor(visitor, typeHint);
+      } else {
+        // Jackson reports date-time, which "2024" doesn't match
+        visitor.expectStringFormat(typeHint);
+      }
+    }
+  }
+
+  /**
+   * Jackson 3 writes a {@link java.sql.Date} like a {@link java.util.Date}: a UTC date-time of its local midnight.
+   */
+  static final class Jackson2SqlDateSerializer extends JavaSqlDateSerializer {
+
+    Jackson2SqlDateSerializer() {
+      this(null, null);
+    }
+
+    private Jackson2SqlDateSerializer(Boolean useTimestamp, DateFormat customFormat) {
+      super(useTimestamp, customFormat);
+    }
+
+    @Override
+    public Jackson2SqlDateSerializer withFormat(Boolean timestamp, DateFormat customFormat) {
+      return new Jackson2SqlDateSerializer(timestamp, customFormat);
+    }
+
+    @Override
+    public void serialize(java.sql.Date value, JsonGenerator g, SerializationContext ctxt) {
+      if (!_asTimestamp(ctxt) && _customFormat == null) {
+        g.writeString(value.toString());
+        return;
+      }
+      super.serialize(value, g, ctxt);
+    }
+
+    @Override
+    protected void _acceptJsonFormatVisitor(JsonFormatVisitorWrapper visitor, JavaType typeHint, boolean asNumber) {
+      if (asNumber) {
+        super._acceptJsonFormatVisitor(visitor, typeHint, true);
+      } else if (_customFormat == null) {
+        visitStringFormat(visitor, typeHint, JsonValueFormat.DATE);
+      } else {
+        visitStringFormat(visitor, typeHint);
+      }
+    }
+  }
+
+  static final class Jackson2SqlDateDeserializer extends JavaSqlDateDeserializer {
+
+    Jackson2SqlDateDeserializer() {
+      super();
+    }
+
+    private Jackson2SqlDateDeserializer(Jackson2SqlDateDeserializer src, DateFormat df, String formatString) {
+      super(src, df, formatString);
+    }
+
+    @Override
+    protected Jackson2SqlDateDeserializer withDateFormat(DateFormat df, String formatString) {
+      return new Jackson2SqlDateDeserializer(this, df, formatString);
+    }
+
+    @Override
+    public java.sql.Date deserialize(JsonParser p, DeserializationContext ctxt) {
+      if (_customFormat == null && p.hasToken(JsonToken.VALUE_STRING)) {
+        try {
+          return java.sql.Date.valueOf(LocalDate.parse(p.getString().trim()));
+        } catch (DateTimeParseException e) {
+          // not yyyy-MM-dd, read it like Jackson does
+        }
+      }
+      return super.deserialize(p, ctxt);
+    }
+  }
+
+  static final class Jackson2LocaleDeserializer extends JDKFromStringDeserializer {
+
+    Jackson2LocaleDeserializer() {
+      super(Locale.class, STD_LOCALE);
+    }
+
+    @Override
+    @SuppressWarnings("deprecation") // Locale.of needs Java 19
+    public Object _deserialize(String value, DeserializationContext ctxt)
+        throws MalformedURLException, UnknownHostException {
+      if (value.contains("_#")) {
+        return fromLocaleString(value);
+      }
+      try {
+        return super._deserialize(value, ctxt);
+      } catch (IllformedLocaleException e) {
+        // Jackson 3 only takes a valid BCP 47 language without separators, Jackson 2 took any (e.g. "c", which is
+        // how 7.x wrote the POSIX locale new Locale("C"))
+        return new Locale(value);
+      }
+    }
+  }
+
+  /**
+   * Reads keys with {@link Jackson2LocaleDeserializer}, like Jackson reads them with its own Locale deserializer.
+   */
+  static final class Jackson2LocaleKeyDeserializer extends JDKKeyDeserializer {
+
+    Jackson2LocaleKeyDeserializer() {
+      super(TYPE_LOCALE, Locale.class, new Jackson2LocaleDeserializer());
+    }
+
+    @Override
+    public Object deserializeKey(String key, DeserializationContext ctxt) {
+      if (key.isEmpty()) {
+        // Locale.ROOT, which Jackson 2 read back and Jackson 3 rejects
+        return Locale.ROOT;
+      }
+      return super.deserializeKey(key, ctxt);
+    }
+  }
+
+  /**
+   * Jackson 2 had no {@link Month} serializer and wrote it like any other enum (by name, enum schema), Jackson 3 writes
+   * its zero-based index.
+   * <p>
+   * Reading is left to Jackson 3's Month deserializer, which reads the names and indexes but not the enum features, so a
+   * mapper that writes enums in lower case ({@code EnumFeature.WRITE_ENUMS_TO_LOWERCASE}) can't read a Month back.
+   */
+  static final class Jackson2MonthSerializers extends Serializers.Base {
+
+    @Override
+    public ValueSerializer<?> findEnumSerializer(SerializationConfig config, JavaType type,
+        BeanDescription.Supplier beanDescRef, JsonFormat.Value formatOverrides) {
+      if (type.hasRawClass(Month.class)) {
+        return EnumSerializer.construct(Month.class, config, beanDescRef.get(),
+            calculateEffectiveFormat(beanDescRef, Month.class, formatOverrides));
+      }
+      return null;
+    }
+  }
+}
PATCH
