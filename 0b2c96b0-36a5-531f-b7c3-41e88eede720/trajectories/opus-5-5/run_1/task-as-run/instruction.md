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

The plugin is not the only caller that runs a command it found rather than one written in the source. `open` and `http` hand a response to a `from <ext>` command chosen by the file extension or the content type, `save` hands its data to a `to <ext>` command chosen by the file extension, and `%($cmd)` runs a built-in command named by a string. When the command those callers pick is a custom command, or when its arguments or input do not fit its signature, the result differs from what writing the same call directly in a script produces: the input type is not checked, the flags and their defaults are not bound, and the arguments are not checked against the signature.

Make every call by declaration id behave as the same direct call would, for every custom command:

- A plugin's `call_decl` runs custom commands, with their positional, rest, and named arguments, switches, and defaults bound as a direct call binds them, and their input type checked.
- `open` and `http` run a custom `from <ext>` command, and `save` runs a custom `to <ext>` command, with its flags and defaults bound and its input type checked as a direct call does, so a converter whose signature does not cover the data it is given is an error instead of running.
- `save` keeps the `$env` changes a custom `to <ext>` command makes inside that command, unless it is defined with `def --env`.
- `%($cmd)` checks its input and its arguments as a direct call does, so spreading a list into a command that has no rest parameter is an error rather than being ignored.

Direct calls and built-in commands keep their behaviour. Everything that works on this commit today must keep working.

Only your changes to Rust sources under `crates/*/src/` and `src/` are kept, except `crates/nu-test-support/`; changes anywhere else, including every `tests/` directory, `crates/nu-test-support/`, `Cargo.toml` files, `Cargo.lock`, and build files, are discarded before your work is evaluated. The environment has no network access. Every crate `Cargo.lock` names is already in `CARGO_HOME`, so `cargo build` and `cargo test` run offline; a full workspace build takes several minutes.
