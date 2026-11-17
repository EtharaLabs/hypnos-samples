const L = ["A", "B"] as const;
const O = { X: 1, Y: 2 } as const;
export function a(v: (typeof L)[number]) { switch (v) { case "A": break; case "B": break; } }
export function b(v: keyof typeof O) { switch (v) { case "X": break; case "Y": break; } }
export function c(v: 1 | 2) { switch (v) { case 1: break; case 2: break; } }
