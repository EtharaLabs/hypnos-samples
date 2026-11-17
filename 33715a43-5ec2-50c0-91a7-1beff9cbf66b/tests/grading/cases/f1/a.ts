const Directions = ["N", "E", "W"] as const;
type Direction = (typeof Directions)[number];

export function heading(d: Direction): number {
  switch (d) {
    case "N":
      return 1;
    case "E":
      return 2;
  }
  return 0;
}

const Grades = { "N": 1, "E": 2, "W": 3 } as const;
type Grade = keyof (typeof Grades);

export function grade(g: Grade): number {
  switch (g) {
    case "N":
      return 1;
    case "E":
      return 2;
  }
  return 0;
}
