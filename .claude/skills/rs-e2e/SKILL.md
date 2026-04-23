# Right-Sizing E2E Validation

Run end-to-end validation of right-sizing resource lifecycle on the current cluster using `bin/rs-e2e`.

## Arguments (optional)

- `--skip-uninstall` — Run phases 0-3 only, don't delete MCO at the end
- `--mode-switch` — Also test MCO-to-MCOA mode switching (adds phases 5-12, 15-16)
- `--build mco|mcoa|both` — Build, push, and apply custom image(s) before running tests
- `--image-override` — Apply existing `image-override.json` without building
- `--phases 0-3,5,9a` — Run specific phases (comma-separated, ranges OK)
- `--yes` — Auto-confirm destructive phases (13, 14, 15)
- `mco` or `mcoa` — Force testing a specific mode (default: auto-detect)

## Workflow

Run `bin/rs-e2e` with the appropriate flags. The script is fully automated and handles all phases.

### Map user request to flags

| User wants | Command |
|------------|---------|
| Quick validation | `bin/rs-e2e --skip-uninstall` |
| Core tests (phases 0-4, 13-14) | `bin/rs-e2e` |
| Full run with mode switching | `bin/rs-e2e --mode-switch` |
| Full run, no prompts | `bin/rs-e2e --mode-switch --yes` |
| Build MCO image then test | `bin/rs-e2e --build mco` |
| Build both images then test | `bin/rs-e2e --build both --mode-switch` |
| Deploy existing override then test | `bin/rs-e2e --image-override` |
| Specific phases | `bin/rs-e2e --phases 0-3,5,9a` |
| Force MCOA mode | `bin/rs-e2e mcoa` |

### Execution

Run the script and stream its output to the user:

```bash
bin/rs-e2e [flags]
```

The script prints phase-by-phase results with PASS/FAIL status and a summary table at the end.

### Phases reference

| Phase | Test | Requires |
|-------|------|----------|
| 0 | Pre-flight (cluster state detection) | — |
| 1 | Baseline resource verification | — |
| 2a-2d | Feature toggle MCO (disable/swap/both/re-enable) | — |
| 3 | Spoke PrometheusRule validation | — |
| 4 | ConfigMap propagation (MCO) | — |
| 5 | MCO → MCOA switch | `--mode-switch` |
| 6 | SpecHash freshness after ADC change | `--mode-switch` |
| 7 | ConfigMap predicate side-effect | `--mode-switch` |
| 8 | Placement filter (cluster selection) | `--mode-switch` |
| 9a-9d | Feature toggle MCOA (disable/swap/both/re-enable) | `--mode-switch` |
| 10 | ConfigMap propagation (MCOA) | `--mode-switch` |
| 11 | MCOA → MCO switch | `--mode-switch` |
| 12 | Version mismatch (any annotation value) | `--mode-switch` |
| 13 | Uninstall cleanup — MCO mode | Destructive (prompts) |
| 14 | Uninstall cleanup — MCOA mode | Destructive (prompts) |
| 15 | MCOA uninstall + reinstall | `--mode-switch`, destructive |
| 16 | Mode switch after reinstall | `--mode-switch` |

## Troubleshooting failures

If the script fails or a phase reports FAIL:

1. **Pre-flight (phase 0) failures**: The script auto-detects and fixes most stale state. If it can't fix it, check `bin/rs-status` output and the error message.

2. **Image override not taking effect**: MCH in Pending state won't reconcile image overrides. The script handles this by:
   - Patching `mch-image-manifest-*` ConfigMap for MCOA image (MCO reads MCOA image from this CM, not from `image-override`)
   - Patching MCO deployment directly if image doesn't match
   - Waiting 120s for MCO pod to run the expected image

3. **Phase 9 (placement filter)**: Uses `placementConfiguration` key (not `placementFilter`) with YAML content. OCM types use yaml.v2 lowercased field names (`requiredclusterselector`, `labelselector`, `matchlabels`).

4. **Phase 11 (ConfigMap propagation)**: ConfigMap data keys are YAML strings, not JSON. The script uses `jq gsub` on `.data.prometheusRuleConfig` to do string replacement.

5. **IsMCOTerminating stale state**: After MCO deletion, the operator caches a terminating flag in memory. The script detects this in phase 0 and restarts the operator pod.

6. **Stock ACM image limitations**: Stock ACM 2.16.0 image does NOT clean up RS resources on MCO deletion and does NOT support MCOA mode. Use custom images (via `--build` or `--image-override`) for full test coverage.

## Environment variables

- `TIMEOUT_E2E_RECONCILE` — Seconds to wait after MCO spec patches (default: 90)
- `TIMEOUT_E2E_MODE_SWITCH` — Seconds to wait after annotation changes (default: 60)

## Important notes

- `--build` requires `podman`/`docker` and registry access. Always builds with `--platform linux/amd64` and `--no-cache`.
- Destructive phases (4a, 4b, 12a) prompt for confirmation unless `--yes` is passed.
- If any phase fails, the script continues with remaining phases and reports all results in the summary.
- The script saves and restores kubeconfig context on exit.
