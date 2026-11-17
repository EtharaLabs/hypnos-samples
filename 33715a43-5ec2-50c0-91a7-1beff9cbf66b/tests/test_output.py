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


rk.rubric_item("R1", "The upstream biome_js_analyze spec_tests test specs::nursery::use_exhaustive_switch_cases::issue7747_invalid_ts passes (1 test)", weight=5, name="R1")
rk.rubric_item("R2", "The upstream biome_js_analyze spec_tests tests use_exhaustive_switch_cases::invalid_numeric_literals_ts and valid_numeric_literals_ts pass (2 tests)", weight=3, name="R2")
rk.rubric_item("R3", "The upstream biome_js_analyze spec_tests tests indexed_access_invalid_ts of no_floating_promises, no_unsafe_plus_operands, no_useless_type_conversion, use_await_thenable, no_unnecessary_conditions and use_array_sort_compare, and no_unnecessary_conditions::indexed_access_valid_ts, pass (7 tests)", weight=5, name="R3")
rk.rubric_item("R4", "The upstream biome_js_analyze spec_tests test specs::nursery::no_useless_type_conversion::invalid_ts passes (1 test)", weight=3, name="R4")
rk.rubric_item("R5", "The upstream biome_module_graph spec_tests tests normalization::test_normalize_type_projections and normalization::test_type_projections_track_imports_without_whole_module_inference pass (2 tests)", weight=3, name="R5")
rk.rubric_item("R6", "Every authored fail-to-pass case f1 to f7 (7 cases), a biome lint run of the built binary, produces the reference diagnostics and exit status", weight=5, name="R6")
rk.rubric_item("R7", "The frame passes, every workspace test that passed at base passing in every test target, by name and by count", weight=5, name="R7")
rk.rubric_item("R9", "Every authored pass-to-pass case g1 to g8 (8 cases) produces the base output: no diagnostic and exit status 0", weight=3, name="R9")
