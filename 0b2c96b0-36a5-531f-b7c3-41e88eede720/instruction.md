# Running a command by its declaration id does not behave like calling it directly

The repository at `/app` is nushell on its main branch. A plugin can look up a command with `EngineInterface::find_decl` and run it with `EngineInterface::call_decl`. That works for built-in commands and for commands another plugin provides, but not for custom commands defined with `def`:

```rust
fn run(
    &self,
    plugin: &Self::Plugin,
    engine: &EngineInterface,
    call: &EvaluatedCall,
    input: PipelineData,
) -> Result<PipelineData, LabeledError> {
    let decl_id = engine.find_decl("foo")?;
    match decl_id {
        Some(decl_id) => engine
            .call_decl(decl_id, EvaluatedCall::new(call.head), input, true, false)
            .map_err(Into::into),
        None => Ok(PipelineData::empty()),
    }
}
```

```console
> def foo [] { 'FOO' }
> call-foo
Error: nu::shell::error

  × Internal error: can't run custom command with 'run', use block_id
```

The bundled example plugin shows the same failure through `example call-decl <name> <named-args-record> ...<positional-args>`. Calling `find_decl` followed by `call_decl` on a custom command should just run the custom command.

The plugin is one of several places where nushell runs a command it found by declaration id rather than one written in the source, including commands it picks on the user's behalf, such as the converter for a file extension or a content type, the syntax highlighter, and the table renderer. Fix the cause rather than the plugin alone. In every such place, a custom command must be called as the same direct call in a script calls it: its positional, rest, and named arguments, switches, and flag defaults bound as a direct call binds them; its declared input type checked, so input its signature does not cover is rejected instead of being handed to it; and its `$env` changes kept inside it unless it is defined with `def --env`. A converter that `http` picks for a response receives the response body as bytes of unknown type, as `open` passes a file's contents to its converter, whatever charset the response declares. `%($cmd)` checks the input type of the built-in command it runs as a direct call does, and spreading a non-empty list into a command with no rest parameter is an error. Elsewhere, a built-in command run by declaration id may have its input type checked the same way. The change must hold for every custom command, not for particular names or inputs. Apart from what this asks for, everything that works on this commit today must keep working. In particular, a call by declaration id need not reject arguments the parser would reject in a direct call, such as a missing or extra positional argument, an unknown flag, or a flag value of the wrong type, and where such a call is accepted today it must still be accepted.

Only your changes to Rust sources under `crates/*/src/` and `src/` are kept, except `crates/nu-test-support/`; changes anywhere else, including every `tests/` directory, `crates/nu-test-support/`, `Cargo.toml` files, `Cargo.lock`, and build files, are discarded before your work is evaluated. The environment has no network access. Every crate `Cargo.lock` names is already in `CARGO_HOME`, so `cargo build` and `cargo test` run offline; a full workspace build takes several minutes.
