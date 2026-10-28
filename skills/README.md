# ocoreai skills

This repo ships the skill that teaches **another agent** how to drive it: `skills/ocoreai/SKILL.md`
(`references/` holds the wire table, the loop contract, and the honesty-field map). It exists because an
HTTP surface that only prose documents is undiscoverable — and because this project publishes what it
measured, so a caller can tell `not_observed` from `supported`.

The skill is executed, not trusted:

```bash
bash scripts/probes/run.sh 39
```

`scripts/probes/39-skill-contract-exec.sh` boots its own server, runs every `exec:` marker in the skill,
and fails on its own floor if it finds too few — so a marker that stops matching is a red build, not a
stale paragraph.

## Install it into an agent host

Adjust the destination directory name if your host wants the skill's own name.

### Claude Code

```sh
mkdir -p ~/.claude/skills
cp -R "$(pwd)/skills/ocoreai" ~/.claude/skills/
```

### Codex

```sh
mkdir -p ~/.codex/skills
cp -R "$(pwd)/skills/ocoreai" ~/.codex/skills/
```

### Anything else (a plain context file)

Point the harness at the absolute path, or paste `skills/ocoreai/SKILL.md` into its project instructions:

```sh
echo "Read and follow $(pwd)/skills/ocoreai/SKILL.md when working against a local ocoreai server."
```

### Gemini / extensions

`skills/ocoreai/SKILL.md` is plain Markdown with YAML front matter (`name`, `description`, `triggers`), so
it packages the same way other model-repo skills do — see `coreai-models/skills/gemini-extension.json` for
the shape this convention follows.
