use crate::*;
use biome_db::ParsedSource;
use biome_db::testing::{Events, function_query_will_execute_count_by_name};
use biome_fs::{BiomePath, MemoryFileSystem};
use biome_js_type_info::{InferredSwitchCase, InferredType, interned_types::TypeData};
use biome_languages::{DocumentFileSource, LanguageDb};
use biome_project_layout::ProjectLayout;
use biome_rowan::TextRange;
use biome_test_utils::get_added_js_paths;
use camino::{Utf8Path, Utf8PathBuf};
use salsa::Setter;
use std::collections::BTreeMap;

#[salsa::db]
struct TestDb {
    storage: salsa::Storage<Self>,
    modules: BTreeMap<Utf8PathBuf, ModuleInfo>,
    events: Events,
}

impl TestDb {
    fn new() -> Self {
        let events = Events::default();
        let db = Self {
            storage: salsa::Storage::new(Some(Box::new({
                let events = events.clone();
                move |event| events.0.lock().unwrap().push(event)
            }))),
            modules: BTreeMap::new(),
            events,
        };
        ModuleGraphGeneration::new(&db, 0);
        db
    }

    fn add(&mut self, fs: &MemoryFileSystem, path: &str, source: &str) -> ModuleInfo {
        fs.insert(path.into(), source);
        let paths = [BiomePath::new(path)];
        let mut parsed = get_added_js_paths(fs, &paths);
        let (path, root, semantic) = parsed.pop().unwrap();
        let (info, _, _) = resolve_js_module(
            root,
            path,
            fs,
            &ProjectLayout::default(),
            semantic,
            &PathInfoCache::default(),
            true,
        );
        let kind = ModuleInfoKind::Js(info);
        if let Some(module) = self.modules.get(path.as_path()).copied() {
            module.set_kind(self).to(kind);
            module
        } else {
            let module = ModuleInfo::new(self, path.as_path().to_owned(), kind);
            self.modules.insert(path.as_path().to_owned(), module);
            module
        }
    }

    fn range(&self, module: ModuleInfo, name: &str) -> TextRange {
        let ModuleInfoKind::Js(info) = module.kind(self) else {
            panic!()
        };
        info.semantic_model
            .all_bindings()
            .find(|binding| {
                binding
                    .tree()
                    .name_token()
                    .is_ok_and(|token| token.text_trimmed() == name)
            })
            .unwrap()
            .syntax()
            .text_trimmed_range()
    }

    fn ty(&self, module: ModuleInfo, name: &str) -> TypeData<'_> {
        let ty = infer_binding_type(
            self,
            BindingTypeInput::new(self, module, self.range(module, name)),
        )
        .unwrap();
        normalize_type(self, NormalizeTypeInput::new(self, module, ty))
    }

    fn cases(&self, module: ModuleInfo, name: &str) -> Vec<InferredSwitchCase> {
        let ty = self.ty(module, name);
        InferredType::new(self, ty)
            .try_switch_case_variants()
            .unwrap()
    }
}

#[salsa::db]
impl salsa::Database for TestDb {}
#[salsa::db]
impl biome_db::Db for TestDb {
    fn parsed_source_for_path(&self, _: &Utf8Path) -> Option<ParsedSource> {
        None
    }
}
#[salsa::db]
impl LanguageDb for TestDb {
    fn source_from_index(&self, _: usize) -> Option<DocumentFileSource> {
        None
    }
}
#[salsa::db]
impl TypeDb for TestDb {}
#[salsa::db]
impl ModuleDb for TestDb {
    fn module_for_path(&self, path: &Utf8Path) -> Option<ModuleInfo> {
        self.modules.get(path).copied()
    }
    fn for_each_module(&self, f: &mut dyn FnMut(ModuleInfo)) {
        for module in self.modules.values() {
            f(*module);
        }
    }
}

fn strings(names: &[&str]) -> Vec<InferredSwitchCase> {
    names
        .iter()
        .map(|name| InferredSwitchCase::String((*name).to_owned().into()))
        .collect()
}

#[test]
fn projections_resolve_aliases_and_const_literals() {
    let fs = MemoryFileSystem::default();
    let mut db = TestDb::new();
    let module = db.add(
        &fs,
        "/src/index.ts",
        r#"
        const letters = ["A", "B", "C"] as const;
        type Index = number;
        type Values = typeof letters;
        declare const tuple: Values[Index];
        declare const readonlyTuple: (readonly ["A", "B", "C"])[number];
        declare const array: string[][number];
        type ObjectType = { A: number; B?: number; C: number };
        const object = { A: 1, B: 2, C: 3 } as const;
        declare const keys: keyof ObjectType;
        declare const valueKeys: keyof typeof object;
        declare const partial: keyof Partial<ObjectType>;
        declare const required: keyof Required<ObjectType>;
        declare const readonlyObject: keyof Readonly<ObjectType>;
        declare const pick: keyof Pick<ObjectType, "A" | "C">;
        declare const omit: keyof Omit<ObjectType, "B">;
        type SelectedKeys = "A" | "C";
        declare const aliasedPick: keyof Pick<ObjectType, SelectedKeys>;
        declare const emptyPick: keyof Pick<ObjectType, never>;
        declare const escaped: keyof { "\u0041": number; B: number; C: number };
        declare const optional: ["A"?][number];
        const computedObject = { ["\u0041"]: 1, B: 2, C: 3 };
        const escapedValues = ["\u0041", "B", "C"] as const;
        declare const escapedTuple: (typeof escapedValues)[number];
        declare const computedKeys: keyof typeof computedObject;
        declare const computedPick: keyof Pick<typeof computedObject, "A" | "C">;
        type SpecialKeys = { NaN: 1; Infinity: 2 };
        declare const special: keyof SpecialKeys;
        declare const specialOmit: keyof Omit<SpecialKeys, "NaN">;
    "#,
    );
    for name in [
        "tuple",
        "readonlyTuple",
        "keys",
        "valueKeys",
        "partial",
        "required",
        "readonlyObject",
        "escaped",
        "computedKeys",
        "escapedTuple",
    ] {
        assert_eq!(db.cases(module, name), strings(&["A", "B", "C"]), "{name}");
    }
    for name in ["pick", "omit", "aliasedPick", "computedPick"] {
        assert_eq!(db.cases(module, name), strings(&["A", "C"]), "{name}");
    }
    assert_eq!(db.ty(module, "array"), TypeData::String);
    assert_eq!(db.ty(module, "emptyPick"), TypeData::NeverKeyword);
    assert_eq!(db.cases(module, "special"), strings(&["NaN", "Infinity"]));
    assert_eq!(db.cases(module, "specialOmit"), strings(&["Infinity"]));
    let keys = db.ty(module, "keys");
    assert!(InferredType::new(&db, keys).is_all_string_like());
    assert_eq!(
        db.cases(module, "optional"),
        vec![
            InferredSwitchCase::String("A".into()),
            InferredSwitchCase::Undefined
        ]
    );
}

#[test]
fn projections_preserve_uncertainty() {
    let fs = MemoryFileSystem::default();
    let mut db = TestDb::new();
    let module = db.add(
        &fs,
        "/src/index.ts",
        r#"
        const mutableArray = ["A", "B"];
        declare const mutable: (typeof mutableArray)[number];
        type Self = [Self];
        declare const recursive: Self[number];
        declare const invalidIndex: ["A"][string];
        declare const unknownElement: [unknown, 1][number];
        declare const anyElement: [any, 1][number];
        const unresolvedValues = [missingValue, 1] as const;
        declare const unresolvedElement: (typeof unresolvedValues)[number];
        declare const rest: ["A", ...string[]][number];
        declare const primitiveKeys: keyof string;
        declare const constructorKeys: keyof { new(): object; A: 1 };
        declare const constructorPick: keyof Pick<{ new(): object; A: 1 }, "A">;
        declare const intersection: keyof ({ A: 1 } & { B: 2 });
        declare const inherited: keyof Readonly<Interface>;
        interface Interface { A: 1; }
        declare const numericKeys: keyof { 1: string; A: string };
        declare const hexadecimalKeys: keyof { 0x1: string; A: string };
        declare const binaryKeys: keyof { 0b1: string; A: string };
        declare const indexKeys: keyof { A: string; [key: string]: string };
        declare const computed: keyof { [Symbol.iterator](): void; A: string };
        declare const spread: keyof typeof object;
        const object = { ...external, A: 1 };
        declare const pick: keyof Pick<{ A: string; [key: string]: string }, "A">;
        declare const badKey: keyof Omit<{ A: string; B: string }, "A" | number>;
    "#,
    );
    for name in [
        "recursive",
        "mutable",
        "invalidIndex",
        "unknownElement",
        "anyElement",
        "unresolvedElement",
        "rest",
        "primitiveKeys",
        "constructorKeys",
        "constructorPick",
        "intersection",
        "inherited",
        "numericKeys",
        "hexadecimalKeys",
        "binaryKeys",
        "indexKeys",
        "computed",
        "spread",
        "pick",
        "badKey",
    ] {
        assert_eq!(db.ty(module, name), TypeData::Unknown, "{name}");
    }
}

#[test]
fn imported_projections_are_incremental() {
    let fs = MemoryFileSystem::default();
    fs.insert(
        "/src/defs.ts".into(),
        "export const letters = ['A', 'B', 'C'] as const;",
    );
    let mut db = TestDb::new();
    db.add(
        &fs,
        "/src/defs.ts",
        "export const letters = ['A', 'B', 'C'] as const;",
    );
    let module = db.add(
        &fs,
        "/src/index.ts",
        "import { letters } from './defs'; declare const value: (typeof letters)[number];",
    );
    db.add(&fs, "/src/other.ts", "export const other = 1;");
    db.events.0.lock().unwrap().clear();
    assert_eq!(db.cases(module, "value"), strings(&["A", "B", "C"]));
    let events = std::mem::take(&mut *db.events.0.lock().unwrap());
    assert_eq!(
        function_query_will_execute_count_by_name(&db, "infer_module_types", &events),
        0
    );
    db.add(&fs, "/src/other.ts", "export const other = 2;");
    db.events.0.lock().unwrap().clear();
    assert_eq!(db.cases(module, "value"), strings(&["A", "B", "C"]));
    let events = std::mem::take(&mut *db.events.0.lock().unwrap());
    assert_eq!(
        function_query_will_execute_count_by_name(&db, "normalize_type", &events),
        0
    );
    db.add(
        &fs,
        "/src/defs.ts",
        "export const letters = ['A', 'D'] as const;",
    );
    assert_eq!(db.cases(module, "value"), strings(&["A", "D"]));
}

#[test]
fn projection_size_limits_are_exact() {
    for count in [1024, 1025] {
        let fs = MemoryFileSystem::default();
        let mut db = TestDb::new();
        let elements = (0..count)
            .map(|i| format!("\"K{i}\""))
            .collect::<Vec<_>>()
            .join(",");
        let members = (0..count)
            .map(|i| format!("K{i}: number"))
            .collect::<Vec<_>>()
            .join(";");
        let source = format!(
            "declare const tuple: [{elements}][number]; declare const keys: keyof {{{members}}};"
        );
        let module = db.add(&fs, "/src/index.ts", &source);
        for name in ["tuple", "keys"] {
            let ty = db.ty(module, name);
            if count == 1025 {
                assert_eq!(ty, TypeData::Unknown, "{name}");
            } else {
                let TypeData::Union(union) = ty else {
                    panic!("{name}: {ty:?}")
                };
                assert_eq!(union.types(&db).len(), count);
            }
        }
    }
}

#[test]
fn imported_alias_operands_and_object_keys_update_without_module_inference() {
    let fs = MemoryFileSystem::default();
    let mut db = TestDb::new();
    let definitions = r#"
        export type Values = readonly ["A", "B", "C"];
        export type Index = number;
        export type ObjectType = { A: 1; B: 2; C: 3 };
        export const object = { A: unknownValue, B: unknownValue, C: unknownValue };
    "#;
    db.add(&fs, "/src/defs.ts", definitions);
    let module = db.add(
        &fs,
        "/src/index.ts",
        r#"
        import type { Values, Index, ObjectType } from './defs';
        import { object } from './defs';
        declare const tuple: Values[Index];
        declare const keys: keyof typeof object;
        declare const utility: keyof Partial<ObjectType>;
        declare const element: { value: unknown }[][number];
    "#,
    );
    db.events.0.lock().unwrap().clear();
    for name in ["tuple", "keys", "utility"] {
        assert_eq!(db.cases(module, name), strings(&["A", "B", "C"]), "{name}");
    }
    assert!(InferredType::new(&db, db.ty(module, "element")).is_non_nullish());
    let events = std::mem::take(&mut *db.events.0.lock().unwrap());
    assert_eq!(
        function_query_will_execute_count_by_name(&db, "infer_module_types", &events),
        0
    );
    db.add(
        &fs,
        "/src/defs.ts",
        r#"
        export type Values = readonly ["A", "D"];
        export type Index = number;
        export type ObjectType = { A: 1; D: 4 };
        export const object = { A: unknownValue, D: unknownValue };
    "#,
    );
    db.events.0.lock().unwrap().clear();
    for name in ["tuple", "keys", "utility"] {
        assert_eq!(db.cases(module, name), strings(&["A", "D"]), "{name}");
    }
    let events = std::mem::take(&mut *db.events.0.lock().unwrap());
    assert_eq!(
        function_query_will_execute_count_by_name(&db, "infer_module_types", &events),
        0
    );
}
