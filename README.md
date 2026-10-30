<p align="center"><img src="images/hero.svg" alt="hypnos" width="720"></p>

# hypnos: samples

<p align="center"><b>The samples lane: 1 of 30 Harbor task bundles.</b></p>

<p align="center"><a href="#summary"><img src="https://img.shields.io/badge/bundles-1_of_30-845EF7" alt="bundles: 1 of 30"></a> <a href="#evidence-status"><img src="https://img.shields.io/badge/sealed-0-845EF7" alt="sealed: 0"></a> <a href="#difficulty-tiers"><img src="https://img.shields.io/badge/difficulty-measured-845EF7" alt="difficulty: measured"></a></p>

<p align="center"><sub><a href="#abstract">Abstract</a> | <a href="#summary">Summary</a> | <a href="#difficulty-tiers">Difficulty tiers</a> | <a href="#evidence-status">Evidence status</a> | <a href="#coverage">Coverage</a> | <a href="#dataset-structure">Dataset structure</a> | <a href="#verification-and-quality-assurance">Verification and quality assurance</a> | <a href="#reproduction">Reproduction</a> | <a href="#cite">Cite</a> | <a href="#license">License</a> | <a href="#contact">Contact</a></sub></p>

## Abstract

The curated lane of this corpus: at most 30 Harbor task bundles, every anchor seated first and every other bundle in seal order. Bundles past that ceiling live in `delivery/`.

Each bundle is one Harbor task in a directory named by its content-derived uuid5, so the name doubles as an integrity check. This page is rendered from the resident bundles on every reconcile; a value a bundle does not carry reads `absent`, and the page never fills one in.

## Summary

| Property | Value |
| --- | --- |
| Bundles | 1 of 30 |
| Sealed | 0 of 1 |
| Registrations | unregistered (1) |
| Audit verdicts | none (1) |
| Harbor schema | 1.4 (1) |

## Difficulty tiers

Difficulty is measured by the signed pilot alone and never declared in a bundle, so this page states no tier a bundle claims.

## Evidence status

The verdict is the audit outcome recorded at the sealed digest, and `none` means no verdict has landed for that digest yet. Only an authoring run removes a bundle from this lane, so removal waits for the next one.

| uuid | Verdict | Sealed digest | Stream |
| --- | --- | --- | --- |
| 0b2c96b0-36a5-531f-b7c3-41e88eede720 | none | absent | none |

## Coverage

| Keyword | Bundles |
| --- | --- |
| issue-resolution | 1 |
| multi-swe-bench | 1 |
| nushell | 1 |
| rewardkit | 1 |
| rust | 1 |

## Dataset structure

| Bundle | Task | Keywords | Registration | Sealed at | Tier |
| --- | --- | --- | --- | --- | --- |
| [`0b2c96b0-36a5-531f-b7c3-41e88eede720`](0b2c96b0-36a5-531f-b7c3-41e88eede720/) | `etharaorion/nushell-call-by-decl-id-as-direct-call` | issue-resolution, multi-swe-bench, nushell, rewardkit, rust | unregistered | unsealed | - |

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#131a33","primaryTextColor":"#e8ecff","primaryBorderColor":"#845EF7","lineColor":"#22d3ee","fontFamily":"monospace"}}}%%
flowchart LR
    bundle["&lt;uuid&gt;/"]
    bundle --> n0["task.toml<br/>runner manifest"]
    bundle --> n1["instruction.md<br/>objective the agent reads"]
    bundle --> n2["environment/<br/>agent sandbox image"]
    bundle --> n3["tests/<br/>verifier, hidden from the agent"]
    bundle --> n4["solution/<br/>private oracle"]
    bundle --> n5["trajectories/"]
```

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#131a33","primaryTextColor":"#e8ecff","primaryBorderColor":"#845EF7","lineColor":"#22d3ee","fontFamily":"monospace"}}}%%
flowchart LR
    staging["staging/"]
    staging --> samples["samples/<br/>1 of 30"]
    samples --> delivery["delivery/<br/>0 of 10000"]
    delivery --> stock["stock/<br/>0 of 10000"]
```

## Verification and quality assurance

Each bundle's signed provenance carrier holds its screening roots, screening instant, and absolute expiry. Placement moves that carrier into the private derivation set, which this page never reads, so reconcile lists no root it cannot verify here.

## Reproduction

Each bundle directory is a complete Harbor task: `task.toml` is the runner manifest, `instruction.md` the objective, `environment/` the sandbox image, and `tests/` the verifier. Point a Harbor runner at one bundle directory to reproduce it; `solution/` stays private.

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

The reference benchmark this corpus is built against is cited in [Related work](#related-work).

## License

Released under the MIT License. See [LICENSE](LICENSE).

Each task bundle carries the license of the upstream repository its environment is built from, and that license governs the task's own contents.

Copyright (c) 2026 Green Rider Technology LLP (Ethara AI). All rights reserved.

## Contact

The organization page is [Ethara AI on GitHub](https://github.com/Ethara-Ai).

Report a vulnerability or a benchmark-integrity defect privately through the process in [SECURITY.md](SECURITY.md). Do not open a public issue for either.

To propose a change, read [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution route and the sign-off it requires.

Copyright (c) 2026 Green Rider Technology LLP (Ethara AI). All rights reserved.
