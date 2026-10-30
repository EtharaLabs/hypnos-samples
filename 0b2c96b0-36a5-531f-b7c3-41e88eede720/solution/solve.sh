#!/bin/bash
# GENERATED SECTION. DO NOT HAND-EDIT.
# FORGE-CANARY-BEGIN
# FORGE-CANARY-SLOT-1: 53b3d68b043f0ac9ebd47bd8f67b19e6b7fa14e174aa9caffdb90444975aa7f3
# FORGE-CANARY-SLOT-2: 38b25c13f561e095dd794f20ce1e467469f45f1b8189951f4b69665b6a622818
# FORGE-CANARY-SLOT-3: 6d1b364b7c03a9c801ba00be36cef100ff8e18f5ba1be4973fa3eb7ba9ca94e1
# FORGE-CANARY-SLOT-4: 8b58ce62941667e72e8c86e7b3c70b3a37a6b0a50d84d4e72d8362b623414dc3
# FORGE-CANARY-END
set -euo pipefail
cd /app
patch -p1 --fuzz=0 <<'PATCH'
diff --git a/crates/nu-cmd-base/src/wrap_call.rs b/crates/nu-cmd-base/src/wrap_call.rs
index 856dfce6..707f5cee 100644
--- a/crates/nu-cmd-base/src/wrap_call.rs
+++ b/crates/nu-cmd-base/src/wrap_call.rs
@@ -33,7 +33,8 @@ use nu_protocol::{
 /// ```rust
 /// # use nu_engine::command_prelude::*;
 /// # use nu_cmd_base::WrapCall;
-/// # let call = WrapCall::Eval(&EngineState::new(), &mut Stack::new(), &Call::new(Span::unknown()));
+/// # let ir_call = nu_protocol::ir::Call::build(nu_protocol::DeclId::new(0), Span::unknown()).finish();
+/// # let call = WrapCall::Eval(&EngineState::new(), &mut Stack::new(), &Call::from(&ir_call));
 /// # fn do_command_logic(call: WrapCall) -> Result<(), ShellError> {
 /// let (call, required): (_, String) = call.req(0)?;
 /// let (call, flag): (_, Option<i64>) = call.get_flag("number")?;
diff --git a/crates/nu-cmd-lang/src/core_commands/let_.rs b/crates/nu-cmd-lang/src/core_commands/let_.rs
index 9c5dcd33..5286531a 100644
--- a/crates/nu-cmd-lang/src/core_commands/let_.rs
+++ b/crates/nu-cmd-lang/src/core_commands/let_.rs
@@ -1,8 +1,5 @@
 use nu_engine::command_prelude::*;
-use nu_engine::eval_expression;
-use nu_protocol::ast::Expr;
-use nu_protocol::debugger::WithoutDebug;
-use nu_protocol::engine::CommandType;
+use nu_protocol::{engine::CommandType, shell_error::generic::GenericError};
 
 #[derive(Clone)]
 pub struct Let;
@@ -48,73 +45,20 @@ impl Command for Let {
 
     fn run(
         &self,
-        engine_state: &EngineState,
-        stack: &mut Stack,
+        _engine_state: &EngineState,
+        _stack: &mut Stack,
         call: &Call,
-        input: PipelineData,
+        _input: PipelineData,
     ) -> Result<PipelineData, ShellError> {
-        let expr = call
-            .positional_nth(stack, 0)
-            .ok_or(ShellError::NushellFailed {
-                msg: "Missing variable name".to_string(),
-            })?;
-        let var_id = expr.as_var().ok_or(ShellError::NushellFailed {
-            msg: "Expected variable".to_string(),
-        })?;
-
-        let initial_value = call.get_parser_info(stack, "initial_value").cloned();
-
-        // Evaluate the right-hand side value:
-        // - If there's an initial_value (let x = expr), evaluate the expression
-        // - Otherwise (let x), use the pipeline input
-        let rhs = if let Some(ref initial_value_expr) = initial_value {
-            // Validate that blocks/subexpressions don't have multiple pipeline elements
-            if let Expr::Block(block_id) | Expr::Subexpression(block_id) = &initial_value_expr.expr
-            {
-                let block = engine_state.get_block(*block_id);
-                if block
-                    .pipelines
-                    .iter()
-                    .any(|pipeline| pipeline.elements.len() > 1)
-                {
-                    return Err(ShellError::NushellFailed {
-                        msg: "invalid `let` keyword call".to_string(),
-                    });
-                }
-            }
-            // Discard input when using = syntax
-            let _ = input.into_value(call.head)?;
-            eval_expression::<WithoutDebug>(engine_state, stack, initial_value_expr)?
-        } else {
-            // Use pipeline input directly when no = is provided
-            input.into_value(call.head)?
-        };
-
-        // If the variable is declared `: glob` and the RHS is a string,
-        // coerce it to an *expandable* `Value::Glob(..., no_expand = false)` so
-        // runtime `let` behavior matches the compiled `GlobFrom { no_expand: false }`.
-        // This ensures `let g: glob = "*.toml"; ls $g` expands like a glob
-        // literal and keeps parity with `into glob`.
-        let value_to_store = {
-            let variable = engine_state.get_var(var_id);
-            if variable.ty == Type::Glob {
-                match &rhs {
-                    Value::String { val, .. } => Value::glob(val.clone(), false, rhs.span()),
-                    _ => rhs.clone(),
-                }
-            } else {
-                rhs.clone()
-            }
-        };
-        stack.add_var(var_id, value_to_store);
-
-        if initial_value.is_some() {
-            // `let var = expr`: suppress output (traditional assignment, no display)
-            Ok(PipelineData::Empty)
-        } else {
-            // `input | let var`: pass through the assigned value
-            Ok(PipelineData::Value(rhs, None))
-        }
+        // The IR compiler turns a direct `let` call into instructions (`compile_let`). This only
+        // runs for an indirect call, like `%($name)` or a plugin's `call_decl`, which passes
+        // values rather than a variable to bind.
+        Err(GenericError::new(
+            "Can't call `let` indirectly",
+            "`let` creates the variable written in its call, like `let x = 1`",
+            call.head,
+        )
+        .into())
     }
 
     fn examples(&self) -> Vec<Example<'_>> {
diff --git a/crates/nu-command/src/filesystem/open.rs b/crates/nu-command/src/filesystem/open.rs
index af1d2b4a..66d6970d 100644
--- a/crates/nu-command/src/filesystem/open.rs
+++ b/crates/nu-command/src/filesystem/open.rs
@@ -1,14 +1,10 @@
-use nu_engine::{command_prelude::*, eval_call};
+use nu_engine::{command_prelude::*, eval_ir_call};
 use nu_path::is_windows_device_path;
 use nu_protocol::{
-    DataSource, NuGlob, PipelineMetadata, ast,
-    debugger::{WithDebug, WithoutDebug},
+    DataSource, NuGlob, PipelineMetadata, ir,
     shell_error::{self, generic::GenericError, io::IoError},
 };
-use std::{
-    collections::HashMap,
-    path::{Path, PathBuf},
-};
+use std::path::{Path, PathBuf};
 
 #[cfg(feature = "sqlite")]
 use crate::database::SQLiteDatabase;
@@ -232,17 +228,9 @@ impl Command for Open {
                                 ));
                             }
 
-                            let open_call = ast::Call {
-                                decl_id: converter_id,
-                                head: call_span,
-                                arguments: vec![],
-                                parser_info: HashMap::new(),
-                            };
-                            let command_output = if engine_state.is_debugging() {
-                                eval_call::<WithDebug>(engine_state, stack, &open_call, stream)
-                            } else {
-                                eval_call::<WithoutDebug>(engine_state, stack, &open_call, stream)
-                            };
+                            let open_call = ir::Call::build(converter_id, call_span).finish();
+                            let command_output =
+                                eval_ir_call(engine_state, stack, &open_call, stream);
                             output.push(command_output.map_err(|inner| {
                                 ShellError::Generic(
                                     GenericError::new(
diff --git a/crates/nu-command/src/filesystem/save.rs b/crates/nu-command/src/filesystem/save.rs
index c8052641..4dce66c7 100644
--- a/crates/nu-command/src/filesystem/save.rs
+++ b/crates/nu-command/src/filesystem/save.rs
@@ -1,10 +1,10 @@
 use crate::formats::{preserve_toml_document, read_toml_source_from_metadata};
 use crate::progress_bar;
-use nu_engine::{command_prelude::*, get_eval_block};
+use nu_engine::{command_prelude::*, eval_ir_call};
 use nu_path::{expand_path_with, is_windows_device_path};
 use nu_protocol::{
-    ByteStreamSource, DataSource, OutDest, PipelineMetadata, Signals, ast,
-    byte_stream::copy_with_signals, process::ChildPipe, shell_error::generic::GenericError,
+    ByteStreamSource, DataSource, OutDest, PipelineMetadata, Signals,
+    byte_stream::copy_with_signals, ir, process::ChildPipe, shell_error::generic::GenericError,
     shell_error::io::IoError,
 };
 use std::{
@@ -333,13 +333,9 @@ fn convert_to_extension(
                 &format!("... | {{}} | save {file}"),
                 path_span,
             ))
-        } else if let Some(block_id) = decl.block_id() {
-            let block = engine_state.get_block(block_id);
-            let eval_block = get_eval_block(engine_state);
-            eval_block(engine_state, stack, block, input).map(|p| p.body)
         } else {
-            let call = ast::Call::new(span);
-            decl.run(engine_state, stack, &(&call).into(), input)
+            let call = ir::Call::build(decl_id, span).finish();
+            eval_ir_call(engine_state, stack, &call, input)
         }
     } else {
         Ok(input)
diff --git a/crates/nu-command/src/misc/run.rs b/crates/nu-command/src/misc/run.rs
index d932967a..4547ef15 100644
--- a/crates/nu-command/src/misc/run.rs
+++ b/crates/nu-command/src/misc/run.rs
@@ -468,13 +468,11 @@ fn ast_run_arguments(
                     engine::Argument::Positional {
                         span,
                         val: eval_expression(engine_state, stack, expr)?,
-                        ast: None,
                     }
                 }
                 ast::Argument::Spread(expr) => engine::Argument::Spread {
                     span,
                     vals: eval_expression(engine_state, stack, expr)?,
-                    ast: None,
                 },
                 ast::Argument::Named((long, short, expr)) => {
                     let short = short.as_ref().map_or("", |short| short.item.as_str());
@@ -486,7 +484,6 @@ fn ast_run_arguments(
                             short,
                             span,
                             val: eval_expression(engine_state, stack, expr)?,
-                            ast: None,
                         },
                         None => engine::Argument::Flag {
                             data,
diff --git a/crates/nu-command/src/misc/tutor.rs b/crates/nu-command/src/misc/tutor.rs
index e7fd52cd..51c2a11e 100644
--- a/crates/nu-command/src/misc/tutor.rs
+++ b/crates/nu-command/src/misc/tutor.rs
@@ -1,5 +1,5 @@
 use itertools::Itertools;
-use nu_engine::command_prelude::*;
+use nu_engine::{command_prelude::*, nu_highlight_string};
 
 #[derive(Clone)]
 pub struct Tutor;
@@ -721,26 +721,7 @@ fn display(help: &str, engine_state: &EngineState, stack: &mut Stack, span: Span
             code_mode = false;
 
             //TODO: support no-color mode
-            if let Some(highlighter) = engine_state.find_decl(b"nu-highlight", &[]) {
-                let decl = engine_state.get_decl(highlighter);
-                let result = decl.run(
-                    engine_state,
-                    stack,
-                    &Call::new(span),
-                    Value::string(item, span).into_pipeline_data(),
-                );
-
-                if let Ok(value) = result.and_then(|data| data.into_value(span)) {
-                    match value.coerce_into_string() {
-                        Ok(s) => {
-                            build.push_str(&s);
-                        }
-                        _ => {
-                            build.push_str(item);
-                        }
-                    }
-                }
-            }
+            build.push_str(&nu_highlight_string(item, engine_state, stack, span));
         } else {
             code_mode = true;
             build.push_str(item);
@@ -758,4 +739,12 @@ mod tests {
     fn test_examples() -> nu_test_support::Result {
         nu_test_support::test().examples(Tutor)
     }
+
+    #[test]
+    fn display_keeps_code_without_nu_highlight() -> nu_test_support::Result {
+        let span = Span::test_data();
+        let shown = display("run `ls` now", &EngineState::new(), &mut Stack::new(), span);
+        assert_eq!(shown.into_value(span)?.into_string()?, "run ls now");
+        Ok(())
+    }
 }
diff --git a/crates/nu-command/src/network/http/client.rs b/crates/nu-command/src/network/http/client.rs
index 1b515799..b93f92f5 100644
--- a/crates/nu-command/src/network/http/client.rs
+++ b/crates/nu-command/src/network/http/client.rs
@@ -15,10 +15,10 @@ use base64::{
 use dns_lookup::LookupErrorKind;
 use log::error;
 use multipart_rs::MultipartWriter;
-use nu_engine::command_prelude::*;
+use nu_engine::{command_prelude::*, eval_ir_call};
 use nu_path::expand_path_with;
 use nu_protocol::{
-    ByteStream, LabeledError, PipelineMetadata, Signals,
+    ByteStream, LabeledError, PipelineMetadata, Signals, ir,
     shell_error::{
         generic::GenericError,
         io::IoError,
@@ -1130,7 +1130,18 @@ fn transform_response_using_content_type(
                         span,
                     ));
                 }
-                decl.run(engine_state, stack, &Call::new(span), output)
+                // A `charset=utf-8` response is typed as a string, but a converter picked by the
+                // URL's extension, like `from xlsx`, may want binary. Hand it the bytes untyped,
+                // as `open` does.
+                let output = match output {
+                    PipelineData::ByteStream(stream, metadata) => PipelineData::byte_stream(
+                        stream.with_type(ByteStreamType::Unknown),
+                        metadata,
+                    ),
+                    other => other,
+                };
+                let call = ir::Call::build(converter_id, span).finish();
+                eval_ir_call(engine_state, stack, &call, output)
             }
             None => Ok(output),
         }
@@ -1422,6 +1433,7 @@ fn retrieve_credential_from_authority(
 #[cfg(test)]
 mod test {
     use super::*;
+    use nu_protocol::DeclId;
 
     #[test]
     fn test_retrieving_credentials_from_authority() {
@@ -1510,7 +1522,8 @@ mod test {
 
     #[test]
     fn test_http_parse_url_with_ipv6_zone_id() {
-        let call = Call::new(Span::test_data());
+        let ir_call = ir::Call::build(DeclId::new(0), Span::test_data()).finish();
+        let call = Call::from(&ir_call);
         let span = Span::test_data();
         let raw_url = Value::test_string("http://[fe80::13%eth0]");
 
@@ -1522,7 +1535,8 @@ mod test {
 
     #[test]
     fn test_http_parse_url_rejects_invalid_ipv6_with_zone_id() {
-        let call = Call::new(Span::test_data());
+        let ir_call = ir::Call::build(DeclId::new(0), Span::test_data()).finish();
+        let call = Call::from(&ir_call);
         let span = Span::test_data();
         // A URL with a zone ID but invalid characters after the bracket must be
         // rejected, not silently rewritten (e.g. to localhost).
diff --git a/crates/nu-command/src/system/run_external.rs b/crates/nu-command/src/system/run_external.rs
index f87fe0f9..6265fd49 100644
--- a/crates/nu-command/src/system/run_external.rs
+++ b/crates/nu-command/src/system/run_external.rs
@@ -1,9 +1,9 @@
 use itertools::Itertools;
 use nu_cmd_base::hook::eval_hook;
-use nu_engine::{command_prelude::*, env_to_strings};
+use nu_engine::{command_prelude::*, env_to_strings, eval_ir_call};
 use nu_path::{AbsolutePath, dots::expand_ndots_safe, expand_tilde};
 use nu_protocol::{
-    ByteStream, DeclId, NuGlob, OutDest, Signals, UseAnsiColoring, did_you_mean,
+    ByteStream, DeclId, NuGlob, OutDest, Signals, UseAnsiColoring, did_you_mean, ir,
     process::{ChildProcess, PostWaitCallback},
     shell_error::io::IoError,
 };
@@ -549,8 +549,13 @@ fn write_pipeline_data(
         engine_state.set_config(config);
 
         // Invoke the `table` command.
-        let output =
-            crate::Table.run(&engine_state, &mut stack, &Call::new(Span::unknown()), data)?;
+        let output = match engine_state.table_decl_id {
+            Some(decl_id) => {
+                let call = ir::Call::build(decl_id, Span::unknown()).finish();
+                eval_ir_call(&engine_state, &mut stack, &call, data)?
+            }
+            None => data,
+        };
 
         // Write the output.
         for value in output {
diff --git a/crates/nu-command/src/system/run_internal.rs b/crates/nu-command/src/system/run_internal.rs
index d4e5e1f7..ea2a75e4 100644
--- a/crates/nu-command/src/system/run_internal.rs
+++ b/crates/nu-command/src/system/run_internal.rs
@@ -1,4 +1,4 @@
-use nu_engine::{CallExt, command_prelude::*, find_builtin_decl};
+use nu_engine::{CallExt, command_prelude::*, eval_ir_call, find_builtin_decl};
 use nu_protocol::ir;
 
 /// Internal command used by the `%($cmd)`/`%$cmd` dynamic builtin dispatch syntax.
@@ -47,7 +47,6 @@ impl Command for RunInternal {
         let decl_id = find_builtin_decl(engine_state, &name)
             .ok_or(ShellError::CommandNotFound { span: head })?;
 
-        let decl = engine_state.get_decl(decl_id);
         // Preserve spread markers here so `%($cmd) ...$args` forwards the same argument shape the
         // target builtin would receive in a direct call.
         let rest_args: Vec<(Value, bool)> = call.rest_preserving_spreads(engine_state, stack, 1)?;
@@ -71,10 +70,10 @@ impl Command for RunInternal {
             }
         }
 
-        // `builder.with` is a scoped guard: it registers temporary IR argument slots,
-        // calls the closure, then always deallocates those slots on exit.
-        builder.with(stack, |stack, engine_call| {
-            decl.run(engine_state, stack, engine_call, input)
-        })
+        // Run it like a direct call, so its input is type checked and record spreads become flags.
+        let call = builder.finish();
+        let result = eval_ir_call(engine_state, stack, &call, input);
+        call.leave(stack);
+        result
     }
 }
diff --git a/crates/nu-command/src/viewers/table.rs b/crates/nu-command/src/viewers/table.rs
index e58c8d86..9773001f 100644
--- a/crates/nu-command/src/viewers/table.rs
+++ b/crates/nu-command/src/viewers/table.rs
@@ -11,12 +11,12 @@ use nu_utils::time::Instant;
 use url::Url;
 
 use nu_color_config::{StyleComputer, TextStyle, color_from_hex};
-use nu_engine::{command_prelude::*, env_to_string};
+use nu_engine::{command_prelude::*, env_to_string, eval_ir_call};
 use nu_path::form::Absolute;
 use nu_pretty_hex::{HexConfig, HexStyles};
 use nu_protocol::{
     ByteStream, Config, DataSource, ListStream, PipelineMetadata, Signals,
-    TABLE_WIDTH_PRIORITY_COLUMNS_METADATA_KEY, TableMode, ValueIterator,
+    TABLE_WIDTH_PRIORITY_COLUMNS_METADATA_KEY, TableMode, ValueIterator, ir,
     shell_error::{bridge::ShellErrorBridge, io::IoError},
 };
 use nu_table::{
@@ -220,11 +220,14 @@ pub(crate) fn render_value_as_plain_table_text(
     value: Value,
     span: Span,
 ) -> ShellResult<String> {
-    let call = Call::new(span);
-    let input = value.into_pipeline_data();
-    let input = CmdInput::parse(engine_state, stack, &call, input)?;
-    let output = handle_table_command(input)?;
-    let output = output.into_value(span)?;
+    let output = match engine_state.table_decl_id {
+        Some(decl_id) => {
+            let call = ir::Call::build(decl_id, span).finish();
+            eval_ir_call(engine_state, stack, &call, value.into_pipeline_data())?
+                .into_value(span)?
+        }
+        None => value,
+    };
     let config = stack.get_config(engine_state);
 
     let text = match output {
diff --git a/crates/nu-dap/src/print_cmd.rs b/crates/nu-dap/src/print_cmd.rs
index 7d104ec8..569550e8 100644
--- a/crates/nu-dap/src/print_cmd.rs
+++ b/crates/nu-dap/src/print_cmd.rs
@@ -10,8 +10,8 @@
 use crate::dap::protocol::DapWriter;
 use crate::dap::types::DapEvent;
 use crate::state::DebugState;
-use nu_engine::command_prelude::*;
-use nu_protocol::shell_error::generic::GenericError;
+use nu_engine::{command_prelude::*, eval_ir_call};
+use nu_protocol::{ir, shell_error::generic::GenericError};
 use std::sync::Arc;
 
 #[derive(Clone)]
@@ -409,13 +409,8 @@ impl DapPrint {
 
         let data = match engine_state.table_decl_id {
             Some(decl_id) => {
-                let table_call = nu_protocol::ast::Call::new(call.head);
-                engine_state.get_decl(decl_id).run(
-                    engine_state,
-                    stack,
-                    &(&table_call).into(),
-                    data,
-                )?
+                let table_call = ir::Call::build(decl_id, call.head).finish();
+                eval_ir_call(engine_state, stack, &table_call, data)?
             }
             None => data,
         };
diff --git a/crates/nu-engine/src/compile/builder.rs b/crates/nu-engine/src/compile/builder.rs
index b2957048..c7f67c97 100644
--- a/crates/nu-engine/src/compile/builder.rs
+++ b/crates/nu-engine/src/compile/builder.rs
@@ -1,7 +1,7 @@
 use nu_protocol::{
     CompileError, IntoSpanned, RegId, Span, Spanned,
     ast::Pattern,
-    ir::{DataSlice, Instruction, IrAstRef, IrBlock, Literal, ScopeRegion},
+    ir::{DataSlice, Instruction, IrBlock, Literal, ScopeRegion},
 };
 
 /// A label identifier. Only exists while building code. Replaced with the actual target.
@@ -21,13 +21,11 @@ pub(crate) struct BlockBuilder {
     /// an index actually set.
     pub(crate) labels: Vec<Option<usize>>,
     pub(crate) data: Vec<u8>,
-    /// The AST of the instructions that have one, as (instruction index, AST) pairs. Only the last
-    /// instruction pushed ever gets one, so the indices increase. Few instructions have one, so
-    /// this and `comments` are only expanded to one entry per instruction by [`finish()`].
+    /// The comments of the instructions that have one, as (instruction index, comment) pairs.
+    /// Only the last instruction pushed ever gets one, so the indices increase. Few instructions
+    /// have one, so this is only expanded to one entry per instruction by [`finish()`].
     ///
     /// [`finish()`]: Self::finish
-    pub(crate) ast: Vec<(usize, IrAstRef)>,
-    /// The comments of the instructions that have one, like `ast`.
     pub(crate) comments: Vec<(usize, String)>,
     pub(crate) register_allocation_state: Vec<bool>,
     pub(crate) file_count: u32,
@@ -45,7 +43,6 @@ impl BlockBuilder {
             spans: vec![],
             labels: vec![],
             data: vec![],
-            ast: vec![],
             comments: vec![],
             register_allocation_state: vec![true],
             file_count: 0,
@@ -341,18 +338,6 @@ impl BlockBuilder {
             .expect("no last instruction")
     }
 
-    /// Set the AST of the last instruction. Separate method because it's rarely used.
-    pub(crate) fn set_last_ast(&mut self, ast_ref: Option<IrAstRef>) {
-        let index = self.last_index();
-        // An entry for the last instruction can only be the last entry.
-        if self.ast.last().is_some_and(|(last, _)| *last == index) {
-            self.ast.pop();
-        }
-        if let Some(ast_ref) = ast_ref {
-            self.ast.push((index, ast_ref));
-        }
-    }
-
     /// Add a comment to the last instruction.
     pub(crate) fn add_comment(&mut self, comment: &str) {
         let index = self.last_index();
@@ -629,17 +614,10 @@ impl BlockBuilder {
             }
         }
 
-        // One AST entry per instruction; instructions without one get `None`.
-        let mut ast = vec![None; self.instructions.len()];
-        for (index, ast_ref) in self.ast {
-            ast[index] = Some(ast_ref);
-        }
-
         Ok(IrBlock {
             instructions: self.instructions,
             spans: self.spans,
             data: self.data.into(),
-            ast,
             comments: comments.into_iter().map(String::into_boxed_str).collect(),
             register_count: self
                 .register_allocation_state
diff --git a/crates/nu-engine/src/compile/call.rs b/crates/nu-engine/src/compile/call.rs
index 05071214..34f8fd81 100644
--- a/crates/nu-engine/src/compile/call.rs
+++ b/crates/nu-engine/src/compile/call.rs
@@ -4,9 +4,8 @@ use nu_protocol::{
     DeclId, IntoSpanned, RegId, Span, Spanned, Type,
     ast::{Argument, Call, Expr, Expression, ExternalArgument, FlagRef},
     engine::{ENV_VARIABLE_ID, IN_VARIABLE_ID, NU_VARIABLE_ID, StateWorkingSet, UNKNOWN_SPAN_ID},
-    ir::{Instruction, IrAstRef, Literal},
+    ir::{Instruction, Literal},
 };
-use std::sync::Arc;
 
 pub(crate) fn compile_call(
     working_set: &StateWorkingSet,
@@ -217,8 +216,6 @@ pub(crate) fn compile_call(
         return compile_unlet(working_set, builder, call, io_reg);
     }
 
-    // Keep AST if the decl needs it.
-    let requires_ast = decl.requires_ast_for_arguments();
     // `metadata $var` needs the variable's definition span, not the use-site span.
     let preserve_var_origin = decl.name() == "metadata";
 
@@ -229,9 +226,9 @@ pub(crate) fn compile_call(
     // the argument state, but we'd have to check all of that first and it just isn't really worth
     // it.
     enum CompiledArg<'a> {
-        Positional(RegId, Span, Option<IrAstRef>),
-        Named(FlagRef<'a>, Option<RegId>, Span, Option<IrAstRef>),
-        Spread(RegId, Span, Option<IrAstRef>),
+        Positional(RegId, Span),
+        Named(FlagRef<'a>, Option<RegId>, Span),
+        Spread(RegId, Span),
     }
 
     let mut compiled_args = vec![];
@@ -268,29 +265,18 @@ pub(crate) fn compile_call(
             })
             .transpose()?;
 
-        let ast_ref = arg
-            .expr()
-            .filter(|_| requires_ast)
-            .map(|expr| IrAstRef(Arc::new(expr.clone())));
-
         match arg {
-            Argument::Positional(_) | Argument::Unknown(_) => {
-                compiled_args.push(CompiledArg::Positional(
-                    arg_reg.expect("expr() None in non-Named"),
-                    arg.span(),
-                    ast_ref,
-                ))
-            }
+            Argument::Positional(_) | Argument::Unknown(_) => compiled_args.push(
+                CompiledArg::Positional(arg_reg.expect("expr() None in non-Named"), arg.span()),
+            ),
             Argument::Named((long, short, _)) => compiled_args.push(CompiledArg::Named(
                 FlagRef::from_named(long, short.as_ref()),
                 arg_reg,
                 arg.span(),
-                ast_ref,
             )),
             Argument::Spread(_) => compiled_args.push(CompiledArg::Spread(
                 arg_reg.expect("expr() None in non-Named"),
                 arg.span(),
-                ast_ref,
             )),
         }
     }
@@ -298,12 +284,11 @@ pub(crate) fn compile_call(
     // Now that the args are all compiled, set up the call state (argument stack and redirections)
     for arg in compiled_args {
         match arg {
-            CompiledArg::Positional(reg, span, ast_ref) => {
+            CompiledArg::Positional(reg, span) => {
                 builder.push(Instruction::PushPositional { src: reg }.into_spanned(span))?;
-                builder.set_last_ast(ast_ref);
             }
             // The long/short × with-value/bare grid, spelled out once.
-            CompiledArg::Named(flag, reg, span, ast_ref) => {
+            CompiledArg::Named(flag, reg, span) => {
                 let instruction = match (flag, reg) {
                     (FlagRef::Long(name), Some(src)) => Instruction::PushNamed {
                         name: builder.data(name)?,
@@ -321,11 +306,9 @@ pub(crate) fn compile_call(
                     },
                 };
                 builder.push(instruction.into_spanned(span))?;
-                builder.set_last_ast(ast_ref);
             }
-            CompiledArg::Spread(reg, span, ast_ref) => {
+            CompiledArg::Spread(reg, span) => {
                 builder.push(Instruction::AppendRest { src: reg }.into_spanned(span))?;
-                builder.set_last_ast(ast_ref);
             }
         }
     }
diff --git a/crates/nu-engine/src/documentation.rs b/crates/nu-engine/src/documentation.rs
index 4d8d8c23..fbc2c47c 100644
--- a/crates/nu-engine/src/documentation.rs
+++ b/crates/nu-engine/src/documentation.rs
@@ -1,18 +1,17 @@
-use crate::eval_call;
+use crate::eval_ir_call;
 use fancy_regex::{Captures, Regex};
 use nu_protocol::{
     Alias, Category, Config, IntoPipelineData, PipelineData, PositionalArg, Signature, Span,
-    SpanId, Spanned, SyntaxShape, Type, Value,
-    ast::{Argument, Call, Expr, Expression, RecordItem},
-    debugger::WithoutDebug,
+    SyntaxShape, Value,
+    ast::Expr,
     engine::CommandType,
-    engine::{Command, EngineState, Stack, UNKNOWN_SPAN_ID},
-    record,
+    engine::{Command, EngineState, Stack},
+    ir, record,
 };
 use nu_utils::terminal_size;
 use std::{
     borrow::Cow,
-    collections::{HashMap, HashSet},
+    collections::HashSet,
     fmt::Write,
     sync::{Arc, LazyLock},
 };
@@ -110,32 +109,27 @@ fn try_nu_highlight(
 ) -> Option<String> {
     let highlighter = engine_state.find_decl(b"nu-highlight", &[])?;
 
-    let decl = engine_state.get_decl(highlighter);
-    let mut call = Call::new(head);
+    let mut call = ir::Call::build(highlighter, head);
     if reject_garbage {
-        call.add_named((
-            Spanned {
-                item: "reject-garbage".into(),
-                span: head,
-            },
-            None,
-            None,
-        ));
+        call.add_flag(stack, "reject-garbage", "", head);
     }
-
-    decl.run(
+    let call = call.finish();
+    let highlighted = eval_ir_call(
         engine_state,
         stack,
-        &(&call).into(),
+        &call,
         Value::string(code_string, head).into_pipeline_data(),
-    )
-    .and_then(|pipe| pipe.into_value(head))
-    .and_then(|val| val.coerce_into_string())
-    .ok()
+    );
+    call.leave(stack);
+
+    highlighted
+        .and_then(|pipe| pipe.into_value(head))
+        .and_then(|val| val.coerce_into_string())
+        .ok()
 }
 
 /// Syntax highlight code using the `nu-highlight` command if available, falling back to the given string
-fn nu_highlight_string(
+pub fn nu_highlight_string(
     code_string: &str,
     engine_state: &EngineState,
     stack: &mut Stack,
@@ -523,26 +517,14 @@ fn get_command_documentation(
         }
 
         let caller_stack = &mut Stack::new().collect_value();
-        if let Ok(result) = eval_call::<WithoutDebug>(
+        let mut table_call = ir::Call::build(decl_id, head);
+        // padding, see below
+        let width = Value::int(get_term_width() as i64 - 2, head);
+        table_call.add_named(caller_stack, "width", "", head, width);
+        if let Ok(result) = eval_ir_call(
             engine_state,
             caller_stack,
-            &Call {
-                decl_id,
-                head,
-                arguments: vec![Argument::Named((
-                    Spanned {
-                        item: "width".to_string(),
-                        span: head,
-                    },
-                    None,
-                    Some(Expression::new_unknown(
-                        Expr::Int(get_term_width() as i64 - 2), // padding, see below
-                        head,
-                        Type::Int,
-                    )),
-                ))],
-                parser_info: HashMap::new(),
-            },
+            &table_call.finish(),
             PipelineData::value(Value::list(vals, head), None),
         ) && let Ok((str, ..)) = result.collect_string_strict(head)
         {
@@ -580,54 +562,27 @@ fn get_command_documentation(
         };
 
         if let Some(result) = &example.result {
-            let mut table_call = Call::new(head);
-            if example.example.ends_with("--collapse") {
-                // collapse the result
-                table_call.add_named((
-                    Spanned {
-                        item: "collapse".to_string(),
-                        span: head,
-                    },
-                    None,
-                    None,
-                ))
-            } else {
-                // expand the result
-                table_call.add_named((
-                    Spanned {
-                        item: "expand".to_string(),
-                        span: head,
-                    },
-                    None,
-                    None,
-                ))
-            }
-            table_call.add_named((
-                Spanned {
-                    item: "width".to_string(),
-                    span: head,
-                },
-                None,
-                Some(Expression::new_unknown(
-                    Expr::Int(get_term_width() as i64 - 2),
-                    head,
-                    Type::Int,
-                )),
-            ));
-
-            let table = engine_state
-                .find_decl("table".as_bytes(), &[])
-                .and_then(|decl_id| {
-                    engine_state
-                        .get_decl(decl_id)
-                        .run(
-                            engine_state,
-                            stack,
-                            &(&table_call).into(),
-                            PipelineData::value(result.clone(), None),
-                        )
-                        .ok()
-                });
+            let table = engine_state.find_decl(b"table", &[]).and_then(|decl_id| {
+                let mut table_call = ir::Call::build(decl_id, head);
+                // collapse or expand the result
+                let layout = if example.example.ends_with("--collapse") {
+                    "collapse"
+                } else {
+                    "expand"
+                };
+                table_call.add_flag(stack, layout, "", head);
+                let width = Value::int(get_term_width() as i64 - 2, head);
+                table_call.add_named(stack, "width", "", head, width);
+                let table_call = table_call.finish();
+                let table = eval_ir_call(
+                    engine_state,
+                    stack,
+                    &table_call,
+                    PipelineData::value(result.clone(), None),
+                );
+                table_call.leave(stack);
+                table.ok()
+            });
 
             for item in table.into_iter().flatten() {
                 writeln!(
@@ -653,80 +608,46 @@ fn update_ansi_from_config(
     theme_component: &str,
     head: Span,
 ) {
-    if let Some(color) = &nu_config.color_config.get(theme_component) {
-        let caller_stack = &mut Stack::new().collect_value();
-        let span_id = UNKNOWN_SPAN_ID;
-
-        let argument_opt = get_argument_for_color_value(nu_config, color, head, span_id);
+    let Some(color) = nu_config
+        .color_config
+        .get(theme_component)
+        .and_then(|color| color_value_for_ansi(nu_config, color, head))
+    else {
+        return;
+    };
+    let Some(decl_id) = engine_state.find_decl(b"ansi", &[]) else {
+        return;
+    };
 
-        // Call ansi command using argument
-        if let Some(argument) = argument_opt
-            && let Some(decl_id) = engine_state.find_decl(b"ansi", &[])
-            && let Ok(result) = eval_call::<WithoutDebug>(
-                engine_state,
-                caller_stack,
-                &Call {
-                    decl_id,
-                    head,
-                    arguments: vec![argument],
-                    parser_info: HashMap::new(),
-                },
-                PipelineData::empty(),
-            )
-            && let Ok((str, ..)) = result.collect_string_strict(head)
-        {
-            *ansi_code = str;
-        }
+    // Call ansi command using the color
+    let caller_stack = &mut Stack::new().collect_value();
+    let mut ansi_call = ir::Call::build(decl_id, head);
+    ansi_call.add_positional(caller_stack, head, color);
+    if let Ok(result) = eval_ir_call(
+        engine_state,
+        caller_stack,
+        &ansi_call.finish(),
+        PipelineData::empty(),
+    ) && let Ok((str, ..)) = result.collect_string_strict(head)
+    {
+        *ansi_code = str;
     }
 }
 
-fn get_argument_for_color_value(
-    nu_config: &Config,
-    color: &Value,
-    span: Span,
-    span_id: SpanId,
-) -> Option<Argument> {
+/// The `ansi` argument for a configured color: a color name, or a style record with its values
+/// as strings.
+fn color_value_for_ansi(nu_config: &Config, color: &Value, span: Span) -> Option<Value> {
     match color {
-        Value::Record { val, .. } => {
-            let record_exp: Vec<RecordItem> = (**val)
-                .iter()
+        Value::Record { val, .. } => Some(Value::record(
+            val.iter()
                 .map(|(k, v)| {
-                    RecordItem::Pair(
-                        Expression::new_existing(
-                            Expr::String(k.clone()),
-                            span,
-                            span_id,
-                            Type::String,
-                        ),
-                        Expression::new_existing(
-                            Expr::String(v.clone().to_expanded_string("", nu_config)),
-                            span,
-                            span_id,
-                            Type::String,
-                        ),
-                    )
+                    let v = Value::string(v.to_expanded_string("", nu_config), span);
+                    (k.clone(), v)
                 })
-                .collect();
-
-            Some(Argument::Positional(Expression::new_existing(
-                Expr::Record(record_exp),
-                span,
-                span_id,
-                Type::Record(
-                    vec![
-                        ("fg".to_string(), Type::String),
-                        ("attr".to_string(), Type::String),
-                    ]
-                    .into(),
-                ),
-            )))
-        }
-        Value::String { val, .. } => Some(Argument::Positional(Expression::new_existing(
-            Expr::String(val.clone()),
+                .collect(),
             span,
-            span_id,
-            Type::String,
-        ))),
+        )),
+        Value::String { val, .. } => Some(Value::string(val.clone(), span)),
         _ => None,
     }
 }
diff --git a/crates/nu-engine/src/eval_ir.rs b/crates/nu-engine/src/eval_ir.rs
index 5a55c035..bffb153b 100644
--- a/crates/nu-engine/src/eval_ir.rs
+++ b/crates/nu-engine/src/eval_ir.rs
@@ -9,12 +9,12 @@ use nu_protocol::{
     ShellError, Signals, Signature, Span, Spanned, Type, Value, VarId,
     ast::{Bits, Block, Boolean, CellPath, Comparison, Math, Operator},
     combined_type_string,
-    debugger::DebugContext,
+    debugger::{DebugContext, WithDebug, WithoutDebug},
     engine::{
         Argument, Closure, EngineState, EnvName, ErrorHandler, Matcher, Redirection, Stack,
         StateWorkingSet, TryHandler, env_var_eq,
     },
-    ir::{Call, DataSlice, Instruction, IrAstRef, IrBlock, Literal, RedirectMode},
+    ir::{Call, DataSlice, Instruction, IrBlock, Literal, RedirectMode},
     shell_error::{
         eval_block_with_input::EvalBlockWithInputError, generic::GenericError, io::IoError,
     },
@@ -285,14 +285,13 @@ fn eval_ir_block_impl<D: DebugContext>(
     while pc < ir_block.instructions.len() {
         let instruction = &ir_block.instructions[pc];
         let span = &ir_block.spans[pc];
-        let ast = &ir_block.ast[pc];
 
         // So `scope` can match inlined keyword-body bindings via ScopeRegion.
         ctx.stack.ir_instruction_index = Some(pc);
 
         D::enter_instruction(ctx.engine_state, ctx.stack, ir_block, pc, ctx.registers);
 
-        let result = eval_instruction::<D>(ctx, instruction, span, ast, need_backtrace);
+        let result = eval_instruction::<D>(ctx, instruction, span, need_backtrace);
 
         D::leave_instruction(
             ctx.engine_state,
@@ -549,7 +548,6 @@ fn eval_instruction<D: DebugContext>(
     ctx: &mut EvalContext<'_>,
     instruction: &Instruction,
     span: &Span,
-    ast: &Option<IrAstRef>,
     need_backtrace: bool,
 ) -> Result<InstructionResult, ShellError> {
     use self::InstructionResult::*;
@@ -723,20 +721,16 @@ fn eval_instruction<D: DebugContext>(
             // Keep the value's own span (e.g. definition span from load-variable-origin for
             // `metadata $var`). Argument::span still records where the arg appears in the call.
             let val = ctx.collect_reg(*src, *span)?;
-            ctx.stack.arguments.push(Argument::Positional {
-                span: *span,
-                val,
-                ast: ast.clone().map(|ast_ref| ast_ref.0),
-            });
+            ctx.stack
+                .arguments
+                .push(Argument::Positional { span: *span, val });
             Ok(Continue)
         }
         Instruction::AppendRest { src } => {
             let vals = ctx.collect_reg(*src, *span)?;
-            ctx.stack.arguments.push(Argument::Spread {
-                span: *span,
-                vals,
-                ast: ast.clone().map(|ast_ref| ast_ref.0),
-            });
+            ctx.stack
+                .arguments
+                .push(Argument::Spread { span: *span, vals });
             Ok(Continue)
         }
         Instruction::PushFlag { name } => {
@@ -770,7 +764,6 @@ fn eval_instruction<D: DebugContext>(
                 short: DataSlice::empty(),
                 span: *span,
                 val,
-                ast: ast.clone().map(|ast_ref| ast_ref.0),
             });
             Ok(Continue)
         }
@@ -783,7 +776,6 @@ fn eval_instruction<D: DebugContext>(
                 short: *short,
                 span: *span,
                 val,
-                ast: ast.clone().map(|ast_ref| ast_ref.0),
             });
             Ok(Continue)
         }
@@ -1492,7 +1484,7 @@ fn eval_call<D: DebugContext>(
     ctx: &mut EvalContext<'_>,
     decl_id: DeclId,
     head: Span,
-    mut input: PipelineData,
+    input: PipelineData,
 ) -> Result<PipelineData, ShellError> {
     let EvalContext {
         engine_state,
@@ -1504,7 +1496,6 @@ fn eval_call<D: DebugContext>(
     } = ctx;
 
     let args_len = caller_stack.arguments.get_len(*args_base);
-    let decl = engine_state.get_decl(decl_id);
     // Commands such as `ignore --stderr` need errors as pipeline values so they can decide
     // whether to suppress or rethrow.
     let stderr_pipe_separate = matches!(
@@ -1515,115 +1506,183 @@ fn eval_call<D: DebugContext>(
     // Set up redirect modes
     let mut caller_stack = caller_stack.push_redirection(redirect_out.take(), redirect_err.take());
 
-    let result = (|| {
-        if let Some(block_id) = decl.block_id() {
-            // If the decl is a custom command
-            let block = engine_state.get_block(block_id);
+    let result = eval_call_frame::<D>(
+        engine_state,
+        &mut caller_stack,
+        decl_id,
+        head,
+        *args_base,
+        args_len,
+        input,
+    );
 
-            // check types after acquiring block to avoid unnecessarily cloning Signature
-            check_input_types(&input, &block.signature, head)?;
+    drop(caller_stack);
 
-            // Expand record spreads into named flags; drop null named values.
-            let args_len = normalize_call_arguments(
-                &block.signature,
-                &mut caller_stack,
-                *args_base,
-                args_len,
-            )?;
+    // Important that this runs, to reset state post-call:
+    ctx.stack.arguments.leave_frame(ctx.args_base);
+    ctx.redirect_out = None;
+    ctx.redirect_err = None;
 
-            // Set up a callee stack with the captures and move arguments from the stack into variables
-            let mut callee_stack = caller_stack.gather_captures(engine_state, &block.captures);
+    match result {
+        Err(err) if stderr_pipe_separate => Ok(PipelineData::Value(Value::error(err, head), None)),
+        result => result,
+    }
+}
 
-            gather_arguments(
-                engine_state,
-                block,
-                &mut caller_stack,
-                &mut callee_stack,
-                *args_base,
-                args_len,
-                head,
-            )?;
-
-            // Snapshot the call's return destination onto the callee stack. Intermediate
-            // expressions in the body may temporarily set OutDest::Value (e.g. `if (…)`);
-            // Stack::is_stdout_redirected / `is-redirected` read this frame instead.
-            // See Stack::with_invocation_stdout for details.
-            let mut callee_stack =
-                callee_stack.with_invocation_stdout(caller_stack.stdout().clone());
-
-            // Add one to the recursion count, so we don't recurse too deep. Stack overflows are not
-            // recoverable in Rust.
-            callee_stack.recursion_count += 1;
-
-            let result =
-                eval_block_with_early_return::<D>(engine_state, &mut callee_stack, block, input)
-                    .map(|p| p.body);
-
-            // Move environment variables back into the caller stack scope if requested to do so
-            if block.redirect_env {
-                redirect_env(engine_state, &mut caller_stack, &callee_stack);
-            }
+/// Evaluate a call to a command the way compiled code calls it. The call's arguments must be the
+/// last ones on `stack`, which is where [`CallBuilder`](nu_protocol::ir::CallBuilder) puts them.
+///
+/// The input is type checked and record spreads become flags. A custom command binds its
+/// parameters and runs its block; any other command goes through
+/// [`Command::run`](nu_protocol::engine::Command::run). Use this rather than calling `run` on a
+/// command found by name, like a `from <ext>` converter, because it may be a custom command.
+///
+/// Call [`Call::leave`] afterwards to reset the argument stack, whether or not the command
+/// consumed the arguments.
+pub fn eval_ir_call(
+    engine_state: &EngineState,
+    stack: &mut Stack,
+    call: &Call,
+    input: PipelineData,
+) -> Result<PipelineData, ShellError> {
+    let Call {
+        decl_id,
+        head,
+        args_base,
+        args_len,
+        ..
+    } = *call;
+    engine_state.signals().check(&head)?;
+    // Normalizing the arguments re-pushes them at the end of the stack. A call without arguments
+    // never set its `args_base`.
+    if args_len != 0 && args_base + args_len != stack.arguments.get_base() {
+        return Err(ShellError::IrEvalError {
+            msg: "the call's arguments must be the last ones on the stack".into(),
+            span: Some(head),
+        });
+    }
+    if engine_state.is_debugging() {
+        eval_call_frame::<WithDebug>(
+            engine_state,
+            stack,
+            decl_id,
+            head,
+            args_base,
+            args_len,
+            input,
+        )
+    } else {
+        eval_call_frame::<WithoutDebug>(
+            engine_state,
+            stack,
+            decl_id,
+            head,
+            args_base,
+            args_len,
+            input,
+        )
+    }
+}
 
-            result
-        } else {
-            // `ignore` intentionally handles upstream error values at command level.
-            // Skip early input-error propagation for the built-in `ignore` command so
-            // `run()` can apply `--stderr`/`--show-errors` semantics.
-            let allow_error_input = matches!(input, PipelineData::Value(Value::Error { .. }, ..))
-                && engine_state
-                    .find_decl(b"ignore", &[])
-                    .is_some_and(|ignore_decl_id| ignore_decl_id == decl_id);
-            if !allow_error_input {
-                check_input_types(&input, &decl.signature(), head)?;
-            }
+/// Run the command `decl_id` with the `args_len` arguments at `args_base` on `caller_stack`.
+/// The caller removes the arguments from the stack afterwards.
+fn eval_call_frame<D: DebugContext>(
+    engine_state: &EngineState,
+    caller_stack: &mut Stack,
+    decl_id: DeclId,
+    head: Span,
+    args_base: usize,
+    args_len: usize,
+    mut input: PipelineData,
+) -> Result<PipelineData, ShellError> {
+    let decl = engine_state.get_decl(decl_id);
+    if let Some(block_id) = decl.block_id() {
+        // If the decl is a custom command
+        let block = engine_state.get_block(block_id);
 
-            // Expand record spreads into named flags; drop null named values.
-            let args_len = normalize_call_arguments(
-                &decl.signature(),
-                &mut caller_stack,
-                *args_base,
-                args_len,
-            )?;
-
-            // FIXME: precalculate this and save it somewhere
-            let span = Span::merge_many(
-                std::iter::once(head).chain(
-                    caller_stack
-                        .arguments
-                        .get_args(*args_base, args_len)
-                        .iter()
-                        .flat_map(|arg| arg.span()),
-                ),
-            );
+        // check types after acquiring block to avoid unnecessarily cloning Signature
+        check_input_types(&input, &block.signature, head)?;
 
-            let call = Call {
-                decl_id,
-                head,
-                span,
-                args_base: *args_base,
-                args_len,
-            };
+        // Expand record spreads into named flags; drop null named values.
+        let args_len =
+            normalize_call_arguments(&block.signature, caller_stack, args_base, args_len)?;
 
-            // Make sure that iterating value itself can be interrupted.
-            // e.g: 0..inf | to md
-            if let PipelineData::Value(v, ..) = &mut input {
-                v.inject_signals(engine_state);
-            }
-            // Run the call
-            decl.run(engine_state, &mut caller_stack, &(&call).into(), input)
+        // Set up a callee stack with the captures and move arguments from the stack into variables
+        let mut callee_stack = caller_stack.gather_captures(engine_state, &block.captures);
+
+        gather_arguments(
+            engine_state,
+            block,
+            caller_stack,
+            &mut callee_stack,
+            args_base,
+            args_len,
+            head,
+        )?;
+
+        // Snapshot the call's return destination onto the callee stack. Intermediate
+        // expressions in the body may temporarily set OutDest::Value (e.g. `if (…)`);
+        // Stack::is_stdout_redirected / `is-redirected` read this frame instead.
+        // See Stack::with_invocation_stdout for details.
+        let mut callee_stack = callee_stack.with_invocation_stdout(caller_stack.stdout().clone());
+
+        // Add one to the recursion count, so we don't recurse too deep. Stack overflows are not
+        // recoverable in Rust.
+        callee_stack.recursion_count += 1;
+
+        let result =
+            eval_block_with_early_return::<D>(engine_state, &mut callee_stack, block, input)
+                .map(|p| p.body);
+
+        // Move environment variables back into the caller stack scope if requested to do so
+        if block.redirect_env {
+            redirect_env(engine_state, caller_stack, &callee_stack);
         }
-    })();
 
-    drop(caller_stack);
+        result
+    } else {
+        let signature = decl.signature();
+
+        // `ignore` intentionally handles upstream error values at command level.
+        // Skip early input-error propagation for the built-in `ignore` command so
+        // `run()` can apply `--stderr`/`--show-errors` semantics.
+        let allow_error_input = matches!(input, PipelineData::Value(Value::Error { .. }, ..))
+            && engine_state
+                .find_decl(b"ignore", &[])
+                .is_some_and(|ignore_decl_id| ignore_decl_id == decl_id);
+        if !allow_error_input {
+            check_input_types(&input, &signature, head)?;
+        }
+
+        // Expand record spreads into named flags; drop null named values.
+        let args_len = normalize_call_arguments(&signature, caller_stack, args_base, args_len)?;
+
+        // FIXME: precalculate this and save it somewhere
+        let span = Span::merge_many(
+            std::iter::once(head).chain(
+                caller_stack
+                    .arguments
+                    .get_args(args_base, args_len)
+                    .iter()
+                    .flat_map(|arg| arg.span()),
+            ),
+        );
 
-    // Important that this runs, to reset state post-call:
-    ctx.stack.arguments.leave_frame(ctx.args_base);
-    ctx.redirect_out = None;
-    ctx.redirect_err = None;
+        let call = Call {
+            decl_id,
+            head,
+            span,
+            args_base,
+            args_len,
+        };
 
-    match result {
-        Err(err) if stderr_pipe_separate => Ok(PipelineData::Value(Value::error(err, head), None)),
-        result => result,
+        // Make sure that iterating value itself can be interrupted.
+        // e.g: 0..inf | to md
+        if let PipelineData::Value(v, ..) = &mut input {
+            v.inject_signals(engine_state);
+        }
+        // Run the call
+        decl.run(engine_state, caller_stack, &(&call).into(), input)
     }
 }
 
@@ -2324,3 +2383,43 @@ fn redirect_env(engine_state: &EngineState, caller_stack: &mut Stack, callee_sta
     // set config to callee config, to capture any updates to that
     caller_stack.config.clone_from(&callee_stack.config);
 }
+
+#[cfg(test)]
+mod tests {
+    use std::sync::atomic::AtomicBool;
+
+    use super::*;
+
+    #[test]
+    fn eval_ir_call_rejects_arguments_below_the_top_of_the_stack() {
+        let engine_state = EngineState::new();
+        let mut stack = Stack::new();
+        let mut call = Call::build(DeclId::new(0), Span::test_data());
+        call.add_positional(&mut stack, Span::test_data(), Value::test_int(1));
+        let call = call.finish();
+        // Another call's argument now sits above this call's.
+        Call::build(DeclId::new(0), Span::test_data()).add_positional(
+            &mut stack,
+            Span::test_data(),
+            Value::test_int(2),
+        );
+
+        let result = eval_ir_call(&engine_state, &mut stack, &call, PipelineData::empty());
+        assert!(matches!(result, Err(ShellError::IrEvalError { .. })));
+    }
+
+    #[test]
+    fn eval_ir_call_stops_when_interrupted() {
+        let mut engine_state = EngineState::new();
+        engine_state.set_signals(Signals::new(Arc::new(AtomicBool::new(true))));
+        let call = Call::build(DeclId::new(0), Span::test_data()).finish();
+
+        let result = eval_ir_call(
+            &engine_state,
+            &mut Stack::new(),
+            &call,
+            PipelineData::empty(),
+        );
+        assert!(matches!(result, Err(ShellError::Interrupted { .. })));
+    }
+}
diff --git a/crates/nu-engine/src/lib.rs b/crates/nu-engine/src/lib.rs
index 162e8fda..de449451 100644
--- a/crates/nu-engine/src/lib.rs
+++ b/crates/nu-engine/src/lib.rs
@@ -25,13 +25,13 @@ pub use call_ext::CallExt;
 pub use closure_eval::*;
 pub use column::get_columns;
 pub use compile::compile;
-pub use documentation::get_full_help;
+pub use documentation::{get_full_help, nu_highlight_string};
 pub use env::*;
 pub use eval::{
     CallEval, eval_block, eval_block_with_early_return, eval_call, eval_expression,
     eval_expression_with_input, eval_subexpression, eval_variable, redirect_env,
 };
 pub use eval_helpers::*;
-pub use eval_ir::eval_ir_block;
+pub use eval_ir::{eval_ir_block, eval_ir_call};
 pub use glob_from::glob_from;
 pub use scope::find_builtin_decl;
diff --git a/crates/nu-parser/src/known_external.rs b/crates/nu-parser/src/known_external.rs
index a2fd4c4d..d49a4cc7 100644
--- a/crates/nu-parser/src/known_external.rs
+++ b/crates/nu-parser/src/known_external.rs
@@ -257,7 +257,6 @@ fn ir_call_to_extern_call(
                 let name_arg = engine::Argument::Positional {
                     span: *span,
                     val: Value::string(known_external_option_name(data, *name, *short), *span),
-                    ast: None,
                 };
                 extern_call.add_argument(stack, name_arg);
             }
@@ -272,12 +271,10 @@ fn ir_call_to_extern_call(
                 let name_arg = engine::Argument::Positional {
                     span: *span,
                     val: Value::string(known_external_option_name(data, *name, *short), *span),
-                    ast: None,
                 };
                 let val_arg = engine::Argument::Positional {
                     span: *span,
                     val: val.clone(),
-                    ast: None,
                 };
                 extern_call.add_argument(stack, name_arg);
                 extern_call.add_argument(stack, val_arg);
diff --git a/crates/nu-plugin-engine/src/context.rs b/crates/nu-plugin-engine/src/context.rs
index 1599b38c..0b08b1eb 100644
--- a/crates/nu-plugin-engine/src/context.rs
+++ b/crates/nu-plugin-engine/src/context.rs
@@ -1,5 +1,5 @@
 use crate::util::MutableCow;
-use nu_engine::{ClosureEvalOnce, get_eval_block_with_early_return, get_full_help};
+use nu_engine::{ClosureEvalOnce, eval_ir_call, get_eval_block_with_early_return, get_full_help};
 use nu_plugin_protocol::{DynamicCompletionCall, EvaluatedCall};
 use nu_protocol::{
     BlockId, Config, DeclId, DynamicCompletionCallRef, IntoSpanned, OutDest, PipelineData,
@@ -249,8 +249,6 @@ impl PluginExecutionContext for PluginExecutionCommandContext<'_> {
             )));
         }
 
-        let decl = self.engine_state.get_decl(decl_id);
-
         let stack = &mut self.stack.push_redirection(
             redirect_stdout.then_some(Redirection::Pipe(OutDest::PipeSeparate)),
             redirect_stderr.then_some(Redirection::Pipe(OutDest::PipeSeparate)),
@@ -270,9 +268,10 @@ impl PluginExecutionContext for PluginExecutionCommandContext<'_> {
             }
         }
 
-        call_builder.with(stack, |stack, call| {
-            decl.run(&self.engine_state, stack, call, input)
-        })
+        let call = call_builder.finish();
+        let result = eval_ir_call(&self.engine_state, stack, &call, input);
+        call.leave(stack);
+        result
     }
 
     fn boxed(&self) -> Box<dyn PluginExecutionContext + 'static> {
diff --git a/crates/nu-protocol/src/engine/argument.rs b/crates/nu-protocol/src/engine/argument.rs
index e10faa9b..19a8e874 100644
--- a/crates/nu-protocol/src/engine/argument.rs
+++ b/crates/nu-protocol/src/engine/argument.rs
@@ -6,17 +6,9 @@ use crate::{Span, Value, ast::Expression, ir::DataSlice};
 #[derive(Debug, Clone)]
 pub enum Argument {
     /// A positional argument
-    Positional {
-        span: Span,
-        val: Value,
-        ast: Option<Arc<Expression>>,
-    },
+    Positional { span: Span, val: Value },
     /// A spread argument, e.g. `...$args`
-    Spread {
-        span: Span,
-        vals: Value,
-        ast: Option<Arc<Expression>>,
-    },
+    Spread { span: Span, vals: Value },
     /// A named argument with no value, e.g. `--flag`
     Flag {
         data: Arc<[u8]>,
@@ -31,7 +23,6 @@ pub enum Argument {
         short: DataSlice,
         span: Span,
         val: Value,
-        ast: Option<Arc<Expression>>,
     },
     /// Information generated by the parser for use by certain keyword commands
     ParserInfo {
@@ -56,18 +47,6 @@ impl Argument {
             Argument::ParserInfo { .. } => None,
         }
     }
-
-    /// The original AST [`Expression`] for the argument's value. This is not usually available;
-    /// declarations have to opt-in if they require this.
-    pub fn ast_expression(&self) -> Option<&Arc<Expression>> {
-        match self {
-            Argument::Positional { ast, .. } => ast.as_ref(),
-            Argument::Spread { ast, .. } => ast.as_ref(),
-            Argument::Flag { .. } => None,
-            Argument::Named { ast, .. } => ast.as_ref(),
-            Argument::ParserInfo { .. } => None,
-        }
-    }
 }
 
 /// Stores the argument context for calls in IR evaluation.
diff --git a/crates/nu-protocol/src/engine/call.rs b/crates/nu-protocol/src/engine/call.rs
index 7c25ea4c..f708b667 100644
--- a/crates/nu-protocol/src/engine/call.rs
+++ b/crates/nu-protocol/src/engine/call.rs
@@ -25,18 +25,6 @@ pub enum CallImpl<'a> {
 }
 
 impl Call<'_> {
-    /// Returns a new AST call with the given span. This is often used by commands that need an
-    /// empty call to pass to a command. It's not easily possible to add anything to this.
-    pub fn new(span: Span) -> Self {
-        // this is using the boxed variant, which isn't so efficient... but this is only temporary
-        // anyway.
-        Call {
-            head: span,
-            decl_id: DeclId::new(0),
-            inner: CallImpl::AstBox(Box::new(ast::Call::new(span))),
-        }
-    }
-
     /// Convert the `Call` from any lifetime into `'static`, by cloning the data within onto the
     /// heap.
     pub fn to_owned(&self) -> Call<'static> {
@@ -185,18 +173,6 @@ impl Call<'_> {
             CallImpl::IrBox(call) => by_ir(call, stack, starting_pos),
         }
     }
-
-    /// Get the original AST expression for a positional argument.
-    ///
-    /// Under IR this is usually `None`: argument AST is not retained for builtins.
-    pub fn positional_nth<'a>(&'a self, stack: &'a Stack, index: usize) -> Option<&'a Expression> {
-        match &self.inner {
-            CallImpl::AstRef(call) => call.positional_iter().nth(index),
-            CallImpl::AstBox(call) => call.positional_iter().nth(index),
-            CallImpl::IrRef(call) => call.positional_ast(stack, index).map(|arc| arc.as_ref()),
-            CallImpl::IrBox(call) => call.positional_ast(stack, index).map(|arc| arc.as_ref()),
-        }
-    }
 }
 
 impl CallImpl<'_> {
diff --git a/crates/nu-protocol/src/engine/command.rs b/crates/nu-protocol/src/engine/command.rs
index beadda21..b650ac0e 100644
--- a/crates/nu-protocol/src/engine/command.rs
+++ b/crates/nu-protocol/src/engine/command.rs
@@ -196,12 +196,6 @@ pub trait Command: Send + Sync + CommandClone + Any {
     ) -> Result<Option<Vec<DynamicSuggestion>>, ShellError> {
         Ok(None)
     }
-
-    /// Return true if the AST nodes for the arguments are required for IR evaluation. This is
-    /// currently inefficient so is not generally done.
-    fn requires_ast_for_arguments(&self) -> bool {
-        false
-    }
 }
 
 pub trait CommandClone {
diff --git a/crates/nu-protocol/src/engine/named_flags.rs b/crates/nu-protocol/src/engine/named_flags.rs
index a48fe5ff..201880eb 100644
--- a/crates/nu-protocol/src/engine/named_flags.rs
+++ b/crates/nu-protocol/src/engine/named_flags.rs
@@ -127,7 +127,6 @@ pub fn expand_flag_record(
                 short: short_slice,
                 span: spread_span,
                 val,
-                ast: None,
             });
         }
     }
@@ -175,7 +174,6 @@ pub fn normalize_engine_arguments(
                 short,
                 span,
                 val: Value::Nothing { .. },
-                ast,
             } => {
                 let accepts = find_signature_flag(signature, &data[name], &data[short])
                     .is_some_and(flag_type_accepts_nothing);
@@ -186,7 +184,6 @@ pub fn normalize_engine_arguments(
                         short,
                         span,
                         val: Value::nothing(span),
-                        ast,
                     });
                 }
                 // else: null → omit
@@ -194,7 +191,6 @@ pub fn normalize_engine_arguments(
             Argument::Spread {
                 vals,
                 span: spread_span,
-                ast,
             } => match vals {
                 Value::Record { val, .. } => {
                     expanded.extend(expand_flag_record(
@@ -210,14 +206,12 @@ pub fn normalize_engine_arguments(
                     expanded.push(Argument::Spread {
                         vals,
                         span: spread_span,
-                        ast,
                     });
                 }
                 Value::Nothing { .. } | Value::Error { .. } => {
                     expanded.push(Argument::Spread {
                         vals,
                         span: spread_span,
-                        ast,
                     });
                 }
                 other => {
diff --git a/crates/nu-protocol/src/ir/call.rs b/crates/nu-protocol/src/ir/call.rs
index 5795c09f..aa6b2233 100644
--- a/crates/nu-protocol/src/ir/call.rs
+++ b/crates/nu-protocol/src/ir/call.rs
@@ -141,23 +141,6 @@ impl Call {
         self.positional_iter(stack).nth(index)
     }
 
-    /// Get the AST node for a positional argument by index. Not usually available unless the decl
-    /// required it.
-    pub fn positional_ast<'a>(
-        &self,
-        stack: &'a Stack,
-        index: usize,
-    ) -> Option<&'a Arc<Expression>> {
-        self.arguments(stack)
-            .iter()
-            .filter_map(|arg| match arg {
-                Argument::Positional { ast, .. } => Some(ast),
-                _ => None,
-            })
-            .nth(index)
-            .and_then(|option| option.as_ref())
-    }
-
     /// Returns every argument to the rest parameter, as well as whether each argument
     /// is spread or a normal positional argument (true for spread, false for normal)
     pub fn rest_iter<'a>(
@@ -223,7 +206,11 @@ impl Call {
 
     /// Resets the [`Stack`] to its state before the call was made.
     pub fn leave(&self, stack: &mut Stack) {
-        stack.arguments.leave_frame(self.args_base);
+        // A call without arguments put nothing on the stack, and its `args_base` was never set,
+        // so leaving its frame would remove every argument on the stack.
+        if self.args_len > 0 {
+            stack.arguments.leave_frame(self.args_base);
+        }
     }
 }
 
@@ -248,26 +235,12 @@ impl CallBuilder {
 
     /// Add a positional argument to the [`Stack`] and reference it from the [`Call`].
     pub fn add_positional(&mut self, stack: &mut Stack, span: Span, val: Value) -> &mut Self {
-        self.add_argument(
-            stack,
-            Argument::Positional {
-                span,
-                val,
-                ast: None,
-            },
-        )
+        self.add_argument(stack, Argument::Positional { span, val })
     }
 
     /// Add a spread argument to the [`Stack`] and reference it from the [`Call`].
     pub fn add_spread(&mut self, stack: &mut Stack, span: Span, vals: Value) -> &mut Self {
-        self.add_argument(
-            stack,
-            Argument::Spread {
-                span,
-                vals,
-                ast: None,
-            },
-        )
+        self.add_argument(stack, Argument::Spread { span, vals })
     }
 
     /// Add a flag (no-value named) argument to the [`Stack`] and reference it from the [`Call`].
@@ -308,7 +281,6 @@ impl CallBuilder {
                 short,
                 span,
                 val,
-                ast: None,
             },
         )
     }
@@ -350,3 +322,22 @@ fn data_from_name_and_short(name: &str, short: &str) -> (Arc<[u8]>, DataSlice, D
     };
     (data, name, short)
 }
+
+#[cfg(test)]
+mod tests {
+    use super::*;
+
+    #[test]
+    fn leaving_a_call_without_arguments_keeps_the_stack() {
+        let mut stack = Stack::new();
+        let mut outer = Call::build(DeclId::new(0), Span::test_data());
+        outer.add_positional(&mut stack, Span::test_data(), Value::test_int(1));
+        let outer = outer.finish();
+
+        Call::build(DeclId::new(1), Span::test_data())
+            .finish()
+            .leave(&mut stack);
+
+        assert_eq!(outer.positional_len(&stack), 1);
+    }
+}
diff --git a/crates/nu-protocol/src/ir/mod.rs b/crates/nu-protocol/src/ir/mod.rs
index daada8a9..00fa4c73 100644
--- a/crates/nu-protocol/src/ir/mod.rs
+++ b/crates/nu-protocol/src/ir/mod.rs
@@ -39,7 +39,6 @@ pub struct IrBlock {
     pub spans: Vec<Span>,
     #[serde(with = "serde_arc_u8_array")]
     pub data: Arc<[u8]>,
-    pub ast: Vec<Option<IrAstRef>>,
     /// Additional information that can be added to help with debugging
     pub comments: Vec<Box<str>>,
     pub register_count: u32,
@@ -52,7 +51,6 @@ pub struct IrBlock {
 
 impl fmt::Debug for IrBlock {
     fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
-        // the ast field is too verbose and doesn't add much
         f.debug_struct("IrBlock")
             .field("instructions", &self.instructions)
             .field("spans", &self.spans)
@@ -61,7 +59,7 @@ impl fmt::Debug for IrBlock {
             .field("register_count", &self.register_count)
             .field("file_count", &self.file_count)
             .field("scope_regions", &self.scope_regions.len())
-            .finish_non_exhaustive()
+            .finish()
     }
 }
 
@@ -99,29 +97,6 @@ impl std::ops::Index<DataSlice> for [u8] {
     }
 }
 
-/// A possible reference into the abstract syntax tree for an instruction. This is not present for
-/// most instructions and is just added when needed.
-#[derive(Debug, Clone)]
-pub struct IrAstRef(pub Arc<Expression>);
-
-impl Serialize for IrAstRef {
-    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
-    where
-        S: serde::Serializer,
-    {
-        self.0.as_ref().serialize(serializer)
-    }
-}
-
-impl<'de> Deserialize<'de> for IrAstRef {
-    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
-    where
-        D: serde::Deserializer<'de>,
-    {
-        Expression::deserialize(deserializer).map(|expr| IrAstRef(Arc::new(expr)))
-    }
-}
-
 #[derive(Debug, Clone, Serialize, Deserialize)]
 pub enum Instruction {
     /// Unreachable code path (error)
diff --git a/crates/nu-protocol/src/pipeline/pipeline_data.rs b/crates/nu-protocol/src/pipeline/pipeline_data.rs
index 12e3a5cd..36960291 100644
--- a/crates/nu-protocol/src/pipeline/pipeline_data.rs
+++ b/crates/nu-protocol/src/pipeline/pipeline_data.rs
@@ -3,8 +3,9 @@ use crate::process::ExitStatusGuard;
 use crate::{
     ByteStream, ByteStreamSource, ByteStreamType, CompareTypes, Config, ListStream, OutDest,
     PipelineMetadata, Range, ShellError, Signals, Span, Type, TypeRelation, Value,
-    ast::{Call, PathMember},
+    ast::PathMember,
     engine::{EngineState, Stack},
+    ir,
     shell_error::{generic::GenericError, io::IoError},
 };
 use std::{
@@ -744,7 +745,7 @@ impl PipelineData {
                     if command.block_id().is_some() {
                         self.write_all_and_flush(engine_state, no_newline, to_stderr)
                     } else {
-                        let call = Call::new(Span::new(0, 0));
+                        let call = ir::Call::build(decl_id, Span::new(0, 0)).finish();
                         let table = command.run(engine_state, stack, &(&call).into(), self)?;
                         table.write_all_and_flush(engine_state, no_newline, to_stderr)
                     }
PATCH
