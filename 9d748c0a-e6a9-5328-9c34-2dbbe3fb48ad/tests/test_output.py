"""Compiled rubric items, read from /logs/verifier/grade.json."""

import json
from pathlib import Path

import rewardkit as rk
from rewardkit import criterion

GRADE = Path("/logs/verifier/grade.json")


@criterion(description="{item}: {text}")
def rubric_item(workspace: Path, item: str, text: str) -> float:
    if not GRADE.is_file():
        return 0.0
    grade = json.loads(GRADE.read_text())
    if grade.get("gate", {}).get("open") is not True:
        return 0.0
    return 1.0 if grade.get("items", {}).get(item) is True else 0.0


rk.rubric_item("R1", "The upstream Jackson2JdkTypesModuleTest passes in all 61 cases: the Jackson 2 form of Year, Month, java.sql.Date and Locale values and map keys, WRITE_DATES_AS_TIMESTAMPS, @JsonFormat patterns and shapes, WRITE_ENUMS_USING_INDEX, the reported schemas, java.sql.Date read as a local date in three timezones and anything else read like Jackson, and Locale values and keys read back from the 2.x, BCP 47 and legacy forms, the empty string and und", weight=5, name="R1")
rk.rubric_item("R2", "The upstream KubernetesSerializationJdkTypesTest fail-to-pass cases pass (7): new KubernetesSerialization() writes every JDK type of the sample exactly like the 7.9.0 golden file and reads it back in three timezones, and Serialization.yamlMapper() writes Month, java.sql.Date and Locale like 7.9.0's yamlMapper", weight=5, name="R2")
rk.rubric_item("R3", "The upstream TypeMappingsTest and JsonSchemaTest fail-to-pass cases pass (37): type and format of byte[], ByteBuffer, Optional/List/Map of byte[], Byte[], List<Byte>, char[], QName (also as a reference), int/long and their Optional, atomic, array, list and map forms, Year, Month (with its enum names), Locale and java.sql.Date, @Size on binary types as base64 lengths, and properties whose own serializer or converter keeps its reported schema", weight=5, name="R3")
rk.rubric_item("R4", "The upstream PrinterColumnTypeTest and the new ResolvingContextMapperTest case pass: @PrinterColumn on Instant, LocalDate and java.sql.Date properties produces string columns, and the CRD generator's default mapper writes Year, Month, java.sql.Date and Locale in their Jackson 2 form", weight=3, name="R4")
rk.rubric_item("R5", "The regenerated CRDs match upstream (19 cases): the 13 changed CRDGeneratorApprovalTest approved YAML files (int32/int64 formats, the new jdktypes CRD, the LocalDate printer column) and the CRD generator API tests comparing the k8svalidations and complexkinds CRDs", weight=3, name="R5")
rk.rubric_item("R6", "The authored guard KubernetesSerializationCallerMapperTest passes in its 3 cases: a mapper the caller passes to KubernetesSerialization (Jackson 3 defaults, or Jackson 2 defaults) keeps writing Year, Month and Locale the way it does on its own, and a Locale serializer the caller registered keeps writing it", weight=3, name="R6")
rk.rubric_item("R7", "The frame holds: every one of the 1025 tests that pass at base with the hidden tests applied, apart from the timing-dependent AsyncUtilsTest and CachedSingleThreadSchedulerTest#testAutoShutdown, passes by name and count across kubernetes-model-common, kubernetes-client-api, crd-generator/api-v2 and crd-generator/test, including the unchanged approved CRDs, the plain Jackson 3 reads of KubernetesSerializationJdkTypesTest and the rest of TypeMappingsTest", weight=5, name="R7")
