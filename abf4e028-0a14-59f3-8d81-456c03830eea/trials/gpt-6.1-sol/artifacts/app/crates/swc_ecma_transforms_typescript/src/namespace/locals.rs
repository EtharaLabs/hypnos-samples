use rustc_hash::FxHashSet;
use swc_ecma_ast::*;
use swc_ecma_visit::{noop_visit_type, Visit, VisitWith};

/// Resolved ids distinguish a body's bindings (including nested parameters and
/// block bindings) from outer bindings with the same spelling. Nested namespace
/// and enum bodies get their own frames, so do not collect their bindings here;
/// this also keeps collection linear for deeply nested namespaces.
#[derive(Default)]
pub(super) struct Locals {
    pub(super) ids: FxHashSet<Id>,
    assignment_target: bool,
}
impl Visit for Locals {
    noop_visit_type!();

    fn visit_binding_ident(&mut self, n: &BindingIdent) {
        if !self.assignment_target {
            self.ids.insert(n.to_id());
        }
    }

    fn visit_assign_expr(&mut self, n: &AssignExpr) {
        // Assignment patterns reuse BindingIdent nodes, but do not declare
        // bindings. Their references must participate in merged lookup.
        let old = std::mem::replace(&mut self.assignment_target, true);
        n.left.visit_with(self);
        self.assignment_target = old;
        n.right.visit_with(self);
    }

    fn visit_for_head(&mut self, n: &ForHead) {
        let old = std::mem::replace(&mut self.assignment_target, matches!(n, ForHead::Pat(_)));
        n.visit_children_with(self);
        self.assignment_target = old;
    }

    fn visit_function(&mut self, n: &Function) {
        let old = std::mem::replace(&mut self.assignment_target, false);
        n.visit_children_with(self);
        self.assignment_target = old;
    }

    fn visit_arrow_expr(&mut self, n: &ArrowExpr) {
        let old = std::mem::replace(&mut self.assignment_target, false);
        n.visit_children_with(self);
        self.assignment_target = old;
    }

    fn visit_class(&mut self, n: &Class) {
        let old = std::mem::replace(&mut self.assignment_target, false);
        n.visit_children_with(self);
        self.assignment_target = old;
    }

    fn visit_setter_prop(&mut self, n: &SetterProp) {
        let old = std::mem::replace(&mut self.assignment_target, false);
        n.visit_children_with(self);
        self.assignment_target = old;
    }

    fn visit_fn_decl(&mut self, n: &FnDecl) {
        self.ids.insert(n.ident.to_id());
        n.function.visit_with(self);
    }

    fn visit_class_decl(&mut self, n: &ClassDecl) {
        self.ids.insert(n.ident.to_id());
        n.class.visit_with(self);
    }

    fn visit_fn_expr(&mut self, n: &FnExpr) {
        if let Some(id) = &n.ident {
            self.ids.insert(id.to_id());
        }
        n.function.visit_with(self);
    }

    fn visit_class_expr(&mut self, n: &ClassExpr) {
        if let Some(id) = &n.ident {
            self.ids.insert(id.to_id());
        }
        n.class.visit_with(self);
    }

    fn visit_ts_module_decl(&mut self, n: &TsModuleDecl) {
        if let TsModuleName::Ident(id) = &n.id {
            self.ids.insert(id.to_id());
        }
    }

    fn visit_ts_namespace_decl(&mut self, n: &TsNamespaceDecl) {
        self.ids.insert(n.id.to_id());
    }

    fn visit_ts_enum_decl(&mut self, n: &TsEnumDecl) {
        self.ids.insert(n.id.to_id());
    }

    fn visit_ts_import_equals_decl(&mut self, n: &TsImportEqualsDecl) {
        self.ids.insert(n.id.to_id());
    }
}
