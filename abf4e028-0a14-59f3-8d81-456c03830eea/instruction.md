# Merged TypeScript namespaces and enums do not behave as TypeScript defines them

The repository at `/app` is SWC on its main branch. A Next.js user reported that compiling TypeScript with SWC leads to a `ReferenceError` at runtime when a namespace is declared more than once:

```typescript
export namespace Test {
    export const a = 1;
}

export namespace Test {
    export const b = a + 1;
}
```

with this configuration:

```json
{
  "jsc": {
    "parser": { "syntax": "typescript", "tsx": false },
    "minify": { "compress": false, "mangle": false }
  },
  "module": { "type": "es6" },
  "minify": false,
  "isModule": true,
  "env": { "targets": "Safari 10" }
}
```

SWC 1.15.11 produces:

```js
(function(Test) {
    Test.a = 1;
})(Test || (Test = {}));
(function(Test) {
    Test.b = a + 1; // undeclared variable
})(Test || (Test = {}));
export var Test;
```

Babel and `tsc` both produce code in which `Test.b` is `2`. A second report shows the same name picked up from the wrong place when an outer binding exists:

```typescript
namespace Test {
    export const a = 1;
}

const a = "out";

namespace Test {
    export const b = a + 1; // Here, `a` should reference Test.a, not the outer `a`
}
```

Here SWC resolves `a` to the outer `"out"`, so `Test.b` is `"out1"` instead of `2`.

SWC's TypeScript transform must give namespace, enum and `import =` declarations exactly the runtime behaviour of the JavaScript the TypeScript compiler (`tsc`) emits for the same program, whether a declaration has one body or is merged from several. Run, the emitted code must create the same namespace and enum objects (and no others), with the same members, values and reverse mappings, and every expression must evaluate to what it evaluates to in `tsc`'s output. In particular, an unqualified name inside a body of a namespace or enum resolves as TypeScript resolves it: to a value member that any body of the same declaration exports, before an outer binding of that name, while names the body binds itself keep their own binding; and enum members are evaluated as `tsc` evaluates them. This holds for every configuration of the TypeScript transform, with one existing exception: unless `tsEnumIsMutable` is set, reads of enum members may be inlined on the assumption that enums are never mutated. The shape of the emitted code (names of generated parameters, which values are inlined, statement layout) is free. Everything else that works on this commit today must keep working.

Make your change only under `crates/swc_ecma_transforms_typescript/src`, `crates/swc_ecma_transforms_base/src`, `crates/swc_ecma_utils/src` and `crates/swc_atoms/src`; leave every `tests/` directory, `Cargo.toml` files, `Cargo.lock` and build files unchanged. The environment has no network access. Every crate `Cargo.lock` names is already in `CARGO_HOME`, so `cargo build` and `cargo test` run offline; `cargo test -p swc_ecma_transforms_typescript` builds and runs in about two minutes at 8 CPUs from a cold start, and `node` with `mocha` is installed for the repository's own execution tests (those that import `@swc/helpers` fail here because that package is not installed).
