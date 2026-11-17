"""Reduce the test phase to /logs/verifier/grade.json and apply the reward gate."""

from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

LIMIT = 64_000_000
DECODER = json.JSONDecoder()
# libtest writes one JSON event per line; raw writes can land before, inside or after it.
EVENT_START = re.compile(r'\{ ?"type": ?"(?:test|suite)"')
# An undecodable line still names its test; its status is recovered only if it comes next.
MANGLED = re.compile(r'\{ ?"type": ?"test", ?"name": ?"([^"\\]+)", ?"event": ?"(ok|failed|ignored|timeout)"')
# Split suite results count unless filtered; a split test status is read from a following line.
NAME_ONLY = re.compile(r'\{ ?"type": ?"test", ?"name": ?"([^"\\]+)"')
STATUS_TAIL = re.compile(r'"event": ?"(ok|failed|ignored|timeout)"')
MANGLED_SUITE = re.compile(r'\{ ?"type": ?"suite", ?"event": ?"(?:ok|failed)", ?"passed": ?(\d+)\D'
                           r'(?:.*?"filtered_out": ?(\d+))?')
MOD = "oxc_minifier:test:mod"
RUD = "peephole::remove_unused_declaration::"
DCE = "peephole::dead_code_elimination::"
# Upstream fail-to-pass tests per rubric item; an item passes iff all its tests pass.
ITEMS = {
    "R1": [RUD + "remove_recursive_unused_function_declaration"],
    "R2": [RUD + "remove_recursive_unused_nested_in_live_function"],
    "R3": [RUD + "remove_self_recursive_function_valued_declarators",
           RUD + "remove_self_recursive_for_init_declarator"],
    "R4": [RUD + "remove_recursive_function_after_eval_dropped"],
    "R5": [RUD + "analyze_commonjs_and_script_local_functions",
           RUD + "keep_commonjs_references_and_script_global_functions",
           RUD + "keep_sloppy_duplicate_block_functions"],
    "R6": [DCE + "dce_recursive_unused_functions",
           DCE + "dce_recursive_unused_functions_in_commonjs_and_script",
           DCE + "dce_keeps_sloppy_duplicate_block_functions"],
    "R7": [RUD + "keep_exported_var_initializer_when_a_dead_cycle_held_its_only_reference",
           RUD + "keep_exported_binding_writes_when_a_dead_cycle_held_its_other_reads",
           RUD + "keep_exported_iife_init_when_a_dead_cycle_held_its_only_reference",
           RUD + "module_export_observability_kinds",
           RUD + "export_observability_ignores_declarations_inside_exported_arrow"],
    "R8": [RUD + "keep_sloppy_annex_b_alias_member_write_after_cycle_removed",
           RUD + "keep_script_root_var_in_nested_statement_after_cycle_removed",
           RUD + "keep_using_member_write_observed_by_disposal",
           DCE + "dce_keeps_implicitly_observable_bindings",
           DCE + "dce_keeps_script_root_var_in_nested_statement_after_cycle_removed"],
    "R9": [RUD + "recursive_function_var_redeclaration_converges_on_count_pass",
           RUD + "for_head_reachability_uses_ordinary_references"],
}
FRAME_ITEM = "R10"


def read(path: Path, limit: int = LIMIT) -> str:
    try:
        with path.open("rb") as handle:
            return handle.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def package_name(package_id: str) -> str:
    """`path+file:///x/crates/oxc_minifier#0.140.0` is oxc_minifier; `...#name@1.0.0` is name."""
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
        if record.get("reason") != "compiler-artifact" or not record.get("executable"):
            continue
        if not record.get("profile", {}).get("test"):
            continue
        target = record.get("target", {})
        kind = (target.get("kind") or ["?"])[0]
        found[record["executable"]] = {
            "key": f"{package_name(record.get('package_id', ''))}:{kind}:{target.get('name')}",
            "dir": str(Path(record.get("manifest_path", "/nonexistent/Cargo.toml")).parent),
        }
    return found


def _empty() -> dict:
    return {"results": [], "ok": collections.Counter(), "failed": collections.Counter(),
            "ignored": collections.Counter(), "mangled": [], "recovered": []}


def parse_run(text: str) -> dict:
    """One executable's events, found anywhere on a line; undecodable ones kept as fragments."""
    run = _empty()
    pending = None
    for line in text.splitlines():
        starts = [m.start() for m in EVENT_START.finditer(line)]
        if pending is not None:
            name, budget = pending
            status = STATUS_TAIL.search(line, 0, starts[0] if starts else len(line))
            if status:
                run["mangled"].append((name, status.group(1)))
                pending = None
            else:
                pending = (name, budget - 1) if budget > 1 and not starts else None
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
                head = NAME_ONLY.match(line, start)
                if head and not STATUS_TAIL.search(line, head.end()):
                    pending = (head.group(1), 3)
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
            elif status == "ignored":
                run["ignored"][name] += 1
            else:
                run["failed"][name] += 1
    return run


def recover(run: dict) -> None:
    """Read mangled events; a mangled `ok` counts only within the suite's pass budget."""
    blocked = set(run["failed"]) | set(run["ignored"])
    blocked |= {name for name, status in run["mangled"] if status != "ok"}
    budget = sum(run["results"]) - sum(1 for count in run["ok"].values() if count)
    for name, status in run["mangled"]:
        if status == "ignored":
            run["ignored"][name] += 1
        elif status != "ok":
            run["failed"][name] += 1
        elif budget > 0 and name not in blocked and not run["ok"][name]:
            run["ok"][name] += 1
            run["recovered"].append(name)
            budget -= 1


def test_passed(run: dict | None, name: str) -> bool:
    return (run is not None and run["ok"].get(name, 0) >= 1 and run["failed"].get(name, 0) == 0
            and run["ignored"].get(name, 0) == 0)


def load_runs(raw: Path, keys: dict[str, dict[str, str]]) -> dict[str, dict]:
    """Every executable's run, by key; `runs.tsv` maps each run file to its executable."""
    runs = {}
    for line in read(raw / "runs.tsv").splitlines():
        stem, _, exe = line.partition("\t")
        if not stem or exe not in keys:
            continue
        run = parse_run(read(raw / "run" / f"{stem}.out"))
        recover(run)
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

    runs = load_runs(raw, keys)
    if args.emit_base:
        args.emit_base.write_text(json.dumps(emit_frame(runs), indent=0, sort_keys=True) + "\n")
        return 0

    try:
        base = json.loads(read(args.grading / "private" / "base-frame.json") or "{}")
    except ValueError:
        base = {}
    frame = frame_check(runs, base)
    frame["recovered"] = {key: sorted(r["recovered"]) for key, r in sorted(runs.items()) if r["recovered"]}
    mod = runs.get(MOD)
    items = {}
    failing_tests = {}
    for item, names in ITEMS.items():
        bad = [name for name in names if not test_passed(mod, name)]
        items[item] = not bad
        failing_tests[item] = bad
    items[FRAME_ITEM] = frame["ok"]
    isolated = args.survivors == 0
    any_f2p = any(items[i] for i in ITEMS)
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
        "failing_tests": failing_tests,
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
