# FORGE-CANARY-BEGIN
# FORGE-CANARY-SLOT-1: 53b3d68b043f0ac9ebd47bd8f67b19e6b7fa14e174aa9caffdb90444975aa7f3
# FORGE-CANARY-SLOT-2: 38b25c13f561e095dd794f20ce1e467469f45f1b8189951f4b69665b6a622818
# FORGE-CANARY-SLOT-3: 6d1b364b7c03a9c801ba00be36cef100ff8e18f5ba1be4973fa3eb7ba9ca94e1
# FORGE-CANARY-SLOT-4: 8b58ce62941667e72e8c86e7b3c70b3a37a6b0a50d84d4e72d8362b623414dc3
# FORGE-CANARY-END
"""Regenerate the oracle, the truth projection, and the compiled criteria from grounding.yaml.

Usage: python recompute.py [--check]. With --check it writes nothing and exits 1 on any drift.
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASK = HERE.parent
GENERATED = "GENERATED SECTION. DO NOT HAND-EDIT."


def load(text: str) -> tuple[dict, list[str]]:
    """The grounding record and its canary block lines, which every generated carrier repeats."""
    canary = [line[2:] for line in text.splitlines() if line.startswith("# FORGE-CANARY-")]
    record = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            key, _, value = line.partition(": ")
            record[key] = json.loads(value)
    return record, canary


def solve_sh(g: dict, canary: list[str]) -> str:
    patch = "\n".join(g["fix_patch"])
    return (
        "#!/bin/bash\n"
        f"# {GENERATED}\n"
        + "".join(f"# {line}\n" for line in canary)
        + "set -euo pipefail\n"
        "cd /app\n"
        "patch -p1 --fuzz=0 <<'PATCH'\n"
        f"{patch}\n"
        "PATCH\n"
    )


def truth_md(g: dict, canary: list[str]) -> str:
    lines = ["# Golden trajectory", "", GENERATED, "", *[f"<!-- {line} -->" for line in canary], "",
             "## Ordered path", ""]
    for number, step in enumerate(g["trajectory"], start=1):
        lines.append(f"{number}. {step}")
    lines += ["", "## Deliverables and red lines", ""]
    for d in g["deliverables"]:
        lines.append(f"- `{d['id']}` at `{d['surface']}`: {d['requirement']}")
    for r in g["red_lines"]:
        lines.append(f"- `{r['id']}`: {r['rule']} Enforced by {r['enforced_by']}.")
    lines += ["", "## Rubric items", ""]
    for item in g["items"]:
        lines.append(
            f"- `{item['id']}` ({item['mode']}, weight {item['weight']}, {item['obligation']}, "
            f"{item['dimension']}): {item['description']}."
        )
    lines += ["", "## Authored cases (R6 fail-to-pass c*, R9 pass-to-pass p*)", ""]
    for case in g["authored_cases"]:
        lines.append(f"- `{case['id']}` ({case['covers']}): {case['case']}.")
    for dropped in g["dropped_cases"]:
        lines.append(f"- dropped: {dropped}.")
    lines += ["", "## Rejected routes", ""]
    for k in g["known_wrong"]:
        lines.append(f"- `{k['id']}`: {k['route']}")
    return "\n".join(lines) + "\n"


def test_output_py(g: dict) -> str:
    compiled = [item for item in g["items"] if item["mode"] == "compiled"]
    out = [
        f'"""{GENERATED} Compiled rubric items read /logs/verifier/grade.json; tests/test.sh starts',
        'Reward Kit only when the reward gate in tests/grading/summarize.py is open."""',
        "",
        "import json",
        "from pathlib import Path",
        "",
        "import rewardkit as rk",
        "from rewardkit import criterion",
        "",
        'GRADE = Path("/logs/verifier/grade.json")',
        "",
        "",
        '@criterion(description="{item}: {text}")',
        "def rubric_item(workspace: Path, item: str, text: str) -> float:",
        "    if not GRADE.is_file():",
        "        return 0.0",
        "    grade = json.loads(GRADE.read_text())",
        '    if grade.get("gate", {}).get("open") is not True:',
        "        return 0.0",
        '    return 1.0 if grade.get("items", {}).get(item) is True else 0.0',
        "",
        "",
    ]
    for item in compiled:
        out.append(
            f'rk.rubric_item("{item["id"]}", {json.dumps(item["description"])}, '
            f'weight={item["weight"]}, name="{item["id"]}")'
        )
    return "\n".join(out) + "\n"


def provenance_yaml(g: dict, canary: list[str], current: str) -> str:
    """The canonical provenance payload, regenerated from grounding.yaml, followed by the binding
    block already in the carrier; the block is applied after generation and is never generated."""
    payload = [*[f"# {line}" for line in canary], f"# {GENERATED}", *g["provenance_lines"]]
    lines = current.split("\n")
    start = next((i for i, line in enumerate(lines) if line == "binding:"), None)
    binding = [line for line in lines[start:] if line] if start is not None else ["binding:"]
    return "\n".join(payload + binding) + "\n"


def outputs(g: dict, canary: list[str]) -> dict[Path, str]:
    return {
        HERE / "solve.sh": solve_sh(g, canary),
        HERE / "TRUTH.md": truth_md(g, canary),
        TASK / "tests" / "test_output.py": test_output_py(g),
        HERE / "provenance.yaml": provenance_yaml(g, canary, (HERE / "provenance.yaml").read_text()),
    }


def main(argv: list[str]) -> int:
    g, canary = load((HERE / "grounding.yaml").read_text())
    drift = []
    for path, text in outputs(g, canary).items():
        if "--check" in argv:
            if not path.is_file() or path.read_text() != text:
                drift.append(path.relative_to(TASK).as_posix())
        else:
            path.write_text(text)
            if path.suffix == ".sh":
                path.chmod(0o755)
    for name in drift:
        print(f"drift: {name}")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
