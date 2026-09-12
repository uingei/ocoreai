# Security Policy

## Reporting a vulnerability

Please report vulnerabilities through [GitHub private vulnerability
reporting](https://github.com/uingei/ocoreai/security/advisories/new), rather
than public issues or pull requests.

Include the affected version or commit, relevant configuration, a
reproducible example (including the exact `OCOREAI_HOST` / `OCOREAI_PORT`
bindings used), the model involved, and the demonstrated impact.
Clearly state the access an attacker needs and any required operator
actions. Scanner output alone is not sufficient.

## Supported versions

Security fixes target the latest release and `main`. Older releases may
require an upgrade.

## Scope and trust assumptions

oCoreAI is a single-operator local inference server for the Apple-native
coding agent. It is not a multi-tenant, untrusted-input service.

- The local user (the process owner) is trusted. Isolation from hostile
  local accounts or an already-compromised host is outside the threat
  model.
- **In scope:** authentication bypass of ``OCOREAI_API_KEYS`` /
  ``OCOREAI_ADMIN_KEYS`` (including the non-loopback bind gate in
  ``ServerAuthGate``), unauthorized access to model weights, KV cache,
  prompt/history, or tool results, and unintended code execution on the
  host process. The admin/UI surface and OpenAI-compatible API routes
  are in scope.
- **Out of scope (by design):** rate-limit tuning on a single-operator
  LAN, and any model-behaviour issue (bad output, tool misuse,
  hallucination) — these are product-quality issues, not
  vulnerabilities, unless they enable one of the in-scope bypasses.
- **Out of scope:** the upstream MLX / CoreAI SDK surfaces it consumes.
  Report those to their own channels.

## Network binding rules

oCoreAI refuses to bind a non-loopback address without `OCOREAI_API_KEYS`
set (``ServerAuthGate``; mirrors omlx `09a7c43`). Any report that
depends on bypassing that gate is in scope; reports that assume a user
intentionally exposes an unauthenticated LAN endpoint are not.

## Disclosure

Reports on `main` are reviewed on a best-effort basis. Please coordinate
disclosure through the private report to allow time for a fix or
mitigation. Confirmed vulnerability reports are credited in the relevant
fix or advisory unless the reporter prefers to remain anonymous.
No paid bug bounty.
