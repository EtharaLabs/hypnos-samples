export function a(v: keyof { 1: number; A: string }) { switch (v) { case "A": break; } }
export function b(v: keyof { "1": number; A: string }) { switch (v) { case "A": break; } }
