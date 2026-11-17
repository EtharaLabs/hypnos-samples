"""Reduce the test phase to /logs/verifier/grade.json and apply the reward gate."""

import argparse
import collections
import json
import re
from pathlib import Path

LIMIT = 256_000_000
ANSI = re.compile(r"\x1b\[[0-9;]*m")
RUNNING = re.compile(r"^\s+Running (.+) \((\S+)\)$")
RESULT = re.compile(r"^test result: \w+\. (\d+) passed; (\d+) failed")
# A result line with filtered-out tests comes from a nested run and never counts.
FILTERED = re.compile(r"; (\d+) filtered out")
# Test output can run into the next per-test line, so names (no whitespace) are searched for.
CASE = re.compile(r"test (\S+)(?: - should panic)? \.\.\. (ok|FAILED)$")
PENDING = re.compile(r"test (\S+)(?: - should panic)? \.\.\. $")
IGNORED = re.compile(r"test (\S+)(?: - should panic)? \.\.\. ignored")
OUTCOME = re.compile(r"^(ok|FAILED|ignored)(?:, .*)?$")
# libtest's final failure list: names there only ever block a test, never pass it.
LISTED = re.compile(r"^    (\S+)$")
FAILURE_HEADER = re.compile(r"^---- (\S+)(?: - should panic)? stdout ----$")
# Concurrent writes can split a per-test line; its `test NAME` fragment survives, LOST never passes.
LOST = ("ignored", "FAILED", "timed out")
SHOULD_PANIC = " - should panic"
ANALYZE = "biome_js_analyze:test:spec_tests"
GRAPH = "biome_module_graph:test:spec_tests"
UPSTREAM = {
    "R1": [(ANALYZE, "specs::nursery::use_exhaustive_switch_cases::issue7747_invalid_ts")],
    "R2": [(ANALYZE, "specs::nursery::use_exhaustive_switch_cases::invalid_numeric_literals_ts"),
           (ANALYZE, "specs::nursery::use_exhaustive_switch_cases::valid_numeric_literals_ts")],
    "R3": [(ANALYZE, "specs::nursery::no_floating_promises::indexed_access_invalid_ts"),
           (ANALYZE, "specs::nursery::no_unsafe_plus_operands::indexed_access_invalid_ts"),
           (ANALYZE, "specs::nursery::no_useless_type_conversion::indexed_access_invalid_ts"),
           (ANALYZE, "specs::nursery::use_await_thenable::indexed_access_invalid_ts"),
           (ANALYZE, "specs::suspicious::no_unnecessary_conditions::indexed_access_invalid_ts"),
           (ANALYZE, "specs::suspicious::no_unnecessary_conditions::indexed_access_valid_ts"),
           (ANALYZE, "specs::suspicious::use_array_sort_compare::indexed_access_invalid_ts")],
    "R4": [(ANALYZE, "specs::nursery::no_useless_type_conversion::invalid_ts")],
    "R5": [(GRAPH, "normalization::test_normalize_type_projections"),
           (GRAPH, "normalization::test_type_projections_track_imports_without_whole_module_inference")],
}
# R6 holds the fail-to-pass cases (f*), R9 the pass-to-pass cases (g*); R9 has no gate role.
F2P_ITEMS = ("R1", "R2", "R3", "R4", "R5", "R6")
# Left out of the frame: this test snapshots an internal type's Debug form, which the fix changes.
EXCLUDED = {"biome_js_type_info:test:local_inference": ["infer_type_of_call_expression_with_type_arguments"]}
DIAGNOSTIC = re.compile(r"^\S.*\.ts:\d+:\d+ lint/")


def read(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            return handle.read(LIMIT).decode("utf-8", "replace")
    except OSError:
        return ""


def package_name(package_id: str) -> str:
    """Package name from a cargo package id."""
    _, _, fragment = package_id.rpartition("#")
    if "@" in fragment:
        return fragment.split("@", 1)[0]
    return package_id.split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]


def split_build(text: str) -> str:
    """The compile phase: everything before the first Running header."""
    lines = text.splitlines()
    for number, line in enumerate(lines):
        if RUNNING.match(ANSI.sub("", line)):
            return "\n".join(lines[:number])
    return text


def executables(text: str) -> dict[str, str]:
    """Each test executable cargo built, mapped to `<package>:<kind>:<target>`."""
    keys = {}
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("reason") != "compiler-artifact" or not record.get("executable"):
            continue
        if not record.get("profile", {}).get("test"):
            continue
        target = record.get("target", {})
        kind = (target.get("kind") or ["?"])[0]
        name = record["executable"].rsplit("/", 1)[-1]
        keys.setdefault(name, f"{package_name(record.get('package_id', ''))}:{kind}:{target.get('name')}")
    return keys


def _target() -> dict:
    return {"results": [], "ok": collections.Counter(), "failed": collections.Counter(),
            "ignored": collections.Counter(), "listed": set(), "fragments": [], "recovered": []}


def _fragments(line: str, skip: int | None = None) -> list[str]:
    """The text after every `test ` in ``line`` except the one starting at ``skip``."""
    out, start = [], line.find("test ")
    while start >= 0:
        if start != skip:
            out.append(line[start + 5:])
        start = line.find("test ", start + 1)
    return out


def frame_run(text: str, keys: dict[str, str]) -> dict[str, dict]:
    """Per target: pass counts, reported names, failure-list names and split-line fragments."""
    targets: dict[str, dict] = {}
    current = None
    pending = None
    listing = False

    def drop_pending() -> None:
        nonlocal pending
        if pending is not None:
            targets[current]["fragments"].append(pending + " ... ")
        pending = None

    for raw in text.splitlines():
        line = ANSI.sub("", raw)
        found = RUNNING.match(line)
        if found:
            if current is not None:
                drop_pending()
            exe = found.group(2).rsplit("/", 1)[-1]
            current = keys.get(exe, "unmapped:" + exe)
            targets.setdefault(current, _target())
            listing = False
            continue
        if current is None:
            continue
        target = targets[current]
        found = RESULT.match(line)
        if found:
            drop_pending()
            filtered = FILTERED.search(line)
            if not (filtered and int(filtered.group(1))):
                target["results"].append(int(found.group(1)))
            target["fragments"] += _fragments(line, 0)
            listing = False
            continue
        if line == "failures:":
            drop_pending()
            listing = True
            continue
        if listing:
            found = LISTED.match(line) or FAILURE_HEADER.match(line)
            if found:
                target["listed"].add(found.group(1))
            else:
                target["fragments"] += _fragments(line)
            continue
        found = CASE.search(line)
        if found:
            target["ok" if found.group(2) == "ok" else "failed"][found.group(1)] += 1
            drop_pending()
            target["fragments"] += _fragments(line[:found.start()])
            continue
        found = OUTCOME.match(line.strip())
        if found and pending is not None:
            status = found.group(1)
            target["ok" if status == "ok" else status if status == "ignored" else "failed"][pending] += 1
            pending = None
            continue
        found = PENDING.search(line) or IGNORED.search(line)
        if found:
            drop_pending()
            if found.re is PENDING:
                pending = found.group(1)
            else:
                target["ignored"][found.group(1)] += 1
            target["fragments"] += _fragments(line, found.start())
            continue
        target["fragments"] += _fragments(line)
    if current is not None:
        drop_pending()
    return targets


def _covers(fragment: str, name: str, pristine: bool) -> bool:
    if not fragment.startswith(name):
        return False
    rest = fragment[len(name):]
    if not pristine and not rest.startswith(" "):
        return False
    if rest.startswith(SHOULD_PANIC):
        rest = rest[len(SHOULD_PANIC):]
    return not (rest.startswith(" ... ") and rest[5:].startswith(LOST))


def recover(run: dict[str, dict], expected: dict[str, dict[str, int]]) -> None:
    """Count split per-test lines as ok, within the target's reported pass count."""
    for key, got in run.items():
        if not got["results"]:
            continue
        pristine = ":test:" in key
        budget = sum(got["results"]) - sum(1 for count in got["ok"].values() if count)
        blocked = set(got["failed"]) | set(got["ignored"]) | got["listed"]
        free = list(got["fragments"])
        for name in sorted(expected.get(key, {}), key=lambda n: (-len(n), n)):
            if budget <= 0:
                break
            if name in blocked or got["ok"][name]:
                continue
            index = next((i for i, f in enumerate(free) if _covers(f, name, pristine)), None)
            if index is None:
                continue
            free.pop(index)
            got["ok"][name] += 1
            got["recovered"].append(name)
            budget -= 1


def base_record(run: dict[str, dict]) -> dict[str, dict]:
    record = {}
    for key, target in sorted(run.items()):
        if not target["results"]:
            continue
        ok = dict(target["ok"])
        passed = sum(target["results"])
        for name in EXCLUDED.get(key, []):
            if ok.pop(name, 0):
                passed -= 1
        record[key] = {"passed": passed, "ok": dict(sorted(ok.items()))}
    return record


def frame_check(run: dict[str, dict], base: dict[str, dict]) -> dict[str, object]:
    failing = {}
    for key, want in base.items():
        got = run.get(key)
        if got is None or not got["results"]:
            failing[key] = "no result line"
            continue
        passed = sum(got["results"])
        if passed < want["passed"]:
            failing[key] = f"passed {passed} < base {want['passed']}"
            continue
        # A name repeats only when a nested run reports it again, so it needs to be seen ok once.
        missing = sorted(n for n in want["ok"] if got["ok"].get(n, 0) < 1)
        if missing:
            failing[key] = {"not ok at base-ok names": missing[:25], "count": len(missing)}
    return {"targets": len(base), "failing": failing, "ok": bool(base) and not failing}


def upstream(run: dict[str, dict], tests: list[tuple[str, str]]) -> dict[str, bool]:
    out = {}
    for key, name in tests:
        got = run.get(key)
        out[name] = got is not None and got["ok"].get(name, 0) >= 1 and got["failed"].get(name, 0) == 0
    return out


def lint_summary(text: str, rc: str) -> str:
    """Each diagnostic as `file:line:col category` with its missing cases, then the exit status."""
    rows, current, missing, in_missing = [], None, "", False
    for line in text.splitlines():
        if DIAGNOSTIC.match(line):
            if current is not None:
                rows.append(current + missing)
            fields = line.split()
            current, missing, in_missing = f"{fields[0]} {fields[1]}", "", False
            continue
        if "These cases are missing:" in line:
            in_missing = True
            continue
        if in_missing and line.startswith("  - "):
            missing += f" [{line[4:]}]"
            continue
        if in_missing and ("Unsafe fix" in line or (line and not line.startswith(" "))):
            in_missing = False
    if current is not None:
        rows.append(current + missing)
    return "\n".join(sorted(rows) + [f"rc={rc}"])


def cases(raw: Path, grading: Path) -> dict[str, bool]:
    out = {}
    for expected in sorted((grading / "private" / "expected").glob("*.sum")):
        case_id = expected.stem
        rc = read(raw / "cases" / f"{case_id}.rc").strip()
        # biome prints diagnostics to stderr and its summary to stdout.
        text = read(raw / "cases" / f"{case_id}.err") + "\n" + read(raw / "cases" / f"{case_id}.out")
        got = lint_summary(text, rc)
        out[case_id] = got == read(expected).strip()
    return out


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

    text = read(raw / "test.out")
    keys = executables(split_build(text))
    run = frame_run(text, keys)
    if args.emit_base:
        args.emit_base.write_text(json.dumps(base_record(run), indent=1, sort_keys=True) + "\n")
        return 0

    try:
        base = json.loads(read(grading / "base-frame.json") or "{}")
    except ValueError:
        base = {}
    expected = {key: dict(want["ok"]) for key, want in base.items()}
    for names in UPSTREAM.values():
        for key, name in names:
            expected.setdefault(key, {}).setdefault(name, 1)
    recover(run, expected)
    frame = frame_check(run, base)
    frame["recovered"] = {key: sorted(t["recovered"]) for key, t in sorted(run.items()) if t["recovered"]}
    case_status = cases(raw, grading)
    tests = {item: upstream(run, names) for item, names in UPSTREAM.items()}
    items = {item: all(status.values()) for item, status in tests.items()}
    fail_to_pass = [ok for case_id, ok in case_status.items() if case_id.startswith("f")]
    pass_to_pass = [ok for case_id, ok in case_status.items() if case_id.startswith("g")]
    items["R6"] = bool(fail_to_pass) and all(fail_to_pass)
    items["R7"] = frame["ok"]
    items["R9"] = bool(pass_to_pass) and all(pass_to_pass)
    isolated = args.survivors == 0
    any_f2p = any(items[i] for i in F2P_ITEMS)
    gate_open = frame["ok"] and any_f2p and isolated
    reason = ("open" if gate_open else
              "test-phase processes survived" if not isolated else
              "frame failed" if not frame["ok"] else
              "no fail-to-pass item passed")
    stages = {"test": read(raw / "test.rc").strip()}
    stages.update({f"cases/{c}": read(raw / "cases" / f"{c}.rc").strip() for c in case_status})
    record = {
        "schema": "hypnos.grade/v3",
        "gate": {"open": gate_open, "frame_ok": frame["ok"], "any_fail_to_pass": any_f2p,
                 "isolated": isolated, "reason": reason},
        "items": items,
        "upstream_tests": tests,
        "cases": case_status,
        "frame": frame,
        "stages": stages,
        "test_phase": {"survivors": args.survivors, "elapsed_s": args.elapsed,
                       "targets_seen": len(run), "executables_mapped": len(keys)},
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
