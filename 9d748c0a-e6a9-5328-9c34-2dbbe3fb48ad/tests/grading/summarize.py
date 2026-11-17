"""Reduce the test stages to /logs/verifier/grade.json and apply the reward gate."""

from __future__ import annotations

import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

LIMIT = 64_000_000
MODULES = ("kubernetes-model-common", "kubernetes-client-api", "api-v2", "test")
# Maven's module totals line; per-class lines end in `-- in <class>` and never match.
TOTALS = re.compile(r"^\[(?:INFO|WARNING|ERROR)\] Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)\s*$")
# Characters XML 1.0 forbids, which test output can carry into a report.
BAD_CHARS = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]")
BAD_REFS = re.compile(r"&#(?:x0*(?:[0-8bcef]|1[0-9a-f])|0*(?:[0-8]|1[124-9]|2[0-9]|3[01]));", re.I)
NOT_PASSED = ("failure", "error", "skipped", "flakyFailure", "flakyError", "rerunFailure", "rerunError")

# Items R1 to R5: fail-to-pass tests per item (`module/class#test`) from private/items.json.
F2P_ITEMS = ("R1", "R2", "R3", "R4", "R5")
# Compiled item R6 holds the authored pass-to-pass guard, also listed in private/items.json.
P2P_ITEMS = ("R6",)


def read(path: Path, limit: int = LIMIT) -> str:
    try:
        with path.open("rb") as handle:
            return handle.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def report(text: str) -> tuple[list[tuple[str, bool]], tuple[int, int, int]] | None:
    """Testcases of one Surefire report and its totals; None when it does not parse whole."""
    text = BAD_REFS.sub("", BAD_CHARS.sub("", text))
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return None
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite")) if root.tag == "testsuites" else []
    if not suites:
        return None
    cases, failed, skipped = [], 0, 0
    for suite in suites:
        for case in suite.findall("testcase"):
            name, cls = case.get("name") or "", case.get("classname") or ""
            tags = {child.tag for child in case}
            bad = bool(tags & set(NOT_PASSED))
            if tags & {"failure", "error"}:
                failed += 1
            elif "skipped" in tags:
                skipped += 1
            cases.append((f"{cls}#{name}", bool(name and cls) and not bad))
    return cases, (len(cases), failed, skipped)


def module_totals(console: str) -> tuple[int, int, int] | None:
    """The totals Maven printed last for the module: (tests, failures + errors, skipped)."""
    last = None
    for line in console.splitlines():
        found = TOTALS.match(line)
        if found:
            run, failures, errors, skipped = map(int, found.groups())
            last = (run, failures + errors, skipped)
    return last


def module_run(raw: Path, module: str) -> tuple[dict[str, list[bool]], dict[str, object]]:
    """Verdicts per `module/class#test` for one module run; all False when the run is not whole."""
    rc = read(raw / f"test-{module}.rc").strip()
    totals = module_totals(read(raw / f"test-{module}.out"))
    out: dict[str, list[bool]] = {}
    seen = [0, 0, 0]
    parsed = True
    directory = raw / f"reports-{module}"
    files = sorted(directory.glob("TEST-*.xml")) if directory.is_dir() else []
    for path in files:
        result = report(read(path))
        if result is None:
            parsed = False
            continue
        cases, counts = result
        for key, ok in cases:
            out.setdefault(f"{module}/{key}", []).append(ok)
        seen = [a + b for a, b in zip(seen, counts)]
    whole = rc == "0" and parsed and totals is not None and tuple(seen) == totals
    if not whole:
        out = {key: [False] * len(verdicts) for key, verdicts in out.items()}
    info = {"rc": rc, "whole": whole, "reports": len(files), "xml_totals": seen,
            "maven_totals": list(totals) if totals else None}
    return out, info


def outcomes(raw: Path) -> tuple[dict[str, list[bool]], dict[str, object]]:
    run: dict[str, list[bool]] = {}
    modules = {}
    for module in MODULES:
        tests, info = module_run(raw, module)
        run.update(tests)
        modules[module] = info
    return run, modules


def passed(run: dict[str, list[bool]], key: str, count: int = 1) -> bool:
    return run.get(key) == [True] * count


def frame_check(run: dict[str, list[bool]], base: dict[str, int]) -> dict[str, object]:
    failing = sorted(key for key, count in base.items() if not passed(run, key, count))
    by_module = {}
    for module in MODULES:
        names = [key for key in base if key.startswith(module + "/")]
        by_module[module] = {"tests": sum(base[k] for k in names),
                             "failing": sum(1 for k in failing if k.startswith(module + "/"))}
    return {"tests": sum(base.values()), "names": len(base), "failing_count": len(failing),
            "failing": failing[:200], "by_module": by_module,
            "ok": bool(base) and not failing and all(v["tests"] for v in by_module.values())}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--grading", type=Path, required=True)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--survivors", type=int, required=True)
    parser.add_argument("--elapsed", type=int, required=True)
    parser.add_argument("--emit-base", type=Path)
    args = parser.parse_args()
    raw, grading = args.raw, args.grading

    run, modules = outcomes(raw)
    if args.emit_base:
        record = {"passed": {k: len(v) for k, v in sorted(run.items()) if all(v)},
                  "not_passed": sorted(k for k, v in run.items() if not all(v)), "modules": modules}
        args.emit_base.write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
        return 0

    try:
        base = json.loads(read(grading / "private" / "base-frame.json") or "{}")
    except ValueError:
        base = {}
    frame = frame_check(run, dict(base.get("frame", {})))
    try:
        F2P = json.loads(read(grading / "private" / "items.json") or "{}")
    except ValueError:
        F2P = {}
    items = {item: bool(F2P.get(item)) and all(passed(run, key) for key in F2P[item]) for item in F2P_ITEMS + P2P_ITEMS}
    items["R7"] = frame["ok"]
    isolated = args.survivors == 0
    any_f2p = any(items[i] for i in F2P_ITEMS)
    gate_open = frame["ok"] and any_f2p and isolated
    reason = ("open" if gate_open else
              "test-phase processes survived" if not isolated else
              "frame failed" if not frame["ok"] else
              "no fail-to-pass item passed")
    stages = {name: read(raw / f"{name}.rc").strip() for name in ("build", *(f"test-{m}" for m in MODULES))}
    record = {
        "schema": "hypnos.grade/v3",
        "gate": {"open": gate_open, "frame_ok": frame["ok"], "any_fail_to_pass": any_f2p,
                 "isolated": isolated, "reason": reason},
        "items": items,
        "fail_to_pass": {key: passed(run, key) for item in F2P_ITEMS for key in F2P.get(item, [])},
        "item_failures": {item: sorted(k for k in F2P.get(item, []) if not passed(run, k))[:50]
                          for item in F2P_ITEMS + P2P_ITEMS},
        "frame": frame,
        "modules": modules,
        "stages": stages,
        "test_phase": {"survivors": args.survivors, "elapsed_s": args.elapsed, "tests_seen": len(run),
                       "tests_passed": sum(1 for v in run.values() if v and all(v))},
    }
    args.logs.mkdir(parents=True, exist_ok=True)
    (args.logs / "grade.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    if gate_open:
        return 0
    (args.logs / "reward.json").write_text(json.dumps({"reward": 0.0}) + "\n")
    details = {"gate": record["gate"], "items": items, "writer": "tests/grading/summarize.py, gate closed"}
    (args.logs / "reward-details.json").write_text(json.dumps(details, indent=2, sort_keys=True) + "\n")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
