# JDK types lost their 7.x wire format, and generated CRDs reject what the client writes

The Jackson 3 migration guide promises that the default `KubernetesSerialization` keeps the 2.x wire format for users' own types. On this commit four JDK types break that promise, while everything else (including the built-in model types) is byte-identical to what 7.9.0 wrote:

- `Year`: `"2024"` became `2024`.
- `Month`: `"JANUARY"` became `0`. The CRD generator declares it `type: string`, so the API server rejects (422) any custom resource with a `Month` field.
- `java.sql.Date`: `"2024-01-15"` became `"2024-01-14T23:00:00.000+00:00"`, local midnight as a UTC instant, so the day depends on the JVM timezone.
- `Locale`: `es_ES` became `es-ES` and `zh_TW_#Hant` became `zh-Hant-TW`. Reading is worse: values and map keys that 7.x wrote with a script or extension (`zh_TW_#Hant`, `th_TH_#u-nu-thai`) silently lose it, and 7.x misreads the new form.

`JsonMapper.builderWithJackson2Defaults()` restores none of these, and Jackson has no setting for them.

The CRD generator has the matching problem: it emits schemas that reject what the client writes. Jackson writes a `byte[]` as a base64 string, but the generated schema is an array of integers, so any custom resource with a non-null `byte[]` is rejected; `char[]` and `QName` are written as strings but declared an array and an object; integer properties carry no `int32`/`int64` format, unlike what controller-gen emits for the Go equivalents. And `@PrinterColumn` on a `LocalDate` property produces a `date` column, which the API server renders as the age of an RFC 3339 timestamp, so it always shows `<invalid>`.

Fix both sides.

**Client.** Provide a public Jackson 3 module `io.fabric8.kubernetes.model.jackson.Jackson2JdkTypesModule` (public no-argument constructor) in the `kubernetes-model-common` artifact. A mapper with it registered writes `Year`, `Month`, `java.sql.Date` and `Locale` (as values and as map keys) exactly as Jackson 2.x did, honouring `@JsonFormat` and `WRITE_DATES_AS_TIMESTAMPS` the way Jackson 2.x did; `Month` is handled like any other enum, as Jackson 2.x had no special case for it. It reads both forms back into the same value: every `Locale` in its 2.x form (`Locale.toString()` of any locale, including those BCP 47 cannot express) and in its BCP 47 form, as values and as map keys; and a `yyyy-MM-dd` `java.sql.Date` as that local date, so it keeps its day in any JVM timezone. A `java.sql.Date` with a `@JsonFormat` pattern (even `yyyy-MM-dd`) is read with that pattern and its timezone exactly as Jackson 3 reads it today. Input in any other form is read as Jackson 3 reads it today. A schema generator working from a mapper with the module registered describes exactly what that mapper writes (for example `type: string, format: date` for a `java.sql.Date` written as `yyyy-MM-dd`, and no format the written value would not match).

`new KubernetesSerialization()` (and so the default client and `Serialization.jsonMapper()`), `Serialization.yamlMapper()` and the CRD generator's default mapper must write these four types like 7.9.0 did and read both forms. A mapper the caller passes to `KubernetesSerialization` keeps its own handling of these types: its own serializers, and Jackson 3's forms unless the caller registers the module.

**Generated CRDs.** Emit what controller-gen emits for the equivalent Go type, and never emit a schema that rejects the value the client writes:

- `byte[]` and `ByteBuffer` (also inside `Optional`, as list items and as map values) are `type: string, format: byte`, like Go's `[]byte`. `Byte[]` and `List<Byte>` stay arrays of integers, because that is what Jackson writes for them. `@Size` on a binary value keeps counting bytes: its length bounds are the tightest ones that accept the base64 string of every value within those limits.
- `char[]` and `QName` are `type: string`.
- `int`/`Integer` values get `format: int32` and `long`/`Long` values `format: int64` (wherever such a value appears, including `OptionalInt`/`OptionalLong`, the atomic types, arrays, list items and map values); `short`, `byte`, `BigInteger` and floating point types get no format.
- Following the restored wire format, `Year`, `Month` and `Locale` are `type: string`, and a `java.sql.Date` property is `type: string, format: date` (as a list item it is `type: string` with no format). `java.sql.Timestamp` stays `type: string, format: date-time`.
- `@PrinterColumn` on a property with `format: date` (`LocalDate`, `java.sql.Date`) produces a `string` column; `date-time` properties keep their `string` column.

Everything else that works on this commit today must keep working.

Make your change only in the main sources (the existing `src/main/java` trees of the model, client API, generator annotations and CRD generator modules and of the modules they build on); do not rely on changes to tests, test resources or any `pom.xml`. There is no network. The JDK (21) and Maven are installed, and `~/.m2` is an offline Maven repository (`settings.xml` sets offline mode) holding every plugin and dependency needed to build the model, client API, generator annotations and CRD generator modules with everything they depend on and to run their tests, plus this commit's modules already installed. Build a module and the modules it depends on with `mvn -o -T 8 -pl <module-dir> -am install -DskipTests` (about two minutes for the largest), then run its tests with `mvn -o -pl <module-dir> test` or a single class with `-Dtest=<TestClass>`; a module's own tests take under a minute. Tests that download a Kubernetes API server cannot run offline.
