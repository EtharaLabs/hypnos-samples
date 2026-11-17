# Golden trajectory

## Ordered path

1. Reproduce issue 11514: the second body of namespace Test reads a, which the first body exports; the emitted IIFE reads an undeclared a and throws ReferenceError.
2. Reproduce issue 11607: an outer const a captures the reference instead of Test.a.
3. Treat TypeScript's rule, not the one case: a merged namespace or enum is one declaration whose exported members are in scope in every body, in either order, through nested and dotted declarations, for reads and for writes, while names a body binds itself keep their binding.
4. Emit exactly the runtime objects tsc emits: no object for namespaces holding only types, an object for namespaces holding only ambient values, and import aliases that evaluate as tsc's do.
5. Evaluate enum members as tsc does: constant initializers through namespace constants and aliases, implicit increments, references to later const bindings, member names shadowing outer names.
6. Check behaviour by running emitted code against what tsc's output does, and keep the existing tests passing.

## Deliverables and red lines

- `D1` at `Rust sources under /app/crates/swc_ecma_transforms_typescript/src, /app/crates/swc_ecma_transforms_base/src, /app/crates/swc_ecma_utils/src, /app/crates/swc_atoms/src`: The JavaScript the TypeScript transform emits for namespace, enum and import-alias declarations, single or merged from several bodies, behaves when run exactly as the JavaScript tsc emits for the same program: the same namespace and enum objects and no others, with the same members, values and reverse mappings; an unqualified name in a body resolves to a member any body of the same declaration exports before an outer binding, names the body binds itself keep their binding, and enum members are evaluated as tsc evaluates them; under tsEnumIsMutable unset, enum member reads may still be inlined.
- `RL1`: The graded result is computed from Rust sources under crates/swc_ecma_transforms_typescript/src, crates/swc_ecma_transforms_base/src, crates/swc_ecma_utils/src, crates/swc_atoms/src alone; every tests/ directory, every other directory, every Cargo.toml, Cargo.lock, .cargo/ and every build file are taken from the pristine base (with the hidden tests and the swc_ecma_utils hashbrown dependency line) before grading. Enforced by tests/grading/grade.sh, which copies the agent's graded source directories onto /opt/base-src and drops symlinks.
- `RL2`: No network is reachable from the agent environment, so the merged fix and crates.io cannot be fetched. Enforced by environment and agent network_mode no-network.
- `RL3`: Every test of the four graded packages' test targets that passed at the base commit (with the hidden tests applied) must run and pass afterwards, counted by name and by each target's pass count, except the named tests that pin the exact emitted text or syntax-context numbering of TypeScript programs holding namespace, enum or import-alias declarations. Enforced by the frame in tests/grading/summarize.py against tests/grading/base-frame.json, and the reward gate in tests/test.sh.

## Rubric items

- `R1` (compiled, weight 5, D1, outcome): The two issues' reproducers behave as tsc's output: a later body's name resolves to the member an earlier body exports, ahead of an outer binding (hidden runtime cases issue_11514, issue_11607).
- `R2` (compiled, weight 5, D1, coverage): Members resolve across every body of a declaration: forward references to later bodies, nested and dotted declarations merged across outer bodies, same-named members of sibling namespaces (hidden runtime cases namespace_bindings__cross_body, namespace_bindings__nested, namespace_bindings__emission_identities).
- `R3` (compiled, weight 5, D1, constraints): Names a body binds itself keep their binding and writes to merged members write the member (hidden runtime cases namespace_bindings__shadowing, namespace_bindings__reference_roles, namespace_bindings__writes).
- `R4` (compiled, weight 5, D1, coverage): Exactly tsc's namespace objects and import-alias values exist for type-only, ambient and alias-only declarations (hidden runtime cases namespace_bindings__ambient_instantiation, namespace_bindings__exported_type_alias, namespace_bindings__private_alias_instantiation, enum_semantics__ambient_export_initializer).
- `R5` (compiled, weight 5, D1, coverage): Enum members evaluate as tsc evaluates them (hidden runtime cases enum_semantics__constants, enum_semantics__body_identity__availability__const_order, enum_semantics__body_identity__availability__wrapped_iife, enum_semantics__regions, semantic_config__mutable_initializers, namespace_bindings__enum_shadow).
- `R6` (compiled, weight 5, RL3, constraints): The frame passes: every test of the four graded packages that passed at base passes, by name and by count, except the named exclusions.
- `R7` (judged, weight 3, D1, constraints): prohibited: the change makes namespace, enum or import-alias declarations behave as TypeScript defines them only for particular declaration names, member names or inputs, such as ones taken from the issue's example or from tests, rather than for every program.

## Authored cases

- `issue_11514` (R1): the reproducer of issue 11514 (two exported bodies of namespace Test; observed: the module's exports, Test.a 1 and Test.b 2).
- `issue_11607` (R1): the reproducer of issue 11607 (an outer const a between two bodies of namespace Test; observed: Test.b is 2).
- `upstream runtime fixtures` (R2 to R5 and the frame): every exec.ts the pull request adds under crates/swc_ecma_transforms_typescript/tests/{fixture,semantic-config}, compiled with the default configuration (or the fixture's config.json), run at module top level through tests/runtime-semantics/observe.mjs and compared with the record tsc 5.9.3's full-program emit produces; 36 kept.
- dropped: upstream runtime fixture decorators__enum_availability__eager: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__alias_dependency_paths: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__aliases: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__body_identity__availability__nested: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__body_identity__availability__regions: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__body_identity__member_order: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__computed_write_reads: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__const_usage: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__delete_targets: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__enum_initializer_binding_owners: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__enum_initializer_binding_owners__untyped: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__folded_reference_retention: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__late_runtime_scope: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__merged_const_enum: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__parameter_owners: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__reference_uses: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__runtime_namespaces: fix differs from tsc.
- dropped: upstream runtime fixture enum_semantics__scoped_queries: fix differs from tsc.
- dropped: upstream runtime fixture namespace_bindings__ambient_exports: fix differs from tsc.
- dropped: upstream runtime fixture namespace_bindings__fused_type_uses__untyped: resolver-without-types variant (needs an API sentence).
- dropped: upstream runtime fixture namespace_bindings__parameter_type_merge__untyped: resolver-without-types variant (needs an API sentence).
- dropped: upstream runtime fixture namespace_bindings__reference_roles__untyped: resolver-without-types variant (needs an API sentence).
- dropped: every upstream exact-output snapshot (fixture/*/output.js, semantic-config output.js, ts-resolver output.ts, tsc-references): the emitted text, generated parameter names and inlining are implementation choices the statement leaves open, so the fixtures are graded by running the emitted code instead (OF19).
- dropped: the upstream minified runtime variants and the span-normalised snapshot variants: they exercise the minifier and span handling, not a consequence the statement states.
- dropped: the swc crate's tsc-references outputs: exact text of a different pipeline (OF19).

## Rejected routes

- `kw_headline`: Collect the names each body of a namespace exports and rewrite an unqualified read in a later body that is unresolved or resolves to a module-level binding to NS.name: R1 passes, R2 to R5 fail.
- `kw_headline_plus_one`: The headline fix plus forward references (names exported by any body, earlier or later): R1 passes, nested, written and enum cases still fail.
