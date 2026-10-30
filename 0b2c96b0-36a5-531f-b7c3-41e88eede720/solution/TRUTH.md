# Golden trajectory

GENERATED SECTION. DO NOT HAND-EDIT.

<!-- FORGE-CANARY-BEGIN -->
<!-- FORGE-CANARY-SLOT-1: 53b3d68b043f0ac9ebd47bd8f67b19e6b7fa14e174aa9caffdb90444975aa7f3 -->
<!-- FORGE-CANARY-SLOT-2: 38b25c13f561e095dd794f20ce1e467469f45f1b8189951f4b69665b6a622818 -->
<!-- FORGE-CANARY-SLOT-3: 6d1b364b7c03a9c801ba00be36cef100ff8e18f5ba1be4973fa3eb7ba9ca94e1 -->
<!-- FORGE-CANARY-SLOT-4: 8b58ce62941667e72e8c86e7b3c70b3a37a6b0a50d84d4e72d8362b623414dc3 -->
<!-- FORGE-CANARY-END -->

## Ordered path

1. Reproduce the issue with the bundled example plugin: example call-decl on a def command fails with the internal error, while a built-in runs.
2. Trace call_decl to where the found declaration is run; a custom command refuses there, because only the evaluator's own call path binds parameters, checks the input type, gives the callee its stack and runs the block.
3. Search the workspace for every place that runs a declaration it looked up by id rather than one written in the source, including the commands nushell picks on the user's behalf, and record how each binds arguments, checks input and treats $env today.
4. Factor the evaluator's call path, the input type check, argument binding, the callee stack, and $env redirection for def --env, into one public function that runs a call built for a declaration id, without adding argument checks the parser would make, so that calls accepted today stay accepted.
5. Build such a call at each place and route it through that function, untyping http's response body before its converter as open does, and making %($cmd) reject a non-empty spread into a command with no rest parameter.
6. Rebuild the workspace offline, rerun the whole suite so every test that passed before still passes, and check custom replacements of each picked command by hand.

## Deliverables and red lines

- `D1` at `Rust sources under /app/crates/*/src`: A plugin's call_decl runs custom commands with their arguments bound as a direct call binds them.
- `D2` at `Rust sources under /app/crates/*/src`: Custom from <ext> converters run by open and http, and custom to <ext> converters run by save, get their flags and defaults bound and their input type checked as a direct call does, and save keeps a converter's $env changes inside it unless it is def --env; the converter http picks receives the response body as bytes of unknown type, whatever charset the response declares.
- `D3` at `Rust sources under /app/crates/*/src`: %($cmd) checks the input type of the built-in command it runs as a direct call does, and spreading a non-empty list into a command with no rest parameter is an error.
- `D4` at `Rust sources under /app/crates/*/src`: A custom command that takes the place of a command nushell picks on the user's behalf, the syntax highlighter or the table renderer, is called as a direct call calls it, with its switches and flag defaults bound.
- `RL1`: The graded result is computed from Rust sources under crates/*/src and src/ alone; tests/, crates/*/tests, crates/nu-test-support, every Cargo.toml, Cargo.lock, and every build file are taken from the pristine base before grading. Enforced by tests/grading/grade.sh, which copies the agent's crates/*/src (but crates/nu-test-support) and src/ onto /opt/base-src, the base with the hidden test patch, and drops symlinks.
- `RL2`: No network is reachable from the agent environment, so the merged fix and crates.io cannot be fetched. Enforced by environment and agent network_mode no-network.
- `RL3`: Every upstream test that passed at the base commit must run and pass afterwards, counted per test target; a target that runs fewer tests than at base counts as failed. Enforced by the frame in tests/grading/summarize.py against tests/grading/base-frame.json, by passed count and by each base-ok test name, and the reward gate in tests/test.sh.
- `RL4`: Direct calls and built-in commands keep their observable behaviour, except as the statement's stated changes require or permit; a call by declaration id that is accepted today, including one with arguments the parser would reject in a direct call, is still accepted. Enforced by the frame, which holds the whole workspace suite to its base results, and the pass-to-pass cases of R9, which hold built-in calls by declaration id to their base output.

## Rubric items

- `R1` (compiled, weight 5, D1, outcome): The upstream plugins::call_decl::call_custom_command test passes.
- `R2` (compiled, weight 3, D2, coverage): The upstream save::custom_converter_binds_its_flags test passes.
- `R3` (compiled, weight 3, D2, constraints): The upstream save::custom_converter_checks_its_input_type test passes.
- `R4` (compiled, weight 3, D2, coverage): The upstream network::http::get::http_get_with_custom_converter test passes.
- `R5` (compiled, weight 3, D3, coverage): The upstream repl::test_parser::percent_dynamic_dispatch_rejects_list_spread_without_rest test passes.
- `R6` (compiled, weight 5, D1, robustness): Every authored fail-to-pass case (c01 to c04, c07 to c12, c14 to c21; 18 cases) produces the reference output.
- `R7` (compiled, weight 5, RL3, constraints): The frame passes, every upstream test that passed at base passing in every workspace test target.
- `R8` (judged, weight 3, D1, constraints): prohibited: the change makes calls by declaration id behave as direct calls only for particular command names, converter names, or inputs, rather than for every custom command.
- `R9` (compiled, weight 3, RL3, constraints): The authored pass-to-pass cases p01 to p04 (4 cases) produce the output the base commit produces.

## Authored cases (R6 fail-to-pass c*, R9 pass-to-pass p*)

- `c01-calldecl-rest` (D1): call_decl on a custom command with a required positional and a rest parameter.
- `c02-calldecl-switch` (D1): call_decl on a custom command with a switch, set and unset.
- `c03-calldecl-default` (D1): call_decl on a custom command whose named flags fall back to their defaults, and are overridden.
- `c04-calldecl-inputtype` (D1): call_decl on a custom command with an int input type, given an int and given a string its signature rejects.
- `c07-save-env` (D2): save with a custom to <ext> command that sets $env, contained without def --env and kept with it.
- `c08-save-default-flag` (D2): save with a custom to <ext> command whose flag default is bound.
- `c09-percent-spread` (D3): %($cmd) spreading a list into reverse, which has no rest parameter.
- `c10-save-inputtype` (D2): save handing a record to a custom to <ext> command typed string -> string.
- `c11-percent-inputtype` (D3): %($cmd) running uniq on an int input it rejects, and on a list.
- `c12-calldecl-rest-typed` (D1): call_decl on a custom command with only a typed rest parameter.
- `c14-http-default-flag` (D2): http get with a custom from <ext> command chosen by the content type, binding a flag default.
- `c15-http-inputtype` (D2): http get with a custom from <ext> command typed int -> int, given the response it rejects.
- `c16-help-highlight-builtin` (D4): help for a built-in command with coloring on, where a custom nu-highlight replaces the highlighter of its example code.
- `c17-help-highlight-switch` (D4): help for a custom command with an @example, where a custom nu-highlight declares the switch the highlighter is given and wraps the example code whether or not the switch is set.
- `c18-help-example-table` (D4): help for a custom command with two @example results, where a custom table replaces the table renderer and reports which of --expand, --collapse and --width it was given.
- `c19-tutor-highlight` (D4): tutor begin, where a custom nu-highlight replaces the highlighter of the tutorial's code.
- `c20-tutor-highlight-default` (D4): tutor begin, where a custom nu-highlight relies on a flag default.
- `c21-http-utf8-binary-converter` (D2): http get on a charset=utf-8 response with a custom from <ext> typed binary -> int, which must receive the body as bytes.
- `p01-calldecl-builtin-unknown-flag` (RL4): pass-to-pass: call_decl on math sum with an unknown named argument, accepted at base.
- `p02-calldecl-builtin-extra-positional` (RL4): pass-to-pass: call_decl on reverse with an extra positional argument, accepted at base.
- `p03-percent-extra-positional` (RL4): pass-to-pass: %($cmd) running reverse with an extra positional argument, accepted at base.
- `p04-http-utf8-builtin-converter` (RL4): pass-to-pass: http get on a charset=utf-8 response whose URL extension picks the built-in from msgpack, which needs binary.
- dropped: open.rs: open with a custom from <ext> command binding a default flag, open with one whose input type rejects the file, and the further open cases e02, o01 to o21 and n01 to n05: all behave the same at base and at the fix, because open already ran converters through the AST evaluator, so none can fail at base.
- dropped: a05, a custom ansi command in help coloring: at the fix its expected value is the same as what any break in help coloring produces, and the statement would have to describe colours.
- dropped: h10 and t05, a def --env highlighter whose $env change would leak into the session through help or tutor: the result depends on which stack help and tutor pass, an implementation choice the statement does not fix.
- dropped: t09, tutor falling back to plain code when the highlighter errors: the fix's fallback is a choice the statement does not state.
- dropped: h01, h03, h08, h11, h13, h14 and h15, earlier help-highlighter probes: superseded by c16 to c18, which do not depend on terminal width or on whether --reject-garbage is passed.
- dropped: x5 and x6, a built-in run by call_decl or save on an input type it rejects: base and the fix differ, and the statement only says a built-in run by declaration id may have its input type checked, so neither side is graded.

## Rejected routes

- `kw_call_decl_only`: Make the plugin's call_decl run a custom command's block directly, without binding its arguments or checking its input; R1 to R6 fail, so no fail-to-pass item passes and the gate closes.
- `kw_no_input_check`: Route every call by declaration id through the binding path but skip the input type check; R3 and the input-type cases of R6 fail.
- `kw_name_special_case`: Apply the direct-call path only to the command and converter names the upstream tests use; R6 fails and R8 judges the change.
- `harness_tamper`: Make crates/nu-test-support report every test as passing; the pristine copy replaces it, so the change earns nothing.
- `exit_hook`: Exit with status 0 from a static initializer in a library crate before any test runs; no target reports its base-ok tests, so the frame fails and the gate closes.
- `kw_no_help_tutor`: Route the plugin's call_decl, the converters and %($cmd) through one independently written direct-call path, but leave the highlighter and the table renderer that help and tutor pick on the old path; c16 to c20 of R6 fail.
- `kw_typed_converter`: Hand http's converter the response stream typed by the charset it declares; the custom binary converter of c21 (R6) and the built-in from msgpack of p04 (R9) are rejected on a charset=utf-8 response, and the upstream http_get_binary_converter_on_utf8_response test that passes at base fails, so the frame fails and the gate closes.
- `kw_strict_builtin_args`: Reject an extra positional argument or an unknown flag when a built-in command is run by declaration id; p01 to p03 of R9 fail.
- `kw_custom_only`: Route only custom commands through the direct-call path and keep built-ins on the old one, without untyping http's response body; c21 of R6 fails.
