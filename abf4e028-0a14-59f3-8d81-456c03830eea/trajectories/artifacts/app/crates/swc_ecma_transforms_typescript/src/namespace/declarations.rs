//! Collect identities and value members across all bodies of a namespace.
use rustc_hash::{FxHashMap, FxHashSet};
use swc_atoms::Atom;
use swc_ecma_ast::*;
use swc_ecma_utils::find_pat_ids;
use swc_ecma_visit::{noop_visit_type, Visit, VisitWith};

use crate::retain::IsConcrete;

#[derive(Default)]
pub(super) struct Declarations {
    pub(super) members: FxHashMap<Id, FxHashSet<Atom>>,
    pub(super) exports: FxHashMap<(Id, Atom), Id>,
    pub(super) aliases: FxHashMap<Id, Id>,
    pub(super) properties: FxHashSet<Id>,
    namespace: Option<Id>,
    ambient: bool,
    pub(super) types: FxHashSet<Id>,
    pub(super) values: FxHashSet<Id>,
    pub(super) imports: FxHashMap<Id, TsEntityName>,
}

impl Declarations {
    fn export(&mut self, id: Id) {
        let Some(namespace) = &self.namespace else {
            return;
        };
        self.members
            .entry(namespace.clone())
            .or_default()
            .insert(id.0.clone());
        self.export_type(id);
    }

    fn export_type(&mut self, id: Id) {
        let Some(namespace) = &self.namespace else {
            return;
        };
        let canonical = self
            .exports
            .entry((namespace.clone(), id.0.clone()))
            .or_insert_with(|| id.clone());
        if &id != canonical {
            self.aliases.insert(id, canonical.clone());
        }
    }

    fn export_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Var(n) => {
                for id in find_pat_ids::<_, Id>(&n.decls) {
                    self.properties.insert(id.clone());
                    self.export(id);
                }
            }
            Decl::Fn(n) => self.export(n.ident.to_id()),
            Decl::Class(n) => self.export(n.ident.to_id()),
            Decl::TsEnum(n) => {
                self.properties.insert(n.id.to_id());
                self.export(n.id.to_id());
            }
            Decl::TsModule(n) => {
                if let TsModuleName::Ident(id) = &n.id {
                    if namespace_has_value(n, self.ambient) {
                        self.properties.insert(id.to_id());
                        self.export(id.to_id());
                    } else {
                        self.export_type(id.to_id());
                    }
                }
            }
            Decl::TsInterface(n) => self.export_type(n.id.to_id()),
            Decl::TsTypeAlias(n) => self.export_type(n.id.to_id()),
            _ => {}
        }
    }

    fn body(&mut self, id: Id, body: &TsNamespaceBody) {
        let id = self.aliases.get(&id).cloned().unwrap_or(id);
        let old = self.namespace.replace(id);
        body.visit_with(self);
        self.namespace = old;
    }
}

impl Visit for Declarations {
    noop_visit_type!();

    fn visit_export_decl(&mut self, n: &ExportDecl) {
        self.export_decl(&n.decl);
        n.visit_children_with(self);
    }

    fn visit_ts_import_equals_decl(&mut self, n: &TsImportEqualsDecl) {
        if n.is_type_only {
            self.types.insert(n.id.to_id());
        } else if let TsModuleRef::TsEntityName(name) = &n.module_ref {
            self.imports.insert(n.id.to_id(), name.clone());
        }
        if n.is_export || self.ambient {
            if n.is_type_only {
                self.export_type(n.id.to_id());
            } else {
                self.properties.insert(n.id.to_id());
                self.export(n.id.to_id());
            }
        }
    }

    fn visit_decl(&mut self, n: &Decl) {
        if self.ambient {
            self.export_decl(n);
        }
        match n {
            Decl::TsInterface(n) => {
                self.types.insert(n.id.to_id());
            }
            Decl::TsTypeAlias(n) => {
                self.types.insert(n.id.to_id());
            }
            Decl::Fn(n) => {
                self.values.insert(n.ident.to_id());
            }
            Decl::Class(n) => {
                self.values.insert(n.ident.to_id());
            }
            Decl::Var(n) => {
                self.values.extend(find_pat_ids::<_, Id>(&n.decls));
            }
            _ => {}
        }
        n.visit_children_with(self);
    }

    fn visit_ts_module_decl(&mut self, n: &TsModuleDecl) {
        if let (TsModuleName::Ident(id), Some(body)) = (&n.id, &n.body) {
            if namespace_has_value(n, self.ambient) {
                self.values.insert(id.to_id());
            } else {
                self.types.insert(id.to_id());
            }
            let old = self.ambient;
            self.ambient |= n.declare;
            self.body(id.to_id(), body);
            self.ambient = old;
        }
    }

    fn visit_ts_namespace_decl(&mut self, n: &TsNamespaceDecl) {
        if if n.declare || self.ambient {
            ambient_body_has_value(&n.body)
        } else {
            n.body.is_concrete()
        } {
            self.values.insert(n.id.to_id());
            self.export(n.id.to_id());
        } else {
            self.types.insert(n.id.to_id());
            self.export_type(n.id.to_id());
        }
        let old = self.ambient;
        self.ambient |= n.declare;
        self.body(n.id.to_id(), &n.body);
        self.ambient = old;
    }

    fn visit_ts_enum_decl(&mut self, n: &TsEnumDecl) {
        self.values.insert(n.id.to_id());
        let id = self
            .aliases
            .get(&n.id.to_id())
            .cloned()
            .unwrap_or_else(|| n.id.to_id());
        let members = self.members.entry(id).or_default();
        for member in &n.members {
            match &member.id {
                TsEnumMemberId::Ident(id) => {
                    members.insert(id.sym.clone());
                }
                TsEnumMemberId::Str(s) => {
                    if let Some(name) = s.value.as_atom() {
                        members.insert(name.clone());
                    }
                }
                #[cfg(swc_ast_unknown)]
                _ => {}
            }
        }
        n.members.visit_with(self);
    }
}

/// Ambient functions and variables are values even though they emit no code.
/// A namespace containing only interfaces or type aliases has no value space.
fn namespace_has_value(n: &TsModuleDecl, ambient: bool) -> bool {
    if n.declare || ambient {
        n.body.as_ref().is_some_and(ambient_body_has_value)
    } else {
        n.is_concrete()
    }
}

fn ambient_body_has_value(body: &TsNamespaceBody) -> bool {
    match body {
        TsNamespaceBody::TsNamespaceDecl(n) => ambient_body_has_value(&n.body),
        TsNamespaceBody::TsModuleBlock(block) => block.body.iter().any(|item| match item {
            ModuleItem::Stmt(Stmt::Decl(decl))
            | ModuleItem::ModuleDecl(ModuleDecl::ExportDecl(ExportDecl { decl, .. })) => match decl
            {
                Decl::TsInterface(_) | Decl::TsTypeAlias(_) => false,
                Decl::TsModule(n) => namespace_has_value(n, true),
                _ => true,
            },
            ModuleItem::ModuleDecl(ModuleDecl::TsImportEquals(n)) => !n.is_type_only,
            _ => false,
        }),
        #[cfg(swc_ast_unknown)]
        _ => false,
    }
}
