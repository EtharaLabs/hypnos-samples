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


rk.rubric_item("R1", "Live imports: imported bindings are read where the source reads them, through calls, awaits, closures, aliases, loops, try/finally, generators, templates, conditions and top-level code, while namespace objects stay stable (hidden runtime cases live_imports__await, live_imports__closure, live_imports__condition_value, live_imports__conditional, live_imports__default_call, live_imports__default_function, live_imports__function_snapshot, live_imports__generator, live_imports__iife_snapshot, live_imports__loop_delta, live_imports__member_snapshot, live_imports__named_call, live_imports__namespace_member, live_imports__renamed, live_imports__result_order, live_imports__stable_aliases, live_imports__template, live_imports__top_level_order, live_imports__try_finally)", weight=5, name="R1")
rk.rubric_item("R2", "Parameter defaults that name an outer function, class or object yield that same value on every call, for plain, destructured (nested and rest), method, constructor, setter, computed-key, nested-function and every function kind, with and without mangling and repeated passes (hidden runtime cases default_params__class_methods, default_params__class_value, default_params__computed_keys, default_params__constructor_default, default_params__destructured_array, default_params__destructured_object, default_params__expression_hook, default_params__function_expressions, default_params__function_kinds, default_params__initializer_effects, default_params__nested_array, default_params__nested_function, default_params__object_method, default_params__parameter_scope, default_params__reassigned_default, default_params__report_passes, default_params__rest_pattern, default_params__setter_default, default_params__shared_object)", weight=5, name="R2")
rk.rubric_item("R3", "(0, super.method) calls with any sequence head, tagged templates, computed, optional and spread forms keep this undefined in class methods, accessors, static methods, fields, static blocks, arrows, async methods, modules and object literals (hidden runtime cases super_callee__class_fields, super_callee__computed_optional, super_callee__methods, super_callee__module_class, super_callee__object_literals, super_callee__sequence_heads, super_callee__static_accessors)", weight=5, name="R3")
rk.rubric_item("R4", "With keep_fnames/keep_classnames, functions, arrows and classes the source leaves anonymous inside (0, ...) gain no inferred name in any naming position: declarations, exports, string, numeric, computed, symbol and private keys, class fields, destructuring and parameter defaults and logical assignments, with or without mangling (hidden runtime cases kept_names__classnames_only, kept_names__destructuring_defaults, kept_names__fnames_only, kept_names__function_kinds, kept_names__mangled_toplevel, kept_names__module_exports, kept_names__nested_sequence, kept_names__property_keys, kept_names__sequences, kept_names__side_effect_head)", weight=5, name="R4")
rk.rubric_item("R5", "With mangle keep_classnames, a class's references to itself in static fields, static blocks, private static members, methods, nested classes, new.target checks, shorthand properties and destructuring assignments keep working, also for exported, derived and mutually referring classes (hidden runtime cases class_self__class_expression, class_self__derived_nested, class_self__keep_both, class_self__module_toplevel, class_self__mutual_statics, class_self__new_target, class_self__plain_mangle, class_self__private_statics, class_self__registry, class_self__shorthand_destructuring_assignment, class_self__shorthand_destructuring_default, class_self__shorthand_method_reassignment, class_self__shorthand_static_block, class_self__shorthand_static_field, class_self__static_members)", weight=5, name="R5")
rk.rubric_item("R6", "Constant factors of * are regrouped only where the result is the same for every value, including chains formed by inlined constants or merged assignments, in modules and methods, and near overflow and underflow (hidden runtime cases float_mul__factors, float_mul__in_expressions, float_mul__inlined_constants, float_mul__merged_steps, float_mul__module_methods, float_mul__more_factors, float_mul__range_limits, float_mul__three_factors, float_mul__unit_conversion)", weight=5, name="R6")
rk.rubric_item("R7", "The frame passes: every test of the five graded packages that passed at base passes, by name and by count, except the named exclusions", weight=5, name="R7")
