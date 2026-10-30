"""GENERATED SECTION. DO NOT HAND-EDIT. Compiled rubric items read /logs/verifier/grade.json; tests/test.sh starts
Reward Kit only when the reward gate in tests/grading/summarize.py is open."""

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


rk.rubric_item("R1", "The upstream plugins::call_decl::call_custom_command test passes", weight=5, name="R1")
rk.rubric_item("R2", "The upstream save::custom_converter_binds_its_flags test passes", weight=3, name="R2")
rk.rubric_item("R3", "The upstream save::custom_converter_checks_its_input_type test passes", weight=3, name="R3")
rk.rubric_item("R4", "The upstream network::http::get::http_get_with_custom_converter test passes", weight=3, name="R4")
rk.rubric_item("R5", "The upstream repl::test_parser::percent_dynamic_dispatch_rejects_list_spread_without_rest test passes", weight=3, name="R5")
rk.rubric_item("R6", "Every authored fail-to-pass case (c01 to c04, c07 to c12, c14 to c21; 18 cases) produces the reference output", weight=5, name="R6")
rk.rubric_item("R7", "The frame passes, every upstream test that passed at base passing in every workspace test target", weight=5, name="R7")
rk.rubric_item("R9", "The authored pass-to-pass cases p01 to p04 (4 cases) produce the output the base commit produces", weight=3, name="R9")
