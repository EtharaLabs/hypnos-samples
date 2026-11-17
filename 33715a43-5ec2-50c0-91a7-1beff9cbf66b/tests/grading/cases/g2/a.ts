const values = ["A", "B"] as const;
declare const k: "K";
export function a(v: ["A", ...string[]][number]) { switch (v) { case "A": break; } }
export function b(v: (typeof values)[string]) { switch (v) { case "A": break; } }
export function c(v: keyof { [key: string]: number; A: number }) { switch (v) { case "A": break; } }
export function d(v: keyof { A: number; [k]: number }) { switch (v) { case "A": break; } }
