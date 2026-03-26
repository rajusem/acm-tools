# Claude Code Instructions for acm-tools

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
  CLAUDE.md              # This file
  config.sh              # Shared configuration (contexts, container engine)
  image-override.json    # Image override entries (edit to add/remove images)
  lib/common.sh          # Shared library (logging, helpers, constants)
  bin/                   # Tool scripts (all executable, bash)
  install-custom-acm/    # Pull secret directory
  manifests/             # Generated YAML manifests
```

All scripts in `bin/` source `lib/common.sh`. Read it to understand available helpers before modifying any script.

## Bash Scripting Conventions

- All scripts use `set -euo pipefail`
- Use `$KUBE_CLI` (auto-detected `oc`/`kubectl`), never hardcode `oc` or `kubectl`
- Use `--context=` flag for spoke cluster operations — do NOT `switch_context` to spoke
- Use `log_info`, `log_success`, `log_warn`, `log_error`, `log_step`, `log_substep` from common.sh
- Use `resource_exists`, `get_resource_field`, `confirm`, `switch_context` helpers
- Save and restore original kubeconfig context on EXIT via trap

### Known Bash Pitfalls (already fixed, don't reintroduce)

- Use `grep ... >/dev/null` instead of `grep -q` when piped with `set -o pipefail` (grep -q causes SIGPIPE/exit 141)
- Use `|| true` not `|| echo 0` after `grep -c` (grep -c outputs its count to stdout even on no-match; `|| echo 0` doubles it)
- Use `subscription.operators.coreos.com` for OLM subscriptions (ACM registers its own `Subscription` CRD under `apps.open-cluster-management.io`, causing API group collision)
- Send log messages to stderr (`>&2`) inside functions whose stdout is captured by command substitution

## Image Overrides

- MCH uses `imagePullPolicy: IfNotPresent` — always increment the image tag when rebuilding (v61 -> v62), never reuse tags
- Image override ConfigMap must exist in BOTH `open-cluster-management` and `open-cluster-management-observability` namespaces
- Edit `image-override.json` to control which images are overridden

## Testing

- Test `--help` / `-h` first (no cluster connection needed)
- Test `status` subcommands before mutating ones
- After script changes, verify with a real cluster — bash pitfalls often only manifest at runtime
