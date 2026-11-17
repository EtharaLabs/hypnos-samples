use crate::{AnalysisFilter, JsAnalyzerServices};
use biome_analyze::{ActionFilter, AnalyzerOptions, Never, RuleFilter};
use biome_diagnostics::Diagnostic;
use biome_fs::{BiomePath, MemoryFileSystem};
use biome_js_parser::{JsParserOptions, parse};
use biome_js_semantic::{SemanticModelOptions, semantic_model};
use biome_languages::JsFileSource;
use biome_module_graph::{ModuleInfo, ModuleInfoKind, PathInfoCache, resolve_js_module};
use biome_project_layout::ProjectLayout;
use biome_service::db::WorkspaceDb;
use std::{ops::ControlFlow, sync::Arc};

fn lint(source: &str, group: &'static str, rule: &'static str) -> (Vec<String>, Vec<String>) {
    let path = BiomePath::new("/src/index.ts");
    let source_type = JsFileSource::ts();
    let parsed = parse(source, source_type, JsParserOptions::default());
    assert!(!parsed.has_errors(), "{:?}", parsed.diagnostics());
    let root = parsed.tree();
    let semantic = semantic_model(&root, SemanticModelOptions::default());
    let fs = MemoryFileSystem::default();
    fs.insert(path.as_path().to_owned(), source);
    let layout = ProjectLayout::default();
    let (info, _, _) = resolve_js_module(
        root.clone(),
        &path,
        &fs,
        &layout,
        Arc::new(semantic.clone()),
        &PathInfoCache::default(),
        true,
    );
    let mut db = WorkspaceDb::default();
    let module = ModuleInfo::new(&db, path.as_path().to_owned(), ModuleInfoKind::Js(info));
    db.insert_module(path.as_path().to_owned(), module);
    let services = JsAnalyzerServices::default()
        .with_source_type(source_type)
        .with_semantic_model(&semantic)
        .with_project_layout(layout.into())
        .with_module_db(db.rc_module_db());
    let options = AnalyzerOptions::default().with_file_path(path.as_path());
    let filters = [RuleFilter::Rule(group, rule)];
    let mut diagnostics = Vec::new();
    let mut fixes = Vec::new();
    crate::analyze(
        &root,
        AnalysisFilter {
            enabled_rules: Some(&filters),
            ..AnalysisFilter::default()
        },
        &options,
        &[],
        services,
        |signal| {
            if let Some(diagnostic) = signal.diagnostic() {
                let span = diagnostic.location().span.unwrap();
                diagnostics
                    .push(source[usize::from(span.start())..usize::from(span.end())].to_owned());
            }
            for action in signal.actions(ActionFilter::all()) {
                if !action.is_suppression() {
                    fixes.push(action.mutation.commit().to_string());
                }
            }
            ControlFlow::<Never>::Continue(())
        },
    );
    (diagnostics, fixes)
}

#[test]
fn projected_unions_are_exhaustive_switch_inputs() {
    let (diagnostics, fixes) = lint(
        r#"
        const values = ["A", "B", "C"] as const;
        const object = { A: 1, B: 2, C: 3 } as const;
        function first(value: (typeof values)[number]) { switch(value) { case "A": break; case "B": break; } }
        function second(value: keyof typeof object) { switch(value) { case "A": break; case "B": break; } }
    "#,
        "nursery",
        "useExhaustiveSwitchCases",
    );
    assert_eq!(diagnostics.len(), 2);
    assert_eq!(fixes.len(), 2);
    for fix in fixes {
        assert!(fix.contains("case \"C\":"), "{fix}");
    }
}

#[test]
fn projected_types_reach_every_type_aware_rule() {
    let cases = [
        (
            "suspicious",
            "noUnnecessaryConditions",
            r#"declare const value: [1, 2][number]; value ?? 0; if (value) {}"#,
            2,
        ),
        (
            "suspicious",
            "noUnnecessaryConditions",
            r#"declare const value: keyof { A: 1; B: 2 }; switch (value) { case "A": break; case "B": break; case "C": break; }"#,
            1,
        ),
        (
            "nursery",
            "noFloatingPromises",
            "declare const value: [Promise<number>][number]; value;",
            1,
        ),
        (
            "nursery",
            "useAwaitThenable",
            "declare const value: [number][number]; await value;",
            1,
        ),
        (
            "nursery",
            "noUnsafePlusOperands",
            "declare const value: number[][number]; value + 1n;",
            1,
        ),
        (
            "nursery",
            "noUselessTypeConversion",
            "declare const s: [string][number]; declare const n: [number][number]; declare const b: [boolean][number]; String(s); Number(n); Boolean(b);",
            3,
        ),
        (
            "suspicious",
            "useArraySortCompare",
            "declare const value: [number[]][number]; value.sort(); value.toSorted();",
            2,
        ),
    ];
    for (group, rule, source, expected) in cases {
        let (diagnostics, _) = lint(source, group, rule);
        assert_eq!(diagnostics.len(), expected, "{rule}: {diagnostics:?}");
    }
}

#[test]
fn numeric_switches_compare_runtime_values_and_fix_decimal_cases() {
    let (diagnostics, fixes) = lint(
        "declare const value: 0x10 | 16 | 0b10001 | -0 | 1e2 | -3; switch (value) { case 0o20: break; case 0: break; }",
        "nursery",
        "useExhaustiveSwitchCases",
    );
    assert_eq!(diagnostics.len(), 1);
    let fix = &fixes[0];
    assert!(fix.contains("case 17:"), "{fix}");
    assert!(fix.contains("case 100:"), "{fix}");
    assert!(fix.contains("case -3:"), "{fix}");
    assert!(!fix.contains("case 16:"), "{fix}");
    assert!(fix.find("case 17:").unwrap() < fix.find("case 100:").unwrap());
    let parsed = parse(fix, JsFileSource::ts(), JsParserOptions::default());
    assert!(!parsed.has_errors());
    assert!(
        lint(fix, "nursery", "useExhaustiveSwitchCases")
            .0
            .is_empty()
    );
    for source in [
        "declare const value: 1 | 2; switch(value) { case NaN: break; }",
        "declare const value: 1 | 2; switch(value) { case 1e999: break; }",
        "declare const value: 1 | 1e999; switch(value) {}",
        "declare const value: 1 | number; switch(value) {}",
        "declare const value: [unknown, 1][number]; switch(value) {}",
        "declare const value: [any, 1][number]; switch(value) {}",
    ] {
        assert!(
            lint(source, "nursery", "useExhaustiveSwitchCases")
                .0
                .is_empty(),
            "{source}"
        );
    }
}

#[test]
fn double_bitwise_not_requires_signed_32_bit_literals_or_bigints() {
    for ty in [
        "-2147483648",
        "2147483647",
        "0",
        "1 | 2",
        "bigint",
        "1n | 2n",
    ] {
        let source = format!("declare const value: {ty}; ~~value;");
        assert_eq!(
            lint(&source, "nursery", "noUselessTypeConversion").0.len(),
            1,
            "{ty}"
        );
    }
    for ty in [
        "-0",
        "2147483648",
        "-2147483649",
        "1.5",
        "number",
        "1 | -0",
        "1 | 2147483648",
    ] {
        let source = format!("declare const value: {ty}; ~~value;");
        assert!(
            lint(&source, "nursery", "noUselessTypeConversion")
                .0
                .is_empty(),
            "{ty}"
        );
    }
}
