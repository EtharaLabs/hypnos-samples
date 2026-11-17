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
package io.fabric8.kubernetes.model.jackson;

import com.fasterxml.jackson.annotation.JsonFormat;
import tools.jackson.core.JsonGenerator;
import tools.jackson.core.JsonParser;
import tools.jackson.core.JsonToken;
import tools.jackson.databind.BeanDescription;
import tools.jackson.databind.BeanProperty;
import tools.jackson.databind.DeserializationContext;
import tools.jackson.databind.JavaType;
import tools.jackson.databind.KeyDeserializer;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.ValueDeserializer;
import tools.jackson.databind.ValueSerializer;
import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.cfg.SerializerFactoryConfig;
import tools.jackson.databind.deser.jdk.EnumDeserializer;
import tools.jackson.databind.deser.std.FromStringDeserializer;
import tools.jackson.databind.deser.std.StdScalarDeserializer;
import tools.jackson.databind.ext.javatime.ser.YearSerializer;
import tools.jackson.databind.ext.sql.JavaSqlDateDeserializer;
import tools.jackson.databind.ext.sql.JavaSqlDateSerializer;
import tools.jackson.databind.introspect.EnumNamingStrategyFactory;
import tools.jackson.databind.jsonFormatVisitors.JsonFormatVisitorWrapper;
import tools.jackson.databind.jsonFormatVisitors.JsonValueFormat;
import tools.jackson.databind.module.SimpleModule;
import tools.jackson.databind.ser.BeanSerializerFactory;
import tools.jackson.databind.ser.jdk.EnumSerializer;
import tools.jackson.databind.ser.std.StdScalarSerializer;
import tools.jackson.databind.util.EnumResolver;

import java.sql.Date;
import java.text.DateFormat;
import java.text.SimpleDateFormat;
import java.time.Month;
import java.time.Year;
import java.time.format.DateTimeFormatter;
import java.util.IllformedLocaleException;
import java.util.Locale;

/** Restores the Jackson 2 wire representation of JDK types changed by Jackson 3. */
public class Jackson2JdkTypesModule extends SimpleModule {
  public Jackson2JdkTypesModule() {
    addSerializer(Year.class, new LegacyYearSerializer());
    // Let the normal enum serializer apply enum features and contextual annotations.
    addSerializer(Month.class, new StdScalarSerializer<Month>(Month.class) {
      @Override
      public ValueSerializer<?> createContextual(SerializationContext ctxt,
          BeanProperty property) {
        JavaType type = ctxt.constructType(Month.class);
        JsonFormat.Value format = findFormatOverrides(ctxt, property, Month.class);
        if (format != null
            && (format.getShape() == JsonFormat.Shape.OBJECT || format.getShape() == JsonFormat.Shape.POJO)) {
          return new EnumPojoSerializerFactory().serializer(ctxt, type, format, property);
        }
        return EnumSerializer.construct(Month.class, ctxt.getConfig(), ctxt.introspectBeanDescription(type),
            format).createContextual(ctxt, property);
      }

      @Override
      public void serialize(Month value, JsonGenerator gen, SerializationContext ctxt) {
        gen.writeString(value.name());
      }
    });
    addDeserializer(Month.class, new StdScalarDeserializer<Month>(Month.class) {
      @Override
      public ValueDeserializer<?> createContextual(DeserializationContext ctxt,
          BeanProperty property) {
        var config = ctxt.getConfig();
        var annotated = ctxt.introspectBeanDescription(ctxt.constructType(Month.class)).getClassInfo();
        var naming = EnumNamingStrategyFactory.createEnumNamingStrategyInstance(
            config.getAnnotationIntrospector().findEnumNamingStrategy(config, annotated),
            config.canOverrideAccessModifiers(), config.getEnumNamingStrategy());
        return new EnumDeserializer(
            EnumResolver.constructFor(config, annotated),
            config.isEnabled(MapperFeature.ACCEPT_CASE_INSENSITIVE_ENUMS),
            naming == null ? null : EnumResolver.constructUsingEnumNamingStrategy(config, annotated, naming),
            EnumResolver.constructUsingToString(config, annotated))
            .createContextual(ctxt, property);
      }

      @Override
      public Month deserialize(JsonParser parser, DeserializationContext ctxt) {
        return (Month) createContextual(ctxt, null).deserialize(parser, ctxt);
      }
    });
    addSerializer(Date.class, new LegacySqlDateSerializer(null, null));
    addDeserializer(Date.class, new LegacySqlDateDeserializer());
    addSerializer(Locale.class, new StdScalarSerializer<Locale>(Locale.class) {
      @Override
      public void serialize(Locale value, JsonGenerator gen, SerializationContext ctxt) {
        gen.writeString(value.toString());
      }
    });
    addKeySerializer(Locale.class, new StdScalarSerializer<Locale>(Locale.class) {
      @Override
      public void serialize(Locale value, JsonGenerator gen, SerializationContext ctxt) {
        gen.writeName(value.toString());
      }
    });
    addDeserializer(Locale.class, new FromStringDeserializer<Locale>(Locale.class) {
      @Override
      protected boolean _shouldTrim() {
        return false;
      }

      @Override
      protected Object _deserializeFromEmptyString(DeserializationContext ctxt) {
        return Locale.ROOT;
      }

      @Override
      protected Locale _deserialize(String value, DeserializationContext ctxt) {
        return parseLocale(value);
      }
    });
    addKeyDeserializer(Locale.class, new KeyDeserializer() {
      @Override
      public Object deserializeKey(String key, DeserializationContext ctxt) {
        return parseLocale(key);
      }
    });
  }

  private static Locale parseLocale(String value) {
    if (!value.contains("_")) {
      return value.contains("-") ? Locale.forLanguageTag(value) : new Locale(value);
    }
    String[] parts = value.split("_#", 2);
    String[] base = parts[0].split("_", 3);
    Locale locale = new Locale(base[0], base.length > 1 ? base[1] : "", base.length > 2 ? base[2] : "");
    if (parts.length == 1) {
      return locale;
    }
    // A legacy variant may not be a BCP 47 variant. Build the script/extensions separately.
    String suffix = parts[1];
    String script = suffix.length() >= 4 && suffix.charAt(0) != 'u' && suffix.charAt(0) != 'x'
        && (suffix.length() == 4 || suffix.charAt(4) == '_') ? suffix.substring(0, 4) : "";
    String extensions = script.isEmpty() ? suffix : suffix.length() == 4 ? "" : suffix.substring(5);
    Locale tags = Locale.forLanguageTag("und" + (script.isEmpty() ? "" : "-" + script)
        + (extensions.isEmpty() ? "" : "-" + extensions));
    // Preserve the constructor's legacy compatibility variants as well as extensions.
    if (script.isEmpty() && tags.getExtensionKeys().equals(locale.getExtensionKeys())
        && tags.getExtensionKeys().stream().allMatch(key -> tags.getExtension(key).equals(locale.getExtension(key)))) {
      return locale;
    }
    try {
      Locale.Builder builder = new Locale.Builder().setLocale(locale).setScript(tags.getScript());
      for (Character key : tags.getExtensionKeys()) {
        builder.setExtension(key, tags.getExtension(key));
      }
      return builder.build();
    } catch (IllformedLocaleException ex) {
      Locale.Builder builder = new Locale.Builder().setLanguage(locale.getLanguage())
          .setRegion(locale.getCountry()).setScript(tags.getScript());
      for (Character key : tags.getExtensionKeys()) {
        builder.setExtension(key, tags.getExtension(key));
      }
      String tag = builder.build().toLanguageTag();
      return Locale.forLanguageTag(tag + (tags.getExtension('x') == null ? "-x" : "")
          + "-lvariant-" + locale.getVariant().replace('_', '-'));
    }
  }

  /** Uses the ordinary enum-to-bean path for an explicit object shape. */
  private static class EnumPojoSerializerFactory extends BeanSerializerFactory {
    EnumPojoSerializerFactory() {
      super(new SerializerFactoryConfig());
    }

    ValueSerializer<?> serializer(SerializationContext ctxt, JavaType type, JsonFormat.Value format, BeanProperty property) {
      BeanDescription description = ctxt.introspectBeanDescription(type);
      BeanDescription.Supplier supplier = description.supplier();
      buildEnumSerializer(ctxt, type, supplier, format);
      ValueSerializer<?> serializer = constructBeanOrAddOnSerializer(ctxt, type, supplier, format, false);
      serializer.resolve(ctxt);
      return serializer.createContextual(ctxt, property);
    }
  }

  private static class LegacyYearSerializer extends YearSerializer {
    LegacyYearSerializer() {
      super();
    }

    LegacyYearSerializer(LegacyYearSerializer base, DateTimeFormatter formatter, Boolean timestamp) {
      super(base, formatter, timestamp);
    }

    @Override
    public void acceptJsonFormatVisitor(JsonFormatVisitorWrapper visitor, JavaType type) {
      if (useTimestamp(visitor.getContext())) {
        super.acceptJsonFormatVisitor(visitor, type);
      } else {
        visitStringFormat(visitor, type);
      }
    }

    @Override
    protected YearSerializer withFormat(DateTimeFormatter formatter, Boolean timestamp, JsonFormat.Shape shape) {
      return new LegacyYearSerializer(this, formatter, timestamp);
    }

    @Override
    protected boolean useTimestampFromGlobalDefaults(SerializationContext ctxt) {
      return ctxt != null && ctxt.isEnabled(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS);
    }
  }

  private static class LegacySqlDateSerializer extends JavaSqlDateSerializer {
    LegacySqlDateSerializer(Boolean timestamp, DateFormat format) {
      super(timestamp, format);
    }

    @Override
    public JavaSqlDateSerializer withFormat(Boolean timestamp, DateFormat format) {
      return new LegacySqlDateSerializer(timestamp, format);
    }

    @Override
    public void serialize(Date value, JsonGenerator gen, SerializationContext ctxt) {
      if (!_asTimestamp(ctxt) && _customFormat == null) {
        gen.writeString(value.toString());
      } else {
        super.serialize(value, gen, ctxt);
      }
    }

    @Override
    public void acceptJsonFormatVisitor(JsonFormatVisitorWrapper visitor, JavaType type) {
      if (!_asTimestamp(visitor.getContext())) {
        if (_customFormat == null || _customFormat instanceof SimpleDateFormat
            && "yyyy-MM-dd".equals(((SimpleDateFormat) _customFormat).toPattern())) {
          visitStringFormat(visitor, type, JsonValueFormat.DATE);
        } else {
          visitStringFormat(visitor, type);
        }
      } else {
        super.acceptJsonFormatVisitor(visitor, type);
      }
    }
  }

  private static class LegacySqlDateDeserializer extends JavaSqlDateDeserializer {
    LegacySqlDateDeserializer() {
      super();
    }

    @Override
    public Date deserialize(JsonParser parser, DeserializationContext ctxt) {
      if (_customFormat == null && parser.hasToken(JsonToken.VALUE_STRING)
          && parser.getString().matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) {
        try {
          return Date.valueOf(java.time.LocalDate.parse(parser.getString()));
        } catch (java.time.DateTimeException ex) {
          // Preserve Jackson's error and coercion handling for other input.
        }
      }
      return super.deserialize(parser, ctxt);
    }
  }
}
