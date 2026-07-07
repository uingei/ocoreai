# Git Hooks

Pre-commit and pre-push hooks for ocoreai.

## Installation (Opt-In)

```bash
# Set hooks path to include these hooks
git config core.hooksPath .github/hooks
```

Or copy individual hooks:
```bash
cp .github/hooks/pre-commit .git/hooks/pre-commit
cp .github/hooks/pre-push .git/hooks/pre-push
```

## Hooks

| Hook | What it does | Skip |
|---|---|---|
| `pre-commit` | Secret scan via gitleaks | `git commit --no-verify` |
| `pre-push` | Build + test gate | `git push --no-verify` |

## Requirements

- `gitleaks` — `brew install gitleaks` (macOS)
- `swift` — Xcode command line tools
