# Right-Sizing E2E Validation

Run end-to-end validation of right-sizing resource lifecycle on the current cluster.
Handles all cluster states: fresh cluster, ACM not installed, observability not installed, etc.

## Arguments (optional)

- `--skip-uninstall` — Run phases 0-3 only, don't delete MCO at the end
- `--mode-switch` — Also test MCO-to-MCOA mode switching (adds Phase 5)
- `--build mco|mcoa|both` — Build, push, and apply custom image(s) before running tests. Auto-increments tag from `image-override.json`. Runs before Phase 0.
- `--image-override` — Apply existing `image-override.json` without building. Use when images are already pushed and you just want to deploy them.
- `mco` or `mcoa` — Force testing a specific mode (default: auto-detect)

## Workflow

### Pre-phase: Custom image build & deploy (only if `--build` or `--image-override`)

Skip this entirely if neither `--build` nor `--image-override` is passed.

**If `--build mco|mcoa|both`:**

1. Read `image-override.json` to find current tags
2. Auto-increment the tag for the requested image(s) (e.g., v66 -> v67). Never reuse tags (MCH uses `imagePullPolicy: IfNotPresent`).
3. Read repo paths and build settings from `config.sh`:
   - `MCO_REPO_DIR` — MCO source repo (default: `../multicluster-observability-operator` relative to acm-tools)
   - `MCOA_REPO_DIR` — MCOA source repo (default: `../multicluster-observability-addon` relative to acm-tools)
   - `MCO_DOCKERFILE` — MCO Dockerfile path within repo (default: `operators/multiclusterobservability/Dockerfile.local`)
   - `MCOA_DOCKERFILE` — MCOA Dockerfile path within repo (default: `Dockerfile`)
   - `CONTAINER_ENGINE` — podman or docker (auto-detected)
   - `BUILD_PLATFORM` — target platform (default: `linux/amd64`)
   - `ACM_TOOLS_REGISTRY` — image registry (default: `quay.io/rzalavad`)
4. Verify repo directories exist before building. If not found, STOP and tell the user to set `MCO_REPO_DIR` / `MCOA_REPO_DIR` in `config.sh` or via environment variables.
5. Build with `$CONTAINER_ENGINE build --platform $BUILD_PLATFORM --no-cache`:
   - **MCO**: `$CONTAINER_ENGINE build --platform $BUILD_PLATFORM --no-cache -t $ACM_TOOLS_REGISTRY/$MCO_IMAGE_NAME:<tag> -f $MCO_DOCKERFILE $MCO_REPO_DIR`
   - **MCOA**: `$CONTAINER_ENGINE build --platform $BUILD_PLATFORM --no-cache -t $ACM_TOOLS_REGISTRY/$MCOA_IMAGE_NAME:<tag> -f $MCOA_DOCKERFILE $MCOA_REPO_DIR`
6. Push to registry (`$ACM_TOOLS_REGISTRY`)
7. Update `image-override.json` with the new tag(s)
8. Run `bin/image-override apply`
9. Verify pod(s) running new image:
   ```bash
   # MCO operator
   oc --context=hub get pod -n open-cluster-management -l name=multicluster-observability-operator -o jsonpath='{.items[0].spec.containers[0].image}'
   # MCOA addon (deployed by MCO — may need MCO to reconcile first)
   oc --context=hub get pod -n open-cluster-management-observability -l app=multicluster-observability-addon-manager -o jsonpath='{.items[0].spec.containers[0].image}'
   ```

**If `--image-override` (no build):**

1. Run `bin/image-override apply` using the current `image-override.json`
2. Verify pod(s) running the expected image(s) from `image-override.json`

After image deployment is verified, continue to Phase 0.

### Phase 0: Pre-flight — Detect cluster state

Run these checks and determine the entry state:

```bash
# 1. Can we reach the cluster?
oc --context=hub cluster-info 2>&1 | head -1

# 2. Is ACM installed?
oc --context=hub get mch -A --no-headers

# 3. Is MCO installed?
oc --context=hub get mco observability --no-headers

# 4. Is MCO Ready?
oc --context=hub get mco observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# 5. Are there managed clusters?
oc --context=hub get managedcluster --no-headers

# 6. Are there orphaned RS resources from a previous run?
oc --context=hub get placement rs-placement rs-virt-placement -n open-cluster-management-global-set --no-headers 2>&1
oc --context=hub get configmap rs-namespace-config rs-virt-config -n open-cluster-management-observability --no-headers 2>&1
oc --context=hub get policy rs-prom-rules-policy rs-virt-prom-rules-policy -n open-cluster-management-global-set --no-headers 2>&1

# 7. What images are running?
oc --context=hub get pod -n open-cluster-management -l name=multicluster-observability-operator -o jsonpath='{.items[0].spec.containers[0].image}' 2>&1

# 8. Does IsMCOTerminating flag have stale state from a previous MCO deletion?
# (plain bool in operator memory — persists until operator pod restarts)
oc --context=hub logs deploy/multicluster-observability-operator -n open-cluster-management --tail=20 2>&1 | grep "MCO is terminating, skip reconcile"
```

Based on the results, follow the appropriate path:

| State | Action |
|-------|--------|
| Cluster unreachable | STOP — report error |
| ACM not installed | STOP — tell user to run `bin/install-custom-acm` or install ACM |
| ACM installed, MCO not installed, no orphans | Install MCO via `bin/setup-observability install`, then continue |
| ACM installed, MCO not installed, orphans exist | Report orphans. Install MCO via `bin/setup-observability install` — the MCO analytics controller will handle stale resources on next reconcile. |
| MCO installed but not Ready | Wait up to 120s for Ready, if still not Ready → STOP with diagnostic info |
| MCO installed, `IsMCOTerminating` stale logs found | Restart operator: `oc --context=hub rollout restart deploy/multicluster-observability-operator -n open-cluster-management`, wait for rollout, then re-check |
| MCO Ready, RS not in spec (fresh install) | The analytics controller auto-patches MCO CR to set `enabled: true` for both RS features on first reconcile (`ensureRightSizingDefaults`). Wait 30s and verify spec was populated. If not, patch explicitly. |
| MCO Ready, RS resources exist | Continue to Phase 1 |

Report the detected state clearly before proceeding.

### Phase 1: Baseline — Detect mode and verify resources

**Detect RS mode:**

```bash
# Note: jsonpath dots in annotation key must be escaped
oc --context=hub get mco observability -o jsonpath='{.metadata.annotations.observability\.open-cluster-management\.io/right-sizing-capable}'
```

- Annotation = `v1` → MCOA mode
- Empty/missing → MCO mode (default)

**Check RS feature state in MCO CR:**

```bash
oc --context=hub get mco observability -o jsonpath='{.spec.capabilities.platform.analytics}'
```

The analytics controller auto-patches `enabled: true` for both RS features when the fields are absent in the MCO spec (OBSINTA-848). This happens on first reconcile after MCO becomes Ready (~30s).

**Ensure both features are enabled** (needed as baseline for tests):

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 30s for controllers to reconcile.

**Run `bin/rs-status`** to show full dashboard.

**Verify all expected RS resources exist:**

Both modes — hub resources:
- Placement `rs-placement` in `open-cluster-management-global-set`
- Placement `rs-virt-placement` in `open-cluster-management-global-set`
- ConfigMap `rs-namespace-config` in `open-cluster-management-observability`
- ConfigMap `rs-virt-config` in `open-cluster-management-observability`

MCO mode additionally (Policy-based resources in `open-cluster-management-global-set`):
- Policy `rs-prom-rules-policy`
- Policy `rs-virt-prom-rules-policy`
- PlacementBinding `rs-policyset-binding`
- PlacementBinding `rs-virt-policyset-binding`

MCOA mode additionally:
- ManifestWork containing PrometheusRules in each managed cluster namespace (check via `bin/rs-status`)

NOTE: In MCOA mode there are NO Policies or PlacementBindings — those are MCO-mode only. Placements and ConfigMaps exist in both modes.

**Result:** PASS if all expected resources exist, FAIL with details of what's missing.

### Phase 2: Test partial feature disable

**Test 2a — Disable namespace RS only:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 30s. Verify:
- DELETED: `rs-placement` (Placement in global-set), `rs-namespace-config` (ConfigMap in obs ns)
- MCO mode also DELETED: `rs-prom-rules-policy` (Policy), `rs-policyset-binding` (PlacementBinding)
- RETAINED: all `rs-virt-*` resources (Placement, ConfigMap, and in MCO mode: Policy, PlacementBinding)

**Test 2b — Re-enable namespace RS:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 30s. Verify all RS resources from Phase 1 exist again.

**Test 2c — Disable virtualization RS only:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 30s. Verify:
- DELETED: `rs-virt-placement` (Placement in global-set), `rs-virt-config` (ConfigMap in obs ns)
- MCO mode also DELETED: `rs-virt-prom-rules-policy` (Policy), `rs-virt-policyset-binding` (PlacementBinding)
- RETAINED: all namespace RS resources (`rs-placement`, `rs-namespace-config`, and in MCO mode: `rs-prom-rules-policy`, `rs-policyset-binding`)

**Test 2d — Re-enable virtualization RS:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 30s. Verify all RS resources exist again.

**Test 2e — Disable BOTH features:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":false},"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 30s. Verify ALL RS resources are deleted (Placements, ConfigMaps, and in MCO mode: Policies, PlacementBindings).

**Test 2f — Re-enable both:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 30s. Verify all RS resources exist again.

**Result:** PASS/FAIL for each sub-test.

### Phase 3: Spoke validation

Check that PrometheusRules are actually deployed on spoke clusters.

**MCO mode** — Check via PlacementDecisions (which clusters are selected by the Placement):

```bash
oc --context=hub get placementdecision -n open-cluster-management-global-set \
  -l cluster.open-cluster-management.io/placement=rs-placement \
  -o jsonpath='{.items[*].status.decisions[*].clusterName}'
```

Then check Policy compliance status:
```bash
oc --context=hub get policy rs-prom-rules-policy -n open-cluster-management-global-set -o jsonpath='{.status}'
```

**MCOA mode** — Check ManifestWorks on hub (no spoke access needed):

```bash
# For each managed cluster, check for PrometheusRule in ManifestWork
oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}'
# Then for each cluster:
oc --context=hub get manifestwork -n <cluster-name> -o json 2>/dev/null | \
  jq '[.items[].spec.workload.manifests[] | select(.kind=="PrometheusRule") | select(.metadata.name | test("acm-rs"))] | length'
```

**Direct spoke check** (optional, if spoke context is reachable):

```bash
oc --context=namespace-spoke get prometheusrule -n openshift-monitoring --no-headers 2>/dev/null | grep -i "rs-\|acm-rs"
```

Report unreachable spokes as SKIP, not FAIL.

**Result:** PASS if at least one spoke has RS PrometheusRules deployed. SKIP if no spoke context is reachable (hub-only check via ManifestWork/Policy status is still valid).

### Phase 4: Uninstall cleanup test

ASK USER FOR CONFIRMATION before this step — it deletes the MCO CR.

If user passed `--skip-uninstall`, skip this phase entirely and go to summary.

```bash
echo "y" | bin/setup-observability uninstall
```

The `setup-observability uninstall` script calls `verify_rs_cleanup` internally (polls for 60s).

After uninstall, independently verify no RS resources remain:

```bash
# Placements (both modes)
oc --context=hub get placement rs-placement rs-virt-placement -n open-cluster-management-global-set 2>&1

# ConfigMaps (both modes)
oc --context=hub get configmap rs-namespace-config rs-virt-config -n open-cluster-management-observability 2>&1

# MCO mode also: Policies and PlacementBindings
oc --context=hub get policy rs-prom-rules-policy rs-virt-prom-rules-policy -n open-cluster-management-global-set 2>&1
oc --context=hub get placementbinding rs-policyset-binding rs-virt-policyset-binding -n open-cluster-management-global-set 2>&1
```

**Result:** PASS if all RS resources are gone, FAIL with details of which resources remain.

### Phase 5: Mode switch test (only if `--mode-switch` requested)

ASK USER FOR CONFIRMATION before this step.

If MCO is not installed (Phase 4 ran), reinstall:
```bash
bin/setup-observability install
```

Wait for MCO Ready. Verify RS resources exist in MCO mode first.

**Test 5a — Switch MCO -> MCOA:**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable=v1
```

Wait 60s (mode switch involves CMA creation, MCOA pod startup, ManifestWork generation). Verify:
- MCO Policy resources DELETED: `rs-prom-rules-policy`, `rs-virt-prom-rules-policy`, `rs-policyset-binding`, `rs-virt-policyset-binding`
- Placements RETAINED: `rs-placement`, `rs-virt-placement` (now managed by MCOA ResourceCreator)
- ConfigMaps RETAINED: `rs-namespace-config`, `rs-virt-config` (now managed by MCOA)
- MCOA pod running in `open-cluster-management-observability`
- ManifestWorks with PrometheusRules created in managed cluster namespaces

**Test 5b — Switch MCOA -> MCO:**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable-
```

Wait 60s. Verify:
- MCO Policy resources RECREATED: `rs-prom-rules-policy`, `rs-virt-prom-rules-policy`, `rs-policyset-binding`, `rs-virt-policyset-binding`
- Placements still exist (now managed by MCO analytics controller)
- CMA deleted, triggering addon framework cascade: CMA -> MCA -> ManifestWork -> spoke PrometheusRules removed
- ManifestWorks for RS PrometheusRules removed from spoke namespaces

**Result:** PASS/FAIL for each sub-test.

### Phase 6: Summary

Print a results table:

```
============================================================
Right-Sizing E2E Results
============================================================
Cluster:          <cluster API URL>
Mode:             <MCO|MCOA>
Images:           <image tag or registry>
Managed Clusters: <count> (<names>)
ACM Version:      <version from CSV>

Test                              Result    Notes
----                              ------    -----
0. Pre-flight                     PASS      <state detected>
1. Baseline resources exist       PASS/FAIL <missing resources>
2a. Disable namespace RS          PASS/FAIL <unexpected resources>
2b. Re-enable namespace RS        PASS/FAIL
2c. Disable virtualization RS     PASS/FAIL
2d. Re-enable virtualization RS   PASS/FAIL
2e. Disable both features         PASS/FAIL
2f. Re-enable both features       PASS/FAIL
3. Spoke PrometheusRules          PASS/FAIL/SKIP
4. Uninstall cleanup              PASS/FAIL/SKIP
5a. MCO -> MCOA switch            PASS/FAIL/SKIP
5b. MCOA -> MCO switch            PASS/FAIL/SKIP
============================================================
```

After the summary:
- If Phase 4 ran (uninstall), remind user: `bin/setup-observability install` to reinstall
- If any test FAILED, highlight which resources were unexpected (present when should be absent, or absent when should be present)

## Important notes

- `--build` requires `podman` (or `docker`) and network access to push to `quay.io`. Always use `--platform linux/amd64` and `--no-cache` (MCOA caches arm64 layers otherwise).
- `--image-override` requires MCO to be installed (the image-override ConfigMap needs the observability namespace to exist). If MCO is not installed, Phase 0 will install it first, then apply the override.
- Always use `--context=hub` for hub cluster commands
- Always use `--context=namespace-spoke` or `--context=vm-spoke` for spoke commands — NEVER switch kubeconfig context
- Wait at least 30 seconds after MCO spec patches for controllers to reconcile
- Wait at least 60 seconds after mode switch (annotation change) for full reconciliation (CMA creation, MCOA startup, ManifestWork generation)
- Phase 4 (uninstall) and Phase 5 (mode switch) are destructive — always ask user confirmation
- If any step fails, report the failure clearly but continue with remaining steps
- Use `bin/rs-status` for quick visual checks between steps
- The `IsMCOTerminating` flag persists in operator memory after MCO deletion. If the operator wasn't restarted between MCO delete and recreate, the analytics controller will skip all reconciles. Detect this in Phase 0 and restart the operator.
- MCO mode partial disable cleanup (Phase 2) is handled by the upstream `HandleComponentRightSizing` function. Full MCO deletion cleanup (Phase 4) is handled by the `CleanupRightSizingResources` function in the MCO finalizer.
