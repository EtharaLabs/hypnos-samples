#!/bin/bash
set -euo pipefail
cd /app
fix=$(mktemp)
cat >"$fix" <<'PATCH'
diff --git a/crates/biome_js_analyze/src/lint/nursery/no_useless_type_conversion.rs b/crates/biome_js_analyze/src/lint/nursery/no_useless_type_conversion.rs
index f1c883bf54..12a5e65d97 100644
--- a/crates/biome_js_analyze/src/lint/nursery/no_useless_type_conversion.rs
+++ b/crates/biome_js_analyze/src/lint/nursery/no_useless_type_conversion.rs
@@ -436,7 +436,7 @@ fn run_unary_expression(
             let ty = ctx.type_of_expression(&nested_argument)?;
             let primitive = if matches_primitive_type(ty, PrimitiveKind::BigInt) {
                 PrimitiveKind::BigInt
-            } else if ty.is_all_integer_like() {
+            } else if ty.is_unchanged_by_double_bitwise_not() {
                 PrimitiveKind::Number
             } else {
                 return None;
diff --git a/crates/biome_js_analyze/src/lint/nursery/use_exhaustive_switch_cases.rs b/crates/biome_js_analyze/src/lint/nursery/use_exhaustive_switch_cases.rs
index 87470d9cb8..5ab78e59a6 100644
--- a/crates/biome_js_analyze/src/lint/nursery/use_exhaustive_switch_cases.rs
+++ b/crates/biome_js_analyze/src/lint/nursery/use_exhaustive_switch_cases.rs
@@ -133,9 +133,14 @@ impl Rule for UseExhaustiveSwitchCases {
             };
             let ty = ctx.type_of_expression(&test)?;
             let variants = ty.try_switch_case_variants().ok()?;
-            if let [variant] = variants.as_slice()
-                && *variant != InferredSwitchCase::UnsupportedLiteral
-            {
+            if variants.iter().any(|variant| match variant {
+                InferredSwitchCase::String(value) => value.text().contains('\\'),
+                InferredSwitchCase::UnsupportedLiteral => true,
+                _ => false,
+            }) {
+                return None;
+            }
+            if let [variant] = variants.as_slice() {
                 found_cases.push(variant.clone());
             }
         }
@@ -160,6 +165,9 @@ impl Rule for UseExhaustiveSwitchCases {
             .type_of_expression(&discriminant)?
             .try_switch_case_variants()
             .ok()?;
+        if variants.contains(&InferredSwitchCase::UnsupportedLiteral) {
+            return None;
+        }
 
         for variant in variants {
             if variant == InferredSwitchCase::Boolean {
diff --git a/crates/biome_js_syntax/src/numbers.rs b/crates/biome_js_syntax/src/numbers.rs
index e87846996a..18514c110c 100644
--- a/crates/biome_js_syntax/src/numbers.rs
+++ b/crates/biome_js_syntax/src/numbers.rs
@@ -47,6 +47,37 @@ pub fn parse_js_number(num: &str) -> Option<f64> {
     }
 }
 
+/// Parses a numeric literal without rounding intermediate digit prefixes.
+///
+/// Decimal literals are converted directly to `f64`. Hexadecimal, binary, and
+/// octal literals are first read as exact integers, then converted to `f64` once.
+/// This matters for large numbers: rounding each prefix while reading its digits
+/// can produce a different value from the JavaScript literal.
+///
+/// For example, these two spellings must produce the same value:
+///
+/// ```ts
+/// 0x1000000000000081 === 1152921504606847232; // true
+/// ```
+///
+/// The input must be numeric literal text already checked by the parser, with
+/// any unary sign removed. Numeric separators and legacy octal notation are
+/// supported. This function does not validate JavaScript syntax.
+///
+/// Returns `None` if conversion fails or a non-decimal integer exceeds
+/// [`u128::MAX`]. Decimal overflow can return infinity; callers that require a
+/// finite value must check the result.
+pub fn parse_js_number_with_single_rounding(num: &str) -> Option<f64> {
+    let (radix, digits) = split_into_radix_and_number(num);
+    if radix == 10 {
+        digits.parse::<f64>().ok()
+    } else {
+        u128::from_str_radix(&digits, u32::from(radix))
+            .ok()
+            .map(|value| value as f64)
+    }
+}
+
 const BIGINT_LIMB_BASE: u64 = 1_000_000_000;
 
 fn bigint_digit_value(byte: u8) -> Option<u32> {
@@ -197,7 +228,10 @@ pub fn canonicalize_js_bigint_literal(input: &str) -> Option<Cow<'_, str>> {
 mod tests {
     use std::borrow::Cow;
 
-    use super::{canonicalize_js_bigint_literal, split_into_radix_and_number};
+    use super::{
+        canonicalize_js_bigint_literal, parse_js_number_with_single_rounding,
+        split_into_radix_and_number,
+    };
     use biome_js_factory::JsSyntaxTreeBuilder;
     use biome_js_factory::syntax::{JsNumberLiteralExpression, JsSyntaxKind::*};
     use biome_rowan::AstNode;
@@ -213,6 +247,49 @@ mod tests {
         assert_eq!(number_literal.as_number(), Some(value))
     }
 
+    #[test]
+    fn single_rounding_preserves_numeric_values() {
+        for (literal, expected) in [
+            ("1", 1.0),
+            ("1_000", 1000.0),
+            ("0.5", 0.5),
+            (".5", 0.5),
+            ("1e3", 1000.0),
+            ("0b101", 5.0),
+            ("0o77", 63.0),
+            ("077", 63.0),
+            ("0xFF", 255.0),
+            ("0x20000000000001", 9_007_199_254_740_992.0),
+            ("0x1000000000000081", ((1_u64 << 60) + 256) as f64),
+        ] {
+            assert_eq!(
+                parse_js_number_with_single_rounding(literal),
+                Some(expected),
+                "{literal}"
+            );
+        }
+    }
+
+    #[test]
+    fn single_rounding_preserves_conversion_limits() {
+        assert_eq!(
+            parse_js_number_with_single_rounding("0xffffffffffffffffffffffffffffffff"),
+            Some(u128::MAX as f64)
+        );
+        for literal in [
+            format!("0x1{}", "0".repeat(32)),
+            format!("0b1{}", "0".repeat(128)),
+            format!("0o4{}", "0".repeat(42)),
+        ] {
+            assert_eq!(parse_js_number_with_single_rounding(&literal), None);
+        }
+        assert_eq!(
+            parse_js_number_with_single_rounding("1e400"),
+            Some(f64::INFINITY)
+        );
+        assert_eq!(parse_js_number_with_single_rounding(""), None);
+    }
+
     #[test]
     fn canonicalizes_bigint_literals() {
         let cases = [
diff --git a/crates/biome_js_type_info/src/builders.rs b/crates/biome_js_type_info/src/builders.rs
index 20851e63cd..5d1a33d370 100644
--- a/crates/biome_js_type_info/src/builders.rs
+++ b/crates/biome_js_type_info/src/builders.rs
@@ -377,7 +377,7 @@ impl<'db> MergedType<'db> {
             | TypeData::Symbol
             | TypeData::Undefined => Some(Self::Primitive(ty)),
             TypeData::Class(class) => {
-                Some(Self::Object(class_static_members(class.members(db)), false))
+                Some(Self::Object(class_static_members(class.members(db)), true))
             }
             TypeData::Function(function) => Some(Self::Function(function)),
             TypeData::InstanceOf(instance) => match instance.ty(db) {
@@ -400,7 +400,7 @@ impl<'db> MergedType<'db> {
             TypeData::NeverKeyword => Some(Self::Never),
             TypeData::Object(object) => Some(Self::Object(
                 object.members(db).to_vec(),
-                object.has_unknown_members(db),
+                object.has_unknown_members(db) || object.prototype(db).is_some(),
             )),
             TypeData::Unknown | TypeData::UnknownKeyword => Some(Self::Unknown),
             _ => None,
@@ -436,15 +436,15 @@ impl<'db> MergedType<'db> {
     /// Splits the merged type into the parts that intersection combines.
     ///
     /// The trailing flag reports whether the operand could hold members that
-    /// inference did not model. Only an object can carry it; every other kind
-    /// reports `false`.
+    /// inference did not model. Class, interface, and namespace member lists
+    /// may omit inherited or uncollected keys, so they also set this flag.
     fn into_kind_with_members(self) -> (MergedTypeKind, Vec<TypeMember<'db>>, bool) {
         match self {
             Self::Any => (MergedTypeKind::Any, Vec::new(), false),
-            Self::ClassInstance(members) => (MergedTypeKind::ClassInstance, members, false),
+            Self::ClassInstance(members) => (MergedTypeKind::ClassInstance, members, true),
             Self::Function(_) => (MergedTypeKind::Function, Vec::new(), false),
-            Self::Interface(members) => (MergedTypeKind::Interface, members, false),
-            Self::Namespace(members) => (MergedTypeKind::Namespace, members, false),
+            Self::Interface(members) => (MergedTypeKind::Interface, members, true),
+            Self::Namespace(members) => (MergedTypeKind::Namespace, members, true),
             Self::Never => (MergedTypeKind::Never, Vec::new(), false),
             Self::Object(members, has_unknown_members) => {
                 (MergedTypeKind::Object, members, has_unknown_members)
diff --git a/crates/biome_js_type_info/src/format_inferred_type_info.rs b/crates/biome_js_type_info/src/format_inferred_type_info.rs
index fed98e5d81..34610325ce 100644
--- a/crates/biome_js_type_info/src/format_inferred_type_info.rs
+++ b/crates/biome_js_type_info/src/format_inferred_type_info.rs
@@ -152,6 +152,16 @@ impl<'db> Format<FormatInferredTypeContext<'db>> for TypeData<'db> {
                 ]]
             ),
             Self::Literal(literal) => write!(f, [literal]),
+            Self::IndexedAccess(access) => write!(
+                f,
+                [
+                    token("("),
+                    access.object(db),
+                    token(")["),
+                    access.index(db),
+                    token("]")
+                ]
+            ),
             Self::InstanceOf(instance) => {
                 write!(f, [&format_args![token("instanceof"), space(), instance]])
             }
diff --git a/crates/biome_js_type_info/src/format_type_info.rs b/crates/biome_js_type_info/src/format_type_info.rs
index 7414e25f01..2a350aae7a 100644
--- a/crates/biome_js_type_info/src/format_type_info.rs
+++ b/crates/biome_js_type_info/src/format_type_info.rs
@@ -107,6 +107,7 @@ impl Format<FormatTypeContext> for TypeData {
             Self::Intersection(ty) => write!(f, [FmtVerbatim(&ty.as_ref())]),
             Self::Union(union) => write!(f, [&union.as_ref()]),
             Self::TypeOperator(ty) => write!(f, [FmtVerbatim(&ty.as_ref())]),
+            Self::IndexedAccess(ty) => write!(f, [FmtVerbatim(ty.as_ref())]),
             Self::Literal(ty) => write!(f, [&ty.as_ref()]),
             Self::InstanceOf(ty) => write!(
                 f,
diff --git a/crates/biome_js_type_info/src/generated/global_types.rs b/crates/biome_js_type_info/src/generated/global_types.rs
index 82eefcfe40..d406b089b4 100644
--- a/crates/biome_js_type_info/src/generated/global_types.rs
+++ b/crates/biome_js_type_info/src/generated/global_types.rs
@@ -1838,13 +1838,19 @@ pub(crate) static ITERATOR_LOCAL_TYPES: std::sync::LazyLock<[crate::TypeData; 15
                 constraint: crate::TypeReference::unknown(),
                 default: crate::RawTypeId::Local(crate::TypeId::new(3)).into(),
             }),
-            crate::TypeData::from(crate::Tuple(Box::new([]))),
-            crate::TypeData::from(crate::Tuple(Box::new([crate::TupleElementType {
-                ty: crate::RawTypeId::Local(crate::TypeId::new(4)).into(),
-                name: None,
-                is_optional: false,
-                is_rest: false,
-            }]))),
+            crate::TypeData::from(crate::Tuple {
+                elements: Box::new([]),
+                is_inferred_array: false,
+            }),
+            crate::TypeData::from(crate::Tuple {
+                elements: Box::new([crate::TupleElementType {
+                    ty: crate::RawTypeId::Local(crate::TypeId::new(4)).into(),
+                    name: None,
+                    is_optional: false,
+                    is_rest: false,
+                }]),
+                is_inferred_array: false,
+            }),
             crate::TypeData::Union(Box::new(crate::Union(Box::new([
                 crate::RawTypeId::Local(crate::TypeId::new(5)).into(),
                 crate::RawTypeId::Local(crate::TypeId::new(6)).into(),
diff --git a/crates/biome_js_type_info/src/inferred_type.rs b/crates/biome_js_type_info/src/inferred_type.rs
index d3ef1b599f..7f85c75dc2 100644
--- a/crates/biome_js_type_info/src/inferred_type.rs
+++ b/crates/biome_js_type_info/src/inferred_type.rs
@@ -9,7 +9,9 @@ use crate::stringification::{
     StringificationAnalyzer, StringificationMode, StringificationUsefulness,
 };
 use crate::type_traversal::{DepthFirstVisitor, TraversalOutcome, VisitContext};
-use biome_js_syntax::numbers::canonicalize_js_bigint_literal;
+use biome_js_syntax::numbers::{
+    canonicalize_js_bigint_literal, parse_js_number_with_single_rounding,
+};
 use biome_rowan::Text;
 use rustc_hash::FxHashSet;
 use std::{borrow::Cow, collections::VecDeque, fmt, ops::ControlFlow};
@@ -158,14 +160,26 @@ impl<'db> InferredType<'db> {
         .unwrap_or(false)
     }
 
-    pub fn is_all_integer_like(self) -> bool {
+    /// Returns whether `~~` leaves every possible value unchanged.
+    ///
+    /// Bigints are unchanged. Number literals must fit in a signed 32-bit integer
+    /// and must not be negative zero:
+    ///
+    /// ```ts
+    /// ~~(-1);          // -1: unchanged
+    /// ~~(-2147483649); // 2147483647: changed by 32-bit conversion
+    /// ~~(-0);          // 0: the sign is lost
+    /// ```
+    pub fn is_unchanged_by_double_bitwise_not(self) -> bool {
         self.try_all_variants_match(|data| match data {
             TypeData::BigInt => true,
             TypeData::Literal(literal) => match literal.literal(self.db) {
                 Literal::BigInt(_) => true,
-                Literal::Number(number) => {
-                    number.to_f64().is_some_and(|number| number.fract() == 0.0)
-                }
+                Literal::Number(number) => number.to_f64().is_some_and(|number| {
+                    number.fract() == 0.0
+                        && (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&number)
+                        && (number != 0.0 || !number.is_sign_negative())
+                }),
                 _ => false,
             },
             _ => false,
@@ -287,6 +301,7 @@ impl<'db> InferredType<'db> {
                 TypeData::TypeofValue(typeof_value) => typeof_value.ty(self.db),
                 TypeData::Unknown
                 | TypeData::Local(_)
+                | TypeData::IndexedAccess(_)
                 | TypeData::TypeofExpression(_)
                 | TypeData::AnyKeyword
                 | TypeData::UnknownKeyword => return None,
@@ -551,6 +566,7 @@ impl<'db> InferredType<'db> {
                 | TypeData::UnknownKeyword => {
                     indeterminate = true;
                 }
+                TypeData::IndexedAccess(_) => indeterminate = true,
             }
         }
 
@@ -1096,7 +1112,23 @@ impl<'db> InferredType<'db> {
                     Literal::Boolean(boolean) => {
                         InferredSwitchCase::BooleanLiteral(boolean.as_bool())
                     }
-                    Literal::Number(number) => InferredSwitchCase::Number(number.text().clone()),
+                    Literal::Number(number) => {
+                        let value = match number.as_str().strip_prefix('-') {
+                            Some(unsigned) => {
+                                parse_js_number_with_single_rounding(unsigned).map(|value| -value)
+                            }
+                            None => parse_js_number_with_single_rounding(number.as_str()),
+                        };
+                        match value {
+                            Some(value) if value.is_finite() => {
+                                let value = if value == 0.0 { 0.0 } else { value };
+                                InferredSwitchCase::Number(Text::new_owned(
+                                    value.to_string().into(),
+                                ))
+                            }
+                            _ => InferredSwitchCase::UnsupportedLiteral,
+                        }
+                    }
                     Literal::String(string) => {
                         InferredSwitchCase::String(Text::new_owned(string.as_str().into()))
                     }
@@ -1473,6 +1505,7 @@ impl<'db> DepthFirstVisitor<TypeData<'db>> for CallableVisitor<'db> {
         match data {
             TypeData::Unknown
             | TypeData::Local(_)
+            | TypeData::IndexedAccess(_)
             | TypeData::TypeofExpression(_)
             | TypeData::AnyKeyword
             | TypeData::UnknownKeyword => self.indeterminate = true,
@@ -1630,6 +1663,7 @@ mod tests {
         InternedIntersection, InternedLiteral, InternedObject, InternedUnion, TypeMember,
         TypeMemberKind,
     };
+    use crate::literal::NumberLiteral;
 
     #[salsa::db]
     #[derive(Default)]
@@ -1687,6 +1721,34 @@ mod tests {
         );
     }
 
+    #[test]
+    fn numeric_switch_cases_use_values_instead_of_spellings() {
+        let db = TestDb::default();
+        for (source, expected) in [
+            ("0x1", "1"),
+            ("0b1", "1"),
+            ("1.0", "1"),
+            ("1_000", "1000"),
+            ("0.1", "0.1"),
+            (".5", "0.5"),
+            ("-0", "0"),
+            ("-0x2", "-2"),
+        ] {
+            let ty = InferredType::new(
+                &db,
+                TypeData::Literal(InternedLiteral::new(
+                    &db,
+                    Literal::Number(NumberLiteral::new(Text::new_static(source))),
+                )),
+            );
+            assert_eq!(
+                ty.try_switch_case_variants(),
+                Ok(vec![InferredSwitchCase::Number(Text::new_static(expected))]),
+                "{source}"
+            );
+        }
+    }
+
     #[test]
     fn canonical_array_is_truthy_and_non_nullish() {
         let db = TestDb::default();
diff --git a/crates/biome_js_type_info/src/interned_types.rs b/crates/biome_js_type_info/src/interned_types.rs
index 4325e2b8e4..b8106f7a55 100644
--- a/crates/biome_js_type_info/src/interned_types.rs
+++ b/crates/biome_js_type_info/src/interned_types.rs
@@ -124,6 +124,7 @@ pub enum TypeData<'db> {
     Intersection(InternedIntersection<'db>),
     Union(InternedUnion<'db>),
     TypeOperator(InternedTypeOperatorType<'db>),
+    IndexedAccess(InternedIndexedAccessType<'db>),
     Literal(InternedLiteral<'db>),
     InstanceOf(InternedTypeInstance<'db>),
     MergedReference(InternedMergedReference<'db>),
@@ -252,6 +253,7 @@ impl<'db> TypeData<'db> {
             Self::Unknown
                 | Self::Local(_)
                 | Self::TypeofExpression(_)
+                | Self::IndexedAccess(_)
                 | Self::AnyKeyword
                 | Self::UnknownKeyword
         )
@@ -329,6 +331,7 @@ impl<'db> TypeData<'db> {
                 Self::Local(_) => "unresolved",
                 Self::MergedReference(_) => "merged type",
                 Self::TypeOperator(_) => "type operator",
+                Self::IndexedAccess(_) => "indexed access",
                 Self::TypeofExpression(_) | Self::TypeofType(_) | Self::TypeofValue(_) => "typeof",
                 Self::Conditional => "conditional",
                 Self::Global | Self::GlobalType(_) => "global",
@@ -587,6 +590,7 @@ impl<'db> TypeData<'db> {
             | Self::GlobalType(_)
             | Self::Local(_)
             | Self::TypeOperator(_)
+            | Self::IndexedAccess(_)
             | Self::TypeofType(_)
             | Self::TypeofValue(_)
             | Self::InstanceOf(_)
@@ -632,6 +636,7 @@ impl<'db> TypeData<'db> {
             | Self::Local(_)
             | Self::MergedReference(_)
             | Self::TypeOperator(_)
+            | Self::IndexedAccess(_)
             | Self::TypeofExpression(_)
             | Self::TypeofType(_)
             | Self::TypeofValue(_) => false,
@@ -889,6 +894,7 @@ impl<'db> TypeData<'db> {
             | Self::Intersection(_)
             | Self::Union(_)
             | Self::TypeOperator(_)
+            | Self::IndexedAccess(_)
             | Self::Literal(_)
             | Self::InstanceOf(_)
             | Self::MergedReference(_)
@@ -1059,6 +1065,7 @@ impl<'db> TypeData<'db> {
                         is_rest: element.is_rest,
                     })
                     .collect::<Box<[_]>>(),
+                tuple.is_inferred_array,
             )),
             raw::TypeData::Generic(generic) => Self::Generic(InternedGenericTypeParameter::new(
                 db,
@@ -1087,6 +1094,13 @@ impl<'db> TypeData<'db> {
                     type_operator.operator,
                 ))
             }
+            raw::TypeData::IndexedAccess(access) => {
+                Self::IndexedAccess(InternedIndexedAccessType::new(
+                    db,
+                    resolve_reference(&access.object),
+                    resolve_reference(&access.index),
+                ))
+            }
             raw::TypeData::Literal(literal) => Self::Literal(InternedLiteral::new(
                 db,
                 convert_literal(db, literal.as_ref(), resolve_reference),
@@ -1215,6 +1229,9 @@ impl<'db> TypeDataSlots<'db> {
             }
             TypeData::Union(union) => result.slots.extend_from_slice(union.types(db)),
             TypeData::TypeOperator(operator) => result.slots.push(operator.ty(db)),
+            TypeData::IndexedAccess(access) => {
+                result.slots.extend([access.object(db), access.index(db)])
+            }
             TypeData::Literal(literal) => {
                 if let Literal::Object(members) = literal.literal(db) {
                     result.push_type_members_slots(members);
@@ -1494,6 +1511,7 @@ impl<'db> TypeDataSlotReplacements<'db> {
                         Some(element)
                     })
                     .collect::<Option<Box<[_]>>>()?,
+                tuple.is_inferred_array(db),
             )),
             TypeData::Generic(generic) => TypeData::Generic(InternedGenericTypeParameter::new(
                 db,
@@ -1511,6 +1529,11 @@ impl<'db> TypeDataSlotReplacements<'db> {
             TypeData::TypeOperator(operator) => TypeData::TypeOperator(
                 InternedTypeOperatorType::new(db, self.take_type()?, operator.operator(db)),
             ),
+            TypeData::IndexedAccess(_) => TypeData::IndexedAccess(InternedIndexedAccessType::new(
+                db,
+                self.take_type()?,
+                self.take_type()?,
+            )),
             TypeData::Literal(literal) => TypeData::Literal(InternedLiteral::new(
                 db,
                 match literal.literal(db) {
@@ -2358,6 +2381,9 @@ pub struct InternedIntersection<'db> {
 pub struct InternedTuple<'db> {
     #[returns(ref)]
     pub elements: Box<[TupleElementType<'db>]>,
+    /// Whether these elements describe an ordinary mutable array expression.
+    /// See [`raw::Tuple::is_inferred_array`] for examples.
+    pub is_inferred_array: bool,
 }
 
 #[salsa::interned]
@@ -2437,6 +2463,15 @@ pub struct InternedTypeOperatorType<'db> {
     pub operator: raw::TypeOperator,
 }
 
+/// The object and index types of a TypeScript indexed access, stored in the
+/// database. See [`raw::IndexedAccessType`] for an example of the two operands.
+#[salsa::interned]
+#[derive(Debug)]
+pub struct InternedIndexedAccessType<'db> {
+    pub object: TypeData<'db>,
+    pub index: TypeData<'db>,
+}
+
 #[salsa::interned]
 #[derive(Debug)]
 pub struct InternedTypeofExpression<'db> {
@@ -3334,6 +3369,7 @@ mod tests {
                         is_rest: true,
                     },
                 ]),
+                true,
             ))
         });
         assert_identity(&db, |s| {
@@ -3357,6 +3393,9 @@ mod tests {
                 raw::TypeOperator::Readonly,
             ))
         });
+        assert_identity(&db, |s| {
+            TypeData::IndexedAccess(InternedIndexedAccessType::new(&db, s.next(), s.next()))
+        });
         assert_identity(&db, |s| {
             TypeData::Literal(InternedLiteral::new(
                 &db,
diff --git a/crates/biome_js_type_info/src/lib.rs b/crates/biome_js_type_info/src/lib.rs
index 60b294fc1c..e6718a0f48 100644
--- a/crates/biome_js_type_info/src/lib.rs
+++ b/crates/biome_js_type_info/src/lib.rs
@@ -22,6 +22,7 @@ pub mod resolved;
 mod return_type_relation;
 mod stringification;
 mod type_data;
+mod type_operations;
 mod type_store;
 mod type_transform;
 mod type_traversal;
diff --git a/crates/biome_js_type_info/src/local_inference.rs b/crates/biome_js_type_info/src/local_inference.rs
index 467f6724dc..6f92ffff17 100644
--- a/crates/biome_js_type_info/src/local_inference.rs
+++ b/crates/biome_js_type_info/src/local_inference.rs
@@ -42,17 +42,17 @@ use crate::literal::{BooleanLiteral, NumberLiteral, RegexpLiteral, StringLiteral
 use crate::{
     AssertsReturnType, CallArgumentType, Class, Constructor, ConstructorParameter,
     DestructureField, Function, FunctionParameter, FunctionParameterBinding, GenericTypeParameter,
-    Interface, Intersection, Literal, Module, NamedFunctionParameter, Namespace, Object, Path,
-    PatternFunctionParameter, PredicateReturnType, RawTypeCollector, RawTypeId, ReturnType,
-    ScopeId, Tuple, TupleElementType, TypeData, TypeInstance, TypeMember, TypeMemberAccessibility,
-    TypeMemberKind, TypeOperator, TypeOperatorType, TypeReference, TypeReferenceQualifier,
-    TypeofAdditionExpression, TypeofAwaitExpression, TypeofBitwiseNotExpression,
-    TypeofCallArgumentExpression, TypeofCallExpression, TypeofConditionalExpression,
-    TypeofDestructureExpression, TypeofExpression, TypeofIndexExpression,
-    TypeofIterableValueOfExpression, TypeofLogicalAndExpression, TypeofLogicalOrExpression,
-    TypeofNewExpression, TypeofNullishCoalescingExpression, TypeofParameterExpression,
-    TypeofStaticMemberExpression, TypeofThisOrSuperExpression, TypeofTypeofExpression,
-    TypeofUnaryMinusExpression, TypeofValue, Union,
+    IndexedAccessType, Interface, Intersection, Literal, Module, NamedFunctionParameter, Namespace,
+    Object, Path, PatternFunctionParameter, PredicateReturnType, RawTypeCollector, RawTypeId,
+    ReturnType, ScopeId, Tuple, TupleElementType, TypeData, TypeInstance, TypeMember,
+    TypeMemberAccessibility, TypeMemberKind, TypeOperator, TypeOperatorType, TypeReference,
+    TypeReferenceQualifier, TypeofAdditionExpression, TypeofAwaitExpression,
+    TypeofBitwiseNotExpression, TypeofCallArgumentExpression, TypeofCallExpression,
+    TypeofConditionalExpression, TypeofDestructureExpression, TypeofExpression,
+    TypeofIndexExpression, TypeofIterableValueOfExpression, TypeofLogicalAndExpression,
+    TypeofLogicalOrExpression, TypeofNewExpression, TypeofNullishCoalescingExpression,
+    TypeofParameterExpression, TypeofStaticMemberExpression, TypeofThisOrSuperExpression,
+    TypeofTypeofExpression, TypeofUnaryMinusExpression, TypeofValue, Union,
 };
 
 const MAX_CONST_ASSERTION_DEPTH: usize = 50;
@@ -437,8 +437,9 @@ impl TypeData {
             AnyJsExpression::AnyJsLiteralExpression(expr) => {
                 Self::from_any_js_literal_expression(expr).unwrap_or_default()
             }
-            AnyJsExpression::JsArrayExpression(expr) => Self::Tuple(Box::new(Tuple(
-                expr.elements()
+            AnyJsExpression::JsArrayExpression(expr) => Self::Tuple(Box::new(Tuple {
+                elements: expr
+                    .elements()
                     .into_iter()
                     .filter_map(|el| match el {
                         Ok(AnyJsArrayElement::AnyJsExpression(expr)) => Some(TupleElementType {
@@ -465,7 +466,8 @@ impl TypeData {
                         }),
                     })
                     .collect(),
-            ))),
+                is_inferred_array: true,
+            })),
             AnyJsExpression::JsArrowFunctionExpression(expr) => {
                 Self::from_js_arrow_function_expression(collector, scope_id, expr)
             }
@@ -755,10 +757,13 @@ impl TypeData {
                 // TODO: Handle import types (`import("./module").T`).
                 Self::unknown()
             }
-            AnyTsType::TsIndexedAccessType(_) => {
-                // TODO: Handle type indexing (`T[U]`).
-                Self::unknown()
-            }
+            AnyTsType::TsIndexedAccessType(ty) => match (ty.object_type(), ty.index_type()) {
+                (Ok(object), Ok(index)) => Self::IndexedAccess(Box::new(IndexedAccessType {
+                    object: TypeReference::from_any_ts_type(collector, scope_id, &object),
+                    index: TypeReference::from_any_ts_type(collector, scope_id, &index),
+                })),
+                _ => Self::unknown(),
+            },
             AnyTsType::TsInferType(_) => {
                 // TODO: Handle `infer T` syntax.
                 Self::unknown()
@@ -778,20 +783,34 @@ impl TypeData {
             AnyTsType::TsNonPrimitiveType(_) => Self::ObjectKeyword,
             AnyTsType::TsNullLiteralType(_) => Self::Null,
             AnyTsType::TsNumberLiteralType(ty) => match ty.literal_token() {
+                Ok(token) if ty.minus_token().is_some() => Literal::Number(NumberLiteral::new(
+                    format!("-{}", token.text_trimmed()).into(),
+                ))
+                .into(),
                 Ok(token) => {
                     Literal::Number(NumberLiteral::new(token.token_text_trimmed().into())).into()
                 }
                 Err(_) => Self::unknown(),
             },
             AnyTsType::TsNumberType(_) => Self::reference(GLOBAL_NUMBER_ID),
-            AnyTsType::TsObjectType(ty) => Self::object_with_members(
-                ty.members()
+            AnyTsType::TsObjectType(ty) => {
+                let mut has_unknown_members = false;
+                let members = ty
+                    .members()
                     .into_iter()
                     .filter_map(|member| {
-                        TypeMember::from_any_ts_type_member(collector, scope_id, &member)
+                        let member =
+                            TypeMember::from_any_ts_type_member(collector, scope_id, &member);
+                        has_unknown_members |= member.is_none();
+                        member
                     })
-                    .collect(),
-            ),
+                    .collect();
+                Self::Object(Box::new(Object {
+                    prototype: None,
+                    members,
+                    has_unknown_members,
+                }))
+            }
             AnyTsType::TsParenthesizedType(ty) => ty
                 .ty()
                 .map(|ty| Self::from_any_ts_type(collector, scope_id, &ty))
@@ -820,7 +839,10 @@ impl TypeData {
                     })
                     .collect();
                 match elements {
-                    Ok(elements) => Self::Tuple(Box::new(Tuple(elements))),
+                    Ok(elements) => Self::Tuple(Box::new(Tuple {
+                        elements,
+                        is_inferred_array: false,
+                    })),
                     Err(_) => Self::unknown(),
                 }
             }
@@ -1320,6 +1342,20 @@ impl TypeData {
         scope_id: ScopeId,
         expr: &JsUnaryExpression,
     ) -> Self {
+        if let Ok(operator @ (JsUnaryOperator::Minus | JsUnaryOperator::Plus)) = expr.operator()
+            && let Ok(argument) = expr.argument()
+            && let AnyJsExpression::AnyJsLiteralExpression(
+                AnyJsLiteralExpression::JsNumberLiteralExpression(literal),
+            ) = argument.omit_parentheses()
+            && let Some(text) = text_from_token(literal.value_token())
+        {
+            let text = if operator == JsUnaryOperator::Minus {
+                format!("-{text}").into()
+            } else {
+                text
+            };
+            return Literal::Number(NumberLiteral::new(text)).into();
+        }
         expr.operator()
             .map(|operator| match operator {
                 JsUnaryOperator::BitwiseNot => {
@@ -3391,7 +3427,10 @@ fn apply_deep_const_inner(
                     is_rest: element.is_rest,
                 })
                 .collect();
-            TypeData::Tuple(Box::new(Tuple(elements)))
+            TypeData::Tuple(Box::new(Tuple {
+                elements,
+                is_inferred_array: false,
+            }))
         }
         TypeData::Object(object) => TypeData::Object(Box::new(Object {
             prototype: object.prototype.clone(),
diff --git a/crates/biome_js_type_info/src/resolved.rs b/crates/biome_js_type_info/src/resolved.rs
index 6dd03472b5..ced32c0823 100644
--- a/crates/biome_js_type_info/src/resolved.rs
+++ b/crates/biome_js_type_info/src/resolved.rs
@@ -13,11 +13,11 @@ pub use crate::interned_types::{
     FunctionParameterBinding as InferredFunctionParameterBinding, InternedClass as InferredClass,
     InternedConstructor as InferredConstructor, InternedFunction as InferredFunction,
     InternedGenericTypeParameter as InferredGenericTypeParameter,
-    InternedInterface as InferredInterface, InternedIntersection as InferredIntersection,
-    InternedLiteral as InferredLiteral, InternedMergedReference as InferredMergedReference,
-    InternedModule as InferredModule, InternedNamespace as InferredNamespace,
-    InternedObject as InferredObject, InternedTuple as InferredTuple,
-    InternedTypeInstance as InferredTypeInstance,
+    InternedIndexedAccessType as InferredIndexedAccessType, InternedInterface as InferredInterface,
+    InternedIntersection as InferredIntersection, InternedLiteral as InferredLiteral,
+    InternedMergedReference as InferredMergedReference, InternedModule as InferredModule,
+    InternedNamespace as InferredNamespace, InternedObject as InferredObject,
+    InternedTuple as InferredTuple, InternedTypeInstance as InferredTypeInstance,
     InternedTypeOperatorType as InferredTypeOperatorType, InternedTypeofType as InferredTypeofType,
     InternedTypeofValue as InferredTypeofValue, InternedUnion as InferredUnion,
     Literal as InferredLiteralValue, LocalTypeHandle as InferredLocalTypeHandle,
diff --git a/crates/biome_js_type_info/src/return_type_relation.rs b/crates/biome_js_type_info/src/return_type_relation.rs
index e7ba953b12..6ebcecd550 100644
--- a/crates/biome_js_type_info/src/return_type_relation.rs
+++ b/crates/biome_js_type_info/src/return_type_relation.rs
@@ -1032,6 +1032,7 @@ mod tests {
                 is_optional: false,
                 is_rest: false,
             }]) as Box<[_]>,
+            false,
         ))
     }
 
diff --git a/crates/biome_js_type_info/src/type_data.rs b/crates/biome_js_type_info/src/type_data.rs
index 82dbc589c0..aa3593f8b2 100644
--- a/crates/biome_js_type_info/src/type_data.rs
+++ b/crates/biome_js_type_info/src/type_data.rs
@@ -168,6 +168,9 @@ pub enum TypeData {
     /// Type derived from another through a built-in operator.
     TypeOperator(Box<TypeOperatorType>),
 
+    /// A type such as `T[K]`, kept unevaluated until `T` and `K` can be resolved.
+    IndexedAccess(Box<IndexedAccessType>),
+
     /// Literal value used as a type.
     Literal(Box<Literal>),
 
@@ -473,6 +476,7 @@ impl TypeData {
             // class, stripping the instance would change its meaning.
             | Self::Reference(_)
             | Self::TypeOperator(_)
+            | Self::IndexedAccess(_)
             | Self::TypeofExpression(_)
             | Self::TypeofType(_)
             | Self::TypeofValue(_) => false,
@@ -976,24 +980,39 @@ pub struct AssertsReturnType {
 ///
 /// Tuples in TypeScript are created using `Array`s of a fixed size.
 #[derive(Clone, Debug, Eq, Hash, PartialEq)]
-pub struct Tuple(pub(super) Box<[TupleElementType]>);
+pub struct Tuple {
+    pub(super) elements: Box<[TupleElementType]>,
+    /// Whether the elements describe an ordinary mutable array expression.
+    ///
+    /// For example, `mutable` sets this flag, while `fixed` does not:
+    ///
+    /// ```ts
+    /// const mutable = ["A", "B"];
+    /// const fixed = ["A", "B"] as const;
+    /// ```
+    ///
+    /// The initial values of `mutable` do not describe every value it can hold.
+    /// A tuple annotation such as `["A", "B"]` also leaves this flag unset.
+    pub is_inferred_array: bool,
+}
 
 impl Tuple {
     pub fn elements(&self) -> &[TupleElementType] {
-        &self.0
+        &self.elements
     }
 
     /// Returns the element at the given index.
     pub fn get_element(&self, index: usize) -> Option<&TupleElementType> {
-        self.0
+        self.elements
             .get(index)
-            .or_else(|| self.0.last().filter(|last| last.is_rest))
+            .or_else(|| self.elements.last().filter(|last| last.is_rest))
     }
 
     /// Returns a new tuple starting at the given index.
     pub fn slice_from(&self, index: usize) -> Self {
-        Self(
-            self.0
+        Self {
+            elements: self
+                .elements
                 .iter()
                 .skip(index)
                 .map(|element| TupleElementType {
@@ -1002,7 +1021,8 @@ impl Tuple {
                     ..*element
                 })
                 .collect(),
-        )
+            is_inferred_array: self.is_inferred_array,
+        }
     }
 }
 
@@ -1497,6 +1517,21 @@ pub struct TypeOperatorType {
     pub ty: TypeReference,
 }
 
+/// Stores the two types used by a TypeScript indexed access.
+///
+/// In this example, `object` refers to `typeof values` and `index` refers to
+/// `number`. Both are kept as references until inference can resolve them:
+///
+/// ```ts
+/// const values = ["A", "B", "C"] as const;
+/// type Letter = (typeof values)[number];
+/// ```
+#[derive(Clone, Debug, Eq, Hash, PartialEq)]
+pub struct IndexedAccessType {
+    pub object: TypeReference,
+    pub index: TypeReference,
+}
+
 #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
 pub enum TypeOperator {
     Keyof,
diff --git a/crates/biome_js_type_info/src/type_operations.rs b/crates/biome_js_type_info/src/type_operations.rs
new file mode 100644
index 0000000000..fcd2012fab
--- /dev/null
+++ b/crates/biome_js_type_info/src/type_operations.rs
@@ -0,0 +1,157 @@
+//! Evaluates types that select object keys or array elements.
+//!
+//! The operands must already be resolved and normalized: references point to
+//! their types, and wrappers such as `typeof` have been removed. An incomplete
+//! result stays unknown so a lint rule cannot mistake a partial list for every
+//! possible key or element. This does not depend on which branches execute.
+
+use crate::TypeOperator;
+use crate::interned_types::{InternedLiteral, Literal, TypeData, TypeDb, TypeMemberKind};
+use rustc_hash::FxHashSet;
+
+const MAX_PROJECTION_MEMBERS: usize = 1024;
+
+/// Builds a union of the names of an object's properties.
+///
+/// For example, the keys of this object form the type `"A" | "B" | "C"`:
+///
+/// ```ts
+/// const values = { A: 1, B: 2, C: 3 } as const;
+/// type Letter = keyof typeof values;
+/// ```
+///
+/// Returns `None` if the object has uncollected or inherited members, numeric or
+/// computed keys, names requiring escape handling, or more than 1024 members.
+/// Reporting only the keys we know would incorrectly describe the whole object.
+pub(crate) fn keyof<'db>(db: &'db dyn TypeDb, ty: TypeData<'db>) -> Option<TypeData<'db>> {
+    let TypeData::Object(object) = ty else {
+        return None;
+    };
+    if object.has_unknown_members(db) || object.prototype(db).is_some() {
+        return None;
+    }
+    let members = object.members(db);
+    if members.len() > MAX_PROJECTION_MEMBERS {
+        return None;
+    }
+
+    let mut keys = Vec::with_capacity(members.len());
+    for member in members {
+        let name = match &member.kind {
+            TypeMemberKind::Named(name)
+            | TypeMemberKind::NamedOptional(name)
+            | TypeMemberKind::Getter(name)
+            | TypeMemberKind::ConstAssertedNamed(name)
+            | TypeMemberKind::ConstAssertedNamedOptional(name)
+            | TypeMemberKind::ConstAssertedGetter(name) => name,
+            TypeMemberKind::CallSignature | TypeMemberKind::ConstAssertedCallSignature => continue,
+            _ => return None,
+        };
+        // Named members do not retain whether a numeric key was quoted. Those
+        // spellings have different keyof types, so neither can be inferred here.
+        if name.text().contains(['\\', '"', '\n', '\r'])
+            || name
+                .text()
+                .starts_with(|c: char| c.is_ascii_digit() || matches!(c, '.' | '-' | '+'))
+        {
+            return None;
+        }
+        keys.push(TypeData::Literal(InternedLiteral::new(
+            db,
+            Literal::String(name.clone().into()),
+        )));
+    }
+    Some(TypeData::union_from_types(db, keys))
+}
+
+/// Combines the possible element types selected by `T[number]`.
+///
+/// For example, indexing this const tuple produces `"A" | "B" | "C"`:
+///
+/// ```ts
+/// const values = ["A", "B", "C"] as const;
+/// type Letter = (typeof values)[number];
+/// ```
+///
+/// Optional tuple elements also contribute `undefined`. A declared array type
+/// contributes its element type; for example, `("A" | "B")[][number]` produces
+/// `"A" | "B"`.
+///
+/// Returns `None` for unannotated mutable arrays, tuples with rest elements,
+/// indices other than `number`, signed bigint literals, strings requiring escape handling, or work
+/// exceeding 1024 members or visited types. These results must stay unknown.
+pub(crate) fn indexed_access<'db>(
+    db: &'db dyn TypeDb,
+    mut object: TypeData<'db>,
+    index: TypeData<'db>,
+) -> Option<TypeData<'db>> {
+    if index != TypeData::Number {
+        return None;
+    }
+    if let TypeData::TypeOperator(operator) = object
+        && operator.operator(db) == TypeOperator::Readonly
+    {
+        object = operator.ty(db);
+    }
+    let projected = match object {
+        TypeData::Tuple(tuple) => {
+            if tuple.is_inferred_array(db) {
+                return None;
+            }
+            let elements = tuple.elements(db);
+            if elements.len() > MAX_PROJECTION_MEMBERS
+                || elements.iter().any(|element| element.is_rest)
+            {
+                return None;
+            }
+            let mut types = Vec::with_capacity(elements.len() + 1);
+            for element in elements {
+                types.push(element.ty);
+            }
+            if elements.iter().any(|element| element.is_optional) {
+                types.push(TypeData::Undefined);
+            }
+            Some(TypeData::union_from_types(db, types))
+        }
+        TypeData::InstanceOf(instance) if instance.ty(db).is_array_class(db) => {
+            instance.type_parameters(db).first().copied()
+        }
+        _ => None,
+    }?;
+    if projected
+        .union_iterator(db)
+        .any(|ty| ty == TypeData::UnknownKeyword)
+    {
+        return Some(TypeData::UnknownKeyword);
+    }
+
+    let mut pending = vec![projected];
+    let mut seen = FxHashSet::default();
+    // String literals retain their source spelling. Escapes can compare
+    // differently from their values, and quotes or line breaks need escaping
+    // before a consumer can safely insert them into a double-quoted literal.
+    for _ in 0..MAX_PROJECTION_MEMBERS {
+        let Some(ty) = pending.pop() else {
+            return Some(projected);
+        };
+        if !seen.insert(ty) {
+            continue;
+        }
+        match ty {
+            TypeData::Literal(literal) => match literal.literal(db) {
+                Literal::String(string) if string.as_str().contains(['\\', '"', '\n', '\r']) => {
+                    return None;
+                }
+                Literal::BigInt(bigint) if bigint.text().starts_with('-') => return None,
+                _ => {}
+            },
+            TypeData::Union(union) => pending.extend(union.types(db).iter().copied()),
+            TypeData::Intersection(intersection) => {
+                pending.extend(intersection.types(db).iter().copied())
+            }
+            TypeData::InstanceOf(instance) => pending.push(instance.ty(db)),
+            _ => {}
+        }
+    }
+    pending.is_empty().then_some(projected)
+}
diff --git a/crates/biome_js_type_info/src/type_transform.rs b/crates/biome_js_type_info/src/type_transform.rs
index d1a6705570..ce6c949f71 100644
--- a/crates/biome_js_type_info/src/type_transform.rs
+++ b/crates/biome_js_type_info/src/type_transform.rs
@@ -5,7 +5,9 @@
 //! the nested types have been transformed. The traversal remains private;
 //! callers use semantic operations such as generic substitution.
 
+use crate::TypeOperator;
 use crate::interned_types::{TypeData, TypeDataSlotRebuilder, TypeDb};
+use crate::type_operations::{indexed_access, keyof};
 use rustc_hash::FxHashSet;
 
 pub(crate) const MAX_TYPE_SUBSTITUTION_STEPS: usize = 1024;
@@ -377,6 +379,12 @@ where
             }
             TypeData::TypeofType(value) => value.ty(db),
             TypeData::TypeofValue(value) => value.ty(db),
+            TypeData::TypeOperator(operator) if operator.operator(db) == TypeOperator::Keyof => {
+                keyof(db, operator.ty(db)).unwrap_or(TypeData::Unknown)
+            }
+            TypeData::IndexedAccess(access) => {
+                indexed_access(db, access.object(db), access.index(db)).unwrap_or(TypeData::Unknown)
+            }
             ty => ty,
         }
     }
diff --git a/crates/biome_module_graph/src/db/queries/type_inference/calls/implementation.rs b/crates/biome_module_graph/src/db/queries/type_inference/calls/implementation.rs
index 67706048d9..1269817151 100644
--- a/crates/biome_module_graph/src/db/queries/type_inference/calls/implementation.rs
+++ b/crates/biome_module_graph/src/db/queries/type_inference/calls/implementation.rs
@@ -1203,6 +1203,7 @@ impl<'db> ArgumentTypeCompatibility<'db> {
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::ObjectKeyword
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::TypeofExpression(_),
                 _,
             )
@@ -1214,6 +1215,7 @@ impl<'db> ArgumentTypeCompatibility<'db> {
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::ObjectKeyword
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::TypeofExpression(_),
             )
             | (
diff --git a/crates/biome_module_graph/src/db/queries/type_inference/normalization.rs b/crates/biome_module_graph/src/db/queries/type_inference/normalization.rs
index 6ae0e74b48..00b7618f25 100644
--- a/crates/biome_module_graph/src/db/queries/type_inference/normalization.rs
+++ b/crates/biome_module_graph/src/db/queries/type_inference/normalization.rs
@@ -50,6 +50,8 @@ fn type_needs_normalization(ty: InferredTypeData<'_>) -> bool {
     matches!(
         ty,
         InferredTypeData::InstanceOf(_)
+            | InferredTypeData::IndexedAccess(_)
+            | InferredTypeData::TypeOperator(_)
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Local(_)
             | InferredTypeData::MergedReference(_)
diff --git a/crates/biome_module_graph/src/db/type_inference/expressions.rs b/crates/biome_module_graph/src/db/type_inference/expressions.rs
index 8152df915a..e527dc1adb 100644
--- a/crates/biome_module_graph/src/db/type_inference/expressions.rs
+++ b/crates/biome_module_graph/src/db/type_inference/expressions.rs
@@ -605,6 +605,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
@@ -797,6 +798,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -871,6 +873,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -918,6 +921,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::InstanceOf(_)
                 | InferredTypeData::MergedReference(_)
@@ -1188,6 +1192,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
@@ -1233,6 +1238,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
@@ -1331,6 +1337,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                         | InferredTypeData::Intersection(_)
                         | InferredTypeData::Union(_)
                         | InferredTypeData::TypeOperator(_)
+                        | InferredTypeData::IndexedAccess(_)
                         | InferredTypeData::Literal(_)
                         | InferredTypeData::InstanceOf(_)
                         | InferredTypeData::MergedReference(_)
@@ -1398,6 +1405,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Local(_)
             | InferredTypeData::Intersection(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -1520,6 +1528,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | RawTypeData::Intersection(_)
             | RawTypeData::Union(_)
             | RawTypeData::TypeOperator(_)
+            | RawTypeData::IndexedAccess(_)
             | RawTypeData::InstanceOf(_)
             | RawTypeData::Reference(_)
             | RawTypeData::MergedReference(_)
@@ -1791,6 +1800,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Local(_)
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::InstanceOf(_)
                 | InferredTypeData::MergedReference(_)
@@ -1893,6 +1903,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Local(_)
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::InstanceOf(_)
                 | InferredTypeData::MergedReference(_)
@@ -1925,7 +1936,9 @@ impl<'db> ResolutionCtx<'db, '_> {
                     .cloned()
                     .collect::<Box<[InferredTupleElementType<'db>]>>();
                 Some(InferredTypeData::Tuple(InferredTuple::new(
-                    self.db, elements,
+                    self.db,
+                    elements,
+                    tuple.is_inferred_array(self.db),
                 )))
             }
             InferredTypeData::InstanceOf(instance)
@@ -1964,6 +1977,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
@@ -2024,6 +2038,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -2133,6 +2148,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::MergedReference(_)
                 | InferredTypeData::TypeofExpression(_)
                 | InferredTypeData::TypeofType(_)
@@ -2245,6 +2261,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
             | InferredTypeData::TypeofType(_)
@@ -2286,6 +2303,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
@@ -2342,6 +2360,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -2430,6 +2449,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                     | InferredTypeData::Generic(_)
                     | InferredTypeData::Local(_)
                     | InferredTypeData::TypeOperator(_)
+                    | InferredTypeData::IndexedAccess(_)
                     | InferredTypeData::Literal(_)
                     | InferredTypeData::AnyKeyword
                     | InferredTypeData::NeverKeyword
@@ -2509,6 +2529,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                     | InferredTypeData::Local(_)
                     | InferredTypeData::Intersection(_)
                     | InferredTypeData::TypeOperator(_)
+                    | InferredTypeData::IndexedAccess(_)
                     | InferredTypeData::Literal(_)
                     | InferredTypeData::MergedReference(_)
                     | InferredTypeData::AnyKeyword
@@ -2556,6 +2577,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::InstanceOf(_)
                 | InferredTypeData::MergedReference(_)
@@ -2603,6 +2625,7 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::InstanceOf(_)
                 | InferredTypeData::MergedReference(_)
diff --git a/crates/biome_module_graph/src/db/type_inference/lookup.rs b/crates/biome_module_graph/src/db/type_inference/lookup.rs
index 366058c618..d002db5145 100644
--- a/crates/biome_module_graph/src/db/type_inference/lookup.rs
+++ b/crates/biome_module_graph/src/db/type_inference/lookup.rs
@@ -453,6 +453,7 @@ pub(in crate::db::type_inference) fn find_member_type_with_resolver<'db>(
             | InferredTypeData::Tuple(_)
             | InferredTypeData::Local(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::TypeofExpression(_)
@@ -533,6 +534,7 @@ fn declared_type_parameters<'db>(
         | InferredTypeData::Intersection(_)
         | InferredTypeData::Union(_)
         | InferredTypeData::TypeOperator(_)
+        | InferredTypeData::IndexedAccess(_)
         | InferredTypeData::Literal(_)
         | InferredTypeData::MergedReference(_)
         | InferredTypeData::TypeofExpression(_)
@@ -605,6 +607,7 @@ fn class_side_type<'db>(db: &'db dyn ModuleDb, ty: InferredTypeData<'db>) -> Inf
         | InferredTypeData::Intersection(_)
         | InferredTypeData::Union(_)
         | InferredTypeData::TypeOperator(_)
+        | InferredTypeData::IndexedAccess(_)
         | InferredTypeData::Literal(_)
         | InferredTypeData::MergedReference(_)
         | InferredTypeData::TypeofExpression(_)
@@ -709,6 +712,7 @@ fn find_own_member_type<'db>(
         | InferredTypeData::Intersection(_)
         | InferredTypeData::Union(_)
         | InferredTypeData::TypeOperator(_)
+        | InferredTypeData::IndexedAccess(_)
         | InferredTypeData::InstanceOf(_)
         | InferredTypeData::MergedReference(_)
         | InferredTypeData::TypeofExpression(_)
diff --git a/crates/biome_module_graph/src/db/type_inference/promise_classification.rs b/crates/biome_module_graph/src/db/type_inference/promise_classification.rs
index 9ecad31f9e..f40d6fdd9a 100644
--- a/crates/biome_module_graph/src/db/type_inference/promise_classification.rs
+++ b/crates/biome_module_graph/src/db/type_inference/promise_classification.rs
@@ -955,6 +955,7 @@ fn classify_expression(
                     | RawTypeData::Intersection(_)
                     | RawTypeData::Union(_)
                     | RawTypeData::TypeOperator(_)
+                    | RawTypeData::IndexedAccess(_)
                     | RawTypeData::MergedReference(_)
                     | RawTypeData::AnyKeyword
                     | RawTypeData::UnknownKeyword => return Indeterminate,
diff --git a/crates/biome_module_graph/src/db/type_inference/qualifiers.rs b/crates/biome_module_graph/src/db/type_inference/qualifiers.rs
index 1e785b4618..3bc49a5a08 100644
--- a/crates/biome_module_graph/src/db/type_inference/qualifiers.rs
+++ b/crates/biome_module_graph/src/db/type_inference/qualifiers.rs
@@ -10,9 +10,9 @@ use biome_js_type_info::{
     Path, TypeImportQualifier, TypeReference, TypeReferenceQualifier, TypeResolverLevel,
     global_type_id_for_qualifier,
     interned_types::{
-        Literal as InferredLiteral, LocalTypeHandle, LocalTypeId, TypeData as InferredTypeData,
-        TypeMember as InferredTypeMember, TypeMemberKind as InferredTypeMemberKind,
-        well_known_symbol_type,
+        InternedObject as InferredObject, Literal as InferredLiteral, LocalTypeHandle, LocalTypeId,
+        TypeData as InferredTypeData, TypeMember as InferredTypeMember,
+        TypeMemberKind as InferredTypeMemberKind, well_known_symbol_type,
     },
 };
 use biome_rowan::Text;
@@ -562,6 +562,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::Literal(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -585,15 +586,26 @@ impl<'db> ResolutionCtx<'db, '_> {
         let Some(key_names) = self.string_literal_keys(key_ty) else {
             return InferredTypeData::Unknown;
         };
-        let Some(members) = self.own_members(target_ty) else {
+        if key_names.iter().any(|key| key.text().contains('\\')) {
+            return InferredTypeData::Unknown;
+        }
+        let Some((members, has_unknown_members)) = self.own_members(target_ty) else {
             return InferredTypeData::Unknown;
         };
 
-        if qualifier.is_pick() {
+        let has_unknown_members = has_unknown_members
+            || qualifier.is_pick()
+                && key_names.iter().any(|key| {
+                    !members
+                        .iter()
+                        .any(|member| member.kind.has_name(key.text()))
+                });
+        let ty = if qualifier.is_pick() {
             InferredTypeData::pick_members(self.db, members, &key_names)
         } else {
             InferredTypeData::omit_members(self.db, members, &key_names)
-        }
+        };
+        self.preserve_unknown_members(ty, has_unknown_members)
     }
 
     fn resolve_partial_or_required(
@@ -601,37 +613,81 @@ impl<'db> ResolutionCtx<'db, '_> {
         qualifier: &TypeReferenceQualifier,
     ) -> InferredTypeData<'db> {
         let target_ty = self.resolve(&qualifier.type_parameters[0]);
-        let Some(members) = self.own_members(target_ty) else {
+        let Some((members, has_unknown_members)) = self.own_members(target_ty) else {
             return InferredTypeData::Unknown;
         };
 
-        if qualifier.is_partial() {
+        let ty = if qualifier.is_partial() {
             InferredTypeData::with_all_optional_members(self.db, members)
         } else {
             InferredTypeData::with_all_required_members(self.db, members)
-        }
+        };
+        self.preserve_unknown_members(ty, has_unknown_members)
     }
 
     fn resolve_readonly(&mut self, qualifier: &TypeReferenceQualifier) -> InferredTypeData<'db> {
         let target_ty = self.resolve(&qualifier.type_parameters[0]);
-        self.own_members(target_ty)
-            .map_or(InferredTypeData::Unknown, |members| {
-                InferredTypeData::object_from_members(self.db, members)
-            })
+        self.own_members(target_ty).map_or(
+            InferredTypeData::Unknown,
+            |(members, has_unknown_members)| {
+                InferredTypeData::Object(InferredObject::new(
+                    self.db,
+                    None,
+                    members.into_boxed_slice(),
+                    has_unknown_members,
+                ))
+            },
+        )
     }
 
-    fn own_members(&mut self, ty: InferredTypeData<'db>) -> Option<Vec<InferredTypeMember<'db>>> {
+    /// Keeps an incomplete key list incomplete after a utility type changes its members.
+    ///
+    /// For example, rebuilding `Partial<Shape>` must not imply that its only key
+    /// is `A` when collection could not represent the computed member:
+    ///
+    /// ```ts
+    /// declare const key: "C";
+    /// type Shape = { A: number; [key]: number };
+    /// type Keys = keyof Partial<Shape>;
+    /// ```
+    fn preserve_unknown_members(
+        &self,
+        ty: InferredTypeData<'db>,
+        has_unknown_members: bool,
+    ) -> InferredTypeData<'db> {
+        if has_unknown_members && let InferredTypeData::Object(object) = ty {
+            InferredTypeData::Object(InferredObject::new(
+                self.db,
+                object.prototype(self.db),
+                object.members(self.db).clone(),
+                true,
+            ))
+        } else {
+            ty
+        }
+    }
+
+    /// Returns the collected own members and whether the list may omit keys.
+    /// Class, interface, and namespace member lists are not assumed complete.
+    fn own_members(
+        &mut self,
+        ty: InferredTypeData<'db>,
+    ) -> Option<(Vec<InferredTypeMember<'db>>, bool)> {
         let mut ty = ty;
 
         for _ in 0..MAX_LOCAL_TYPE_RESOLUTION_STEPS {
             match self.resolve_inferred_type(ty) {
-                InferredTypeData::Class(class) => return Some(class.members(self.db).to_vec()),
+                InferredTypeData::Class(class) => {
+                    return Some((class.members(self.db).to_vec(), true));
+                }
                 InferredTypeData::Interface(interface) => {
-                    return Some(interface.members(self.db).to_vec());
+                    return Some((interface.members(self.db).to_vec(), true));
                 }
                 InferredTypeData::InstanceOf(instance) => ty = instance.ty(self.db),
+                InferredTypeData::TypeofType(typeof_type) => ty = typeof_type.ty(self.db),
+                InferredTypeData::TypeofValue(typeof_value) => ty = typeof_value.ty(self.db),
                 InferredTypeData::Literal(literal) => match literal.literal(self.db) {
-                    InferredLiteral::Object(members) => return Some(members.to_vec()),
+                    InferredLiteral::Object(members) => return Some((members.to_vec(), false)),
                     InferredLiteral::BigInt(_)
                     | InferredLiteral::Boolean(_)
                     | InferredLiteral::Number(_)
@@ -639,11 +695,18 @@ impl<'db> ResolutionCtx<'db, '_> {
                     | InferredLiteral::String(_)
                     | InferredLiteral::Template(_) => return None,
                 },
-                InferredTypeData::Module(module) => return Some(module.members(self.db).to_vec()),
+                InferredTypeData::Module(module) => {
+                    return Some((module.members(self.db).to_vec(), true));
+                }
                 InferredTypeData::Namespace(namespace) => {
-                    return Some(namespace.members(self.db).to_vec());
+                    return Some((namespace.members(self.db).to_vec(), true));
+                }
+                InferredTypeData::Object(object) => {
+                    return Some((
+                        object.members(self.db).to_vec(),
+                        object.has_unknown_members(self.db) || object.prototype(self.db).is_some(),
+                    ));
                 }
-                InferredTypeData::Object(object) => return Some(object.members(self.db).to_vec()),
                 InferredTypeData::Unknown
                 | InferredTypeData::Global
                 | InferredTypeData::GlobalType(_)
@@ -663,10 +726,9 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::MergedReference(_)
                 | InferredTypeData::TypeofExpression(_)
-                | InferredTypeData::TypeofType(_)
-                | InferredTypeData::TypeofValue(_)
                 | InferredTypeData::AnyKeyword
                 | InferredTypeData::NeverKeyword
                 | InferredTypeData::ObjectKeyword
@@ -690,14 +752,12 @@ impl<'db> ResolutionCtx<'db, '_> {
                 | InferredLiteral::RegExp(_)
                 | InferredLiteral::Template(_) => None,
             },
-            InferredTypeData::Union(union) => Some(
-                union
-                    .types(self.db)
-                    .to_vec()
-                    .into_iter()
-                    .filter_map(|ty| self.string_literal_key(ty))
-                    .collect(),
-            ),
+            InferredTypeData::Union(union) => union
+                .types(self.db)
+                .to_vec()
+                .into_iter()
+                .map(|ty| self.string_literal_key(ty))
+                .collect(),
             InferredTypeData::Unknown
             | InferredTypeData::Global
             | InferredTypeData::GlobalType(_)
@@ -721,6 +781,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Local(_)
             | InferredTypeData::Intersection(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
@@ -770,6 +831,7 @@ impl<'db> ResolutionCtx<'db, '_> {
             | InferredTypeData::Intersection(_)
             | InferredTypeData::Union(_)
             | InferredTypeData::TypeOperator(_)
+            | InferredTypeData::IndexedAccess(_)
             | InferredTypeData::InstanceOf(_)
             | InferredTypeData::MergedReference(_)
             | InferredTypeData::TypeofExpression(_)
diff --git a/crates/biome_module_graph/src/db/type_inference/resolver.rs b/crates/biome_module_graph/src/db/type_inference/resolver.rs
index c63f8a1be6..c2d5482348 100644
--- a/crates/biome_module_graph/src/db/type_inference/resolver.rs
+++ b/crates/biome_module_graph/src/db/type_inference/resolver.rs
@@ -913,6 +913,7 @@ impl<'db, 'a> ResolutionCtx<'db, 'a> {
                 | InferredTypeData::Intersection(_)
                 | InferredTypeData::Union(_)
                 | InferredTypeData::TypeOperator(_)
+                | InferredTypeData::IndexedAccess(_)
                 | InferredTypeData::Literal(_)
                 | InferredTypeData::MergedReference(_)
                 | InferredTypeData::TypeofType(_)
diff --git a/xtask/codegen/src/generate_global_types/emit.rs b/xtask/codegen/src/generate_global_types/emit.rs
index 7d6699a363..e34b5ec16a 100644
--- a/xtask/codegen/src/generate_global_types/emit.rs
+++ b/xtask/codegen/src/generate_global_types/emit.rs
@@ -202,7 +202,10 @@ fn render_type_data(data: &LoweredTypeData) -> String {
             "crate::TypeData::Union(Box::new(crate::Union({})))",
             render_type_references(types),
         ),
-        LoweredTypeData::Tuple(elements) => format!("crate::TypeData::from(crate::Tuple(Box::new([{}])))", elements.iter().map(|ty| format!("crate::TupleElementType {{ ty: {}, name: None, is_optional: false, is_rest: false }}", render_type_reference(ty))).collect::<Vec<_>>().join(",")),
+        LoweredTypeData::Tuple(elements) => format!(
+            "crate::TypeData::from(crate::Tuple {{ elements: Box::new([{}]), is_inferred_array: false }})",
+            elements.iter().map(|ty| format!("crate::TupleElementType {{ ty: {}, name: None, is_optional: false, is_rest: false }}", render_type_reference(ty))).collect::<Vec<_>>().join(","),
+        ),
         LoweredTypeData::Symbol => "crate::TypeData::Symbol".to_string(),
         LoweredTypeData::Undefined => "crate::TypeData::Undefined".to_string(),
         LoweredTypeData::InstanceOf {
PATCH
if command -v patch >/dev/null 2>&1; then
  patch -p1 --fuzz=0 <"$fix"
else
  git apply --whitespace=nowarn "$fix"
fi
rm -f "$fix"
