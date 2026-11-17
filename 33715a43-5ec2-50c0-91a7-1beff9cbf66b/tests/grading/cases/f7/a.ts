interface Parent { P: number }
interface Child extends Parent { A: number }
class K { A = 1; B = 2; }
const O = { X: 1, Y: 2 } as const;
export function a(v: keyof Child) { switch (v) { case "A": break; } }
export function b(v: keyof K) { switch (v) { case "B": break; } }
export function c(v: keyof typeof O) { switch (v) { case "X": break; case "Y": break; } }
export function d(v: keyof { 1: number; A: string }) { switch (v) { case "A": break; } }
