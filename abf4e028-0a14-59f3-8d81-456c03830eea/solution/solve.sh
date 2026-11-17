#!/bin/bash
set -euo pipefail
cd /app
fix=$(mktemp)
cat >"$fix" <<'PATCH'
diff --git a/crates/swc_atoms/src/lib.rs b/crates/swc_atoms/src/lib.rs
index fa8f36caff485fe42b50e3e9e829a80cf83bd17f..7a300e48ab8a6465b003931249b1b7620bf5e5a0 100644
--- a/crates/swc_atoms/src/lib.rs
+++ b/crates/swc_atoms/src/lib.rs
@@ -175,7 +175,9 @@ impl From<hstr::Atom> for Atom {
 impl From<Atom> for hstr::Wtf8Atom {
     #[inline(always)]
     fn from(s: Atom) -> Self {
-        hstr::Wtf8Atom::from(&*s)
+        // UTF-8 is valid WTF-8. Transfer the owned backing atom rather than
+        // looking up its text in the global store again.
+        hstr::Wtf8Atom::from(s.0)
     }
 }
 
diff --git a/crates/swc_atoms/src/wtf8_atom.rs b/crates/swc_atoms/src/wtf8_atom.rs
index ddd08f2e46433c38451174bf5c2882f94f08d6e8..1044f94a1838bb267249984d37b06a03d13deddf 100644
--- a/crates/swc_atoms/src/wtf8_atom.rs
+++ b/crates/swc_atoms/src/wtf8_atom.rs
@@ -200,7 +200,30 @@ impl shrink_to_fit::ShrinkToFit for Wtf8Atom {
 
 #[cfg(test)]
 mod tests {
+    use std::collections::HashSet;
+
     use super::*;
+    use crate::AtomStore;
+
+    #[test]
+    fn owned_utf8_conversion_preserves_value_and_hash_across_stores() {
+        for text in ["inline", "A dynamically stored UTF-8 identifier: 世界"] {
+            let converted = {
+                let mut store = AtomStore::default();
+                Wtf8Atom::from(store.atom(text))
+            };
+            let mut other_store = AtomStore::default();
+            let equivalent = Wtf8Atom::from(other_store.atom(text));
+
+            assert_eq!(converted.as_str(), Some(text));
+            assert_eq!(converted, equivalent);
+            let values = HashSet::from([converted.clone()]);
+            assert!(values.contains(&equivalent));
+
+            let round_trip = converted.try_into_atom().expect("UTF-8 must remain valid");
+            assert_eq!(round_trip, Atom::from(text));
+        }
+    }
 
     #[test]
     fn to_atom_lossy_returns_borrowed_for_utf8() {
diff --git a/crates/swc_ecma_transforms_base/src/resolver/mod.rs b/crates/swc_ecma_transforms_base/src/resolver/mod.rs
index df704bc847ecbe6936c2b1ad32ec450976a0911e..19ab9b86bae1f5d49a4324c3538cab771ae8cf3b 100644
--- a/crates/swc_ecma_transforms_base/src/resolver/mod.rs
+++ b/crates/swc_ecma_transforms_base/src/resolver/mod.rs
@@ -1,8 +1,12 @@
+use std::cell::Cell;
+
 use rustc_hash::{FxHashMap, FxHashSet};
 use swc_atoms::Atom;
 use swc_common::{Mark, SyntaxContext};
 use swc_ecma_ast::*;
-use swc_ecma_utils::{find_pat_ids, stack_size::maybe_grow_default};
+use swc_ecma_utils::{
+    find_pat_ids, for_each_ts_fn_param_binding_ident, stack_size::maybe_grow_default,
+};
 use swc_ecma_visit::{
     noop_visit_mut_type, visit_mut_obj_and_computed, visit_mut_pass, VisitMut, VisitMutWith,
 };
@@ -13,6 +17,8 @@ use crate::scope::{DeclKind, IdentType, ScopeKind};
 #[cfg(test)]
 mod tests;
 
+mod typescript;
+
 const LOG: bool = false && cfg!(debug_assertions);
 
 /// See [Ident] for know how does swc manages identifiers.
@@ -138,7 +144,7 @@ pub fn resolver(
         "Marker provided to resolver should not be the root mark"
     );
 
-    let _ = SyntaxContext::empty().apply_mark(unresolved_mark);
+    let unresolved_ctxt = SyntaxContext::empty().apply_mark(unresolved_mark);
     let _ = SyntaxContext::empty().apply_mark(top_level_mark);
 
     visit_mut_pass(Resolver {
@@ -147,8 +153,12 @@ pub fn resolver(
         in_type: false,
         is_module: false,
         in_ts_module: false,
+        in_erased_type: false,
+        namespace_owner: None,
+        unresolved_ctxt,
         decl_kind: DeclKind::Lexical,
         strict_mode: false,
+        namespace_state: Default::default(),
         config: InnerConfig {
             handle_types: typescript,
             unresolved_mark,
@@ -168,6 +178,10 @@ struct Scope<'a> {
     /// [Mark] of the current scope.
     mark: Mark,
 
+    /// Materialize the scope's identity once, without assigning contexts to
+    /// empty scopes or changing the lexical walk's context creation order.
+    ctxt: Cell<SyntaxContext>,
+
     /// All declarations in the scope
     declared_symbols: FxHashMap<Atom, DeclKind>,
 
@@ -181,11 +195,27 @@ impl<'a> Scope<'a> {
             parent,
             kind,
             mark,
+            ctxt: Cell::default(),
             declared_symbols: Default::default(),
             declared_types: Default::default(),
         }
     }
 
+    fn ctxt(&self) -> SyntaxContext {
+        let ctxt = self.ctxt.get();
+        if ctxt != SyntaxContext::empty() || self.mark == Mark::root() {
+            return ctxt;
+        }
+        let ctxt = SyntaxContext::empty().apply_mark(self.mark);
+        self.ctxt.set(ctxt);
+        ctxt
+    }
+
+    fn set_mark(&mut self, mark: Mark) {
+        self.mark = mark;
+        self.ctxt.set(SyntaxContext::empty());
+    }
+
     fn is_declared(&self, symbol: &Atom) -> Option<&DeclKind> {
         self.declared_symbols
             .get(symbol)
@@ -204,8 +234,15 @@ struct Resolver<'a> {
     in_type: bool,
     is_module: bool,
     in_ts_module: bool,
+    in_erased_type: bool,
+    namespace_owner: Option<typescript::NamespaceScopeId>,
+    unresolved_ctxt: SyntaxContext,
     decl_kind: DeclKind,
     strict_mode: bool,
+    // Lexical fallback identities are recorded while parent scopes still
+    // exist. The later TS member pass can reject a known type-only alias
+    // without reconstructing lexical scopes or looking up names again.
+    namespace_state: typescript::NamespaceLookupStateRef<'a>,
 
     config: InnerConfig,
 }
@@ -217,6 +254,13 @@ struct InnerConfig {
     top_level_mark: Mark,
 }
 
+/// A found lexical declaration can intentionally resolve to the global value
+/// context for the non-configurable built-ins in scripts.
+enum ReferenceScope<'a> {
+    Declared(&'a Scope<'a>),
+    Unresolved,
+}
+
 #[allow(clippy::needless_lifetimes)]
 impl<'a> Resolver<'a> {
     #[cfg(test)]
@@ -227,9 +271,13 @@ impl<'a> Resolver<'a> {
             in_type: false,
             is_module: false,
             in_ts_module: false,
+            in_erased_type: false,
+            namespace_owner: None,
+            unresolved_ctxt: SyntaxContext::empty().apply_mark(config.unresolved_mark),
             config,
             decl_kind: DeclKind::Lexical,
             strict_mode: false,
+            namespace_state: Default::default(),
         }
     }
 
@@ -248,11 +296,60 @@ impl<'a> Resolver<'a> {
             in_type: self.in_type,
             is_module: self.is_module,
             in_ts_module: self.in_ts_module,
+            in_erased_type: self.in_erased_type,
+            namespace_owner: self.namespace_owner,
+            unresolved_ctxt: self.unresolved_ctxt,
             decl_kind: self.decl_kind,
             strict_mode: self.strict_mode,
+            namespace_state: typescript::NamespaceLookupStateRef::Borrowed(
+                self.namespace_state.get(),
+            ),
         };
 
         op(&mut child);
+
+        if let Some(owner) = child.namespace_owner {
+            if child.namespace_owner == self.namespace_owner
+                // Enum members deliberately share the global unresolved mark.
+                && child.current.mark != self.config.unresolved_mark
+                && (!child.current.declared_symbols.is_empty()
+                    || !child.current.declared_types.is_empty())
+            {
+                child
+                    .namespace_state
+                    .get()
+                    .scope(child.current.ctxt(), owner);
+            }
+        }
+    }
+
+    fn visit_ts_computed_key(&mut self, key: &mut Expr) {
+        // Computed names refer to values even in erased type syntax.
+        let in_type = std::mem::replace(&mut self.in_type, false);
+        key.visit_mut_with(self);
+        self.in_type = in_type;
+    }
+
+    fn visit_ts_signature_params(&mut self, params: &mut [TsFnParam]) {
+        // Constraints are resolved before parameters enter the value space.
+        // Predeclare every parameter so annotations can reference later ones.
+        for param in params.iter() {
+            for_each_ts_fn_param_binding_ident(param, |id| {
+                self.current
+                    .declared_symbols
+                    .insert(id.id.sym.clone(), DeclKind::Param);
+            });
+        }
+
+        let in_type = std::mem::replace(&mut self.in_type, false);
+        let ident_type = std::mem::replace(&mut self.ident_type, IdentType::Binding);
+        let decl_kind = std::mem::replace(&mut self.decl_kind, DeclKind::Param);
+        for param in params {
+            param.visit_mut_with(self);
+        }
+        self.decl_kind = decl_kind;
+        self.ident_type = ident_type;
+        self.in_type = in_type;
     }
 
     fn visit_mut_stmt_within_child_scope(&mut self, s: &mut Stmt) {
@@ -265,43 +362,42 @@ impl<'a> Resolver<'a> {
         });
     }
 
-    /// Returns a [Mark] for an identifier reference.
-    fn mark_for_ref(&self, sym: &Atom) -> Option<Mark> {
-        self.mark_for_ref_inner(sym, false)
+    /// Preserve the resolved scope so references reuse its existing identity.
+    fn scope_for_ref(&self, sym: &Atom) -> Option<ReferenceScope<'_>> {
+        self.scope_for_ref_inner(sym, false)
     }
 
-    fn mark_for_ref_inner(&self, sym: &Atom, stop_an_fn_scope: bool) -> Option<Mark> {
+    fn scope_for_ref_inner(
+        &self,
+        sym: &Atom,
+        stop_an_fn_scope: bool,
+    ) -> Option<ReferenceScope<'_>> {
         if self.config.handle_types && self.in_type {
-            let mut mark = self.current.mark;
             let mut scope = Some(&self.current);
 
             while let Some(cur) = scope {
                 // if cur.declared_types.contains(sym) ||
                 // cur.hoisted_symbols.borrow().contains(sym) {
                 if cur.declared_types.contains(sym) {
-                    if mark == Mark::root() {
+                    if cur.mark == Mark::root() {
                         break;
                     }
-                    return Some(mark);
+                    return Some(ReferenceScope::Declared(cur));
                 }
 
                 if cur.kind == ScopeKind::Fn && stop_an_fn_scope {
                     return None;
                 }
 
-                if let Some(parent) = &cur.parent {
-                    mark = parent.mark;
-                }
                 scope = cur.parent;
             }
         }
 
-        let mut mark = self.current.mark;
         let mut scope = Some(&self.current);
 
         while let Some(cur) = scope {
             if cur.declared_symbols.contains_key(sym) {
-                if mark == Mark::root() {
+                if cur.mark == Mark::root() {
                     return None;
                 }
 
@@ -309,11 +405,11 @@ impl<'a> Resolver<'a> {
                     // https://tc39.es/ecma262/multipage/global-object.html#sec-value-properties-of-the-global-object-infinity
                     // non configurable global value
                     "undefined" | "NaN" | "Infinity"
-                        if mark == self.config.top_level_mark && !self.is_module =>
+                        if cur.mark == self.config.top_level_mark && !self.is_module =>
                     {
-                        Some(self.config.unresolved_mark)
+                        Some(ReferenceScope::Unresolved)
                     }
-                    _ => Some(mark),
+                    _ => Some(ReferenceScope::Declared(cur)),
                 };
             }
 
@@ -321,9 +417,6 @@ impl<'a> Resolver<'a> {
                 return None;
             }
 
-            if let Some(parent) = &cur.parent {
-                mark = parent.mark;
-            }
             scope = cur.parent;
         }
 
@@ -350,11 +443,7 @@ impl<'a> Resolver<'a> {
             self.current.declared_symbols.insert(id.sym.clone(), kind);
         }
 
-        let mark = self.current.mark;
-
-        if mark != Mark::root() {
-            id.ctxt = id.ctxt.apply_mark(mark);
-        }
+        id.ctxt = self.current.ctxt();
     }
 
     fn mark_block(&mut self, ctxt: &mut SyntaxContext) {
@@ -362,11 +451,7 @@ impl<'a> Resolver<'a> {
             return;
         }
 
-        let mark = self.current.mark;
-
-        if mark != Mark::root() {
-            *ctxt = ctxt.apply_mark(mark)
-        }
+        *ctxt = self.current.ctxt();
     }
 
     fn try_resolving_as_type(&mut self, i: &mut Ident) {
@@ -472,12 +557,8 @@ impl VisitMut for Resolver<'_> {
 
     typed_ref!(visit_mut_ts_type_query, TsTypeQuery);
 
-    typed_ref!(visit_mut_ts_type_query_expr, TsTypeQueryExpr);
-
     typed_ref!(visit_mut_ts_type_operator, TsTypeOperator);
 
-    typed_ref_init!(visit_mut_ts_type, TsType);
-
     typed_ref_init!(visit_mut_ts_type_ann, TsTypeAnn);
 
     typed!(
@@ -489,8 +570,6 @@ impl VisitMut for Resolver<'_> {
 
     typed_ref!(visit_mut_ts_union_type, TsUnionType);
 
-    typed_ref!(visit_mut_ts_infer_type, TsInferType);
-
     typed_ref!(visit_mut_ts_tuple_type, TsTupleType);
 
     typed_ref!(visit_mut_ts_intersection_type, TsIntersectionType);
@@ -503,8 +582,6 @@ impl VisitMut for Resolver<'_> {
 
     typed!(visit_mut_ts_indexed_access_type, TsIndexedAccessType);
 
-    typed!(visit_mut_ts_index_signature, TsIndexSignature);
-
     typed!(visit_mut_ts_interface_body, TsInterfaceBody);
 
     typed!(visit_mut_ts_parenthesized_type, TsParenthesizedType);
@@ -519,14 +596,41 @@ impl VisitMut for Resolver<'_> {
 
     typed!(visit_mut_ts_type_predicate, TsTypePredicate);
 
-    typed_ref!(visit_mut_ts_this_type_or_ident, TsThisTypeOrIdent);
-
     visit_mut_obj_and_computed!();
 
     // TODO: How should I handle this?
     typed!(visit_mut_ts_namespace_export_decl, TsNamespaceExportDecl);
 
+    fn visit_mut_ts_infer_type(&mut self, node: &mut TsInferType) {
+        if self.config.handle_types {
+            // Inferred bindings do not yet have their own lexical scope.
+            // Keep their declaration-level owners in namespace completion
+            // instead of treating the surrounding scope as their owner.
+            self.namespace_state.get().require_type_scopes();
+            let in_type = std::mem::replace(&mut self.in_type, true);
+            let ident_type = self.ident_type;
+            node.visit_mut_children_with(self);
+            self.ident_type = ident_type;
+            self.in_type = in_type;
+        }
+    }
+
+    fn visit_mut_ts_type(&mut self, node: &mut TsType) {
+        if self.config.handle_types {
+            let in_type = std::mem::replace(&mut self.in_type, true);
+            let ident_type = std::mem::replace(&mut self.ident_type, IdentType::Ref);
+            let in_erased_type = std::mem::replace(&mut self.in_erased_type, true);
+            node.visit_mut_children_with(self);
+            self.in_erased_type = in_erased_type;
+            self.ident_type = ident_type;
+            self.in_type = in_type;
+        }
+    }
+
     fn visit_mut_arrow_expr(&mut self, e: &mut ArrowExpr) {
+        if self.in_erased_type {
+            self.namespace_state.get().require_type_scopes();
+        }
         self.with_child(ScopeKind::Fn, |child| {
             child.mark_block(&mut e.ctxt);
             e.type_params.visit_mut_with(child);
@@ -661,6 +765,9 @@ impl VisitMut for Resolver<'_> {
     }
 
     fn visit_mut_class_expr(&mut self, n: &mut ClassExpr) {
+        if self.in_erased_type {
+            self.namespace_state.get().require_type_scopes();
+        }
         // Create a child scope. The class name is only accessible within the class.
 
         n.class.super_class.visit_mut_with(self);
@@ -879,6 +986,9 @@ impl VisitMut for Resolver<'_> {
     }
 
     fn visit_mut_function(&mut self, f: &mut Function) {
+        if self.in_erased_type {
+            self.namespace_state.get().require_type_scopes();
+        }
         self.mark_block(&mut f.ctxt);
         f.type_params.visit_mut_with(self);
 
@@ -961,8 +1071,11 @@ impl VisitMut for Resolver<'_> {
                     return;
                 }
 
-                if let Some(mark) = self.mark_for_ref(sym) {
-                    let ctxt = ctxt.apply_mark(mark);
+                if let Some(scope) = self.scope_for_ref(sym) {
+                    let ctxt = match scope {
+                        ReferenceScope::Declared(scope) => scope.ctxt(),
+                        ReferenceScope::Unresolved => self.unresolved_ctxt,
+                    };
 
                     if cfg!(debug_assertions) && LOG {
                         #[cfg(debug_assertions)]
@@ -975,7 +1088,7 @@ impl VisitMut for Resolver<'_> {
                         debug!("\t -> Unresolved");
                     }
 
-                    let ctxt = ctxt.apply_mark(self.config.unresolved_mark);
+                    let ctxt = self.unresolved_ctxt;
 
                     if cfg!(debug_assertions) && LOG {
                         #[cfg(debug_assertions)]
@@ -1048,9 +1161,17 @@ impl VisitMut for Resolver<'_> {
     }
 
     fn visit_mut_module(&mut self, module: &mut Module) {
+        self.namespace_state.get().reset();
         self.strict_mode = true;
         self.is_module = true;
-        module.visit_mut_children_with(self)
+        module.visit_mut_children_with(self);
+        if self.namespace_state.get().needs_lookup() {
+            typescript::resolve(
+                module,
+                self.unresolved_ctxt,
+                self.namespace_state.get().take_facts(),
+            );
+        }
     }
 
     fn visit_mut_module_items(&mut self, stmts: &mut Vec<ModuleItem>) {
@@ -1080,6 +1201,10 @@ impl VisitMut for Resolver<'_> {
             return;
         }
 
+        if self.in_ts_module && !e.specifiers.is_empty() {
+            self.namespace_state.get().require_lookup();
+        }
+
         e.visit_mut_children_with(self);
     }
 
@@ -1134,12 +1259,20 @@ impl VisitMut for Resolver<'_> {
     }
 
     fn visit_mut_script(&mut self, script: &mut Script) {
+        self.namespace_state.get().reset();
         self.strict_mode = script
             .body
             .first()
             .map(|stmt| stmt.is_use_strict())
             .unwrap_or(false);
-        script.visit_mut_children_with(self)
+        script.visit_mut_children_with(self);
+        if self.namespace_state.get().needs_lookup() {
+            typescript::resolve(
+                script,
+                self.unresolved_ctxt,
+                self.namespace_state.get().take_facts(),
+            );
+        }
     }
 
     fn visit_mut_stmts(&mut self, stmts: &mut Vec<Stmt>) {
@@ -1206,7 +1339,7 @@ impl VisitMut for Resolver<'_> {
             child.in_type = true;
 
             n.type_params.visit_mut_with(child);
-            n.params.visit_mut_with(child);
+            child.visit_ts_signature_params(&mut n.params);
             n.type_ann.visit_mut_with(child);
         });
     }
@@ -1222,7 +1355,7 @@ impl VisitMut for Resolver<'_> {
 
             // order is important
             decl.type_params.visit_mut_with(child);
-            decl.params.visit_mut_with(child);
+            child.visit_ts_signature_params(&mut decl.params);
             decl.type_ann.visit_mut_with(child);
         });
     }
@@ -1236,15 +1369,12 @@ impl VisitMut for Resolver<'_> {
             child.in_type = true;
 
             ty.type_params.visit_mut_with(child);
-            ty.params.visit_mut_with(child);
+            child.visit_ts_signature_params(&mut ty.params);
             ty.type_ann.visit_mut_with(child);
         });
     }
 
     fn visit_mut_ts_enum_decl(&mut self, decl: &mut TsEnumDecl) {
-        if decl.declare && !self.config.handle_types {
-            return;
-        }
         self.modify(&mut decl.id, DeclKind::Lexical);
 
         self.with_child(ScopeKind::Block, |child| {
@@ -1262,9 +1392,9 @@ impl VisitMut for Resolver<'_> {
             //
             // This keeps references like `A`, `B`, and `b = a` in the unresolved
             // context instead of resolving them to the enum's lexical scope, so the
-            // TypeScript enum transform can rewrite them later using
-            // `semantic.enum_record`.
-            child.current.mark = self.config.unresolved_mark;
+            // TypeScript enum transform can interpret them later through the
+            // current enum's typed member index.
+            child.current.set_mark(self.config.unresolved_mark);
             // add the enum member names as declared symbols for this scope
             // Ex. `enum Foo { a, b = a }`
             let member_names = decl.members.iter().filter_map(|m| match &m.id {
@@ -1296,7 +1426,9 @@ impl VisitMut for Resolver<'_> {
         if self.config.handle_types {
             let old = self.in_type;
             self.in_type = true;
+            let in_erased_type = std::mem::replace(&mut self.in_erased_type, true);
             n.visit_mut_children_with(self);
+            self.in_erased_type = in_erased_type;
             self.in_type = old;
         }
     }
@@ -1310,21 +1442,56 @@ impl VisitMut for Resolver<'_> {
             child.in_type = true;
 
             ty.type_params.visit_mut_with(child);
-            ty.params.visit_mut_with(child);
+            child.visit_ts_signature_params(&mut ty.params);
             ty.type_ann.visit_mut_with(child);
         });
     }
 
     fn visit_mut_ts_getter_signature(&mut self, n: &mut TsGetterSignature) {
         if n.computed {
-            n.key.visit_mut_with(self);
+            self.visit_ts_computed_key(&mut n.key);
         }
 
         n.type_ann.visit_mut_with(self);
     }
 
+    fn visit_mut_ts_index_signature(&mut self, n: &mut TsIndexSignature) {
+        if !self.config.handle_types {
+            return;
+        }
+
+        self.with_child(ScopeKind::Block, |child| {
+            child.visit_ts_signature_params(&mut n.params);
+            n.type_ann.visit_mut_with(child);
+        });
+    }
+
     fn visit_mut_ts_import_equals_decl(&mut self, n: &mut TsImportEqualsDecl) {
         self.modify(&mut n.id, DeclKind::Lexical);
+        self.namespace_state.get().alias();
+
+        let mut scope = self.current.parent;
+        let mut fallback = self.config.unresolved_mark;
+        while let Some(parent) = scope {
+            if parent.declared_symbols.contains_key(&n.id.sym) {
+                fallback = parent.mark;
+                break;
+            }
+            scope = parent.parent;
+        }
+        if fallback == self.config.top_level_mark
+            && !self.is_module
+            && matches!(&*n.id.sym, "undefined" | "NaN" | "Infinity")
+        {
+            fallback = self.config.unresolved_mark;
+        }
+        // Most aliases have no outer value. Their default unresolved fallback
+        // is implicit; only custom lexical targets need an owned ID record.
+        if fallback != self.config.unresolved_mark {
+            self.namespace_state
+                .get()
+                .alias_fallback(n.id.to_id(), SyntaxContext::empty().apply_mark(fallback));
+        }
 
         n.module_ref.visit_mut_with(self);
     }
@@ -1355,6 +1522,7 @@ impl VisitMut for Resolver<'_> {
 
         self.with_child(ScopeKind::Fn, |child| {
             child.in_type = true;
+            child.in_erased_type = true;
 
             n.type_params.visit_mut_with(child);
             n.extends.visit_mut_with(child);
@@ -1384,47 +1552,51 @@ impl VisitMut for Resolver<'_> {
             return;
         }
 
+        if n.computed {
+            self.visit_ts_computed_key(&mut n.key);
+        }
+
         self.with_child(ScopeKind::Fn, |child| {
             child.in_type = true;
 
             n.type_params.visit_mut_with(child);
-            if n.computed {
-                n.key.visit_mut_with(child);
-            }
-            n.params.visit_mut_with(child);
+            child.visit_ts_signature_params(&mut n.params);
             n.type_ann.visit_mut_with(child);
         });
     }
 
     fn visit_mut_ts_module_decl(&mut self, decl: &mut TsModuleDecl) {
-        if decl.declare && !self.config.handle_types {
-            return;
-        }
-
-        match &mut decl.id {
+        let owner = match &mut decl.id {
             TsModuleName::Ident(i) => {
                 self.modify(i, DeclKind::Lexical);
+                let owner = self.namespace_state.get().namespace(i);
+                (!decl.global).then_some(owner)
+            }
+            TsModuleName::Str(_) => {
+                self.namespace_state.get().require_lookup();
+                None
             }
-            TsModuleName::Str(_) => {}
             #[cfg(swc_ast_unknown)]
-            _ => {}
-        }
+            _ => None,
+        };
 
         self.with_child(ScopeKind::Block, |child| {
             child.in_ts_module = true;
+            child.namespace_owner = owner.or(child.namespace_owner);
 
             decl.body.visit_mut_children_with(child);
         });
     }
 
     fn visit_mut_ts_namespace_decl(&mut self, n: &mut TsNamespaceDecl) {
-        if n.declare && !self.config.handle_types {
-            return;
-        }
-
         self.modify(&mut n.id, DeclKind::Lexical);
+        let owner = self.namespace_state.get().namespace(&n.id);
 
-        n.body.visit_mut_with(self);
+        self.with_child(ScopeKind::Block, |child| {
+            child.in_ts_module = true;
+            child.namespace_owner = Some(owner);
+            n.body.visit_mut_with(child);
+        });
     }
 
     fn visit_mut_ts_param_prop_param(&mut self, n: &mut TsParamPropParam) {
@@ -1438,7 +1610,7 @@ impl VisitMut for Resolver<'_> {
         }
 
         if n.computed {
-            n.key.visit_mut_with(self);
+            self.visit_ts_computed_key(&mut n.key);
         }
 
         self.with_child(ScopeKind::Fn, |child| {
@@ -1463,11 +1635,44 @@ impl VisitMut for Resolver<'_> {
     }
 
     fn visit_mut_ts_setter_signature(&mut self, n: &mut TsSetterSignature) {
+        if !self.config.handle_types {
+            return;
+        }
+
         if n.computed {
-            n.key.visit_mut_with(self);
+            self.visit_ts_computed_key(&mut n.key);
+        }
+
+        self.with_child(ScopeKind::Fn, |child| {
+            child.visit_ts_signature_params(std::slice::from_mut(&mut n.param));
+        });
+    }
+
+    fn visit_mut_ts_this_type_or_ident(&mut self, n: &mut TsThisTypeOrIdent) {
+        if !self.config.handle_types {
+            return;
         }
 
-        n.param.visit_mut_with(self);
+        // Predicate names refer to value parameters, not type declarations.
+        let in_type = std::mem::replace(&mut self.in_type, false);
+        let ident_type = std::mem::replace(&mut self.ident_type, IdentType::Ref);
+        n.visit_mut_children_with(self);
+        self.ident_type = ident_type;
+        self.in_type = in_type;
+    }
+
+    fn visit_mut_ts_type_query_expr(&mut self, n: &mut TsTypeQueryExpr) {
+        if !self.config.handle_types {
+            return;
+        }
+
+        // A type query's entity is a value reference; type arguments are
+        // resolved separately in the type space.
+        let in_type = std::mem::replace(&mut self.in_type, false);
+        let ident_type = std::mem::replace(&mut self.ident_type, IdentType::Ref);
+        n.visit_mut_children_with(self);
+        self.ident_type = ident_type;
+        self.in_type = in_type;
     }
 
     fn visit_mut_ts_tuple_element(&mut self, e: &mut TsTupleElement) {
@@ -1582,7 +1787,7 @@ impl Hoister<'_, '_> {
     fn add_pat_id(&mut self, id: &mut BindingIdent) {
         if self.in_catch_body {
             // If we have a binding, it's different variable.
-            if self.resolver.mark_for_ref_inner(&id.sym, true).is_some()
+            if self.resolver.scope_for_ref_inner(&id.sym, true).is_some()
                 && self.catch_param_decls.contains(&id.sym)
             {
                 return;
@@ -1713,51 +1918,42 @@ impl VisitMut for Hoister<'_, '_> {
     fn visit_mut_decl(&mut self, decl: &mut Decl) {
         decl.visit_mut_children_with(self);
 
-        if self.resolver.config.handle_types {
-            match decl {
-                Decl::TsInterface(i) => {
-                    if self.in_block {
-                        return;
-                    }
-
-                    let old_in_type = self.resolver.in_type;
-                    self.resolver.in_type = true;
-                    self.resolver.modify(&mut i.id, DeclKind::Type);
-                    self.resolver.in_type = old_in_type;
+        match decl {
+            Decl::TsInterface(i) if self.resolver.config.handle_types => {
+                if self.in_block {
+                    return;
                 }
 
-                Decl::TsTypeAlias(a) => {
-                    let old_in_type = self.resolver.in_type;
-                    self.resolver.in_type = true;
-                    self.resolver.modify(&mut a.id, DeclKind::Type);
-                    self.resolver.in_type = old_in_type;
-                }
+                let old_in_type = self.resolver.in_type;
+                self.resolver.in_type = true;
+                self.resolver.modify(&mut i.id, DeclKind::Type);
+                self.resolver.in_type = old_in_type;
+            }
 
-                Decl::TsEnum(e) if !self.in_block => {
-                    let old_in_type = self.resolver.in_type;
-                    self.resolver.in_type = false;
-                    self.resolver.modify(&mut e.id, DeclKind::Lexical);
-                    self.resolver.in_type = old_in_type;
-                }
+            Decl::TsTypeAlias(a) if self.resolver.config.handle_types => {
+                let old_in_type = self.resolver.in_type;
+                self.resolver.in_type = true;
+                self.resolver.modify(&mut a.id, DeclKind::Type);
+                self.resolver.in_type = old_in_type;
+            }
 
-                Decl::TsModule(v)
-                    if matches!(
-                        &**v,
-                        TsModuleDecl {
-                            global: false,
-                            id: TsModuleName::Ident(_),
-                            ..
-                        },
-                    ) && !self.in_block =>
-                {
-                    let old_in_type = self.resolver.in_type;
-                    self.resolver.in_type = false;
-                    let id = v.id.as_mut_ident().unwrap();
-                    self.resolver.modify(id, DeclKind::Lexical);
-                    self.resolver.in_type = old_in_type;
-                }
-                _ => {}
+            Decl::TsEnum(e) if !self.in_block => {
+                let old_in_type = self.resolver.in_type;
+                self.resolver.in_type = false;
+                self.resolver.modify(&mut e.id, DeclKind::Lexical);
+                self.resolver.in_type = old_in_type;
+            }
+
+            Decl::TsModule(namespace) if !self.in_block && !namespace.global => {
+                let TsModuleName::Ident(id) = &mut namespace.id else {
+                    return;
+                };
+                let old_in_type = self.resolver.in_type;
+                self.resolver.in_type = false;
+                self.resolver.modify(id, DeclKind::Lexical);
+                self.resolver.in_type = old_in_type;
             }
+            _ => {}
         }
     }
 
diff --git a/crates/swc_ecma_transforms_base/src/resolver/tests.rs b/crates/swc_ecma_transforms_base/src/resolver/tests.rs
index d32b9b91f67f71547e087e6c12a5f9740b55787b..1b934dd9fbd005c110866a76ffca1431d7a2d48b 100644
--- a/crates/swc_ecma_transforms_base/src/resolver/tests.rs
+++ b/crates/swc_ecma_transforms_base/src/resolver/tests.rs
@@ -95,7 +95,8 @@ fn test_mark_for() {
             .current
             .declared_symbols
             .insert(atom!("bar"), DeclKind::Var);
-        assert_eq!(folder3.mark_for_ref(&atom!("bar")), Some(mark3));
+        assert!(matches!(folder3.scope_for_ref(&atom!("bar")),
+            Some(ReferenceScope::Declared(scope)) if scope.mark == mark3));
 
         let mut folder4 = Resolver::new(
             Scope::new(ScopeKind::Block, mark4, Some(&folder3.current)),
@@ -110,8 +111,10 @@ fn test_mark_for() {
             .declared_symbols
             .insert(atom!("foo"), DeclKind::Var);
 
-        assert_eq!(folder4.mark_for_ref(&atom!("foo")), Some(mark4));
-        assert_eq!(folder4.mark_for_ref(&atom!("bar")), Some(mark3));
+        assert!(matches!(folder4.scope_for_ref(&atom!("foo")),
+            Some(ReferenceScope::Declared(scope)) if scope.mark == mark4));
+        assert!(matches!(folder4.scope_for_ref(&atom!("bar")),
+            Some(ReferenceScope::Declared(scope)) if scope.mark == mark3));
         Ok(())
     })
     .unwrap();
diff --git a/crates/swc_ecma_transforms_base/src/resolver/typescript.rs b/crates/swc_ecma_transforms_base/src/resolver/typescript.rs
new file mode 100644
index 0000000000000000000000000000000000000000..654d78844d60f1421e60df9d45ff0d36cb8ba0c9
--- /dev/null
+++ b/crates/swc_ecma_transforms_base/src/resolver/typescript.rs
@@ -0,0 +1,347 @@
+//! Complete namespace lookup after lexical declarations have their IDs.
+//!
+//! At each namespace boundary, declarations in the current body take priority,
+//! then the shared exported members, then the next enclosing environment. The
+//! original lexical result identifies where to stop; we do not reimplement
+//! lexical lookup or merge the IDs of separate emitted JS declarations.
+
+use std::borrow::Borrow;
+
+use rustc_hash::FxHashMap;
+use swc_common::SyntaxContext;
+use swc_ecma_ast::*;
+use swc_ecma_utils::{
+    stack_size::maybe_grow_default,
+    ts_bindings::{
+        TsBindingCollector, TsBindingObserver, TsBindings, TsContainerId, TsNamespaceBodyId,
+        TsReferenceSpace,
+    },
+};
+use swc_ecma_visit::{VisitMut, VisitMutWith, VisitWith};
+
+mod bindings;
+mod state;
+use bindings::BindingResolver;
+pub(super) use state::NamespaceLookupStateRef;
+pub(super) use swc_ecma_utils::ts_bindings::TsLexicalNamespaceId as NamespaceScopeId;
+
+pub(super) fn resolve<N>(
+    node: &mut N,
+    unresolved_ctxt: SyntaxContext,
+    facts: state::NamespaceLookupFacts,
+) where
+    N: VisitWith<TsBindingCollector<(), false>>
+        + VisitWith<TsBindingCollector<LexicalScopeObserver>>
+        + VisitMutWith<NamespaceResolver>,
+{
+    let bindings = if facts.collect_type_scopes {
+        TsBindings::collect_for_namespace(node, unresolved_ctxt)
+    } else {
+        TsBindings::collect_with_observer(node, LexicalScopeObserver)
+            .0
+            .with_lexical_scopes(facts.scopes)
+    }
+    .with_namespace_aliases();
+    // Complete alias roots before caching their meanings for value fallback.
+    // Select erased aliases once instead of resolving them at every value use.
+    let mut alias_fallbacks = FxHashMap::default();
+    for alias in bindings.aliases() {
+        if !bindings.alias_has_value(alias) {
+            let id = bindings.declaration(bindings.alias(alias).declaration);
+            let fallback = facts
+                .alias_fallbacks
+                .get(id)
+                .copied()
+                .unwrap_or(unresolved_ctxt);
+            alias_fallbacks.insert(id.clone(), fallback);
+        }
+    }
+    node.visit_mut_with(&mut NamespaceResolver {
+        bindings,
+        alias_fallbacks,
+        bodies: Vec::new(),
+        next_body: 0,
+        enum_container: None,
+        unresolved_ctxt,
+        space: TsReferenceSpace::Value,
+    });
+}
+
+/// Lexical resolution already recorded erased scope owners. Declaration and
+/// runtime-expression collection keeps the ordinary non-type binding facts.
+#[derive(Default)]
+pub(super) struct LexicalScopeObserver;
+
+impl TsBindingObserver for LexicalScopeObserver {
+    type DeclarationState = ();
+    type NamespaceState = ();
+
+    const TYPE_SCOPES: bool = false;
+
+    fn enter_decl(&mut self, _: &Decl) {}
+
+    fn leave_decl(&mut self, _: ()) {}
+
+    fn enter_namespace(&mut self, _: &Id) {}
+
+    fn leave_namespace(&mut self, _: ()) {}
+}
+
+pub(super) struct NamespaceResolver {
+    bindings: TsBindings,
+    alias_fallbacks: FxHashMap<Id, SyntaxContext>,
+    bodies: Vec<TsNamespaceBodyId>,
+    next_body: usize,
+    enum_container: Option<TsContainerId>,
+    unresolved_ctxt: SyntaxContext,
+    space: TsReferenceSpace,
+}
+
+impl NamespaceResolver {
+    fn computed_key(&mut self, key: &mut Expr) {
+        // Signature keys look up values, but are erased together with the type.
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::TypeQuery);
+        key.visit_mut_with(self);
+        self.space = previous;
+    }
+
+    fn namespace(&mut self, body: &mut TsNamespaceBody) {
+        let current = self
+            .bindings
+            .namespace_body(self.next_body)
+            .expect("namespace lookup must walk the collected declaration sequence");
+        self.next_body += 1;
+        self.bodies.push(current);
+        body.visit_mut_with(self);
+        self.bodies.pop();
+    }
+}
+
+impl VisitMut for NamespaceResolver {
+    fn visit_mut_expr(&mut self, node: &mut Expr) {
+        maybe_grow_default(|| node.visit_mut_children_with(self));
+    }
+
+    fn visit_mut_var_declarator(&mut self, node: &mut VarDeclarator) {
+        node.name.visit_mut_with(&mut BindingResolver(self));
+        node.init.visit_mut_with(self);
+    }
+
+    fn visit_mut_param(&mut self, node: &mut Param) {
+        node.decorators.visit_mut_with(self);
+        node.pat.visit_mut_with(&mut BindingResolver(self));
+    }
+
+    fn visit_mut_ts_param_prop(&mut self, node: &mut TsParamProp) {
+        node.decorators.visit_mut_with(self);
+        node.param.visit_mut_with(&mut BindingResolver(self));
+    }
+
+    fn visit_mut_catch_clause(&mut self, node: &mut CatchClause) {
+        node.param.visit_mut_with(&mut BindingResolver(self));
+        node.body.visit_mut_with(self);
+    }
+
+    fn visit_mut_arrow_expr(&mut self, node: &mut ArrowExpr) {
+        node.params.visit_mut_with(&mut BindingResolver(self));
+        node.body.visit_mut_with(self);
+        node.type_params.visit_mut_with(self);
+        node.return_type.visit_mut_with(self);
+    }
+
+    fn visit_mut_fn_decl(&mut self, node: &mut FnDecl) {
+        node.function.visit_mut_with(self);
+    }
+
+    fn visit_mut_fn_expr(&mut self, node: &mut FnExpr) {
+        node.function.visit_mut_with(self);
+    }
+
+    fn visit_mut_class_decl(&mut self, node: &mut ClassDecl) {
+        node.class.visit_mut_with(self);
+    }
+
+    fn visit_mut_class_expr(&mut self, node: &mut ClassExpr) {
+        node.class.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_interface_decl(&mut self, node: &mut TsInterfaceDecl) {
+        node.type_params.visit_mut_with(self);
+        node.extends.visit_mut_with(self);
+        node.body.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_type_alias_decl(&mut self, node: &mut TsTypeAliasDecl) {
+        node.type_params.visit_mut_with(self);
+        node.type_ann.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_type_param(&mut self, node: &mut TsTypeParam) {
+        node.constraint.visit_mut_with(self);
+        node.default.visit_mut_with(self);
+    }
+
+    fn visit_mut_computed_prop_name(&mut self, node: &mut ComputedPropName) {
+        if self.space == TsReferenceSpace::Any {
+            // Signature parameter bindings accept either meaning. Their keys
+            // instead require value lookup throughout the erased expression.
+            self.computed_key(&mut node.expr);
+        } else {
+            node.visit_mut_children_with(self);
+        }
+    }
+
+    fn visit_mut_ident(&mut self, node: &mut Ident) {
+        if node.ctxt == SyntaxContext::empty() {
+            return;
+        }
+
+        if self.space == TsReferenceSpace::Value && !self.alias_fallbacks.is_empty() {
+            while let Some(fallback) = self.alias_fallbacks.get(&node.to_id()) {
+                node.ctxt = *fallback;
+            }
+        }
+        if self.bodies.is_empty() {
+            return;
+        }
+
+        // The lexical resolver reserves its unresolved context for bare enum
+        // members. Keep that representation confined to the current enum;
+        // exported namespace names must not override a nearer enum member.
+        if node.ctxt == self.unresolved_ctxt {
+            if let Some(container) = self.enum_container {
+                if self
+                    .bindings
+                    .named_member(container, node.sym.borrow())
+                    .is_some_and(|member| self.bindings.member(member).is_enum_member())
+                {
+                    return;
+                }
+            }
+        }
+
+        if let Some(target) =
+            self.bindings
+                .ident_namespace_reference(node, &self.bodies, self.space)
+        {
+            node.ctxt = target.1;
+        }
+    }
+
+    fn visit_mut_ts_module_decl(&mut self, node: &mut TsModuleDecl) {
+        match (&node.id, &mut node.body) {
+            (TsModuleName::Ident(_), Some(body)) if !node.global => self.namespace(body),
+            _ => node.body.visit_mut_with(self),
+        }
+    }
+
+    fn visit_mut_ts_namespace_decl(&mut self, node: &mut TsNamespaceDecl) {
+        self.namespace(&mut node.body);
+    }
+
+    fn visit_mut_ts_enum_decl(&mut self, node: &mut TsEnumDecl) {
+        let previous = self.enum_container;
+        self.enum_container = self.bindings.container(&node.id.to_id());
+        for member in &mut node.members {
+            member.init.visit_mut_with(self);
+        }
+        self.enum_container = previous;
+    }
+
+    fn visit_mut_ts_type(&mut self, node: &mut TsType) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::Type);
+        node.visit_mut_children_with(self);
+        self.space = previous;
+    }
+
+    fn visit_mut_ts_type_query(&mut self, node: &mut TsTypeQuery) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::TypeQuery);
+        node.expr_name.visit_mut_with(self);
+        self.space = previous;
+        node.type_args.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_fn_param(&mut self, node: &mut TsFnParam) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::Any);
+        node.visit_mut_with(&mut BindingResolver(self));
+        self.space = previous;
+    }
+
+    fn visit_mut_ts_getter_signature(&mut self, node: &mut TsGetterSignature) {
+        if node.computed {
+            self.computed_key(&mut node.key);
+        }
+        node.type_ann.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_method_signature(&mut self, node: &mut TsMethodSignature) {
+        if node.computed {
+            self.computed_key(&mut node.key);
+        }
+        // Preserve the structural order used by the declaration collector.
+        node.params.visit_mut_with(self);
+        node.type_ann.visit_mut_with(self);
+        node.type_params.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_property_signature(&mut self, node: &mut TsPropertySignature) {
+        if node.computed {
+            self.computed_key(&mut node.key);
+        }
+        node.type_ann.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_setter_signature(&mut self, node: &mut TsSetterSignature) {
+        if node.computed {
+            self.computed_key(&mut node.key);
+        }
+        node.param.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_qualified_name(&mut self, node: &mut TsQualifiedName) {
+        let previous = self.space;
+        if matches!(self.space, TsReferenceSpace::Type | TsReferenceSpace::Any) {
+            self.space = TsReferenceSpace::Namespace;
+        }
+        node.left.visit_mut_with(self);
+        self.space = previous;
+    }
+
+    fn visit_mut_ts_expr_with_type_args(&mut self, node: &mut TsExprWithTypeArgs) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::Type);
+        node.visit_mut_children_with(self);
+        self.space = previous;
+    }
+
+    fn visit_mut_import_decl(&mut self, _: &mut ImportDecl) {}
+
+    fn visit_mut_ts_import_equals_decl(&mut self, node: &mut TsImportEqualsDecl) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::Any);
+        node.module_ref.visit_mut_with(self);
+        self.space = previous;
+    }
+
+    fn visit_mut_export_named_specifier(&mut self, node: &mut ExportNamedSpecifier) {
+        let previous = std::mem::replace(&mut self.space, TsReferenceSpace::Any);
+        node.orig.visit_mut_with(self);
+        self.space = previous;
+    }
+
+    fn visit_mut_labeled_stmt(&mut self, node: &mut LabeledStmt) {
+        node.body.visit_mut_with(self);
+    }
+
+    fn visit_mut_break_stmt(&mut self, _: &mut BreakStmt) {}
+
+    fn visit_mut_continue_stmt(&mut self, _: &mut ContinueStmt) {}
+
+    fn visit_mut_jsx_attr_name(&mut self, _: &mut JSXAttrName) {}
+
+    fn visit_mut_jsx_element_name(&mut self, node: &mut JSXElementName) {
+        if matches!(node, JSXElementName::Ident(id) if id.sym.starts_with(|c: char| c.is_ascii_lowercase()))
+        {
+            return;
+        }
+        node.visit_mut_children_with(self);
+    }
+}
diff --git a/crates/swc_ecma_transforms_base/src/resolver/typescript/bindings.rs b/crates/swc_ecma_transforms_base/src/resolver/typescript/bindings.rs
new file mode 100644
index 0000000000000000000000000000000000000000..8eb2331b0167406ce1901a22c63466f39da79023
--- /dev/null
+++ b/crates/swc_ecma_transforms_base/src/resolver/typescript/bindings.rs
@@ -0,0 +1,27 @@
+//! Binding names already have their physical declaration identities. Only
+//! expressions and annotations within a binding pattern need completion.
+
+use swc_ecma_ast::{BindingIdent, ComputedPropName, Expr, TsType};
+use swc_ecma_visit::{VisitMut, VisitMutWith};
+
+use super::NamespaceResolver;
+
+pub(super) struct BindingResolver<'a>(pub &'a mut NamespaceResolver);
+
+impl VisitMut for BindingResolver<'_> {
+    fn visit_mut_binding_ident(&mut self, node: &mut BindingIdent) {
+        node.type_ann.visit_mut_with(self.0);
+    }
+
+    fn visit_mut_expr(&mut self, node: &mut Expr) {
+        node.visit_mut_with(self.0);
+    }
+
+    fn visit_mut_ts_type(&mut self, node: &mut TsType) {
+        node.visit_mut_with(self.0);
+    }
+
+    fn visit_mut_computed_prop_name(&mut self, node: &mut ComputedPropName) {
+        node.visit_mut_with(self.0);
+    }
+}
diff --git a/crates/swc_ecma_transforms_base/src/resolver/typescript/state.rs b/crates/swc_ecma_transforms_base/src/resolver/typescript/state.rs
new file mode 100644
index 0000000000000000000000000000000000000000..ed6afa378b1cde1ff47ccace005996545b878b73
--- /dev/null
+++ b/crates/swc_ecma_transforms_base/src/resolver/typescript/state.rs
@@ -0,0 +1,100 @@
+//! Facts observed while the lexical scopes still exist. Child resolvers borrow
+//! this state so merged declarations are detected once for the whole input.
+
+use std::cell::{Cell, RefCell};
+
+use rustc_hash::FxHashMap;
+use swc_common::SyntaxContext;
+use swc_ecma_ast::{Id, Ident};
+use swc_ecma_utils::ts_bindings::{TsLexicalNamespaceId, TsLexicalScopes};
+
+#[derive(Default)]
+pub(in crate::resolver) struct NamespaceLookupState {
+    scopes: RefCell<TsLexicalScopes>,
+    collect_type_scopes: Cell<bool>,
+    required: Cell<bool>,
+    has_aliases: Cell<bool>,
+    alias_fallbacks: RefCell<FxHashMap<Id, SyntaxContext>>,
+}
+
+impl NamespaceLookupState {
+    pub(in crate::resolver) fn reset(&self) {
+        self.scopes.borrow_mut().clear();
+        self.collect_type_scopes.set(false);
+        self.required.set(false);
+        self.has_aliases.set(false);
+        self.alias_fallbacks.borrow_mut().clear();
+    }
+
+    pub(in crate::resolver) fn namespace(&self, id: &Ident) -> TsLexicalNamespaceId {
+        let (owner, inserted) = self.scopes.borrow_mut().namespace(id);
+        if !inserted {
+            self.required.set(true);
+        }
+        owner
+    }
+
+    pub(in crate::resolver) fn scope(&self, ctxt: SyntaxContext, owner: TsLexicalNamespaceId) {
+        self.scopes.borrow_mut().scope(ctxt, owner);
+    }
+
+    pub(in crate::resolver) fn require_type_scopes(&self) {
+        // Some erased constructs contribute owner-only bindings or nested
+        // declarations not covered by the lexical scope table.
+        self.collect_type_scopes.set(true);
+    }
+
+    pub(in crate::resolver) fn require_lookup(&self) {
+        self.required.set(true);
+    }
+
+    pub(in crate::resolver) fn alias(&self) {
+        self.has_aliases.set(true);
+    }
+
+    pub(in crate::resolver) fn alias_fallback(&self, id: Id, fallback: SyntaxContext) {
+        self.alias_fallbacks.borrow_mut().insert(id, fallback);
+    }
+
+    pub(in crate::resolver) fn needs_lookup(&self) -> bool {
+        // Within a single namespace body ordinary lexical resolution already
+        // found its declarations. Shared members, public export names and alias
+        // space fallbacks need the additional namespace lookup phase.
+        self.required.get() || (self.scopes.borrow().has_namespaces() && self.has_aliases.get())
+    }
+
+    pub(in crate::resolver) fn take_facts(&self) -> NamespaceLookupFacts {
+        NamespaceLookupFacts {
+            scopes: std::mem::take(&mut *self.scopes.borrow_mut()),
+            collect_type_scopes: self.collect_type_scopes.get(),
+            alias_fallbacks: std::mem::take(&mut *self.alias_fallbacks.borrow_mut()),
+        }
+    }
+}
+
+pub(in crate::resolver) struct NamespaceLookupFacts {
+    pub scopes: TsLexicalScopes,
+    pub collect_type_scopes: bool,
+    pub alias_fallbacks: FxHashMap<Id, SyntaxContext>,
+}
+
+/// The root owns the phase state; every nested lexical scope borrows it.
+pub(in crate::resolver) enum NamespaceLookupStateRef<'a> {
+    Owned(NamespaceLookupState),
+    Borrowed(&'a NamespaceLookupState),
+}
+
+impl Default for NamespaceLookupStateRef<'_> {
+    fn default() -> Self {
+        Self::Owned(NamespaceLookupState::default())
+    }
+}
+
+impl NamespaceLookupStateRef<'_> {
+    pub(in crate::resolver) fn get(&self) -> &NamespaceLookupState {
+        match self {
+            Self::Owned(state) => state,
+            Self::Borrowed(state) => state,
+        }
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/config.rs b/crates/swc_ecma_transforms_typescript/src/config.rs
index 708518d747f882156e6cad322445f5677fb99502..d53ec645bba55792156f4a26ccae62b7593ea879 100644
--- a/crates/swc_ecma_transforms_typescript/src/config.rs
+++ b/crates/swc_ecma_transforms_typescript/src/config.rs
@@ -27,9 +27,9 @@ pub struct Config {
     #[serde(default)]
     pub import_export_assign_config: TsImportExportAssignConfig,
 
-    /// Disables an optimization that inlines TS enum member values
-    /// within the same module that assumes the enum member values
-    /// are never modified.
+    /// Disables additional inlining of non-const enum member reads within
+    /// the same module. Enum initializers still follow TypeScript's constant
+    /// evaluation rules.
     ///
     /// Defaults to false.
     #[serde(default)]
diff --git a/crates/swc_ecma_transforms_typescript/src/lib.rs b/crates/swc_ecma_transforms_typescript/src/lib.rs
index 777a7d24ba194a92096888260b8fedb8ebd88ae3..ce9b274a33546cc15df8ea0d1ee24fb5163a14ad 100644
--- a/crates/swc_ecma_transforms_typescript/src/lib.rs
+++ b/crates/swc_ecma_transforms_typescript/src/lib.rs
@@ -62,6 +62,5 @@ mod retain;
 mod semantic;
 mod shared;
 mod transform;
-mod ts_enum;
 pub mod typescript;
 mod utils;
diff --git a/crates/swc_ecma_transforms_typescript/src/retain.rs b/crates/swc_ecma_transforms_typescript/src/retain.rs
index c9277ff2941eecd3fae94a178037c9d2452b7cc9..cd212c2298004041eaacd889246faba8361d3a51 100644
--- a/crates/swc_ecma_transforms_typescript/src/retain.rs
+++ b/crates/swc_ecma_transforms_typescript/src/retain.rs
@@ -1,14 +1,9 @@
 use swc_ecma_ast::*;
 
 /// Returns true if a module item should survive TS type-stripping.
-pub(crate) fn should_retain_module_item(module_item: &ModuleItem, in_namespace: bool) -> bool {
+pub(crate) fn should_retain_module_item(module_item: &ModuleItem) -> bool {
     match module_item {
         ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(export_decl)) => {
-            // Keep `export declare var` in namespace blocks for downstream transforms.
-            if in_namespace && export_decl.decl.is_var() {
-                return true;
-            }
-
             should_retain_decl(&export_decl.decl)
         }
         ModuleItem::Stmt(stmt) => should_retain_stmt(stmt),
@@ -48,14 +43,39 @@ impl IsConcrete for TsModuleDecl {
 
 impl IsConcrete for TsNamespaceBody {
     fn is_concrete(&self) -> bool {
-        match self {
-            Self::TsModuleBlock(ts_module_block) => {
-                ts_module_block.body.iter().any(|item| item.is_concrete())
-            }
-            Self::TsNamespaceDecl(ts_namespace_decl) => ts_namespace_decl.body.is_concrete(),
-            #[cfg(swc_ast_unknown)]
-            _ => panic!("unable to access unknown nodes"),
+        namespace_body_is_concrete(self, &mut IsConcrete::is_concrete)
+    }
+}
+
+/// Apply the concrete-body rules with a caller-provided nested namespace query.
+/// This deliberately differs from runtime instantiation: private aliases and
+/// ambient value declarations still make a body concrete.
+pub(crate) fn namespace_body_is_concrete(
+    body: &TsNamespaceBody,
+    namespace_is_concrete: &mut impl FnMut(&TsModuleDecl) -> bool,
+) -> bool {
+    match body {
+        TsNamespaceBody::TsModuleBlock(ts_module_block) => {
+            ts_module_block.body.iter().any(|item| match item {
+                ModuleItem::Stmt(Stmt::Decl(declaration))
+                | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+                    decl: declaration,
+                    ..
+                })) => match declaration {
+                    Decl::TsInterface(_) | Decl::TsTypeAlias(_) => false,
+                    Decl::TsModule(namespace) => namespace_is_concrete(namespace),
+                    // Value declarations instantiate the namespace even
+                    // when they are ambient or bodyless function signatures.
+                    _ => true,
+                },
+                _ => item.is_concrete(),
+            })
+        }
+        TsNamespaceBody::TsNamespaceDecl(ts_namespace_decl) => {
+            namespace_body_is_concrete(&ts_namespace_decl.body, namespace_is_concrete)
         }
+        #[cfg(swc_ast_unknown)]
+        _ => panic!("unable to access unknown nodes"),
     }
 }
 
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic.rs b/crates/swc_ecma_transforms_typescript/src/semantic.rs
index bce70d309539ad1e53b8678751ac3e7b8475cdbd..42579498b151ac8687f36268cd28d03d38fcda71 100644
--- a/crates/swc_ecma_transforms_typescript/src/semantic.rs
+++ b/crates/swc_ecma_transforms_typescript/src/semantic.rs
@@ -1,26 +1,42 @@
 use rustc_hash::{FxHashMap, FxHashSet};
-use swc_common::{Mark, Span, SyntaxContext};
+use swc_common::{Mark, SyntaxContext};
 use swc_ecma_ast::*;
-use swc_ecma_utils::{find_pat_ids, stack_size::maybe_grow_default};
+use swc_ecma_utils::{
+    for_each_binding_ident,
+    stack_size::maybe_grow_default,
+    ts_bindings::{TsAliasId, TsBindingObserver, TsBindings, TsContainerId},
+};
 use swc_ecma_visit::{noop_visit_type, Visit, VisitWith};
 
-use crate::{
-    retain::{should_retain_decl, IsConcrete},
-    shared::{enum_member_name, get_module_ident},
-    ts_enum::{EnumValueComputer, EvalCtx, TsEnumRecord, TsEnumRecordKey, TsEnumRecordValue},
-};
+use self::concrete::NamespaceConcreteness;
+
+mod availability;
+mod concrete;
+mod constants;
+mod enums;
+mod usage;
+
+pub(crate) use enums::{EnumBodyCursor, EnumDeclaration, EnumFacts, EnumValue};
 
 #[derive(Debug, Default)]
 pub(crate) struct SemanticInfo {
+    pub bindings: TsBindings,
+    pub enums: EnumFacts,
+    pub enum_inlining: EnumInlining,
+    pub live_aliases: FxHashSet<TsAliasId>,
+    pub runtime_containers: FxHashSet<TsContainerId>,
     pub usage: FxHashSet<Id>,
     pub id_type: FxHashSet<Id>,
     pub id_value: FxHashSet<Id>,
     pub exported_binding: FxHashMap<Id, Option<Id>>,
-    pub enum_record: TsEnumRecord,
-    pub ambient_enum_record: TsEnumRecord,
-    pub const_enum: FxHashSet<Id>,
-    pub namespace_import_equals_usage: FxHashSet<Span>,
-    pub const_vars: FxHashMap<Id, TsEnumRecordValue>,
+}
+
+/// Whether runtime reference analysis has already substituted enum reads.
+#[derive(Debug, Default, Clone, Copy)]
+pub(crate) enum EnumInlining {
+    #[default]
+    Emit,
+    Applied,
 }
 
 impl SemanticInfo {
@@ -39,113 +55,195 @@ impl SemanticInfo {
         self.id_type.contains(id) && !self.id_value.contains(id)
     }
 
-    #[inline]
-    pub fn has_namespace_import_equals_usage(&self, span: Span) -> bool {
-        self.namespace_import_equals_usage.contains(&span)
+    pub fn has_import_equals_usage(&self, id: &Id) -> bool {
+        self.bindings
+            .declaration_id(id)
+            .and_then(|declaration| self.bindings.declaration_alias(declaration))
+            .map_or_else(
+                || self.has_usage(id),
+                |alias| self.live_aliases.contains(&alias),
+            )
     }
 }
 
+/// Evaluate enum definitions before erasure, substitute eligible reads, and
+/// retain only the references that survive those substitutions.
 pub(crate) fn analyze_program(
-    program: &Program,
+    program: &mut Program,
     unresolved_mark: Mark,
     seed_usage: FxHashSet<Id>,
     flow_syntax: bool,
     ts_enum_is_mutable: bool,
+    verbatim_module_syntax: bool,
 ) -> SemanticInfo {
     let mut analyzer = SemanticAnalyzer {
-        unresolved_ctxt: SyntaxContext::empty().apply_mark(unresolved_mark),
         info: SemanticInfo {
-            usage: seed_usage,
             ..Default::default()
         },
-        import_chain: Default::default(),
-        namespace_block_stack: Default::default(),
         namespace_id: None,
         skip_transform_info: false,
-        flow_syntax,
-        ts_enum_is_mutable,
+        runtime_bindings_seen: false,
+        enum_seen: false,
+        literal_enums: enums::LiteralEnums::new(flow_syntax),
+        concrete: NamespaceConcreteness::default(),
     };
 
-    program.visit_with(&mut analyzer);
+    let bindings = if has_root_runtime_declaration(program, &mut analyzer.concrete) {
+        let (bindings, observed) = TsBindings::collect_with_observer(program, analyzer);
+        analyzer = observed;
+        Some(bindings)
+    } else {
+        // Ordinary inputs retain their existing reference-only walk. Runtime
+        // declarations found in nested statements use the complete fallback.
+        program.visit_with(&mut analyzer);
+        None
+    };
 
-    analyzer.finish()
+    // Only the combined declaration walk supplies ambient/export context to
+    // literal collection. Nested-declaration fallback keeps complete analysis.
+    let literal_enums = bindings.is_some().then_some(analyzer.literal_enums);
+    let runtime_bindings_seen = analyzer.runtime_bindings_seen;
+    let enum_seen = analyzer.enum_seen;
+    let mut info = analyzer.info;
+    if runtime_bindings_seen {
+        info.bindings = bindings.unwrap_or_else(|| TsBindings::collect(program));
+        let runtime_usage = if enum_seen {
+            info.bindings = info.bindings.with_runtime_queries();
+            info.enums = literal_enums
+                .and_then(|enums| enums.finish(&info.bindings))
+                .unwrap_or_else(|| {
+                    enums::analyze(
+                        program,
+                        &info.bindings,
+                        SyntaxContext::empty().apply_mark(unresolved_mark),
+                        flow_syntax,
+                    )
+                });
+            // Substitute while original declaration order and execution regions
+            // are intact. Later erasure/lowering never reconstructs use positions.
+            let runtime_usage = usage::analyze(
+                program,
+                &info.bindings,
+                &info.enums,
+                seed_usage,
+                ts_enum_is_mutable,
+                verbatim_module_syntax,
+                SyntaxContext::empty().apply_mark(unresolved_mark),
+            );
+            info.enum_inlining = EnumInlining::Applied;
+            runtime_usage
+        } else {
+            // Without enum substitution the first walk already collected the
+            // surviving references. Only alias dependencies remain to finish.
+            info.usage.extend(seed_usage);
+            usage::from_resolved_usage(
+                &info.bindings,
+                std::mem::take(&mut info.usage),
+                verbatim_module_syntax,
+            )
+        };
+        for &container in &runtime_usage.containers {
+            info.enums.require_runtime(container);
+        }
+        info.runtime_containers = runtime_usage.containers;
+        info.usage = runtime_usage.bindings;
+        info.live_aliases = runtime_usage.aliases;
+    } else {
+        info.usage.extend(seed_usage);
+    }
+    info
 }
 
+fn has_root_runtime_declaration(program: &Program, concrete: &mut NamespaceConcreteness) -> bool {
+    let mut declaration = |decl: &Decl| match decl {
+        Decl::TsEnum(_) => true,
+        Decl::TsModule(namespace) => concrete.is_concrete(namespace),
+        _ => false,
+    };
+    match program {
+        Program::Module(module) => module.body.iter().any(|item| match item {
+            ModuleItem::Stmt(Stmt::Decl(decl)) => declaration(decl),
+            ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(export)) => declaration(&export.decl),
+            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(_)) => true,
+            _ => false,
+        }),
+        Program::Script(script) => script.body.iter().any(|stmt| match stmt {
+            Stmt::Decl(decl) => declaration(decl),
+            _ => false,
+        }),
+        #[cfg(swc_ast_unknown)]
+        _ => false,
+    }
+}
+
+#[derive(Default)]
 struct SemanticAnalyzer {
-    unresolved_ctxt: SyntaxContext,
     info: SemanticInfo,
-    import_chain: FxHashMap<Id, Id>,
-    namespace_block_stack: Vec<NamespaceBlock>,
+    concrete: NamespaceConcreteness,
     namespace_id: Option<Id>,
     skip_transform_info: bool,
-    flow_syntax: bool,
-    ts_enum_is_mutable: bool,
+    runtime_bindings_seen: bool,
+    enum_seen: bool,
+    literal_enums: enums::LiteralEnums,
 }
 
-#[derive(Default)]
-struct NamespaceBlock {
-    usage: FxHashSet<Id>,
-    import_chain: FxHashMap<Id, Id>,
-    import_equals: Vec<NamespaceImportEquals>,
-}
-
-struct NamespaceImportEquals {
-    id: Id,
-    span: Span,
-    is_export: bool,
-    is_type_only: bool,
+struct DeclarationState {
+    skip_transform_info: bool,
 }
 
-impl NamespaceBlock {
-    fn analyze_import_chain(&mut self) {
-        if self.import_chain.is_empty() {
-            return;
-        }
-
-        let mut new_usage = FxHashSet::default();
-        for id in &self.usage {
-            let mut next = self.import_chain.remove(id);
-
-            while let Some(id) = next {
-                next = self.import_chain.remove(&id);
-                new_usage.insert(id);
-            }
-
-            if self.import_chain.is_empty() {
-                break;
-            }
+impl SemanticAnalyzer {
+    fn collect_module(&mut self, node: &Module) {
+        for item in &node.body {
+            self.collect_top_level_module_item(item);
         }
-
-        self.usage.extend(new_usage);
     }
-}
 
-impl SemanticAnalyzer {
-    fn finish(mut self) -> SemanticInfo {
-        self.analyze_import_chain();
-        self.info
+    fn collect_enum(&mut self, _: &TsEnumDecl) {
+        self.runtime_bindings_seen = true;
+        self.enum_seen = true;
+        self.info.usage.clear();
     }
 
-    fn analyze_import_chain(&mut self) {
-        if self.import_chain.is_empty() {
+    fn collect_export_decl(&mut self, node: &ExportDecl) {
+        // Namespace declaration exports already have shared member identities
+        // in TsBindings. Only root exports and unindexed export forms need this
+        // additional record; copying every member also duplicates its owner ID.
+        if self.skip_transform_info || self.namespace_id.is_some() {
             return;
         }
-
-        let mut new_usage = FxHashSet::default();
-        for id in &self.info.usage {
-            let mut next = self.import_chain.remove(id);
-
-            while let Some(id) = next {
-                next = self.import_chain.remove(&id);
-                new_usage.insert(id);
+        match &node.decl {
+            Decl::Var(var_decl) => {
+                for_each_binding_ident(&var_decl.decls, |binding| {
+                    self.info
+                        .exported_binding
+                        .insert(binding.id.to_id(), self.namespace_id.clone());
+                });
             }
-
-            if self.import_chain.is_empty() {
-                break;
+            Decl::TsEnum(ts_enum_decl) => {
+                self.info
+                    .exported_binding
+                    .insert(ts_enum_decl.id.to_id(), self.namespace_id.clone());
             }
+            Decl::TsModule(ts_module_decl) => {
+                if let TsModuleName::Ident(ident) = &ts_module_decl.id {
+                    self.info
+                        .exported_binding
+                        .insert(ident.to_id(), self.namespace_id.clone());
+                }
+            }
+            _ => {}
         }
+    }
 
-        self.info.usage.extend(new_usage);
+    fn collect_export_default_expr(&mut self, node: &ExportDefaultExpr) {
+        if self.skip_transform_info {
+            return;
+        }
+        if let Expr::Ident(ident) = &*node.expr {
+            self.info
+                .exported_binding
+                .insert(ident.to_id(), self.namespace_id.clone());
+        }
     }
 
     fn collect_top_level_module_item(&mut self, item: &ModuleItem) {
@@ -215,12 +313,14 @@ impl SemanticAnalyzer {
     fn collect_decl(&mut self, decl: &Decl) {
         match decl {
             Decl::Var(var_decl) => {
-                let ids: Vec<Id> = find_pat_ids(&var_decl.decls);
-                self.info.id_value.extend(ids);
+                for_each_binding_ident(&var_decl.decls, |binding| {
+                    self.info.id_value.insert(binding.id.to_id());
+                });
             }
             Decl::Using(using_decl) => {
-                let ids: Vec<Id> = find_pat_ids(&using_decl.decls);
-                self.info.id_value.extend(ids);
+                for_each_binding_ident(&using_decl.decls, |binding| {
+                    self.info.id_value.insert(binding.id.to_id());
+                });
             }
             Decl::Fn(fn_decl) => {
                 self.info.id_value.insert(fn_decl.ident.to_id());
@@ -229,6 +329,7 @@ impl SemanticAnalyzer {
                 self.info.id_value.insert(class_decl.ident.to_id());
             }
             Decl::TsEnum(ts_enum_decl) => {
+                self.enum_seen = true;
                 self.info.id_value.insert(ts_enum_decl.id.to_id());
             }
             Decl::TsModule(ts_module_decl) => {
@@ -240,7 +341,7 @@ impl SemanticAnalyzer {
                     return;
                 };
 
-                if ts_module_decl.is_concrete() {
+                if self.concrete.is_concrete(ts_module_decl) {
                     self.info.id_value.insert(ident.to_id());
                 } else {
                     self.info.id_type.insert(ident.to_id());
@@ -256,116 +357,85 @@ impl SemanticAnalyzer {
             _ => panic!("unable to access unknown nodes"),
         }
     }
+}
+
+impl TsBindingObserver for SemanticAnalyzer {
+    type DeclarationState = DeclarationState;
+    type NamespaceState = Option<Option<Id>>;
+
+    const RUNTIME: bool = true;
+
+    fn module(&mut self, node: &Module) {
+        self.collect_module(node);
+    }
 
-    #[allow(clippy::too_many_arguments)]
-    fn transform_ts_enum_member(
-        member: TsEnumMember,
-        enum_id: &Id,
-        default_init: &TsEnumRecordValue,
-        record: &TsEnumRecord,
-        ambient_record: &TsEnumRecord,
-        ambient_const_enum_only: Option<&FxHashSet<Id>>,
-        const_vars: &FxHashMap<Id, TsEnumRecordValue>,
-        unresolved_ctxt: SyntaxContext,
-        flow_syntax: bool,
-    ) -> TsEnumRecordValue {
-        member
-            .init
-            .map(|expr| {
-                EnumValueComputer {
-                    enum_id,
-                    unresolved_ctxt,
-                    record,
-                    const_vars,
-                    const_enum_only: None,
-                    ambient_record,
-                    ambient_const_enum_only,
-                }
-                .compute(expr, EvalCtx::MEMBER)
-            })
-            .filter(TsEnumRecordValue::has_value)
-            .unwrap_or_else(|| {
-                if flow_syntax && matches!(default_init, TsEnumRecordValue::Void) {
-                    // Flow defaulted enums without an initializer use the member
-                    // name as the runtime string value. The AST does not retain
-                    // the explicit `of string` kind, so `Void` acts as the
-                    // sentinel for Flow's default string mode here.
-                    TsEnumRecordValue::String(enum_member_name(&member.id))
-                } else {
-                    default_init.clone()
-                }
-            })
+    fn enter_decl(&mut self, node: &Decl) -> DeclarationState {
+        let state = DeclarationState {
+            skip_transform_info: self.skip_transform_info,
+        };
+        self.skip_transform_info |= !self.concrete.should_retain_decl(node);
+        state
     }
-}
 
-impl SemanticAnalyzer {
-    /// Ambient enums are erased from the output, but `tsc` still treats their
-    /// members with constant initializers as constant enum expressions inside
-    /// enum and const initializers. In an ambient `const enum` every member is
-    /// constant, so the usual auto-increment applies; in a plain ambient enum
-    /// a member without an initializer stays opaque. Kept out of `enum_record`
-    /// so the inliner never rewrites runtime reads of the ambient object.
-    fn record_ambient_enum(&mut self, node: &TsEnumDecl) {
-        if node.is_const {
-            self.info.const_enum.insert(node.id.to_id());
+    fn leave_decl(&mut self, state: DeclarationState) {
+        self.skip_transform_info = state.skip_transform_info;
+    }
+
+    fn ident(&mut self, node: &Ident) {
+        self.visit_ident(node);
+    }
+
+    fn enter_namespace(&mut self, id: &Id) -> Self::NamespaceState {
+        if self.skip_transform_info {
+            return None;
         }
+        Some(self.namespace_id.replace(id.clone()))
+    }
 
-        let mut default_init: TsEnumRecordValue = 0.0.into();
-
-        for member in &node.members {
-            let value = match (&member.init, node.is_const) {
-                (Some(init), _) => EnumValueComputer {
-                    enum_id: &node.id.to_id(),
-                    unresolved_ctxt: self.unresolved_ctxt,
-                    record: &self.info.enum_record,
-                    const_vars: &self.info.const_vars,
-                    const_enum_only: self.ts_enum_is_mutable.then_some(&self.info.const_enum),
-                    ambient_record: &self.info.ambient_enum_record,
-                    ambient_const_enum_only: self
-                        .ts_enum_is_mutable
-                        .then_some(&self.info.const_enum),
-                }
-                .compute(
-                    init.clone(),
-                    // Type syntax inside an ambient initializer removes
-                    // constness, like in a const initializer: `tsc` leaves
-                    // `declare enum A { X = 1 as number }` opaque.
-                    EvalCtx::CONST_INIT,
-                ),
-                (None, true) => default_init.clone(),
-                (None, false) => continue,
-            };
-
-            default_init = value.inc();
-
-            if value.is_const() {
-                self.info.ambient_enum_record.insert(
-                    TsEnumRecordKey {
-                        enum_id: node.id.to_id(),
-                        member_name: enum_member_name(&member.id),
-                    },
-                    value,
-                );
-            }
+    fn leave_namespace(&mut self, previous: Self::NamespaceState) {
+        if let Some(previous) = previous {
+            self.namespace_id = previous;
         }
     }
+
+    fn module_decl(&mut self, _: &TsModuleDecl) {
+        self.runtime_bindings_seen = true;
+    }
+
+    fn import_equals(&mut self, node: &TsImportEqualsDecl) {
+        self.visit_ts_import_equals_decl(node);
+    }
+
+    fn enum_decl(&mut self, node: &TsEnumDecl, ambient: bool, exported: bool) {
+        self.collect_enum(node);
+        self.literal_enums.collect(node, ambient, exported);
+    }
+
+    fn named_export(&mut self, node: &NamedExport) {
+        self.visit_named_export(node);
+    }
+
+    fn export_decl(&mut self, node: &ExportDecl) {
+        self.collect_export_decl(node);
+    }
+
+    fn export_default_expr(&mut self, node: &ExportDefaultExpr) {
+        self.collect_export_default_expr(node);
+    }
 }
 
 impl Visit for SemanticAnalyzer {
     noop_visit_type!();
 
     fn visit_module(&mut self, node: &Module) {
-        for item in &node.body {
-            self.collect_top_level_module_item(item);
-        }
-
+        self.collect_module(node);
         node.visit_children_with(self);
     }
 
     fn visit_decl(&mut self, node: &Decl) {
         let prev = self.skip_transform_info;
 
-        if !should_retain_decl(node) {
+        if !self.concrete.should_retain_decl(node) {
             self.skip_transform_info = true;
         }
 
@@ -374,12 +444,12 @@ impl Visit for SemanticAnalyzer {
     }
 
     fn visit_ident(&mut self, node: &Ident) {
-        let id = node.to_id();
-        self.info.usage.insert(id.clone());
-
-        if let Some(namespace_block) = self.namespace_block_stack.last_mut() {
-            namespace_block.usage.insert(id);
+        // Enum substitution needs the later reference walk. Do not collect a
+        // second set that would be discarded after evaluating the enums.
+        if self.skip_transform_info || self.enum_seen {
+            return;
         }
+        self.info.usage.insert(node.to_id());
     }
 
     fn visit_expr(&mut self, node: &Expr) {
@@ -415,80 +485,20 @@ impl Visit for SemanticAnalyzer {
     }
 
     fn visit_ts_import_equals_decl(&mut self, node: &TsImportEqualsDecl) {
-        if let Some(namespace_block) = self.namespace_block_stack.last_mut() {
-            namespace_block.import_equals.push(NamespaceImportEquals {
-                id: node.id.to_id(),
-                span: node.span,
-                is_export: node.is_export,
-                is_type_only: node.is_type_only,
-            });
-        }
-
-        if !self.skip_transform_info && node.is_export {
+        self.runtime_bindings_seen = true;
+        if !self.skip_transform_info && node.is_export && self.namespace_id.is_none() {
             self.info
                 .exported_binding
                 .insert(node.id.to_id(), self.namespace_id.clone());
         }
 
-        if node.is_type_only {
-            return;
-        }
-
-        let TsModuleRef::TsEntityName(ts_entity_name) = &node.module_ref else {
-            return;
-        };
-
-        let id = get_module_ident(ts_entity_name);
-
-        if let Some(namespace_block) = self.namespace_block_stack.last_mut() {
-            if node.is_export {
-                namespace_block.usage.insert(id.to_id());
-                namespace_block.usage.insert(node.id.to_id());
-            } else {
-                namespace_block
-                    .import_chain
-                    .insert(node.id.to_id(), id.to_id());
-            }
-        }
-
-        if node.is_export {
-            id.visit_with(self);
-            node.id.visit_with(self);
-            return;
-        }
-
-        self.import_chain.insert(node.id.to_id(), id.to_id());
+        // Alias roots are dependencies, not ordinary runtime references.
+        // The binding graph activates them only when their alias survives.
     }
 
     fn visit_export_decl(&mut self, node: &ExportDecl) {
         node.visit_children_with(self);
-
-        if self.skip_transform_info {
-            return;
-        }
-
-        match &node.decl {
-            Decl::Var(var_decl) => {
-                let ids: Vec<Id> = find_pat_ids(&var_decl.decls);
-                self.info.exported_binding.extend(
-                    ids.into_iter()
-                        .zip(std::iter::repeat(self.namespace_id.clone())),
-                );
-            }
-            Decl::TsEnum(ts_enum_decl) => {
-                self.info
-                    .exported_binding
-                    .insert(ts_enum_decl.id.to_id(), self.namespace_id.clone());
-            }
-            Decl::TsModule(ts_module_decl) => {
-                if let TsModuleName::Ident(ident) = &ts_module_decl.id {
-                    self.info
-                        .exported_binding
-                        .insert(ident.to_id(), self.namespace_id.clone());
-                }
-            }
-            _ => {}
-        }
+        self.collect_export_decl(node);
     }
 
     fn visit_export_named_specifier(&mut self, node: &ExportNamedSpecifier) {
@@ -520,16 +530,7 @@ impl Visit for SemanticAnalyzer {
 
     fn visit_export_default_expr(&mut self, node: &ExportDefaultExpr) {
         node.visit_children_with(self);
-
-        if self.skip_transform_info {
-            return;
-        }
-
-        if let Expr::Ident(ident) = &*node.expr {
-            self.info
-                .exported_binding
-                .insert(ident.to_id(), self.namespace_id.clone());
-        }
+        self.collect_export_default_expr(node);
     }
 
     fn visit_ts_namespace_decl(&mut self, node: &TsNamespaceDecl) {
@@ -546,6 +547,12 @@ impl Visit for SemanticAnalyzer {
     }
 
     fn visit_ts_module_decl(&mut self, node: &TsModuleDecl) {
+        // Pure type namespaces cannot contribute evaluated references. Skip
+        // their entire body instead of requesting a file-wide binding graph.
+        if !self.concrete.is_concrete(node) {
+            return;
+        }
+        self.runtime_bindings_seen = true;
         if self.skip_transform_info {
             if let Some(body) = &node.body {
                 body.visit_with(self);
@@ -570,122 +577,9 @@ impl Visit for SemanticAnalyzer {
         self.namespace_id = namespace_id;
     }
 
-    fn visit_ts_module_block(&mut self, node: &TsModuleBlock) {
-        self.namespace_block_stack.push(NamespaceBlock::default());
-
-        node.visit_children_with(self);
-
-        let mut namespace_block = self
-            .namespace_block_stack
-            .pop()
-            .expect("namespace block stack should contain current block");
-
-        namespace_block.analyze_import_chain();
-
-        for import_equals in &namespace_block.import_equals {
-            if import_equals.is_type_only {
-                continue;
-            }
-
-            if import_equals.is_export || namespace_block.usage.contains(&import_equals.id) {
-                self.info
-                    .namespace_import_equals_usage
-                    .insert(import_equals.span);
-            }
-        }
-
-        if let Some(parent_block) = self.namespace_block_stack.last_mut() {
-            parent_block.usage.extend(namespace_block.usage);
-            parent_block
-                .import_chain
-                .extend(namespace_block.import_chain);
-        }
-    }
-
-    fn visit_var_decl(&mut self, node: &VarDecl) {
-        let track = node.kind == VarDeclKind::Const;
-
-        for decl in &node.decls {
-            decl.visit_with(self);
-
-            if !track {
-                continue;
-            }
-
-            let Pat::Ident(BindingIdent { id, type_ann: None }) = &decl.name else {
-                continue;
-            };
-            let Some(init) = &decl.init else { continue };
-
-            if !EnumValueComputer::can_fold_shape(init) {
-                continue;
-            }
-
-            let value = EnumValueComputer {
-                enum_id: &id.to_id(),
-                unresolved_ctxt: self.unresolved_ctxt,
-                record: &self.info.enum_record,
-                const_vars: &self.info.const_vars,
-                const_enum_only: self.ts_enum_is_mutable.then_some(&self.info.const_enum),
-                ambient_record: &self.info.ambient_enum_record,
-                ambient_const_enum_only: self.ts_enum_is_mutable.then_some(&self.info.const_enum),
-            }
-            .compute(init.clone(), EvalCtx::CONST_INIT);
-
-            if value.is_const() {
-                self.info.const_vars.insert(id.to_id(), value);
-            }
-        }
-    }
-
     fn visit_ts_enum_decl(&mut self, node: &TsEnumDecl) {
-        node.visit_children_with(self);
-
-        if self.skip_transform_info {
-            self.record_ambient_enum(node);
-            return;
-        }
-
-        let TsEnumDecl {
-            is_const,
-            id,
-            members,
-            ..
-        } = node;
-
-        if *is_const {
-            self.info.const_enum.insert(id.to_id());
-        }
-
-        let mut default_init = if self.flow_syntax {
-            TsEnumRecordValue::Void
-        } else {
-            0.0.into()
-        };
-
-        for member in members {
-            let value = Self::transform_ts_enum_member(
-                member.clone(),
-                &id.to_id(),
-                &default_init,
-                &self.info.enum_record,
-                &self.info.ambient_enum_record,
-                self.ts_enum_is_mutable.then_some(&self.info.const_enum),
-                &self.info.const_vars,
-                self.unresolved_ctxt,
-                self.flow_syntax,
-            );
-
-            default_init = value.inc();
-
-            let member_name = enum_member_name(&member.id);
-            let key = TsEnumRecordKey {
-                enum_id: id.to_id(),
-                member_name,
-            };
-
-            self.info.enum_record.insert(key, value);
-        }
+        self.collect_enum(node);
+        node.members.visit_with(self);
     }
 
     fn visit_jsx_element_name(&mut self, node: &JSXElementName) {
@@ -700,50 +594,53 @@ impl Visit for SemanticAnalyzer {
 
 #[cfg(test)]
 mod tests {
-    use swc_common::{SyntaxContext, DUMMY_SP};
+    use swc_common::DUMMY_SP;
     use swc_ecma_ast::{Ident, TsEnumMember, TsEnumMemberId};
+    use swc_ecma_parser::Syntax;
+    use swc_ecma_transforms_base::resolver;
+    use swc_ecma_transforms_testing::Tester;
 
     use super::*;
 
-    fn id(sym: &str) -> Id {
-        (sym.into(), SyntaxContext::empty())
+    fn namespace_usage(source: &str) -> FxHashSet<swc_atoms::Atom> {
+        Tester::run(|tester| {
+            let module = tester.with_parser(
+                "namespace-aliases.ts",
+                Syntax::Typescript(Default::default()),
+                source,
+                |parser| parser.parse_module(),
+            )?;
+            let unresolved = Mark::new();
+            let top_level = Mark::new();
+            let mut program = Program::Module(module);
+            program.mutate(resolver(unresolved, top_level, true));
+            let info = analyze_program(
+                &mut program,
+                unresolved,
+                FxHashSet::default(),
+                false,
+                false,
+                false,
+            );
+            Ok(info.usage.into_iter().map(|(name, _)| name).collect())
+        })
     }
 
     #[test]
     fn namespace_block_analyze_import_chain_marks_transitive_usage() {
-        let mut namespace_block = NamespaceBlock {
-            usage: [id("a")].into_iter().collect(),
-            import_chain: [(id("a"), id("b")), (id("b"), id("c"))]
-                .into_iter()
-                .collect(),
-            ..Default::default()
-        };
-
-        namespace_block.analyze_import_chain();
+        let usage = namespace_usage("namespace N { class c {} import b = c; import a = b; a; }");
 
-        assert!(namespace_block.usage.contains(&id("b")));
-        assert!(namespace_block.usage.contains(&id("c")));
+        assert!(usage.contains(&swc_atoms::Atom::from("b")));
+        assert!(usage.contains(&swc_atoms::Atom::from("c")));
     }
 
     #[test]
     fn namespace_block_merge_from_child_keeps_parent_alias_used() {
-        let mut parent = NamespaceBlock {
-            import_chain: [(id("a"), id("n"))].into_iter().collect(),
-            ..Default::default()
-        };
-
-        let mut child = NamespaceBlock {
-            usage: [id("b")].into_iter().collect(),
-            import_chain: [(id("b"), id("a"))].into_iter().collect(),
-            ..Default::default()
-        };
-
-        child.analyze_import_chain();
-        parent.usage.extend(child.usage);
-        parent.import_chain.extend(child.import_chain);
-        parent.analyze_import_chain();
+        let usage = namespace_usage(
+            "namespace N { class n {} import a = n; namespace Child { import b = a; b; } }",
+        );
 
-        assert!(parent.usage.contains(&id("a")));
+        assert!(usage.contains(&swc_atoms::Atom::from("a")));
     }
 
     fn enum_member(sym: &str) -> TsEnumMember {
@@ -756,19 +653,11 @@ mod tests {
 
     #[test]
     fn flow_defaulted_enum_member_uses_member_name_as_runtime_value() {
-        let value = SemanticAnalyzer::transform_ts_enum_member(
-            enum_member("A"),
-            &id("E"),
-            &TsEnumRecordValue::Void,
-            &Default::default(),
-            &Default::default(),
-            None,
-            &Default::default(),
-            SyntaxContext::empty(),
-            true,
-        );
+        let member = enum_member("A");
+        let name = crate::shared::enum_member_name(&member.id);
+        let value = enums::default_member(&EnumValue::Unknown, &name, true);
 
-        let TsEnumRecordValue::String(value) = value else {
+        let EnumValue::String(value) = value else {
             panic!("expected defaulted Flow enum member to become a string literal");
         };
         assert_eq!(&*value, "A");
@@ -776,19 +665,11 @@ mod tests {
 
     #[test]
     fn typescript_defaulted_enum_member_still_uses_numeric_sequence() {
-        let value = SemanticAnalyzer::transform_ts_enum_member(
-            enum_member("A"),
-            &id("E"),
-            &TsEnumRecordValue::from(2.0),
-            &Default::default(),
-            &Default::default(),
-            None,
-            &Default::default(),
-            SyntaxContext::empty(),
-            false,
-        );
+        let member = enum_member("A");
+        let name = crate::shared::enum_member_name(&member.id);
+        let value = enums::default_member(&EnumValue::number(2.0), &name, false);
 
-        let TsEnumRecordValue::Number(value) = value else {
+        let EnumValue::Number(value) = value else {
             panic!("expected defaulted TypeScript enum member to stay numeric");
         };
         assert_eq!(value.value, 2.0);
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/availability.rs b/crates/swc_ecma_transforms_typescript/src/semantic/availability.rs
new file mode 100644
index 0000000000000000000000000000000000000000..b0856b2609075dda42b420e7c51c55c857a76103
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/availability.rs
@@ -0,0 +1,167 @@
+//! Initialization order and execution regions, derived only from AST traversal.
+//!
+//! Constant evaluation and enum inlining share these coordinates. Source spans
+//! and the order in which dependencies happen to be evaluated are not semantic
+//! inputs to availability.
+
+use std::ops::Range;
+
+mod traversal;
+pub(super) use traversal::{
+    visit_execution_regions, visit_function_decorators, visit_function_execution,
+};
+
+#[derive(Debug, Clone, Copy)]
+struct RegionId(usize);
+
+/// The position and execution region of an enum member or const initializer.
+#[derive(Debug, Clone, Copy)]
+pub(crate) struct Initialization {
+    order: usize,
+    region: RegionId,
+}
+
+/// A reference's current position in the same AST execution-order walk.
+#[derive(Debug, Clone, Copy)]
+pub(crate) struct UseSite {
+    order: usize,
+    region: RegionId,
+}
+
+impl Initialization {
+    /// Constant-expression IR has no nested declarations. Its references occur
+    /// immediately after this declaration's position in the order walk.
+    pub(super) fn use_site(self) -> UseSite {
+        UseSite {
+            order: self.order + 1,
+            region: self.region,
+        }
+    }
+}
+
+#[derive(Debug, Default)]
+pub(super) struct Availability {
+    regions: Vec<Range<usize>>,
+}
+
+impl Availability {
+    pub(super) fn is_available(&self, definition: Initialization, usage: UseSite) -> bool {
+        definition.order < usage.order || !self.regions[usage.region.0].contains(&definition.order)
+    }
+}
+
+/// A single collection walk assigns both declaration order and region bounds.
+pub(super) struct AvailabilityBuilder {
+    facts: Availability,
+    next_order: usize,
+    region: RegionId,
+}
+
+pub(super) struct DeferredRegion {
+    region: RegionId,
+    parent: RegionId,
+}
+
+impl Default for AvailabilityBuilder {
+    fn default() -> Self {
+        Self {
+            facts: Availability {
+                regions: std::iter::once(0..0).collect(),
+            },
+            next_order: 0,
+            region: RegionId(0),
+        }
+    }
+}
+
+impl AvailabilityBuilder {
+    pub(super) fn initialization(&mut self) -> Initialization {
+        let location = Initialization {
+            order: self.next_order,
+            region: self.region,
+        };
+        self.next_order += 1;
+        location
+    }
+
+    pub(super) fn enter_deferred(&mut self) -> DeferredRegion {
+        let region = RegionId(self.facts.regions.len());
+        self.facts.regions.push(self.next_order..self.next_order);
+        let parent = std::mem::replace(&mut self.region, region);
+        DeferredRegion { region, parent }
+    }
+
+    pub(super) fn exit_deferred(&mut self, frame: DeferredRegion) {
+        self.facts.regions[frame.region.0].end = self.next_order;
+        self.region = frame.parent;
+    }
+
+    pub(super) fn finish(mut self) -> Availability {
+        // The root is immediate execution and contains every declaration.
+        self.facts.regions[0].end = self.next_order;
+        self.facts
+    }
+}
+
+/// Replay declaration and region events before erasure. Replacing a constant
+/// read cannot remove either kind of event, so substitution preserves the walk.
+pub(super) struct AvailabilityCursor<'a> {
+    // Reference-free enum definitions cannot observe these coordinates.
+    facts: Option<&'a Availability>,
+    next_order: usize,
+    next_region: usize,
+    region: RegionId,
+}
+
+impl<'a> AvailabilityCursor<'a> {
+    pub(super) fn new(facts: Option<&'a Availability>) -> Self {
+        Self {
+            facts,
+            next_order: 0,
+            next_region: 1,
+            region: RegionId(0),
+        }
+    }
+
+    pub(super) fn initialization(&mut self) {
+        if self.facts.is_some() {
+            self.next_order += 1;
+        }
+    }
+
+    pub(super) fn use_site(&self) -> Option<UseSite> {
+        self.facts.map(|_| UseSite {
+            order: self.next_order,
+            region: self.region,
+        })
+    }
+
+    pub(super) fn enter_deferred(&mut self) -> Option<DeferredRegion> {
+        self.facts?;
+        let region = RegionId(self.next_region);
+        self.next_region += 1;
+        let parent = std::mem::replace(&mut self.region, region);
+        Some(DeferredRegion { region, parent })
+    }
+
+    pub(super) fn exit_deferred(&mut self, frame: Option<DeferredRegion>) {
+        if let Some(frame) = frame {
+            self.region = frame.parent;
+        }
+    }
+
+    pub(super) fn finish(self) {
+        let Some(facts) = self.facts else {
+            return;
+        };
+        debug_assert_eq!(
+            self.next_order, facts.regions[0].end,
+            "enum substitution must replay every declaration event before erasure"
+        );
+        debug_assert_eq!(
+            self.next_region,
+            facts.regions.len(),
+            "enum substitution must replay every execution region before erasure"
+        );
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/availability/traversal.rs b/crates/swc_ecma_transforms_typescript/src/semantic/availability/traversal.rs
new file mode 100644
index 0000000000000000000000000000000000000000..3ecb1bfe699b5173d1aecdaea586c4a3ec266325
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/availability/traversal.rs
@@ -0,0 +1,170 @@
+//! Definition collection and substitution use identical execution boundaries.
+
+use swc_ecma_ast::Function;
+use swc_ecma_visit::{VisitMut, VisitMutWith};
+
+/// Decorators execute when the enclosing class is evaluated, including those
+/// stored on parameters rather than on the function itself.
+pub(in crate::semantic) fn visit_function_decorators(
+    node: &mut Function,
+    visitor: &mut impl VisitMut,
+) {
+    node.decorators.visit_mut_with(visitor);
+    for parameter in &mut node.params {
+        parameter.decorators.visit_mut_with(visitor);
+    }
+}
+
+/// Visit only runtime children evaluated on invocation. Type syntax is erased
+/// and decorators have already been visited in the enclosing execution region.
+pub(in crate::semantic) fn visit_function_execution(
+    node: &mut Function,
+    visitor: &mut impl VisitMut,
+) {
+    for parameter in &mut node.params {
+        parameter.pat.visit_mut_with(visitor);
+    }
+    node.body.visit_mut_with(visitor);
+}
+
+macro_rules! visit_execution_regions {
+    () => {
+        fn visit_mut_function(&mut self, node: &mut Function) {
+            $crate::semantic::availability::visit_function_decorators(node, self);
+            self.deferred(|collector| {
+                $crate::semantic::availability::visit_function_execution(node, collector);
+            });
+        }
+
+        fn visit_mut_arrow_expr(&mut self, node: &mut ArrowExpr) {
+            self.deferred(|collector| node.visit_mut_children_with(collector));
+        }
+
+        fn visit_mut_constructor(&mut self, node: &mut Constructor) {
+            for parameter in &mut node.params {
+                match parameter {
+                    ParamOrTsParamProp::Param(parameter) => {
+                        parameter.decorators.visit_mut_with(self);
+                    }
+                    ParamOrTsParamProp::TsParamProp(parameter) => {
+                        parameter.decorators.visit_mut_with(self);
+                    }
+                    #[cfg(swc_ast_unknown)]
+                    _ => panic!("unable to access unknown nodes"),
+                }
+            }
+            self.deferred(|collector| {
+                node.key.visit_mut_with(collector);
+                for parameter in &mut node.params {
+                    match parameter {
+                        ParamOrTsParamProp::Param(parameter) => {
+                            parameter.pat.visit_mut_with(collector);
+                        }
+                        ParamOrTsParamProp::TsParamProp(parameter) => {
+                            parameter.param.visit_mut_with(collector);
+                        }
+                        #[cfg(swc_ast_unknown)]
+                        _ => panic!("unable to access unknown nodes"),
+                    }
+                }
+                node.body.visit_mut_with(collector);
+            });
+        }
+
+        fn visit_mut_class_method(&mut self, node: &mut ClassMethod) {
+            $crate::semantic::availability::visit_function_decorators(&mut node.function, self);
+            // Method names participate in the method's semantic deferred region,
+            // as do parameter initializers and the body. Ordinary computed
+            // properties do not.
+            self.deferred(|collector| {
+                node.key.visit_mut_with(collector);
+                $crate::semantic::availability::visit_function_execution(
+                    &mut node.function,
+                    collector,
+                );
+            });
+        }
+
+        fn visit_mut_private_method(&mut self, node: &mut PrivateMethod) {
+            node.function.visit_mut_with(self);
+        }
+
+        fn visit_mut_method_prop(&mut self, node: &mut MethodProp) {
+            $crate::semantic::availability::visit_function_decorators(&mut node.function, self);
+            self.deferred(|collector| {
+                node.key.visit_mut_with(collector);
+                $crate::semantic::availability::visit_function_execution(
+                    &mut node.function,
+                    collector,
+                );
+            });
+        }
+
+        fn visit_mut_getter_prop(&mut self, node: &mut GetterProp) {
+            self.deferred(|collector| {
+                node.key.visit_mut_with(collector);
+                node.function.visit_mut_children_with(collector);
+            });
+        }
+
+        fn visit_mut_setter_prop(&mut self, node: &mut SetterProp) {
+            self.deferred(|collector| {
+                node.key.visit_mut_with(collector);
+                node.function.visit_mut_children_with(collector);
+            });
+        }
+
+        fn visit_mut_auto_accessor(&mut self, node: &mut AutoAccessor) {
+            node.key.visit_mut_with(self);
+            node.decorators.visit_mut_with(self);
+            if node.is_static {
+                node.value.visit_mut_with(self);
+            } else if let Some(value) = &mut node.value {
+                self.deferred(|collector| value.visit_mut_with(collector));
+            }
+        }
+
+        fn visit_mut_class_prop(&mut self, node: &mut ClassProp) {
+            node.key.visit_mut_with(self);
+            node.decorators.visit_mut_with(self);
+            if node.is_static {
+                node.value.visit_mut_with(self);
+            } else if let Some(value) = &mut node.value {
+                self.deferred(|collector| value.visit_mut_with(collector));
+            }
+        }
+
+        fn visit_mut_private_prop(&mut self, node: &mut PrivateProp) {
+            node.decorators.visit_mut_with(self);
+            if node.is_static {
+                node.value.visit_mut_with(self);
+            } else if let Some(value) = &mut node.value {
+                self.deferred(|collector| value.visit_mut_with(collector));
+            }
+        }
+
+        fn visit_mut_call_expr(&mut self, node: &mut CallExpr) {
+            // Direct function IIFEs execute in the current region. Functions
+            // nested in their bodies still introduce their own regions.
+            if let Callee::Expr(callee) = &mut node.callee {
+                let mut callee = &mut **callee;
+                // TypeScript recognizes IIFEs only through grouping. Type
+                // wrappers retain the function's deferred analysis boundary,
+                // even though those wrappers are erased before execution.
+                while let Expr::Paren(ParenExpr { expr, .. }) = callee {
+                    callee = expr;
+                }
+                match callee {
+                    Expr::Fn(function) => function.function.visit_mut_children_with(self),
+                    Expr::Arrow(arrow) => arrow.visit_mut_children_with(self),
+                    _ => callee.visit_mut_with(self),
+                }
+            } else {
+                node.callee.visit_mut_with(self);
+            }
+            node.args.visit_mut_with(self);
+        }
+    };
+}
+
+pub(crate) use visit_execution_regions;
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/concrete.rs b/crates/swc_ecma_transforms_typescript/src/semantic/concrete.rs
new file mode 100644
index 0000000000000000000000000000000000000000..5cc79801e5b0b3b7db317b416f2bc49728de007c
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/concrete.rs
@@ -0,0 +1,50 @@
+//! Concrete namespace bodies are memoized during semantic analysis, before
+//! declaration erasure. Expression substitution does not move namespace boxes
+//! or change their concrete status. Keys identify individual declarations, even
+//! when merged declarations share resolved names or synthesized spans.
+
+use rustc_hash::FxHashMap;
+use swc_ecma_ast::{Decl, TsModuleDecl};
+use swc_ecma_utils::stack_size::maybe_grow_default;
+
+use crate::retain::{namespace_body_is_concrete, should_retain_decl};
+
+#[derive(Default)]
+pub(super) struct NamespaceConcreteness {
+    // Addresses are identity keys only and are never dereferenced. This cache
+    // must be discarded before namespace declarations are moved or erased.
+    values: FxHashMap<*const TsModuleDecl, bool>,
+}
+
+impl NamespaceConcreteness {
+    pub(super) fn is_concrete(&mut self, node: &TsModuleDecl) -> bool {
+        let key = node as *const TsModuleDecl;
+        if let Some(&concrete) = self.values.get(&key) {
+            return concrete;
+        }
+        let mut recursive = false;
+        let concrete = node.body.as_ref().is_some_and(|body| {
+            maybe_grow_default(|| {
+                namespace_body_is_concrete(body, &mut |child| {
+                    recursive = true;
+                    self.is_concrete(child)
+                })
+            })
+        });
+        // Leaf bodies have no repeated subtree work. Avoid allocating cache
+        // entries for the common case of flat namespace declarations.
+        if recursive {
+            self.values.insert(key, concrete);
+        }
+        concrete
+    }
+
+    pub(super) fn should_retain_decl(&mut self, node: &Decl) -> bool {
+        match node {
+            Decl::TsModule(namespace) => {
+                !namespace.declare && !namespace.global && self.is_concrete(namespace)
+            }
+            _ => should_retain_decl(node),
+        }
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/constants.rs b/crates/swc_ecma_transforms_typescript/src/semantic/constants.rs
new file mode 100644
index 0000000000000000000000000000000000000000..0a25949fbd364665e99a7bab583d78ba3459bace
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/constants.rs
@@ -0,0 +1,234 @@
+//! The syntax accepted by TypeScript's constant evaluator, before type erasure.
+//!
+//! This is a small derived expression tree. It owns computed strings and
+//! literal values, but never copies runtime AST subtrees such as functions or
+//! calls.
+
+use swc_atoms::{wtf8::Wtf8Buf, Wtf8Atom};
+use swc_common::SyntaxContext;
+use swc_ecma_ast::*;
+use swc_ecma_utils::{
+    number::{JsNumber, ToJsString},
+    stack_size::maybe_grow_default,
+    ts_bindings::{transparent_expr, TsBindings, TsContainerId, TsMemberResolution, TsValueTarget},
+};
+
+use super::enums::EnumValue;
+
+#[derive(Debug)]
+pub(super) enum ConstantExpr {
+    Literal(EnumValue),
+    Reference(TsValueTarget),
+    Unary(UnaryOp, Box<ConstantExpr>),
+    Binary(BinaryOp, Box<ConstantExpr>, Box<ConstantExpr>),
+    Template {
+        quasis: Box<[Option<Wtf8Atom>]>,
+        expressions: Box<[ConstantExpr]>,
+    },
+    Unknown,
+}
+
+impl ConstantExpr {
+    pub(super) fn collect(
+        expression: &Expr,
+        bindings: &TsBindings,
+        enum_owner: Option<TsContainerId>,
+        unresolved: SyntaxContext,
+    ) -> Self {
+        Self::collect_with(expression, &|expression| {
+            Self::reference(expression, bindings, enum_owner, unresolved)
+        })
+    }
+
+    /// Evaluate only reference-free syntax. Unknown syntax stays opaque,
+    /// including type wrappers, so this cannot bypass declaration availability.
+    pub(super) fn literal(expression: &Expr) -> EnumValue {
+        Self::collect_with(expression, &|_| Self::Unknown)
+            .evaluate(&mut |_| unreachable!("literal collection does not produce references"))
+    }
+
+    fn reference(
+        expression: &Expr,
+        bindings: &TsBindings,
+        enum_owner: Option<TsContainerId>,
+        unresolved: SyntaxContext,
+    ) -> Self {
+        match expression {
+            Expr::Ident(ident) => {
+                // Resolver deliberately gives bare enum members its unresolved
+                // sentinel. Only this enum's declared member set can interpret it.
+                if ident.ctxt == unresolved {
+                    let member = enum_owner
+                        .and_then(|owner| bindings.named_member(owner, &ident.sym.clone().into()));
+                    if let Some(member) =
+                        member.filter(|member| bindings.member(*member).is_enum_member())
+                    {
+                        return Self::Reference(TsValueTarget::EnumMember(member));
+                    }
+                    let value = match ident.sym.as_ref() {
+                        "Infinity" => f64::INFINITY,
+                        "NaN" => f64::NAN,
+                        _ => return Self::Unknown,
+                    };
+                    return Self::Literal(EnumValue::Number(Number {
+                        span: ident.span,
+                        value,
+                        raw: Some(ident.sym.clone()),
+                    }));
+                }
+                bindings
+                    .ident_value_target(ident)
+                    .map_or(Self::Unknown, Self::Reference)
+            }
+            Expr::Member(_) | Expr::OptChain(_) => bindings
+                .expression_target(expression, TsMemberResolution::Constant)
+                .map_or(Self::Unknown, Self::Reference),
+            _ => unreachable!("only reference syntax requests declaration lookup"),
+        }
+    }
+
+    fn collect_with(expression: &Expr, reference: &impl Fn(&Expr) -> Self) -> Self {
+        maybe_grow_default(|| Self::collect_syntax(expression, reference))
+    }
+
+    fn collect_syntax(expression: &Expr, reference: &impl Fn(&Expr) -> Self) -> Self {
+        let expression = transparent_expr(expression);
+        let child = |expression: &Expr| Self::collect_with(expression, reference);
+        match expression {
+            Expr::Lit(Lit::Num(number)) => Self::Literal(EnumValue::Number(number.clone())),
+            Expr::Lit(Lit::Str(string)) => Self::Literal(EnumValue::String(string.value.clone())),
+            Expr::Ident(_) | Expr::Member(_) | Expr::OptChain(_) => reference(expression),
+            Expr::Unary(unary)
+                if matches!(unary.op, UnaryOp::Plus | UnaryOp::Minus | UnaryOp::Tilde) =>
+            {
+                Self::Unary(unary.op, Box::new(child(&unary.arg)))
+            }
+            Expr::Bin(binary)
+                if matches!(
+                    binary.op,
+                    BinaryOp::Add
+                        | BinaryOp::Sub
+                        | BinaryOp::Mul
+                        | BinaryOp::Div
+                        | BinaryOp::Mod
+                        | BinaryOp::Exp
+                        | BinaryOp::LShift
+                        | BinaryOp::RShift
+                        | BinaryOp::ZeroFillRShift
+                        | BinaryOp::BitOr
+                        | BinaryOp::BitAnd
+                        | BinaryOp::BitXor
+                ) =>
+            {
+                Self::Binary(
+                    binary.op,
+                    Box::new(child(&binary.left)),
+                    Box::new(child(&binary.right)),
+                )
+            }
+            Expr::Tpl(template) => Self::Template {
+                quasis: template
+                    .quasis
+                    .iter()
+                    .map(|quasi| quasi.cooked.clone())
+                    .collect(),
+                expressions: template
+                    .exprs
+                    .iter()
+                    .map(|expression| child(expression))
+                    .collect(),
+            },
+            // TS assertions, satisfies, non-null and instantiation syntax are
+            // barriers both to constants and to syntactic string knowledge.
+            _ => Self::Unknown,
+        }
+    }
+
+    pub(super) fn evaluate(
+        &self,
+        resolve: &mut impl FnMut(TsValueTarget) -> EnumValue,
+    ) -> EnumValue {
+        maybe_grow_default(|| self.evaluate_inner(resolve))
+    }
+
+    fn evaluate_inner(&self, resolve: &mut impl FnMut(TsValueTarget) -> EnumValue) -> EnumValue {
+        match self {
+            Self::Literal(value) => value.clone(),
+            Self::Reference(target) => resolve(*target),
+            Self::Unknown => EnumValue::Unknown,
+            Self::Unary(operator, operand) => {
+                let EnumValue::Number(number) = operand.evaluate(resolve) else {
+                    return EnumValue::Unknown;
+                };
+                let value = match operator {
+                    UnaryOp::Plus => number.value,
+                    UnaryOp::Minus => -number.value,
+                    UnaryOp::Tilde => (!JsNumber::from(number.value)).into(),
+                    _ => unreachable!("constant IR only contains arithmetic unary operators"),
+                };
+                EnumValue::number(value)
+            }
+            Self::Binary(operator, left, right) => {
+                let left = left.evaluate(resolve);
+                let right = right.evaluate(resolve);
+                if *operator == BinaryOp::Add && (left.is_string() || right.is_string()) {
+                    let mut string = Wtf8Buf::new();
+                    if push_string(&left, &mut string) && push_string(&right, &mut string) {
+                        return EnumValue::String(Wtf8Atom::from(&*string));
+                    }
+                    return EnumValue::StringExpression;
+                }
+                let (EnumValue::Number(left), EnumValue::Number(right)) = (left, right) else {
+                    return EnumValue::Unknown;
+                };
+                let left = JsNumber::from(left.value);
+                let right = JsNumber::from(right.value);
+                let value = match operator {
+                    BinaryOp::Add => left + right,
+                    BinaryOp::Sub => left - right,
+                    BinaryOp::Mul => left * right,
+                    BinaryOp::Div => left / right,
+                    BinaryOp::Mod => left % right,
+                    BinaryOp::Exp => left.pow(right),
+                    BinaryOp::LShift => left << right,
+                    BinaryOp::RShift => left >> right,
+                    BinaryOp::ZeroFillRShift => left.unsigned_shr(right),
+                    BinaryOp::BitOr => left | right,
+                    BinaryOp::BitAnd => left & right,
+                    BinaryOp::BitXor => left ^ right,
+                    _ => unreachable!("constant IR only contains arithmetic binary operators"),
+                };
+                EnumValue::number(value)
+            }
+            Self::Template {
+                quasis,
+                expressions,
+            } => {
+                let Some(Some(first)) = quasis.first() else {
+                    return EnumValue::StringExpression;
+                };
+                let mut string = Wtf8Buf::from(first);
+                for (expression, quasi) in expressions.iter().zip(&quasis[1..]) {
+                    let value = expression.evaluate(resolve);
+                    let Some(quasi) = quasi else {
+                        return EnumValue::StringExpression;
+                    };
+                    if !push_string(&value, &mut string) {
+                        return EnumValue::StringExpression;
+                    }
+                    string.push_wtf8(quasi);
+                }
+                EnumValue::String(Wtf8Atom::from(&*string))
+            }
+        }
+    }
+}
+
+fn push_string(value: &EnumValue, output: &mut Wtf8Buf) -> bool {
+    match value {
+        EnumValue::String(string) => output.push_wtf8(string),
+        EnumValue::Number(number) => output.push_str(&number.value.to_js_string()),
+        EnumValue::StringExpression | EnumValue::Unknown => return false,
+    }
+    true
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/enums.rs b/crates/swc_ecma_transforms_typescript/src/semantic/enums.rs
new file mode 100644
index 0000000000000000000000000000000000000000..99112b8d71eb6cc590ba625fed4aae80a3658a7d
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/enums.rs
@@ -0,0 +1,353 @@
+//! Enum values and runtime requirements share resolved declaration handles.
+//! Evaluation borrows immutable definitions; cached facts own literals and
+//! handles.
+
+use rustc_hash::FxHashMap;
+use swc_atoms::Wtf8Atom;
+use swc_common::{SyntaxContext, DUMMY_SP};
+use swc_ecma_ast::*;
+use swc_ecma_utils::ts_bindings::{
+    transparent_expr, TsBindings, TsContainerId, TsMemberId, TsValueTarget,
+};
+
+use super::availability::{Availability, AvailabilityCursor, Initialization, UseSite};
+
+mod bodies;
+mod definitions;
+mod literals;
+use bodies::EnumBodies;
+pub(crate) use bodies::EnumBodyCursor;
+use definitions::Definitions;
+pub(super) use literals::LiteralEnums;
+
+#[derive(Debug, Clone)]
+pub(crate) enum EnumValue {
+    Number(Number),
+    String(Wtf8Atom),
+    /// Syntactically a string, but its runtime value is not known.
+    StringExpression,
+    Unknown,
+}
+
+impl EnumValue {
+    pub(crate) fn number(value: impl Into<f64>) -> Self {
+        Self::Number(Number {
+            span: DUMMY_SP,
+            value: value.into(),
+            raw: None,
+        })
+    }
+
+    pub(crate) fn is_constant(&self) -> bool {
+        matches!(self, Self::Number(_) | Self::String(_))
+    }
+
+    pub(crate) fn is_string(&self) -> bool {
+        matches!(self, Self::String(_) | Self::StringExpression)
+    }
+
+    pub(crate) fn literal(&self) -> Option<Expr> {
+        match self {
+            Self::Number(number) => Some(Lit::Num(number.clone()).into()),
+            Self::String(string) => Some(Lit::Str(string.clone().into()).into()),
+            Self::StringExpression | Self::Unknown => None,
+        }
+    }
+
+    fn increment(&self) -> Self {
+        match self {
+            Self::Number(number) => Self::number(number.value + 1.0),
+            _ => Self::Unknown,
+        }
+    }
+}
+
+#[derive(Debug)]
+pub(crate) struct EnumDeclaration {
+    pub values: Vec<EnumValue>,
+    pub container: TsContainerId,
+}
+
+/// Erasure requirements accumulated across every body of a merged enum.
+#[derive(Debug)]
+pub(super) struct EnumContainer {
+    pub is_const: bool,
+    pub exported: bool,
+    pub all_constant: bool,
+    pub runtime_required: bool,
+}
+
+#[derive(Debug)]
+struct EnumMemberValue {
+    value: EnumValue,
+    inline: bool,
+    initialization: Option<Initialization>,
+}
+
+/// Facts survive syntax erasure; no initializer AST or evaluator is retained.
+#[derive(Debug, Default)]
+pub(crate) struct EnumFacts {
+    declarations: EnumBodies,
+    pub(super) containers: FxHashMap<TsContainerId, EnumContainer>,
+    values: FxHashMap<TsMemberId, EnumMemberValue>,
+    has_member_aliases: bool,
+    availability: Option<Availability>,
+}
+
+impl EnumFacts {
+    pub(super) fn availability_cursor(&self) -> AvailabilityCursor<'_> {
+        AvailabilityCursor::new(self.availability.as_ref())
+    }
+
+    /// Select bodies in declaration order without relying on source locations.
+    pub(crate) fn body_cursor(&self) -> EnumBodyCursor<'_> {
+        self.declarations.cursor()
+    }
+
+    pub(crate) fn can_erase(&self, container: TsContainerId, verbatim: bool) -> bool {
+        !verbatim
+            && self.containers.get(&container).is_some_and(|facts| {
+                facts.is_const && !facts.exported && facts.all_constant && !facts.runtime_required
+            })
+    }
+
+    /// Module-level import-alias initializers are synthesized after analysis.
+    /// They follow ordinary enum-read rules outside enum initializers.
+    pub(crate) fn inline_module_value(
+        &self,
+        bindings: &TsBindings,
+        expression: &Expr,
+        mutable: bool,
+        verbatim: bool,
+    ) -> Option<&EnumValue> {
+        if verbatim || self.values.is_empty() {
+            return None;
+        }
+        // Only member accesses and aliases to enum members can be replaced.
+        // Other expressions still visit their children during transformation.
+        match transparent_expr(expression) {
+            Expr::Member(_) => {}
+            Expr::Ident(_) if self.has_member_aliases => {}
+            _ => return None,
+        }
+        let TsValueTarget::EnumMember(member) = bindings.runtime_expression_target(expression)?
+        else {
+            return None;
+        };
+        self.member_value(bindings, member, mutable, None)
+    }
+
+    pub(crate) fn member_value(
+        &self,
+        bindings: &TsBindings,
+        member: TsMemberId,
+        mutable: bool,
+        initializer: Option<UseSite>,
+    ) -> Option<&EnumValue> {
+        if mutable {
+            let owner = bindings.member(member).owner;
+            let facts = self.containers.get(&owner)?;
+            if !facts.is_const {
+                return None;
+            }
+        }
+        let value = self.values.get(&member)?;
+        if let Some(location) = initializer {
+            if !self
+                .availability
+                .as_ref()?
+                .is_available(value.initialization?, location)
+            {
+                return None;
+            }
+        }
+        (value.inline && value.value.is_constant()).then_some(&value.value)
+    }
+
+    pub(super) fn require_runtime(&mut self, container: TsContainerId) {
+        if let Some(facts) = self.containers.get_mut(&container) {
+            facts.runtime_required = true;
+        }
+    }
+}
+
+/// Initializer facts follow TypeScript independently of optional read inlining.
+pub(super) fn analyze(
+    program: &mut Program,
+    bindings: &TsBindings,
+    unresolved: SyntaxContext,
+    flow: bool,
+) -> EnumFacts {
+    let definitions = Definitions::collect(program, bindings, unresolved);
+    let mut evaluator = Evaluator {
+        definitions: &definitions,
+        constants: vec![ConstantState::Pending; definitions.constants.len()],
+        enums: vec![EnumState::Pending; definitions.enums.len()],
+        values: definitions
+            .enums
+            .iter()
+            .map(|definition| vec![EnumValue::Unknown; definition.members.len()])
+            .collect(),
+        flow,
+    };
+    for index in 0..definitions.enums.len() {
+        evaluator.evaluate_enum(index);
+    }
+
+    let mut facts = EnumFacts {
+        values: FxHashMap::with_capacity_and_hasher(definitions.members.len(), Default::default()),
+        has_member_aliases: bindings.aliases().any(|alias| {
+            matches!(
+                bindings.alias_target(alias),
+                Some(TsValueTarget::EnumMember(_))
+            )
+        }),
+        ..Default::default()
+    };
+    for (definition, values) in definitions.enums.iter().zip(evaluator.values) {
+        let all_constant = values.iter().all(EnumValue::is_constant);
+        let container = facts
+            .containers
+            .entry(definition.container)
+            .or_insert(EnumContainer {
+                is_const: true,
+                exported: false,
+                all_constant: true,
+                runtime_required: false,
+            });
+        container.is_const &= definition.is_const;
+        container.exported |= definition.exported;
+        container.all_constant &= all_constant;
+        for (member, value) in definition.members.iter().zip(&values) {
+            facts.values.insert(
+                member.id,
+                EnumMemberValue {
+                    value: value.clone(),
+                    inline: !definition.ambient || definition.is_const,
+                    initialization: Some(member.initialization),
+                },
+            );
+        }
+        if !definition.ambient {
+            // Ambient bodies contribute constant evaluation and container
+            // facts, but neither runtime usage nor emission visits their bodies.
+            facts.declarations.insert(
+                definition.declaration,
+                EnumDeclaration {
+                    values,
+                    container: definition.container,
+                },
+            );
+        }
+    }
+    facts.availability = Some(definitions.availability);
+    facts
+}
+
+#[derive(Clone)]
+enum ConstantState {
+    Pending,
+    Evaluating,
+    Evaluated(EnumValue),
+}
+
+#[derive(Clone, Copy, PartialEq, Eq)]
+enum EnumState {
+    Pending,
+    Evaluating,
+    Evaluated,
+}
+
+struct Evaluator<'a, 'b> {
+    definitions: &'a Definitions<'b>,
+    constants: Vec<ConstantState>,
+    enums: Vec<EnumState>,
+    values: Vec<Vec<EnumValue>>,
+    flow: bool,
+}
+
+impl Evaluator<'_, '_> {
+    fn reference(&mut self, target: TsValueTarget, usage: UseSite) -> EnumValue {
+        match target {
+            TsValueTarget::Binding(declaration) => {
+                let Some(&index) = self.definitions.constants_by_declaration.get(&declaration)
+                else {
+                    return EnumValue::Unknown;
+                };
+                let definition = &self.definitions.constants[index];
+                // Availability belongs to this use, even after a previous use
+                // caused the definition to be memoized.
+                if !self
+                    .definitions
+                    .availability
+                    .is_available(definition.initialization, usage)
+                {
+                    return EnumValue::Unknown;
+                }
+                match &self.constants[index] {
+                    ConstantState::Evaluated(value) => return value.clone(),
+                    ConstantState::Evaluating => return EnumValue::Unknown,
+                    ConstantState::Pending => {}
+                }
+                self.constants[index] = ConstantState::Evaluating;
+                let value = definition.expression.evaluate(&mut |target| {
+                    self.reference(target, definition.initialization.use_site())
+                });
+                self.constants[index] = ConstantState::Evaluated(value.clone());
+                value
+            }
+            TsValueTarget::EnumMember(member) => {
+                let Some(&(index, member_index)) = self.definitions.members.get(&member) else {
+                    return EnumValue::Unknown;
+                };
+                let definition = &self.definitions.enums[index];
+                if !self
+                    .definitions
+                    .availability
+                    .is_available(definition.members[member_index].initialization, usage)
+                {
+                    return EnumValue::Unknown;
+                }
+                self.evaluate_enum(index);
+                self.values[index][member_index].clone()
+            }
+        }
+    }
+
+    fn evaluate_enum(&mut self, index: usize) {
+        if self.enums[index] != EnumState::Pending {
+            return;
+        }
+        self.enums[index] = EnumState::Evaluating;
+        let definition = &self.definitions.enums[index];
+        let mut default = if self.flow {
+            EnumValue::Unknown
+        } else {
+            EnumValue::number(0.0)
+        };
+        for (member_index, member) in definition.members.iter().enumerate() {
+            let value = match &member.expression {
+                Some(expression) => expression.evaluate(&mut |target| {
+                    self.reference(target, member.initialization.use_site())
+                }),
+                None if definition.ambient && !definition.is_const => EnumValue::Unknown,
+                None => default_member(
+                    &default,
+                    &self.definitions.bindings.member(member.id).name,
+                    self.flow,
+                ),
+            };
+            default = value.increment();
+            self.values[index][member_index] = value;
+        }
+        self.enums[index] = EnumState::Evaluated;
+    }
+}
+
+pub(super) fn default_member(default: &EnumValue, name: &Wtf8Atom, flow: bool) -> EnumValue {
+    if flow && matches!(default, EnumValue::Unknown) {
+        EnumValue::String(name.clone())
+    } else {
+        default.clone()
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/enums/bodies.rs b/crates/swc_ecma_transforms_typescript/src/semantic/enums/bodies.rs
new file mode 100644
index 0000000000000000000000000000000000000000..afd09d78198db1e5d38bdc6ca6d96039379b0244
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/enums/bodies.rs
@@ -0,0 +1,96 @@
+//! Each enum body has an identity independent of its merged binding and span.
+//! Consumers walk the same per-binding declaration order after type erasure.
+
+use std::num::NonZeroUsize;
+
+use rustc_hash::FxHashMap;
+use swc_ecma_ast::TsEnumDecl;
+use swc_ecma_utils::ts_bindings::{TsBindings, TsDeclarationId};
+
+use super::EnumDeclaration;
+
+#[derive(Debug, Clone, Copy)]
+struct EnumBodyId(NonZeroUsize);
+
+impl EnumBodyId {
+    fn from_index(index: usize) -> Self {
+        let index = NonZeroUsize::new(index.wrapping_add(1))
+            .expect("enum body arena indices must be smaller than usize::MAX");
+        Self(index)
+    }
+
+    fn index(self) -> usize {
+        self.0.get() - 1
+    }
+}
+
+#[derive(Debug)]
+struct EnumBody {
+    facts: EnumDeclaration,
+    next: Option<EnumBodyId>,
+}
+
+#[derive(Debug)]
+struct EnumBodyGroup {
+    first: EnumBodyId,
+    last: EnumBodyId,
+}
+
+#[derive(Debug, Default)]
+pub(super) struct EnumBodies {
+    bodies: Vec<EnumBody>,
+    groups: Vec<EnumBodyGroup>,
+    groups_by_binding: FxHashMap<TsDeclarationId, usize>,
+}
+
+impl EnumBodies {
+    pub(super) fn insert(&mut self, binding: TsDeclarationId, facts: EnumDeclaration) {
+        use std::collections::hash_map::Entry;
+
+        let body = EnumBodyId::from_index(self.bodies.len());
+        self.bodies.push(EnumBody { facts, next: None });
+        match self.groups_by_binding.entry(binding) {
+            Entry::Occupied(entry) => {
+                let group = &mut self.groups[*entry.get()];
+                self.bodies[group.last.index()].next = Some(body);
+                group.last = body;
+            }
+            Entry::Vacant(entry) => {
+                entry.insert(self.groups.len());
+                self.groups.push(EnumBodyGroup {
+                    first: body,
+                    last: body,
+                });
+            }
+        }
+    }
+
+    pub(super) fn cursor(&self) -> EnumBodyCursor<'_> {
+        EnumBodyCursor {
+            bodies: self,
+            next: self.groups.iter().map(|group| Some(group.first)).collect(),
+        }
+    }
+}
+
+/// A separate cursor for each phase; facts stay in stable, borrowed storage.
+/// Grouping by binding keeps skipped declarations from shifting other bodies.
+pub(crate) struct EnumBodyCursor<'a> {
+    bodies: &'a EnumBodies,
+    next: Vec<Option<EnumBodyId>>,
+}
+
+impl<'a> EnumBodyCursor<'a> {
+    pub(crate) fn declaration(
+        &mut self,
+        bindings: &TsBindings,
+        node: &TsEnumDecl,
+    ) -> Option<&'a EnumDeclaration> {
+        let binding = bindings.ident_declaration(&node.id)?;
+        let group = *self.bodies.groups_by_binding.get(&binding)?;
+        let body = self.next[group]?;
+        let body = &self.bodies.bodies[body.index()];
+        self.next[group] = body.next;
+        Some(&body.facts)
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/enums/definitions.rs b/crates/swc_ecma_transforms_typescript/src/semantic/enums/definitions.rs
new file mode 100644
index 0000000000000000000000000000000000000000..fc3a6e1ad113b75740cd21a518df2e8efc4c9e44
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/enums/definitions.rs
@@ -0,0 +1,238 @@
+//! Collect immutable definitions and their shared AST initialization
+//! coordinates.
+
+use rustc_hash::FxHashMap;
+use swc_common::SyntaxContext;
+use swc_ecma_ast::*;
+use swc_ecma_utils::{
+    stack_size::maybe_grow_default,
+    ts_bindings::{TsBindings, TsContainerId, TsDeclarationId, TsMemberId},
+};
+use swc_ecma_visit::{noop_visit_mut_type, VisitMut, VisitMutWith};
+
+use super::super::{
+    availability::{visit_execution_regions, Availability, AvailabilityBuilder, Initialization},
+    constants::ConstantExpr,
+};
+
+#[derive(Debug)]
+pub(super) struct ConstantDefinition {
+    pub(super) initialization: Initialization,
+    pub(super) expression: ConstantExpr,
+}
+
+#[derive(Debug)]
+pub(super) struct EnumMemberDefinition {
+    pub(super) id: TsMemberId,
+    pub(super) initialization: Initialization,
+    pub(super) expression: Option<ConstantExpr>,
+}
+
+#[derive(Debug)]
+pub(super) struct EnumDefinition {
+    pub(super) declaration: TsDeclarationId,
+    pub(super) container: TsContainerId,
+    pub(super) is_const: bool,
+    pub(super) ambient: bool,
+    pub(super) exported: bool,
+    pub(super) members: Vec<EnumMemberDefinition>,
+}
+
+pub(super) struct Definitions<'a> {
+    pub(super) bindings: &'a TsBindings,
+    pub(super) constants: Vec<ConstantDefinition>,
+    pub(super) constants_by_declaration: FxHashMap<TsDeclarationId, usize>,
+    pub(super) enums: Vec<EnumDefinition>,
+    pub(super) members: FxHashMap<TsMemberId, (usize, usize)>,
+    pub(super) availability: Availability,
+}
+
+impl<'a> Definitions<'a> {
+    pub(super) fn collect(
+        program: &mut Program,
+        bindings: &'a TsBindings,
+        unresolved: SyntaxContext,
+    ) -> Self {
+        let mut collector = DefinitionCollector {
+            definitions: Self {
+                bindings,
+                constants: Vec::new(),
+                constants_by_declaration: FxHashMap::default(),
+                enums: Vec::new(),
+                members: FxHashMap::default(),
+                availability: Availability::default(),
+            },
+            unresolved,
+            order: AvailabilityBuilder::default(),
+            exported: false,
+            ambient: false,
+            constant: false,
+        };
+        // This walk does not mutate syntax. Sharing the mutable execution-region
+        // visitor with substitution keeps both walks on exactly the same model.
+        program.visit_mut_with(&mut collector);
+        collector.definitions.availability = collector.order.finish();
+        collector.definitions
+    }
+}
+
+struct DefinitionCollector<'a> {
+    definitions: Definitions<'a>,
+    unresolved: SyntaxContext,
+    order: AvailabilityBuilder,
+    exported: bool,
+    ambient: bool,
+    constant: bool,
+}
+
+impl DefinitionCollector<'_> {
+    fn expression(&self, expression: &Expr, owner: Option<TsContainerId>) -> ConstantExpr {
+        ConstantExpr::collect(
+            expression,
+            self.definitions.bindings,
+            owner,
+            self.unresolved,
+        )
+    }
+
+    fn collect_constant(&mut self, node: &VarDeclarator, initialization: Initialization) {
+        if !self.constant {
+            return;
+        }
+        let (Pat::Ident(BindingIdent { id, type_ann: None }), Some(init)) =
+            (&node.name, &node.init)
+        else {
+            return;
+        };
+        let expression = self.expression(init, None);
+        // Unsupported initializers are already unknown to evaluation;
+        // they need no definition entry or declaration lookup.
+        if matches!(expression, ConstantExpr::Unknown) {
+            return;
+        }
+        let Some(id) = self.definitions.bindings.ident_declaration(id) else {
+            return;
+        };
+        let index = self.definitions.constants.len();
+        self.definitions.constants.push(ConstantDefinition {
+            initialization,
+            expression,
+        });
+        self.definitions.constants_by_declaration.insert(id, index);
+    }
+
+    fn deferred(&mut self, visit: impl FnOnce(&mut Self)) {
+        let region = self.order.enter_deferred();
+        visit(self);
+        self.order.exit_deferred(region);
+    }
+}
+
+impl VisitMut for DefinitionCollector<'_> {
+    noop_visit_mut_type!();
+
+    visit_execution_regions!();
+
+    fn visit_mut_expr(&mut self, node: &mut Expr) {
+        maybe_grow_default(|| node.visit_mut_children_with(self));
+    }
+
+    fn visit_mut_export_decl(&mut self, node: &mut ExportDecl) {
+        let previous = std::mem::replace(&mut self.exported, true);
+        node.decl.visit_mut_with(self);
+        self.exported = previous;
+    }
+
+    fn visit_mut_ts_module_decl(&mut self, node: &mut TsModuleDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        let previous = self.ambient;
+        self.ambient |= node.declare || node.global || matches!(node.id, TsModuleName::Str(_));
+        node.body.visit_mut_with(self);
+        self.ambient = previous;
+        self.exported = exported;
+    }
+
+    fn visit_mut_var_decl(&mut self, node: &mut VarDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        let constant = std::mem::replace(&mut self.constant, node.kind == VarDeclKind::Const);
+        node.decls.visit_mut_with(self);
+        self.constant = constant;
+        self.exported = exported;
+    }
+
+    fn visit_mut_using_decl(&mut self, node: &mut UsingDecl) {
+        let constant = std::mem::replace(&mut self.constant, false);
+        node.visit_mut_children_with(self);
+        self.constant = constant;
+    }
+
+    fn visit_mut_var_declarator(&mut self, node: &mut VarDeclarator) {
+        let initialization = self.order.initialization();
+        self.collect_constant(node, initialization);
+        node.visit_mut_children_with(self);
+    }
+
+    fn visit_mut_ts_enum_decl(&mut self, node: &mut TsEnumDecl) {
+        let Some(declaration) = self.definitions.bindings.ident_declaration(&node.id) else {
+            node.members.visit_mut_with(self);
+            return;
+        };
+        let Some(container) = self.definitions.bindings.declaration_container(declaration) else {
+            node.members.visit_mut_with(self);
+            return;
+        };
+        let exported = std::mem::take(&mut self.exported);
+        let index = self.definitions.enums.len();
+        // Reserve the body before descending into initializers. Nested enums
+        // keep their own identities without moving later outer members ahead
+        // of the declarations in an earlier initializer.
+        self.definitions.enums.push(EnumDefinition {
+            declaration,
+            container,
+            is_const: node.is_const,
+            ambient: self.ambient || node.declare,
+            exported,
+            members: Vec::new(),
+        });
+        let mut members = Vec::with_capacity(node.members.len());
+        for member in &mut node.members {
+            let initialization = self.order.initialization();
+            let name = crate::shared::enum_member_name(&member.id);
+            if let Some(id) = self.definitions.bindings.named_member(container, &name) {
+                self.definitions
+                    .members
+                    .entry(id)
+                    .or_insert((index, members.len()));
+                let expression = member
+                    .init
+                    .as_deref()
+                    .map(|init| self.expression(init, Some(container)));
+                members.push(EnumMemberDefinition {
+                    id,
+                    initialization,
+                    expression,
+                });
+            }
+            member.visit_mut_children_with(self);
+        }
+        self.definitions.enums[index].members = members;
+        self.exported = exported;
+    }
+
+    fn visit_mut_ts_enum_member(&mut self, node: &mut TsEnumMember) {
+        self.order.initialization();
+        node.visit_mut_children_with(self);
+    }
+
+    fn visit_mut_fn_decl(&mut self, node: &mut FnDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        node.function.visit_mut_with(self);
+        self.exported = exported;
+    }
+
+    fn visit_mut_class_decl(&mut self, node: &mut ClassDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        node.class.visit_mut_with(self);
+        self.exported = exported;
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/enums/literals.rs b/crates/swc_ecma_transforms_typescript/src/semantic/enums/literals.rs
new file mode 100644
index 0000000000000000000000000000000000000000..74e8fa60dc8fb45c0bcd815785686e3dd5da2370
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/enums/literals.rs
@@ -0,0 +1,119 @@
+//! Reference-free enums need neither constant dependencies nor order replay.
+//! Collect them in the existing declaration walk; any unsupported initializer
+//! selects the complete definition collector for the entire file instead.
+
+use swc_atoms::Wtf8Atom;
+use swc_ecma_ast::{Id, TsEnumDecl};
+use swc_ecma_utils::ts_bindings::TsBindings;
+
+use super::{
+    default_member, EnumContainer, EnumDeclaration, EnumFacts, EnumMemberValue, EnumValue,
+};
+use crate::{semantic::constants::ConstantExpr, shared::enum_member_name};
+
+struct LiteralEnum {
+    id: Id,
+    is_const: bool,
+    exported: bool,
+    members: Vec<(Wtf8Atom, EnumValue)>,
+}
+
+pub(in crate::semantic) struct LiteralEnums {
+    declarations: Option<Vec<LiteralEnum>>,
+    flow: bool,
+}
+
+impl Default for LiteralEnums {
+    fn default() -> Self {
+        Self::new(false)
+    }
+}
+
+impl LiteralEnums {
+    pub(in crate::semantic) fn new(flow: bool) -> Self {
+        Self {
+            declarations: Some(Vec::new()),
+            flow,
+        }
+    }
+
+    pub(in crate::semantic) fn collect(
+        &mut self,
+        node: &TsEnumDecl,
+        ambient: bool,
+        exported: bool,
+    ) {
+        let Some(declarations) = &mut self.declarations else {
+            return;
+        };
+        if ambient {
+            self.declarations = None;
+            return;
+        }
+        let mut next = if self.flow {
+            EnumValue::Unknown
+        } else {
+            EnumValue::number(0.0)
+        };
+        let mut members = Vec::with_capacity(node.members.len());
+        for member in &node.members {
+            let name = enum_member_name(&member.id);
+            let value = match &member.init {
+                Some(expression) => ConstantExpr::literal(expression),
+                None => default_member(&next, &name, self.flow),
+            };
+            if !value.is_constant() {
+                self.declarations = None;
+                return;
+            }
+            next = value.increment();
+            members.push((name, value));
+        }
+        declarations.push(LiteralEnum {
+            id: node.id.to_id(),
+            is_const: node.is_const,
+            exported,
+            members,
+        });
+    }
+
+    pub(in crate::semantic) fn finish(self, bindings: &TsBindings) -> Option<EnumFacts> {
+        let declarations = self.declarations?;
+        let mut facts = EnumFacts::default();
+        for declaration in declarations {
+            let id = bindings.declaration_id(&declaration.id)?;
+            let container = bindings.declaration_container(id)?;
+            let owner = facts.containers.entry(container).or_insert(EnumContainer {
+                is_const: true,
+                exported: false,
+                all_constant: true,
+                runtime_required: false,
+            });
+            owner.is_const &= declaration.is_const;
+            owner.exported |= declaration.exported;
+            let mut values = Vec::with_capacity(declaration.members.len());
+            for (name, value) in declaration.members {
+                let member = bindings.named_member(container, &name)?;
+                facts.values.insert(
+                    member,
+                    EnumMemberValue {
+                        value: value.clone(),
+                        inline: true,
+                        initialization: None,
+                    },
+                );
+                values.push(value);
+            }
+            facts
+                .declarations
+                .insert(id, EnumDeclaration { values, container });
+        }
+        facts.has_member_aliases = bindings.aliases().any(|alias| {
+            matches!(
+                bindings.alias_target(alias),
+                Some(super::TsValueTarget::EnumMember(_))
+            )
+        });
+        Some(facts)
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/usage.rs b/crates/swc_ecma_transforms_typescript/src/semantic/usage.rs
new file mode 100644
index 0000000000000000000000000000000000000000..c380654cbbab21ff629f5faec904a596383296d9
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/usage.rs
@@ -0,0 +1,446 @@
+//! Substitute enum reads while collecting the surviving runtime references.
+//! Resolve import-alias dependencies after substitution.
+
+use rustc_hash::FxHashSet;
+use swc_common::SyntaxContext;
+use swc_ecma_ast::*;
+use swc_ecma_utils::{
+    stack_size::maybe_grow_default,
+    ts_bindings::{TsAliasId, TsBindings, TsContainerId, TsValueTarget},
+};
+use swc_ecma_visit::{noop_visit_mut_type, VisitMut, VisitMutWith};
+
+use super::{
+    availability::{visit_execution_regions, AvailabilityCursor},
+    concrete::NamespaceConcreteness,
+    enums::{EnumBodyCursor, EnumFacts, EnumValue},
+};
+
+mod candidates;
+mod members;
+use candidates::{Candidates, ReferenceFacts};
+use members::MemberTargets;
+
+pub(super) struct RuntimeUsage {
+    pub bindings: FxHashSet<Id>,
+    pub aliases: FxHashSet<TsAliasId>,
+    pub containers: FxHashSet<TsContainerId>,
+}
+
+pub(super) fn analyze(
+    program: &mut Program,
+    bindings: &TsBindings,
+    enums: &EnumFacts,
+    seed: FxHashSet<Id>,
+    mutable: bool,
+    verbatim: bool,
+    unresolved: SyntaxContext,
+) -> RuntimeUsage {
+    let mut collector = UsageCollector {
+        bindings,
+        enums,
+        concrete: NamespaceConcreteness::default(),
+        enum_bodies: enums.body_cursor(),
+        candidates: Candidates::new(program, bindings),
+        member_targets: MemberTargets::default(),
+        usage: RuntimeUsage {
+            bindings: seed,
+            aliases: FxHashSet::default(),
+            containers: FxHashSet::default(),
+        },
+        mutable,
+        verbatim,
+        unresolved,
+        enum_owner: None,
+        order: enums.availability_cursor(),
+        skip_usage: false,
+        lhs: false,
+    };
+    program.visit_mut_with(&mut collector);
+    collector.order.finish();
+    finish_aliases(bindings, collector.usage, verbatim)
+}
+
+pub(super) fn from_resolved_usage(
+    bindings: &TsBindings,
+    references: FxHashSet<Id>,
+    verbatim: bool,
+) -> RuntimeUsage {
+    let mut usage = RuntimeUsage {
+        bindings: references,
+        aliases: FxHashSet::default(),
+        containers: FxHashSet::default(),
+    };
+    for reference in &usage.bindings {
+        if let Some(target) = bindings.value_target(reference) {
+            require_target(bindings, &mut usage.containers, target);
+        }
+    }
+    finish_aliases(bindings, usage, verbatim)
+}
+
+fn finish_aliases(bindings: &TsBindings, mut usage: RuntimeUsage, verbatim: bool) -> RuntimeUsage {
+    let mut pending = Vec::new();
+    for alias in bindings.aliases() {
+        let declaration = bindings.alias(alias);
+        if bindings.alias_has_runtime_initializer(alias)
+            && (declaration.is_export
+                || declaration.is_script_global
+                || verbatim
+                || usage
+                    .bindings
+                    .contains(bindings.declaration(declaration.declaration)))
+        {
+            pending.push(alias);
+        }
+    }
+    while let Some(alias) = pending.pop() {
+        if !bindings.alias_has_runtime_initializer(alias) || !usage.aliases.insert(alias) {
+            continue;
+        }
+        let declaration = bindings.alias(alias);
+        usage
+            .bindings
+            .insert(bindings.declaration(declaration.declaration).clone());
+        if let Some(target) = bindings.alias_target(alias) {
+            require_target(bindings, &mut usage.containers, target);
+        }
+        if let Some(dependency) = bindings.alias_dependency(alias) {
+            usage
+                .bindings
+                .insert(bindings.declaration(dependency).clone());
+            if let Some(alias) = bindings.declaration_alias(dependency) {
+                pending.push(alias);
+            }
+        }
+    }
+    usage
+}
+
+struct UsageCollector<'a> {
+    concrete: NamespaceConcreteness,
+    bindings: &'a TsBindings,
+    enums: &'a EnumFacts,
+    enum_bodies: EnumBodyCursor<'a>,
+    candidates: Candidates<'a>,
+    member_targets: MemberTargets,
+    usage: RuntimeUsage,
+    mutable: bool,
+    verbatim: bool,
+    unresolved: SyntaxContext,
+    enum_owner: Option<TsContainerId>,
+    order: AvailabilityCursor<'a>,
+    skip_usage: bool,
+    lhs: bool,
+}
+
+impl UsageCollector<'_> {
+    fn inline_value(&self, target: TsValueTarget) -> Option<Expr> {
+        if self.skip_usage || self.lhs || self.verbatim {
+            return None;
+        }
+        let TsValueTarget::EnumMember(member) = target else {
+            return None;
+        };
+        self.enums
+            .member_value(
+                self.bindings,
+                member,
+                self.mutable,
+                self.enum_owner.and_then(|_| self.order.use_site()),
+            )
+            .and_then(EnumValue::literal)
+    }
+
+    fn unresolved_member_value(&self, ident: &Ident) -> Option<Expr> {
+        if ident.ctxt != self.unresolved {
+            return None;
+        }
+        let member = self
+            .bindings
+            .named_member(self.enum_owner?, &ident.sym.clone().into())?;
+        self.inline_value(TsValueTarget::EnumMember(member))
+    }
+
+    fn deferred(&mut self, visit: impl FnOnce(&mut Self)) {
+        let region = self.order.enter_deferred();
+        visit(self);
+        self.order.exit_deferred(region);
+    }
+
+    fn require_target(&mut self, target: TsValueTarget) {
+        if self.skip_usage {
+            return;
+        }
+        require_target(self.bindings, &mut self.usage.containers, target);
+    }
+
+    fn record_ident(&mut self, node: &Ident, candidate: ReferenceFacts) {
+        if self.skip_usage {
+            return;
+        }
+        if candidate.reference {
+            self.usage.bindings.insert(node.to_id());
+        }
+        if let Some(owner) = self.enum_owner {
+            self.require_unresolved_enum_member(node, owner);
+        }
+        if let Some(target) = candidate.target {
+            self.require_target(target);
+        }
+    }
+
+    fn require_unresolved_enum_member(&mut self, node: &Ident, owner: TsContainerId) {
+        if self.skip_usage || node.ctxt != self.unresolved {
+            return;
+        }
+        if self
+            .bindings
+            .named_member(owner, &node.sym.clone().into())
+            .is_some_and(|member| self.bindings.member(member).is_enum_member())
+        {
+            self.usage.containers.insert(owner);
+        }
+    }
+}
+
+fn require_target(
+    bindings: &TsBindings,
+    containers: &mut FxHashSet<TsContainerId>,
+    target: TsValueTarget,
+) {
+    let owner = match target {
+        TsValueTarget::Binding(declaration) => bindings.declaration_container(declaration),
+        TsValueTarget::EnumMember(member) => Some(bindings.member(member).owner),
+    };
+    if let Some(owner) = owner {
+        containers.insert(owner);
+    }
+}
+
+impl VisitMut for UsageCollector<'_> {
+    noop_visit_mut_type!();
+
+    visit_execution_regions!();
+
+    fn visit_mut_var_declarator(&mut self, node: &mut VarDeclarator) {
+        self.order.initialization();
+        node.visit_mut_children_with(self);
+    }
+
+    fn visit_mut_decl(&mut self, node: &mut Decl) {
+        let previous = self.skip_usage;
+        self.skip_usage |= !self.concrete.should_retain_decl(node);
+        node.visit_mut_children_with(self);
+        self.skip_usage = previous;
+    }
+
+    fn visit_mut_expr(&mut self, node: &mut Expr) {
+        // Only resolved identifiers and static member reads can substitute an
+        // enum value or retain a runtime container. Other expression kinds
+        // contribute references through their children.
+        match &*node {
+            Expr::Ident(ident) => {
+                if let Some(candidate) = self.member_targets.candidate(ident, &self.candidates) {
+                    if let Some(target) = candidate.target {
+                        if let Some(value) = self.inline_value(target) {
+                            *node = value;
+                            return;
+                        }
+                    }
+                    self.record_ident(ident, candidate);
+                } else if let Some(owner) = self.enum_owner {
+                    if let Some(value) = self.unresolved_member_value(ident) {
+                        *node = value;
+                        return;
+                    }
+                    // Unresolved member names can still retain an enum initializer's owner.
+                    self.require_unresolved_enum_member(ident, owner);
+                }
+                return;
+            }
+            Expr::Member(_) | Expr::Paren(_) => {
+                if let Some(target) =
+                    self.member_targets
+                        .target(node, &self.candidates, self.bindings)
+                {
+                    if let Some(value) = self.inline_value(target) {
+                        // Substitution discards the unvisited inner prefixes.
+                        self.member_targets.clear();
+                        *node = value;
+                        return;
+                    }
+                    self.require_target(target);
+                }
+            }
+            _ => {}
+        }
+        maybe_grow_default(|| node.visit_mut_children_with(self));
+    }
+
+    fn visit_mut_prop(&mut self, node: &mut Prop) {
+        if let Prop::Shorthand(ident) = node {
+            let value = self
+                .candidates
+                .get(ident)
+                .and_then(|candidate| candidate.target)
+                .and_then(|target| self.inline_value(target))
+                .or_else(|| self.unresolved_member_value(ident));
+            if let Some(value) = value {
+                *node = Prop::KeyValue(KeyValueProp {
+                    key: PropName::Ident(ident.clone().into()),
+                    value: Box::new(value),
+                });
+                return;
+            }
+        }
+        node.visit_mut_children_with(self);
+    }
+
+    fn visit_mut_ident(&mut self, node: &mut Ident) {
+        if let Some(candidate) = self.candidates.get(node) {
+            self.record_ident(node, candidate);
+        } else if let Some(owner) = self.enum_owner {
+            self.require_unresolved_enum_member(node, owner);
+        }
+    }
+
+    fn visit_mut_binding_ident(&mut self, _: &mut BindingIdent) {}
+
+    fn visit_mut_import_decl(&mut self, _: &mut ImportDecl) {}
+
+    fn visit_mut_ts_import_equals_decl(&mut self, _: &mut TsImportEqualsDecl) {}
+
+    fn visit_mut_fn_decl(&mut self, node: &mut FnDecl) {
+        node.function.visit_mut_with(self);
+    }
+
+    fn visit_mut_fn_expr(&mut self, node: &mut FnExpr) {
+        node.function.visit_mut_with(self);
+    }
+
+    fn visit_mut_class_decl(&mut self, node: &mut ClassDecl) {
+        node.class.visit_mut_with(self);
+    }
+
+    fn visit_mut_class_expr(&mut self, node: &mut ClassExpr) {
+        node.class.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_module_decl(&mut self, node: &mut TsModuleDecl) {
+        node.body.visit_mut_with(self);
+    }
+
+    fn visit_mut_export_decl(&mut self, node: &mut ExportDecl) {
+        if let Decl::TsModule(namespace) = &node.decl {
+            if self.concrete.should_retain_decl(&node.decl) {
+                if let TsModuleName::Ident(id) = &namespace.id {
+                    if let Some(target) = self.bindings.runtime_target(id) {
+                        self.require_target(target);
+                    }
+                }
+            }
+        }
+        node.decl.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_namespace_decl(&mut self, node: &mut TsNamespaceDecl) {
+        node.body.visit_mut_with(self);
+    }
+
+    fn visit_mut_ts_enum_decl(&mut self, node: &mut TsEnumDecl) {
+        let declaration = if self.skip_usage {
+            None
+        } else {
+            self.enum_bodies.declaration(self.bindings, node)
+        };
+        let previous = self.enum_owner;
+        self.enum_owner = declaration.map(|declaration| declaration.container);
+        for (index, member) in node.members.iter_mut().enumerate() {
+            let facts = declaration.and_then(|declaration| declaration.values.get(index));
+            self.order.initialization();
+            if facts.is_some_and(EnumValue::is_constant) {
+                continue;
+            }
+            member.init.visit_mut_with(self);
+        }
+        self.enum_owner = previous;
+    }
+
+    fn visit_mut_assign_expr(&mut self, node: &mut AssignExpr) {
+        let previous = std::mem::replace(&mut self.lhs, true);
+        node.left.visit_mut_with(self);
+        self.lhs = false;
+        node.right.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_unary_expr(&mut self, node: &mut UnaryExpr) {
+        // Delete consumes a reference; other unary operators consume a value.
+        let target_is_reference =
+            node.op == UnaryOp::Delete && crate::shared::is_reference_expr(&node.arg);
+        let previous = std::mem::replace(&mut self.lhs, target_is_reference);
+        node.arg.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_update_expr(&mut self, node: &mut UpdateExpr) {
+        let previous = std::mem::replace(&mut self.lhs, true);
+        node.arg.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_assign_pat(&mut self, node: &mut AssignPat) {
+        let previous = std::mem::replace(&mut self.lhs, true);
+        node.left.visit_mut_with(self);
+        self.lhs = false;
+        node.right.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_assign_pat_prop(&mut self, node: &mut AssignPatProp) {
+        node.key.visit_mut_with(self);
+        let previous = std::mem::replace(&mut self.lhs, false);
+        node.value.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_member_expr(&mut self, node: &mut MemberExpr) {
+        let previous = std::mem::replace(&mut self.lhs, false);
+        node.visit_mut_children_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_computed_prop_name(&mut self, node: &mut ComputedPropName) {
+        // A computed key is read even when its property is a write target.
+        let previous = std::mem::replace(&mut self.lhs, false);
+        node.expr.visit_mut_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_for_head(&mut self, node: &mut ForHead) {
+        let previous = std::mem::replace(&mut self.lhs, true);
+        node.visit_mut_children_with(self);
+        self.lhs = previous;
+    }
+
+    fn visit_mut_named_export(&mut self, node: &mut NamedExport) {
+        if !node.type_only && node.src.is_none() {
+            node.visit_mut_children_with(self);
+        }
+    }
+
+    fn visit_mut_export_named_specifier(&mut self, node: &mut ExportNamedSpecifier) {
+        if !node.is_type_only {
+            node.orig.visit_mut_with(self);
+        }
+    }
+
+    fn visit_mut_jsx_element_name(&mut self, node: &mut JSXElementName) {
+        if matches!(node, JSXElementName::Ident(ident) if ident.sym.starts_with(|character: char| character.is_ascii_lowercase()))
+        {
+            return;
+        }
+        node.visit_mut_children_with(self);
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/usage/candidates.rs b/crates/swc_ecma_transforms_typescript/src/semantic/usage/candidates.rs
new file mode 100644
index 0000000000000000000000000000000000000000..6dd698b98e114df2a14af471709a7b4fdbed98ea
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/usage/candidates.rs
@@ -0,0 +1,52 @@
+//! Runtime targets and import retention share one resolved-identity query.
+//! Candidate names borrow the declaration graph, which outlives substitutions;
+//! only surviving use records acquire IDs that outlive syntax erasure.
+
+use rustc_hash::FxHashMap;
+use swc_atoms::Atom;
+use swc_common::SyntaxContext;
+use swc_ecma_ast::*;
+use swc_ecma_utils::ts_bindings::{TsBindings, TsValueTarget};
+
+#[derive(Default, Clone, Copy)]
+pub(super) struct ReferenceFacts {
+    pub reference: bool,
+    pub target: Option<TsValueTarget>,
+}
+
+pub(super) struct Candidates<'a> {
+    values: FxHashMap<(&'a Atom, SyntaxContext), ReferenceFacts>,
+}
+
+impl<'a> Candidates<'a> {
+    pub(super) fn new(program: &Program, bindings: &'a TsBindings) -> Self {
+        let mut values = FxHashMap::<_, ReferenceFacts>::default();
+        if let Program::Module(module) = program {
+            for item in &module.body {
+                if let ModuleItem::ModuleDecl(ModuleDecl::Import(import)) = item {
+                    for specifier in &import.specifiers {
+                        let local = specifier.local();
+                        let declaration = bindings
+                            .ident_declaration(local)
+                            .expect("runtime binding collection must register every import");
+                        let id = bindings.declaration(declaration);
+                        values.entry((&id.0, id.1)).or_default().reference = true;
+                    }
+                }
+            }
+        }
+        for alias in bindings.aliases() {
+            let declaration = bindings.alias(alias).declaration;
+            let id = bindings.declaration(declaration);
+            values.entry((&id.0, id.1)).or_default().reference = true;
+        }
+        for (name, ctxt, target) in bindings.runtime_values() {
+            values.entry((name, ctxt)).or_default().target = Some(target);
+        }
+        Self { values }
+    }
+
+    pub(super) fn get(&self, ident: &Ident) -> Option<ReferenceFacts> {
+        self.values.get(&(&ident.sym, ident.ctxt)).copied()
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/semantic/usage/members.rs b/crates/swc_ecma_transforms_typescript/src/semantic/usage/members.rs
new file mode 100644
index 0000000000000000000000000000000000000000..6e466a279b0263256fb2c74bc1cc9bf3387df97d
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/semantic/usage/members.rs
@@ -0,0 +1,106 @@
+//! Resolve each object chain once and reuse its root's reference facts.
+
+use swc_ecma_ast::{Expr, Ident};
+use swc_ecma_utils::{
+    stack_size::maybe_grow_default,
+    ts_bindings::{TsBindings, TsMemberResolution, TsValueTarget},
+};
+
+use super::candidates::{Candidates, ReferenceFacts};
+
+#[derive(Default)]
+enum RootReference {
+    #[default]
+    Pending,
+    Cached(Option<ReferenceFacts>),
+}
+
+#[derive(Default)]
+pub(super) struct MemberTargets {
+    targets: Vec<Option<TsValueTarget>>,
+    unknown: usize,
+    // The object root is visited before any computed member keys.
+    root: RootReference,
+}
+
+impl MemberTargets {
+    pub(super) fn candidate(
+        &mut self,
+        ident: &Ident,
+        candidates: &Candidates<'_>,
+    ) -> Option<ReferenceFacts> {
+        match std::mem::take(&mut self.root) {
+            RootReference::Pending => candidates.get(ident),
+            RootReference::Cached(candidate) => candidate,
+        }
+    }
+
+    pub(super) fn target(
+        &mut self,
+        expression: &Expr,
+        candidates: &Candidates<'_>,
+        bindings: &TsBindings,
+    ) -> Option<TsValueTarget> {
+        if self.unknown == 0 && self.targets.is_empty() {
+            let mut root = expression;
+            let mut length = 0;
+            loop {
+                root = match root {
+                    Expr::Member(member) => &member.obj,
+                    Expr::Paren(paren) => &paren.expr,
+                    _ => break,
+                };
+                length += 1;
+            }
+            let target = if let Expr::Ident(ident) = root {
+                let candidate = candidates.get(ident);
+                self.root = RootReference::Cached(candidate);
+                candidate.and_then(|candidate| candidate.target)
+            } else {
+                None
+            };
+            if let Some(target) = target {
+                self.resolve(expression, target, bindings);
+            } else {
+                // No prefix can acquire a target after an unrelated root.
+                // Count these prefixes without allocating or recursively
+                // resolving them; the ordinary walk still visits their keys.
+                self.unknown = length;
+            }
+        }
+        if self.unknown != 0 {
+            self.unknown -= 1;
+            None
+        } else {
+            self.targets.pop().flatten()
+        }
+    }
+
+    fn resolve(
+        &mut self,
+        expression: &Expr,
+        root: TsValueTarget,
+        bindings: &TsBindings,
+    ) -> Option<TsValueTarget> {
+        maybe_grow_default(|| {
+            let target = match expression {
+                Expr::Member(member) => {
+                    self.resolve(&member.obj, root, bindings)
+                        .and_then(|object| {
+                            bindings.member_target(object, &member.prop, TsMemberResolution::Inline)
+                        })
+                }
+                Expr::Paren(paren) => self.resolve(&paren.expr, root, bindings),
+                _ => return Some(root),
+            };
+            self.targets.push(target);
+            target
+        })
+    }
+
+    pub(super) fn clear(&mut self) {
+        self.targets.clear();
+        self.unknown = 0;
+        self.root = RootReference::Pending;
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/shared.rs b/crates/swc_ecma_transforms_typescript/src/shared.rs
index 2079b162124b226c67ef1a50b1aaf8602b19e821..60374203e11323e7fe445ef9986d6950d885e1b3 100644
--- a/crates/swc_ecma_transforms_typescript/src/shared.rs
+++ b/crates/swc_ecma_transforms_typescript/src/shared.rs
@@ -1,5 +1,8 @@
 use swc_atoms::Wtf8Atom;
-use swc_ecma_ast::{Ident, TsEntityName, TsEnumMemberId};
+use swc_ecma_ast::{
+    Expr, OptChainBase, ParenExpr, TsAsExpr, TsConstAssertion, TsEnumMemberId, TsInstantiation,
+    TsNonNullExpr, TsSatisfiesExpr, TsTypeAssertion,
+};
 
 /// Returns an enum member name without discarding lone surrogates.
 #[inline]
@@ -12,14 +15,24 @@ pub(crate) fn enum_member_name(id: &TsEnumMemberId) -> Wtf8Atom {
     }
 }
 
-/// Returns the root identifier of an entity name chain like `A.B.C`.
-pub(crate) fn get_module_ident(ts_entity_name: &TsEntityName) -> &Ident {
-    match ts_entity_name {
-        TsEntityName::TsQualifiedName(ts_qualified_name) => {
-            get_module_ident(&ts_qualified_name.left)
-        }
-        TsEntityName::Ident(ident) => ident,
-        #[cfg(swc_ast_unknown)]
-        _ => panic!("unable to access unknown nodes"),
+/// Whether deleting this expression consumes a JavaScript reference.
+/// Grouping and erased TypeScript wrappers preserve the target's identity.
+pub(crate) fn is_reference_expr(mut expression: &Expr) -> bool {
+    loop {
+        expression = match expression {
+            Expr::Paren(ParenExpr { expr, .. })
+            | Expr::TsAs(TsAsExpr { expr, .. })
+            | Expr::TsNonNull(TsNonNullExpr { expr, .. })
+            | Expr::TsTypeAssertion(TsTypeAssertion { expr, .. })
+            | Expr::TsConstAssertion(TsConstAssertion { expr, .. })
+            | Expr::TsInstantiation(TsInstantiation { expr, .. })
+            | Expr::TsSatisfies(TsSatisfiesExpr { expr, .. }) => expr,
+            _ => break,
+        };
+    }
+    match expression {
+        Expr::Ident(_) | Expr::Member(_) | Expr::SuperProp(_) => true,
+        Expr::OptChain(chain) => matches!(&*chain.base, OptChainBase::Member(_)),
+        _ => false,
     }
 }
diff --git a/crates/swc_ecma_transforms_typescript/src/transform.rs b/crates/swc_ecma_transforms_typescript/src/transform.rs
index bd01331f811a724fef3d25276b5043ec56a2dc43..df5c8292ddaa6afd9e701edeed9cffa80d628b79 100644
--- a/crates/swc_ecma_transforms_typescript/src/transform.rs
+++ b/crates/swc_ecma_transforms_typescript/src/transform.rs
@@ -1,34 +1,36 @@
-use std::{borrow::Borrow, iter, mem};
+use std::mem;
 
 use rustc_hash::{FxHashMap, FxHashSet};
-use swc_atoms::{Atom, Wtf8Atom};
-use swc_common::{
-    errors::HANDLER, source_map::PURE_SP, util::take::Take, Mark, Span, Spanned, SyntaxContext,
-    DUMMY_SP,
-};
+use swc_atoms::Atom;
+use swc_common::{errors::HANDLER, util::take::Take, Mark, Span, Spanned, SyntaxContext, DUMMY_SP};
 use swc_ecma_ast::*;
 use swc_ecma_transforms_base::rename::rename;
 use swc_ecma_utils::{
-    alias_ident_for, constructor::inject_after_super, ident::IdentLike, is_literal, member_expr,
-    private_ident, quote_ident, quote_str, stack_size::maybe_grow_default, ExprFactory, QueryRef,
-    RefRewriter, StmtLikeInjector,
+    alias_ident_for,
+    constructor::inject_after_super,
+    is_literal, member_expr, private_ident, quote_ident, quote_str,
+    stack_size::maybe_grow_default,
+    ts_bindings::{TsContainerId, TsMemberId},
+    ExprFactory, RefRewriter, StmtLikeInjector,
 };
 use swc_ecma_visit::{
     noop_visit_mut_type, visit_mut_pass, Visit, VisitMut, VisitMutWith, VisitWith,
 };
 
 use crate::{
-    config::TsImportExportAssignConfig,
-    retain::{should_retain_module_item, should_retain_stmt},
-    semantic::SemanticInfo,
-    shared::enum_member_name,
-    ts_enum::{
-        static_enum_member_name, EnumValueComputer, EvalCtx, TsEnumRecordKey, TsEnumRecordValue,
-    },
-    utils::{assign_value_to_this_private_prop, assign_value_to_this_prop, Factory},
+    config::{Config, TsImportExportAssignConfig},
+    retain::{should_retain_decl, should_retain_module_item, should_retain_stmt},
+    semantic::{EnumBodyCursor, EnumInlining, SemanticInfo},
+    utils::{assign_value_to_this_private_prop, assign_value_to_this_prop},
 };
 
-/// ## This Module will transform all TypeScript specific synatx
+mod enums;
+mod exports;
+mod namespaces;
+
+use self::{enums::EnumEmission, exports::ExportQuery, namespaces::NamespaceInstantiation};
+
+/// ## This Module will transform all TypeScript specific syntax
 ///
 /// - ### [namespace]/[modules]/[enums]
 /// - ### class constructor [parameter properties]
@@ -52,8 +54,7 @@ use crate::{
 /// [enums]: https://www.typescriptlang.org/docs/handbook/enums.html
 /// [parameter properties]: https://www.typescriptlang.org/docs/handbook/2/classes.html#parameter-properties
 /// [export and import require]: https://www.typescriptlang.org/docs/handbook/modules.html#export--and-import--require
-#[derive(Default)]
-pub(crate) struct Transform {
+pub(crate) struct Transform<'a> {
     unresolved_ctxt: SyntaxContext,
     top_level_ctxt: SyntaxContext,
 
@@ -64,12 +65,20 @@ pub(crate) struct Transform {
     native_class_properties: bool,
     flow_syntax: bool,
 
-    semantic: SemanticInfo,
+    semantic: &'a SemanticInfo,
+    has_export_refs: bool,
 
     in_namespace: bool,
+    // Preserve each completed body's contribution across erasure so its
+    // enclosing namespace can reuse the result without rescanning the body.
+    namespace_state: NamespaceInstantiation,
     is_lhs: bool,
 
-    ref_rewriter: Option<RefRewriter<ExportQuery>>,
+    in_binding: bool,
+    container_contexts: Vec<ContainerContext<'a>>,
+    enum_inlining: EnumInlining,
+    enum_emissions: Vec<EnumEmission<'a>>,
+    enum_bodies: EnumBodyCursor<'a>,
 
     decl_id_record: FxHashSet<Id>,
     namespace_id: Option<Id>,
@@ -81,33 +90,122 @@ pub(crate) struct Transform {
     in_class_prop_init: Vec<Box<Expr>>,
 }
 
-#[allow(clippy::too_many_arguments)]
-pub fn transform(
+/// The JS bindings that this particular emitted container body provides.
+/// Exported variables, enums, aliases and nested namespaces are properties;
+/// functions and classes retain a body-local declaration.
+struct ContainerContext<'a> {
+    container: TsContainerId,
+    object: Id,
+    // Local names borrow the immutable semantic declaration store.
+    locals: FxHashMap<TsMemberId, &'a Id>,
+}
+
+impl Transform<'_> {
+    fn retain_decl(&self, declaration: &Decl) -> bool {
+        if let Decl::TsModule(declaration) = declaration {
+            // No namespace bindings means analysis found only erased namespaces.
+            return self.semantic.bindings.namespace_body(0).is_some()
+                && !declaration.declare
+                && !declaration.global
+                && declaration.body.is_some()
+                && declaration.id.as_ident().is_some_and(|id| {
+                    // A known value lets the ordinary child walk decide this
+                    // body's contribution. Reuse known type-only identities
+                    // before the fallback for uninstantiated private aliases.
+                    self.semantic.bindings.ident_value_target(id).is_some()
+                        || (!self.semantic.has_pure_type(&id.to_id())
+                            && self.namespace_instantiation(declaration).is_instantiated())
+                });
+        }
+        if !should_retain_decl(declaration) {
+            return false;
+        }
+        match declaration {
+            Decl::TsEnum(declaration) => !self.can_erase_enum(declaration),
+            _ => true,
+        }
+    }
+
+    fn retain_module_item(&self, item: &ModuleItem) -> bool {
+        match item {
+            // Statement declarations apply the same check in visit_mut_stmt.
+            ModuleItem::Stmt(Stmt::Decl(Decl::TsModule(_))) => true,
+            ModuleItem::Stmt(Stmt::Decl(declaration))
+            | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+                decl: declaration,
+                ..
+            })) => self.retain_decl(declaration),
+            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(declaration)) => {
+                !declaration.is_type_only
+                    && self
+                        .semantic
+                        .has_import_equals_usage(&declaration.id.to_id())
+            }
+            _ => should_retain_module_item(item),
+        }
+    }
+
+    fn has_ref_rewrites(&self) -> bool {
+        !self.in_binding && (!self.container_contexts.is_empty() || self.has_export_refs)
+    }
+
+    fn ref_rewriter(&self) -> Option<RefRewriter<ExportQuery<'_, '_>>> {
+        self.has_ref_rewrites().then(|| self.new_ref_rewriter())
+    }
+
+    fn new_ref_rewriter(&self) -> RefRewriter<ExportQuery<'_, '_>> {
+        RefRewriter {
+            query: ExportQuery::new(
+                &self.semantic.exported_binding,
+                &self.semantic.bindings,
+                &self.container_contexts,
+                self.has_export_refs,
+            ),
+        }
+    }
+}
+
+pub fn transform<'a>(
     unresolved_mark: Mark,
     top_level_mark: Mark,
-    semantic: SemanticInfo,
-    import_not_used_as_values: crate::ImportsNotUsedAsValues,
-    import_export_assign_config: TsImportExportAssignConfig,
-    ts_enum_is_mutable: bool,
-    verbatim_module_syntax: bool,
-    native_class_properties: bool,
-    flow_syntax: bool,
-) -> impl Pass {
+    semantic: &'a SemanticInfo,
+    config: Config,
+) -> impl Pass + 'a {
+    // Shared members are handled by the emitted owner. Only unindexed exports
+    // can use the legacy fallback outside or after those owner queries.
+    let has_export_refs = semantic
+        .exported_binding
+        .iter()
+        .any(|(id, owner)| owner.is_some() && semantic.bindings.member_of(id).is_none());
     visit_mut_pass(Transform {
         unresolved_ctxt: SyntaxContext::empty().apply_mark(unresolved_mark),
         top_level_ctxt: SyntaxContext::empty().apply_mark(top_level_mark),
         semantic,
-        import_not_used_as_values,
-        import_export_assign_config,
-        ts_enum_is_mutable,
-        verbatim_module_syntax,
-        native_class_properties,
-        flow_syntax,
-        ..Default::default()
+        has_export_refs,
+        import_not_used_as_values: config.import_not_used_as_values,
+        import_export_assign_config: config.import_export_assign_config,
+        ts_enum_is_mutable: config.ts_enum_is_mutable,
+        verbatim_module_syntax: config.verbatim_module_syntax,
+        native_class_properties: config.native_class_properties,
+        flow_syntax: config.flow_syntax,
+        in_namespace: false,
+        namespace_state: NamespaceInstantiation::default(),
+        is_lhs: false,
+        in_binding: false,
+        container_contexts: Vec::new(),
+        enum_inlining: semantic.enum_inlining,
+        enum_emissions: Vec::new(),
+        enum_bodies: semantic.enums.body_cursor(),
+        decl_id_record: FxHashSet::default(),
+        namespace_id: None,
+        var_list: Vec::new(),
+        export_var_list: Vec::new(),
+        in_class_prop: Vec::new(),
+        in_class_prop_init: Vec::new(),
     })
 }
 
-impl VisitMut for Transform {
+impl VisitMut for Transform<'_> {
     noop_visit_mut_type!();
 
     crate::type_to_none!(visit_mut_opt_ts_type, Box<TsType>);
@@ -122,13 +220,6 @@ impl VisitMut for Transform {
     );
 
     fn visit_mut_program(&mut self, node: &mut Program) {
-        if !self.semantic.exported_binding.is_empty() {
-            self.ref_rewriter = Some(RefRewriter {
-                query: ExportQuery {
-                    export_name: self.semantic.exported_binding.clone(),
-                },
-            });
-        }
         node.visit_mut_children_with(self);
     }
 
@@ -169,13 +260,17 @@ impl VisitMut for Transform {
 
     fn visit_mut_module_items(&mut self, node: &mut Vec<ModuleItem>) {
         let var_list = self.var_list.take();
-        node.retain(|item| should_retain_module_item(item, self.in_namespace));
-        node.retain_mut(|item| {
-            let is_empty = item.as_stmt().map(Stmt::is_empty).unwrap_or(false);
-            item.visit_mut_with(self);
-            // Remove those folded into Empty
-            is_empty || !item.as_stmt().map(Stmt::is_empty).unwrap_or(false)
-        });
+        if self.in_namespace {
+            self.namespace_state = self.visit_namespace_items(node);
+        } else {
+            node.retain(|item| self.retain_module_item(item));
+            node.retain_mut(|item| {
+                let is_empty = item.as_stmt().map(Stmt::is_empty).unwrap_or(false);
+                item.visit_mut_with(self);
+                // Remove those folded into Empty.
+                is_empty || !item.as_stmt().map(Stmt::is_empty).unwrap_or(false)
+            });
+        }
         let var_list = mem::replace(&mut self.var_list, var_list);
 
         if !var_list.is_empty() {
@@ -328,25 +423,60 @@ impl VisitMut for Transform {
 
     fn visit_mut_ts_namespace_decl(&mut self, node: &mut TsNamespaceDecl) {
         let id = node.id.to_id();
+        let context = self.namespace_context(id.clone(), &node.body);
+        let pushed = context.is_some();
+        self.container_contexts.extend(context);
         let namespace_id = self.namespace_id.replace(id);
 
         node.body.visit_mut_with(self);
+        self.namespace_state =
+            self.namespace_instantiation_with_usage(&node.id, self.namespace_state);
 
         self.namespace_id = namespace_id;
+        if pushed {
+            self.container_contexts.pop();
+        }
     }
 
     fn visit_mut_ts_module_decl(&mut self, node: &mut TsModuleDecl) {
         let id = node.id.to_id();
 
+        let context = node
+            .body
+            .as_ref()
+            .and_then(|body| self.namespace_context(id.clone(), body));
+        let pushed = context.is_some();
+        self.container_contexts.extend(context);
+
         let namespace_id = self.namespace_id.replace(id);
 
         node.body.visit_mut_with(self);
+        if let TsModuleName::Ident(id) = &node.id {
+            self.namespace_state =
+                self.namespace_instantiation_with_usage(id, self.namespace_state);
+        }
 
         self.namespace_id = namespace_id;
+        if pushed {
+            self.container_contexts.pop();
+        }
+    }
+
+    fn visit_mut_ts_enum_decl(&mut self, node: &mut TsEnumDecl) {
+        self.visit_enum(node);
     }
 
     fn visit_mut_stmt(&mut self, node: &mut Stmt) {
-        if !should_retain_stmt(node) {
+        let retain = match node {
+            Stmt::Decl(declaration) => self.retain_decl(declaration),
+            _ => should_retain_stmt(node),
+        };
+        if !retain {
+            if self.in_namespace {
+                if let Stmt::Decl(Decl::TsModule(declaration)) = node {
+                    self.namespace_state = self.namespace_instantiation(declaration);
+                }
+            }
             if !node.is_empty() {
                 node.take();
             }
@@ -402,7 +532,7 @@ impl VisitMut for Transform {
     }
 
     fn visit_mut_export_decl(&mut self, node: &mut ExportDecl) {
-        if self.ref_rewriter.is_some() {
+        if self.has_ref_rewrites() {
             if let Decl::Var(var_decl) = &mut node.decl {
                 // visit inner directly to bypass visit_mut_var_declarator
                 for decl in var_decl.decls.iter_mut() {
@@ -421,7 +551,7 @@ impl VisitMut for Transform {
     fn visit_mut_prop(&mut self, node: &mut Prop) {
         node.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_prop(node);
         }
     }
@@ -431,21 +561,24 @@ impl VisitMut for Transform {
             convert_flow_component_arrow(n);
         }
 
-        let ref_rewriter = self.ref_rewriter.take();
+        let in_binding = mem::replace(&mut self.in_binding, true);
         n.name.visit_mut_with(self);
-        self.ref_rewriter = ref_rewriter;
+        self.in_binding = in_binding;
         n.init.visit_mut_with(self);
     }
 
     fn visit_mut_pat(&mut self, node: &mut Pat) {
         node.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_pat(node);
         }
     }
 
     fn visit_mut_expr(&mut self, node: &mut Expr) {
+        // Defaults and computed keys within binding patterns are evaluated
+        // expressions; only the binding names themselves exclude rewrites.
+        let in_binding = mem::replace(&mut self.in_binding, false);
         while let Expr::TsAs(TsAsExpr { expr, .. })
         | Expr::TsNonNull(TsNonNullExpr { expr, .. })
         | Expr::TsTypeAssertion(TsTypeAssertion { expr, .. })
@@ -456,13 +589,18 @@ impl VisitMut for Transform {
             *node = *expr.take();
         }
 
-        self.enter_expr_for_inline_enum(node);
+        if matches!(self.enum_inlining, EnumInlining::Emit) {
+            self.enter_expr_for_inline_enum(node);
+        }
 
         maybe_grow_default(|| node.visit_mut_children_with(self));
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
-            ref_rewriter.exit_expr(node);
+        // Only identifiers can be rewritten at this boundary. Other expressions
+        // have already visited their reference-bearing children.
+        if self.has_ref_rewrites() && matches!(node, Expr::Ident(_)) {
+            self.new_ref_rewriter().exit_expr(node);
         }
+        self.in_binding = in_binding;
     }
 
     fn visit_mut_assign_expr(&mut self, n: &mut AssignExpr) {
@@ -481,6 +619,15 @@ impl VisitMut for Transform {
         self.is_lhs = is_lhs;
     }
 
+    fn visit_mut_unary_expr(&mut self, node: &mut UnaryExpr) {
+        // Delete consumes a reference; other unary operators consume a value.
+        let target_is_reference =
+            node.op == UnaryOp::Delete && crate::shared::is_reference_expr(&node.arg);
+        let previous = std::mem::replace(&mut self.is_lhs, target_is_reference);
+        node.arg.visit_mut_with(self);
+        self.is_lhs = previous;
+    }
+
     fn visit_mut_update_expr(&mut self, n: &mut UpdateExpr) {
         let is_lhs = mem::replace(&mut self.is_lhs, true);
         n.arg.visit_mut_with(self);
@@ -500,19 +647,38 @@ impl VisitMut for Transform {
         self.is_lhs = is_lhs;
     }
 
+    fn visit_mut_computed_prop_name(&mut self, node: &mut ComputedPropName) {
+        // A computed key is read even when its property is a write target.
+        let previous = std::mem::replace(&mut self.is_lhs, false);
+        node.expr.visit_mut_with(self);
+        self.is_lhs = previous;
+    }
+
+    fn visit_mut_for_head(&mut self, node: &mut ForHead) {
+        let previous = mem::replace(&mut self.is_lhs, true);
+        node.visit_mut_children_with(self);
+        self.is_lhs = previous;
+    }
+
     fn visit_mut_simple_assign_target(&mut self, node: &mut SimpleAssignTarget) {
-        while let SimpleAssignTarget::TsAs(TsAsExpr { expr, .. })
+        // A wrapped assignment still targets the same reference. Peel the
+        // entire chain before visiting its receiver and computed-key reads.
+        while let SimpleAssignTarget::Paren(ParenExpr { expr, .. })
+        | SimpleAssignTarget::TsAs(TsAsExpr { expr, .. })
         | SimpleAssignTarget::TsNonNull(TsNonNullExpr { expr, .. })
         | SimpleAssignTarget::TsTypeAssertion(TsTypeAssertion { expr, .. })
         | SimpleAssignTarget::TsInstantiation(TsInstantiation { expr, .. })
         | SimpleAssignTarget::TsSatisfies(TsSatisfiesExpr { expr, .. }) = node
         {
-            *node = expr.take().try_into().unwrap();
+            *node = expr
+                .take()
+                .try_into()
+                .expect("assignment-target wrappers must contain an assignable expression");
         }
 
         node.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_simple_assign_target(node);
         }
     }
@@ -520,7 +686,7 @@ impl VisitMut for Transform {
     fn visit_mut_jsx_element_name(&mut self, node: &mut JSXElementName) {
         node.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_jsx_element_name(node);
         }
     }
@@ -528,7 +694,7 @@ impl VisitMut for Transform {
     fn visit_mut_jsx_object(&mut self, node: &mut JSXObject) {
         node.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_jsx_object(node);
         }
     }
@@ -536,7 +702,7 @@ impl VisitMut for Transform {
     fn visit_mut_object_pat_prop(&mut self, n: &mut ObjectPatProp) {
         n.visit_mut_children_with(self);
 
-        if let Some(ref_rewriter) = self.ref_rewriter.as_mut() {
+        if let Some(mut ref_rewriter) = self.ref_rewriter() {
             ref_rewriter.exit_object_pat_prop(n);
         }
     }
@@ -616,10 +782,6 @@ impl VisitMut for Transform {
     }
 
     fn visit_mut_ts_module_block(&mut self, node: &mut TsModuleBlock) {
-        if !self.verbatim_module_syntax {
-            self.strip_namespace_module_items_with_semantic(&mut node.body);
-        }
-
         let in_namespace = mem::replace(&mut self.in_namespace, true);
         node.visit_mut_children_with(self);
         self.in_namespace = in_namespace;
@@ -672,8 +834,12 @@ impl VisitMut for Transform {
         node.visit_mut_children_with(self);
     }
 
-    fn visit_mut_ts_import_equals_decl(&mut self, _: &mut TsImportEqualsDecl) {
-        // id should be left intact for runtime rewriting
+    fn visit_mut_ts_import_equals_decl(&mut self, node: &mut TsImportEqualsDecl) {
+        if let TsModuleRef::TsEntityName(name) = &mut node.module_ref {
+            if let Some(rewriter) = self.ref_rewriter() {
+                rewriter.query.rewrite_entity_name(name);
+            }
+        }
     }
 
     fn visit_mut_ts_param_prop(&mut self, node: &mut TsParamProp) {
@@ -688,7 +854,7 @@ enum FoldedDecl {
     Expr(Stmt),
 }
 
-impl Transform {
+impl Transform<'_> {
     fn normalize_flow_static_constructor_key(
         &self,
         key: &mut PropName,
@@ -819,51 +985,8 @@ impl Transform {
                     return true;
                 }
 
-                self.semantic.has_usage(&ts_import_equals_decl.id.to_id())
-            }
-            ModuleItem::Stmt(Stmt::Decl(Decl::TsModule(ts_module))) if ts_module.body.is_some() => {
-                if let Some(body) = &mut ts_module.body {
-                    self.strip_namespace_body_with_semantic(body);
-                }
-
-                true
-            }
-            _ => true,
-        });
-    }
-
-    fn strip_namespace_body_with_semantic(&self, body: &mut TsNamespaceBody) {
-        match body {
-            TsNamespaceBody::TsModuleBlock(block) => {
-                self.strip_namespace_module_items_with_semantic(&mut block.body);
-
-                for module_item in &mut block.body {
-                    if let ModuleItem::Stmt(Stmt::Decl(Decl::TsModule(ts_module))) = module_item {
-                        if let Some(body) = &mut ts_module.body {
-                            self.strip_namespace_body_with_semantic(body);
-                        }
-                    }
-                }
-            }
-            TsNamespaceBody::TsNamespaceDecl(namespace_decl) => {
-                self.strip_namespace_body_with_semantic(&mut namespace_decl.body);
-            }
-            #[cfg(swc_ast_unknown)]
-            _ => panic!("unable to access unknown nodes"),
-        }
-    }
-
-    fn strip_namespace_module_items_with_semantic(&self, items: &mut Vec<ModuleItem>) {
-        items.retain(|module_item| match module_item {
-            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(ts_import_equals_decl)) => {
-                if ts_import_equals_decl.is_type_only {
-                    return false;
-                }
-
-                ts_import_equals_decl.is_export
-                    || self
-                        .semantic
-                        .has_namespace_import_equals_usage(ts_import_equals_decl.span)
+                self.semantic
+                    .has_import_equals_usage(&ts_import_equals_decl.id.to_id())
             }
             _ => true,
         });
@@ -872,6 +995,9 @@ impl Transform {
     fn fold_decl(&mut self, node: Decl, is_export: bool) -> FoldedDecl {
         match node {
             Decl::TsModule(ts_module) => {
+                if !self.namespace_state.is_instantiated() {
+                    return FoldedDecl::Empty;
+                }
                 let id = ts_module.id.to_id();
 
                 if self.decl_id_record.insert(id.clone()) {
@@ -1087,408 +1213,7 @@ impl InitArg<'_> {
     }
 }
 
-impl Transform {
-    fn transform_ts_enum(
-        &mut self,
-        ts_enum: TsEnumDecl,
-        is_first: bool,
-        is_export: bool,
-    ) -> FoldedDecl {
-        let TsEnumDecl {
-            span,
-            declare,
-            is_const,
-            id,
-            members,
-        } = ts_enum;
-
-        debug_assert!(!declare);
-
-        let ts_enum_safe_remove = !self.verbatim_module_syntax
-            && is_const
-            && !is_export
-            && !self.semantic.exported_binding.contains_key(&id.to_id());
-
-        let member_names = self
-            .semantic
-            .enum_record
-            .keys()
-            .filter(|k| k.enum_id == id.to_id())
-            .map(|k| k.member_name.clone())
-            .collect();
-
-        let enum_computer = EnumValueComputer {
-            enum_id: &id.to_id(),
-            unresolved_ctxt: self.unresolved_ctxt,
-            record: &self.semantic.enum_record,
-            const_vars: &self.semantic.const_vars,
-            const_enum_only: None,
-            ambient_record: &self.semantic.ambient_enum_record,
-            ambient_const_enum_only: None,
-        };
-
-        let member_list: Vec<_> = members
-            .into_iter()
-            .map(|m| {
-                let span = m.span;
-                let name = enum_member_name(&m.id);
-
-                let key = TsEnumRecordKey {
-                    enum_id: id.to_id(),
-                    member_name: name.clone(),
-                };
-
-                let mut value = self.semantic.enum_record.get(&key).unwrap().clone();
-
-                if matches!(value, TsEnumRecordValue::Opaque(..)) {
-                    if let Some(init) = m.init {
-                        // Recompute from the original initializer so enum member
-                        // references can be rewritten to runtime property
-                        // accesses. Implicit Flow enum members do not have an
-                        // initializer, so keep the semantic value as-is.
-                        let mut recomputed = enum_computer.compute(init, EvalCtx::RECOMPUTE);
-                        if let TsEnumRecordValue::Opaque(expr) = &mut recomputed {
-                            expr.visit_mut_with(&mut RefRewriter {
-                                query: EnumMemberRefQuery {
-                                    enum_id: &id.to_id(),
-                                    member_names: &member_names,
-                                    unresolved_ctxt: self.unresolved_ctxt,
-                                },
-                            });
-                        }
-                        value = recomputed;
-                    }
-                }
-
-                EnumMemberItem { span, name, value }
-            })
-            .filter(|m| !ts_enum_safe_remove || !m.is_const())
-            .collect();
-
-        if member_list.is_empty() && is_const {
-            return FoldedDecl::Empty;
-        }
-
-        let opaque = member_list
-            .iter()
-            .any(|item| matches!(item.value, TsEnumRecordValue::Opaque(..)));
-
-        let stmts = member_list
-            .into_iter()
-            .filter(|item| !ts_enum_safe_remove || !item.is_const())
-            .map(|item| item.build_assign(&id.to_id()));
-
-        let namespace_export = self.namespace_id.is_some() && is_export;
-        let iife = !is_first || namespace_export;
-
-        let body = if !iife {
-            let return_stmt: Stmt = ReturnStmt {
-                arg: Some(id.clone().into()),
-                ..Default::default()
-            }
-            .into();
-
-            let stmts = stmts.chain(iter::once(return_stmt)).collect();
-
-            BlockStmt {
-                stmts,
-                ..Default::default()
-            }
-        } else {
-            BlockStmt {
-                stmts: stmts.collect(),
-                ..Default::default()
-            }
-        };
-
-        let var_kind = if is_export || id.ctxt == self.top_level_ctxt {
-            VarDeclKind::Var
-        } else {
-            VarDeclKind::Let
-        };
-
-        let init_arg = 'init_arg: {
-            let init_arg = InitArg {
-                id: &id,
-                namespace_id: self.namespace_id.as_ref().filter(|_| is_export),
-            };
-            if !is_first {
-                break 'init_arg init_arg.get();
-            }
-
-            if namespace_export {
-                break 'init_arg init_arg.or_assign_empty();
-            }
-
-            if is_export || var_kind == VarDeclKind::Let {
-                InitArg::empty()
-            } else {
-                init_arg.or_empty()
-            }
-        };
-
-        let expr = Factory::function(vec![id.clone().into()], body).as_call(
-            if iife || opaque { DUMMY_SP } else { PURE_SP },
-            vec![init_arg],
-        );
-
-        if iife {
-            FoldedDecl::Expr(
-                ExprStmt {
-                    span,
-                    expr: expr.into(),
-                }
-                .into(),
-            )
-        } else {
-            let var_declarator = VarDeclarator {
-                span,
-                name: id.into(),
-                init: Some(expr.into()),
-                definite: false,
-            };
-
-            FoldedDecl::Decl(
-                VarDecl {
-                    span,
-                    kind: var_kind,
-                    decls: vec![var_declarator],
-                    ..Default::default()
-                }
-                .into(),
-            )
-        }
-    }
-}
-
-impl Transform {
-    fn transform_ts_module(&self, ts_module: TsModuleDecl, is_export: bool) -> FoldedDecl {
-        debug_assert!(!ts_module.declare);
-        debug_assert!(!ts_module.global);
-
-        let TsModuleDecl {
-            span,
-            id: TsModuleName::Ident(module_ident),
-            body: Some(body),
-            ..
-        } = ts_module
-        else {
-            unreachable!();
-        };
-
-        let body = Self::transform_ts_namespace_body(module_ident.to_id(), body);
-
-        let init_arg = InitArg {
-            id: &module_ident,
-            namespace_id: self.namespace_id.as_ref().filter(|_| is_export),
-        }
-        .or_assign_empty();
-
-        let expr = Factory::function(vec![module_ident.clone().into()], body)
-            .as_call(DUMMY_SP, vec![init_arg])
-            .into();
-
-        FoldedDecl::Expr(ExprStmt { span, expr }.into())
-    }
-
-    fn transform_ts_namespace_body(id: Id, body: TsNamespaceBody) -> BlockStmt {
-        let TsNamespaceDecl {
-            span,
-            declare,
-            global,
-            id: local_name,
-            body,
-        } = match body {
-            TsNamespaceBody::TsModuleBlock(ts_module_block) => {
-                return Self::transform_ts_module_block(id, ts_module_block);
-            }
-            TsNamespaceBody::TsNamespaceDecl(ts_namespace_decl) => ts_namespace_decl,
-            #[cfg(swc_ast_unknown)]
-            _ => panic!("unable to access unknown nodes"),
-        };
-
-        debug_assert!(!declare);
-        debug_assert!(!global);
-
-        let body = Self::transform_ts_namespace_body(local_name.to_id(), *body);
-
-        let init_arg = InitArg {
-            id: &local_name,
-            namespace_id: Some(&id.to_id()),
-        }
-        .or_assign_empty();
-
-        let expr =
-            Factory::function(vec![local_name.into()], body).as_call(DUMMY_SP, vec![init_arg]);
-
-        BlockStmt {
-            span,
-            stmts: vec![expr.into_stmt()],
-            ..Default::default()
-        }
-    }
-
-    /// Note:
-    /// All exported variable declarations are transformed into assignment to
-    /// the namespace. All references to the exported binding will be
-    /// replaced with qualified access to the namespace property.
-    ///
-    /// Exported function and class will be treat as const exported which is in
-    /// line with how the TypeScript compiler handles exports.
-    ///
-    /// Inline exported syntax should not be used with function which will lead
-    /// to issues with function hoisting.
-    ///
-    /// Input:
-    /// ```TypeScript
-    /// export const foo = init, { bar: baz = init } = init;
-    ///
-    /// export function a() {}
-    ///
-    /// export let b = init;
-    /// ```
-    ///
-    /// Output:
-    /// ```TypeScript
-    /// NS.foo = init, { bar: NS.baz = init } = init;
-    ///
-    /// function a() {}
-    /// NS.a = a;
-    ///
-    /// NS.b = init;
-    /// ```
-    fn transform_ts_module_block(id: Id, TsModuleBlock { span, body }: TsModuleBlock) -> BlockStmt {
-        let mut stmts = Vec::new();
-
-        for module_item in body {
-            match module_item {
-                ModuleItem::Stmt(stmt) => stmts.push(stmt),
-                ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
-                    decl, span, ..
-                })) => match decl {
-                    Decl::Class(ClassDecl { ref ident, .. })
-                    | Decl::Fn(FnDecl { ref ident, .. }) => {
-                        let assign_stmt = Self::assign_prop(&id, ident, span);
-                        stmts.push(decl.into());
-                        stmts.push(assign_stmt);
-                    }
-                    Decl::Var(var_decl) => {
-                        let mut exprs: Vec<Box<_>> = var_decl
-                            .decls
-                            .into_iter()
-                            .flat_map(
-                                |VarDeclarator {
-                                     span, name, init, ..
-                                 }| {
-                                    let right = init?;
-                                    let left = name.try_into().unwrap();
-
-                                    Some(
-                                        AssignExpr {
-                                            span,
-                                            left,
-                                            op: op!("="),
-                                            right,
-                                        }
-                                        .into(),
-                                    )
-                                },
-                            )
-                            .collect();
-
-                        if exprs.is_empty() {
-                            continue;
-                        }
-
-                        let expr = if exprs.len() == 1 {
-                            exprs.pop().unwrap()
-                        } else {
-                            SeqExpr {
-                                span: DUMMY_SP,
-                                exprs,
-                            }
-                            .into()
-                        };
-
-                        stmts.push(
-                            ExprStmt {
-                                span: var_decl.span,
-                                expr,
-                            }
-                            .into(),
-                        );
-                    }
-                    decl => unreachable!("{decl:?}"),
-                },
-                ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(decl)) => {
-                    match decl.module_ref {
-                        TsModuleRef::TsEntityName(ts_entity_name) => {
-                            let init = Self::ts_entity_name_to_expr(ts_entity_name);
-
-                            // export impot foo = bar.baz
-                            let stmt = if decl.is_export {
-                                // Foo.foo = bar.baz
-                                let left = id.clone().make_member(decl.id.clone().into());
-                                let expr = init.make_assign_to(op!("="), left.into());
-
-                                ExprStmt {
-                                    span: decl.span,
-                                    expr: expr.into(),
-                                }
-                                .into()
-                            } else {
-                                // const foo = bar.baz
-                                let mut var_decl =
-                                    init.into_var_decl(VarDeclKind::Const, decl.id.clone().into());
-
-                                var_decl.span = decl.span;
-
-                                var_decl.into()
-                            };
-
-                            stmts.push(stmt);
-                        }
-                        TsModuleRef::TsExternalModuleRef(..) => {
-                            // TS1147
-                            if HANDLER.is_set() {
-                                HANDLER.with(|handler| {
-                                    handler
-                                    .struct_span_err(
-                                        decl.span,
-                                        r#"Import declarations in a namespace cannot reference a module."#,
-                                    )
-                                    .emit();
-                                });
-                            }
-                        }
-                        #[cfg(swc_ast_unknown)]
-                        _ => panic!("unable to access unknown nodes"),
-                    }
-                }
-                item => {
-                    if HANDLER.is_set() {
-                        HANDLER.with(|handler| {
-                            handler
-                                .struct_span_err(
-                                    item.span(),
-                                    r#"ESM-style module declarations are not permitted in a namespace."#,
-                                )
-                                .emit();
-                        });
-                    }
-                }
-            }
-        }
-
-        BlockStmt {
-            span,
-            stmts,
-            ..Default::default()
-        }
-    }
-}
-
-impl Transform {
+impl Transform<'_> {
     fn reorder_class_prop_decls_and_inits(
         &mut self,
         class_member_list: &mut Vec<ClassMember>,
@@ -1608,7 +1333,7 @@ impl Transform {
     }
 }
 
-impl Transform {
+impl Transform<'_> {
     // Foo.x = x;
     fn assign_prop(id: &Id, prop: &Ident, span: Span) -> Stmt {
         let expr = prop
@@ -1641,40 +1366,7 @@ impl Transform {
     }
 }
 
-impl Transform {
-    fn enter_expr_for_inline_enum(&mut self, node: &mut Expr) {
-        if self.is_lhs {
-            return;
-        }
-
-        if let Expr::Member(MemberExpr { obj, prop, .. }) = node {
-            let Some(enum_id) = get_enum_id(obj) else {
-                return;
-            };
-
-            if self.ts_enum_is_mutable && !self.semantic.const_enum.contains(&enum_id) {
-                return;
-            }
-
-            let Some(member_name) = static_enum_member_name(prop) else {
-                return;
-            };
-
-            let key = TsEnumRecordKey {
-                enum_id,
-                member_name,
-            };
-
-            let Some(value) = self.semantic.enum_record.get(&key) else {
-                return;
-            };
-
-            if value.is_const() {
-                *node = value.clone().into();
-            }
-        }
-    }
-
+impl Transform<'_> {
     fn visit_mut_for_ts_import_export(&mut self, node: &mut Module) {
         let mut should_inject = false;
         let create_require = private_ident!("_createRequire");
@@ -1702,7 +1394,14 @@ impl Transform {
                     match &mut decl.module_ref {
                         // import foo = bar.baz
                         TsModuleRef::TsEntityName(ts_entity_name) => {
-                            let init = Self::ts_entity_name_to_expr(ts_entity_name.clone());
+                            let mut init = Self::ts_entity_name_to_expr(ts_entity_name.clone());
+                            if matches!(self.enum_inlining, EnumInlining::Applied) {
+                                // This expression did not exist during reference analysis.
+                                let enum_inlining =
+                                    mem::replace(&mut self.enum_inlining, EnumInlining::Emit);
+                                init.visit_mut_with(self);
+                                self.enum_inlining = enum_inlining;
+                            }
 
                             let mut var_decl =
                                 init.into_var_decl(VarDeclKind::Const, decl.id.take().into());
@@ -1881,119 +1580,6 @@ impl Transform {
     }
 }
 
-struct ExportQuery {
-    export_name: FxHashMap<Id, Option<Id>>,
-}
-
-impl QueryRef for ExportQuery {
-    fn query_ref(&self, export_name: &Ident) -> Option<Box<Expr>> {
-        self.export_name
-            .get(&export_name.to_id())?
-            .clone()
-            .map(|namespace_id| namespace_id.make_member(export_name.clone().into()).into())
-    }
-
-    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
-        self.query_ref(ident)
-    }
-
-    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
-        self.export_name
-            .get(&ident.to_id())?
-            .clone()
-            .map(|namespace_id| {
-                JSXMemberExpr {
-                    span: DUMMY_SP,
-                    obj: JSXObject::Ident(namespace_id.into()),
-                    prop: ident.clone().into(),
-                }
-                .into()
-            })
-    }
-}
-
-struct EnumMemberRefQuery<'a> {
-    enum_id: &'a Id,
-    member_names: &'a FxHashSet<Wtf8Atom>,
-    unresolved_ctxt: SyntaxContext,
-}
-
-impl QueryRef for EnumMemberRefQuery<'_> {
-    fn query_ref(&self, ident: &Ident) -> Option<Box<Expr>> {
-        if ident.ctxt == self.unresolved_ctxt && self.member_names.contains(ident.sym.borrow()) {
-            Some(
-                self.enum_id
-                    .clone()
-                    .make_member(ident.clone().into())
-                    .into(),
-            )
-        } else {
-            None
-        }
-    }
-
-    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
-        self.query_ref(ident)
-    }
-
-    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
-        if ident.ctxt == self.unresolved_ctxt && self.member_names.contains(ident.sym.borrow()) {
-            Some(
-                JSXMemberExpr {
-                    span: DUMMY_SP,
-                    obj: JSXObject::Ident(self.enum_id.clone().into()),
-                    prop: ident.clone().into(),
-                }
-                .into(),
-            )
-        } else {
-            None
-        }
-    }
-}
-
-struct EnumMemberItem {
-    span: Span,
-    name: Wtf8Atom,
-    value: TsEnumRecordValue,
-}
-
-impl EnumMemberItem {
-    fn is_const(&self) -> bool {
-        self.value.is_const()
-    }
-
-    fn build_assign(self, enum_id: &Id) -> Stmt {
-        let is_string = self.value.is_string();
-        let value: Expr = self.value.into();
-        let name: Expr = Str::from(self.name).into();
-
-        let inner_assign = value.make_assign_to(
-            op!("="),
-            Ident::from(enum_id.clone())
-                .computed_member(name.clone())
-                .into(),
-        );
-
-        let outer_assign = if is_string {
-            inner_assign
-        } else {
-            name.make_assign_to(
-                op!("="),
-                Ident::from(enum_id.clone())
-                    .computed_member(inner_assign)
-                    .into(),
-            )
-        };
-
-        ExprStmt {
-            span: self.span,
-            expr: outer_assign.into(),
-        }
-        .into()
-    }
-}
-
 trait ModuleId {
     fn to_id(&self) -> Id;
 }
@@ -2108,11 +1694,3 @@ fn id_to_var_declarator(id: Id) -> VarDeclarator {
         definite: false,
     }
 }
-
-fn get_enum_id(e: &Expr) -> Option<Id> {
-    if let Expr::Ident(ident) = e {
-        Some(ident.to_id())
-    } else {
-        None
-    }
-}
diff --git a/crates/swc_ecma_transforms_typescript/src/transform/enums.rs b/crates/swc_ecma_transforms_typescript/src/transform/enums.rs
new file mode 100644
index 0000000000000000000000000000000000000000..d0c21747317ea8a3fbb3df080c8078f0b52e8aa8
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/transform/enums.rs
@@ -0,0 +1,335 @@
+//! Enum initializer rewriting and runtime object emission.
+
+use std::iter;
+
+use rustc_hash::FxHashMap;
+use swc_atoms::Wtf8Atom;
+use swc_common::{source_map::PURE_SP, Mark, Span, SyntaxContext, DUMMY_SP};
+use swc_ecma_ast::*;
+use swc_ecma_utils::{
+    ts_bindings::{TsBindings, TsContainerId, TsMemberId},
+    ExprFactory, QueryRef, RefRewriter,
+};
+use swc_ecma_visit::VisitMutWith;
+
+use super::{ContainerContext, FoldedDecl, InitArg, Transform};
+use crate::{
+    semantic::{EnumDeclaration, EnumValue},
+    shared::enum_member_name,
+    utils::Factory,
+};
+
+/// State selected while visiting the initializer and consumed by lowering.
+pub(super) struct EnumEmission<'a> {
+    object: Id,
+    declaration: &'a EnumDeclaration,
+}
+
+impl<'a> Transform<'a> {
+    pub(super) fn visit_enum(&mut self, node: &mut TsEnumDecl) {
+        let declaration = self
+            .enum_bodies
+            .declaration(&self.semantic.bindings, node)
+            .expect("every retained enum declaration must have pre-erasure semantic facts");
+        // The emitted IIFE parameter is a JS binding of its own. Sharing the
+        // source enum's ID makes compressor inlining merge unrelated scopes.
+        let object = (
+            node.id.sym.clone(),
+            SyntaxContext::empty().apply_mark(Mark::new()),
+        );
+        // An enum IIFE has its own object parameter, but contributes no local
+        // enum binding to the surrounding namespace body's emitted scope.
+        self.container_contexts.push(ContainerContext {
+            container: declaration.container,
+            object: object.clone(),
+            locals: FxHashMap::default(),
+        });
+        node.members.visit_mut_with(self);
+        self.container_contexts.pop();
+        // Nested declarations consume their own state before this visit ends.
+        // The facts remain borrowed from immutable pre-erasure semantic storage.
+        self.enum_emissions.push(EnumEmission {
+            object,
+            declaration,
+        });
+    }
+}
+
+impl Transform<'_> {
+    pub(super) fn transform_ts_enum(
+        &mut self,
+        ts_enum: TsEnumDecl,
+        is_first: bool,
+        is_export: bool,
+    ) -> FoldedDecl {
+        let TsEnumDecl {
+            span,
+            declare,
+            is_const,
+            id,
+            members,
+        } = ts_enum;
+
+        debug_assert!(!declare);
+
+        let EnumEmission {
+            object,
+            declaration,
+        } = self
+            .enum_emissions
+            .pop()
+            .expect("enum lowering must consume the state selected by its preceding visit");
+        if self
+            .semantic
+            .enums
+            .can_erase(declaration.container, self.verbatim_module_syntax)
+            && !is_export
+            && !self.semantic.exported_binding.contains_key(&id.to_id())
+        {
+            return FoldedDecl::Empty;
+        }
+
+        let member_list: Vec<_> = members
+            .into_iter()
+            .enumerate()
+            .map(|(index, m)| {
+                let span = m.span;
+                let name = enum_member_name(&m.id);
+
+                let value = declaration.values.get(index).unwrap_or(&EnumValue::Unknown);
+                let is_string = value.is_string();
+                let is_constant = value.is_constant();
+                let mut expression = value
+                    .literal()
+                    .map(Box::new)
+                    .or(m.init)
+                    .unwrap_or_else(|| Expr::undefined(DUMMY_SP));
+                if !is_constant {
+                    expression.visit_mut_with(&mut RefRewriter {
+                        query: EnumMemberRefQuery {
+                            enum_id: &object,
+                            bindings: &self.semantic.bindings,
+                            owner: declaration.container,
+                            unresolved_ctxt: self.unresolved_ctxt,
+                        },
+                    });
+                }
+                EnumMemberItem {
+                    span,
+                    name,
+                    expression,
+                    is_string,
+                    is_constant,
+                }
+            })
+            .collect();
+
+        if member_list.is_empty() && is_const {
+            return FoldedDecl::Empty;
+        }
+
+        let opaque = member_list.iter().any(|item| !item.is_constant);
+
+        let stmts = member_list
+            .into_iter()
+            .map(|item| item.build_assign(&object));
+
+        let namespace_export = self.namespace_id.is_some() && is_export;
+        let iife = !is_first || namespace_export;
+
+        let body = if !iife {
+            let return_stmt: Stmt = ReturnStmt {
+                arg: Some(object.clone().into()),
+                ..Default::default()
+            }
+            .into();
+
+            let stmts = stmts.chain(iter::once(return_stmt)).collect();
+
+            BlockStmt {
+                stmts,
+                ..Default::default()
+            }
+        } else {
+            BlockStmt {
+                stmts: stmts.collect(),
+                ..Default::default()
+            }
+        };
+
+        let var_kind = if is_export || id.ctxt == self.top_level_ctxt {
+            VarDeclKind::Var
+        } else {
+            VarDeclKind::Let
+        };
+
+        let init_arg = 'init_arg: {
+            let init_arg = InitArg {
+                id: &id,
+                namespace_id: self.namespace_id.as_ref().filter(|_| is_export),
+            };
+            if !is_first {
+                break 'init_arg init_arg.get();
+            }
+
+            if namespace_export {
+                break 'init_arg init_arg.or_assign_empty();
+            }
+
+            if is_export || var_kind == VarDeclKind::Let {
+                InitArg::empty()
+            } else {
+                init_arg.or_empty()
+            }
+        };
+
+        let expr = Factory::function(vec![Ident::from(object).into()], body).as_call(
+            if iife || opaque { DUMMY_SP } else { PURE_SP },
+            vec![init_arg],
+        );
+
+        if iife {
+            FoldedDecl::Expr(
+                ExprStmt {
+                    span,
+                    expr: expr.into(),
+                }
+                .into(),
+            )
+        } else {
+            let var_declarator = VarDeclarator {
+                span,
+                name: id.into(),
+                init: Some(expr.into()),
+                definite: false,
+            };
+
+            FoldedDecl::Decl(
+                VarDecl {
+                    span,
+                    kind: var_kind,
+                    decls: vec![var_declarator],
+                    ..Default::default()
+                }
+                .into(),
+            )
+        }
+    }
+}
+
+impl Transform<'_> {
+    pub(super) fn enter_expr_for_inline_enum(&mut self, node: &mut Expr) {
+        if self.is_lhs {
+            return;
+        }
+        if let Some(value) = self
+            .semantic
+            .enums
+            .inline_module_value(
+                &self.semantic.bindings,
+                node,
+                self.ts_enum_is_mutable,
+                self.verbatim_module_syntax,
+            )
+            .and_then(EnumValue::literal)
+        {
+            *node = value;
+        }
+    }
+}
+
+struct EnumMemberRefQuery<'a> {
+    enum_id: &'a Id,
+    bindings: &'a TsBindings,
+    owner: TsContainerId,
+    unresolved_ctxt: SyntaxContext,
+}
+
+impl QueryRef for EnumMemberRefQuery<'_> {
+    fn query_ref(&self, ident: &Ident) -> Option<Box<Expr>> {
+        if self.member(ident).is_some() {
+            Some(
+                self.enum_id
+                    .clone()
+                    .make_member(ident.clone().into())
+                    .into(),
+            )
+        } else {
+            None
+        }
+    }
+
+    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
+        self.member(ident).map(|_| {
+            self.enum_id
+                .clone()
+                .make_member(ident.clone().into())
+                .into()
+        })
+    }
+
+    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
+        if self.member(ident).is_some() {
+            Some(
+                JSXMemberExpr {
+                    span: DUMMY_SP,
+                    obj: JSXObject::Ident(self.enum_id.clone().into()),
+                    prop: ident.clone().into(),
+                }
+                .into(),
+            )
+        } else {
+            None
+        }
+    }
+}
+
+impl EnumMemberRefQuery<'_> {
+    fn member(&self, ident: &Ident) -> Option<TsMemberId> {
+        if ident.ctxt != self.unresolved_ctxt {
+            return None;
+        }
+        self.bindings
+            .named_member(self.owner, &ident.sym.clone().into())
+            .filter(|member| self.bindings.member(*member).is_enum_member())
+    }
+}
+
+struct EnumMemberItem {
+    span: Span,
+    name: Wtf8Atom,
+    expression: Box<Expr>,
+    is_string: bool,
+    is_constant: bool,
+}
+
+impl EnumMemberItem {
+    fn build_assign(self, enum_id: &Id) -> Stmt {
+        let value = *self.expression;
+        let name: Expr = Str::from(self.name).into();
+
+        let inner_assign = value.make_assign_to(
+            op!("="),
+            Ident::from(enum_id.clone())
+                .computed_member(name.clone())
+                .into(),
+        );
+
+        let outer_assign = if self.is_string {
+            inner_assign
+        } else {
+            name.make_assign_to(
+                op!("="),
+                Ident::from(enum_id.clone())
+                    .computed_member(inner_assign)
+                    .into(),
+            )
+        };
+
+        ExprStmt {
+            span: self.span,
+            expr: outer_assign.into(),
+        }
+        .into()
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/transform/exports.rs b/crates/swc_ecma_transforms_typescript/src/transform/exports.rs
new file mode 100644
index 0000000000000000000000000000000000000000..22d491f7cc429905cd2d2c500b4b45aa63553aac
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/transform/exports.rs
@@ -0,0 +1,149 @@
+//! Runtime references under the currently emitted namespace or enum owner.
+
+use rustc_hash::FxHashMap;
+use swc_ecma_ast::*;
+use swc_ecma_utils::{ts_bindings::TsBindings, ExprFactory, QueryRef};
+
+use super::ContainerContext;
+
+enum RuntimeAccess<'a> {
+    Local(&'a Id),
+    NamespaceProperty(&'a Id),
+}
+
+pub(super) struct ExportQuery<'a, 'semantic> {
+    export_name: &'a FxHashMap<Id, Option<Id>>,
+    bindings: &'a TsBindings,
+    contexts: &'a [ContainerContext<'semantic>],
+    has_legacy_exports: bool,
+}
+
+impl<'a, 'semantic> ExportQuery<'a, 'semantic> {
+    pub(super) fn new(
+        export_name: &'a FxHashMap<Id, Option<Id>>,
+        bindings: &'a TsBindings,
+        contexts: &'a [ContainerContext<'semantic>],
+        has_legacy_exports: bool,
+    ) -> Self {
+        Self {
+            export_name,
+            bindings,
+            contexts,
+            has_legacy_exports,
+        }
+    }
+
+    fn runtime_access(&self, ident: &Ident) -> Option<RuntimeAccess<'_>> {
+        if self.contexts.is_empty() {
+            // Outside emitted containers only the legacy export fallback can
+            // apply. Check its smaller index before looking up a declaration;
+            // a shared member still requires a current emitted owner.
+            let id = ident.to_id();
+            let object = self.export_name.get(&id)?.as_ref()?;
+            return self
+                .bindings
+                .member_of(&id)
+                .is_none()
+                .then_some(RuntimeAccess::NamespaceProperty(object));
+        }
+        // Query resolved identities directly: spelling buckets would scan
+        // unrelated lexical bindings. Only declared identities can name a
+        // current emitted owner; unindexed exports keep their legacy fallback.
+        if let Some(declaration) = self.bindings.ident_declaration(ident) {
+            let container = self.bindings.declaration_container(declaration);
+            let member = self.bindings.declaration_member(declaration);
+
+            for context in self.contexts.iter().rev() {
+                if container == Some(context.container) {
+                    return Some(RuntimeAccess::Local(&context.object));
+                }
+
+                if let Some(member) = member {
+                    if self.bindings.member(member).owner == context.container {
+                        return Some(match context.locals.get(&member) {
+                            Some(local) => RuntimeAccess::Local(local),
+                            None => RuntimeAccess::NamespaceProperty(&context.object),
+                        });
+                    }
+                }
+            }
+
+            // A shared namespace member requires a current emitted owner.
+            // Never reuse another declaration body's object parameter.
+            if member.is_some() {
+                return None;
+            }
+        }
+        if !self.has_legacy_exports {
+            return None;
+        }
+        self.export_name
+            .get(&ident.to_id())?
+            .as_ref()
+            .map(RuntimeAccess::NamespaceProperty)
+    }
+
+    pub(super) fn rewrite_entity_name(&self, name: &mut TsEntityName) {
+        match name {
+            TsEntityName::TsQualifiedName(qualified) => {
+                self.rewrite_entity_name(&mut qualified.left);
+            }
+            TsEntityName::Ident(ident) => match self.runtime_access(ident) {
+                Some(RuntimeAccess::Local(local)) => {
+                    ident.sym = local.0.clone();
+                    ident.ctxt = local.1;
+                }
+                Some(RuntimeAccess::NamespaceProperty(object)) => {
+                    let qualified = TsQualifiedName {
+                        span: ident.span,
+                        left: TsEntityName::Ident(Ident::new(
+                            object.0.clone(),
+                            ident.span,
+                            object.1,
+                        )),
+                        right: ident.clone().into(),
+                    };
+                    *name = TsEntityName::TsQualifiedName(Box::new(qualified));
+                }
+                None => {}
+            },
+            #[cfg(swc_ast_unknown)]
+            _ => {}
+        }
+    }
+}
+
+impl QueryRef for ExportQuery<'_, '_> {
+    fn query_ref(&self, ident: &Ident) -> Option<Box<Expr>> {
+        match self.runtime_access(ident)? {
+            RuntimeAccess::Local(local) if local.0 != ident.sym || local.1 != ident.ctxt => {
+                Some(Ident::new(local.0.clone(), ident.span, local.1).into())
+            }
+            RuntimeAccess::Local(_) => None,
+            RuntimeAccess::NamespaceProperty(object) => {
+                Some(object.clone().make_member(ident.clone().into()).into())
+            }
+        }
+    }
+
+    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
+        self.query_ref(ident)
+    }
+
+    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
+        match self.runtime_access(ident)? {
+            RuntimeAccess::Local(local) if local.0 != ident.sym || local.1 != ident.ctxt => Some(
+                JSXElementName::Ident(Ident::new(local.0.clone(), ident.span, local.1)),
+            ),
+            RuntimeAccess::Local(_) => None,
+            RuntimeAccess::NamespaceProperty(object) => Some(
+                JSXMemberExpr {
+                    span: ident.span,
+                    obj: JSXObject::Ident(Ident::new(object.0.clone(), ident.span, object.1)),
+                    prop: ident.clone().into(),
+                }
+                .into(),
+            ),
+        }
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/transform/namespaces.rs b/crates/swc_ecma_transforms_typescript/src/transform/namespaces.rs
new file mode 100644
index 0000000000000000000000000000000000000000..9bbf8791672c7a9564a7b6e0ee48c88c32b141c6
--- /dev/null
+++ b/crates/swc_ecma_transforms_typescript/src/transform/namespaces.rs
@@ -0,0 +1,468 @@
+//! Namespace instantiation and runtime emission. Contributions are recorded
+//! before erasure and combined bottom up during the emission walk.
+//! Ambient value declarations instantiate their enclosing namespace even though
+//! they do not emit statements themselves.
+
+use rustc_hash::FxHashMap;
+use swc_common::{errors::HANDLER, Spanned, DUMMY_SP};
+use swc_ecma_ast::*;
+use swc_ecma_utils::ExprFactory;
+use swc_ecma_visit::VisitMutWith;
+
+use super::{ContainerContext, FoldedDecl, InitArg, Transform};
+use crate::{
+    retain::{should_retain_decl, should_retain_module_item},
+    utils::Factory,
+};
+
+/// The contribution of one declaration body, before applying its own `declare`
+/// modifier. Const-enum-only bodies additionally depend on runtime references;
+/// pure type bodies stay erased even when another declaration shares their
+/// name.
+#[derive(Clone, Copy, Default)]
+pub(super) enum NamespaceInstantiation {
+    #[default]
+    NonInstantiated,
+    ConstEnumOnly,
+    Instantiated,
+}
+
+impl NamespaceInstantiation {
+    pub(super) fn combine(self, other: Self) -> Self {
+        match (self, other) {
+            (Self::Instantiated, _) | (_, Self::Instantiated) => Self::Instantiated,
+            (Self::ConstEnumOnly, _) | (_, Self::ConstEnumOnly) => Self::ConstEnumOnly,
+            _ => Self::NonInstantiated,
+        }
+    }
+
+    pub(super) fn is_instantiated(&self) -> bool {
+        matches!(self, Self::Instantiated)
+    }
+}
+
+impl<'a> Transform<'a> {
+    /// Accumulate each body's runtime contribution before erasure and reuse
+    /// completed child results without recursively rescanning retained bodies.
+    pub(super) fn visit_namespace_items(
+        &mut self,
+        node: &mut Vec<ModuleItem>,
+    ) -> NamespaceInstantiation {
+        let mut namespace_state = NamespaceInstantiation::default();
+        node.retain_mut(|item| {
+            let is_namespace = matches!(
+                item,
+                ModuleItem::Stmt(Stmt::Decl(Decl::TsModule(_)))
+                    | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+                        decl: Decl::TsModule(_),
+                        ..
+                    }))
+            );
+            let retain = self.retain_module_item(item);
+            // Capture contributions before erasure; retained child namespaces
+            // supply their completed body result after the ordinary walk.
+            let contribution = (!(namespace_state.is_instantiated() || is_namespace && retain))
+                .then(|| self.namespace_item_instantiation(item));
+            if let Some(contribution) = contribution {
+                namespace_state = namespace_state.combine(contribution);
+            }
+            if !retain {
+                return false;
+            }
+            let is_empty = item.as_stmt().map(Stmt::is_empty).unwrap_or(false);
+            item.visit_mut_with(self);
+            if is_namespace {
+                namespace_state = namespace_state.combine(self.namespace_state);
+            }
+            // Remove those folded into Empty
+            is_empty || !item.as_stmt().map(Stmt::is_empty).unwrap_or(false)
+        });
+        namespace_state
+    }
+
+    pub(super) fn namespace_context(
+        &self,
+        object: Id,
+        body: &TsNamespaceBody,
+    ) -> Option<ContainerContext<'a>> {
+        let bindings = &self.semantic.bindings;
+        let container = bindings.container(&object)?;
+        let mut locals = FxHashMap::default();
+
+        if let TsNamespaceBody::TsModuleBlock(body) = body {
+            for item in &body.body {
+                let ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(decl)) = item else {
+                    continue;
+                };
+                let ident = match &decl.decl {
+                    Decl::Fn(decl) => &decl.ident,
+                    Decl::Class(decl) => &decl.ident,
+                    _ => continue,
+                };
+                if !should_retain_decl(&decl.decl) {
+                    continue;
+                }
+                let Some(declaration) = bindings.ident_declaration(ident) else {
+                    continue;
+                };
+                let Some(member) = bindings.declaration_member(declaration) else {
+                    continue;
+                };
+                locals.insert(member, bindings.declaration(declaration));
+            }
+        }
+
+        Some(ContainerContext {
+            container,
+            object,
+            locals,
+        })
+    }
+
+    pub(super) fn namespace_instantiation(
+        &self,
+        declaration: &TsModuleDecl,
+    ) -> NamespaceInstantiation {
+        if declaration.global {
+            return NamespaceInstantiation::NonInstantiated;
+        }
+        let Some(body) = &declaration.body else {
+            return NamespaceInstantiation::Instantiated;
+        };
+        let state = self.namespace_body_instantiation(body);
+        match &declaration.id {
+            TsModuleName::Ident(id) => self.namespace_instantiation_with_usage(id, state),
+            _ => state,
+        }
+    }
+
+    pub(super) fn namespace_instantiation_with_usage(
+        &self,
+        id: &Ident,
+        state: NamespaceInstantiation,
+    ) -> NamespaceInstantiation {
+        if matches!(state, NamespaceInstantiation::ConstEnumOnly) {
+            let required = self
+                .semantic
+                .bindings
+                .container(&id.to_id())
+                .is_some_and(|container| self.semantic.runtime_containers.contains(&container));
+            if required {
+                return NamespaceInstantiation::Instantiated;
+            }
+        }
+        state
+    }
+
+    fn namespace_body_instantiation(&self, body: &TsNamespaceBody) -> NamespaceInstantiation {
+        match body {
+            TsNamespaceBody::TsNamespaceDecl(declaration) => {
+                let state = self.namespace_body_instantiation(&declaration.body);
+                self.namespace_instantiation_with_usage(&declaration.id, state)
+            }
+            TsNamespaceBody::TsModuleBlock(block) => {
+                let mut state = NamespaceInstantiation::NonInstantiated;
+                for item in &block.body {
+                    match self.namespace_item_instantiation(item) {
+                        NamespaceInstantiation::Instantiated => {
+                            return NamespaceInstantiation::Instantiated;
+                        }
+                        NamespaceInstantiation::ConstEnumOnly => {
+                            state = NamespaceInstantiation::ConstEnumOnly;
+                        }
+                        NamespaceInstantiation::NonInstantiated => {}
+                    }
+                }
+                state
+            }
+            #[cfg(swc_ast_unknown)]
+            _ => NamespaceInstantiation::NonInstantiated,
+        }
+    }
+
+    pub(super) fn namespace_item_instantiation(&self, item: &ModuleItem) -> NamespaceInstantiation {
+        match item {
+            ModuleItem::Stmt(Stmt::Decl(declaration))
+            | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+                decl: declaration,
+                ..
+            })) => match declaration {
+                Decl::TsInterface(_) | Decl::TsTypeAlias(_) => {
+                    NamespaceInstantiation::NonInstantiated
+                }
+                Decl::TsModule(declaration) => self.namespace_instantiation(declaration),
+                Decl::TsEnum(declaration) => {
+                    let ambient_const =
+                        declaration.declare && declaration.is_const && !self.verbatim_module_syntax;
+                    if ambient_const || self.can_erase_enum(declaration) {
+                        NamespaceInstantiation::ConstEnumOnly
+                    } else {
+                        NamespaceInstantiation::Instantiated
+                    }
+                }
+                // A value declaration contributes even if it is ambient or a
+                // function signature with no body. Its own erasure is separate.
+                _ => NamespaceInstantiation::Instantiated,
+            },
+            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(declaration)) => {
+                // Exported aliases instantiate their namespace even when a
+                // type-only target erases the alias assignment.
+                let instantiates = !declaration.is_type_only
+                    && (declaration.is_export
+                        || self
+                            .semantic
+                            .has_import_equals_usage(&declaration.id.to_id()));
+                if instantiates {
+                    NamespaceInstantiation::Instantiated
+                } else {
+                    NamespaceInstantiation::NonInstantiated
+                }
+            }
+            _ if should_retain_module_item(item) => NamespaceInstantiation::Instantiated,
+            _ => NamespaceInstantiation::NonInstantiated,
+        }
+    }
+
+    pub(super) fn can_erase_enum(&self, declaration: &TsEnumDecl) -> bool {
+        self.semantic
+            .bindings
+            .ident_declaration(&declaration.id)
+            .and_then(|id| self.semantic.bindings.declaration_container(id))
+            .is_some_and(|container| {
+                self.semantic
+                    .enums
+                    .can_erase(container, self.verbatim_module_syntax)
+            })
+    }
+}
+
+impl Transform<'_> {
+    pub(super) fn transform_ts_module(
+        &self,
+        ts_module: TsModuleDecl,
+        is_export: bool,
+    ) -> FoldedDecl {
+        debug_assert!(!ts_module.declare);
+        debug_assert!(!ts_module.global);
+
+        let TsModuleDecl {
+            span,
+            id: TsModuleName::Ident(module_ident),
+            body: Some(body),
+            ..
+        } = ts_module
+        else {
+            unreachable!();
+        };
+
+        let body = Self::transform_ts_namespace_body(module_ident.to_id(), body);
+
+        let init_arg = InitArg {
+            id: &module_ident,
+            namespace_id: self.namespace_id.as_ref().filter(|_| is_export),
+        }
+        .or_assign_empty();
+
+        let expr = Factory::function(vec![module_ident.clone().into()], body)
+            .as_call(DUMMY_SP, vec![init_arg])
+            .into();
+
+        FoldedDecl::Expr(ExprStmt { span, expr }.into())
+    }
+
+    fn transform_ts_namespace_body(id: Id, body: TsNamespaceBody) -> BlockStmt {
+        let TsNamespaceDecl {
+            span,
+            declare,
+            global,
+            id: local_name,
+            body,
+        } = match body {
+            TsNamespaceBody::TsModuleBlock(ts_module_block) => {
+                return Self::transform_ts_module_block(id, ts_module_block);
+            }
+            TsNamespaceBody::TsNamespaceDecl(ts_namespace_decl) => ts_namespace_decl,
+            #[cfg(swc_ast_unknown)]
+            _ => panic!("unable to access unknown nodes"),
+        };
+
+        debug_assert!(!declare);
+        debug_assert!(!global);
+
+        let body = Self::transform_ts_namespace_body(local_name.to_id(), *body);
+
+        let init_arg = InitArg {
+            id: &local_name,
+            namespace_id: Some(&id),
+        }
+        .or_assign_empty();
+
+        let expr =
+            Factory::function(vec![local_name.into()], body).as_call(DUMMY_SP, vec![init_arg]);
+
+        BlockStmt {
+            span,
+            stmts: vec![expr.into_stmt()],
+            ..Default::default()
+        }
+    }
+
+    /// Note:
+    /// All exported variable declarations are transformed into assignment to
+    /// the namespace. All references to the exported binding will be
+    /// replaced with qualified access to the namespace property.
+    ///
+    /// Exported function and class will be treat as const exported which is in
+    /// line with how the TypeScript compiler handles exports.
+    ///
+    /// Inline exported syntax should not be used with function which will lead
+    /// to issues with function hoisting.
+    ///
+    /// Input:
+    /// ```TypeScript
+    /// export const foo = init, { bar: baz = init } = init;
+    ///
+    /// export function a() {}
+    ///
+    /// export let b = init;
+    /// ```
+    ///
+    /// Output:
+    /// ```TypeScript
+    /// NS.foo = init, { bar: NS.baz = init } = init;
+    ///
+    /// function a() {}
+    /// NS.a = a;
+    ///
+    /// NS.b = init;
+    /// ```
+    fn transform_ts_module_block(id: Id, TsModuleBlock { span, body }: TsModuleBlock) -> BlockStmt {
+        let mut stmts = Vec::new();
+
+        for module_item in body {
+            match module_item {
+                ModuleItem::Stmt(stmt) => stmts.push(stmt),
+                ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+                    decl, span, ..
+                })) => match decl {
+                    Decl::Class(ClassDecl { ref ident, .. })
+                    | Decl::Fn(FnDecl { ref ident, .. }) => {
+                        let assign_stmt = Self::assign_prop(&id, ident, span);
+                        stmts.push(decl.into());
+                        stmts.push(assign_stmt);
+                    }
+                    Decl::Var(var_decl) => {
+                        let mut exprs: Vec<Box<_>> = var_decl
+                            .decls
+                            .into_iter()
+                            .flat_map(
+                                |VarDeclarator {
+                                     span, name, init, ..
+                                 }| {
+                                    let right = init?;
+                                    let left = name.try_into().unwrap();
+
+                                    Some(
+                                        AssignExpr {
+                                            span,
+                                            left,
+                                            op: op!("="),
+                                            right,
+                                        }
+                                        .into(),
+                                    )
+                                },
+                            )
+                            .collect();
+
+                        if exprs.is_empty() {
+                            continue;
+                        }
+
+                        let expr = if exprs.len() == 1 {
+                            exprs.pop().unwrap()
+                        } else {
+                            SeqExpr {
+                                span: DUMMY_SP,
+                                exprs,
+                            }
+                            .into()
+                        };
+
+                        stmts.push(
+                            ExprStmt {
+                                span: var_decl.span,
+                                expr,
+                            }
+                            .into(),
+                        );
+                    }
+                    decl => unreachable!("{decl:?}"),
+                },
+                ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(decl)) => {
+                    match decl.module_ref {
+                        TsModuleRef::TsEntityName(ts_entity_name) => {
+                            let init = Self::ts_entity_name_to_expr(ts_entity_name);
+
+                            // export import foo = bar.baz
+                            let stmt = if decl.is_export {
+                                // Foo.foo = bar.baz
+                                let left = id.clone().make_member(decl.id.clone().into());
+                                let expr = init.make_assign_to(op!("="), left.into());
+
+                                ExprStmt {
+                                    span: decl.span,
+                                    expr: expr.into(),
+                                }
+                                .into()
+                            } else {
+                                // const foo = bar.baz
+                                let mut var_decl =
+                                    init.into_var_decl(VarDeclKind::Const, decl.id.clone().into());
+
+                                var_decl.span = decl.span;
+
+                                var_decl.into()
+                            };
+
+                            stmts.push(stmt);
+                        }
+                        TsModuleRef::TsExternalModuleRef(..) => {
+                            // TS1147
+                            if HANDLER.is_set() {
+                                HANDLER.with(|handler| {
+                                    handler
+                                    .struct_span_err(
+                                        decl.span,
+                                        r#"Import declarations in a namespace cannot reference a module."#,
+                                    )
+                                    .emit();
+                                });
+                            }
+                        }
+                        #[cfg(swc_ast_unknown)]
+                        _ => panic!("unable to access unknown nodes"),
+                    }
+                }
+                item => {
+                    if HANDLER.is_set() {
+                        HANDLER.with(|handler| {
+                            handler
+                                .struct_span_err(
+                                    item.span(),
+                                    r#"ESM-style module declarations are not permitted in a namespace."#,
+                                )
+                                .emit();
+                        });
+                    }
+                }
+            }
+        }
+
+        BlockStmt {
+            span,
+            stmts,
+            ..Default::default()
+        }
+    }
+}
diff --git a/crates/swc_ecma_transforms_typescript/src/ts_enum.rs b/crates/swc_ecma_transforms_typescript/src/ts_enum.rs
deleted file mode 100644
index 1e9a28d65114c4a4a7e788f43e7f54df60eeceaa..0000000000000000000000000000000000000000
--- a/crates/swc_ecma_transforms_typescript/src/ts_enum.rs
+++ /dev/null
@@ -1,481 +0,0 @@
-use rustc_hash::{FxHashMap, FxHashSet};
-use swc_atoms::{wtf8::Wtf8Buf, Atom, Wtf8Atom};
-use swc_common::{SyntaxContext, DUMMY_SP};
-use swc_ecma_ast::*;
-use swc_ecma_utils::{
-    number::{JsNumber, ToJsString},
-    ExprFactory,
-};
-
-#[derive(Debug, Clone, PartialEq, Eq, Hash)]
-pub(crate) struct TsEnumRecordKey {
-    pub enum_id: Id,
-    pub member_name: Wtf8Atom,
-}
-
-pub(crate) type TsEnumRecord = FxHashMap<TsEnumRecordKey, TsEnumRecordValue>;
-
-#[derive(Debug, Clone)]
-pub(crate) enum TsEnumRecordValue {
-    String(Wtf8Atom),
-    Number(Number),
-    Opaque(Box<Expr>),
-    Void,
-}
-
-impl TsEnumRecordValue {
-    /// Creates a computed number. Computations intentionally discard source
-    /// spelling so code generation can choose the canonical representation.
-    fn number(value: impl Into<f64>) -> Self {
-        Self::Number(Number {
-            span: DUMMY_SP,
-            value: value.into(),
-            raw: None,
-        })
-    }
-
-    /// Creates a number converted directly from an AST value.
-    fn converted_number(value: impl Into<f64>, raw: Option<Atom>) -> Self {
-        Self::Number(Number {
-            span: DUMMY_SP,
-            value: value.into(),
-            raw,
-        })
-    }
-
-    pub fn inc(&self) -> Self {
-        match self {
-            Self::Number(num) => Self::number(num.value + 1.0),
-            _ => Self::Void,
-        }
-    }
-
-    pub fn is_const(&self) -> bool {
-        matches!(
-            self,
-            TsEnumRecordValue::String(..) | TsEnumRecordValue::Number(..)
-        )
-    }
-
-    pub fn is_string(&self) -> bool {
-        matches!(self, TsEnumRecordValue::String(..))
-    }
-
-    pub fn has_value(&self) -> bool {
-        !matches!(self, TsEnumRecordValue::Void)
-    }
-
-    fn push_to_string(&self, output: &mut Wtf8Buf) -> bool {
-        match self {
-            Self::String(value) => output.push_wtf8(value),
-            Self::Number(value) => output.push_str(&value.value.to_js_string()),
-            Self::Opaque(_) | Self::Void => return false,
-        }
-
-        true
-    }
-}
-
-impl From<TsEnumRecordValue> for Expr {
-    fn from(value: TsEnumRecordValue) -> Self {
-        match value {
-            TsEnumRecordValue::String(string) => Lit::Str(string.into()).into(),
-            TsEnumRecordValue::Number(num) => Lit::Num(num).into(),
-            TsEnumRecordValue::Void => *Expr::undefined(DUMMY_SP),
-            TsEnumRecordValue::Opaque(expr) => *expr,
-        }
-    }
-}
-
-impl From<f64> for TsEnumRecordValue {
-    fn from(value: f64) -> Self {
-        Self::number(value)
-    }
-}
-
-pub(crate) struct EnumValueComputer<'a> {
-    pub enum_id: &'a Id,
-    pub unresolved_ctxt: SyntaxContext,
-    pub record: &'a TsEnumRecord,
-    pub const_vars: &'a FxHashMap<Id, TsEnumRecordValue>,
-    /// When `Some`, only enums in this set may be resolved through a member
-    /// expression.
-    ///
-    /// Mirrors the `ts_enum_is_mutable` guard in `transform.rs`: a non-const
-    /// enum can be reassigned at runtime, so reads of its members are not
-    /// compile-time constants and must stay opaque.
-    pub const_enum_only: Option<&'a FxHashSet<Id>>,
-    /// Members of ambient (`declare`) enums. Kept separate from `record` so
-    /// only the evaluator sees them: `tsc` folds them inside enum and const
-    /// initializers but never rewrites runtime reads of the ambient object,
-    /// and the inliner keys on `record` membership.
-    pub ambient_record: &'a TsEnumRecord,
-    /// Applied to the ambient fallback only: under `tsEnumIsMutable` a plain
-    /// ambient enum is a runtime object that can be reassigned like any other
-    /// non-const enum, so only ambient `const enum` members may resolve.
-    /// Unlike `const_enum_only`, this does not touch the primary record — how
-    /// concrete enum reads behave under the option predates the ambient
-    /// support (see swc-project/swc#12151).
-    pub ambient_const_enum_only: Option<&'a FxHashSet<Id>>,
-}
-
-/// Returns a statically known enum member key without discarding lone
-/// surrogates.
-pub(crate) fn static_enum_member_name(property: &MemberProp) -> Option<Wtf8Atom> {
-    match property {
-        MemberProp::Ident(ident) => Some(ident.sym.clone().into()),
-        MemberProp::Computed(ComputedPropName { expr, .. }) => match &**expr {
-            Expr::Lit(Lit::Str(string)) => Some(string.value.clone()),
-            Expr::Tpl(template) if template.exprs.is_empty() && template.quasis.len() == 1 => {
-                template.quasis[0].cooked.clone()
-            }
-            _ => None,
-        },
-        MemberProp::PrivateName(_) => None,
-        #[cfg(swc_ast_unknown)]
-        _ => panic!("unable to access unknown nodes"),
-    }
-}
-
-/// Evaluation context for [`EnumValueComputer::compute_rec`].
-///
-/// TypeScript decides enum member constness from the *syntactic* form of the
-/// initializer, without type resolution. See
-/// https://github.com/microsoft/TypeScript/pull/50528 and the constraints
-/// described in https://github.com/evanw/esbuild/issues/4387.
-#[derive(Clone, Copy)]
-pub(crate) struct EvalCtx {
-    /// Whether a reference to a `const` binding may be resolved to its value.
-    /// Disabled under type syntax: `enum E { A = foo as string }` is not a
-    /// constant for TypeScript even when `foo` is.
-    allow_const_var: bool,
-    /// Whether type syntax makes the whole expression non-constant instead of
-    /// being stripped. Used when evaluating a `const` initializer, where any
-    /// annotation or assertion removes constness.
-    ts_is_opaque: bool,
-}
-
-impl EvalCtx {
-    /// Context for a `const` variable initializer.
-    pub(crate) const CONST_INIT: Self = Self {
-        allow_const_var: true,
-        ts_is_opaque: true,
-    };
-    /// Context for an enum member initializer.
-    pub(crate) const MEMBER: Self = Self {
-        allow_const_var: true,
-        ts_is_opaque: false,
-    };
-    /// Context for re-computing a member whose value the pre-pass already
-    /// classified as non-constant. Resolving `const` bindings here would
-    /// override that verdict: the binding map is complete by this point, and
-    /// type assertions have already been stripped from the initializer.
-    pub(crate) const RECOMPUTE: Self = Self {
-        allow_const_var: false,
-        ts_is_opaque: false,
-    };
-}
-
-/// https://github.com/microsoft/TypeScript/pull/50528
-impl EnumValueComputer<'_> {
-    /// Whether [`Self::compute`] could fold this expression at all, decided
-    /// from its outermost form alone.
-    ///
-    /// `compute` takes the expression by value, so evaluating an initializer
-    /// means cloning it. Every form not listed here hits the `Opaque`
-    /// catch-all immediately, and `const` initializers in real TypeScript are
-    /// mostly arrow functions, object literals and calls — cloning those to
-    /// discard the result dominated the cost of the collection pass.
-    ///
-    /// Kept in sync with the arms of `compute_rec`. An omission here can only
-    /// under-fold; it can never produce a wrong value.
-    pub fn can_fold_shape(expr: &Expr) -> bool {
-        matches!(
-            expr,
-            Expr::Lit(..)
-                | Expr::Ident(..)
-                | Expr::Paren(..)
-                | Expr::Unary(..)
-                | Expr::Bin(..)
-                | Expr::Member(..)
-                | Expr::OptChain(..)
-                | Expr::Tpl(..)
-                | Expr::TsAs(..)
-                | Expr::TsNonNull(..)
-                | Expr::TsTypeAssertion(..)
-                | Expr::TsConstAssertion(..)
-                | Expr::TsInstantiation(..)
-                | Expr::TsSatisfies(..)
-        )
-    }
-
-    pub fn compute(&self, expr: Box<Expr>, ctx: EvalCtx) -> TsEnumRecordValue {
-        self.compute_rec(expr, ctx)
-    }
-
-    fn compute_rec(&self, expr: Box<Expr>, ctx: EvalCtx) -> TsEnumRecordValue {
-        match *expr {
-            Expr::Lit(Lit::Str(s)) => TsEnumRecordValue::String(s.value),
-            Expr::Lit(Lit::Num(n)) => TsEnumRecordValue::Number(n),
-            Expr::Ident(ref ident) if ident.ctxt == self.unresolved_ctxt => {
-                let key = TsEnumRecordKey {
-                    enum_id: self.enum_id.clone(),
-                    member_name: ident.sym.clone().into(),
-                };
-
-                if let Some(value) = self.record.get(&key).or_else(|| {
-                    // Same rules as `compute_member`: crossing type syntax
-                    // clears `allow_const_var`, and under mutable enums only
-                    // ambient `const enum` siblings may resolve.
-                    (ctx.allow_const_var && self.ambient_is_resolvable(&key.enum_id))
-                        .then(|| self.ambient_record.get(&key))
-                        .flatten()
-                }) {
-                    if value.is_const() {
-                        value.clone()
-                    } else {
-                        TsEnumRecordValue::Opaque(
-                            self.enum_id
-                                .clone()
-                                .make_member(ident.clone().into())
-                                .into(),
-                        )
-                    }
-                } else {
-                    match ident.sym.as_ref() {
-                        "Infinity" => TsEnumRecordValue::converted_number(
-                            f64::INFINITY,
-                            Some(ident.sym.clone()),
-                        ),
-                        "NaN" => {
-                            TsEnumRecordValue::converted_number(f64::NAN, Some(ident.sym.clone()))
-                        }
-                        _ => TsEnumRecordValue::Opaque(expr),
-                    }
-                }
-            }
-            // A reference to a `const` binding whose initializer is a constant
-            // expression. TypeScript treats it as a compile-time constant, so
-            // the member is emitted as a string enum instead of a reverse
-            // mapping. Only reachable when not under type syntax.
-            Expr::Ident(ref ident) if ctx.allow_const_var => self
-                .const_vars
-                .get(&ident.to_id())
-                .cloned()
-                .unwrap_or_else(|| TsEnumRecordValue::Opaque(expr)),
-            Expr::Paren(e) => self.compute_rec(e.expr, ctx),
-            Expr::Unary(e) => self.compute_unary(e, ctx),
-            Expr::Bin(e) => self.compute_bin(e, ctx),
-            Expr::Member(e) => self.compute_member(e, ctx),
-            Expr::OptChain(e) => {
-                let opaque_expr = TsEnumRecordValue::Opaque(e.clone().into());
-                let OptChainBase::Member(member) = *e.base else {
-                    return opaque_expr;
-                };
-                // `compute_member` builds its own fallback from the
-                // `MemberExpr` alone, which would drop the `?.` and turn a
-                // guarded read into an unguarded one.
-                match self.compute_member(member, ctx) {
-                    TsEnumRecordValue::Opaque(..) => opaque_expr,
-                    value => value,
-                }
-            }
-            Expr::Tpl(e) => self.compute_tpl(e, ctx),
-            // Handle TypeScript type expressions by stripping them
-            // and computing the inner expression
-            Expr::TsAs(TsAsExpr { expr: inner, .. })
-            | Expr::TsNonNull(TsNonNullExpr { expr: inner, .. })
-            | Expr::TsTypeAssertion(TsTypeAssertion { expr: inner, .. })
-            | Expr::TsConstAssertion(TsConstAssertion { expr: inner, .. })
-            | Expr::TsInstantiation(TsInstantiation { expr: inner, .. })
-            | Expr::TsSatisfies(TsSatisfiesExpr { expr: inner, .. }) => {
-                if ctx.ts_is_opaque {
-                    // Any annotation or assertion removes constness from a
-                    // `const` initializer.
-                    return TsEnumRecordValue::Opaque(inner);
-                }
-                self.compute_rec(
-                    inner,
-                    EvalCtx {
-                        allow_const_var: false,
-                        ..ctx
-                    },
-                )
-            }
-            _ => TsEnumRecordValue::Opaque(expr),
-        }
-    }
-
-    fn compute_unary(&self, expr: UnaryExpr, ctx: EvalCtx) -> TsEnumRecordValue {
-        if !matches!(expr.op, op!(unary, "+") | op!(unary, "-") | op!("~")) {
-            return TsEnumRecordValue::Opaque(expr.into());
-        }
-
-        let inner = self.compute_rec(expr.arg, ctx);
-
-        let TsEnumRecordValue::Number(num) = inner else {
-            return TsEnumRecordValue::Opaque(
-                UnaryExpr {
-                    span: expr.span,
-                    op: expr.op,
-                    arg: Box::new(inner.into()),
-                }
-                .into(),
-            );
-        };
-
-        match expr.op {
-            op!(unary, "+") => TsEnumRecordValue::number(num.value),
-            op!(unary, "-") => TsEnumRecordValue::number(-num.value),
-            op!("~") => TsEnumRecordValue::number(!JsNumber::from(num.value)),
-            _ => unreachable!(),
-        }
-    }
-
-    fn compute_bin(&self, expr: BinExpr, ctx: EvalCtx) -> TsEnumRecordValue {
-        let origin_expr = expr.clone();
-        if !matches!(
-            expr.op,
-            op!(bin, "+")
-                | op!(bin, "-")
-                | op!("*")
-                | op!("/")
-                | op!("%")
-                | op!("**")
-                | op!("<<")
-                | op!(">>")
-                | op!(">>>")
-                | op!("|")
-                | op!("&")
-                | op!("^"),
-        ) {
-            return TsEnumRecordValue::Opaque(origin_expr.into());
-        }
-
-        let left = self.compute_rec(expr.left, ctx);
-        let right = self.compute_rec(expr.right, ctx);
-
-        if expr.op == BinaryOp::Add && (left.is_string() || right.is_string()) {
-            let mut value = Wtf8Buf::new();
-
-            if left.push_to_string(&mut value) && right.push_to_string(&mut value) {
-                return TsEnumRecordValue::String(Wtf8Atom::from(&*value));
-            }
-        }
-
-        match (left, right, expr.op) {
-            (TsEnumRecordValue::Number(left), TsEnumRecordValue::Number(right), op) => {
-                let left = JsNumber::from(left.value);
-                let right = JsNumber::from(right.value);
-                let value = match op {
-                    op!(bin, "+") => left + right,
-                    op!(bin, "-") => left - right,
-                    op!("*") => left * right,
-                    op!("/") => left / right,
-                    op!("%") => left % right,
-                    op!("**") => left.pow(right),
-                    op!("<<") => left << right,
-                    op!(">>") => left >> right,
-                    op!(">>>") => left.unsigned_shr(right),
-                    op!("|") => left | right,
-                    op!("&") => left & right,
-                    op!("^") => left ^ right,
-                    _ => unreachable!(),
-                };
-
-                TsEnumRecordValue::number(value)
-            }
-            (left, right, _) => {
-                let mut origin_expr = origin_expr;
-
-                if left.is_const() {
-                    origin_expr.left = Box::new(left.into());
-                }
-
-                if right.is_const() {
-                    origin_expr.right = Box::new(right.into());
-                }
-
-                TsEnumRecordValue::Opaque(origin_expr.into())
-            }
-        }
-    }
-
-    fn ambient_is_resolvable(&self, enum_id: &Id) -> bool {
-        self.ambient_const_enum_only
-            .map_or(true, |set| set.contains(enum_id))
-    }
-
-    fn compute_member(&self, expr: MemberExpr, ctx: EvalCtx) -> TsEnumRecordValue {
-        let opaque_expr = TsEnumRecordValue::Opaque(expr.clone().into());
-
-        let Some(member_name) = static_enum_member_name(&expr.prop) else {
-            return opaque_expr;
-        };
-
-        let Expr::Ident(ident) = *expr.obj else {
-            return opaque_expr;
-        };
-
-        let enum_id = ident.to_id();
-
-        if self
-            .const_enum_only
-            .is_some_and(|set| !set.contains(&enum_id))
-        {
-            return opaque_expr;
-        }
-
-        let key = TsEnumRecordKey {
-            enum_id,
-            member_name,
-        };
-
-        // `allow_const_var` is cleared when evaluation crosses type syntax, so
-        // an ambient member reached through an assertion is not a constant
-        // enum expression. Only the ambient lookup is guarded: the concrete
-        // path folds these today (swc-project/swc#12150) and changing it here
-        // would revert #11769.
-        self.record
-            .get(&key)
-            .or_else(|| {
-                (ctx.allow_const_var && self.ambient_is_resolvable(&key.enum_id))
-                    .then(|| self.ambient_record.get(&key))
-                    .flatten()
-            })
-            .cloned()
-            .filter(TsEnumRecordValue::has_value)
-            .unwrap_or(opaque_expr)
-    }
-
-    fn compute_tpl(&self, expr: Tpl, ctx: EvalCtx) -> TsEnumRecordValue {
-        let opaque_expr = TsEnumRecordValue::Opaque(expr.clone().into());
-
-        let Tpl { exprs, quasis, .. } = expr;
-
-        let mut quasis_iter = quasis.into_iter();
-
-        let Some(first_quasi) = quasis_iter.next() else {
-            return opaque_expr;
-        };
-        let Some(first_cooked) = first_quasi.cooked.as_ref() else {
-            return opaque_expr;
-        };
-        let mut string = Wtf8Buf::from(first_cooked);
-
-        for (q, expr) in quasis_iter.zip(exprs) {
-            let expr = self.compute_rec(expr, ctx);
-
-            if !expr.push_to_string(&mut string) {
-                return opaque_expr;
-            }
-            let Some(cooked) = q.cooked.as_ref() else {
-                return opaque_expr;
-            };
-
-            string.push_wtf8(cooked);
-        }
-
-        TsEnumRecordValue::String(Wtf8Atom::from(&*string))
-    }
-}
diff --git a/crates/swc_ecma_transforms_typescript/src/typescript.rs b/crates/swc_ecma_transforms_typescript/src/typescript.rs
index 22cdc98688f382bc91995700c5dbf4c25efcb041..33261632cf16c44bfe6354c78062624cc0d8d85a 100644
--- a/crates/swc_ecma_transforms_typescript/src/typescript.rs
+++ b/crates/swc_ecma_transforms_typescript/src/typescript.rs
@@ -53,18 +53,14 @@ impl Pass for TypeScript {
             mem::take(&mut self.id_usage),
             self.config.flow_syntax,
             self.config.ts_enum_is_mutable,
+            self.config.verbatim_module_syntax,
         );
 
         n.mutate(transform(
             self.unresolved_mark,
             self.top_level_mark,
-            semantic,
-            self.config.import_not_used_as_values,
-            self.config.import_export_assign_config,
-            self.config.ts_enum_is_mutable,
-            self.config.verbatim_module_syntax,
-            self.config.native_class_properties,
-            self.config.flow_syntax,
+            &semantic,
+            self.config,
         ));
 
         if let Some(span) = last_module_span {
@@ -76,7 +72,14 @@ impl Pass for TypeScript {
 
 impl TypeScript {
     fn get_last_module_span(&self, n: &Module) -> Option<Span> {
-        if self.config.no_empty_export {
+        if self.config.no_empty_export
+            || n.body.iter().any(|item| {
+                matches!(
+                    item,
+                    ModuleItem::ModuleDecl(ModuleDecl::TsExportAssignment(_))
+                )
+            })
+        {
             return None;
         }
 
diff --git a/crates/swc_ecma_utils/Cargo.toml b/crates/swc_ecma_utils/Cargo.toml
index 844d51f7435b72e9759a2e44e18123081a210e3a..f7c7cd1aa24c0b23aa92ebd230ce6b3631afba1f 100644
--- a/crates/swc_ecma_utils/Cargo.toml
+++ b/crates/swc_ecma_utils/Cargo.toml
@@ -24,6 +24,7 @@ concurrent = ["swc_common/concurrent", "par-core/parallel"]
 
 [dependencies]
 dragonbox_ecma = { workspace = true }
+hashbrown      = { workspace = true }
 indexmap       = { workspace = true }
 num_cpus       = { workspace = true }
 once_cell      = { workspace = true }
diff --git a/crates/swc_ecma_utils/src/lib.rs b/crates/swc_ecma_utils/src/lib.rs
index 8b7f2e42c630b3e9aa6395ab5dd71639538ef79f..dda1615e49829085af1e491f97df3f7e9f7b6d1f 100644
--- a/crates/swc_ecma_utils/src/lib.rs
+++ b/crates/swc_ecma_utils/src/lib.rs
@@ -62,6 +62,8 @@ mod node_ignore_span;
 pub mod number;
 pub mod stack_size;
 pub mod str;
+#[doc(hidden)]
+pub mod ts_bindings;
 pub use node_ignore_span::NodeIgnoringSpan;
 
 // TODO: remove
@@ -1766,6 +1768,17 @@ where
     node.visit_with(&mut v);
 }
 
+/// Finds binding identifiers in a TypeScript signature parameter, ignoring
+/// expressions and type annotations. The ordinary binding visitor skips the
+/// erased `TsFnParam` wrapper, so enter its binding pattern directly.
+pub fn for_each_ts_fn_param_binding_ident<F>(node: &TsFnParam, op: F)
+where
+    F: for<'a> FnMut(&'a BindingIdent),
+{
+    let mut v = BindingIdentifierVisitor { op };
+    node.visit_children_with(&mut v);
+}
+
 impl<F> Visit for BindingIdentifierVisitor<F>
 where
     F: for<'a> FnMut(&'a BindingIdent),
@@ -2559,6 +2572,9 @@ pub trait QueryRef {
     fn query_ref(&self, _ident: &Ident) -> Option<Box<Expr>> {
         None
     }
+    /// Rewrites an assignment, update, or deletion target while preserving
+    /// its identity as a reference rather than substituting its stored value.
+    /// A replacement must remain assignable, such as an identifier or member.
     fn query_lhs(&self, _ident: &Ident) -> Option<Box<Expr>> {
         None
     }
@@ -2587,6 +2603,30 @@ impl<T> RefRewriter<T>
 where
     T: QueryRef,
 {
+    /// Rewrites the target itself with the write query. Its receiver and
+    /// computed key are ordinary reads and keep using the read query.
+    fn visit_mut_reference(&mut self, mut expression: &mut Expr) {
+        loop {
+            expression = match expression {
+                Expr::Paren(ParenExpr { expr, .. })
+                | Expr::TsAs(TsAsExpr { expr, .. })
+                | Expr::TsNonNull(TsNonNullExpr { expr, .. })
+                | Expr::TsTypeAssertion(TsTypeAssertion { expr, .. })
+                | Expr::TsConstAssertion(TsConstAssertion { expr, .. })
+                | Expr::TsInstantiation(TsInstantiation { expr, .. })
+                | Expr::TsSatisfies(TsSatisfiesExpr { expr, .. }) => expr,
+                _ => break,
+            };
+        }
+        if let Expr::Ident(ident) = expression {
+            if let Some(replacement) = self.query.query_lhs(ident) {
+                *expression = *replacement;
+            }
+        } else {
+            expression.visit_mut_children_with(self);
+        }
+    }
+
     pub fn exit_prop(&mut self, n: &mut Prop) {
         if let Prop::Shorthand(shorthand) = n {
             if let Some(expr) = self.query.query_ref(shorthand) {
@@ -2601,7 +2641,7 @@ where
 
     pub fn exit_pat(&mut self, n: &mut Pat) {
         if let Pat::Ident(id) = n {
-            if let Some(expr) = self.query.query_lhs(&id.clone().into()) {
+            if let Some(expr) = self.query.query_lhs(&id.id) {
                 *n = expr.into();
             }
         }
@@ -2617,8 +2657,10 @@ where
 
     pub fn exit_simple_assign_target(&mut self, n: &mut SimpleAssignTarget) {
         if let SimpleAssignTarget::Ident(ref_ident) = n {
-            if let Some(expr) = self.query.query_lhs(&ref_ident.clone().into()) {
-                *n = expr.try_into().unwrap();
+            if let Some(expr) = self.query.query_lhs(&ref_ident.id) {
+                *n = expr
+                    .try_into()
+                    .expect("write query must produce a simple assignment target");
             }
         };
     }
@@ -2651,7 +2693,10 @@ where
                 let value = value
                     .take()
                     .map(|default_value| {
-                        let left = expr.clone().try_into().unwrap();
+                        let left = expr
+                            .clone()
+                            .try_into()
+                            .expect("write query must produce an assignment target");
                         Box::new(default_value.make_assign_to(op!("="), left))
                     })
                     .unwrap_or(expr);
@@ -2693,8 +2738,12 @@ where
     }
 
     fn visit_mut_pat(&mut self, n: &mut Pat) {
-        n.visit_mut_children_with(self);
-        self.exit_pat(n);
+        if let Pat::Expr(expression) = n {
+            self.visit_mut_reference(expression);
+        } else {
+            n.visit_mut_children_with(self);
+            self.exit_pat(n);
+        }
     }
 
     fn visit_mut_expr(&mut self, n: &mut Expr) {
@@ -2702,9 +2751,33 @@ where
         self.exit_expr(n);
     }
 
+    fn visit_mut_update_expr(&mut self, n: &mut UpdateExpr) {
+        self.visit_mut_reference(&mut n.arg);
+    }
+
+    fn visit_mut_unary_expr(&mut self, n: &mut UnaryExpr) {
+        if n.op == UnaryOp::Delete {
+            self.visit_mut_reference(&mut n.arg);
+        } else {
+            n.visit_mut_children_with(self);
+        }
+    }
+
     fn visit_mut_simple_assign_target(&mut self, n: &mut SimpleAssignTarget) {
-        n.visit_mut_children_with(self);
-        self.exit_simple_assign_target(n);
+        match n {
+            SimpleAssignTarget::Paren(ParenExpr { expr, .. })
+            | SimpleAssignTarget::TsAs(TsAsExpr { expr, .. })
+            | SimpleAssignTarget::TsNonNull(TsNonNullExpr { expr, .. })
+            | SimpleAssignTarget::TsTypeAssertion(TsTypeAssertion { expr, .. })
+            | SimpleAssignTarget::TsInstantiation(TsInstantiation { expr, .. })
+            | SimpleAssignTarget::TsSatisfies(TsSatisfiesExpr { expr, .. }) => {
+                self.visit_mut_reference(expr);
+            }
+            _ => {
+                n.visit_mut_children_with(self);
+                self.exit_simple_assign_target(n);
+            }
+        }
     }
 
     fn visit_mut_callee(&mut self, n: &mut Callee) {
diff --git a/crates/swc_ecma_utils/src/ts_bindings.rs b/crates/swc_ecma_utils/src/ts_bindings.rs
new file mode 100644
index 0000000000000000000000000000000000000000..42cc1f657b30b535c9dbe7416b97f13e8a0f7a0a
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings.rs
@@ -0,0 +1,699 @@
+//! Declaration relationships for TypeScript runtime containers.
+//!
+//! The lexical resolver owns reference lookup. This index links its declaration
+//! IDs to shared namespace/enum members without merging physical JS bindings.
+//! It is rebuilt from the AST at each phase boundary; body handles are valid
+//! only during a walk of that same, structurally unchanged AST.
+
+use std::{
+    borrow::Borrow,
+    hash::{Hash, Hasher},
+};
+
+use hashbrown::HashTable;
+use rustc_hash::FxHasher;
+use swc_atoms::{Atom, Wtf8Atom};
+use swc_common::{Span, SyntaxContext};
+use swc_ecma_ast::*;
+mod aliases;
+mod collect;
+mod exports;
+mod ids;
+mod lookup;
+mod namespaces;
+mod observer;
+mod scopes;
+
+use self::scopes::ScopeOwners;
+pub use self::{
+    ids::{TsAliasId, TsContainerId, TsDeclarationId, TsMemberId, TsNamespaceBodyId},
+    observer::TsBindingObserver,
+    scopes::{TsLexicalNamespaceId, TsLexicalScopes},
+};
+
+/// A resolved value reached through a binding, member, or internal alias.
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+pub enum TsValueTarget {
+    Binding(TsDeclarationId),
+    EnumMember(TsMemberId),
+}
+
+/// The selected member grammar differs between constant evaluation and reads.
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+pub enum TsMemberResolution {
+    Constant,
+    Inline,
+}
+
+/// The meaning required by a reference, independent of JavaScript emission.
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+pub enum TsReferenceSpace {
+    /// A reference that survives type erasure.
+    Value,
+    /// An ordinary type reference.
+    Type,
+    /// The qualifier of a type name or internal import alias.
+    Namespace,
+    /// A value lookup inside erased syntax, including `typeof`.
+    TypeQuery,
+    /// A binding, alias, or export may refer to any target meaning.
+    Any,
+}
+
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+enum MemberKind {
+    Namespace,
+    Enum,
+}
+
+/// Declaration candidates for runtime and erased references to a shared member.
+#[derive(Debug)]
+pub struct TsMember {
+    pub owner: TsContainerId,
+    pub name: Wtf8Atom,
+    pub value: Option<TsDeclarationId>,
+    /// Also carries namespaces, aliases, and type-only export specifiers.
+    /// Lookup checks the target's meaning before selecting this candidate.
+    pub erased: Option<TsDeclarationId>,
+    pub container: Option<TsContainerId>,
+    kind: MemberKind,
+}
+
+impl TsMember {
+    /// Enum members have a value identity without a physical JS declaration.
+    pub fn is_enum_member(&self) -> bool {
+        self.kind == MemberKind::Enum
+    }
+}
+
+#[derive(Debug)]
+struct Container {
+    declaration: TsDeclarationId,
+}
+
+#[derive(Debug)]
+struct Declaration {
+    id: Id,
+    owner: Option<TsNamespaceBodyId>,
+    member: Option<TsMemberId>,
+    container: Option<TsContainerId>,
+    export_target: Option<TsDeclarationId>,
+    alias: Option<TsAliasId>,
+    value_space: bool,
+    type_space: bool,
+    ambient: bool,
+}
+
+#[derive(Debug)]
+struct AliasPath {
+    root: Id,
+    members: AliasMembers,
+}
+
+/// Most internal aliases name a root or one direct member. Keep those paths
+/// inline; only longer qualified paths need a separate allocation.
+#[derive(Debug)]
+enum AliasMembers {
+    Empty,
+    Single(Wtf8Atom),
+    Qualified(Box<[Wtf8Atom]>),
+}
+
+impl AliasMembers {
+    fn as_slice(&self) -> &[Wtf8Atom] {
+        match self {
+            Self::Empty => &[],
+            Self::Single(member) => std::slice::from_ref(member),
+            Self::Qualified(members) => members,
+        }
+    }
+}
+
+/// Same-file alias metadata used by transform dependency analysis.
+#[derive(Debug)]
+pub struct TsAlias {
+    pub declaration: TsDeclarationId,
+    pub span: Span,
+    pub is_export: bool,
+    pub is_type_only: bool,
+    pub is_script_global: bool,
+    path: Option<AliasPath>,
+}
+
+#[derive(Debug, Clone, Copy)]
+enum AliasState {
+    Pending,
+    Resolving,
+    Resolved(TsValueTarget),
+    Unknown,
+}
+
+#[derive(Debug)]
+struct NamespaceBody {
+    container: TsContainerId,
+    parent: Option<TsNamespaceBodyId>,
+}
+
+struct NamespaceExport {
+    body: TsNamespaceBodyId,
+    source: Id,
+    name: swc_atoms::Atom,
+    type_only: bool,
+}
+
+/// A phase-local index of resolved declarations and TS container membership.
+#[derive(Debug, Default)]
+pub struct TsBindings {
+    containers: Vec<Container>,
+    members: Vec<TsMember>,
+    // Member storage owns each (container, name) once. A shared handle index
+    // avoids allocating a separate hash table for every small namespace.
+    members_by_name: HashTable<TsMemberId>,
+    declarations: Vec<Declaration>,
+    // Declaration storage owns each ID once. The hash table carries handles
+    // and compares against that storage, without a second owning key copy.
+    declarations_by_id: HashTable<TsDeclarationId>,
+    aliases: Vec<TsAlias>,
+    alias_states: Vec<AliasState>,
+    bodies: Vec<NamespaceBody>,
+    // Erased parameters share a lexical context. Namespace completion needs
+    // one owner per scope rather than a declaration for every parameter.
+    erased_scopes: ScopeOwners,
+    // Full declaration identities avoid scanning every same-named binding.
+    // The declarations own the names; this index only stores handles and targets.
+    runtime_values: Option<HashTable<(TsDeclarationId, TsValueTarget)>>,
+}
+
+impl TsBindings {
+    /// Reuse lexical scope ownership supplied by the resolver instead of
+    /// collecting owner-only bindings from erased type syntax again.
+    #[doc(hidden)]
+    pub fn with_lexical_scopes(mut self, scopes: TsLexicalScopes) -> Self {
+        self.erased_scopes = scopes.resolve(&self);
+        self
+    }
+
+    /// Build runtime-read queries for a transform that also performs enum
+    /// substitution. Namespace resolution does not need this additional index.
+    pub fn with_runtime_queries(mut self) -> Self {
+        self.index_runtime_values();
+        self
+    }
+
+    /// Get a body while walking the same declaration sequence again.
+    pub fn namespace_body(&self, index: usize) -> Option<TsNamespaceBodyId> {
+        (index < self.bodies.len()).then(|| TsNamespaceBodyId::from_index(index))
+    }
+
+    /// The owner shared by all declarations contributing to a container.
+    pub fn container(&self, declaration: &Id) -> Option<TsContainerId> {
+        self.declaration_id(declaration)
+            .and_then(|declaration| self.declaration_container(declaration))
+    }
+
+    /// The source binding identity for an interned declaration.
+    pub fn declaration(&self, declaration: TsDeclarationId) -> &Id {
+        &self.declarations[declaration.index()].id
+    }
+
+    /// Interned declaration corresponding to an already resolved AST ID.
+    pub fn declaration_id(&self, id: &Id) -> Option<TsDeclarationId> {
+        self.lookup_declaration(&id.0, id.1)
+    }
+
+    /// Resolve an identifier without copying its owned declaration ID.
+    pub fn ident_declaration(&self, ident: &Ident) -> Option<TsDeclarationId> {
+        self.lookup_declaration(&ident.sym, ident.ctxt)
+    }
+
+    fn lookup_declaration(&self, name: &Atom, ctxt: SyntaxContext) -> Option<TsDeclarationId> {
+        self.declarations_by_id
+            .find(declaration_hash(name, ctxt), |&declaration| {
+                let id = &self.declarations[declaration.index()].id;
+                id.0 == *name && id.1 == ctxt
+            })
+            .copied()
+    }
+
+    /// The runtime container attached to this declaration or merged member.
+    pub fn declaration_container(&self, declaration: TsDeclarationId) -> Option<TsContainerId> {
+        let declaration = &self.declarations[declaration.index()];
+        declaration.container.or_else(|| {
+            declaration
+                .member
+                .and_then(|member| self.member(member).container)
+        })
+    }
+
+    /// One representative declaration of a shared runtime container.
+    pub fn container_declaration(&self, container: TsContainerId) -> TsDeclarationId {
+        self.containers[container.index()].declaration
+    }
+
+    /// The shared member contributed by an exported declaration.
+    pub fn member_of(&self, declaration: &Id) -> Option<TsMemberId> {
+        self.declaration_id(declaration)
+            .and_then(|declaration| self.declaration_member(declaration))
+    }
+
+    /// Shared membership of an already interned declaration.
+    pub fn declaration_member(&self, declaration: TsDeclarationId) -> Option<TsMemberId> {
+        self.declarations[declaration.index()].member
+    }
+
+    /// Facts for a handle obtained from this index.
+    pub fn member(&self, member: TsMemberId) -> &TsMember {
+        &self.members[member.index()]
+    }
+
+    /// Lookup under a resolved owner, preserving quoted/lone-surrogate keys.
+    pub fn named_member(&self, container: TsContainerId, name: &Wtf8Atom) -> Option<TsMemberId> {
+        self.members_by_name
+            .find(member_hash(container, name), |&member| {
+                let member = self.member(member);
+                member.owner == container && member.name == *name
+            })
+            .copied()
+    }
+
+    /// Aliases in declaration order, with independent binding identities.
+    pub fn aliases(&self) -> impl Iterator<Item = TsAliasId> + '_ {
+        (0..self.aliases.len()).map(TsAliasId::from_index)
+    }
+
+    /// Declaration and dependency policy inputs for one alias.
+    pub fn alias(&self, alias: TsAliasId) -> &TsAlias {
+        &self.aliases[alias.index()]
+    }
+
+    /// Whether a declaration is an import-equals binding.
+    pub fn declaration_alias(&self, declaration: TsDeclarationId) -> Option<TsAliasId> {
+        self.declarations[declaration.index()].alias
+    }
+
+    /// Known terminal value of an internal alias. Cycles, type-only aliases,
+    /// and external targets deliberately return no value.
+    pub fn alias_target(&self, alias: TsAliasId) -> Option<TsValueTarget> {
+        match self.alias_states[alias.index()] {
+            AliasState::Resolved(target) => Some(target),
+            AliasState::Pending | AliasState::Resolving | AliasState::Unknown => None,
+        }
+    }
+
+    /// A known type-only terminal cannot introduce a runtime alias binding.
+    /// Unknown external targets remain possible values.
+    pub fn alias_has_value(&self, alias: TsAliasId) -> bool {
+        if self.alias(alias).is_type_only {
+            return false;
+        }
+        match self.alias_target(alias) {
+            Some(TsValueTarget::Binding(declaration)) => {
+                self.declarations[declaration.index()].value_space
+            }
+            Some(TsValueTarget::EnumMember(_)) | None => true,
+        }
+    }
+
+    /// Whether an alias initializer can create a runtime dependency.
+    ///
+    /// Ambient aliases retain their target's symbol meanings, but their
+    /// erased initializers never access that target at runtime.
+    pub fn alias_has_runtime_initializer(&self, alias: TsAliasId) -> bool {
+        !self.declarations[self.alias(alias).declaration.index()].ambient
+            && self.alias_has_value(alias)
+    }
+
+    fn target_has_space(&self, target: TsValueTarget, space: TsReferenceSpace) -> bool {
+        let TsValueTarget::Binding(declaration) = target else {
+            return matches!(
+                space,
+                TsReferenceSpace::Value | TsReferenceSpace::TypeQuery | TsReferenceSpace::Any
+            );
+        };
+        let facts = &self.declarations[declaration.index()];
+        match space {
+            TsReferenceSpace::Value | TsReferenceSpace::TypeQuery => facts.value_space,
+            TsReferenceSpace::Type => {
+                // A value and a type may have separate physical declarations
+                // while contributing to the same exported namespace member.
+                facts.type_space
+                    || facts.member.is_some_and(|member| {
+                        self.member(member)
+                            .erased
+                            .is_some_and(|ty| self.declarations[ty.index()].type_space)
+                    })
+            }
+            TsReferenceSpace::Namespace => self.declaration_container(declaration).is_some(),
+            TsReferenceSpace::Any => true,
+        }
+    }
+
+    fn declaration_has_space(&self, declaration: TsDeclarationId, space: TsReferenceSpace) -> bool {
+        let facts = &self.declarations[declaration.index()];
+        let source = facts.export_target.unwrap_or(declaration);
+        if let Some(alias) = self.declaration_alias(source) {
+            if space == TsReferenceSpace::Value {
+                return self.alias_has_value(alias);
+            }
+            // An unknown external target can contribute any meaning. A known
+            // internal target contributes only its actual symbol meanings.
+            return self
+                .alias_target(alias)
+                .map_or(true, |target| self.target_has_space(target, space));
+        }
+        self.target_has_space(TsValueTarget::Binding(source), space)
+    }
+
+    /// The root dependency retains its own alias declaration identity.
+    pub fn alias_dependency(&self, alias: TsAliasId) -> Option<TsDeclarationId> {
+        self.aliases[alias.index()]
+            .path
+            .as_ref()
+            .and_then(|path| self.declaration_id(&path.root))
+    }
+
+    /// Resolve a runtime value through the known declaration/member/alias
+    /// facts.
+    pub fn value_target(&self, id: &Id) -> Option<TsValueTarget> {
+        self.declaration_id(id)
+            .and_then(|declaration| self.declaration_value(declaration))
+    }
+
+    /// Resolve an AST identifier through declaration/member/alias facts
+    /// without constructing an owned binding ID.
+    pub fn ident_value_target(&self, ident: &Ident) -> Option<TsValueTarget> {
+        self.ident_declaration(ident)
+            .and_then(|declaration| self.declaration_value(declaration))
+    }
+
+    /// Resolve only values that can retain a runtime container or inline an
+    /// enum member. Ordinary local references need neither operation, so this
+    /// smaller index accepts a borrowed identifier without constructing an ID.
+    pub fn runtime_target(&self, ident: &Ident) -> Option<TsValueTarget> {
+        match &self.runtime_values {
+            Some(values) => values
+                .find(
+                    declaration_hash(&ident.sym, ident.ctxt),
+                    |&(declaration, _)| {
+                        let id = &self.declarations[declaration.index()].id;
+                        id.0 == ident.sym && id.1 == ident.ctxt
+                    },
+                )
+                .map(|&(_, target)| target),
+            None => self
+                .ident_declaration(ident)
+                .and_then(|declaration| self.declaration_value(declaration))
+                .filter(|&target| self.is_runtime_target(target)),
+        }
+    }
+
+    /// Cached runtime identities for a phase-local consumer index. Names
+    /// borrow this declaration graph; targets remain valid while it is alive.
+    pub fn runtime_values(&self) -> impl Iterator<Item = (&Atom, SyntaxContext, TsValueTarget)> {
+        self.runtime_values.iter().flat_map(|values| {
+            values.iter().map(|&(declaration, target)| {
+                let (name, ctxt) = &self.declarations[declaration.index()].id;
+                (name, *ctxt, target)
+            })
+        })
+    }
+
+    fn is_runtime_target(&self, target: TsValueTarget) -> bool {
+        match target {
+            TsValueTarget::Binding(declaration) => {
+                self.declaration_container(declaration).is_some()
+            }
+            TsValueTarget::EnumMember(_) => true,
+        }
+    }
+
+    fn index_runtime_values(&mut self) {
+        let mut values = HashTable::new();
+        for index in 0..self.declarations.len() {
+            let declaration = TsDeclarationId::from_index(index);
+            let Some(target) = self.declaration_value(declaration) else {
+                continue;
+            };
+            if !self.is_runtime_target(target) {
+                continue;
+            }
+            let (name, ctxt) = &self.declarations[index].id;
+            values.insert_unique(
+                declaration_hash(name, *ctxt),
+                (declaration, target),
+                |&(id, _)| {
+                    let (name, ctxt) = &self.declarations[id.index()].id;
+                    declaration_hash(name, *ctxt)
+                },
+            );
+        }
+        self.runtime_values = Some(values);
+    }
+
+    fn declaration_value(&self, declaration: TsDeclarationId) -> Option<TsValueTarget> {
+        let declaration = self.canonical_value_declaration(declaration);
+        if !self.declarations[declaration.index()].value_space {
+            return None;
+        }
+        match self.declaration_alias(declaration) {
+            Some(alias) => self.alias_target(alias),
+            None => Some(TsValueTarget::Binding(declaration)),
+        }
+    }
+
+    fn canonical_value_declaration(&self, declaration: TsDeclarationId) -> TsDeclarationId {
+        let facts = &self.declarations[declaration.index()];
+        facts
+            .export_target
+            .or_else(|| facts.member.and_then(|member| self.member(member).value))
+            .unwrap_or(declaration)
+    }
+
+    /// Resolve a statically named member with the selected entity-name grammar.
+    /// Parentheses are transparent; optional runtime accesses remain opaque.
+    pub fn expression_target(
+        &self,
+        expression: &Expr,
+        resolution: TsMemberResolution,
+    ) -> Option<TsValueTarget> {
+        self.expression_target_inner(expression, resolution, false)
+    }
+
+    /// Runtime reads start from a known container or enum-member alias. Their
+    /// member grammar matches inline substitution and does not inspect
+    /// unrelated lexical declarations.
+    pub fn runtime_expression_target(&self, expression: &Expr) -> Option<TsValueTarget> {
+        self.expression_target_inner(expression, TsMemberResolution::Inline, true)
+    }
+
+    fn expression_target_inner(
+        &self,
+        expression: &Expr,
+        resolution: TsMemberResolution,
+        runtime: bool,
+    ) -> Option<TsValueTarget> {
+        crate::stack_size::maybe_grow_default(|| match expression {
+            Expr::Ident(ident) if runtime => self.runtime_target(ident),
+            Expr::Ident(ident) => self.ident_value_target(ident),
+            Expr::Paren(paren) => self.expression_target_inner(&paren.expr, resolution, runtime),
+            Expr::Member(member) => self
+                .expression_target_inner(&member.obj, resolution, runtime)
+                .and_then(|object| self.member_target(object, &member.prop, resolution)),
+            Expr::OptChain(chain) if resolution == TsMemberResolution::Constant => {
+                match &*chain.base {
+                    OptChainBase::Member(member) => self
+                        .expression_target_inner(&member.obj, resolution, runtime)
+                        .and_then(|object| self.member_target(object, &member.prop, resolution)),
+                    OptChainBase::Call(_) => None,
+                    #[cfg(swc_ast_unknown)]
+                    _ => None,
+                }
+            }
+            _ => None,
+        })
+    }
+
+    /// Resolve one member after its object has already been resolved. Consumers
+    /// walking an object chain can reuse each prefix instead of scanning it
+    /// again.
+    pub fn member_target(
+        &self,
+        object: TsValueTarget,
+        property: &MemberProp,
+        resolution: TsMemberResolution,
+    ) -> Option<TsValueTarget> {
+        let TsValueTarget::Binding(object) = object else {
+            return None;
+        };
+        let container = self.declaration_container(object)?;
+        let name = static_member_name(property)?;
+        let member_id = self.named_member(container, &name)?;
+        let facts = self.member(member_id);
+
+        if facts.is_enum_member() {
+            return Some(TsValueTarget::EnumMember(member_id));
+        }
+        if resolution == TsMemberResolution::Constant && matches!(property, MemberProp::Computed(_))
+        {
+            return None;
+        }
+        facts
+            .value
+            .and_then(|declaration| self.declaration_value(declaration))
+    }
+
+    fn register(&mut self, id: Id, owner: Option<TsNamespaceBodyId>) -> TsDeclarationId {
+        use hashbrown::hash_table::Entry;
+
+        let declarations = &mut self.declarations;
+        let entry = self.declarations_by_id.entry(
+            declaration_hash(&id.0, id.1),
+            |&declaration| declarations[declaration.index()].id == id,
+            |&declaration| {
+                let id = &declarations[declaration.index()].id;
+                declaration_hash(&id.0, id.1)
+            },
+        );
+        match entry {
+            Entry::Occupied(entry) => {
+                let declaration = *entry.get();
+                declarations[declaration.index()].owner = owner;
+                declaration
+            }
+            Entry::Vacant(entry) => {
+                let declaration = TsDeclarationId::from_index(declarations.len());
+                declarations.push(Declaration {
+                    id,
+                    owner,
+                    member: None,
+                    container: None,
+                    export_target: None,
+                    alias: None,
+                    value_space: false,
+                    type_space: false,
+                    ambient: false,
+                });
+                entry.insert(declaration);
+                declaration
+            }
+        }
+    }
+
+    /// A declaration target selected at a namespace boundary. The original
+    /// lexical result remains authoritative for bindings owned by that body.
+    pub fn namespace_reference(
+        &self,
+        reference: &Id,
+        bodies: &[TsNamespaceBodyId],
+        space: TsReferenceSpace,
+    ) -> Option<&Id> {
+        self.namespace_lookup(&reference.0, reference.1, bodies, space)
+    }
+
+    /// Complete an AST identifier's namespace lookup without copying its ID.
+    pub fn ident_namespace_reference(
+        &self,
+        reference: &Ident,
+        bodies: &[TsNamespaceBodyId],
+        space: TsReferenceSpace,
+    ) -> Option<&Id> {
+        self.namespace_lookup(&reference.sym, reference.ctxt, bodies, space)
+    }
+
+    fn namespace_lookup(
+        &self,
+        name: &Atom,
+        ctxt: SyntaxContext,
+        bodies: &[TsNamespaceBodyId],
+        space: TsReferenceSpace,
+    ) -> Option<&Id> {
+        lookup::NamespaceCandidates::new(self, name, ctxt, bodies.iter().rev().copied(), space)
+            .find(|&declaration| self.declaration_has_space(declaration, space))
+            .map(|declaration| self.declaration(declaration))
+    }
+
+    fn add_member(&mut self, owner: TsContainerId, name: Wtf8Atom) -> TsMemberId {
+        use hashbrown::hash_table::Entry;
+
+        let members = &mut self.members;
+        let entry = self.members_by_name.entry(
+            member_hash(owner, &name),
+            |&member| {
+                let member = &members[member.index()];
+                member.owner == owner && member.name == name
+            },
+            |&member| {
+                let member = &members[member.index()];
+                member_hash(member.owner, &member.name)
+            },
+        );
+        match entry {
+            Entry::Occupied(entry) => *entry.get(),
+            Entry::Vacant(entry) => {
+                let member = TsMemberId::from_index(members.len());
+                members.push(TsMember {
+                    owner,
+                    name,
+                    value: None,
+                    erased: None,
+                    container: None,
+                    kind: MemberKind::Namespace,
+                });
+                entry.insert(member);
+                member
+            }
+        }
+    }
+}
+
+fn member_hash(owner: TsContainerId, name: &Wtf8Atom) -> u64 {
+    let mut hasher = FxHasher::default();
+    (owner, name).hash(&mut hasher);
+    hasher.finish()
+}
+
+fn declaration_hash(name: &Atom, ctxt: SyntaxContext) -> u64 {
+    let mut hasher = FxHasher::default();
+    (name, ctxt).hash(&mut hasher);
+    hasher.finish()
+}
+
+/// Visitor used by [`TsBindings::collect`]. Its state is intentionally private.
+#[derive(Default)]
+pub struct TsBindingCollector<O: TsBindingObserver = (), const TYPE_OWNERS: bool = true> {
+    observer: O,
+    unresolved_ctxt: SyntaxContext,
+    bindings: TsBindings,
+    body: Option<TsNamespaceBodyId>,
+    exported: bool,
+    ambient: bool,
+    is_module: bool,
+    implicit_exports: bool,
+    namespace_has_value: bool,
+    namespace_exports: Vec<NamespaceExport>,
+}
+
+/// Parentheses carry syntax grouping, not a new value or binding identity.
+pub fn transparent_expr(mut expression: &Expr) -> &Expr {
+    while let Expr::Paren(paren) = expression {
+        expression = &paren.expr;
+    }
+    expression
+}
+
+/// A literal member key, with transparent grouping and lossless WTF-8 text.
+pub fn static_member_name(property: &MemberProp) -> Option<Wtf8Atom> {
+    match property {
+        MemberProp::Ident(ident) => Some(ident.sym.clone().into()),
+        MemberProp::Computed(computed) => match transparent_expr(&computed.expr) {
+            Expr::Lit(Lit::Str(string)) => Some(string.value.clone()),
+            Expr::Tpl(template) if template.exprs.is_empty() && template.quasis.len() == 1 => {
+                template.quasis[0].cooked.clone()
+            }
+            _ => None,
+        },
+        MemberProp::PrivateName(_) => None,
+        #[cfg(swc_ast_unknown)]
+        _ => None,
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/aliases.rs b/crates/swc_ecma_utils/src/ts_bindings/aliases.rs
new file mode 100644
index 0000000000000000000000000000000000000000..da558c05e81eca6190fec9ec3a9a78ae0dd47821
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/aliases.rs
@@ -0,0 +1,295 @@
+use std::{ops::ControlFlow, slice};
+
+use super::{
+    lookup::{NamespaceAncestors, NamespaceCandidates},
+    *,
+};
+
+pub(super) fn path(name: &TsEntityName) -> AliasPath {
+    if let TsEntityName::Ident(root) = name {
+        return AliasPath {
+            root: root.to_id(),
+            members: AliasMembers::Empty,
+        };
+    }
+    if let TsEntityName::TsQualifiedName(qualified) = name {
+        if let TsEntityName::Ident(root) = &qualified.left {
+            return AliasPath {
+                root: root.to_id(),
+                members: AliasMembers::Single(qualified.right.sym.clone().into()),
+            };
+        }
+    }
+
+    fn collect(name: &TsEntityName, members: &mut Vec<Wtf8Atom>) -> Id {
+        match name {
+            TsEntityName::Ident(ident) => ident.to_id(),
+            TsEntityName::TsQualifiedName(qualified) => {
+                let root = collect(&qualified.left, members);
+                members.push(qualified.right.sym.clone().into());
+                root
+            }
+            #[cfg(swc_ast_unknown)]
+            _ => panic!("unable to access unknown nodes"),
+        }
+    }
+
+    let mut members = Vec::new();
+    let root = collect(name, &mut members);
+    AliasPath {
+        root,
+        members: AliasMembers::Qualified(members.into_boxed_slice()),
+    }
+}
+
+impl TsBindings {
+    pub(super) fn resolve_aliases(&mut self) {
+        if self.aliases.is_empty() {
+            return;
+        }
+        self.alias_states = AliasResolver::new(self, false).resolve_all().0;
+    }
+
+    /// Complete alias roots against the collected namespace scopes before
+    /// caching their meanings. Root selection resolves alias dependencies with
+    /// the same worklist, so qualifiers never consult an earlier target cache.
+    #[doc(hidden)]
+    pub fn with_namespace_aliases(mut self) -> Self {
+        if self.aliases.is_empty() {
+            return self;
+        }
+        let (states, roots) = AliasResolver::new(&self, true).resolve_all();
+        for (alias, root) in self.aliases.iter_mut().zip(roots) {
+            if let (Some(path), Some(root)) = (&mut alias.path, root) {
+                let id = &self.declarations[root.index()].id;
+                if path.root != *id {
+                    path.root.clone_from(id);
+                }
+            }
+        }
+        self.alias_states = states;
+        self
+    }
+}
+
+type AliasResolution = ControlFlow<TsAliasId, Option<TsValueTarget>>;
+
+struct AliasFrame<'a> {
+    alias: TsAliasId,
+    members: slice::Iter<'a, Wtf8Atom>,
+    root: Option<Box<AliasRoot<'a>>>,
+}
+
+struct AliasRoot<'a> {
+    candidates: NamespaceCandidates<'a, NamespaceAncestors<'a>>,
+    current: Option<TsDeclarationId>,
+    original: Option<TsDeclarationId>,
+    space: TsReferenceSpace,
+}
+
+struct AliasResolver<'a> {
+    bindings: &'a TsBindings,
+    states: Vec<AliasState>,
+    pending: Vec<AliasFrame<'a>>,
+    roots: Vec<Option<TsDeclarationId>>,
+}
+
+impl<'a> AliasResolver<'a> {
+    fn new(bindings: &'a TsBindings, complete_roots: bool) -> Self {
+        Self {
+            bindings,
+            states: vec![AliasState::Pending; bindings.aliases.len()],
+            pending: Vec::new(),
+            roots: if complete_roots {
+                vec![None; bindings.aliases.len()]
+            } else {
+                Vec::new()
+            },
+        }
+    }
+
+    fn resolve_all(mut self) -> (Vec<AliasState>, Vec<Option<TsDeclarationId>>) {
+        let bindings = self.bindings;
+        for alias in bindings.aliases() {
+            self.resolve(alias);
+        }
+        (self.states, self.roots)
+    }
+
+    fn declaration(&self, declaration: TsDeclarationId) -> AliasResolution {
+        let declaration = self.bindings.canonical_value_declaration(declaration);
+        let Some(alias) = self.bindings.declaration_alias(declaration) else {
+            return ControlFlow::Continue(Some(TsValueTarget::Binding(declaration)));
+        };
+        match self.states[alias.index()] {
+            AliasState::Pending => ControlFlow::Break(alias),
+            AliasState::Resolved(target) => ControlFlow::Continue(Some(target)),
+            AliasState::Resolving | AliasState::Unknown => ControlFlow::Continue(None),
+        }
+    }
+
+    fn resolve(&mut self, alias: TsAliasId) {
+        if !matches!(self.states[alias.index()], AliasState::Pending) {
+            return;
+        }
+        let Some((mut frame, mut resolution)) = self.start(alias) else {
+            return;
+        };
+
+        // Alias dependencies can be much deeper than the AST. Keep suspended
+        // paths on the heap and resume their existing member iterators, so a
+        // flat input cannot exhaust the call stack or repeat name lookups.
+        loop {
+            match resolution {
+                ControlFlow::Break(dependency) => {
+                    if let Some((next_frame, next_resolution)) = self.start(dependency) {
+                        self.pending.push(frame);
+                        frame = next_frame;
+                        resolution = next_resolution;
+                    } else {
+                        resolution = ControlFlow::Continue(None);
+                    }
+                }
+                ControlFlow::Continue(result) => {
+                    if let Some(root) = &mut frame.root {
+                        resolution = match self.namespace_root(root) {
+                            ControlFlow::Break(dependency) => ControlFlow::Break(dependency),
+                            ControlFlow::Continue(root) => {
+                                self.roots[frame.alias.index()] = root;
+                                frame.root = None;
+                                root.map_or(ControlFlow::Continue(None), |root| {
+                                    self.declaration(root)
+                                })
+                            }
+                        };
+                        continue;
+                    }
+                    if let Some(target) = result {
+                        if let Some(name) = frame.members.next() {
+                            resolution = self.member(target, name);
+                            continue;
+                        }
+                    }
+                    self.states[frame.alias.index()] = match result {
+                        Some(target) => AliasState::Resolved(target),
+                        None => AliasState::Unknown,
+                    };
+                    let Some(parent) = self.pending.pop() else {
+                        break;
+                    };
+                    frame = parent;
+                }
+            }
+        }
+    }
+
+    fn start(&mut self, alias: TsAliasId) -> Option<(AliasFrame<'a>, AliasResolution)> {
+        self.states[alias.index()] = AliasState::Unknown;
+        let declaration = self.bindings.alias(alias);
+        if declaration.is_type_only {
+            return None;
+        }
+        let path = declaration.path.as_ref()?;
+        let original = self.bindings.declaration_id(&path.root);
+        let mut frame = AliasFrame {
+            alias,
+            members: path.members.as_slice().iter(),
+            root: None,
+        };
+        let resolution = if self.roots.is_empty() {
+            let original = original?;
+            self.states[alias.index()] = AliasState::Resolving;
+            self.declaration(original)
+        } else {
+            let space = if path.members.as_slice().is_empty() {
+                TsReferenceSpace::Any
+            } else {
+                TsReferenceSpace::Namespace
+            };
+            let mut root = AliasRoot {
+                candidates: NamespaceCandidates::new(
+                    self.bindings,
+                    &path.root.0,
+                    path.root.1,
+                    NamespaceAncestors {
+                        bindings: self.bindings,
+                        next: self.bindings.declarations[declaration.declaration.index()].owner,
+                    },
+                    space,
+                ),
+                current: None,
+                original,
+                space,
+            };
+            self.states[alias.index()] = AliasState::Resolving;
+            match self.namespace_root(&mut root) {
+                ControlFlow::Break(dependency) => {
+                    // Only a suspended qualifier lookup needs to retain its
+                    // candidate cursor alongside the ordinary member frame.
+                    frame.root = Some(Box::new(root));
+                    ControlFlow::Break(dependency)
+                }
+                ControlFlow::Continue(root) => {
+                    self.roots[alias.index()] = root;
+                    root.map_or(ControlFlow::Continue(None), |root| self.declaration(root))
+                }
+            }
+        };
+        Some((frame, resolution))
+    }
+
+    fn namespace_root(
+        &self,
+        root: &mut AliasRoot<'a>,
+    ) -> ControlFlow<TsAliasId, Option<TsDeclarationId>> {
+        loop {
+            let Some(declaration) = root.current.or_else(|| root.candidates.next()) else {
+                return ControlFlow::Continue(root.original);
+            };
+            root.current = Some(declaration);
+            let source = self.bindings.declarations[declaration.index()]
+                .export_target
+                .unwrap_or(declaration);
+            let eligible = if root.space == TsReferenceSpace::Any {
+                true
+            } else if let Some(alias) = self.bindings.declaration_alias(source) {
+                match self.states[alias.index()] {
+                    AliasState::Pending => return ControlFlow::Break(alias),
+                    AliasState::Resolved(target) => {
+                        self.bindings.target_has_space(target, root.space)
+                    }
+                    AliasState::Resolving | AliasState::Unknown => true,
+                }
+            } else {
+                self.bindings
+                    .target_has_space(TsValueTarget::Binding(source), root.space)
+            };
+            if eligible {
+                return ControlFlow::Continue(Some(declaration));
+            }
+            root.current = None;
+        }
+    }
+
+    fn member(&self, target: TsValueTarget, name: &Wtf8Atom) -> AliasResolution {
+        let TsValueTarget::Binding(declaration) = target else {
+            return ControlFlow::Continue(None);
+        };
+        let Some(container) = self.bindings.declaration_container(declaration) else {
+            return ControlFlow::Continue(None);
+        };
+        let Some(member_id) = self.bindings.named_member(container, name) else {
+            return ControlFlow::Continue(None);
+        };
+        let member = self.bindings.member(member_id);
+        if member.is_enum_member() {
+            return ControlFlow::Continue(Some(TsValueTarget::EnumMember(member_id)));
+        }
+        // A known type terminal differs from an unknown external target:
+        // it cannot shadow a lexical value or emit an alias.
+        match member.value.or(member.erased) {
+            Some(declaration) => self.declaration(declaration),
+            None => ControlFlow::Continue(None),
+        }
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/collect.rs b/crates/swc_ecma_utils/src/ts_bindings/collect.rs
new file mode 100644
index 0000000000000000000000000000000000000000..8b09528d92de0c2922516cbdf866b7fe6e0448f2
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/collect.rs
@@ -0,0 +1,488 @@
+//! Build a phase-local declaration graph from an unchanged, resolved AST.
+//! Traversal flags and pending exports belong to this walk, not its result.
+
+use swc_ecma_visit::{Visit, VisitWith};
+
+use super::*;
+use crate::{for_each_binding_ident, for_each_ts_fn_param_binding_ident};
+
+impl TsBindings {
+    /// Collect declaration relationships after ordinary lexical resolution.
+    /// No reference is looked up by spelling during this walk.
+    pub fn collect<N: VisitWith<TsBindingCollector>>(node: &N) -> Self {
+        Self::collect_with_observer(node, ()).0
+    }
+
+    /// Collect declaration relationships and phase facts in a single walk.
+    #[doc(hidden)]
+    pub fn collect_with_observer<O: TsBindingObserver, N: VisitWith<TsBindingCollector<O>>>(
+        node: &N,
+        observer: O,
+    ) -> (Self, O) {
+        Self::collect_with_owner_policy::<O, N, true>(node, observer, SyntaxContext::empty())
+    }
+
+    /// Collect namespace members and share erased parameter owners by scope.
+    /// Unresolved names retain individual owners because their context is
+    /// global.
+    #[doc(hidden)]
+    pub fn collect_for_namespace<N: VisitWith<TsBindingCollector<(), false>>>(
+        node: &N,
+        unresolved_ctxt: SyntaxContext,
+    ) -> Self {
+        Self::collect_with_owner_policy::<(), N, false>(node, (), unresolved_ctxt).0
+    }
+
+    fn collect_with_owner_policy<
+        O: TsBindingObserver,
+        N: VisitWith<TsBindingCollector<O, TYPE_OWNERS>>,
+        const TYPE_OWNERS: bool,
+    >(
+        node: &N,
+        observer: O,
+        unresolved_ctxt: SyntaxContext,
+    ) -> (Self, O) {
+        let mut collector = TsBindingCollector::<O, TYPE_OWNERS> {
+            observer,
+            unresolved_ctxt,
+            ..Default::default()
+        };
+        node.visit_with(&mut collector);
+        collector.finish_exports();
+        let mut bindings = collector.bindings;
+        bindings.resolve_aliases();
+        (bindings, collector.observer)
+    }
+}
+
+impl<O: TsBindingObserver, const TYPE_OWNERS: bool> TsBindingCollector<O, TYPE_OWNERS> {
+    fn visit_erased<N: VisitWith<Self>>(&mut self, node: &N) {
+        // Runtime consumers keep the enclosing declaration's identity, but
+        // erased syntax cannot contribute a runtime binding or reference.
+        // Lexical namespace resolution still needs owners inside type scopes.
+        if !O::RUNTIME && O::TYPE_SCOPES {
+            node.visit_children_with(self);
+        }
+    }
+
+    fn record_owner(&mut self, id: Id) {
+        let declaration = self.bindings.register(id, self.body);
+        self.bindings.declarations[declaration.index()].value_space = true;
+    }
+
+    fn record_type_owner(&mut self, ident: &Ident) {
+        if TYPE_OWNERS || ident.ctxt == self.unresolved_ctxt {
+            self.record_owner(ident.to_id());
+        } else if let Some(body) = self.body {
+            // Scope ownership is collected before completion visits any
+            // annotations, including forward parameter queries and class bodies.
+            self.bindings.erased_scopes.insert(ident.ctxt, body);
+        }
+    }
+
+    fn declaration(&mut self, id: Id, value: bool, ty: bool, exported: bool) -> TsDeclarationId {
+        let declaration = self.bindings.register(id, self.body);
+        let facts = &mut self.bindings.declarations[declaration.index()];
+        facts.ambient = self.ambient && (!(facts.value_space || facts.type_space) || facts.ambient);
+        facts.value_space |= value;
+        facts.type_space |= ty;
+        let Some(body) = self.body else {
+            return declaration;
+        };
+        if !(exported || self.implicit_exports) {
+            return declaration;
+        }
+
+        let owner = self.bindings.bodies[body.index()].container;
+        let name = self.bindings.declaration(declaration).0.clone().into();
+        let member = self.bindings.add_member(owner, name);
+        if value {
+            self.value_member(member, declaration);
+        }
+        let facts = &mut self.bindings.members[member.index()];
+        // Namespace and alias candidates do not prove a type meaning. Prefer
+        // a real type contribution when merged bodies provide one later.
+        let replace_erased = ty
+            && facts.erased.map_or(true, |previous| {
+                !self.bindings.declarations[previous.index()].type_space
+            });
+        if replace_erased {
+            facts.erased = Some(declaration);
+        }
+        self.bindings.declarations[declaration.index()].member = Some(member);
+        declaration
+    }
+
+    fn value_member(&mut self, member: TsMemberId, declaration: TsDeclarationId) {
+        let previous = self.bindings.members[member.index()].value;
+        let replaces_ambient = previous.is_some_and(|previous| {
+            self.bindings.declarations[previous.index()].ambient && !self.ambient
+        });
+        if previous.is_none() || replaces_ambient {
+            self.bindings.members[member.index()].value = Some(declaration);
+        }
+    }
+
+    fn container(&mut self, declaration: TsDeclarationId) -> TsContainerId {
+        let member = self.bindings.declarations[declaration.index()].member;
+        let existing = member
+            .and_then(|member| self.bindings.member(member).container)
+            .or_else(|| self.bindings.declaration_container(declaration));
+
+        let container = existing.unwrap_or_else(|| {
+            let container = TsContainerId::from_index(self.bindings.containers.len());
+            self.bindings.containers.push(Container { declaration });
+            container
+        });
+        if let Some(member) = member {
+            self.bindings.members[member.index()].container = Some(container);
+        }
+        self.bindings.declarations[declaration.index()].container = Some(container);
+        container
+    }
+
+    fn type_candidate(&mut self, declaration: TsDeclarationId) {
+        if let Some(member) = self.bindings.declarations[declaration.index()].member {
+            self.bindings.members[member.index()]
+                .erased
+                .get_or_insert(declaration);
+        }
+    }
+
+    fn namespace(&mut self, id: Id, body: &TsNamespaceBody, declare: bool) {
+        let observer_state = self.observer.enter_namespace(&id);
+        let exported = std::mem::take(&mut self.exported);
+        let declaration = self.declaration(id, false, false, exported);
+        let container = self.container(declaration);
+        self.type_candidate(declaration);
+        let next = TsNamespaceBodyId::from_index(self.bindings.bodies.len());
+        self.bindings.bodies.push(NamespaceBody {
+            container,
+            parent: self.body,
+        });
+        let previous_body = self.body.replace(next);
+        let previous_ambient = self.ambient;
+        self.ambient |= declare;
+        let previous_implicit = self.implicit_exports;
+        self.implicit_exports = self.ambient && !exports::has_export_specifiers(body);
+        let previous_value = std::mem::take(&mut self.namespace_has_value);
+
+        body.visit_with(self);
+
+        let value = std::mem::replace(&mut self.namespace_has_value, previous_value);
+        self.ambient = previous_ambient;
+        self.implicit_exports = previous_implicit;
+        self.body = previous_body;
+        // Accumulate nested bodies during the declaration walk rather than
+        // recursively rescanning them for each enclosing namespace.
+        if value {
+            self.bindings.declarations[declaration.index()].value_space = true;
+            if let Some(member) = self.bindings.declarations[declaration.index()].member {
+                self.value_member(member, declaration);
+            }
+            if self.body.is_some() {
+                self.namespace_has_value = true;
+            }
+        }
+        self.observer.leave_namespace(observer_state);
+    }
+
+    fn finish_exports(&mut self) {
+        for export in std::mem::take(&mut self.namespace_exports) {
+            self.bindings.add_namespace_export(export);
+        }
+    }
+}
+
+impl<O: TsBindingObserver, const TYPE_OWNERS: bool> Visit for TsBindingCollector<O, TYPE_OWNERS> {
+    fn visit_module_item(&mut self, node: &ModuleItem) {
+        if self.body.is_some() && !self.namespace_has_value {
+            self.namespace_has_value = namespaces::item_has_value(node);
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_decl(&mut self, node: &Decl) {
+        let state = self.observer.enter_decl(node);
+        node.visit_children_with(self);
+        self.observer.leave_decl(state);
+    }
+
+    fn visit_ident(&mut self, node: &Ident) {
+        self.observer.ident(node);
+    }
+
+    fn visit_expr(&mut self, node: &Expr) {
+        crate::stack_size::maybe_grow_default(|| node.visit_children_with(self));
+    }
+
+    fn visit_ts_type(&mut self, node: &TsType) {
+        self.visit_erased(node);
+    }
+
+    fn visit_ts_expr_with_type_args(&mut self, node: &TsExprWithTypeArgs) {
+        self.visit_erased(node);
+    }
+
+    fn visit_jsx_element_name(&mut self, node: &JSXElementName) {
+        if O::RUNTIME
+            && matches!(node, JSXElementName::Ident(ident) if ident.sym.starts_with(|character: char| character.is_ascii_lowercase()))
+        {
+            return;
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_block_stmt(&mut self, node: &BlockStmt) {
+        let previous = std::mem::take(&mut self.implicit_exports);
+        node.visit_children_with(self);
+        self.implicit_exports = previous;
+    }
+
+    fn visit_named_export(&mut self, node: &NamedExport) {
+        self.observer.named_export(node);
+        let Some(body) = self.body.filter(|_| node.src.is_none()) else {
+            return;
+        };
+        for specifier in &node.specifiers {
+            let ExportSpecifier::Named(specifier) = specifier else {
+                continue;
+            };
+            let ModuleExportName::Ident(source) = &specifier.orig else {
+                continue;
+            };
+            let name = match &specifier.exported {
+                Some(ModuleExportName::Ident(exported)) => exported.sym.clone(),
+                Some(ModuleExportName::Str(_)) => continue,
+                None => source.sym.clone(),
+                #[cfg(swc_ast_unknown)]
+                _ => continue,
+            };
+            self.namespace_exports.push(NamespaceExport {
+                body,
+                source: source.to_id(),
+                name,
+                type_only: node.type_only || specifier.is_type_only,
+            });
+        }
+    }
+
+    fn visit_module(&mut self, node: &Module) {
+        self.observer.module(node);
+        // SWC's Module AST also represents TS scripts containing internal
+        // import-equals declarations. Those aliases remain script globals.
+        self.is_module = node.body.iter().any(|item| match item {
+            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(alias)) => {
+                alias.is_export || matches!(alias.module_ref, TsModuleRef::TsExternalModuleRef(_))
+            }
+            ModuleItem::ModuleDecl(ModuleDecl::TsNamespaceExport(_)) | ModuleItem::Stmt(_) => false,
+            ModuleItem::ModuleDecl(_) => true,
+            #[cfg(swc_ast_unknown)]
+            _ => false,
+        });
+        node.visit_children_with(self);
+    }
+
+    fn visit_script(&mut self, node: &Script) {
+        self.is_module = false;
+        node.visit_children_with(self);
+    }
+
+    fn visit_export_decl(&mut self, node: &ExportDecl) {
+        let previous = std::mem::replace(&mut self.exported, true);
+        node.decl.visit_with(self);
+        self.exported = previous;
+        self.observer.export_decl(node);
+    }
+
+    fn visit_export_default_expr(&mut self, node: &ExportDefaultExpr) {
+        node.expr.visit_with(self);
+        self.observer.export_default_expr(node);
+    }
+
+    fn visit_binding_ident(&mut self, node: &BindingIdent) {
+        // BindingIdent is also used in assignment patterns. Declaration owners
+        // are recorded only from binding positions, never from those uses.
+        node.type_ann.visit_with(self);
+    }
+
+    fn visit_ts_fn_param(&mut self, node: &TsFnParam) {
+        if !O::RUNTIME && O::TYPE_SCOPES {
+            for_each_ts_fn_param_binding_ident(node, |id| self.record_type_owner(&id.id));
+            node.visit_children_with(self);
+        }
+    }
+
+    fn visit_function(&mut self, node: &Function) {
+        if !O::RUNTIME {
+            for_each_binding_ident(&node.params, |id| self.record_owner(id.id.to_id()));
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_arrow_expr(&mut self, node: &ArrowExpr) {
+        if !O::RUNTIME {
+            for_each_binding_ident(&node.params, |id| self.record_owner(id.id.to_id()));
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_constructor(&mut self, node: &Constructor) {
+        if !O::RUNTIME {
+            for_each_binding_ident(&node.params, |id| self.record_owner(id.id.to_id()));
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_catch_clause(&mut self, node: &CatchClause) {
+        if !O::RUNTIME {
+            for_each_binding_ident(&node.param, |id| self.record_owner(id.id.to_id()));
+        }
+        node.visit_children_with(self);
+    }
+
+    fn visit_ts_type_param(&mut self, node: &TsTypeParam) {
+        if !O::RUNTIME && O::TYPE_SCOPES {
+            self.record_type_owner(&node.name);
+            node.constraint.visit_with(self);
+            node.default.visit_with(self);
+        }
+    }
+
+    fn visit_fn_decl(&mut self, node: &FnDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        self.declaration(node.ident.to_id(), true, false, exported);
+        node.function.visit_with(self);
+    }
+
+    fn visit_fn_expr(&mut self, node: &FnExpr) {
+        if !O::RUNTIME {
+            if let Some(ident) = &node.ident {
+                self.record_owner(ident.to_id());
+            }
+        }
+        node.function.visit_with(self);
+    }
+
+    fn visit_class_decl(&mut self, node: &ClassDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        self.declaration(node.ident.to_id(), true, true, exported);
+        node.class.visit_with(self);
+    }
+
+    fn visit_class_expr(&mut self, node: &ClassExpr) {
+        if !O::RUNTIME {
+            if let Some(ident) = &node.ident {
+                self.record_owner(ident.to_id());
+            }
+        }
+        node.class.visit_with(self);
+    }
+
+    fn visit_var_decl(&mut self, node: &VarDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        for_each_binding_ident(&node.decls, |binding| {
+            self.declaration(binding.id.to_id(), true, false, exported);
+        });
+        node.decls.visit_with(self);
+    }
+
+    fn visit_using_decl(&mut self, node: &UsingDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        for_each_binding_ident(&node.decls, |binding| {
+            self.declaration(binding.id.to_id(), true, false, exported);
+        });
+        node.decls.visit_with(self);
+    }
+
+    fn visit_ts_interface_decl(&mut self, node: &TsInterfaceDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        self.declaration(node.id.to_id(), false, true, exported);
+        self.visit_erased(node);
+    }
+
+    fn visit_ts_type_alias_decl(&mut self, node: &TsTypeAliasDecl) {
+        let exported = std::mem::take(&mut self.exported);
+        self.declaration(node.id.to_id(), false, true, exported);
+        self.visit_erased(node);
+    }
+
+    fn visit_ts_enum_decl(&mut self, node: &TsEnumDecl) {
+        self.observer
+            .enum_decl(node, self.ambient || node.declare, self.exported);
+        let exported = std::mem::take(&mut self.exported);
+        let declaration = self.declaration(node.id.to_id(), true, true, exported);
+        let owner = self.container(declaration);
+        for member in &node.members {
+            let name = match &member.id {
+                TsEnumMemberId::Ident(id) => id.sym.clone().into(),
+                TsEnumMemberId::Str(string) => string.value.clone(),
+                #[cfg(swc_ast_unknown)]
+                _ => continue,
+            };
+            let member = self.bindings.add_member(owner, name);
+            self.bindings.members[member.index()].kind = MemberKind::Enum;
+        }
+        node.members.visit_with(self);
+    }
+
+    fn visit_ts_module_decl(&mut self, node: &TsModuleDecl) {
+        self.observer.module_decl(node);
+        match (&node.id, &node.body) {
+            (TsModuleName::Ident(id), Some(body)) if !node.global => {
+                self.namespace(id.to_id(), body, node.declare);
+            }
+            _ => {
+                self.exported = false;
+                // Global augmentations and string-named modules are ambient
+                // scopes even when their children have no `declare` modifier.
+                let previous = std::mem::replace(&mut self.ambient, true);
+                node.body.visit_with(self);
+                self.ambient = previous;
+            }
+        }
+    }
+
+    fn visit_ts_namespace_decl(&mut self, node: &TsNamespaceDecl) {
+        // A dotted namespace segment is an implicitly exported namespace.
+        self.exported = true;
+        self.namespace(node.id.to_id(), &node.body, node.declare);
+    }
+
+    fn visit_import_decl(&mut self, node: &ImportDecl) {
+        for specifier in &node.specifiers {
+            self.record_owner(specifier.local().to_id());
+        }
+    }
+
+    fn visit_ts_import_equals_decl(&mut self, node: &TsImportEqualsDecl) {
+        self.observer.import_equals(node);
+        // Import bindings are private unless explicitly exported, including
+        // inside namespaces with an ambient implicit export context.
+        let previous = std::mem::take(&mut self.implicit_exports);
+        // Alias syntax does not grant an ordinary type meaning. Keep a lookup
+        // candidate and derive its meanings from the resolved target instead.
+        let declaration =
+            self.declaration(node.id.to_id(), !node.is_type_only, false, node.is_export);
+        self.type_candidate(declaration);
+        self.implicit_exports = previous;
+        let path = match &node.module_ref {
+            TsModuleRef::TsEntityName(name) => Some(aliases::path(name)),
+            TsModuleRef::TsExternalModuleRef(_) => None,
+            #[cfg(swc_ast_unknown)]
+            _ => None,
+        };
+        let alias = TsAliasId::from_index(self.bindings.aliases.len());
+        self.bindings.aliases.push(TsAlias {
+            declaration,
+            span: node.span,
+            is_export: node.is_export,
+            is_type_only: node.is_type_only,
+            is_script_global: self.body.is_none() && !self.is_module,
+            path,
+        });
+        self.bindings.declarations[declaration.index()].alias = Some(alias);
+        // Alias roots are dependency edges, not direct runtime uses.
+        self.visit_erased(&node.module_ref);
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/exports.rs b/crates/swc_ecma_utils/src/ts_bindings/exports.rs
new file mode 100644
index 0000000000000000000000000000000000000000..431c535e9ed213a5ae4c0f0569c8515f742bfe25
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/exports.rs
@@ -0,0 +1,71 @@
+//! Namespace export specifiers contribute public names without changing the
+//! source declaration's private identity.
+
+use super::*;
+
+pub(super) fn has_export_specifiers(body: &TsNamespaceBody) -> bool {
+    match body {
+        TsNamespaceBody::TsModuleBlock(block) => block.body.iter().any(|item| {
+            matches!(
+                item,
+                ModuleItem::ModuleDecl(
+                    ModuleDecl::ExportNamed(_)
+                        | ModuleDecl::ExportAll(_)
+                        | ModuleDecl::ExportDefaultExpr(_)
+                        | ModuleDecl::TsExportAssignment(_)
+                )
+            )
+        }),
+        TsNamespaceBody::TsNamespaceDecl(declaration) => has_export_specifiers(&declaration.body),
+        #[cfg(swc_ast_unknown)]
+        _ => false,
+    }
+}
+
+impl TsBindings {
+    pub(super) fn add_namespace_export(&mut self, export: NamespaceExport) {
+        let Some(source) = self.declaration_id(&export.source) else {
+            return;
+        };
+        let source_facts = &self.declarations[source.index()];
+        // Namespace export specifiers refer to that body's declarations. A
+        // malformed outer export must not steal an unrelated lexical ID.
+        if source_facts.owner != Some(export.body) {
+            return;
+        }
+        let value = source_facts.value_space && !export.type_only;
+        let ty = source_facts.type_space;
+        let type_candidate = ty
+            || export.type_only
+            || source_facts.container.is_some()
+            || self.declaration_alias(source).is_some();
+        let ambient = source_facts.ambient;
+        let id = (export.name.clone(), export.source.1);
+        let renamed = id != export.source;
+        if renamed && self.declaration_id(&id).is_some() {
+            return;
+        }
+        let carrier = if renamed {
+            self.register(id, Some(export.body))
+        } else {
+            source
+        };
+        let owner = self.bodies[export.body.index()].container;
+        let member = self.add_member(owner, export.name.into());
+        let facts = &mut self.members[member.index()];
+        if value && facts.value.is_none() {
+            facts.value = Some(carrier);
+        }
+        if type_candidate && facts.erased.is_none() {
+            facts.erased = Some(carrier);
+        }
+        let facts = &mut self.declarations[carrier.index()];
+        facts.ambient = ambient;
+        facts.member = Some(member);
+        facts.value_space |= value;
+        facts.type_space |= ty;
+        if renamed {
+            facts.export_target = Some(source);
+        }
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/ids.rs b/crates/swc_ecma_utils/src/ts_bindings/ids.rs
new file mode 100644
index 0000000000000000000000000000000000000000..35a7003c1bf9cdfba9e0f86205f19ad3cc4d1c82
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/ids.rs
@@ -0,0 +1,58 @@
+//! Arena handles reserve zero for the absence of a relationship. Optional
+//! handles therefore occupy one word throughout declaration and member facts.
+
+use std::{fmt, num::NonZeroUsize};
+
+macro_rules! arena_id {
+    ($(#[$meta:meta])* $name:ident) => {
+        $(#[$meta])*
+        #[repr(transparent)]
+        #[derive(Clone, Copy, PartialEq, Eq, Hash)]
+        pub struct $name(NonZeroUsize);
+
+        impl $name {
+            pub(super) fn from_index(index: usize) -> Self {
+                // Vec arenas cannot contain usize::MAX entries. Keep this
+                // structural invariant checked without exposing raw handles.
+                let value = NonZeroUsize::new(index.wrapping_add(1))
+                    .expect("binding arena indices must be smaller than usize::MAX");
+                Self(value)
+            }
+
+            pub(super) fn index(self) -> usize {
+                self.0.get() - 1
+            }
+        }
+
+        impl fmt::Debug for $name {
+            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
+                formatter.debug_tuple(stringify!($name)).field(&self.index()).finish()
+            }
+        }
+    };
+}
+
+arena_id! {
+    /// A same-file namespace or enum owner, including merged declarations.
+    TsContainerId
+}
+
+arena_id! {
+    /// An exported declaration or enum member under one resolved owner.
+    TsMemberId
+}
+
+arena_id! {
+    /// One namespace declaration body's private lexical environment.
+    TsNamespaceBodyId
+}
+
+arena_id! {
+    /// A declaration ID interned once for this analysis phase.
+    TsDeclarationId
+}
+
+arena_id! {
+    /// An import-equals declaration, kept separate from its terminal target.
+    TsAliasId
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/lookup.rs b/crates/swc_ecma_utils/src/ts_bindings/lookup.rs
new file mode 100644
index 0000000000000000000000000000000000000000..1b0521259b57463247be5401f6af609c53e47ac8
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/lookup.rs
@@ -0,0 +1,91 @@
+//! Namespace candidates share the lexical boundary policy. Alias completion
+//! checks their meanings with its in-progress dependency resolution states.
+
+use super::{scopes::ScopeOwner, *};
+
+pub(super) struct NamespaceCandidates<'a, I> {
+    bindings: &'a TsBindings,
+    name: &'a Wtf8Atom,
+    lexical_owner: Option<ScopeOwner>,
+    bodies: Option<I>,
+    pending: Option<TsDeclarationId>,
+    space: TsReferenceSpace,
+}
+
+impl<'a, I: Iterator<Item = TsNamespaceBodyId>> NamespaceCandidates<'a, I> {
+    pub(super) fn new(
+        bindings: &'a TsBindings,
+        name: &'a Atom,
+        ctxt: SyntaxContext,
+        bodies: I,
+        space: TsReferenceSpace,
+    ) -> Self {
+        let lexical_owner = bindings.erased_scopes.get(ctxt).or_else(|| {
+            bindings
+                .lookup_declaration(name, ctxt)
+                .and_then(|declaration| {
+                    bindings.declarations[declaration.index()]
+                        .owner
+                        .map(ScopeOwner::Body)
+                })
+        });
+        Self {
+            bindings,
+            name: name.borrow(),
+            lexical_owner,
+            bodies: Some(bodies),
+            pending: None,
+            space,
+        }
+    }
+}
+
+impl<I: Iterator<Item = TsNamespaceBodyId>> Iterator for NamespaceCandidates<'_, I> {
+    type Item = TsDeclarationId;
+
+    fn next(&mut self) -> Option<Self::Item> {
+        loop {
+            if let Some(declaration) = self.pending.take() {
+                return Some(declaration);
+            }
+            let body = self.bodies.as_mut()?.next()?;
+            let container = self.bindings.bodies[body.index()].container;
+            if self
+                .lexical_owner
+                .is_some_and(|owner| owner.matches(body, container))
+            {
+                self.bodies = None;
+                return None;
+            }
+            let Some(member) = self.bindings.named_member(container, self.name) else {
+                continue;
+            };
+            let member = self.bindings.member(member);
+            if self.space == TsReferenceSpace::Value {
+                if member.value.is_some() {
+                    return member.value;
+                }
+            } else {
+                self.pending = member.value;
+                if member.erased.is_some() {
+                    return member.erased;
+                }
+            }
+        }
+    }
+}
+
+pub(super) struct NamespaceAncestors<'a> {
+    pub(super) bindings: &'a TsBindings,
+    pub(super) next: Option<TsNamespaceBodyId>,
+}
+
+impl Iterator for NamespaceAncestors<'_> {
+    type Item = TsNamespaceBodyId;
+
+    fn next(&mut self) -> Option<Self::Item> {
+        let body = self.next?;
+        self.next = self.bindings.bodies[body.index()].parent;
+        Some(body)
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/namespaces.rs b/crates/swc_ecma_utils/src/ts_bindings/namespaces.rs
new file mode 100644
index 0000000000000000000000000000000000000000..7db6adf0db43678674cd334712c95b9932bc35bc
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/namespaces.rs
@@ -0,0 +1,31 @@
+//! Direct namespace value contributions. Nested bodies contribute on exit from
+//! the collector's ordinary declaration walk, so each body is inspected once.
+
+use super::*;
+
+pub(super) fn item_has_value(item: &ModuleItem) -> bool {
+    match item {
+        ModuleItem::Stmt(Stmt::Decl(declaration))
+        | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl {
+            decl: declaration,
+            ..
+        })) => !matches!(
+            declaration,
+            Decl::TsInterface(_) | Decl::TsTypeAlias(_) | Decl::TsModule(_)
+        ),
+        ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(alias)) => {
+            // An exported alias instantiates its namespace even when its
+            // target is erased. A private import alone does not instantiate it.
+            alias.is_export && !alias.is_type_only
+        }
+        ModuleItem::ModuleDecl(ModuleDecl::ExportNamed(export)) => {
+            !export.type_only
+                && export.specifiers.iter().any(
+                    |specifier| matches!(specifier, ExportSpecifier::Named(named) if !named.is_type_only),
+                )
+        }
+        ModuleItem::Stmt(Stmt::Empty(_))
+        | ModuleItem::ModuleDecl(ModuleDecl::TsNamespaceExport(_)) => false,
+        _ => true,
+    }
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/observer.rs b/crates/swc_ecma_utils/src/ts_bindings/observer.rs
new file mode 100644
index 0000000000000000000000000000000000000000..ae26780cb348c058f65d5adbac42fc5f65eeb7b2
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/observer.rs
@@ -0,0 +1,47 @@
+use swc_ecma_ast::*;
+
+/// Phase-specific facts collected alongside declaration relationships.
+#[doc(hidden)]
+pub trait TsBindingObserver: Default {
+    /// Skip erased type syntax for runtime consumers. Lexical namespace
+    /// resolution still collects its type-scope declaration owners.
+    /// Parameters, catch bindings and named expression bindings only provide
+    /// lexical shadowing owners, so runtime consumers omit those records too.
+    /// Declared and imported bindings remain available for constant evaluation
+    /// and alias dependencies.
+    const RUNTIME: bool = false;
+
+    /// Whether erased syntax must be walked to collect lexical owners. A
+    /// resolver that supplies its scope facts can omit this repeated analysis.
+    const TYPE_SCOPES: bool = true;
+
+    type DeclarationState;
+    type NamespaceState;
+
+    fn module(&mut self, _: &Module) {}
+    fn enter_decl(&mut self, _: &Decl) -> Self::DeclarationState;
+    fn leave_decl(&mut self, _: Self::DeclarationState);
+    fn ident(&mut self, _: &Ident) {}
+    fn enter_namespace(&mut self, _: &Id) -> Self::NamespaceState;
+    fn leave_namespace(&mut self, _: Self::NamespaceState);
+    fn module_decl(&mut self, _: &TsModuleDecl) {}
+    fn import_equals(&mut self, _: &TsImportEqualsDecl) {}
+    /// Observe inherited ambient status and this declaration's export modifier.
+    fn enum_decl(&mut self, _: &TsEnumDecl, _ambient: bool, _exported: bool) {}
+    fn named_export(&mut self, _: &NamedExport) {}
+    fn export_decl(&mut self, _: &ExportDecl) {}
+    fn export_default_expr(&mut self, _: &ExportDefaultExpr) {}
+}
+
+impl TsBindingObserver for () {
+    type DeclarationState = ();
+    type NamespaceState = ();
+
+    fn enter_decl(&mut self, _: &Decl) {}
+
+    fn leave_decl(&mut self, _: ()) {}
+
+    fn enter_namespace(&mut self, _: &Id) {}
+
+    fn leave_namespace(&mut self, _: ()) {}
+}
diff --git a/crates/swc_ecma_utils/src/ts_bindings/scopes.rs b/crates/swc_ecma_utils/src/ts_bindings/scopes.rs
new file mode 100644
index 0000000000000000000000000000000000000000..30eed6fccfbb2d833446c1fb55c3b81613c119db
--- /dev/null
+++ b/crates/swc_ecma_utils/src/ts_bindings/scopes.rs
@@ -0,0 +1,116 @@
+//! Lexical ownership can come from declaration collection or the resolver's
+//! already completed scope walk. Keep one representation per collection phase.
+
+use std::{hash::BuildHasherDefault, num::NonZeroUsize};
+
+use indexmap::IndexSet;
+use rustc_hash::{FxHashMap, FxHasher};
+use swc_common::SyntaxContext;
+use swc_ecma_ast::{Id, Ident};
+
+use super::{TsBindings, TsContainerId, TsNamespaceBodyId};
+
+/// One namespace identity in a lexical resolver's phase-local scope facts.
+#[doc(hidden)]
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+pub struct TsLexicalNamespaceId(NonZeroUsize);
+
+/// Ownership retained while lexical scopes exist, before declaration graph
+/// handles are available. Each binding context is recorded only once.
+#[doc(hidden)]
+#[derive(Default)]
+pub struct TsLexicalScopes {
+    namespaces: IndexSet<Id, BuildHasherDefault<FxHasher>>,
+    owners: FxHashMap<SyntaxContext, TsLexicalNamespaceId>,
+}
+
+impl TsLexicalScopes {
+    /// Start a new input without retaining its lexical identities.
+    pub fn clear(&mut self) {
+        self.namespaces.clear();
+        self.owners.clear();
+    }
+
+    /// Intern a namespace and report whether this is its first declaration.
+    pub fn namespace(&mut self, ident: &Ident) -> (TsLexicalNamespaceId, bool) {
+        let (index, inserted) = self.namespaces.insert_full(ident.to_id());
+        let id = NonZeroUsize::new(index + 1).expect("namespace index must fit in usize");
+        (TsLexicalNamespaceId(id), inserted)
+    }
+
+    /// Record a non-namespace scope's nearest enclosing namespace.
+    pub fn scope(&mut self, ctxt: SyntaxContext, owner: TsLexicalNamespaceId) {
+        self.owners.insert(ctxt, owner);
+    }
+
+    /// Whether this input contains a namespace declaration.
+    pub fn has_namespaces(&self) -> bool {
+        !self.namespaces.is_empty()
+    }
+
+    pub(super) fn resolve(self, bindings: &TsBindings) -> ScopeOwners {
+        if self.owners.is_empty() {
+            return ScopeOwners::default();
+        }
+        // Join once per namespace, not once per parameter or binding. Transfer
+        // the original scope table instead of allocating and hashing it again.
+        let containers = self
+            .namespaces
+            .iter()
+            .map(|id| bindings.container(id))
+            .collect();
+        ScopeOwners::Lexical {
+            owners: self.owners,
+            containers,
+        }
+    }
+}
+
+#[derive(Debug)]
+pub(super) enum ScopeOwners {
+    Bodies(FxHashMap<SyntaxContext, TsNamespaceBodyId>),
+    Lexical {
+        owners: FxHashMap<SyntaxContext, TsLexicalNamespaceId>,
+        containers: Vec<Option<TsContainerId>>,
+    },
+}
+
+impl Default for ScopeOwners {
+    fn default() -> Self {
+        Self::Bodies(FxHashMap::default())
+    }
+}
+
+impl ScopeOwners {
+    pub(super) fn insert(&mut self, ctxt: SyntaxContext, body: TsNamespaceBodyId) {
+        let Self::Bodies(owners) = self else {
+            unreachable!("lexical scope owners are attached after declaration collection");
+        };
+        owners.insert(ctxt, body);
+    }
+
+    pub(super) fn get(&self, ctxt: SyntaxContext) -> Option<ScopeOwner> {
+        match self {
+            Self::Bodies(owners) => owners.get(&ctxt).copied().map(ScopeOwner::Body),
+            Self::Lexical { owners, containers } => owners
+                .get(&ctxt)
+                .and_then(|owner| containers[owner.0.get() - 1])
+                .map(ScopeOwner::Container),
+        }
+    }
+}
+
+#[derive(Clone, Copy)]
+pub(super) enum ScopeOwner {
+    Body(TsNamespaceBodyId),
+    Container(TsContainerId),
+}
+
+impl ScopeOwner {
+    pub(super) fn matches(self, body: TsNamespaceBodyId, container: TsContainerId) -> bool {
+        match self {
+            Self::Body(owner) => owner == body,
+            Self::Container(owner) => owner == container,
+        }
+    }
+}
diff --git a/Cargo.lock b/Cargo.lock
--- a/Cargo.lock
+++ b/Cargo.lock
@@ -6954,6 +6954,7 @@ name = "swc_ecma_utils"
 version = "36.0.0"
 dependencies = [
  "dragonbox_ecma",
+ "hashbrown 0.14.5",
  "indexmap",
  "num_cpus",
  "once_cell",
PATCH
if command -v patch >/dev/null 2>&1; then
  patch -p1 --fuzz=0 <"$fix"
else
  git apply --whitespace=nowarn "$fix"
fi
rm -f "$fix"
