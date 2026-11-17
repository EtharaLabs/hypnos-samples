//! Execution regressions for transformations whose syntax carries semantics.

use std::process::Command;

use swc_common::{sync::Lrc, FileName, Globals, Mark, SourceMap, GLOBALS};
use swc_ecma_ast::Program;
use swc_ecma_codegen::{text_writer::JsWriter, Emitter};
use swc_ecma_parser::parse_file_as_module;
use swc_ecma_transforms_base::{
    fixer::{fixer, paren_remover},
    resolver,
};

use crate::{
    optimize,
    option::{CompressOptions, ExtraOptions, MangleOptions, MinifyOptions},
};

fn minify(source: &str, options: &MinifyOptions) -> String {
    GLOBALS.set(&Globals::new(), || {
        let cm = Lrc::<SourceMap>::default();
        let file = cm.new_source_file(FileName::Anon.into(), source.to_owned());
        let unresolved_mark = Mark::new();
        let top_level_mark = Mark::new();
        let program = Program::Module(
            parse_file_as_module(
                &file,
                Default::default(),
                Default::default(),
                None,
                &mut Vec::new(),
            )
            .unwrap(),
        )
        .apply(resolver(unresolved_mark, top_level_mark, false))
        .apply(paren_remover(None));
        let program = optimize(
            program,
            cm.clone(),
            None,
            None,
            options,
            &ExtraOptions {
                unresolved_mark,
                top_level_mark,
                mangle_name_cache: None,
            },
        )
        .apply(fixer(None));
        let mut output = Vec::new();
        Emitter {
            cfg: swc_ecma_codegen::Config::default().with_minify(true),
            cm: cm.clone(),
            comments: None,
            wr: JsWriter::new(cm, "\n", &mut output, None),
        }
        .emit_program(&program)
        .unwrap();
        String::from_utf8(output).unwrap()
    })
}

fn run(source: &str) -> Vec<u8> {
    let output = Command::new("node")
        .args(["--input-type=module", "--eval", source])
        .output()
        .expect("node is required for execution regressions");
    assert!(
        output.status.success(),
        "{source}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

/// Check both optimization and parsing of the resulting syntax on a second run.
fn equivalent(source: &str, keep_names: bool) {
    let expected = run(source);
    for mode in 0..6 {
        let options = MinifyOptions {
            compress: (mode != 5).then(|| CompressOptions {
                keep_fnames: keep_names,
                keep_classnames: keep_names,
                passes: if mode == 1 { 1 } else { 0 },
                reduce_vars: mode != 2,
                collapse_vars: mode != 3,
                sequences: if mode == 4 { 0 } else { 3 },
                ..Default::default()
            }),
            mangle: (mode != 0).then(|| MangleOptions {
                keep_fn_names: keep_names,
                keep_class_names: true,
                top_level: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        let mut code = source.to_owned();
        for _ in 0..2 {
            code = minify(&code, &options);
            assert_eq!(run(&code), expected, "mode {mode}: {code}");
        }
    }
}

#[test]
fn live_imports() {
    equivalent(
        r#"
import {count, bump} from "data:text/javascript,export let count=0;export function bump(){count++}";
export function changed(f) { const before = count; f(); return before !== count; }
console.log(changed(bump), changed(() => {}));
"#,
        false,
    );
    equivalent(
        r#"
import count, {bump} from "data:text/javascript,let count=0;export{count as default};export function bump(){count++}";
function changed(f) { const before = count; f(); return [before, count]; }
console.log(changed(bump), changed(() => {}));
"#,
        false,
    );
    equivalent(
        r#"
import * as counter from "data:text/javascript,export let count=0;export function bump(){count++}";
function changed(f) { const before = counter.count; f(); return before !== counter.count; }
console.log(changed(counter.bump), changed(() => {}));
"#,
        false,
    );
}

#[test]
fn parameter_default_identity() {
    equivalent(
        r#"
(function () {
    function load(value) { return value + 1; }
    const object = {};
    function hook([callback = load, value = object] = []) { return [callback, value]; }
    globalThis.render = function (callbacks) { return hook(callbacks); };
})();
console.log(render()[0] === render([])[0], render()[1] === render([])[1]);
"#,
        false,
    );
    equivalent(
        r#"
(() => {
    const value = {};
    const load = () => 1;
    const hook = ({callback = load, object = value} = {}) => [callback, object];
    globalThis.render = hook;
})();
console.log(render()[0] === render({})[0], render()[1] === render({})[1]);
"#,
        false,
    );
    equivalent(
        r#"
(() => {
    function load() {}
    const object = {};
    function hook({callback = load, value = object} = {}) { return [callback, value]; }
    function direct(callback = load) { return callback; }
    globalThis.render = hook;
    globalThis.direct = direct;
})();
console.log(render()[0] === render({})[0], render()[1] === render({})[1], direct() === direct());
"#,
        false,
    );
}

#[test]
fn unbound_super_calls() {
    equivalent(
        r#"
class Base { method() { return this; } }
class Derived extends Base {
    test() {
        console.log((0, super.method)() === undefined);
        console.log((0, super["method"])?.() === undefined);
        console.log(super.method() === this);
    }
}
new Derived().test();
const object = {
    __proto__: {method() { return this; }},
    test() { console.log((0, super.method)() === undefined, super.method() === this); }
};
object.test();
class Throws extends Base {
    method() { return this.value; }
}
class Calls extends Throws {
    test() {
        try { (0, super.method)(); } catch (error) { console.log(error.name); }
    }
}
new Calls().test();
"#,
        false,
    );
}

#[test]
fn anonymous_sequence_names() {
    equivalent(
        r#"
var f = (0, function () {}), a = (0, () => {}), c = (0, class {});
console.log(f.name, a.name, c.name);
let assigned;
assigned = (0, function () {});
console.log(assigned.name);
const object = { f: (0, function () {}), a: (0, () => {}), c: (0, class {}) };
console.log(object.f.name, object.a.name, object.c.name);
function defaults(f = (0, function () {}), a = (0, () => {}), c = (0, class {})) {
    console.log(f.name, a.name, c.name);
}
defaults();
const { p = (0, function () {}) } = {};
const [q = (0, class {})] = [];
console.log(p.name, q.name);
class Fields {
    f = (0, function () {});
    static a = (0, () => {});
    static c = (0, class {});
}
console.log(new Fields().f.name, Fields.a.name, Fields.c.name);
let logical;
logical ||= (0, function () {});
console.log(logical.name);
let destructured;
({destructured = (0, () => {})} = {});
console.log(destructured.name);
export default (0, class { static { console.log(this.name); } });
"#,
        true,
    );
}

#[test]
fn class_inner_binding() {
    equivalent(
        r#"
(() => {
    class Foo { static self = Foo; }
    console.log(Foo.self === Foo);
})();
try {
    class Foo { static { Foo = 1; } }
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo { static { Foo = Foo; } }
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo { static { Foo += 1; } }
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo { static { Foo++; } }
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo { static { Foo = (console.log("first"), 0); Foo = (console.log("second"), 1); } }
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo extends Foo {}
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
try {
    class Foo { [Foo]() {} }
    console.log(Foo);
} catch (error) { console.log(error.name, error.message); }
let Bar = Object;
try {
    const Other = class Bar extends Bar {};
    console.log(Other);
} catch (error) { console.log(error.name, error.message); }
"#,
        false,
    );
    equivalent(
        r#"
(() => {
    class Foo { static self = Foo; method() { return Foo; } }
    console.log(Foo.self === Foo, new Foo().method() === Foo);
    const Original = Foo;
    Foo = 1;
    console.log(new Original().method() === Original);
    const Named = class Bar { static self = Bar; };
    console.log(Named.self === Named, Named.name);
})();
"#,
        true,
    );
}

#[test]
fn floating_point_factors() {
    equivalent(
        r#"
function product(x) { return x * 24 * 60 * 60; }
for (const x of [365.2425, 1e307, 5e-324, -0, Infinity, NaN]) {
    console.log(product(x), Object.is(product(x), -0));
}
let calls = 0;
const value = {valueOf() { calls++; return 365.2425; }};
console.log(product(value), calls);
try { console.log(product(1n)); } catch (error) { console.log(error.name); }
"#,
        false,
    );
}
