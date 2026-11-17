interface Parent { P: number }
interface Child extends Parent { A: number }
class K { A = 1; B = 2; }
export function a(v: keyof Child) { switch (v) { case "A": break; } }
export function b(v: keyof Readonly<Child>) { switch (v) { case "A": break; } }
export function c(v: keyof (Child & { B: number })) { switch (v) { case "A": break; } }
export function d(v: keyof K) { switch (v) { case "A": break; } }
