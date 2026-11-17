const names = ["x", "y"] as const;
declare const name: (typeof names)[number];
export const n = name ?? "z";

declare const tasks: [Promise<string>, Promise<number>][number];
tasks;

declare const words: string[][number];
export const w = String(words);
