"""Reduce the test phase to /logs/verifier/grade.json and apply the reward gate.

Runs as root after every uid 10003 process is gone. Every file it reads was written by processes
running agent-compiled code through descriptors root opened, so every read is size-bounded and parsed
with fixed patterns. Exit 0 opens the gate for Reward Kit; exit 3 means the gate is closed and
reward.json already holds 0.0. With --emit-base it instead writes the per-target frame record of the
run it reads, which is how tests/grading/base-frame.json is produced from the unchanged base.
"""

import argparse
import collections
import json
import re
from pathlib import Path

LIMIT = 64_000_000
ANSI = re.compile(r"\x1b\[[0-9;]*m")
RUNNING = re.compile(r"^\s+Running (.+) \((\S+)\)$")
DOCTESTS = re.compile(r"^\s+Doc-tests (\S+)$")
RESULT = re.compile(r"^test result: \w+\. (\d+) passed; (\d+) failed")
# A test's own unterminated output can run into the next per-test line, so test names (which hold
# no whitespace) are searched for; doc-test names hold spaces and are matched from the line start.
CASE = re.compile(r"test (\S+)(?: - should panic)? \.\.\. (ok|FAILED)$")
PENDING = re.compile(r"test (\S+)(?: - should panic)? \.\.\. $")
OUTCOME = re.compile(r"^(ok|FAILED)$")
DOC_CASE = re.compile(r"^test (.+) \.\.\. (ok|FAILED)$")
DOC_LINE = re.compile(r" \(line \d+\)$")
ROOT_TESTS = "nu:test:tests"
COMMAND_TESTS = "nu-command:test:tests"
UPSTREAM = {
    "R1": (ROOT_TESTS, "plugins::call_decl::call_custom_command"),
    "R2": (COMMAND_TESTS, "commands::save::custom_converter_binds_its_flags"),
    "R3": (COMMAND_TESTS, "commands::save::custom_converter_checks_its_input_type"),
    "R4": (COMMAND_TESTS, "commands::network::http::get::http_get_with_custom_converter"),
    "R5": (ROOT_TESTS, "repl::test_parser::percent_dynamic_dispatch_rejects_list_spread_without_rest"),
}
# R6 holds the fail-to-pass cases (c*), R9 the pass-to-pass cases (p*); R9 has no gate role.
F2P_ITEMS = ("R1", "R2", "R3", "R4", "R5", "R6")


def read(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            return handle.read(LIMIT).decode("utf-8", "replace")
    except OSError:
        return ""


def package_name(package_id: str) -> str:
    """`path+file:///x/crates/nu-cli#0.116.2` is nu-cli; `path+file:///x/src#nu@0.116.2` is nu."""
    _, _, fragment = package_id.rpartition("#")
    if "@" in fragment:
        return fragment.split("@", 1)[0]
    return package_id.split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]


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
        keys[name] = f"{package_name(record.get('package_id', ''))}:{kind}:{target.get('name')}"
    return keys


def frame_run(text: str, keys: dict[str, str]) -> dict[str, dict]:
    """Per target: the passed counts of its result lines and the multiset of names reported ok."""
    targets: dict[str, dict] = {}
    current = None
    pending = None
    for raw in text.splitlines():
        line = ANSI.sub("", raw)
        found = RUNNING.match(line)
        if found:
            exe = found.group(2).rsplit("/", 1)[-1]
            current, pending = keys.get(exe, "unmapped:" + exe), None
            targets.setdefault(current, {"results": [], "ok": collections.Counter(), "failed": collections.Counter()})
            continue
        found = DOCTESTS.match(line)
        if found:
            current, pending = "doc:" + found.group(1), None
            targets.setdefault(current, {"results": [], "ok": collections.Counter(), "failed": collections.Counter()})
            continue
        if current is None:
            continue
        found = RESULT.match(line)
        if found:
            targets[current]["results"].append(int(found.group(1)))
            pending = None
            continue
        doc = current.startswith("doc:")
        found = DOC_CASE.match(line) if doc else CASE.search(line)
        if found:
            name = DOC_LINE.sub("", found.group(1)) if doc else found.group(1)
            targets[current]["ok" if found.group(2) == "ok" else "failed"][name] += 1
            pending = None
            continue
        if doc:
            continue
        found = PENDING.search(line)
        if found:
            pending = found.group(1)
            continue
        found = OUTCOME.match(line.strip())
        if found and pending is not None:
            targets[current]["ok" if found.group(1) == "ok" else "failed"][pending] += 1
            pending = None
    return targets


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
        missing = sorted(n for n, c in want["ok"].items() if got["ok"].get(n, 0) < c)
        if missing:
            failing[key] = {"not ok at base-ok names": missing[:25], "count": len(missing)}
    return {"targets": len(base), "failing": failing, "ok": bool(base) and not failing}


def upstream(run: dict[str, dict], key: str, name: str) -> bool:
    got = run.get(key)
    return got is not None and got["ok"].get(name, 0) == 1 and got["failed"].get(name, 0) == 0


def cases(raw: Path, grading: Path) -> dict[str, bool]:
    expected = {}
    for line in read(grading / "private" / "expected.tsv").splitlines():
        case_id, _, value = line.partition("\t")
        if case_id:
            expected[case_id] = value
    out = {}
    for case_id, value in sorted(expected.items()):
        rc = read(raw / "cases" / f"{case_id}.rc").strip()
        out[case_id] = rc == "0" and read(raw / "cases" / f"{case_id}.out").strip() == value
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

    keys = executables(read(raw / "build.out"))
    run = frame_run(read(raw / "frame.out"), keys)
    if args.emit_base:
        record = {key: {"passed": sum(t["results"]), "ok": dict(sorted(t["ok"].items()))}
                  for key, t in sorted(run.items()) if t["results"]}
        args.emit_base.write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
        return 0

    try:
        base = json.loads(read(grading / "base-frame.json") or "{}")
    except ValueError:
        base = {}
    frame = frame_check(run, base)
    case_status = cases(raw, grading)
    items = {item: upstream(run, key, name) for item, (key, name) in UPSTREAM.items()}
    fail_to_pass = [ok for case_id, ok in case_status.items() if case_id.startswith("c")]
    pass_to_pass = [ok for case_id, ok in case_status.items() if case_id.startswith("p")]
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
    stages = {name: read(raw / f"{name}.rc").strip() for name in ("build", "frame", "plugin")}
    record = {
        "schema": "hypnos.grade/v3",
        "gate": {"open": gate_open, "frame_ok": frame["ok"], "any_fail_to_pass": any_f2p,
                 "isolated": isolated, "reason": reason},
        "items": items,
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
