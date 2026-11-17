# `useExhaustiveSwitchCases` ignores unions built from `(typeof x)[number]` and `keyof typeof x`

The repository at `/app` is Biome on its main branch. Biome's type-aware lint rules do not understand TypeScript indexed-access types (`T[number]`) or `keyof` applied to object types. Take this example from a user report:

```ts
const LetterValues = ["A", "B", "C"] as const;
type Letter = (typeof LetterValues)[number];

function test(letter: Letter): number {
  switch (letter) {
    case "A":
      return 1;
    case "B":
      return 1;
  }
}

const Bar = { "A": 1, "B": 2, "C": 3 } as const;
type Letter2 = keyof (typeof Bar);

function test2(letter: Letter2): number {
  switch (letter) {
    case "A":
      return 1;
    case "B":
      return 1;
  }
}
```

With `nursery/useExhaustiveSwitchCases` enabled, both switches should be reported as not exhaustive, with `"C"` as the missing case, but Biome reports nothing. With `suspicious/noUnnecessaryConditions` enabled, Biome also wrongly reports `case "A"` and `case "B"` in `test2` as unreachable.

Make these types work for every type-aware rule. The required behaviour follows.

Results that would be a union of more than 1024 members, or tuples longer than 1024 elements, stay unknown.

## 1. `T[number]`

- If `T` is a tuple type, a `readonly` tuple type, or the `typeof` of an `as const` array, the result is the union of its element types in order, as TypeScript computes it. This also applies when `T` or the index is reached through type aliases (`type Index = number; Values[Index]`) or through an imported binding.
- If `T` is an array type `E[]`, the result is `E`.
- Any other form, and any result that cannot be represented exactly as the union of a fixed list of element types, or that refers to itself, must stay **unknown**, so that no rule draws a conclusion from it.

## 2. `keyof`

- `keyof` an object type literal, or `keyof typeof` an object literal, gives the union of its property names as string literal types in declaration order, as TypeScript computes it.
- `Readonly<O>`, `Partial<O>`, `Required<O>`, `Pick<O, K>` and `Omit<O, K>` give the keys TypeScript gives only when every key of `O` and every requested key is known exactly.
- Any other form, and any object whose keys cannot all be represented exactly as a fixed list of non-numeric string literal names declared on the object itself, must stay **unknown**.

## 3. Incremental behaviour

Resolving the type of a single binding that uses these types must not run whole-module type inference, either for its own module or for the modules it imports from. Editing an unrelated module must not cause the type to be normalised again. Editing the imported definitions must update the result.

## 4. Rules

Every type-aware rule must see the resolved types:

- `useExhaustiveSwitchCases` must report the missing members.
- `noUnnecessaryConditions` must flag `x ?? y` or `if (x)` on a projection that cannot be nullish or falsy. It must flag a `case` that can never match, and it must not flag reachable cases.
- `noFloatingPromises` must flag an unused projected promise.
- `useAwaitThenable` must flag `await` on a projected non-thenable.
- `noUnsafePlusOperands` must flag adding a number projection to a bigint.
- `noUselessTypeConversion` must flag `String(x)`, `Number(x)` and `Boolean(x)` on projections that already have the target type.
- `useArraySortCompare` must flag `.sort()` and `.toSorted()` on projected number arrays.

## 5. Numeric `case` values in `useExhaustiveSwitchCases`

- Number literal types and `case` values must be compared by the numeric value JavaScript gives them, as a `switch` compares them at run time, not by spelling.
- Missing numeric cases are listed, and inserted by the rule's code fix, in JavaScript's shortest decimal form, in the order of the union, with values equal to an earlier one removed.
- Report nothing for a switch whose discriminant or `case` values include a value the rule cannot compare exactly as JavaScript does.

## 6. `~~x` in `noUselessTypeConversion`

Report `~~x` as useless only when every possible value is a bigint, or an integer number literal within the signed 32-bit range that is not `-0`.

## Invariant

Everything that works on this commit today must keep working. Only the debug form of internal type-inference data may change along with that data.

## Environment

Make your change only in Rust sources under `crates/*/src/` and `xtask/codegen/src/`, outside the test-support crates `crates/biome_test_utils/`, `crates/biome_formatter_test/` and `crates/tests_macros/`; do not rely on changes anywhere else, including any `tests/` directory, any `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml` or `build.rs`. The environment has no network access. Every crate `Cargo.lock` names, including its git dependencies, is already in `CARGO_HOME`, and the toolchain, `rustfmt`, `clippy` and the `wasm32-unknown-unknown` target are installed, so `cargo build` and `cargo test` run offline. Code generators that download their inputs do not work offline. A cold build of one crate's tests, such as `cargo test -p biome_js_analyze --test spec_tests`, takes 2 to 3 minutes on 8 CPUs, and a cold build of every workspace test target takes about 6 minutes and needs more than 16 GB of memory to link.
