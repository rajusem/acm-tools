# Right-Sizing E2E Validation

Run end-to-end validation of right-sizing resource lifecycle on the current cluster using `bin/rs-e2e`.

## Arguments (optional)

- `--skip-uninstall` — Run phases 0-4a only, don't delete MCO at the end
- `--mode-switch` — Also test MCO-to-MCOA mode switching (adds phases 5-12, 15-16)
- `--build mco|mcoa|both` — Build, push, and apply custom image(s) before running tests
- `--image-override` — Apply existing `image-override.json` without building
- `--phases 0-3,5,9a` — Run specific phases (comma-separated, ranges OK)
- `--skip-perses-check` — Skip COO/Perses dashboard verification
- `--yes` — Auto-confirm destructive phases (13, 14, 15)
- `mco` or `mcoa` — Force testing a specific mode (default: auto-detect)

## Workflow

Run `bin/rs-e2e` with the appropriate flags. The script is fully automated and handles all phases.

### Map user request to flags

| User wants | Command |
|------------|---------|
| Quick validation | `bin/rs-e2e --skip-uninstall` |
| Core tests (phases 0-4a, 13-14) | `bin/rs-e2e` |
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
| 4a | ConfigMap coexistence (MCO+MCOA) | — |
| 5 | MCO → MCOA switch + Perses dashboards | `--mode-switch` |
| 6 | SpecHash freshness after ADC change | `--mode-switch` |
| 7 | ConfigMap predicate side-effect | `--mode-switch` |
| 8 | Placement filter (cluster selection) | `--mode-switch` |
| 9a-9d | Feature toggle MCOA + Perses dashboards | `--mode-switch` |
| 10 | ConfigMap propagation (MCOA) | `--mode-switch` |
| 11 | MCOA → MCO switch | `--mode-switch` |
| 12 | Version mismatch (any annotation value) | `--mode-switch` |
| 13 | Uninstall cleanup — MCO mode | Destructive (prompts) |
| 14 | Uninstall cleanup — MCOA mode + Perses | Destructive (prompts) |
| 15 | MCOA uninstall + reinstall | `--mode-switch`, destructive |
| 16 | Mode switch after reinstall + Perses | `--mode-switch` |

## Troubleshooting failures

If the script fails or a phase reports FAIL:

1. **Pre-flight (phase 0) failures**: The script auto-detects and fixes most stale state. If it can't fix it, check `bin/rs-status` output and the error message.

2. **Image override not taking effect**: MCH in Pending state won't reconcile image overrides. The script handles this by:
   - Patching `mch-image-manifest-*` ConfigMap for MCOA image (MCO reads MCOA image from this CM, not from `image-override`)
   - Patching MCO deployment directly if image doesn't match
   - Waiting 120s for MCO pod to run the expected image

3. **Phase 8 (placement filter)**: Uses `placementConfiguration` key (not `placementFilter`) with YAML content. OCM types use yaml.v2 lowercased field names (`requiredclusterselector`, `labelselector`, `matchlabels`). Validates filtering via ManifestWork PrometheusRule distribution, not PlacementDecisions.

4. **Phase 10 (ConfigMap propagation MCOA)**: ConfigMap data keys are YAML strings, not JSON. The script uses `jq gsub` on `.data.prometheusRuleConfig` to do string replacement.

5. **IsMCOTerminating stale state**: After MCO deletion, the operator caches a terminating flag in memory. The script detects this in phase 0 and restarts the operator pod.

6. **Phase 3 (spoke validation) failures**: Common causes:
   - Spoke cluster `Available: Unknown` — registration agent stopped updating lease. Fix with `bin/add-managed-cluster add <spoke> --force-import`.
   - Policy `rs-prom-rules-policy` shows `unknown` compliance — spoke is unreachable or `KlusterletAddonConfig` is missing (required for `config-policy-controller` addon).
   - Unreachable spoke contexts are skipped with an info message, not a hard failure.

7. **Phase 4a (ConfigMap coexistence) failures**: Tests that RS ConfigMaps survive when MCOA is deployed alongside MCO. Failure means MCOA is deleting ConfigMaps it shouldn't own. Check ADC `rightSizingDelegated` value — must be `"false"` in MCO mode.

8. **Stuck ManifestWorks blocking phases 5/14**: The script calls `cleanup_stuck_mcoa_mw()` at phase 5 entry and passes `--force-cleanup-mw` to `setup-observability install` in reinstall phases. If ManifestWorks are stuck in Deleting on `local-cluster`, the script handles it automatically.

9. **Stock ACM image limitations**: Stock ACM 2.16.0 image does NOT clean up RS resources on MCO deletion and does NOT support MCOA mode. Use custom images (via `--build` or `--image-override`) for full test coverage.

## Environment variables

Timeouts (set in `bin/rs-e2e` or `config.sh`):

- `TIMEOUT_E2E_RECONCILE` — Seconds to wait after MCO spec patches (default: 90)
- `TIMEOUT_E2E_MODE_SWITCH` — Seconds to wait after annotation changes (default: 60)
- `TIMEOUT_PERSES_DASHBOARD` — Seconds to wait for Perses dashboard convergence (default: 300)
- `TIMEOUT_COO_INSTALL` — Seconds to wait for COO installation before checking Perses (default: 120, in `config.sh`)
- `TIMEOUT_MW_STUCK` — Seconds before a deleting ManifestWork is considered stuck (default: 120, in `config.sh`)

Spoke cluster contexts (set in `config.sh`):

- `NAMESPACE_SPOKE_CONTEXT` — kubectl context for namespace spoke cluster (default: `namespace-spoke`)
- `VM_SPOKE_CONTEXT` — kubectl context for virtualization spoke cluster (default: `vm-spoke`)

## Debugging failed phases

When a phase fails, use the `PHASE_FAIL_REASON` in the output to guide diagnosis. Common patterns:

### Cluster/infrastructure issues

| Fail reason | Root cause | Diagnosis |
|-------------|-----------|-----------|
| `Cluster unreachable` | Kubeconfig context wrong or cluster down | `oc --context=hub cluster-info` |
| `ACM not installed` | No MCH on the cluster | `bin/install-custom-acm` |
| `MCO not Ready after Xs` | MCO stuck installing — check conditions | `oc get mco observability -o jsonpath='{.status.conditions}'` |
| `local-cluster not available` | Registration agent stale after hub change | `bin/add-managed-cluster add hub --force-import` |
| `No managed clusters found` | ManagedCluster resources missing | `oc get managedcluster` |
| `MCO image override not applied` | MCH in Pending state blocks reconciliation | Check `bin/image-override apply`, patch deployment directly |

### ConfigMap lifecycle issues

| Fail reason | Root cause | Diagnosis |
|-------------|-----------|-----------|
| `ConfigMap(s) not found (MCOA deletes MCO-created ConfigMaps)` | MCOA create-delete loop — delegation signal broken | Check ADC `rightSizingDelegated` value and MCOA logs |
| `Retained virt ConfigMap missing (MCOA create-delete loop)` | Same as above — ConfigMaps deleted between feature toggles | `oc get cm rs-namespace-config rs-virt-config -n open-cluster-management-observability` |
| `Baseline RS ConfigMaps missing` | MCO hasn't created ConfigMaps yet | Wait for MCO reconciliation or check MCO Ready status |

### Mode switch issues

| Fail reason | Root cause | Diagnosis |
|-------------|-----------|-----------|
| `Failed to switch to MCO/MCOA mode` | Annotation patch failed or MCO not reconciling | Check MCO CR annotation and operator logs |
| `ADC not synced to disabled after MCOA->MCO switch` | Analytics controller hasn't reconciled | Check MCO operator pod logs for `rs - syncing` |
| `Empty specHash values` | Addon framework hasn't computed specHash for MCA | Restart MCOA: `oc rollout restart deploy/multicluster-observability-addon-manager -n open-cluster-management-observability` |

### Policy/ManifestWork issues

| Fail reason | Root cause | Diagnosis |
|-------------|-----------|-----------|
| `Policy already exists` | Stale Policy from previous test run | Delete Policy manually in `open-cluster-management-global-set` |
| `ConfigMap change not propagated to Policy` | MCO didn't regenerate Policy after ConfigMap update | Check MCO operator logs, restart if needed |
| `ConfigMap change not propagated to ManifestWork` | MCOA didn't regenerate ManifestWork | Check MCOA logs and MCA specHash |
| `MCOA leaked RS resources in MCO mode` | Phase 4a — MCOA created RS resources when `rightSizingDelegated=false` | Code bug — delegation guard not working |

### General diagnosis commands

```bash
# Check rs-status for full dashboard
bin/rs-status

# Check MCO operator logs
oc logs deploy/multicluster-observability-operator -n open-cluster-management --tail=50

# Check MCOA logs
oc logs deploy/multicluster-observability-addon-manager -n open-cluster-management-observability --tail=50

# Check ADC state
oc get addondeploymentconfig multicluster-observability-addon \
  -n open-cluster-management-observability \
  -o jsonpath='{.spec.customizedVariables}' | python3 -m json.tool

# Check ManifestWorks for a cluster
oc get manifestwork -n local-cluster --no-headers
```

## Important notes

- `--build` requires `podman`/`docker` and registry access. Always builds with `--platform linux/amd64` and `--no-cache`.
- Destructive phases (13, 14, 15) prompt for confirmation unless `--yes` is passed.
- If any phase fails, the script continues with remaining phases and reports all results in the summary.
- The script saves and restores kubeconfig context on exit.
