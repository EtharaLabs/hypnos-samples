#!/bin/bash
set -euo pipefail
cd /app
fix=$(mktemp)
cat >"$fix" <<'PATCH'
diff --git a/crates/swc_ecma_ast/src/expr.rs b/crates/swc_ecma_ast/src/expr.rs
index b83a5bda7c..19f52460db 100644
--- a/crates/swc_ecma_ast/src/expr.rs
+++ b/crates/swc_ecma_ast/src/expr.rs
@@ -364,9 +364,14 @@ impl Expr {
         self.directness_matters()
     }
 
-    /// Returns true for `eval` and member expressions.
+    /// Returns true for `eval`, member expressions and `super` property
+    /// accesses such as `super.method`.
+    ///
+    /// Wrapping such an expression in a sequence expression, e.g.
+    /// `(0, super.method)()`, changes the `this` value of the call (or turns a
+    /// direct `eval` into an indirect one), so the wrapper must be kept.
     pub fn directness_matters(&self) -> bool {
-        self.is_ident_ref_to("eval") || matches!(self, Expr::Member(..))
+        self.is_ident_ref_to("eval") || matches!(self, Expr::Member(..) | Expr::SuperProp(..))
     }
 
     pub fn with_span(mut self, span: Span) -> Expr {
diff --git a/crates/swc_ecma_minifier/src/compress/optimize/inline.rs b/crates/swc_ecma_minifier/src/compress/optimize/inline.rs
index c6f642975b..9980d2d15b 100644
--- a/crates/swc_ecma_minifier/src/compress/optimize/inline.rs
+++ b/crates/swc_ecma_minifier/src/compress/optimize/inline.rs
@@ -223,8 +223,7 @@ impl Optimizer<'_> {
                             false
                         } else if let Some(u) = self.data.vars.get(&id.to_id()) {
                             let mut should_inline =
-                                !u.flags.contains(VarUsageInfoFlags::REASSIGNED)
-                                    && u.flags.contains(VarUsageInfoFlags::DECLARED);
+                                !u.may_change() && u.flags.contains(VarUsageInfoFlags::DECLARED);
 
                             should_inline &=
                                 // Function declarations are hoisted
@@ -435,7 +434,7 @@ impl Optimizer<'_> {
                     Expr::Object(..) if self.options.pristine_globals => {
                         for id in idents_used_by_ignoring_nested(init) {
                             if let Some(v_usage) = self.data.vars.get(&id) {
-                                if v_usage.flags.contains(VarUsageInfoFlags::REASSIGNED) {
+                                if v_usage.may_change() {
                                     return;
                                 }
                             }
@@ -448,7 +447,7 @@ impl Optimizer<'_> {
                         }
 
                         if let Some(init_usage) = self.data.vars.get(&id.to_id()) {
-                            if init_usage.flags.contains(VarUsageInfoFlags::REASSIGNED)
+                            if init_usage.may_change()
                                 || !init_usage.flags.contains(VarUsageInfoFlags::DECLARED)
                             {
                                 return;
@@ -482,10 +481,10 @@ impl Optimizer<'_> {
                         for id in idents_used_by(init) {
                             if let Some(v_usage) = self.data.vars.get(&id) {
                                 if v_usage.property_mutation_count > usage.property_mutation_count
-                                    || v_usage.flags.intersects(
-                                        VarUsageInfoFlags::HAS_PROPERTY_ACCESS
-                                            .union(VarUsageInfoFlags::REASSIGNED),
-                                    )
+                                    || v_usage.may_change()
+                                    || v_usage
+                                        .flags
+                                        .contains(VarUsageInfoFlags::HAS_PROPERTY_ACCESS)
                                 {
                                     return;
                                 }
diff --git a/crates/swc_ecma_minifier/src/compress/optimize/sequences.rs b/crates/swc_ecma_minifier/src/compress/optimize/sequences.rs
index 15f598edc7..061c4d1948 100644
--- a/crates/swc_ecma_minifier/src/compress/optimize/sequences.rs
+++ b/crates/swc_ecma_minifier/src/compress/optimize/sequences.rs
@@ -404,8 +404,7 @@ impl Optimizer<'_> {
                 })) => {
                     if let Some(id) = obj.as_ident() {
                         if let Some(usage) = self.data.vars.get(&id.to_id()) {
-                            id.ctxt != self.ctx.expr_ctx.unresolved_ctxt
-                                && !usage.flags.contains(VarUsageInfoFlags::REASSIGNED)
+                            id.ctxt != self.ctx.expr_ctx.unresolved_ctxt && !usage.may_change()
                         } else {
                             false
                         }
@@ -1430,9 +1429,7 @@ impl Optimizer<'_> {
                 };
                 if has_side_effect
                     && !usgae.flags.contains(VarUsageInfoFlags::IS_FN_LOCAL)
-                    && (usgae.flags.intersects(
-                        VarUsageInfoFlags::EXPORTED.union(VarUsageInfoFlags::REASSIGNED),
-                    ))
+                    && (usgae.flags.contains(VarUsageInfoFlags::EXPORTED) || usgae.may_change())
                 {
                     log_abort!("a (expr) has side effect");
                     return false;
@@ -1442,9 +1439,7 @@ impl Optimizer<'_> {
                 if let Some(init) = &a.init {
                     if init.may_have_side_effects(self.ctx.expr_ctx)
                         && !usgae.flags.contains(VarUsageInfoFlags::IS_FN_LOCAL)
-                        && (usgae.flags.intersects(
-                            VarUsageInfoFlags::EXPORTED.union(VarUsageInfoFlags::REASSIGNED),
-                        ))
+                        && (usgae.flags.contains(VarUsageInfoFlags::EXPORTED) || usgae.may_change())
                     {
                         log_abort!("a (var) init has side effect");
                         return false;
@@ -1708,7 +1703,7 @@ impl Optimizer<'_> {
                                         && !usage
                                             .flags
                                             .contains(VarUsageInfoFlags::INLINE_PREVENTED)
-                                        && !usage.flags.contains(VarUsageInfoFlags::REASSIGNED)
+                                        && !usage.may_change()
                                         && !b_left.prop.is_computed()
                                     {
                                         match &*a {
diff --git a/crates/swc_ecma_minifier/src/compress/pure/mod.rs b/crates/swc_ecma_minifier/src/compress/pure/mod.rs
index ff9e506dbb..7ba27ce835 100644
--- a/crates/swc_ecma_minifier/src/compress/pure/mod.rs
+++ b/crates/swc_ecma_minifier/src/compress/pure/mod.rs
@@ -95,6 +95,22 @@ impl Repeated for Pure<'_> {
 }
 
 impl Pure<'_> {
+    /// Returns true if `e` is an anonymous function, arrow function or class
+    /// whose `name` is inferred from the surrounding syntax (e.g. `var f =
+    /// ...`, `{ k: ... }`, `a ||= ...`) only when it is not wrapped in a
+    /// sequence expression, and the user asked to keep the corresponding names.
+    ///
+    /// Unwrapping `(0, function () {})` would make the function observe the
+    /// inferred name, which `keep_fnames` and `keep_classnames` promise to
+    /// preserve.
+    fn is_name_inference_sensitive(&self, e: &Expr) -> bool {
+        match e {
+            Expr::Fn(FnExpr { ident: None, .. }) | Expr::Arrow(..) => self.options.keep_fnames,
+            Expr::Class(ClassExpr { ident: None, .. }) => self.options.keep_classnames,
+            _ => false,
+        }
+    }
+
     #[inline(always)]
     fn is_expr_leaf(e: &Expr) -> bool {
         matches!(
@@ -1303,7 +1319,14 @@ impl VisitMut for Pure<'_> {
 
         e.exprs.retain(|e| !e.is_invalid());
 
-        if !can_change_this && e.exprs.len() == 1 {
+        // Keep a `0` placeholder in front of the last expression if removing the
+        // sequence would change the semantics of the surrounding code:
+        //
+        //  - `this` of a call would change (`(0, a.b)()`).
+        //  - the inferred `name` of an anonymous function or class would change (`var f
+        //    = (0, function () {})`) and the user asked to keep names.
+        if e.exprs.len() == 1 && (!can_change_this || self.is_name_inference_sensitive(&e.exprs[0]))
+        {
             e.exprs.insert(0, 0.into());
         }
 
diff --git a/crates/swc_ecma_minifier/src/program_data.rs b/crates/swc_ecma_minifier/src/program_data.rs
index 1963c5ce5d..06e6fee691 100644
--- a/crates/swc_ecma_minifier/src/program_data.rs
+++ b/crates/swc_ecma_minifier/src/program_data.rs
@@ -58,7 +58,7 @@ bitflags::bitflags! {
         const DECLARED_AS_FN_DECL       = 1 << 3;
         const DECLARED_AS_FN_EXPR       = 1 << 4;
         const DECLARED_AS_FOR_INIT      = 1 << 5;
-        /// The variable itself is assigned after reference.
+        /// The variable itself is reassigned in the current module.
         const REASSIGNED                = 1 << 6;
         const HAS_PROPERTY_ACCESS       = 1 << 7;
         const EXPORTED                  = 1 << 8;
@@ -90,6 +90,9 @@ bitflags::bitflags! {
 
         /// The variable is declared without initializer.
         const LAZY_INIT                 = 1 << 25;
+
+        /// The binding's value may be changed by another module.
+        const EXTERNALLY_MUTABLE        = 1 << 26;
     }
 
     #[derive(Debug, Default, Clone, Copy)]
@@ -159,6 +162,12 @@ impl VarUsageInfo {
         !self.infects_to.is_empty()
     }
 
+    /// Whether the binding's value may change after initialization.
+    pub(crate) fn may_change(&self) -> bool {
+        self.flags
+            .intersects(VarUsageInfoFlags::REASSIGNED | VarUsageInfoFlags::EXTERNALLY_MUTABLE)
+    }
+
     /// The variable itself or a property of it is modified.
     pub(crate) fn mutated(&self) -> bool {
         self.assign_count > 1 || self.property_mutation_count > 0
@@ -301,6 +310,7 @@ impl Storage for ProgramData {
                     let var_info_flags = var_info.flags;
                     let e_flags = &mut e.flags;
                     *e_flags |= var_info_flags & VarUsageInfoFlags::REASSIGNED;
+                    *e_flags |= var_info_flags & VarUsageInfoFlags::EXTERNALLY_MUTABLE;
                     *e_flags |= var_info_flags & VarUsageInfoFlags::HAS_PROPERTY_ACCESS;
                     *e_flags |= var_info_flags & VarUsageInfoFlags::EXPORTED;
                     *e_flags |= var_info_flags & VarUsageInfoFlags::DECLARED;
@@ -690,6 +700,12 @@ impl VarDataLike for VarUsageInfo {
         self.flags.insert(VarUsageInfoFlags::EXPORTED);
     }
 
+    fn mark_as_externally_mutable(&mut self) {
+        // External writes are invisible to assignment counts and scope analysis.
+        self.flags.insert(VarUsageInfoFlags::EXTERNALLY_MUTABLE);
+        self.flags.remove(VarUsageInfoFlags::IS_FN_LOCAL);
+    }
+
     fn mark_initialized_with_safe_value(&mut self) {
         self.flags
             .insert(VarUsageInfoFlags::NO_SIDE_EFFECT_FOR_MEMBER_ACCESS);
diff --git a/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/mod.rs b/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/mod.rs
index e6f9eb0b6e..fbe0976db4 100644
--- a/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/mod.rs
+++ b/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/mod.rs
@@ -1091,14 +1091,17 @@ where
     }
 
     fn visit_import_default_specifier(&mut self, n: &ImportDefaultSpecifier) {
-        self.declare_decl(&n.local, Some(Value::Unknown), None, false);
+        self.declare_decl(&n.local, Some(Value::Unknown), None, false)
+            .mark_as_externally_mutable();
     }
 
     fn visit_import_named_specifier(&mut self, n: &ImportNamedSpecifier) {
-        self.declare_decl(&n.local, Some(Value::Unknown), None, false);
+        self.declare_decl(&n.local, Some(Value::Unknown), None, false)
+            .mark_as_externally_mutable();
     }
 
     fn visit_import_star_as_specifier(&mut self, n: &ImportStarAsSpecifier) {
+        // A namespace object's identity is stable even when its exports change.
         self.declare_decl(&n.local, Some(Value::Unknown), None, false);
     }
 
@@ -1724,10 +1727,6 @@ fn for_each_id_ref_in_expr(e: &Expr, op: &mut impl FnMut(&Ident)) {
             for_each_id_ref_in_class(&c.class, op);
         }
 
-        Expr::Fn(f) => {
-            for_each_id_ref_in_fn(&f.function, op);
-        }
-
         Expr::Seq(s) => {
             for_each_id_ref_in_expr(s.exprs.last().unwrap(), op);
         }
@@ -1754,14 +1753,16 @@ fn for_each_id_ref_in_expr(e: &Expr, op: &mut impl FnMut(&Ident)) {
                     Prop::Assign(p) => {
                         for_each_id_ref_in_expr(&p.value, op);
                     }
+                    // Function bodies and parameter defaults run on invocation, so
+                    // only computed keys can contribute references here.
                     Prop::Getter(p) => {
-                        for_each_id_ref_in_prop_function(&p.key, &p.function, op);
+                        for_each_id_ref_in_prop_name(&p.key, op);
                     }
                     Prop::Setter(p) => {
-                        for_each_id_ref_in_prop_function(&p.key, &p.function, op);
+                        for_each_id_ref_in_prop_name(&p.key, op);
                     }
                     Prop::Method(p) => {
-                        for_each_id_ref_in_prop_function(&p.key, &p.function, op);
+                        for_each_id_ref_in_prop_name(&p.key, op);
                     }
                     #[cfg(swc_ast_unknown)]
                     _ => panic!("unable to access unknown nodes"),
@@ -1776,28 +1777,17 @@ fn for_each_id_ref_in_expr(e: &Expr, op: &mut impl FnMut(&Ident)) {
 
 fn for_each_id_ref_in_class(c: &Class, op: &mut impl FnMut(&Ident)) {
     c.body.iter().for_each(|m| match m {
+        // Like other functions, constructor parameter defaults are evaluated
+        // on each invocation and are not aliased by the class value.
         ClassMember::Constructor(m) => {
             for_each_id_ref_in_prop_name(&m.key, op);
-            m.params.iter().for_each(|p| match p {
-                ParamOrTsParamProp::TsParamProp(..) => {
-                    unreachable!()
-                }
-                ParamOrTsParamProp::Param(p) => {
-                    for_each_id_ref_in_pat(&p.pat, op);
-                }
-                #[cfg(swc_ast_unknown)]
-                _ => panic!("unable to access unknown nodes"),
-            });
         }
 
         ClassMember::Method(m) => {
             for_each_id_ref_in_prop_name(&m.key, op);
-            for_each_id_ref_in_fn(&m.function, op);
         }
 
-        ClassMember::PrivateMethod(m) => {
-            for_each_id_ref_in_fn(&m.function, op);
-        }
+        ClassMember::PrivateMethod(_) => {}
 
         ClassMember::ClassProp(m) => {
             for_each_id_ref_in_prop_name(&m.key, op);
@@ -1835,67 +1825,6 @@ fn for_each_id_ref_in_prop_name(p: &PropName, op: &mut impl FnMut(&Ident)) {
     }
 }
 
-fn for_each_id_ref_in_prop_function(
-    key: &PropName,
-    function: &Function,
-    op: &mut impl FnMut(&Ident),
-) {
-    for_each_id_ref_in_prop_name(key, op);
-    for_each_id_ref_in_fn(function, op);
-}
-
-fn for_each_id_ref_in_pat(p: &Pat, op: &mut impl FnMut(&Ident)) {
-    match p {
-        Pat::Ident(..) => {
-            // IdentifierBinding is not IdentifierReference
-        }
-        Pat::Array(p) => {
-            p.elems.iter().flatten().for_each(|e| {
-                for_each_id_ref_in_pat(e, op);
-            });
-        }
-        Pat::Rest(p) => {
-            for_each_id_ref_in_pat(&p.arg, op);
-        }
-        Pat::Object(p) => {
-            p.props.iter().for_each(|p| match p {
-                ObjectPatProp::KeyValue(p) => {
-                    for_each_id_ref_in_prop_name(&p.key, op);
-                    for_each_id_ref_in_pat(&p.value, op);
-                }
-                ObjectPatProp::Assign(p) => {
-                    // We skip key because it's IdentifierBinding
-
-                    if let Some(value) = &p.value {
-                        for_each_id_ref_in_expr(value, op);
-                    }
-                }
-                ObjectPatProp::Rest(p) => {
-                    for_each_id_ref_in_pat(&p.arg, op);
-                }
-                #[cfg(swc_ast_unknown)]
-                _ => panic!("unable to access unknown nodes"),
-            });
-        }
-        Pat::Assign(p) => {
-            for_each_id_ref_in_pat(&p.left, op);
-            for_each_id_ref_in_expr(&p.right, op);
-        }
-        Pat::Invalid(..) => {}
-        Pat::Expr(p) => {
-            for_each_id_ref_in_expr(p, op);
-        }
-        #[cfg(swc_ast_unknown)]
-        _ => panic!("unable to access unknown nodes"),
-    }
-}
-
-fn for_each_id_ref_in_fn(f: &Function, op: &mut impl FnMut(&Ident)) {
-    for p in &f.params {
-        for_each_id_ref_in_pat(&p.pat, op);
-    }
-}
-
 // Support for pure_getters
 fn is_safe_to_access_prop(e: &Expr) -> bool {
     match e {
diff --git a/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/storage.rs b/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/storage.rs
index 61210081e1..8ec54a7569 100644
--- a/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/storage.rs
+++ b/crates/swc_ecma_minifier/src/usage_analyzer/analyzer/storage.rs
@@ -90,6 +90,8 @@ pub trait VarDataLike: Sized {
 
     fn mark_as_exported(&mut self);
 
+    fn mark_as_externally_mutable(&mut self);
+
     fn mark_initialized_with_safe_value(&mut self);
 
     fn mark_as_pure_fn(&mut self);
diff --git a/crates/swc_ecma_transforms_base/src/rename/ops.rs b/crates/swc_ecma_transforms_base/src/rename/ops.rs
index b7df4ad9fe..1f41a4e358 100644
--- a/crates/swc_ecma_transforms_base/src/rename/ops.rs
+++ b/crates/swc_ecma_transforms_base/src/rename/ops.rs
@@ -466,14 +466,12 @@ where
         n.visit_mut_children_with(self);
 
         if let ObjectPatProp::Assign(p) = n {
-            let mut renamed = Ident::from(&p.key);
-            if self.rename_ident(&mut renamed).is_ok() {
-                if renamed.sym == p.key.sym {
-                    return;
-                }
-
+            // Rename in place so context-only updates keep the correct binding.
+            let key = Ident::from(&p.key);
+            if self.rename_ident(&mut p.key).is_ok() {
+                let renamed = p.key.take();
                 *n = KeyValuePatProp {
-                    key: PropName::Ident(p.key.take().into()),
+                    key: PropName::Ident(key.into()),
                     value: match p.value.take() {
                         Some(default_expr) => AssignPat {
                             span: p.span,
@@ -498,15 +496,12 @@ where
     fn visit_mut_prop(&mut self, prop: &mut Prop) {
         match prop {
             Prop::Shorthand(i) => {
-                let mut renamed = i.clone();
-                if self.rename_ident(&mut renamed).is_ok() {
-                    if renamed.sym == i.sym {
-                        return;
-                    }
-
+                // Keep context-only updates without expanding the shorthand.
+                let key = i.clone();
+                if self.rename_ident(i).is_ok() {
                     *prop = Prop::KeyValue(KeyValueProp {
-                        key: prop_name_from_ident(i.clone()),
-                        value: renamed.into(),
+                        key: prop_name_from_ident(key),
+                        value: i.take().into(),
                     })
                 }
             }
@@ -645,16 +640,17 @@ impl<V> Operator<'_, V>
 where
     V: RenamedVariable,
 {
-    /// Returns `Ok(renamed_ident)` if ident should be renamed.
+    /// Returns `Ok(())` if the identifier's symbol changed.
     fn rename_ident(&mut self, ident: &mut Ident) -> Result<(), ()> {
         if let Some(new_id) = self.rename.get(&ident.to_id()) {
+            // Preserved class names still need their self-references rebound.
+            ident.ctxt = new_id.ctxt();
             let new_sym = new_id.atom();
 
             if ident.sym.eq(new_sym) {
                 return Err(());
             }
 
-            ident.ctxt = new_id.ctxt();
             ident.sym = new_sym.clone();
             return Ok(());
         }
diff --git a/crates/swc_ecma_transforms_optimization/src/simplify/expr/mod.rs b/crates/swc_ecma_transforms_optimization/src/simplify/expr/mod.rs
index 727118f70a..c52cf73d79 100644
--- a/crates/swc_ecma_transforms_optimization/src/simplify/expr/mod.rs
+++ b/crates/swc_ecma_transforms_optimization/src/simplify/expr/mod.rs
@@ -1250,7 +1250,13 @@ pub fn optimize_bin_expr(expr_ctx: ExprCtx, expr: &mut Expr, changed: &mut bool)
                 right: left_rhs,
             }) = &mut **left
             {
-                if *left_op == op {
+                // Bitwise operators work on int32 values, so reassociating them
+                // is always exact. Floating-point multiplication is not
+                // associative, so `*` is reassociated only when the result is
+                // the same for every value of `left_lhs`.
+                if *left_op == op
+                    && (op != op!("*") || is_exact_mul_reassociation(expr_ctx, left_rhs, right))
+                {
                     if let Known(value) = perform_arithmetic_op(expr_ctx, op, left_rhs, right) {
                         let value_expr = Lit::Num(Number {
                             value,
@@ -1437,6 +1443,43 @@ fn try_fold_typeof(_expr_ctx: ExprCtx, expr: &mut Expr, changed: &mut bool) {
     .into();
 }
 
+/// Returns `true` if `(a * b) * c` and `a * (b * c)` evaluate to the same
+/// value for every number `a`.
+///
+/// Floating-point multiplication rounds after each step, so reassociation is
+/// generally not exact. For example, `365.2425 * 24 * 3600` is
+/// `31556951.999999996`, but `365.2425 * 86400` is `31556952`. See
+/// https://github.com/swc-project/swc/issues/12634
+///
+/// The reassociation is exact in these cases:
+///
+/// - `b` or `c` is `1` or `-1`. Multiplication by `-1` only negates the value,
+///   and rounding is symmetric around zero.
+/// - `b` and `c` are powers of two with a magnitude of at least `1`, and their
+///   product is finite. Scaling by such a power of two never rounds. It can
+///   only overflow, and the overflow then occurs in both forms.
+///
+/// Powers of two with a magnitude less than `1` are not accepted. They can
+/// round a subnormal intermediate result, and a mix with larger powers of two
+/// can overflow only in `(a * b) * c`.
+fn is_exact_mul_reassociation(expr_ctx: ExprCtx, b: &Expr, c: &Expr) -> bool {
+    /// Returns `true` if `v` is `±2^n` for some `n >= 0`.
+    fn is_pow2_at_least_one(v: f64) -> bool {
+        const MANTISSA_MASK: u64 = (1 << 52) - 1;
+
+        let v = v.abs();
+        v >= 1.0 && v.is_finite() && v.to_bits() & MANTISSA_MASK == 0
+    }
+
+    let (Known(b), Known(c)) = (b.as_pure_number(expr_ctx), c.as_pure_number(expr_ctx)) else {
+        return false;
+    };
+
+    b.abs() == 1.0
+        || c.abs() == 1.0
+        || (is_pow2_at_least_one(b) && is_pow2_at_least_one(c) && (b * c).is_finite())
+}
+
 /// Try to fold arithmetic binary operators
 fn perform_arithmetic_op(expr_ctx: ExprCtx, op: BinaryOp, left: &Expr, right: &Expr) -> Value<f64> {
     /// Replace only if it becomes shorter
diff --git a/crates/swc_ecma_transforms_optimization/src/simplify/expr/tests.rs b/crates/swc_ecma_transforms_optimization/src/simplify/expr/tests.rs
index fb6382c4c6..f33c1c3d82 100644
--- a/crates/swc_ecma_transforms_optimization/src/simplify/expr/tests.rs
+++ b/crates/swc_ecma_transforms_optimization/src/simplify/expr/tests.rs
@@ -874,10 +874,44 @@ fn non_finite_arithmetic_results_are_number_literals() {
 fn test_fold_arithmetic2() {
     fold_same("x = y + 10 + 20");
     fold_same("x = y / 2 / 4");
-    fold("x = y * 2.25 * 3", "x = y * 6.75");
+    // Floating-point multiplication is not associative.
+    fold_same("x = y * 2.25 * 3");
     fold_same("z = x * y");
     fold_same("x = y * 5");
-    fold("x = y + (z * 24 * 60 * 60 * 1000)", "x = y + z * 86400000");
+    fold(
+        "x = y + (z * 24 * 60 * 60 * 1000)",
+        "x = y + z * 24 * 60 * 60 * 1000",
+    );
+}
+
+/// https://github.com/swc-project/swc/issues/12634
+#[test]
+fn test_fold_mul_reassociation() {
+    // `365.2425 * 24 * 3600` and `365.2425 * 86400` are different numbers.
+    fold_same("x = y * 24 * 60 * 60");
+    fold_same("x = y * 1000 * 60 * 60");
+    fold_same("x = y * 30.44 * 24");
+    // A power of two less than `1` can round a subnormal intermediate result.
+    fold_same("x = y * 0.5 * 0.5");
+    // `(y * 4) * 0.25` overflows for a large `y`, but `y * 1` does not.
+    fold_same("x = y * 4 * 0.25");
+    // `2 ** 1000 * 2 ** 1000` overflows, but `(y * 2 ** 1000) * 2 ** 1000` does
+    // not overflow for a small `y`.
+    fold_same("x = y * 2 ** 1000 * 2 ** 1000");
+
+    // Multiplication by `1` or `-1` never rounds.
+    fold("x = y * 1 * 2.25", "x = y * 2.25");
+    fold("x = y * 2.25 * 1", "x = y * 2.25");
+    fold("x = y * -1 * 2.25", "x = y * -2.25");
+    fold("x = y * 2.25 * -1", "x = y * -2.25");
+    // Multiplication by a power of two of at least `1` never rounds.
+    fold("x = y * 2 * 4", "x = y * 8");
+    fold("x = y * -2 * 1024", "x = y * -2048");
+
+    // Bitwise operators are associative.
+    fold("x = y & 7 & 3", "x = y & 3");
+    fold("x = y | 4 | 3", "x = y | 7");
+    fold("x = y ^ 5 ^ 3", "x = y ^ 6");
 }
 
 #[test]
PATCH
if command -v patch >/dev/null 2>&1; then
  patch -p1 --fuzz=0 <"$fix"
else
  git apply --whitespace=nowarn "$fix"
fi
rm -f "$fix"
