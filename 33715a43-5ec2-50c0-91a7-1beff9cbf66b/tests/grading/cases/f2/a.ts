import { Colors, Sizes } from "./values.ts";
type ColorList = typeof Colors;
type Num = number;
type Color = ColorList[Num];
type SizeObj = typeof Sizes;
type Size = keyof SizeObj;

export function color(c: Color): number {
  switch (c) {
    case "red":
      return 1;
  }
  return 0;
}

export function size(s: Size): number {
  switch (s) {
    case "small":
      return 1;
    case "large":
      return 3;
  }
  return 0;
}

export function ro(v: (readonly [7, 8, 9])[number]): number {
  switch (v) {
    case 7:
      return 1;
    case 9:
      return 2;
  }
  return 0;
}
