//! Reconcile the lexical scopes produced by the resolver with TypeScript's
//! declaration merging. Private bindings stay local to a body; exported values
//! are visible from every body, including bodies preceding their declaration.
use rustc_hash::{FxHashMap, FxHashSet};
use swc_ecma_ast::*;
use swc_ecma_utils::{ExprFactory, QueryRef, RefRewriter};
use swc_ecma_visit::{VisitMut, VisitMutWith, VisitWith};

mod declarations;
mod locals;

use self::{declarations::Declarations, locals::Locals};

pub(crate) fn reconcile(program: &mut Program) -> crate::value_bindings::ValueBindings {
    let mut declarations;
    loop {
        declarations = Declarations::default();
        program.visit_with(&mut declarations);
        if !declarations.aliases.is_empty() {
            program.visit_mut_with(&mut Canonicalize(&declarations.aliases));
            // Recollect after canonicalizing nested exported declarations.
            declarations = Declarations::default();
            program.visit_with(&mut declarations);
        }
        if declarations.imports.is_empty() {
            break;
        }
        let bindings = crate::value_bindings::ValueBindings {
            exports: declarations.exports.clone(),
            imports: std::mem::take(&mut declarations.imports),
        };
        let type_aliases: FxHashSet<_> = bindings
            .imports
            .keys()
            .filter(|id| {
                bindings.alias_target(id).is_some_and(|target| {
                    declarations.types.contains(&target) && !declarations.values.contains(&target)
                })
            })
            .cloned()
            .collect();
        if type_aliases.is_empty() {
            break;
        }
        let mut prune = TypeOnlyAliases {
            ids: &type_aliases,
            changed: false,
        };
        program.visit_mut_with(&mut prune);
        if !prune.changed {
            break;
        }
        // Removing an alias can make its containing namespace type-only, which
        // in turn makes aliases to that namespace type-only. Each iteration
        // marks at least one new alias; cycles therefore cannot stall this
        // pass.
    }
    if declarations.members.is_empty() {
        return Default::default();
    }
    let mut references = References {
        declarations: &declarations,
        frames: Vec::new(),
        imports: Default::default(),
    };
    program.visit_mut_with(&mut references);
    let imports = references.imports;
    crate::value_bindings::ValueBindings {
        exports: declarations.exports,
        imports,
    }
}

struct TypeOnlyAliases<'a> {
    ids: &'a FxHashSet<Id>,
    changed: bool,
}
impl VisitMut for TypeOnlyAliases<'_> {
    fn visit_mut_ts_type(&mut self, _: &mut TsType) {}

    fn visit_mut_ts_import_equals_decl(&mut self, n: &mut TsImportEqualsDecl) {
        if !n.is_type_only && self.ids.contains(&n.id.to_id()) {
            n.is_type_only = true;
            self.changed = true;
        }
    }
}

struct Canonicalize<'a>(&'a FxHashMap<Id, Id>);
impl VisitMut for Canonicalize<'_> {
    fn visit_mut_ident(&mut self, n: &mut Ident) {
        if let Some(id) = self.0.get(&n.to_id()) {
            n.ctxt = id.1;
        }
    }
}

struct Frame {
    id: Id,
    locals: FxHashSet<Id>,
}
struct References<'a> {
    declarations: &'a Declarations,
    frames: Vec<Frame>,
    imports: FxHashMap<Id, TsEntityName>,
}
impl QueryRef for References<'_> {
    fn query_ref(&self, ident: &Ident) -> Option<Box<Expr>> {
        for frame in self.frames.iter().rev() {
            if frame.locals.contains(&ident.to_id()) {
                return None;
            }
            if self
                .declarations
                .members
                .get(&frame.id)
                .is_some_and(|members| members.contains(&ident.sym))
            {
                return Some(frame.id.clone().make_member(ident.clone().into()).into());
            }
        }
        None
    }

    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
        self.query_ref(ident)
    }

    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
        let Expr::Member(member) = *self.query_ref(ident)? else {
            return None;
        };
        let Expr::Ident(obj) = *member.obj else {
            return None;
        };
        Some(
            JSXMemberExpr {
                span: ident.span,
                obj: JSXObject::Ident(obj),
                prop: ident.clone().into(),
            }
            .into(),
        )
    }
}
impl QueryRef for &References<'_> {
    fn query_ref(&self, ident: &Ident) -> Option<Box<Expr>> {
        (**self).query_ref(ident)
    }

    fn query_lhs(&self, ident: &Ident) -> Option<Box<Expr>> {
        (**self).query_lhs(ident)
    }

    fn query_jsx(&self, ident: &Ident) -> Option<JSXElementName> {
        (**self).query_jsx(ident)
    }
}
impl References<'_> {
    fn body(&mut self, id: Id, body: &mut TsNamespaceBody) {
        let mut locals = Locals::default();
        body.visit_with(&mut locals);
        self.frames.push(Frame {
            id,
            locals: locals.ids,
        });
        body.visit_mut_with(self);
        self.frames.pop();
    }
}
impl VisitMut for References<'_> {
    fn visit_mut_ts_type(&mut self, _: &mut TsType) {}

    fn visit_mut_ts_import_equals_decl(&mut self, n: &mut TsImportEqualsDecl) {
        if n.is_type_only {
            return;
        }
        n.module_ref.visit_mut_with(self);
        if let TsModuleRef::TsEntityName(name) = &n.module_ref {
            self.imports.insert(n.id.to_id(), name.clone());
        }
    }

    fn visit_mut_ts_entity_name(&mut self, n: &mut TsEntityName) {
        match n {
            TsEntityName::Ident(ident) => {
                let replacement = self.query_ref(ident).or_else(|| {
                    // Exported variables, namespaces, enums and aliases have
                    // property storage even in their own body. Entity names
                    // bypass the ordinary expression reference rewriter.
                    if !self.declarations.properties.contains(&ident.to_id()) {
                        return None;
                    }
                    for frame in self.frames.iter().rev() {
                        if frame.locals.contains(&ident.to_id()) {
                            return (self
                                .declarations
                                .exports
                                .get(&(frame.id.clone(), ident.sym.clone()))
                                == Some(&ident.to_id()))
                            .then(|| frame.id.clone().make_member(ident.clone().into()).into());
                        }
                    }
                    None
                });
                if let Some(expr) = replacement {
                    match *expr {
                        Expr::Member(MemberExpr {
                            obj,
                            prop: MemberProp::Ident(right),
                            ..
                        }) => {
                            if let Expr::Ident(left) = *obj {
                                *n = TsEntityName::TsQualifiedName(Box::new(TsQualifiedName {
                                    span: ident.span,
                                    left: TsEntityName::Ident(left),
                                    right,
                                }));
                            }
                        }
                        Expr::Ident(id) => *ident = id,
                        _ => unreachable!(),
                    }
                }
            }
            TsEntityName::TsQualifiedName(name) => name.left.visit_mut_with(self),
            #[cfg(swc_ast_unknown)]
            _ => {}
        }
    }

    fn visit_mut_ts_module_decl(&mut self, n: &mut TsModuleDecl) {
        if let (TsModuleName::Ident(id), Some(body)) = (&n.id, &mut n.body) {
            self.body(id.to_id(), body);
        }
    }

    fn visit_mut_ts_namespace_decl(&mut self, n: &mut TsNamespaceDecl) {
        self.body(n.id.to_id(), &mut n.body);
    }

    fn visit_mut_ts_enum_decl(&mut self, n: &mut TsEnumDecl) {
        let mut locals = Locals::default();
        n.members.visit_with(&mut locals);
        self.frames.push(Frame {
            id: n.id.to_id(),
            locals: locals.ids,
        });
        n.members.visit_mut_with(self);
        self.frames.pop();
    }

    fn visit_mut_expr(&mut self, n: &mut Expr) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_expr(n);
    }

    fn visit_mut_prop(&mut self, n: &mut Prop) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_prop(n);
    }

    fn visit_mut_pat(&mut self, n: &mut Pat) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_pat(n);
    }

    fn visit_mut_object_pat_prop(&mut self, n: &mut ObjectPatProp) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_object_pat_prop(n);
    }

    fn visit_mut_simple_assign_target(&mut self, n: &mut SimpleAssignTarget) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_simple_assign_target(n);
    }

    fn visit_mut_jsx_element_name(&mut self, n: &mut JSXElementName) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_jsx_element_name(n);
    }

    fn visit_mut_jsx_object(&mut self, n: &mut JSXObject) {
        n.visit_mut_children_with(self);
        RefRewriter { query: &*self }.exit_jsx_object(n);
    }
}
