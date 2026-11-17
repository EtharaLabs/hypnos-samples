//! Value identities behind namespace properties and internal import aliases.
use rustc_hash::FxHashMap;
use swc_atoms::Atom;
use swc_ecma_ast::*;

use crate::ts_enum::static_enum_member_name;

#[derive(Debug, Default)]
pub(crate) struct ValueBindings {
    pub exports: FxHashMap<(Id, Atom), Id>,
    pub imports: FxHashMap<Id, TsEntityName>,
}

impl ValueBindings {
    pub fn alias_target(&self, id: &Id) -> Option<Id> {
        self.ident(id.clone(), &mut self.imports.len())
    }

    pub fn property(&self, owner: Id, name: &Atom) -> Option<Id> {
        self.property_with_fuel(owner, name, &mut self.imports.len())
    }

    pub fn expression(&self, expr: &Expr) -> Option<Id> {
        self.expr(expr, &mut self.imports.len())
    }

    fn expr(&self, expr: &Expr, fuel: &mut usize) -> Option<Id> {
        match expr {
            Expr::Ident(id) => self.ident(id.to_id(), fuel),
            Expr::Member(member) => {
                let owner = self.expr(&member.obj, fuel)?;
                let name = static_enum_member_name(&member.prop)?;
                self.property_with_fuel(owner, name.as_atom()?, fuel)
            }
            Expr::Paren(paren) => self.expr(&paren.expr, fuel),
            _ => None,
        }
    }

    fn property_with_fuel(&self, owner: Id, name: &Atom, fuel: &mut usize) -> Option<Id> {
        let id = self.exports.get(&(owner, name.clone()))?;
        self.ident(id.clone(), fuel)
    }

    fn entity(&self, name: &TsEntityName, fuel: &mut usize) -> Option<Id> {
        match name {
            TsEntityName::Ident(id) => self.ident(id.to_id(), fuel),
            TsEntityName::TsQualifiedName(name) => {
                let owner = self.entity(&name.left, fuel)?;
                self.property_with_fuel(owner, &name.right.sym, fuel)
            }
            #[cfg(swc_ast_unknown)]
            _ => None,
        }
    }

    fn ident(&self, id: Id, fuel: &mut usize) -> Option<Id> {
        let Some(alias) = self.imports.get(&id) else {
            return Some(id);
        };
        // Invalid cyclic aliases must not make compilation recurse forever.
        *fuel = fuel.checked_sub(1)?;
        self.entity(alias, fuel)
    }
}
