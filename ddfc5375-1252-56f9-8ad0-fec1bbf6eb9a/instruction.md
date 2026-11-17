# The minifier keeps functions that nothing can ever call

The repository at `/app` is oxc on its main branch, with the `oxc_minifier` crate at version 0.140.0. The minifier removes a function declaration nobody uses, but not one that is used only by itself or by other functions nobody uses. Compressing this ES module with unused-code removal on:

```js
function a() {}
function b() {
  if (Math.random() > 0.1) b();
}
function c() {
  if (Math.random() > 0.1) d();
}
function d() {
  if (Math.random() > 0.1) c();
}
```

removes `a` and keeps `b`, `c` and `d`, although no code that can run ever calls them. It should minify to nothing.

The minifier must remove every function that no code that can run can reach, even when it refers to itself or to other such functions, and must keep everything observable behaving exactly as before. This applies to function declarations and to variables declared with `var`, `let` or `const` whose initializer is a function or arrow function that nothing but the function itself refers to, at every nesting level, for ES modules, CommonJS modules and scripts, and both in full compression and in dead-code-elimination-only compression. Bindings that code outside the program can observe without referring to them, such as what an ES module exports at runtime and the bindings of a script's global scope, count as used, and so does everything that sets them. The change must hold for every program, not for particular names or inputs.

Everything else that works on this commit today must keep working.

Make your change only in Rust sources under `crates/oxc_minifier/src/`; leave `crates/oxc_minifier/tests/`, the other crates, `Cargo.toml` files, `Cargo.lock`, build scripts, `.cargo/` and other build files unchanged. The environment has no network access. Every crate `Cargo.lock` names is already in `CARGO_HOME`, so `cargo build` and `cargo test` run offline, for example `cargo test -p oxc_minifier`; a cold build of the minifier's tests takes under a minute at 8 CPUs and the test run takes a few seconds.
