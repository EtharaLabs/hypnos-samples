const e = ["\u0041", "B"] as const;
const o = { "\u0041": 1, B: 2 } as const;
export function a(v: (typeof e)[number]) { switch (v) { case "B": break; } }
export function b(v: keyof typeof o) { switch (v) { case "B": break; } }
