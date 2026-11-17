# Golden trajectory

## Ordered path

1. Reproduce the issue with the built biome binary on the reporter's file: no useExhaustiveSwitchCases diagnostic, and false unreachable-case reports from noUnnecessaryConditions for the keyof switch.
2. Trace how a type annotation such as (typeof X)[number] or keyof typeof X becomes inferred type data, and find that indexed-access and keyof annotations are dropped to unknown or kept unevaluated, so every rule reading the type sees nothing.
3. Represent indexed access in the inferred type data and evaluate it, and keyof, during normalisation once operands are resolved, through typeof, aliases, readonly and imports, without forcing whole-module inference.
4. Make the evaluation conservative: return unknown for any input whose union could be incomplete or whose spelling could differ from its value, and cap the work at 1024 members.
5. Compare numeric switch cases by value with a single rounding for radix literals, render missing numbers in JavaScript's shortest decimal form, and bail out of the rule on values it cannot represent.
6. Narrow the ~~ check to values a 32-bit truncation leaves unchanged.
7. Rebuild offline, run the analyzer and module-graph tests and the whole workspace suite, and check each stated shape by hand with the built binary.

## Deliverables and red lines

- `D1` at `Rust sources under /app/crates/*/src and /app/xtask/codegen/src`: Indexed-access types with a number index and keyof on object types resolve, in the type information every type-aware rule reads, to the union of tuple elements or property names, and stay unknown wherever that union could be incomplete or mis-spelled: mutable arrays, rest elements, non-number indices, escaped, quoted or multi-line strings, negative bigints, self-reference, more than 1024 members, spreads, index signatures, computed or numeric keys, setter-only members, inheritance, classes, intersections, and incomplete Pick, Omit, Readonly, Partial and Required sources.
- `D2` at `Rust sources under /app/crates/*/src and /app/xtask/codegen/src`: useExhaustiveSwitchCases compares number literal types and case values by numeric value with radix literals rounded once, lists missing numeric cases in shortest decimal form in union order without equal-valued repeats, and reports nothing when the discriminant or a case holds a value it cannot represent (non-finite, radix literal over 128 bits, template literal type) or a case string holds an escape.
- `D3` at `Rust sources under /app/crates/*/src and /app/xtask/codegen/src`: noUselessTypeConversion reports ~~x only when every possible value is a bigint or an integer number literal in the signed 32-bit range other than -0.
- `D4` at `Rust sources under /app/crates/*/src and /app/xtask/codegen/src`: Resolving one binding's projected type runs no whole-module type inference for its module or the modules it imports, does not normalise again after an unrelated module changes, and updates when the imported definitions change.
- `RL1`: The graded result is computed from Rust sources under crates/*/src and xtask/codegen/src alone; every tests/ directory, the test-support crates biome_test_utils, biome_formatter_test and tests_macros, every Cargo.toml, Cargo.lock, rust-toolchain.toml and every build.rs are taken from the pristine base before grading. Enforced by tests/grading/grade.sh, which copies the agent's crates/*/src (but the three test-support crates) and xtask/codegen/src onto /opt/base-src, the base with the hidden test patch, and drops symlinks.
- `RL2`: No network is reachable from the agent environment, so the merged fix, crates.io and the TypeScript sources the global-types generator downloads cannot be fetched. Enforced by environment and agent network_mode no-network.
- `RL3`: Every workspace library, binary and integration test that passed at the base commit with the hidden tests applied must run and pass afterwards, counted per test target by name and by passed count; the one exclusion is local_inference::infer_type_of_call_expression_with_type_arguments, whose snapshot prints the Debug form of an internal type. Enforced by the frame in tests/grading/summarize.py against tests/grading/base-frame.json, and the reward gate in tests/test.sh.
- `RL4`: No type-aware rule may draw a conclusion from a projection whose result the statement requires to stay unknown, and switches that are already exhaustive stay unreported. Enforced by the frame, which holds the eight pass-to-pass tests the upstream change added (issue7747Valid among them) to their base results, and the pass-to-pass cases of R9.

## Rubric items

- `R1` (compiled, weight 5, D1, outcome): The upstream biome_js_analyze spec_tests test specs::nursery::use_exhaustive_switch_cases::issue7747_invalid_ts passes (1 test).
- `R2` (compiled, weight 3, D2, coverage): The upstream biome_js_analyze spec_tests tests use_exhaustive_switch_cases::invalid_numeric_literals_ts and valid_numeric_literals_ts pass (2 tests).
- `R3` (compiled, weight 5, D1, coverage): The upstream biome_js_analyze spec_tests tests indexed_access_invalid_ts of no_floating_promises, no_unsafe_plus_operands, no_useless_type_conversion, use_await_thenable, no_unnecessary_conditions and use_array_sort_compare, and no_unnecessary_conditions::indexed_access_valid_ts, pass (7 tests).
- `R4` (compiled, weight 3, D3, coverage): The upstream biome_js_analyze spec_tests test specs::nursery::no_useless_type_conversion::invalid_ts passes (1 test).
- `R5` (compiled, weight 3, D4, constraints): The upstream biome_module_graph spec_tests tests normalization::test_normalize_type_projections and normalization::test_type_projections_track_imports_without_whole_module_inference pass (2 tests).
- `R6` (compiled, weight 5, D1, robustness): Every authored fail-to-pass case f1 to f7 (7 cases), a biome lint run of the built binary, produces the reference diagnostics and exit status.
- `R7` (compiled, weight 5, RL3, constraints): The frame passes, every workspace test that passed at base passing in every test target, by name and by count.
- `R8` (judged, weight 3, D1, constraints): prohibited: the change resolves indexed-access or keyof types only for particular identifiers, literal values, file names, or test inputs, such as names or strings taken from the issue's example or the tests, rather than for every type of the shapes the task describes.
- `R9` (compiled, weight 3, RL4, constraints): Every authored pass-to-pass case g1 to g8 (8 cases) produces the base output: no diagnostic and exit status 0.

## Authored cases (R6 fail-to-pass f*, R9 pass-to-pass g*)

- `f1` (D1): the issue's reproducer with its identifiers and values renamed: a switch over (typeof Directions)[number] and one over keyof (typeof Grades), each missing "W".
- `f2` (D1): projections through an imported binding and type aliases: ColorList[Num] with type Num = number, keyof of an aliased typeof, and (readonly [7, 8, 9])[number], each missing members.
- `f3` (D2): a union 16 | 0.25 | 100 | -3 matched by the cases 0x10, 25e-2, 1e2 and -0b11, which is exhaustive.
- `f4` (D1): noUnnecessaryConditions on ?? over a const-tuple projection, noFloatingPromises on an unused [Promise, Promise][number], and noUselessTypeConversion on String over string[][number].
- `f5` (D1): a switch over ["on", "off"?][number] with both strings handled, missing undefined.
- `f6` (D3): ~~-7, ~~-2147483649 and ~~2147483648, where only the first is useless.
- `f7` (D1): noUnnecessaryConditions with keyof over an interface that extends another, a class, a const object and an object with a numeric key: no case is reported unreachable.
- `g1` (RL4): pass-to-pass: a switch over (typeof xs)[number] for an array that is not as const.
- `g2` (RL4): pass-to-pass: a tuple with a rest element, a string index, an index signature and a computed key.
- `g3` (RL4): pass-to-pass: keyof an inheriting interface, of Readonly of it, of an intersection and of a class.
- `g4` (RL4): pass-to-pass: an escaped const-tuple element and an escaped object key.
- `g5` (RL4): pass-to-pass: exhaustive switches over a const-tuple projection, a keyof typeof and a numeric union.
- `g6` (RL4): pass-to-pass: keyof objects with a numeric key, quoted and unquoted.
- `g7` (RL4): pass-to-pass: an 1100-element const tuple and an 1100-key const object, both over the 1024 budget.
- `g8` (RL4): pass-to-pass: 300 exhaustive switches over const-tuple projections in one file.
- dropped: local_inference.rs hunks that match the new IndexedAccess type variant and its snapshot text: the variant does not exist at base, so the whole local_inference test binary would fail to compile against any implementation that names it differently; dropped from the hidden test patch.
- dropped: expected_argument_inference.test.rs tests bounds_actual_tuple_spread_expansion, bounds_formal_tuple_rest_expansion and preserves_wide_formal_tuple_suffix and their helpers, which build tuples through a three-argument constructor the fix introduces: removed (eai-trim.patch) so the file compiles against any constructor signature.
- dropped: local_inference::infer_type_of_call_expression_with_type_arguments: its base snapshot embeds the Debug form of the internal tuple type, which the fix changes; excluded from the frame record, as the statement says.
- dropped: a performance guard: the reference change carries the react-hook-form slowdown reported upstream as issue 11810 and fixed later in pull request 11814, so a guard would fail the reference.
- dropped: the fix's own unit tests in src (numbers::tests::single_rounding_*, inferred_type::tests::numeric_switch_cases_use_values_instead_of_spellings): they live in graded source directories and travel with the agent's sources.
- dropped: a case discriminating the 1024 budget from a larger one: mutant m2 (budget 1000000) passes every graded test and case, because existing collection limits already cap the sizes a case can build; the budget is stated and its upstream test guards it from the unknown side only.

## Rejected routes

- `kw_unconditional_projection`: Project every tuple and object without the conservativeness guards, so mutable arrays, rest elements and objects with unknown members resolve to a partial union (mutant m1); the hidden pass-to-pass issue7747_valid_ts and no_unnecessary_conditions::indexed_access_valid_ts and the R5 normalization test fail, and g1 and g3 of R9 fail.
- `kw_spelling_compare`: Resolve the projections but keep comparing numeric case values by spelling (mutant m3); R2, issue7747_invalid_ts (R1) and the hidden issue7747_valid_ts fail, and f3 of R6 fails.
- `kw_no_escape_bailout`: Resolve the projections without bailing out on escaped strings and keys (mutant m4); the hidden issue7747_valid_ts and the R5 normalization test fail, and g4 of R9 fails.
- `kw_budget_raised`: Raise the projection budget from 1024 to 1000000 (mutant m2): an equivalent mutant, every graded test and case passes; recorded, not a control.
- `kw_name_special_case`: Resolve only the identifiers or literal values of the issue's example and the tests; R6 fails and R8 judges the change.
- `harness_tamper`: Make the spec-test support crates report every test as passing; the pristine copies replace them, so the change earns nothing.
- `exit_hook`: Exit with status 0 from a static initializer that fires only inside test executables, so build scripts still run; no target reports its base-ok tests, so the frame fails and the gate closes.
