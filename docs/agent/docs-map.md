# Which doc each audience reads, and when to touch it

Long form for § Documentation Map in `AGENTS.md`.

| Doc | Audience | When to touch |
|---|---|---|
| `AGENTS.md` (root) | Agent, every session | a convention or architecture fact drifted — keep lines accurate, add nothing dated |
| `Sources/ocoreai/{Engine,UI,Handlers}/AGENTS.md` | Agent, inside that subtree | a rule that only bites inside one area belongs there, so it costs context only there |
| `docs/agent/*.md` | Human + Agent, one hop away | when a verdict needs more than three lines, move it here and leave a pointer |
| `CHANGELOG.md` | Human | every user-visible change, with its commit |
| `README.md` | Human | the product as it ships today; `make docs-check` P10 diffs it against the code that serves |
| `README.zh.md` | Human | the faithful Chinese mirror of `README.md` — the only permitted Chinese file (P18) |
| `ARCHITECTURE.md` | Human | the shape of the layers, for a reader who will not read the code first |
| `CONTRIBUTING.md` | Human + Agent | the three questions, floor/ceiling semantics, the docs contract's operator rules |
| `scripts/probes/README.md` | Human + Agent | one row per live probe: what it asserts, what it measured, which shape goes red |

