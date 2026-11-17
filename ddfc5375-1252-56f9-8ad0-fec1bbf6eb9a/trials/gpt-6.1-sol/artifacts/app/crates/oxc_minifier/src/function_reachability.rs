//! References inside an unreachable function do not make other functions live.
//! Keep the semantic reference lists intact: the ordinary removal helpers prune
//! them only when the corresponding AST nodes are actually removed.
use oxc_ast::ast::*;
use oxc_ast_visit::{Visit, walk};
use oxc_semantic::Scoping;
use oxc_syntax::{scope::ScopeFlags, symbol::SymbolId};
use rustc_hash::{FxHashMap, FxHashSet};

pub(crate) fn unreachable_functions(
    program: &Program<'_>,
    scoping: &Scoping,
) -> (FxHashSet<SymbolId>, FxHashSet<SymbolId>) {
    let mut collector = Collector {
        scoping,
        script: program.source_type.is_script(),
        owner: None,
        exported: false,
        observable: FxHashSet::default(),
        candidates: FxHashSet::default(),
        roots: FxHashSet::default(),
        edges: FxHashMap::default(),
    };
    if collector.script {
        collector.observable.extend(scoping.symbol_ids().filter(|&symbol| {
            scoping.symbol_scope_id(symbol) == scoping.root_scope_id()
        }));
    }
    collector.visit_program(program);
    collector.roots.extend(collector.observable.iter().copied());
    let mut pending: Vec<_> = collector.roots.iter().copied().collect();
    while let Some(symbol) = pending.pop() {
        if let Some(edges) = collector.edges.remove(&symbol) {
            for target in edges {
                if collector.roots.insert(target) {
                    pending.push(target);
                }
            }
        }
    }
    collector.candidates.retain(|symbol| !collector.roots.contains(symbol));
    (collector.candidates, collector.observable)
}

struct Collector<'s> {
    scoping: &'s Scoping,
    script: bool,
    owner: Option<SymbolId>,
    exported: bool,
    observable: FxHashSet<SymbolId>,
    candidates: FxHashSet<SymbolId>,
    roots: FxHashSet<SymbolId>,
    edges: FxHashMap<SymbolId, Vec<SymbolId>>,
}

impl Collector<'_> {
    fn candidate(&mut self, symbol: SymbolId) {
        self.candidates.insert(symbol);
        if self.exported {
            self.observable.insert(symbol);
        }
        let scope = self.scoping.symbol_scope_id(symbol);
        if self.exported
            || (self.script && scope == self.scoping.root_scope_id())
            || self.scoping.scope_ancestors(scope).any(|scope| {
                self.scoping.scope_flags(scope).contains_direct_eval()
            })
        {
            self.roots.insert(symbol);
        }
    }
}

impl<'a> Visit<'a> for Collector<'_> {
    fn visit_function(&mut self, function: &Function<'a>, flags: ScopeFlags) {
        let previous = self.owner;
        if function.is_function_declaration() {
            if let Some(id) = &function.id {
                let symbol = id.symbol_id();
                self.candidate(symbol);
                // Sloppy script block functions can also create an Annex B
                // global binding, even though their lexical scope is a block.
                let scope = self.scoping.symbol_scope_id(symbol);
                if self.script
                    && !self.scoping.scope_flags(scope).is_strict_mode()
                    && !self.scoping.scope_ancestors(scope).any(|scope| {
                        self.scoping.scope_flags(scope).is_function()
                    })
                {
                    self.observable.insert(symbol);
                }
                self.owner = Some(symbol);
            }
        }
        let exported = std::mem::replace(&mut self.exported, false);
        walk::walk_function(self, function, flags);
        self.exported = exported;
        self.owner = previous;
    }

    fn visit_variable_declarator(&mut self, declaration: &VariableDeclarator<'a>) {
        let previous = self.owner;
        if self.exported {
            declaration.id.all_binding_identifiers(&mut |id| {
                self.observable.insert(id.symbol_id());
                true
            });
        }
        if !declaration.kind.is_using()
            && let BindingPattern::BindingIdentifier(id) = &declaration.id
            && declaration.init.as_ref().is_some_and(|init| {
                matches!(
                    init.get_inner_expression(),
                    Expression::FunctionExpression(_) | Expression::ArrowFunctionExpression(_)
                )
            })
        {
            let symbol = id.symbol_id();
            self.candidate(symbol);
            self.owner = Some(symbol);
        }
        let exported = std::mem::replace(&mut self.exported, false);
        walk::walk_variable_declarator(self, declaration);
        self.exported = exported;
        self.owner = previous;
    }

    fn visit_identifier_reference(&mut self, identifier: &IdentifierReference<'a>) {
        if let Some(symbol) = self.scoping.get_reference(identifier.reference_id()).symbol_id() {
            if let Some(owner) = self.owner {
                self.edges.entry(owner).or_default().push(symbol);
            } else {
                self.roots.insert(symbol);
            }
        }
    }

    fn visit_export_named_declaration(&mut self, declaration: &ExportNamedDeclaration<'a>) {
        let exported = std::mem::replace(&mut self.exported, true);
        walk::walk_export_named_declaration(self, declaration);
        self.exported = exported;
    }

    fn visit_export_default_declaration(&mut self, declaration: &ExportDefaultDeclaration<'a>) {
        let exported = std::mem::replace(&mut self.exported, true);
        walk::walk_export_default_declaration(self, declaration);
        self.exported = exported;
    }
}

#[cfg(test)]
mod tests {
    use oxc_allocator::Allocator;
    use oxc_codegen::Codegen;
    use oxc_parser::Parser;
    use oxc_span::SourceType;

    use crate::{CompressOptions, Compressor};

    fn compress(source: &str, source_type: SourceType, dce: bool) -> String {
        let allocator = Allocator::default();
        let parsed = Parser::new(&allocator, source, source_type).parse();
        assert!(parsed.diagnostics.is_empty());
        let mut program = parsed.program;
        let compressor = Compressor::new(&allocator);
        if dce {
            compressor.dead_code_elimination(&mut program, CompressOptions::smallest());
        } else {
            compressor.build(&mut program, CompressOptions::smallest());
        }
        Codegen::new().build(&program).code
    }

    #[test]
    fn recursive_components() {
        for dce in [false, true] {
            for source in [
                "function a() {} function b() { if (Math.random()) b() } function c() { d() } function d() { c() }",
                "var a = function() { a() }; let b = () => b(); const c = function named() { named(); c() };",
                "function a() { b() } const b = () => a();",
                "function outer() { function inner() { inner() } inner() }",
                "function a() { a() } function a() { a() }",
            ] {
                for source_type in [SourceType::mjs(), SourceType::cjs()] {
                    assert_eq!(compress(source, source_type, dce), "", "{source}");
                }
            }
            for source_type in [SourceType::mjs(), SourceType::cjs(), SourceType::script()] {
                let output = compress(
                    "(() => { function a() { a() } const b = () => b(); console.log('effect') })()",
                    source_type,
                    dce,
                );
                assert!(!output.contains("function a"), "{output}");
                assert!(!output.contains("const b"), "{output}");
                assert!(output.contains("effect"), "{output}");
            }
        }
    }

    #[test]
    fn observable_roots() {
        for dce in [false, true] {
            for source in [
                "export function a() { b() } function b() { a() }",
                "function a() { b() } function b() { a() } a();",
                "function a() { b() } function b() { a() } export { a };",
                "function a() { a() } eval('a()');",
                "const a = () => a(); module.exports = a;",
            ] {
                assert!(!compress(source, SourceType::mjs(), dce).is_empty(), "{source}");
            }
            let output = compress(
                "var a = () => 1; function set() { a = () => 2 } set();",
                SourceType::script(),
                dce,
            );
            assert!(output.contains("2"), "{output}");
            let output = compress(
                "export let a = () => 1; a = () => 2;",
                SourceType::mjs(),
                dce,
            );
            assert!(output.contains("2"), "{output}");
            let output = compress("function a() { a() }", SourceType::script(), dce);
            assert!(output.contains("function a"), "{output}");
        }
    }
}
