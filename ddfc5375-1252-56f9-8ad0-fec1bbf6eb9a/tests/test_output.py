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


rk.rubric_item("R1", "The reported case: the upstream peephole::remove_unused_declaration::remove_recursive_unused_function_declaration test passes (self- and mutually recursive function declarations in a module, including a cycle whose only outside reference is in dead code)", weight=5, name="R1")
rk.rubric_item("R2", "Dead cycles inside a used function: the upstream peephole::remove_unused_declaration::remove_recursive_unused_nested_in_live_function test passes", weight=3, name="R2")
rk.rubric_item("R3", "Function-valued bindings that refer only to themselves: the upstream peephole::remove_unused_declaration::remove_self_recursive_function_valued_declarators and remove_self_recursive_for_init_declarator tests pass", weight=3, name="R3")
rk.rubric_item("R4", "Liveness only from code that can never run, including a direct eval in dead code: the upstream peephole::remove_unused_declaration::remove_recursive_function_after_eval_dropped test passes", weight=3, name="R4")
rk.rubric_item("R5", "CommonJS and script sources: the upstream peephole::remove_unused_declaration::analyze_commonjs_and_script_local_functions, keep_commonjs_references_and_script_global_functions and keep_sloppy_duplicate_block_functions tests pass", weight=3, name="R5")
rk.rubric_item("R6", "Dead-code-elimination-only compression: the upstream peephole::dead_code_elimination::dce_recursive_unused_functions, dce_recursive_unused_functions_in_commonjs_and_script and dce_keeps_sloppy_duplicate_block_functions tests pass", weight=3, name="R6")
rk.rubric_item("R7", "Exports after a cycle is removed: the upstream peephole::remove_unused_declaration::keep_exported_var_initializer_when_a_dead_cycle_held_its_only_reference, keep_exported_binding_writes_when_a_dead_cycle_held_its_other_reads, keep_exported_iife_init_when_a_dead_cycle_held_its_only_reference, module_export_observability_kinds and export_observability_ignores_declarations_inside_exported_arrow tests pass", weight=3, name="R7")
rk.rubric_item("R8", "Other observers after a cycle is removed: the upstream peephole::remove_unused_declaration::keep_sloppy_annex_b_alias_member_write_after_cycle_removed, keep_script_root_var_in_nested_statement_after_cycle_removed, keep_using_member_write_observed_by_disposal, peephole::dead_code_elimination::dce_keeps_implicitly_observable_bindings and dce_keeps_script_root_var_in_nested_statement_after_cycle_removed tests pass", weight=3, name="R8")
rk.rubric_item("R9", "Redeclarations and loop heads: the upstream peephole::remove_unused_declaration::recursive_function_var_redeclaration_converges_on_count_pass and for_head_reachability_uses_ordinary_references tests pass", weight=3, name="R9")
rk.rubric_item("R10", "The frame passes: every test that passed at base with the hidden tests passes in both test targets of oxc_minifier, by name and count", weight=5, name="R10")
