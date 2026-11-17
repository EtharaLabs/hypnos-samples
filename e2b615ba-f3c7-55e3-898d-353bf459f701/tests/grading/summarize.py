"""Reduce the test phase to /logs/verifier/grade.json and apply the reward gate."""

from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

LIMIT = 256_000_000
ITEM_LIMIT = 4_000_000
DECODER = json.JSONDecoder()
TARGET = "swc_ecma_minifier:test:runtime_behaviour"
# libtest writes one JSON event per line; raw writes can land before, inside or after it.
EVENT_START = re.compile(r'\{ ?"type": ?"(?:test|suite)"')
# An undecodable line still names its test; its status is recovered only if it comes next.
MANGLED = re.compile(r'\{ ?"type": ?"test", ?"name": ?"([^"\\]+)", ?"event": ?"(ok|failed|ignored|timeout)"')
# A split suite result line still counts, unless it shows filtered-out tests.
MANGLED_SUITE = re.compile(r'\{ ?"type": ?"suite", ?"event": ?"(?:ok|failed)", ?"passed": ?(\d+)\D'
                           r'(?:.*?"filtered_out": ?(\d+))?')
OBSERVED = "RUNTIME-BEHAVIOUR-OBSERVED "
CASE_PREFIX = "runtime_behaviour_tests__runtime_behaviour__"
CASE_SUFFIX = "__input_js"
F2P_ITEMS = ("R1", "R2", "R3", "R4", "R5", "R6")
FRAME_ITEM = "R7"


def read(path: Path, limit: int = LIMIT) -> str:
    try:
        with path.open("rb") as handle:
            return handle.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def package_name(package_id: str) -> str:
    """Package name from a cargo package id."""
    _, _, fragment = package_id.rpartition("#")
    if "@" in fragment:
        return fragment.split("@", 1)[0]
    return package_id.split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]


def executables(text: str) -> dict[str, dict[str, str]]:
    """Each test executable cargo built: its key `<package>:<kind>:<target>` and its package dir."""
    found = {}
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("reason") != "compiler-artifact":
            continue
        if not record.get("executable") or not record.get("profile", {}).get("test"):
            continue
        target = record.get("target", {})
        kind = (target.get("kind") or ["?"])[0]
        path = record["executable"]
        found[path] = {
            "key": f"{package_name(record.get('package_id', ''))}:{kind}:{target.get('name')}",
            "dir": str(Path(record.get("manifest_path", "/nonexistent/Cargo.toml")).parent),
        }
    return found


def _empty() -> dict:
    return {"results": [], "ok": collections.Counter(), "failed": collections.Counter(),
            "ignored": collections.Counter(), "events": collections.Counter(),
            "mangled": [], "recovered": [], "stdout": {}, "observations": {}}


def parse_run(text: str) -> dict:
    """One executable's events, found anywhere on a line; undecodable ones kept as fragments."""
    run = _empty()
    for line in text.splitlines():
        starts = [m.start() for m in EVENT_START.finditer(line)]
        for start in starts:
            try:
                event, _ = DECODER.raw_decode(line, start)
            except ValueError:
                suite = MANGLED_SUITE.match(line, start)
                if suite:
                    if not int(suite.group(2) or 0):
                        run["results"].append(int(suite.group(1)))
                    continue
                fragment = MANGLED.match(line, start)
                if fragment:
                    run["mangled"].append((fragment.group(1), fragment.group(2)))
                continue
            if not isinstance(event, dict):
                continue
            kind, status = event.get("type"), event.get("event")
            if kind == "suite" and status in ("ok", "failed"):
                if not event.get("filtered_out"):
                    passed = event.get("passed")
                    if isinstance(passed, int):
                        run["results"].append(passed)
                continue
            name = event.get("name")
            if kind != "test" or not isinstance(name, str) or status == "started":
                continue
            if status == "ok":
                run["ok"][name] += 1
                if isinstance(event.get("stdout"), str):
                    run["stdout"][name] = event["stdout"]
            elif status == "ignored":
                run["ignored"][name] += 1
            else:
                run["failed"][name] += 1
            run["events"][name] += 1
    return run


def recover(run: dict) -> None:
    """Read mangled events; a mangled `ok` counts only within the suite's pass budget."""
    blocked = set(run["failed"]) | set(run["ignored"])
    blocked |= {name for name, status in run["mangled"] if status != "ok"}
    budget = sum(run["results"]) - sum(1 for count in run["ok"].values() if count)
    for name, status in run["mangled"]:
        run["events"][name] += 1
        if status == "ignored":
            run["ignored"][name] += 1
        elif status != "ok":
            run["failed"][name] += 1
        elif budget > 0 and name not in blocked and not run["ok"][name]:
            run["ok"][name] += 1
            run["recovered"].append(name)
            budget -= 1


def observed(stdout: str):
    """The record a runtime case printed last, or None."""
    for line in reversed(stdout.splitlines()):
        if line.startswith(OBSERVED):
            try:
                return json.loads(line[len(OBSERVED):])
            except ValueError:
                return None
    return None


def apply_observations(run: dict, expected_dir: Path) -> None:
    """A runtime case that ran without its record matching the original program's is failed."""
    for name in list(run["ok"]):
        if not run["ok"][name]:
            continue
        case = name[len(CASE_PREFIX):-len(CASE_SUFFIX)] if (
            name.startswith(CASE_PREFIX) and name.endswith(CASE_SUFFIX)) else None
        want = None
        if case and "/" not in case and "." not in case:
            try:
                want = json.loads(read(expected_dir / f"{case}.json", ITEM_LIMIT))
            except ValueError:
                want = None
        got = observed(run["stdout"].get(name, ""))
        run["observations"][name] = want is not None and got == want
        if not run["observations"][name]:
            run["failed"][name] += 1


def test_passed(run: dict | None, name: str) -> bool:
    return (run is not None and run["ok"].get(name, 0) >= 1 and run["failed"].get(name, 0) == 0
            and run["ignored"].get(name, 0) == 0)


def load_runs(raw: Path, keys: dict[str, dict[str, str]], expected_dir: Path) -> dict[str, dict]:
    """Every executable's run, by key; `runs.tsv` maps each run file to its executable."""
    runs = {}
    for line in read(raw / "runs.tsv").splitlines():
        stem, _, exe = line.partition("\t")
        if not stem or exe not in keys:
            continue
        run = parse_run(read(raw / "run" / f"{stem}.out"))
        recover(run)
        if keys[exe]["key"] == TARGET:
            apply_observations(run, expected_dir)
        runs[keys[exe]["key"]] = run
    return runs


def emit_frame(runs: dict[str, dict]) -> dict:
    record = {}
    for key, run in sorted(runs.items()):
        if not run["results"]:
            continue
        tests = sorted(n for n in run["ok"] if test_passed(run, n))
        record[key] = {"passed": sum(run["results"]), "tests": tests}
    return record


def frame_check(runs: dict[str, dict], base: dict) -> dict:
    """Per target: a suite result, the base pass count, and every base-ok test passing."""
    failing = {}
    for key, want in base.items():
        run = runs.get(key)
        if run is None or not run["results"]:
            failing[key] = "no suite result"
            continue
        passed = sum(run["results"])
        problems = {}
        if passed < want["passed"]:
            problems["passed"] = f"{passed} < base {want['passed']}"
        missing = [n for n in want["tests"] if not test_passed(run, n)]
        if missing:
            problems["tests not ok"] = {"names": missing[:25], "count": len(missing)}
        if problems:
            failing[key] = problems
    return {"targets": len(base), "failing": failing, "ok": bool(base) and not failing}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--grading", type=Path)
    parser.add_argument("--logs", type=Path)
    parser.add_argument("--survivors", type=int, default=0)
    parser.add_argument("--elapsed", type=int, default=0)
    parser.add_argument("--list", type=Path, metavar="WORK")
    parser.add_argument("--emit-base", type=Path)
    args = parser.parse_args()
    raw = args.raw

    keys = executables(read(raw / "build.out"))
    if args.list:
        root = args.list.resolve() / "target"
        for exe, info in sorted(keys.items(), key=lambda kv: kv[1]["key"]):
            path = Path(exe)
            if path.is_symlink() or not path.is_file() or root not in path.resolve().parents:
                continue
            print(f"{path}\t{info['dir']}")
        return 0

    grading = args.grading or Path("/grading")
    runs = load_runs(raw, keys, grading / "private" / "expected")
    if args.emit_base:
        args.emit_base.write_text(json.dumps(emit_frame(runs), indent=0, sort_keys=True) + "\n")
        return 0

    try:
        base = json.loads(read(grading / "base-frame.json") or "{}")
    except ValueError:
        base = {}
    try:
        wanted = json.loads(read(grading / "private" / "items.json", ITEM_LIMIT) or "{}")
    except ValueError:
        wanted = {}
    frame = frame_check(runs, base)
    frame["recovered"] = {key: sorted(r["recovered"]) for key, r in sorted(runs.items()) if r["recovered"]}
    run = runs.get(TARGET)
    items = {}
    detail = {}
    for item in F2P_ITEMS:
        names = wanted.get(item) or []
        bad = [name for name in names if not test_passed(run, name)]
        items[item] = bool(names) and not bad
        detail[item] = {"expected": len(names), "failing": bad[:40], "failing_count": len(bad)}
    items[FRAME_ITEM] = frame["ok"]
    isolated = args.survivors == 0
    any_f2p = any(items[i] for i in F2P_ITEMS)
    gate_open = frame["ok"] and any_f2p and isolated
    reason = ("open" if gate_open else
              "test-phase processes survived" if not isolated else
              "frame failed" if not frame["ok"] else
              "no fail-to-pass item passed")
    stages = {"build": read(raw / "build.rc").strip()}
    for line in read(raw / "runs.tsv").splitlines():
        stem = line.partition("\t")[0]
        if stem:
            stages[f"run/{stem}"] = read(raw / "run" / f"{stem}.rc").strip()
    record = {
        "schema": "hypnos.grade/v3",
        "gate": {"open": gate_open, "frame_ok": frame["ok"], "any_fail_to_pass": any_f2p,
                 "isolated": isolated, "reason": reason},
        "items": items,
        "tests": detail,
        "frame": frame,
        "stages": stages,
        "test_phase": {"survivors": args.survivors, "elapsed_s": args.elapsed,
                       "targets_seen": len(runs), "executables_mapped": len(keys)},
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
