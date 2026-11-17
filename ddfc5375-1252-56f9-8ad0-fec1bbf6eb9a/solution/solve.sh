#!/bin/bash
set -euo pipefail
cd /app
fix=$(mktemp)
cat >"$fix" <<'PATCH'
diff --git a/crates/oxc_minifier/src/compressor.rs b/crates/oxc_minifier/src/compressor.rs
index bfe9fcaee..0c685c23a 100644
--- a/crates/oxc_minifier/src/compressor.rs
+++ b/crates/oxc_minifier/src/compressor.rs
@@ -117,21 +117,37 @@ impl<'a> Compressor<'a> {
         let initial_references_len = ctx.get_mut().scoping().references_len();
         // Consume the drops Normalize recorded (`void x` -> `void 0`,
         // drop_console), so pass 1 already observes the pruned reference
-        // counts and Normalize's drops cost no extra peephole pass.
-        PeepholeOptimizations::flush_pass_dirty(program, ctx.get_mut());
+        // counts and Normalize's drops cost no extra peephole pass. Normalize
+        // also registered function declarations and exports, so post-flush
+        // analysis makes source-level dead cycles (`function f() { f() }`)
+        // visible to pass 1. Ignore the result because pass 1 runs
+        // unconditionally and consumes any newly dead functions.
+        PeepholeOptimizations::end_pass(
+            program,
+            ctx.get_mut(),
+            /* force_liveness_analysis */ true,
+        );
         // Start the loop from a clean signal: Normalize's drops are flushed
         // above, so a Normalize-only mutation must not force a pointless
         // extra iteration.
         ctx.state_mut().take_mutated();
         loop {
             PeepholeOptimizations.run_once(program, ctx);
-            // A pass with no recorded mutation cannot have recorded drops
-            // (every drop helper also records a mutation), so the terminal
-            // iteration skips the flush.
-            if !ctx.state_mut().take_mutated() {
+            let mutated = ctx.state_mut().take_mutated();
+            // Flush every pass. Reachability is recomputed only when a removed
+            // reference belonged to a graph candidate or direct eval was
+            // dropped; only those changes can invalidate the previous verdict.
+            let found_new_dead_functions = PeepholeOptimizations::end_pass(
+                program,
+                ctx.get_mut(),
+                /* force_liveness_analysis */ false,
+            );
+            // Liveness requests another pass only for a newly dead function
+            // (bounded by the candidate set); ordinary AST mutation also keeps
+            // the fixed-point loop running. The iteration cap backstops churn.
+            if !mutated && !found_new_dead_functions {
                 break;
             }
-            PeepholeOptimizations::flush_pass_dirty(program, ctx.get_mut());
             if let Some(max) = max_iterations {
                 if iteration >= max {
                     break;
diff --git a/crates/oxc_minifier/src/lib.rs b/crates/oxc_minifier/src/lib.rs
index f3925ecf7..a98482255 100644
--- a/crates/oxc_minifier/src/lib.rs
+++ b/crates/oxc_minifier/src/lib.rs
@@ -52,6 +52,7 @@ mod options;
 mod peephole;
 mod state;
 mod symbol_facts;
+mod symbol_liveness;
 mod symbol_value;
 mod traverse_context;
 
diff --git a/crates/oxc_minifier/src/peephole/inline.rs b/crates/oxc_minifier/src/peephole/inline.rs
index 8e3e76078..9040a5faa 100644
--- a/crates/oxc_minifier/src/peephole/inline.rs
+++ b/crates/oxc_minifier/src/peephole/inline.rs
@@ -77,7 +77,7 @@ impl<'a> PeepholeOptimizations {
         symbol_id: SymbolId,
         ctx: &TraverseCtx<'a>,
     ) -> bool {
-        if decl.init.is_none() || Self::keep_top_level_var_in_script_mode(ctx) {
+        if decl.init.is_none() || Self::is_script_root_scope(ctx) {
             return false;
         }
         // `body_unsafe` is set by a preceding non-declarative statement, and the
diff --git a/crates/oxc_minifier/src/peephole/minimize_statements.rs b/crates/oxc_minifier/src/peephole/minimize_statements.rs
index 0931bd4c9..b01c34cf6 100644
--- a/crates/oxc_minifier/src/peephole/minimize_statements.rs
+++ b/crates/oxc_minifier/src/peephole/minimize_statements.rs
@@ -1343,9 +1343,7 @@ impl<'a> PeepholeOptimizations {
         ctx: &mut TraverseCtx<'a>,
         non_scoped_literal_only: bool,
     ) -> bool {
-        if Self::keep_top_level_var_in_script_mode(ctx)
-            || ctx.current_scope_flags().contains_direct_eval()
-        {
+        if Self::is_script_root_scope(ctx) || ctx.current_scope_flags().contains_direct_eval() {
             return false;
         }
 
@@ -1387,7 +1385,7 @@ impl<'a> PeepholeOptimizations {
         declarations: &mut ArenaVec<'a, VariableDeclarator<'a>>,
         ctx: &mut TraverseCtx<'a>,
     ) -> bool {
-        if Self::keep_top_level_var_in_script_mode(ctx)
+        if Self::is_script_root_scope(ctx)
             || ctx.current_scope_flags().contains_direct_eval()
             || kind.is_using()
         {
@@ -1457,9 +1455,12 @@ impl<'a> PeepholeOptimizations {
             else {
                 return true;
             };
-            // we should check whether it's exported by `symbol_value.exported`
-            // because the variable might be exported with `export { foo }` rather than `export var foo`
-            if symbol_value.exported
+            // Implicitly observable bindings remain live independently of
+            // their resolved-reference count.
+            // An `export { foo }` specifier also contributes a reference, but
+            // consult the shared metadata explicitly for consistency with the
+            // other count-based consumers.
+            if ctx.state.symbol_is_implicitly_observable(prev_decl_id.symbol_id())
                 || symbol_value.read_references_count > 1
                 || symbol_value.write_references_count > 0
             {
diff --git a/crates/oxc_minifier/src/peephole/mod.rs b/crates/oxc_minifier/src/peephole/mod.rs
index 3c797d339..4bcad81ba 100644
--- a/crates/oxc_minifier/src/peephole/mod.rs
+++ b/crates/oxc_minifier/src/peephole/mod.rs
@@ -32,7 +32,7 @@ use oxc_ast::ast::*;
 
 use crate::{
     ReusableTraverseCtx, Traverse, TraverseCtx, minifier_traverse::traverse_mut_with_ctx,
-    traverse_context::as_direct_eval_call,
+    symbol_liveness, traverse_context::as_direct_eval_call,
 };
 
 pub use self::normalize::{Normalize, NormalizeOptions};
@@ -396,12 +396,14 @@ impl<'a> PeepholeOptimizations {
     /// references from scoping, refresh direct-eval flags if an `eval(...)`
     /// call was dropped, and re-initialize the accumulator.
     ///
-    /// The `Compressor` driver calls this after `Normalize` (so the
-    /// fixed-point loop starts against already-pruned scoping and
-    /// Normalize's drops cost no extra peephole pass) and after every
-    /// peephole pass.
-    pub(crate) fn flush_pass_dirty(program: &Program<'a>, ctx: &mut TraverseCtx<'a>) {
+    /// [`Self::end_pass`] calls this after `Normalize` (so the fixed-point
+    /// loop starts against already-pruned scoping and Normalize's drops cost
+    /// no extra peephole pass) and after every peephole pass — quiet ones
+    /// included, where every step below is a cheap no-op.
+    fn flush_pass_dirty(program: &Program<'a>, ctx: &mut TraverseCtx<'a>) -> bool {
         let had_dead = !ctx.state.dirty.dead_refs.is_empty();
+        let liveness_inputs_changed = ctx.state.dirty.eval_dropped
+            || (had_dead && symbol_liveness::dead_references_affect_analysis(ctx));
 
         // (1) Resolved references — direct consumption, no walk.
         //     Dirty data is built by `replace_*` / `drop_*` helpers as
@@ -445,6 +447,20 @@ impl<'a> PeepholeOptimizations {
             ctx.state.dirty.dead_refs = BitSet::new_in(refs_len, ctx.allocator());
         }
         ctx.state.dirty.eval_dropped = false;
+        liveness_inputs_changed
+    }
+
+    /// End-of-pass sequence: flush the dirty accumulator into scoping, then
+    /// derive function reachability from those settled semantic references.
+    /// Keeping the pair together makes the ordering structural. Returns
+    /// whether newly dead functions demand another pass.
+    pub(crate) fn end_pass(
+        program: &Program<'a>,
+        ctx: &mut TraverseCtx<'a>,
+        force_liveness_analysis: bool,
+    ) -> bool {
+        let liveness_inputs_changed = Self::flush_pass_dirty(program, ctx);
+        symbol_liveness::analyze(program, ctx, force_liveness_analysis || liveness_inputs_changed)
     }
 }
 
@@ -466,8 +482,8 @@ impl<'a> Traverse<'a> for PeepholeOptimizations {
         // than reallocating (matching the `reset`/`clear` above).
         *ctx.state.body_unsafe_stack.last_mut() =
             (ctx.scoping().root_scope_id(), module_has_loaders);
-        // `PassDirty` is managed by the `Compressor` driver via
-        // `flush_pass_dirty`, not reset per traversal.
+        // `PassDirty` is managed by the end-of-pass sequence, not reset per
+        // traversal.
     }
 
     fn enter_function_body(&mut self, _body: &mut FunctionBody<'a>, ctx: &mut TraverseCtx<'a>) {
diff --git a/crates/oxc_minifier/src/peephole/normalize.rs b/crates/oxc_minifier/src/peephole/normalize.rs
index 6e9a6119a..49f6ef990 100644
--- a/crates/oxc_minifier/src/peephole/normalize.rs
+++ b/crates/oxc_minifier/src/peephole/normalize.rs
@@ -11,7 +11,7 @@ use oxc_syntax::scope::ScopeFlags;
 use super::PeepholeOptimizations;
 use crate::{
     ReusableTraverseCtx, Traverse, TraverseCtx, minifier_traverse::traverse_mut_with_ctx,
-    symbol_facts::SymbolFact,
+    symbol_facts::SymbolFact, symbol_liveness,
 };
 
 #[derive(Default)]
@@ -58,6 +58,38 @@ impl<'a> Traverse<'a> for Normalize {
         }
     }
 
+    // Normalize is the only traversal that builds stable liveness metadata:
+    // registered function declarations and implicitly observable bindings.
+    // Each post-flush analysis derives ownership and reachability from the
+    // current semantic references.
+    fn enter_function(&mut self, node: &mut Function<'a>, ctx: &mut TraverseCtx<'a>) {
+        symbol_liveness::register_function(node, ctx);
+    }
+
+    fn enter_variable_declaration(
+        &mut self,
+        node: &mut VariableDeclaration<'a>,
+        ctx: &mut TraverseCtx<'a>,
+    ) {
+        symbol_liveness::register_using_declaration(node, ctx);
+    }
+
+    fn enter_export_named_declaration(
+        &mut self,
+        node: &mut ExportNamedDeclaration<'a>,
+        ctx: &mut TraverseCtx<'a>,
+    ) {
+        symbol_liveness::register_named_export(node, ctx);
+    }
+
+    fn enter_export_default_declaration(
+        &mut self,
+        node: &mut ExportDefaultDeclaration<'a>,
+        ctx: &mut TraverseCtx<'a>,
+    ) {
+        symbol_liveness::register_default_export(node, ctx);
+    }
+
     fn exit_statements(
         &mut self,
         stmts: &mut ArenaVec<'a, Statement<'a>>,
@@ -309,9 +341,8 @@ impl<'a> Normalize {
             return;
         }
         // `replace_expression` walks the dropped ident into `PassDirty`, so
-        // its resolved reference is pruned by the driver's pre-loop
-        // `flush_pass_dirty`, before pass 1 — otherwise the symbol would
-        // look referenced forever.
+        // its resolved reference is pruned by the pre-loop `end_pass` flush,
+        // before pass 1 — otherwise the symbol would look referenced forever.
         let new_arg =
             Expression::new_numeric_literal(ident.span, 0.0, None, NumberBase::Decimal, ctx);
         ctx.replace_expression(&mut e.argument, new_arg);
diff --git a/crates/oxc_minifier/src/peephole/remove_unused_declaration.rs b/crates/oxc_minifier/src/peephole/remove_unused_declaration.rs
index 93478cd23..310ac8247 100644
--- a/crates/oxc_minifier/src/peephole/remove_unused_declaration.rs
+++ b/crates/oxc_minifier/src/peephole/remove_unused_declaration.rs
@@ -2,14 +2,67 @@ use super::PeepholeOptimizations;
 use crate::{CompressOptionsUnused, TraverseCtx};
 use oxc_ast::ast::*;
 use oxc_ecmascript::constant_evaluation::{DetermineValueType, ValueType};
+use oxc_syntax::symbol::SymbolId;
 
 impl<'a> PeepholeOptimizations {
     pub(super) fn can_remove_unused_declarators(ctx: &TraverseCtx<'a>) -> bool {
         ctx.state.options.unused != CompressOptionsUnused::Keep
-            && !Self::keep_top_level_var_in_script_mode(ctx)
+            && !Self::is_script_root_scope(ctx)
             && !ctx.scoping().root_scope_flags().contains_direct_eval()
     }
 
+    /// Count-based unusedness for declaration removal and IIFE folding. The
+    /// assignment, member-write, and single-use-substitution consumers instead
+    /// pair `symbol_is_implicitly_observable` with their own count thresholds,
+    /// because some runtime semantics can observe a binding independently of
+    /// resolved references.
+    pub(super) fn symbol_is_unused_by_count(symbol_id: SymbolId, ctx: &TraverseCtx<'a>) -> bool {
+        !ctx.state.symbol_is_implicitly_observable(symbol_id)
+            && ctx.scoping().symbol_is_unused(symbol_id)
+    }
+
+    /// Function declarations additionally consume graph deadness, allowing
+    /// self- and mutually-recursive cycles to be removed.
+    fn function_has_no_live_references(symbol_id: SymbolId, ctx: &TraverseCtx<'a>) -> bool {
+        Self::symbol_is_unused_by_count(symbol_id, ctx) || ctx.state.function_is_dead(symbol_id)
+    }
+
+    /// Return `true` when an exact function-valued initializer contains every
+    /// reference to its own binding. Creating a function or arrow has no side
+    /// effects, and without a reference from outside that function it can
+    /// never be called.
+    ///
+    /// This check deliberately runs at the declarator removal site instead of
+    /// registering declarators in the recursive-function graph. That keeps
+    /// mutual declarator cycles unsupported, but also means statement
+    /// relocation cannot leave a dead candidate in a non-removable AST slot.
+    /// For example, `const f = () => f()` is removable, while adding `use(f)`
+    /// supplies an outside reference and keeps it.
+    fn self_recursive_function_declarator_is_unused(
+        decl: &VariableDeclarator<'a>,
+        symbol_id: SymbolId,
+        ctx: &TraverseCtx<'a>,
+    ) -> bool {
+        let Some(function_scope_id) = decl.init.as_ref().and_then(|init| match init {
+            Expression::FunctionExpression(function) => function.scope_id.get(),
+            Expression::ArrowFunctionExpression(arrow) => arrow.scope_id.get(),
+            _ => None,
+        }) else {
+            return false;
+        };
+
+        // Covers exports, Script-root bindings, Annex B aliases, and `using`.
+        if ctx.state.symbol_is_implicitly_observable(symbol_id) {
+            return false;
+        }
+
+        ctx.scoping().get_resolved_references(symbol_id).all(|reference| {
+            ctx.scoping()
+                .scope_ancestors(reference.scope_id())
+                .any(|scope_id| scope_id == function_scope_id)
+        })
+    }
+
     fn is_sync_iterator_expr(expr: &Expression<'a>, ctx: &TraverseCtx<'a>) -> bool {
         match expr {
             Expression::ArrayExpression(_)
@@ -44,7 +97,10 @@ impl<'a> PeepholeOptimizations {
         match &decl.id {
             BindingPattern::BindingIdentifier(ident) => {
                 if let Some(symbol_id) = ident.symbol_id.get() {
-                    return ctx.scoping().symbol_is_unused(symbol_id);
+                    return Self::symbol_is_unused_by_count(symbol_id, ctx)
+                        || Self::self_recursive_function_declarator_is_unused(
+                            decl, symbol_id, ctx,
+                        );
                 }
                 false
             }
@@ -107,12 +163,10 @@ impl<'a> PeepholeOptimizations {
         }
         let Some(id) = &f.id else { return };
         let Some(symbol_id) = id.symbol_id.get() else { return };
-        if Self::keep_top_level_var_in_script_mode(ctx)
-            || ctx.current_scope_flags().contains_direct_eval()
-        {
+        if Self::is_script_root_scope(ctx) || ctx.current_scope_flags().contains_direct_eval() {
             return;
         }
-        if !ctx.scoping().symbol_is_unused(symbol_id) {
+        if !Self::function_has_no_live_references(symbol_id, ctx) {
             return;
         }
         let new_stmt = Statement::new_empty_statement(f.span, ctx);
@@ -126,12 +180,10 @@ impl<'a> PeepholeOptimizations {
         }
         let Some(id) = &c.id else { return };
         let Some(symbol_id) = id.symbol_id.get() else { return };
-        if Self::keep_top_level_var_in_script_mode(ctx)
-            || ctx.current_scope_flags().contains_direct_eval()
-        {
+        if Self::is_script_root_scope(ctx) || ctx.current_scope_flags().contains_direct_eval() {
             return;
         }
-        if !ctx.scoping().symbol_is_unused(symbol_id) {
+        if !Self::symbol_is_unused_by_count(symbol_id, ctx) {
             return;
         }
         if let Some(changed) = Self::remove_unused_class(c, ctx).map(|exprs| {
@@ -146,8 +198,8 @@ impl<'a> PeepholeOptimizations {
         }
     }
 
-    /// Do remove top level vars in script mode.
-    pub fn keep_top_level_var_in_script_mode(ctx: &TraverseCtx<'a>) -> bool {
+    /// Whether bindings in the current scope are visible to later scripts.
+    pub fn is_script_root_scope(ctx: &TraverseCtx<'a>) -> bool {
         ctx.scoping.current_scope_id() == ctx.scoping().root_scope_id()
             && ctx.source_type().is_script()
     }
diff --git a/crates/oxc_minifier/src/peephole/remove_unused_expression.rs b/crates/oxc_minifier/src/peephole/remove_unused_expression.rs
index 524c1fc83..a62079ed9 100644
--- a/crates/oxc_minifier/src/peephole/remove_unused_expression.rs
+++ b/crates/oxc_minifier/src/peephole/remove_unused_expression.rs
@@ -761,9 +761,7 @@ impl<'a> PeepholeOptimizations {
         else {
             unreachable!()
         };
-        if Self::keep_top_level_var_in_script_mode(ctx)
-            || ctx.current_scope_flags().contains_direct_eval()
-        {
+        if Self::is_script_root_scope(ctx) || ctx.current_scope_flags().contains_direct_eval() {
             return false;
         }
         let reference_id = ident.reference_id();
@@ -774,13 +772,14 @@ impl<'a> PeepholeOptimizations {
         if ctx.scoping().symbol_flags(symbol_id).is_const_variable() {
             return false;
         }
+        // Cannot remove writes to implicitly observable bindings, for example
+        // `export let foo; foo = 1;`.
+        if ctx.state.symbol_is_implicitly_observable(symbol_id) {
+            return false;
+        }
         let Some(symbol_value) = ctx.state.symbol_values.get_symbol_value(symbol_id) else {
             return false;
         };
-        // Cannot remove assignment to live bindings: `export let foo; foo = 1;`.
-        if symbol_value.exported {
-            return false;
-        }
         if symbol_value.read_references_count > 0 {
             return false;
         }
@@ -802,7 +801,7 @@ impl<'a> PeepholeOptimizations {
     ///   `__proto__` setters) — the `MEMBER_WRITE_HAZARD` fact in
     ///   `MinifierState::symbol_facts`. See `docs/ASSUMPTIONS.md`.
     fn remove_unused_member_assignment(e: &mut Expression<'a>, ctx: &mut TraverseCtx<'a>) -> bool {
-        if Self::keep_top_level_var_in_script_mode(ctx) {
+        if Self::is_script_root_scope(ctx) {
             return false;
         }
         let Expression::AssignmentExpression(assign_expr) = &*e else { unreachable!() };
@@ -968,7 +967,7 @@ impl<'a> PeepholeOptimizations {
     /// Four conditions must hold:
     /// 1. The target is a single-level member expression (`A.foo`, not `a.b.c`)
     /// 2. ALL references to the symbol are member write targets
-    /// 3. The symbol creates a fresh value (not an alias) and is not exported
+    /// 3. The symbol creates a fresh value and is not otherwise observable
     /// 4. No `__proto__` write may have installed a setter that another
     ///    reference could trigger
     fn is_member_assign_to_unused_binding(symbol_id: SymbolId, ctx: &TraverseCtx<'a>) -> bool {
@@ -984,11 +983,14 @@ impl<'a> PeepholeOptimizations {
             return false;
         }
 
-        // Check: symbol creates a fresh value (not an alias) and is not exported.
+        // Check: symbol creates a fresh value and is not implicitly observable.
+        if ctx.state.symbol_is_implicitly_observable(symbol_id) {
+            return false;
+        }
         let Some(sv) = ctx.state.symbol_values.get_symbol_value(symbol_id) else {
             return false;
         };
-        if sv.kind == FreshValueKind::None || sv.exported {
+        if sv.kind == FreshValueKind::None {
             return false;
         }
         // Check: all references are member write targets (O(1) via pre-computed count).
diff --git a/crates/oxc_minifier/src/peephole/substitute_alternate_syntax.rs b/crates/oxc_minifier/src/peephole/substitute_alternate_syntax.rs
index 6fd7a4b34..5b322129e 100644
--- a/crates/oxc_minifier/src/peephole/substitute_alternate_syntax.rs
+++ b/crates/oxc_minifier/src/peephole/substitute_alternate_syntax.rs
@@ -574,8 +574,9 @@ impl<'a> PeepholeOptimizations {
             ctx.scoping().get_reference(is_null_id_ref.reference_id()).symbol_id();
 
         // Plain `clone_in` resets every `reference_id` to `None`, making id
-        // aliasing structurally impossible; the loop below installs the one
-        // fresh reference the clone needs.
+        // aliasing structurally impossible. The fresh references below are
+        // stamped with the current scope, so the next post-flush graph
+        // analysis observes them directly from scoping.
         let mut new_left_expr = typeof_binary_expr.clone_in(ctx.allocator());
         if let Expression::BinaryExpression(new_left_expr_binary) = &mut new_left_expr {
             new_left_expr_binary.operator =
@@ -1888,8 +1889,8 @@ impl<'a> PeepholeOptimizations {
     }
 
     /// Whether the expression's result will be discarded — bare expression
-    /// statement, or the init of a `var`/`let`/`const` whose binding has no
-    /// references and isn't exported. Used by the IIFE inliner to short-circuit
+    /// statement, or the init of a `var`/`let`/`const` whose binding is unused
+    /// by count. Used by the IIFE inliner to short-circuit
     /// pure-annotated IIFEs to `void 0` so they drop regardless of body shape,
     /// and to allow `(async () => {})()` / `(function* () {})()` (whose return
     /// value isn't a meaningful result) to collapse in those positions too.
@@ -1908,32 +1909,12 @@ impl<'a> PeepholeOptimizations {
                 let BindingPattern::BindingIdentifier(ident) = decl.id() else {
                     return false;
                 };
-                if !ctx.scoping().symbol_is_unused(ident.symbol_id()) {
-                    return false;
-                }
-                !Self::var_declaration_is_exported(ctx)
+                Self::symbol_is_unused_by_count(ident.symbol_id(), ctx)
             }
             _ => false,
         }
     }
 
-    /// `true` if the `VariableDeclaration` that contains the current expression
-    /// (entered via `VariableDeclaratorInit`) sits directly under an `export`
-    /// wrapper. Exports are cross-module reachable, and the inner
-    /// `VariableDeclaration` never routes through `handle_variable_declaration`
-    /// — dropping its init would silently break the export's runtime value.
-    ///
-    /// Checks the exact ancestor slot above `VariableDeclaration` only;
-    /// walking the full chain would over-broaden the guard to function-local
-    /// vars inside exported functions.
-    fn var_declaration_is_exported(ctx: &TraverseCtx<'a>) -> bool {
-        // Only `ExportNamedDeclaration`'s `declaration` field can hold a
-        // `VariableDeclaration`. `export default` wraps a function / class /
-        // expression — never a `VariableDeclaration` — so no arm is needed
-        // for it.
-        matches!(ctx.ancestors().nth(2), Some(Ancestor::ExportNamedDeclarationDeclaration(_)))
-    }
-
     /// Optimizes the usage of Immediately Invoked Function Expressions (IIFEs)
     /// within the given expression and context by performing various substitutions
     /// to clean up and simplify the code.
diff --git a/crates/oxc_minifier/src/state.rs b/crates/oxc_minifier/src/state.rs
index fdc937e6d..0e54cb969 100644
--- a/crates/oxc_minifier/src/state.rs
+++ b/crates/oxc_minifier/src/state.rs
@@ -8,13 +8,16 @@ use oxc_span::SourceType;
 use oxc_str::Str;
 use oxc_syntax::{scope::ScopeId, symbol::SymbolId};
 
-use crate::{CompressOptions, symbol_facts::PersistentSymbolFacts, symbol_value::SymbolValues};
+use crate::{
+    CompressOptions, symbol_facts::PersistentSymbolFacts, symbol_liveness::SymbolLiveness,
+    symbol_value::SymbolValues,
+};
 
 /// Dirty data accumulated by the `replace_*` / `drop_*` helper calls between
 /// two consumption points. Live from `MinifierState::new` so the pre-loop
 /// `Normalize` pass records drops through the same typed helpers as the
-/// peephole loop; consumed and re-initialized by `flush_pass_dirty` in the
-/// `Compressor` driver after `Normalize` and after every peephole pass.
+/// peephole loop; consumed and reset or resized by the end-of-pass sequence
+/// after `Normalize` and after every peephole pass.
 pub struct PassDirty<'a> {
     /// `ReferenceId`s whose AST node has been removed and not re-installed
     /// in any later mutation this pass.
@@ -98,11 +101,18 @@ pub struct MinifierState<'a> {
     mutated: bool,
 
     /// Per-pass dirty accumulator populated by `replace_*` / `drop_*` helpers
-    /// as subtrees are removed. Consumed by `flush_pass_dirty` in the
-    /// `Compressor` driver (pre-loop and after each mutated pass) to drive
-    /// the incremental scoping refresh.
+    /// as subtrees are removed. Consumed by the end-of-pass sequence after
+    /// Normalize and every peephole pass to drive the incremental scoping
+    /// refresh.
     pub(crate) dirty: PassDirty<'a>,
 
+    /// Implicitly observable bindings plus the optional recursive-function
+    /// graph. Present for modules or when unused removal is enabled; a `using`
+    /// declaration can also create it lazily. Stable metadata is seeded from
+    /// scoping and Normalize; post-flush analysis derives reachability from the
+    /// current semantic reference lists.
+    pub(crate) symbol_liveness: Option<SymbolLiveness<'a>>,
+
     /// Scratch buffer reused by `try_fold_concat` to build template literal
     /// quasis without allocating a fresh `String` per call.
     pub concat_scratch: String,
@@ -116,6 +126,8 @@ impl<'a> MinifierState<'a> {
         scoping: &Scoping,
         allocator: &'a Allocator,
     ) -> Self {
+        let symbol_liveness =
+            SymbolLiveness::new_if_enabled(source_type, &options, scoping, allocator);
         Self {
             source_type,
             options,
@@ -127,6 +139,7 @@ impl<'a> MinifierState<'a> {
             body_unsafe_stack: NonEmptyStack::new((scoping.root_scope_id(), false)),
             mutated: false,
             dirty: PassDirty::new(scoping.references_len(), allocator),
+            symbol_liveness,
             concat_scratch: String::new(),
         }
     }
@@ -143,6 +156,21 @@ impl<'a> MinifierState<'a> {
         !self.dce || !self.options.treeshake.property_write_side_effects
     }
 
+    /// Whether runtime semantics have an implicit observation channel that
+    /// remains even if every resolved reference disappears from the current
+    /// AST.
+    pub(crate) fn symbol_is_implicitly_observable(&self, symbol_id: SymbolId) -> bool {
+        self.symbol_liveness
+            .as_ref()
+            .is_some_and(|liveness| liveness.is_implicitly_observable(symbol_id))
+    }
+
+    /// Whether post-flush graph analysis proved a function declaration
+    /// unreachable from executing code.
+    pub(crate) fn function_is_dead(&self, symbol_id: SymbolId) -> bool {
+        self.symbol_liveness.as_ref().is_some_and(|liveness| liveness.function_is_dead(symbol_id))
+    }
+
     /// Returns whether the AST was mutated since the last call, and resets.
     /// Read and reset are one operation so the signal cannot be cleared
     /// anywhere except at its single consumption point.
diff --git a/crates/oxc_minifier/src/symbol_liveness/mod.rs b/crates/oxc_minifier/src/symbol_liveness/mod.rs
new file mode 100644
index 000000000..e464825bf
--- /dev/null
+++ b/crates/oxc_minifier/src/symbol_liveness/mod.rs
@@ -0,0 +1,631 @@
+//! Symbol liveness: observability that reference counts cannot express, and
+//! reachability for recursively referenced function declarations.
+//!
+//! Reference counting removes an acyclic unused declaration once its last
+//! reference disappears, but it cannot remove `function a() { b() }
+//! function b() { a() }`: each function keeps the other's count non-zero.
+//! This module adds the missing reachability question: can executing code
+//! reach a candidate function declaration?
+//!
+//! Four concepts define the analysis:
+//!
+//! 1. **Candidates** are eligible function declarations whose deadness may
+//!    require graph reachability. Normalize initially registers every eligible
+//!    declaration. Analysis permanently untracks a non-dead candidate once no
+//!    current reference has a registered function owner; it no longer needs
+//!    graph reachability, so ordinary removal checks handle it from then on.
+//!    Published-dead candidates remain tracked to enforce monotonicity. Other
+//!    declaration kinds continue to use reference counts.
+//!    Self-recursive function and arrow expressions in declarator initializers
+//!    are handled by a local check at their removal site
+//!    (`self_recursive_function_declarator_is_unused`) and need no graph state.
+//! 2. **Ownership** comes from semantic scopes. The nearest registered function
+//!    declaration is a reference's owner. A reference from a candidate that is
+//!    not implicitly observable is stored as `(owner, target)` and propagates
+//!    when the owner becomes live. Implicitly observable owners and references
+//!    outside registered functions make their targets live immediately. A
+//!    registered non-candidate owner does so only while implicitly observable
+//!    or count-live, because a count-dead owner's body never executes.
+//! 3. **Implicit observability** is stable metadata for bindings whose runtime
+//!    value can be observed without a resolved reference in this AST. A symbol
+//!    here may have any number of references; the bit records that an observer
+//!    remains even if every reference disappears. The four channels are module
+//!    exports, Script-root bindings, Annex B aliases, and `using` disposal. This
+//!    metadata protects every count-based removal consumer, not only
+//!    declaration removal.
+//! 4. **Analysis runs after scoping is flushed.** Every result is derived from
+//!    the settled resolved-reference lists, so AST rewrites need no parallel
+//!    collection hooks or behind-the-cursor repair log.
+//!
+//! ## Transform contract
+//!
+//! Functions are registered once during Normalize and the graph is recomputed
+//! only when its settled inputs can change. Peephole transforms must preserve
+//! four invariants:
+//!
+//! 1. **Do not create function declarations.** A new declaration would have no
+//!    entry in `function_by_scope` and therefore could not own references or
+//!    become a candidate. Removing an existing declaration is supported.
+//! 2. **Do not move an existing reference across function owners.** Ownership
+//!    comes from `Reference::scope_id()` and the registered function-scope
+//!    ancestors. A transform that changes the nearest owning function must
+//!    instead drop and recreate the reference, so the dirty gate requests a
+//!    new analysis.
+//! 3. **Do not create a path to a function already published as dead.** Deadness
+//!    is monotonic. Transforms may duplicate an already-live reference, but
+//!    must not make an unreachable binding reachable; debug builds assert that
+//!    a dead function never becomes live again.
+//! 4. **Do not form a direct eval call.** Semantic flags propagate any direct
+//!    eval to the root scope, disabling the analysis for the whole program. The
+//!    analysis relies on that flag only ever clearing (dropping an eval
+//!    re-triggers analysis). An eval created after deadness was published could
+//!    reach a removed function. Debug builds assert this never happens.
+//!
+//! A transform that needs to violate one of these invariants must first extend
+//! function registration or the dirty-analysis signal. Keeping this boundary
+//! explicit is what lets the analysis run without per-transform collection
+//! hooks or a reference-mint log.
+//!
+//! ES module bindings and CommonJS top-level bindings are local to their module
+//! or wrapper. Script root bindings are visible to later scripts, so root
+//! function declarations are implicitly observable, not graph candidates;
+//! references in their bodies keep local candidates live. Local declarations
+//! inside Script functions and strict blocks can still be removed.
+//!
+//! Treating a count-dead non-candidate owner's body as unreachable requires
+//! that a declaration cannot execute without a resolved reference.
+//! Registration therefore also excludes sloppy Annex B block functions whose
+//! runtime var-alias write is not represented by their block-scoped symbol.
+//!
+//! ## Current limitations
+//!
+//! - Only function declarations are candidates. Mutual declarator cycles
+//!   (`const a = () => b(); const b = () => a();`) and class cycles are kept.
+//!   Making them candidates measured zero output bytes on real bundles but
+//!   caused most of the wrong-code hazards, and class removal has no stable
+//!   proof (`remove_unused_class` extracts static values, and heritage
+//!   classification can change between passes).
+//! - Any direct eval propagates to the root scope and disables the analysis for
+//!   the whole program. There is no per-scope granularity.
+//! - Sloppy unhoisted Annex B block functions are always kept, even when
+//!   nothing can reach them. Removing them requires modeling the runtime
+//!   var-alias write.
+
+use oxc_allocator::{Allocator, ArenaVec, BitSet, GetAllocator};
+use oxc_ast::ast::*;
+#[cfg(debug_assertions)]
+use oxc_ast_visit::{VisitJs, walk_js::walk_function};
+use oxc_ecmascript::BoundNames;
+use oxc_semantic::Scoping;
+use oxc_span::SourceType;
+use oxc_syntax::{reference::ReferenceId, scope::ScopeId, symbol::SymbolId};
+
+use crate::{CompressOptions, CompressOptionsUnused, TraverseCtx};
+
+/// Stable program-wide symbol facts plus the optional recursive-function graph.
+///
+/// This is always present for ES modules because exported-binding implicit
+/// observability must protect count-based optimizations even when recursive
+/// function removal is disabled. For CommonJS and Script sources it exists
+/// whenever unused-declaration removal is enabled, and a `using` declaration
+/// creates it lazily even otherwise, because disposal observes its binding
+/// without an ordinary reference.
+pub struct SymbolLiveness<'a> {
+    /// Bindings with a runtime observer independent of resolved references:
+    /// module exports, Script roots, Annex B aliases, and `using` disposal.
+    implicitly_observable: BitSet<'a>,
+    recursive_functions: Option<FunctionGraph<'a>>,
+}
+
+impl<'a> SymbolLiveness<'a> {
+    /// Return `None` when the configuration needs no symbol liveness: a
+    /// non-module source with unused-declaration removal disabled.
+    pub fn new_if_enabled(
+        source_type: SourceType,
+        options: &CompressOptions,
+        scoping: &Scoping,
+        allocator: &'a Allocator,
+    ) -> Option<Self> {
+        let recursive_functions_enabled = options.unused != CompressOptionsUnused::Keep;
+        if !source_type.is_module() && !recursive_functions_enabled {
+            return None;
+        }
+        Some(Self::new(source_type, scoping, allocator))
+    }
+
+    /// Seed implicit observability from scoping; the function graph is created
+    /// lazily at first registration.
+    fn new(source_type: SourceType, scoping: &Scoping, allocator: &'a Allocator) -> Self {
+        let symbols_len = scoping.symbols_len();
+        let mut implicitly_observable = BitSet::new_in(symbols_len, allocator);
+        if source_type.is_script() {
+            for &symbol_id in scoping.get_bindings(scoping.root_scope_id()).values() {
+                implicitly_observable.set_bit(symbol_id.index());
+            }
+        }
+        Self { implicitly_observable, recursive_functions: None }
+    }
+
+    #[inline]
+    pub fn is_implicitly_observable(&self, symbol_id: SymbolId) -> bool {
+        self.implicitly_observable.contains(symbol_id.index())
+    }
+
+    #[inline]
+    pub fn function_is_dead(&self, symbol_id: SymbolId) -> bool {
+        self.recursive_functions.as_ref().is_some_and(|graph| graph.is_dead(symbol_id))
+    }
+
+    fn mark_implicitly_observable(&mut self, symbol_id: SymbolId) {
+        self.implicitly_observable.set_bit(symbol_id.index());
+    }
+
+    fn mark_bound_names<'b>(&mut self, node: &impl BoundNames<'b>) {
+        node.bound_names(&mut |ident| {
+            if let Some(symbol_id) = ident.symbol_id.get() {
+                self.mark_implicitly_observable(symbol_id);
+            }
+        });
+    }
+
+    fn register_function(
+        &mut self,
+        function: &Function<'_>,
+        source_type: SourceType,
+        scoping: &Scoping,
+        allocator: &'a Allocator,
+    ) {
+        let Some(symbol_id) = function.id.as_ref().and_then(|id| id.symbol_id.get()) else {
+            return;
+        };
+        let Some(scope_id) = function.scope_id.get() else { return };
+
+        let binding_scope_id = scoping.symbol_scope_id(symbol_id);
+
+        // Annex B block functions also assign their function object to a
+        // var-like binding when the block executes. Semantic hoisting records
+        // that alias when possible, but duplicates and TypeScript declarations
+        // can retain a block-scoped symbol even though the runtime alias write
+        // still occurs. Such a declaration and writes to it can be observed
+        // with no resolved reference to its own symbol, so mark it implicitly
+        // observable instead of registering it.
+        let binding_scope_flags = scoping.scope_flags(binding_scope_id);
+        if !function.r#async
+            && !function.generator
+            && !binding_scope_flags.is_var()
+            && !binding_scope_flags.is_strict_mode()
+        {
+            self.mark_implicitly_observable(symbol_id);
+            return;
+        }
+
+        if source_type.is_script() && binding_scope_id == scoping.root_scope_id() {
+            // Already seeded implicitly observable by `new`; only graph
+            // candidacy is skipped here.
+            return;
+        }
+
+        let graph =
+            self.recursive_functions.get_or_insert_with(|| FunctionGraph::new(scoping, allocator));
+        graph.register(scope_id, symbol_id);
+    }
+
+    fn analyze(&mut self, scoping: &Scoping) -> bool {
+        let Some(graph) = &mut self.recursive_functions else { return false };
+        graph.analyze(scoping, &self.implicitly_observable)
+    }
+
+    #[cfg(debug_assertions)]
+    fn dead_functions(&self) -> Option<&BitSet<'a>> {
+        self.recursive_functions.as_ref().map(|graph| &graph.dead)
+    }
+}
+
+/// The recursive-function reachability graph and its reused analysis buffers.
+struct FunctionGraph<'a> {
+    /// Eligible functions the graph still tracks. [`Self::analyze`]
+    /// permanently stops tracking a non-dead candidate whose references all
+    /// lie outside registered functions, because it no longer needs graph
+    /// reachability. Graph-independent removal checks then handle it. Untracked
+    /// functions stay in `function_by_scope` and can still own references.
+    candidates: BitSet<'a>,
+    /// Maps each registered function declaration's own scope to its symbol.
+    /// Owner lookup walks the current semantic parent chain, so scopes inserted
+    /// or reparented after Normalize remain correct.
+    function_by_scope: ArenaVec<'a, Option<SymbolId>>,
+    /// Function symbols already published as unreachable. Declaration-removal
+    /// sites consume membership, but bits persist after AST removal so later
+    /// analyses can reject resurrection. Deadness is monotonic.
+    dead: BitSet<'a>,
+    scratch: GraphScratch<'a>,
+}
+
+impl<'a> FunctionGraph<'a> {
+    fn new(scoping: &Scoping, allocator: &'a Allocator) -> Self {
+        let symbols_len = scoping.symbols_len();
+        let function_by_scope =
+            ArenaVec::from_iter_in(std::iter::repeat_n(None, scoping.scopes_len()), &allocator);
+        Self {
+            candidates: BitSet::new_in(symbols_len, allocator),
+            function_by_scope,
+            dead: BitSet::new_in(symbols_len, allocator),
+            scratch: GraphScratch::new(symbols_len, allocator),
+        }
+    }
+
+    fn register(&mut self, scope_id: ScopeId, symbol_id: SymbolId) {
+        self.function_by_scope[scope_id.index()] = Some(symbol_id);
+        self.candidates.set_bit(symbol_id.index());
+    }
+
+    #[inline]
+    fn is_dead(&self, symbol_id: SymbolId) -> bool {
+        self.dead.contains(symbol_id.index())
+    }
+
+    /// Returns the nearest registered function whose body contains
+    /// `scope_id`. Code there only runs when that function is called. `None`
+    /// means the scope is not inside any registered function, so references
+    /// there make their target unconditionally live.
+    fn owner(&self, scoping: &Scoping, scope_id: ScopeId) -> Option<SymbolId> {
+        scoping
+            .scope_ancestors(scope_id)
+            .find_map(|scope_id| self.function_by_scope.get(scope_id.index()).copied().flatten())
+    }
+
+    /// Rebuild current reachability and report whether this run published any
+    /// newly dead function, requiring another peephole pass.
+    fn analyze(&mut self, scoping: &Scoping, implicitly_observable: &BitSet<'_>) -> bool {
+        if scoping.root_scope_flags().contains_direct_eval() {
+            // The minifier may remove direct eval but must never create one,
+            // so a graph that already published dead functions cannot get
+            // here.
+            debug_assert!(self.dead.is_empty(), "direct eval formed after liveness was published");
+            // In release builds, stop later passes from consuming more
+            // invalidated deadness. Declarations already removed cannot be
+            // restored if a transform violated the direct-eval contract.
+            self.dead.clear();
+            return false;
+        }
+
+        self.scratch.reset();
+
+        // Phase 1: classify every current reference to a candidate. Seed
+        // unconditional liveness, store candidate-owned dependencies, and
+        // identify functions that no longer need graph reachability.
+        for bit in self.candidates.ones() {
+            let target = SymbolId::from_usize(bit);
+            // Implicitly observable candidates (e.g. exported functions) are
+            // unconditionally live regardless of their references.
+            if implicitly_observable.contains(bit) {
+                self.scratch.mark_live(target);
+            }
+            let mut has_registered_function_owner = false;
+            for &reference_id in scoping.get_resolved_reference_ids(target) {
+                let reference = scoping.get_reference(reference_id);
+                let Some(owner) = self.owner(scoping, reference.scope_id()) else {
+                    self.scratch.mark_live(target);
+                    continue;
+                };
+
+                has_registered_function_owner = true;
+                if implicitly_observable.contains(owner.index()) {
+                    // A reference owned by a permanently live function keeps
+                    // its target live unconditionally. Avoid storing and
+                    // sorting the common implicitly observable owner case; the
+                    // result is the same.
+                    self.scratch.mark_live(target);
+                    continue;
+                }
+                if self.candidates.contains(owner.index()) {
+                    self.scratch.owned_references.push((owner, target));
+                } else if !scoping.symbol_is_unused(owner) {
+                    // A registered non-candidate owner keeps the target live
+                    // only while its body can still execute.
+                    self.scratch.mark_live(target);
+                }
+            }
+            if !has_registered_function_owner && !self.dead.contains(bit) {
+                self.scratch.candidates_to_untrack.set_bit(bit);
+            }
+        }
+
+        // Phase 2: untrack owners that no longer need graph reachability.
+        // `owned_references` was collected before `candidates_to_untrack` was
+        // known. Stored owners are not implicitly observable, so preserve
+        // their targets when ordinary reference counts still make the owner
+        // executable.
+        for index in 0..self.scratch.owned_references.len() {
+            let (owner, target) = self.scratch.owned_references[index];
+            let owner_leaves_graph = self.scratch.candidates_to_untrack.contains(owner.index());
+            let owner_stays_live_by_count = !scoping.symbol_is_unused(owner);
+            if owner_leaves_graph && owner_stays_live_by_count {
+                self.scratch.mark_live(target);
+            }
+        }
+        // Future analyses treat these functions as registered non-candidate
+        // owners.
+        for bit in self.scratch.candidates_to_untrack.ones() {
+            self.candidates.unset_bit(bit);
+        }
+
+        #[cfg(debug_assertions)]
+        for bit in self.dead.ones() {
+            assert!(
+                self.candidates.contains(bit),
+                "dead function symbol {bit} was untracked; dead candidates must remain graph \
+                 candidates",
+            );
+        }
+
+        // Phase 3: propagate from unconditional live seeds through references
+        // owned by live candidates.
+        self.scratch.propagate_liveness(&self.candidates);
+
+        #[cfg(debug_assertions)]
+        for bit in self.dead.ones() {
+            assert!(
+                !self.scratch.live.contains(bit),
+                "function liveness resurrected dead symbol {bit}; transforms must not create a \
+                 new path to a previously unreachable binding",
+            );
+        }
+
+        // Phase 4: publish newly unreachable candidates. Existing dead bits
+        // remain as tombstones for the transform contract checks above.
+        let mut published_new_dead = false;
+        for bit in self.candidates.ones() {
+            if !self.scratch.live.contains(bit) && !self.dead.contains(bit) {
+                self.dead.set_bit(bit);
+                published_new_dead = true;
+            }
+        }
+        published_new_dead
+    }
+}
+
+struct GraphScratch<'a> {
+    /// All functions proven live during the current analysis.
+    live: BitSet<'a>,
+    /// Live functions whose owned references have not been propagated yet.
+    live_worklist: ArenaVec<'a, SymbolId>,
+    /// `(owner, target)` for each reference to `target` inside `owner`'s body.
+    owned_references: ArenaVec<'a, (SymbolId, SymbolId)>,
+    /// Candidates that no longer need graph reachability and will stop being
+    /// tracked after reference collection.
+    candidates_to_untrack: BitSet<'a>,
+}
+
+impl<'a> GraphScratch<'a> {
+    fn new(symbols_len: usize, allocator: &'a Allocator) -> Self {
+        Self {
+            live: BitSet::new_in(symbols_len, allocator),
+            live_worklist: ArenaVec::new_in(&allocator),
+            owned_references: ArenaVec::new_in(&allocator),
+            candidates_to_untrack: BitSet::new_in(symbols_len, allocator),
+        }
+    }
+
+    fn reset(&mut self) {
+        self.live.clear();
+        self.live_worklist.clear();
+        self.owned_references.clear();
+        self.candidates_to_untrack.clear();
+    }
+
+    fn mark_live(&mut self, symbol_id: SymbolId) {
+        let bit = symbol_id.index();
+        if !self.live.contains(bit) {
+            self.live.set_bit(bit);
+            self.live_worklist.push(symbol_id);
+        }
+    }
+
+    /// Marks the direct targets referenced by `owner` as live.
+    /// Requires `owned_references` to be sorted by owner.
+    fn mark_targets_live(&mut self, owner: SymbolId) {
+        let mut index = self
+            .owned_references
+            .partition_point(|&(reference_owner, _)| reference_owner.index() < owner.index());
+        while let Some((reference_owner, target)) = self.owned_references.get(index).copied() {
+            if reference_owner != owner {
+                break;
+            }
+            self.mark_live(target);
+            index += 1;
+        }
+    }
+
+    fn propagate_liveness(&mut self, candidates: &BitSet<'_>) {
+        // References owned by functions no longer in the graph cannot
+        // propagate. Targets of count-live owners were seeded before this call.
+        self.owned_references.retain(|(owner, _)| candidates.contains(owner.index()));
+        // Group references by owner for `mark_targets_live`.
+        self.owned_references.sort_unstable_by_key(|&(owner, _)| owner.index());
+        while let Some(owner) = self.live_worklist.pop() {
+            if !candidates.contains(owner.index()) {
+                // The owner may have been seeded before it was untracked; its
+                // targets were already handled by graph-independent liveness.
+                continue;
+            }
+            self.mark_targets_live(owner);
+        }
+    }
+}
+
+/// Normalize hook: register a function declaration as a potential graph
+/// candidate.
+pub fn register_function(function: &Function<'_>, ctx: &mut TraverseCtx<'_>) {
+    if !function.is_declaration() {
+        return;
+    }
+    if ctx.state.options.unused == CompressOptionsUnused::Keep {
+        return;
+    }
+    let allocator = ctx.allocator();
+    let TraverseCtx { state, scoping, .. } = ctx;
+    if let Some(liveness) = &mut state.symbol_liveness {
+        liveness.register_function(function, state.source_type, scoping.scoping(), allocator);
+    }
+}
+
+/// Normalize hook: record resource bindings observed later by explicit
+/// resource management. Disposal reads the bound value through runtime state,
+/// not through a resolved identifier reference in the AST.
+pub fn register_using_declaration(
+    declaration: &VariableDeclaration<'_>,
+    ctx: &mut TraverseCtx<'_>,
+) {
+    if !declaration.kind.is_using() {
+        return;
+    }
+
+    let source_type = ctx.state.source_type;
+    let allocator = ctx.allocator();
+    let TraverseCtx { state, scoping, .. } = ctx;
+    let liveness = state
+        .symbol_liveness
+        .get_or_insert_with(|| SymbolLiveness::new(source_type, scoping.scoping(), allocator));
+    liveness.mark_bound_names(declaration);
+}
+
+/// Normalize hook: record runtime bindings exposed by a named export.
+pub fn register_named_export(declaration: &ExportNamedDeclaration<'_>, ctx: &mut TraverseCtx<'_>) {
+    let TraverseCtx { state, scoping, .. } = ctx;
+    let Some(liveness) = &mut state.symbol_liveness else { return };
+
+    if !declaration.export_kind.is_type()
+        && let Some(inner) = &declaration.declaration
+    {
+        liveness.mark_bound_names(inner);
+    }
+
+    if declaration.source.is_some() || declaration.export_kind.is_type() {
+        return;
+    }
+
+    for specifier in &declaration.specifiers {
+        if specifier.export_kind.is_type() {
+            continue;
+        }
+        let ModuleExportName::IdentifierReference(local) = &specifier.local else { continue };
+        let Some(reference_id) = local.reference_id.get() else { continue };
+        let reference = scoping.scoping().get_reference(reference_id);
+        if reference.flags().is_type_only() {
+            continue;
+        }
+        if let Some(symbol_id) = reference.symbol_id() {
+            liveness.mark_implicitly_observable(symbol_id);
+        }
+    }
+}
+
+/// Normalize hook: record the local binding of a named default function or
+/// class declaration. `export default identifier` is intentionally excluded:
+/// it exports the evaluated value, not subsequent writes to that local binding.
+pub fn register_default_export(
+    declaration: &ExportDefaultDeclaration<'_>,
+    ctx: &mut TraverseCtx<'_>,
+) {
+    let symbol_id = match &declaration.declaration {
+        ExportDefaultDeclarationKind::FunctionDeclaration(function) => {
+            function.id.as_ref().and_then(|id| id.symbol_id.get())
+        }
+        ExportDefaultDeclarationKind::ClassDeclaration(class) => {
+            class.id.as_ref().and_then(|id| id.symbol_id.get())
+        }
+        _ => None,
+    };
+    if let Some(symbol_id) = symbol_id
+        && let Some(liveness) = &mut ctx.state.symbol_liveness
+    {
+        liveness.mark_implicitly_observable(symbol_id);
+    }
+}
+
+/// Whether pruning this pass's dead references can change a graph input.
+///
+/// Reachability is immediately sensitive to resolved-reference-list changes of
+/// candidate target symbols. It also checks whether registered non-candidate
+/// owners are count-live. Removing the last reference to such an owner can only
+/// make the current result conservatively stale: direct eval disables the
+/// analysis, while implicitly observable owners take a separate branch. A
+/// later pass removes the count-dead owner; removing its body then drops
+/// candidate-target references and triggers recomputation. Fresh references
+/// cannot resurrect a published dead function, so additions alone need no
+/// recompute. Scope-only rewrites preserve the nearest function owner.
+pub fn dead_references_affect_analysis(ctx: &TraverseCtx<'_>) -> bool {
+    let Some(liveness) = &ctx.state.symbol_liveness else { return false };
+    let Some(graph) = &liveness.recursive_functions else { return false };
+    // The analysis is disabled while the root scope contains direct eval, so
+    // removed references cannot affect it. The flag may be stale if this pass
+    // dropped the last eval (flags refresh after this check), but that drop
+    // also sets `eval_dropped`, which forces the recompute anyway.
+    if ctx.scoping().root_scope_flags().contains_direct_eval() {
+        return false;
+    }
+    ctx.state.dirty.dead_refs.ones().any(|bit| {
+        ctx.scoping()
+            .get_reference(ReferenceId::from_usize(bit))
+            .symbol_id()
+            .is_some_and(|symbol_id| graph.candidates.contains(symbol_id.index()))
+    })
+}
+
+/// Assert that the completed pass removed every previously published dead
+/// declaration, then optionally analyze settled semantic references and
+/// publish newly dead functions. Called only by the end-of-pass sequence after
+/// scoping has been flushed.
+pub fn analyze<'a>(program: &Program<'a>, ctx: &mut TraverseCtx<'a>, recompute: bool) -> bool {
+    #[cfg(not(debug_assertions))]
+    let _ = program;
+
+    #[cfg(debug_assertions)]
+    if let Some(dead) = ctx.state.symbol_liveness.as_ref().and_then(SymbolLiveness::dead_functions)
+    {
+        debug_assert_dead_function_declarations_removed(program, ctx.scoping(), dead);
+    }
+
+    if !recompute {
+        return false;
+    }
+
+    let TraverseCtx { state, scoping, .. } = ctx;
+    state.symbol_liveness.as_mut().is_some_and(|liveness| liveness.analyze(scoping.scoping()))
+}
+
+/// Debug contract for previously published graph deadness: it is consumed only
+/// at function-declaration sites, and every such declaration must now be gone.
+#[cfg(debug_assertions)]
+fn debug_assert_dead_function_declarations_removed(
+    program: &Program<'_>,
+    scoping: &Scoping,
+    dead: &BitSet<'_>,
+) {
+    if dead.is_empty() {
+        return;
+    }
+    DeadFunctionSweep { scoping, dead }.visit_program(program);
+}
+
+#[cfg(debug_assertions)]
+struct DeadFunctionSweep<'s, 'd, 'a> {
+    scoping: &'s Scoping,
+    dead: &'d BitSet<'a>,
+}
+
+#[cfg(debug_assertions)]
+impl<'a> VisitJs<'a> for DeadFunctionSweep<'_, '_, '_> {
+    fn visit_function(&mut self, function: &Function<'a>, flags: oxc_syntax::scope::ScopeFlags) {
+        if function.is_declaration()
+            && let Some(symbol_id) = function.id.as_ref().and_then(|id| id.symbol_id.get())
+        {
+            assert!(
+                !self.dead.contains(symbol_id.index()),
+                "dead function `{}` survived the pass after its deadness was published",
+                self.scoping.symbol_name(symbol_id),
+            );
+        }
+        walk_function(self, function, flags);
+    }
+}
diff --git a/crates/oxc_minifier/src/symbol_value.rs b/crates/oxc_minifier/src/symbol_value.rs
index f2691ccb2..a20cde416 100644
--- a/crates/oxc_minifier/src/symbol_value.rs
+++ b/crates/oxc_minifier/src/symbol_value.rs
@@ -42,9 +42,6 @@ pub struct SymbolValue<'a> {
     /// resolve the value through `initialized_constant`.
     pub implicit_undefined: bool,
 
-    /// Symbol is exported.
-    pub exported: bool,
-
     pub read_references_count: u32,
     pub write_references_count: u32,
 
diff --git a/crates/oxc_minifier/src/traverse_context/ecma_context.rs b/crates/oxc_minifier/src/traverse_context/ecma_context.rs
index 292a6cfd0..cbddcd2ac 100644
--- a/crates/oxc_minifier/src/traverse_context/ecma_context.rs
+++ b/crates/oxc_minifier/src/traverse_context/ecma_context.rs
@@ -290,18 +290,6 @@ impl<'a> TraverseCtx<'a, MinifierState<'a>> {
         falsy_init: bool,
         init_absent: bool,
     ) {
-        let mut exported = false;
-        if self.scoping.current_scope_id() == self.scoping().root_scope_id() {
-            for ancestor in self.ancestors() {
-                if ancestor.is_export_named_declaration()
-                    || ancestor.is_export_all_declaration()
-                    || ancestor.is_export_default_declaration()
-                {
-                    exported = true;
-                }
-            }
-        }
-
         let mut read_references_count = 0;
         let mut write_references_count = 0;
         let mut member_write_target_read_count = 0;
@@ -344,7 +332,6 @@ impl<'a> TraverseCtx<'a, MinifierState<'a>> {
         let symbol_value = SymbolValue {
             initialized_constant,
             implicit_undefined,
-            exported,
             read_references_count,
             write_references_count,
             member_write_target_read_count,
PATCH
if command -v patch >/dev/null 2>&1; then
  patch -p1 --fuzz=0 <"$fix"
else
  git apply --whitespace=nowarn "$fix"
fi
rm -f "$fix"
