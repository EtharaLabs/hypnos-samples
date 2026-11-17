# Minified code does not behave like the source

The repository at `/app` is SWC on its main branch. Users of SWC's JavaScript minifier (`swc_ecma_minifier`, the minifier behind `jsc.minify` and `@swc/core`'s `minify()`) have reported several programs that do something different once minified. Each report below reproduces on this commit with the compressor's default optimizations (`defaults: true`) and the options it names.

1. **Imported bindings.** An ES module import is a live binding: when the exporting module changes the exported variable, the importer sees the new value. The minifier treats imported bindings as if they never change. With `counter.js` being `export let count = 0; export function bump() { count++; }`:

   ```js
   import { count, bump } from "./counter.js";

   export function changed(f) {
       const before = count;
       f();
       return before !== count;
   }

   console.log(changed(bump), changed(() => {}));
   ```

   prints `true false`; the minified module prints `false false`.

2. **Default parameter values.** A parameter default that names a function or object defined outside the function must evaluate to that same function or object on every call:

   ```js
   (function () {
       function load(value) { return value + 1; }
       function hook([callback = load] = []) { return callback; }
       globalThis.render = function (callbacks) { return hook(callbacks); };
   })();
   console.log(render() === render([]));
   ```

   prints `true`; the minified script prints `false`.

3. **`super` method calls.** Inside a class or object-literal method, `(0, super.method)()` calls the method with `this` undefined, unlike `super.method()`. The minifier rewrites the first form into the second, so the method receives the current object.

4. **Inferred names with `keep_fnames` / `keep_classnames`.** With the compress option `keep_fnames: true`, `var f = (0, function () {});` gives `f.name === ""`, but the minified code gives the function the name `"f"`. The same happens wherever JavaScript would infer a name for an anonymous function, arrow function or class (with `keep_classnames: true` for classes) when the source writes it as `(0, ...)`.

5. **Classes that refer to themselves, with `mangle: { keep_classnames: true }`:**

   ```js
   (() => {
       class Foo {
           static self = Foo;
       }
       console.log(Foo.self === Foo);
   })();
   ```

   prints `true`; the minified script throws a `ReferenceError`.

6. **Constant factors.** `x * 24 * 60 * 60` is minified to `24 * x * 3600`. Floating-point multiplication is not associative: for `x = 365.2425` the source computes `31556951.999999996` and the minified code `31556952`.

Fix the minifier so that none of these reports reproduces and, more generally, so that for every program of these six kinds the minified program behaves exactly as the source program does when run: the same output, the same values and the same exceptions. This holds for any compress and mangle options apart from those that let the minifier assume something the program does not guarantee (such as the `unsafe*` options), including when the minifier's own output is minified again. As today, the minifier may change the `name` of a function or class unless `keep_fnames` or `keep_classnames` asks to keep it. The shape and size of the minified code are free. The change must hold for every program of these six kinds, not for particular names or inputs. Everything else that works on this commit today must keep working.

Make your change only under `crates/swc_ecma_minifier/src`, `crates/swc_ecma_ast/src`, `crates/swc_ecma_transforms_base/src`, `crates/swc_ecma_transforms_optimization/src` and `crates/swc_ecma_utils/src`; leave every `tests/` directory, `Cargo.toml` files, `Cargo.lock` and build files unchanged. The environment has no network access. Every crate `Cargo.lock` names is already in `CARGO_HOME`, so `cargo build` and `cargo test` run offline; `cargo test -p swc_ecma_minifier --no-run` takes about two minutes at 8 CPUs from a cold start, and `node` is installed for the minifier's tests that run the minified code.
