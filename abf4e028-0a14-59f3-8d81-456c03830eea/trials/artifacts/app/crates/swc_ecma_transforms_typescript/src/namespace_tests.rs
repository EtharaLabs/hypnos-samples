//! Execution regressions kept next to the reconciliation pass.
use std::process::Command;

use swc_common::{sync::Lrc, FileName, Globals, Mark, SourceMap, GLOBALS};
use swc_ecma_ast::{EsVersion, Pass};
use swc_ecma_parser::{parse_file_as_program, Syntax, TsSyntax};
use swc_ecma_transforms_base::{fixer::fixer, hygiene::hygiene, resolver};

use crate::{typescript, Config};

fn exec(source: &str) {
    for mutable in [false, true] {
        for verbatim in [false, true] {
            GLOBALS.set(&Globals::default(), || {
                let cm: Lrc<SourceMap> = Default::default();
                let file = cm.new_source_file(
                    FileName::Custom("merged.ts".into()).into(),
                    source.to_owned(),
                );
                let mut errors = Vec::new();
                let mut program = parse_file_as_program(
                    &file,
                    Syntax::Typescript(TsSyntax::default()),
                    EsVersion::latest(),
                    None,
                    &mut errors,
                )
                .unwrap();
                assert!(errors.is_empty(), "{errors:?}");
                let unresolved = Mark::new();
                let top_level = Mark::new();
                (
                    resolver(unresolved, top_level, true),
                    typescript(
                        Config {
                            ts_enum_is_mutable: mutable,
                            verbatim_module_syntax: verbatim,
                            no_empty_export: true,
                            ..Default::default()
                        },
                        unresolved,
                        top_level,
                    ),
                    hygiene(),
                    fixer(None),
                )
                    .process(&mut program);
                let code = swc_ecma_codegen::to_code_default(cm, None, &program);
                let result = Command::new("node")
                    .arg("--input-type=module")
                    .arg("--eval")
                    .arg(&code)
                    .output()
                    .unwrap();
                assert!(
                    result.status.success(),
                    "mutable={mutable}, verbatim={verbatim}\n{code}\n{}",
                    String::from_utf8_lossy(&result.stderr)
                );
            });
        }
    }
}

#[test]
fn merged_namespace_bindings() {
    exec(
        r#"
        export namespace Test { export const a = 1; }
        const a = 'out';
        export namespace Test { export const b = a + 1; }
        if (Test.b !== 2) throw new Error('merged export');
        namespace Test {
            const a = 10;
            export const c = a + 1;
            export function local(a: number) { return a; }
        }
        namespace Test {
            export const d = (() => { const a = 20; return a; })();
            export const f = () => later;
        }
        namespace Test { export const later = 30; }
        if (Test.c !== 11 || Test.d !== 20 || Test.local(40) !== 40 || Test.f() !== 30) throw new Error('locals');
        namespace Test { export namespace Inner { export const x = 3; } }
        namespace Test { export namespace Inner { export const y = x + 1; } }
        if (Test.Inner.y !== 4) throw new Error('nested merging');
    "#,
    );
}

#[test]
fn merged_enum_evaluation() {
    exec(
        r#"
        let calls = 0;
        function value() { calls++; return 4; }
        enum E { A = value() }
        const A = 100;
        enum E { B = A + 1, C = E.A + 2, D = (() => { const A = 9; return A; })() }
        if (calls !== 1 || E.A !== 4 || E.B !== 5 || E.C !== 6 || E.D !== 9 || E[4] !== 'A' || E[5] !== 'B') throw new Error('enum evaluation');
        namespace E { export const extra = B + 10; }
        if (E.extra !== 15) throw new Error('enum namespace');
        namespace N { export enum F { X = 2 } }
        namespace N { export enum F { Y = X + 1 } }
        if (N.F.Y !== 3 || N.F[3] !== 'Y') throw new Error('nested enum');
    "#,
    );
}

#[test]
fn namespace_import_equals() {
    exec(
        r#"
        namespace Source { export const value = 7; }
        namespace N { export import Alias = Source; }
        const Alias = { value: 100 };
        namespace N { import Local = Alias; export const value = Local.value; }
        namespace N { export import Other = Source; import Local = Other; export const same = Local.value; }
        if (N.same !== 7) throw new Error('same body alias');
        if (N.value !== 7) throw new Error('merged alias');
    "#,
    );
}

#[test]
fn qualified_enum_constants_and_aliases() {
    exec(
        r#"
        namespace N { export enum E { A = 'a', B = 3 } export const text = 'a'; }
        namespace N {
            export enum F { A = E.A, B = E.B }
            export enum G { A = N.E.A, B = N.E.B }
            import Alias = N.E;
            export enum H { A = Alias.A, B = Alias.B }
            export enum I { A = text, B = 3 }
        }
        for (const e of [N.F, N.G, N.H, N.I]) {
            if (e.A !== 'a' || e.B !== 3 || e[3] !== 'B' || Object.hasOwn(e, 'a')) throw new Error('qualified string constant');
        }
    "#,
    );
}

#[test]
fn enum_object_exists_during_initialization() {
    exec(
        r#"
        function inspect() { return E; }
        enum E { A = inspect() === E ? 1 : 2 }
        if (E.A !== 1) throw new Error('top-level initialization');
        function local() {
            function inspect() { return F; }
            enum F { A = inspect() === F ? 1 : 2 }
            return F.A;
        }
        if (local() !== 1) throw new Error('local initialization');
    "#,
    );
}

#[test]
fn merged_enum_reinitializes_missing_object() {
    exec(
        r#"
        namespace N { export enum E { A = 1 } }
        const first = N.E;
        N.E = undefined as any;
        namespace N { export enum E { B = 2 } }
        if (N.E === first || N.E.B !== 2 || Object.hasOwn(N.E, 'A')) throw new Error('missing exported object');
        enum E { A = 1 }
        const old = E;
        E = undefined as any;
        enum E { B = 2 }
        if (E === old || E.B !== 2 || Object.hasOwn(E, 'A')) throw new Error('missing object');
    "#,
    );
}

#[test]
fn namespace_scopes_and_assignment_patterns() {
    exec(
        r#"
        namespace N { export let a = 1; }
        let a = 100;
        namespace N {
            ({a} = {a: 3});
            [a] = [4];
            ({a = 8} = {});
            for (a of [9]) {}
            export const result = a;
        }
        if (N.a !== 9 || N.result !== 9 || a !== 100) throw new Error('assignment target');
        namespace Parent {
            namespace Child.Inner { const value = 100; }
            export const read = () => value;
        }
        namespace Parent { export const value = 8; }
        if (Parent.read() !== 8) throw new Error('private dotted binding');
        namespace Shape { export class Item { value = 3; } }
        namespace Shape { export const result = new Item().value; }
        if (Shape.result !== 3) throw new Error('merged class');
    "#,
    );
}

#[test]
fn nested_enum_uses_outer_members() {
    exec(
        r#"
        enum E {
            A = 'a',
            B = (() => {
                enum F { X = A }
                if (F.X !== 'a' || Object.hasOwn(F, 'a')) throw new Error('outer string enum');
                namespace N { export const read = () => A; }
                if (N.read() !== 'a') throw new Error('outer member in namespace');
                return 1;
            })()
        }
        if (E.B !== 1) throw new Error('nested enum initialization');
    "#,
    );
}

#[test]
fn type_only_aliases_do_not_create_objects_or_shadow_values() {
    exec(
        r#"
        namespace Types { export interface Item {} }
        namespace N { export import Item = Types.Item; }
        namespace M { export import Alias = N; }
        if (typeof Types !== 'undefined' || typeof N !== 'undefined' || typeof M !== 'undefined') throw new Error('type-only objects');
        const Item = 3;
        namespace Values { export import Item = Types.Item; }
        namespace Values { export const result = Item; }
        if (Values.result !== 3 || Object.hasOwn(Values, 'Item')) throw new Error('type-only member shadow');
    "#,
    );
}

#[test]
fn ambient_namespace_members_merge_without_emitting_bodies() {
    exec(
        r#"
        function External() {}
        External.value = 2;
        External.read = () => 7;
        const value = 100;
        declare namespace External { const value: number; function read(): number; }
        namespace External { export const result = value + read(); }
        if (External.result !== 9) throw new Error('ambient values');
        declare namespace OnlyTypes { interface T {} }
        namespace N { export import Alias = OnlyTypes; }
        if (typeof N !== 'undefined') throw new Error('ambient type-only namespace');
    "#,
    );
}
