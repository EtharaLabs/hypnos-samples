const xs = ["A", "B", "C"];
export function f(v: (typeof xs)[number]) {
  switch (v) {
    case "A": break;
  }
}
