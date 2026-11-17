<p align="center"><img src="images/hero.svg" alt="hypnos" width="720"></p>

# hypnos: samples

<p align="center"><b>Five sample Harbor tasks from the hypnos corpus, each shipped with one graded agent rollout.</b></p>

<p align="center"><a href="#tasks"><img src="https://img.shields.io/badge/tasks-5-845EF7" alt="tasks: 5"></a> <a href="#rollouts"><img src="https://img.shields.io/badge/rollouts-5-845EF7" alt="rollouts: 5"></a> <a href="#agent"><img src="https://img.shields.io/badge/agent-codex_%7C_gpt--6.1--sol-845EF7" alt="agent: codex | gpt-6.1-sol"></a> <a href="#summary"><img src="https://img.shields.io/badge/AHT-690_min-845EF7" alt="AHT: 690 min"></a></p>

<p align="center"><sub><a href="#about">About</a> | <a href="#summary">Summary</a> | <a href="#tasks">Tasks</a> | <a href="#rollouts">Rollouts</a> | <a href="#rewards">Rewards</a> | <a href="#agent">Agent</a> | <a href="#dataset-structure">Dataset structure</a> | <a href="#cite">Cite</a> | <a href="#contact">Contact</a></sub></p>

## About

hypnos is Ethara AI's corpus of multilingual, issue-resolving terminal tasks for coding agents. Each task puts the agent inside a real open-source repository pinned at a fixed base commit, describes a defect the way a user would report it, and grades the agent's patch with the project's own test suite plus held-out tests the agent never sees.

This repository is the samples lane of that corpus: a small set of complete tasks you can read end to end. Each task directory is a self-contained Harbor task, and it also holds the recorded rollout of one agent run with the verifier's grading output.

## Summary

| Property | Value |
| --- | --- |
| Tasks | 5 |
| Upstream repositories | 4: `biomejs/biome`, `fabric8io/kubernetes-client`, `oxc-project/oxc`, `swc-project/swc` |
| Languages | Rust (4 tasks), Java (1 task) |
| Task format | Harbor task, schema 1.4 |
| Reward type | Bounded continuous, 0.0 to 1.0 |
| Rollouts | 5 (one per task) |
| Agent | Codex CLI 0.169.0 with `openai/gpt-6.1-sol` |
| Mean reward | 0.1351 |
| Tasks with a non-zero reward | 1 of 5 |
| Average handling time (AHT) | 690 minutes (11.5 hours) |

## Tasks

| # | Task | Upstream | Language | Issue |
| --- | --- | --- | --- | --- |
| 1 | [`33715a43`](33715a43-5ec2-50c0-91a7-1beff9cbf66b/) | `biomejs/biome` | Rust | `useExhaustiveSwitchCases` ignores unions built from `(typeof x)[number]` and `keyof typeof x` |
| 2 | [`9d748c0a`](9d748c0a-e6a9-5328-9c34-2dbbe3fb48ad/) | `fabric8io/kubernetes-client` | Java | JDK types lost their 7.x wire format, and generated CRDs reject what the client writes |
| 3 | [`abf4e028`](abf4e028-0a14-59f3-8d81-456c03830eea/) | `swc-project/swc` | Rust | Merged TypeScript namespaces and enums do not behave as TypeScript defines them |
| 4 | [`ddfc5375`](ddfc5375-1252-56f9-8ad0-fec1bbf6eb9a/) | `oxc-project/oxc` | Rust | The minifier keeps functions that nothing can ever call |
| 5 | [`e2b615ba`](e2b615ba-f3c7-55e3-898d-353bf459f701/) | `swc-project/swc` | Rust | Minified code does not behave like the source |

What each task asks the agent to do:

1. **Biome type inference** (base `97cfc6e40a31`). Teach Biome's type inference TypeScript indexed-access types with a `number` index and `keyof` on object types. Then `useExhaustiveSwitchCases` and the six other type-aware rules must see the resolved unions, stay unknown wherever the union could be incomplete, compare numeric switch cases by value, and narrow the `~~` check to the signed 32-bit range. All of this must work without whole-module inference.
2. **fabric8 JDK wire format and CRD schemas** (base `889d3b158163`). Restore the 7.x (Jackson 2) wire format of `Year`, `Month`, `java.sql.Date` and `Locale` through a public `Jackson2JdkTypesModule` that reads both forms. Also make the CRD generator map `byte[]`, `ByteBuffer`, `char[]`, `QName`, integers and these JDK types the way controller-gen does, so generated schemas never reject what the client writes.
3. **SWC TypeScript namespaces and enums** (base `75848acc40ea`). Give namespace, enum and import-alias declarations, whether single or merged from several bodies, exactly the runtime behaviour of the JavaScript that `tsc` emits. That covers name resolution across merged bodies, the same objects, members and values, and enum members evaluated the way `tsc` evaluates them.
4. **oxc dead-code elimination** (base `d76d89996f56`). Make the oxc minifier remove every function that no runnable code can reach, including functions that refer only to themselves or to each other. This must hold in every source type and compression mode that removes unused code, and everything observable must keep its behaviour.
5. **SWC minifier miscompilations** (base `75848acc40ea`). Fix SWC's JavaScript minifier so that minified programs behave exactly like their source. The reported cases are live ES module imports, parameter defaults that name outer functions or objects, `(0, super.method)()` calls, names inferred under `keep_fnames`/`keep_classnames`, self-referencing classes under mangle `keep_classnames`, and non-associative constant multiplications.

Every task also requires that everything that works at the base commit keeps working. Every instruction also limits which source directories the agent may change. The agent works offline: the task environment has no network, and the agent can reach only an allowlist of model API and sign-in hosts. Each task runs on 8 CPUs with 16 to 32 GB of memory. The agent time limit is 5 hours, except task 2, which allows 2 hours.

## Rollouts

Each task carries one rollout under `trajectories/`. The rollouts were recorded with Harbor on 13 and 14 November 2026, using the agent described in [Agent](#agent).

| # | Task | Reward |
| --- | --- | --- |
| 1 | Biome type inference | 0.0 |
| 2 | fabric8 JDK wire format and CRD schemas | 0.0 |
| 3 | SWC TypeScript namespaces and enums | 0.0 |
| 4 | oxc dead-code elimination | 0.6757 |
| 5 | SWC minifier miscompilations | 0.0 |

Mean reward across the five rollouts is 0.1351.

## Rewards

Every task uses a bounded continuous reward from 0.0 to 1.0. The verifier runs in a container separate from the agent's. Its entry point, `tests/test.sh`, builds the agent's submission, adds the task's held-out tests, runs them, and writes the result to `grade.json`.

The reward is gated. It stays at 0.0 unless grading finishes within its time budget and the gate opens. The gate opens only when all three of these hold:

- At least one fail-to-pass test now passes.
- The frame holds: every test that passed at the base commit still passes.
- No test process outlives the test phase.

Once the gate opens, Reward Kit computes the reward as a weighted mean of two kinds of rubric item:

- **Compiled items** (`tests/test_output.py`). Each item is a named group of tests that must all pass. A task has 6 to 10 of these, with a total weight of 29 to 35.
- **One judged item** (`tests/judge.toml`), with weight 3. `anthropic/claude-sonnet-5-5` reads `submission.diff` and checks that the fix is general rather than special-cased to the issue's example or the test inputs.

If no judge is reachable, the reward is computed from the compiled items alone. The weights for each task are in `tests/reward.toml`. A scored rollout's breakdown, item by item, is in `trajectories/verifier/reward-details.json`.

## Agent

| Property | Value |
| --- | --- |
| Harness | Harbor, Docker environment |
| Agent | Codex CLI 0.169.0 |
| Model | `openai/gpt-6.1-sol` |
| Skills / MCP servers | none |
| Agent user | uid 20001, non-root |
| Network | Allowlist only: `api.openai.com`, `api.anthropic.com`, plus `chatgpt.com` and `auth.openai.com` for Codex sign-in. The task environment itself has no network. |

The Codex CLI is preinstalled in each task image from checksum-verified release binaries, because the environment cannot download anything. `trajectories/result.json` records the agent and model versions, token counts and timings for each rollout.

## Dataset structure

```text
hypnos-samples/
├── README.md
├── images/hero.svg
└── <task-uuid>/                      one directory per task, named by its uuid5
    ├── task.toml                     Harbor manifest: metadata, provenance, resources, timeouts
    ├── instruction.md                the issue the agent receives
    ├── environment/                  the agent's sandbox
    │   ├── Dockerfile                pinned upstream source at the base commit, offline dependencies, Codex CLI
    │   └── codex-model-catalog.json
    ├── tests/                        the verifier
    │   ├── Dockerfile                verifier image
    │   ├── test.sh                   verifier entry point
    │   ├── grading/                  build and run scripts, held-out test diff, expected outputs
    │   ├── test_output.py            compiled rubric items
    │   ├── judge.toml                judged rubric item
    │   ├── reward.toml               reward weights
    │   └── rewardkit.lock
    └── trajectories/                 the recorded rollout
        ├── config.json               trial configuration
        ├── lock.json                 resolved task digest and run settings
        ├── result.json               agent, model, tokens, timings, reward
        ├── trial.log
        ├── agent/                    trajectory.json, codex.txt, sessions/*.jsonl, setup/
        ├── artifacts/                source directories captured from the container after the run
        └── verifier/                 reward.json, reward.txt, reward-details.json, grade.json,
                                      submission.diff, build and test logs
```

Tasks 3 and 5 (SWC) also carry an `exec-tools/` directory in `environment/` and `tests/`. Point a Harbor runner at a task directory to run that task.

## Cite

```bibtex
@misc{hypnos2026,
  title        = {hypnos: Multilingual Issue-Resolving Terminal Tasks Replayed Before the Fix},
  author       = {Ethara AI},
  year         = {2026},
  howpublished = {\url{https://github.com/EtharaOrion/hypnos}},
  note         = {Corpus in preparation; no measured difficulty published at the time of writing}
}
```

## Contact

The organization page is [Ethara AI on GitHub](https://github.com/Ethara-Ai).
