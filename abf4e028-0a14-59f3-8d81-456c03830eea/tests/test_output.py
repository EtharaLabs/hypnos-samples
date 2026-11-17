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


rk.rubric_item("R1", "The two issues' reproducers behave as tsc's output: a later body's name resolves to the member an earlier body exports, ahead of an outer binding (hidden runtime cases issue_11514, issue_11607)", weight=5, name="R1")
rk.rubric_item("R2", "Members resolve across every body of a declaration: forward references to later bodies, nested and dotted declarations merged across outer bodies, same-named members of sibling namespaces (hidden runtime cases namespace_bindings__cross_body, namespace_bindings__nested, namespace_bindings__emission_identities)", weight=5, name="R2")
rk.rubric_item("R3", "Names a body binds itself keep their binding and writes to merged members write the member (hidden runtime cases namespace_bindings__shadowing, namespace_bindings__reference_roles, namespace_bindings__writes)", weight=5, name="R3")
rk.rubric_item("R4", "Exactly tsc's namespace objects and import-alias values exist for type-only, ambient and alias-only declarations (hidden runtime cases namespace_bindings__ambient_instantiation, namespace_bindings__exported_type_alias, namespace_bindings__private_alias_instantiation, enum_semantics__ambient_export_initializer)", weight=5, name="R4")
rk.rubric_item("R5", "Enum members evaluate as tsc evaluates them (hidden runtime cases enum_semantics__constants, enum_semantics__body_identity__availability__const_order, enum_semantics__body_identity__availability__wrapped_iife, enum_semantics__regions, semantic_config__mutable_initializers, namespace_bindings__enum_shadow)", weight=5, name="R5")
rk.rubric_item("R6", "The frame passes: every test of the four graded packages that passed at base passes, by name and by count, except the named exclusions", weight=5, name="R6")
