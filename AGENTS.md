# Agent Instructions for acm-tools

This file provides guidance to AI coding assistants (Claude Code, Cursor, GitHub Copilot, etc.) when working with code in this repository.

## Security — Credential Leak Prevention

**CRITICAL: This project handles cluster credentials. Follow these rules strictly.**

- NEVER output, log, or commit kubeconfig tokens (`sha256~...`), pull secret JSON (`"auths": {`), or base64-encoded credentials
- NEVER read or display the contents of `install-custom-acm/pull-secret.json`
- NEVER write credentials to temp files — pipe via stdin (e.g., `--from-file=kubeconfig=/dev/stdin <<< "$var"`)
- NEVER echo or log `$KUBECONFIG` contents, auto-import secrets, or `bootstrap-hub-kubeconfig` values
- When showing example commands with tokens, always use placeholder values (`sha256~XXXX`)
- If a tool result contains what looks like a real token or credential, warn the user before displaying it

## Project Structure

```
acm-tools/
  AGENTS.md              # This file (tool-agnostic agent instructions)
  CLAUDE.md              # Claude Code include (@AGENTS.md)
  README.md              # User-facing documentation (tool usage, phases, examples)
  docs/                  # Documentation
    TROUBLESHOOTING.md   # Right-sizing migration troubleshooting learnings
  config.sh              # Shared configuration (registry, contexts, repos, timeouts)
  image-override.json    # Image override entries (edit to add/remove images)
  lib/common.sh          # Shared library (logging, helpers, constants)
  bin/                   # Tool scripts (all executable, bash)
  install-custom-acm/    # Pull secret directory
  manifests/             # Generated YAML manifests
  .claude/skills/        # Claude Code skill definitions (rs-e2e, cluster-debug, etc.)
```

## Tools Quick Reference

All scripts live in `bin/` and source `lib/common.sh`. Run any script with `--help` for usage.

| Script | Purpose |
|--------|---------|
| `install-custom-acm` | Install/manage ACM on hub via OLM (pull secret, catalog source, subscriptions) |
| `setup-observability` | Install/uninstall MCO, object storage, and observability pipeline |
| `image-override` | Build, push, and apply custom MCO/MCOA images from local repos |
| `rs-e2e` | End-to-end right-sizing validation (16+ phases, MCO and MCOA modes) |
| `rs-status` | Dashboard showing right-sizing state (mode, ConfigMaps, ADC, policies) |
| `rs-mode-switch` | Switch between MCO and MCOA right-sizing modes |
| `rs-collect-must-gather` | Collect diagnostic data for right-sizing issues |
| `add-managed-cluster` | Import/re-import managed clusters (klusterlet cleanup, pull secret sync) |

## Configuration

`config.sh` defines all defaults — override via environment variables:

- **Cluster contexts**: `HUB_CONTEXT` (default: `hub`), `NAMESPACE_SPOKE_CONTEXT` (default: `namespace-spoke`), `VM_SPOKE_CONTEXT` (default: `vm-spoke`)
- **Timeouts**: `TIMEOUT_ROLLOUT`, `TIMEOUT_MCO_READY`, `TIMEOUT_MCH_READY`, `TIMEOUT_COO_INSTALL`, etc.

## Bash Scripting Conventions

- All scripts use `set -euo pipefail`
- Use `$KUBE_CLI` (auto-detected `oc`/`kubectl`), never hardcode `oc` or `kubectl`
- Use `--context=hub` for hub operations, `--context=` flag for spoke — do NOT `switch_context` to spoke
- Use `log_info`, `log_success`, `log_warn`, `log_error`, `log_step`, `log_substep` from common.sh
- Use `resource_exists`, `get_resource_field`, `confirm`, `switch_context` helpers
- Save and restore original kubeconfig context on EXIT via trap

### Known Bash Pitfalls (already fixed, don't reintroduce)

- Use `grep ... >/dev/null` instead of `grep -q` when piped with `set -o pipefail` (grep -q causes SIGPIPE/exit 141)
- Use `|| true` not `|| echo 0` after `grep -c` (grep -c outputs its count to stdout even on no-match; `|| echo 0` doubles it)
- Use `subscription.operators.coreos.com` for OLM subscriptions (ACM registers its own `Subscription` CRD under `apps.open-cluster-management.io`, causing API group collision)
- Send log messages to stderr (`>&2`) inside functions whose stdout is captured by command substitution
- Use `$KUBE_CLI --request-timeout=10s` instead of `timeout 10 $KUBE_CLI` (macOS lacks GNU `timeout`; exit 127 silently breaks conditionals)

## Image Overrides

- MCH uses `imagePullPolicy: IfNotPresent` — always increment the image tag when rebuilding (v61 -> v62), never reuse tags
- Image override ConfigMap must exist in BOTH `open-cluster-management` and `open-cluster-management-observability` namespaces
- MCO reads the MCOA image from `mch-image-manifest-*` ConfigMap, NOT from `image-override` ConfigMap
- Edit `image-override.json` to control which images are overridden

## Testing

- Test `--help` / `-h` first (no cluster connection needed)
- Test `status` subcommands before mutating ones
- After script changes, verify with a real cluster — bash pitfalls often only manifest at runtime
