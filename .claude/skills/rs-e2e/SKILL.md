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

# 9. Is local-cluster Available? (stale bootstrap-hub-kubeconfig blocks ManifestWork delivery)
oc --context=hub get managedcluster local-cluster -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>&1

# If Available=Unknown, check bootstrap-hub-kubeconfig target
oc --context=hub get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"
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
| local-cluster `Available: Unknown`, bootstrap-hub-kubeconfig points to wrong hub | Re-apply import manifests: `oc get secret local-cluster-import -n local-cluster -o jsonpath='{.data.crds\.yaml}' \| base64 -d \| oc apply -f -` then `oc get secret local-cluster-import -n local-cluster -o jsonpath='{.data.import\.yaml}' \| base64 -d \| oc apply -f -`, delete `hub-kubeconfig-secret`, restart all pods in `open-cluster-management-agent`. Wait 60s for `Available: True`. |
| MCO Ready, RS not in spec (fresh install) | The analytics controller auto-patches MCO CR to set `enabled: true` for both RS features on first reconcile (`ensureRightSizingDefaults`). Wait 90s and verify spec was populated. If not, patch explicitly. |
| MCO Ready, RS resources exist | Continue to Phase 1 |

Report the detected state clearly before proceeding.

### Phase 1: Baseline — Detect mode and verify resources

**Detect RS mode:**

```bash
# Note: jsonpath dots in annotation key must be escaped
oc --context=hub get mco observability -o jsonpath='{.metadata.annotations.observability\.open-cluster-management\.io/right-sizing-capable}'
```

- Annotation present → MCOA mode (convention: set value to `"true"`)
- Annotation absent → MCO mode (default)

**Check RS feature state in MCO CR:**

```bash
oc --context=hub get mco observability -o jsonpath='{.spec.capabilities.platform.analytics}'
```

The analytics controller auto-patches `enabled: true` for both RS features when the fields are absent in the MCO spec (OBSINTA-848). This happens on first reconcile after MCO becomes Ready (~30s).

**Ensure both features are enabled** (needed as baseline for tests):

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 90s for controllers to reconcile.

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

### Phase 2: Test feature toggle (in current mode)

Run these tests in whichever mode is currently active (MCO or MCOA).

**Test 2a — Disable namespace RS only:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 90s. Verify:
- DELETED: `rs-placement` (Placement in global-set), `rs-namespace-config` (ConfigMap in obs ns)
- MCO mode also DELETED: `rs-prom-rules-policy` (Policy), `rs-policyset-binding` (PlacementBinding)
- RETAINED: all `rs-virt-*` resources (Placement, ConfigMap, and in MCO mode: Policy, PlacementBinding)
- ADC: `platformNamespaceRightSizing=disabled`, `platformVirtualizationRightSizing=enabled`

**Test 2b — Swap features (re-enable ns + disable virt in one patch):**

Tests both resource re-creation AND single-feature deletion in one step.

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 90s. Verify:
- RESTORED: `rs-placement`, `rs-namespace-config` (and in MCO mode: `rs-prom-rules-policy`, `rs-policyset-binding`)
- DELETED: `rs-virt-placement`, `rs-virt-config` (and in MCO mode: `rs-virt-prom-rules-policy`, `rs-virt-policyset-binding`)
- ADC: `platformNamespaceRightSizing=enabled`, `platformVirtualizationRightSizing=disabled`

**Test 2c — Disable BOTH features:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":false},"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 90s. Verify ALL RS resources are deleted (Placements, ConfigMaps, and in MCO mode: Policies, PlacementBindings). In MCOA mode, also verify ManifestWorks contain NO RS PrometheusRules (addon framework prunes stale content when the rendering pipeline produces manifests without PrometheusRules).
- ADC: both RS values = `disabled`

**Test 2d — Re-enable both:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 90s. Verify all RS resources from Phase 1 exist again.

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

If Policy shows non-compliant on a spoke, check that the spoke has `KlusterletAddonConfig` with `policyController: true` — without it, `config-policy-controller` and `governance-policy-framework` addons are not installed and Policy enforcement doesn't work:
```bash
oc --context=hub get klusterletaddonconfig -n <spoke-name> -o jsonpath='{.spec.policyController.enabled}'
oc --context=hub get managedclusteraddon -n <spoke-name> --no-headers | grep -E "config-policy|governance"
```
If missing, `bin/add-managed-cluster add` creates it automatically. Report missing KlusterletAddonConfig as a diagnostic note, not a test FAIL.

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

#### Test 4a — Delete MCO in MCO mode (Policy-based)

The cluster should already be in MCO mode from Phases 1-3.

```bash
echo "y" | bin/setup-observability uninstall
```

The `setup-observability uninstall` script calls `verify_rs_cleanup` internally (polls for 60s).

After uninstall, independently verify no RS resources remain:

```bash
# Placements
oc --context=hub get placement rs-placement rs-virt-placement -n open-cluster-management-global-set 2>&1

# ConfigMaps
oc --context=hub get configmap rs-namespace-config rs-virt-config -n open-cluster-management-observability 2>&1

# Policies and PlacementBindings (MCO mode)
oc --context=hub get policy rs-prom-rules-policy rs-virt-prom-rules-policy -n open-cluster-management-global-set 2>&1
oc --context=hub get placementbinding rs-policyset-binding rs-virt-policyset-binding -n open-cluster-management-global-set 2>&1
```

**Result:** PASS if all RS resources are gone, FAIL with details of which resources remain.

#### Test 4b — Delete MCO in MCOA mode (ManifestWork-based)

Reinstall MCO, switch to MCOA mode, verify MCOA resources exist, then delete MCO.

```bash
# Reinstall MCO
bin/setup-observability install
```

Wait for MCO Ready. Ensure both RS features are enabled, then switch to MCOA mode:

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable=true --overwrite
```

Wait 60s. Verify MCOA mode is active before deleting:
- MCOA pod running
- specHash populated on all managed clusters
- ManifestWorks with PrometheusRules exist
- Placements and ConfigMaps exist

Then delete MCO:

```bash
echo "y" | bin/setup-observability uninstall
```

After uninstall, verify ALL MCOA-mode RS resources are cleaned up:

```bash
# Placements
oc --context=hub get placement rs-placement rs-virt-placement -n open-cluster-management-global-set 2>&1

# ConfigMaps
oc --context=hub get configmap rs-namespace-config rs-virt-config -n open-cluster-management-observability 2>&1

# CMA (ClusterManagementAddOn) — should be deleted
oc --context=hub get clustermanagementaddon multicluster-observability-addon 2>&1

# MCA (ManagedClusterAddon) — should be deleted on all clusters
for mc in $(oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc --context=hub get managedclusteraddon multicluster-observability-addon -n "$mc" 2>&1
done

# ManifestWorks with RS PrometheusRules — should be 0 on all clusters
for mc in $(oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  count=$(oc --context=hub get manifestwork -n "$mc" -o json 2>/dev/null | \
    jq '[.items[]?.spec.workload.manifests[]? | select(.kind=="PrometheusRule") | select(.metadata.name | test("acm-rs"))] | length' 2>/dev/null || echo 0)
  echo "$mc: $count RS PrometheusRules in ManifestWork"
done
```

**Result:** PASS if all RS resources are gone (Placements, ConfigMaps, CMA, MCA, ManifestWorks), FAIL with details of which resources remain.

### Phase 5: Mode switch test (only if `--mode-switch` requested)

ASK USER FOR CONFIRMATION before this step.

If MCO is not installed (Phase 4 ran), reinstall:
```bash
bin/setup-observability install
```

Wait for MCO Ready. Verify RS resources exist in MCO mode first.

**Test 5a — Switch MCO -> MCOA:**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable=true
```

Wait 60s (mode switch involves CMA creation, MCOA pod startup, ManifestWork generation). Verify:
- MCO Policy resources DELETED: `rs-prom-rules-policy`, `rs-virt-prom-rules-policy`, `rs-policyset-binding`, `rs-virt-policyset-binding`
- Placements RETAINED: `rs-placement`, `rs-virt-placement` (now managed by MCOA ResourceCreator)
- ConfigMaps RETAINED: `rs-namespace-config`, `rs-virt-config` (now managed by MCOA)
- MCOA pod running in `open-cluster-management-observability`
- MCA `desiredConfig.specHash` populated (non-empty) on all managed clusters — empty specHash means MCOA addon framework will NOT create ManifestWorks (false PASS scenario)
  ```bash
  # Check specHash for each managed cluster
  for mc in $(oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}'); do
    oc --context=hub get managedclusteraddon multicluster-observability-addon -n "$mc" \
      -o jsonpath='{.status.configReferences[0].desiredConfig.specHash}'
    echo " ($mc)"
  done
  ```
- ManifestWorks with PrometheusRules created in managed cluster namespaces (will be 0 if specHash is empty)
- ADC CustomizedVariables reflect enabled state for both RS features:
  ```bash
  oc --context=hub get addondeploymentconfig multicluster-observability-addon \
    -n open-cluster-management-observability -o jsonpath='{.spec.customizedVariables}' | jq .
  ```
  Verify `platformNamespaceRightSizing=enabled` and `platformVirtualizationRightSizing=enabled`

**Test 5b — Switch MCOA -> MCO:**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable-
```

Wait 60s. Verify:
- MCO Policy resources RECREATED: `rs-prom-rules-policy`, `rs-virt-prom-rules-policy`, `rs-policyset-binding`, `rs-virt-policyset-binding`
- Placements still exist (now managed by MCO analytics controller)
- CMA deleted, triggering addon framework cascade: CMA -> MCA -> ManifestWork -> spoke PrometheusRules removed
- ManifestWorks for RS PrometheusRules removed from spoke namespaces
- ADC CustomizedVariables show `disabled` for both RS features:
  ```bash
  oc --context=hub get addondeploymentconfig multicluster-observability-addon \
    -n open-cluster-management-observability -o jsonpath='{.spec.customizedVariables}' | jq .
  ```
  Verify `platformNamespaceRightSizing=disabled` and `platformVirtualizationRightSizing=disabled`

**Result:** PASS/FAIL for each sub-test.

### Phase 6: Version mismatch test (only if `--mode-switch` requested)

Tests that `IsRightSizingDelegated()` checks annotation KEY existence, not value. Any annotation value (v1, v99, empty) triggers delegation to MCOA.

Ensure MCO is installed and in MCO mode (annotation absent). Verify MCO Policy resources exist first.

**Test 6a — Set non-v1 annotation value:**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable=v99 --overwrite
```

Wait 60s. Verify:
- MCO Policy resources DELETED (annotation presence = delegated, regardless of value)
- MCOA Placements EXIST: `rs-placement`, `rs-virt-placement`
- ManifestWorks contain RS PrometheusRules (MCOA handles RS)
- ADC CustomizedVariables reflect enabled state (namespace and virtualization)

**Test 6b — Remove annotation (back to MCO mode):**

```bash
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable-
```

Wait 60s. Verify MCO Policy resources recreated.

**Result:** PASS if non-v1 annotation triggers delegation identically to v1. FAIL if MCO retains Policy resources with non-v1 value.

### Phase 7: SpecHash freshness test (only if `--mode-switch` requested)

Tests that MCA SpecHash is refreshed when ADC spec changes at runtime. This validates the fix where `needsConfigReferencesInitialization()` compares stored hash against current ADC hash.

Ensure MCO is in MCOA mode (annotation present). Verify MCA specHash is populated.

**Test 7a — Record current specHash:**

```bash
# Record specHash on each managed cluster
for mc in $(oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}'); do
  hash=$(oc --context=hub get managedclusteraddon observability-controller -n "$mc" \
    -o jsonpath='{.status.configReferences[0].desiredConfig.specHash}' 2>/dev/null)
  echo "  $mc: $hash"
done
```

All specHash values should be non-empty and identical (same ADC config for all clusters).

**Test 7b — Trigger ADC change via MCO spec patch:**

Disable one RS feature to change ADC CustomizedVariables:

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 60s (ADC update → PlacementRule reconciler → MCA SpecHash refresh). Record new specHash:

```bash
for mc in $(oc --context=hub get managedcluster -o jsonpath='{.items[*].metadata.name}'); do
  hash=$(oc --context=hub get managedclusteraddon observability-controller -n "$mc" \
    -o jsonpath='{.status.configReferences[0].desiredConfig.specHash}' 2>/dev/null)
  echo "  $mc: $hash"
done
```

Verify:
- New specHash is different from the one recorded in 7a (ADC spec changed)
- New specHash is non-empty on ALL managed clusters
- All clusters have the SAME new specHash (consistent ADC)

**Test 7c — Re-enable and verify hash changes again:**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 60s. Verify specHash changed again and matches the original value from 7a (same ADC state restored).

**Result:** PASS if specHash changes correctly with ADC spec changes. FAIL if specHash stays stale (old hash persists after ADC change).

### Phase 8: ConfigMap predicate side-effect test (only if `--mode-switch` requested)

Tests that in MCOA mode, ConfigMap changes do NOT trigger MCO Policy creation. The MCO `processConfigMap` function checks `IsRightSizingDelegated` and skips policy creation when delegated.

Ensure MCO is in MCOA mode (annotation present). Verify NO Policy resources exist.

**Test 8 — Modify RS ConfigMap and verify no Policy side-effect:**

```bash
oc --context=hub get configmap rs-namespace-config -n open-cluster-management-observability -o json | \
  jq '.data.config = (.data.config // "{}" | fromjson | .testKey = "testValue" | tojson)' | \
  oc --context=hub apply -f -
```

Wait 90s. Verify:
- NO Policy resources created: `rs-prom-rules-policy` should NOT exist
- NO PlacementBinding resources created: `rs-policyset-binding` should NOT exist

Then revert:

```bash
oc --context=hub get configmap rs-namespace-config -n open-cluster-management-observability -o json | \
  jq '.data.config = (.data.config | fromjson | del(.testKey) | tojson)' | \
  oc --context=hub apply -f -
```

**Result:** PASS if ConfigMap change in MCOA mode does NOT create Policy resources. FAIL if Policy/PlacementBinding appear after ConfigMap edit.

### Phase 9: Placement filter test (only if `--mode-switch` requested)

Tests per-feature cluster selection via ConfigMap placement configuration. Verifies that updating the placement config in a RS ConfigMap changes which clusters receive PrometheusRules.

Ensure MCO is in MCOA mode with both RS features enabled.

**Test 9a — Verify default placement selects all clusters:**

```bash
# Check how many clusters are selected by namespace placement
oc --context=hub get placementdecision -n open-cluster-management-global-set \
  -l cluster.open-cluster-management.io/placement=rs-placement \
  -o jsonpath='{.items[*].status.decisions[*].clusterName}'
```

Default: all managed clusters should be selected.

**Test 9b — Update namespace ConfigMap to select only one spoke:**

```bash
# Get the spoke cluster name
SPOKE_NAME=$(oc --context=hub get managedcluster -o jsonpath='{.items[?(@.metadata.name!="local-cluster")].metadata.name}' | awk '{print $1}')

# Patch the namespace ConfigMap with a placement filter
oc --context=hub patch configmap rs-namespace-config -n open-cluster-management-observability --type merge -p "{
  \"data\": {
    \"placementFilter\": \"{\\\"spec\\\":{\\\"predicates\\\":[{\\\"requiredClusterSelector\\\":{\\\"labelSelector\\\":{\\\"matchLabels\\\":{\\\"name\\\":\\\"$SPOKE_NAME\\\"}}}}]}}\"
  }
}"
```

Wait 60s (may need addon manager restart for placement filter to take effect). Verify:
- Namespace Placement `rs-placement` has predicates restricting cluster selection
- Only `$SPOKE_NAME` is selected by namespace Placement (check PlacementDecisions)
- Virtualization Placement `rs-virt-placement` still selects all clusters (unaffected)

**Test 9c — Reset to default placement:**

Remove the `placementFilter` key from the ConfigMap or delete/recreate it:

```bash
oc --context=hub patch configmap rs-namespace-config -n open-cluster-management-observability --type json -p '[{"op":"remove","path":"/data/placementFilter"}]'
```

Wait 60s. Verify namespace Placement selects all clusters again.

**Result:** PASS if placement filter correctly restricts cluster selection. FAIL if placement doesn't update or wrong clusters are selected.

### Phase 10: Both-disabled in MCOA mode (only if `--mode-switch` requested)

Tests the critical case where both RS features are disabled in MCOA mode. `Platform.Enabled` stays true (`options.go` sets it when RS keys are present even with `"disabled"` value), ensuring the rendering pipeline runs and produces manifests without PrometheusRules for framework pruning.

Single-feature disable in MCOA mode is already covered by Phase 2 (if cluster started in MCOA mode) or implicitly by the mode switch in Phase 5.

Ensure MCO is in MCOA mode (annotation present), both RS features enabled.

**Test 10a — Disable BOTH features (MCOA mode):**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":false},"virtualizationRightSizingRecommendation":{"enabled":false}}}}}}'
```

Wait 90s. Verify:
- ALL Placements DELETED: `rs-placement`, `rs-virt-placement`
- ALL ConfigMaps DELETED: `rs-namespace-config`, `rs-virt-config`
- ManifestWorks contain NO RS PrometheusRules
- ADC: both RS values = `disabled`

**Test 10b — Re-enable both (MCOA mode):**

```bash
oc --context=hub patch mco observability --type merge -p '{"spec":{"capabilities":{"platform":{"analytics":{"namespaceRightSizingRecommendation":{"enabled":true},"virtualizationRightSizingRecommendation":{"enabled":true}}}}}}'
```

Wait 90s. Verify all RS resources restored, ManifestWorks contain both PrometheusRules.

**Result:** PASS/FAIL for each sub-test. 10a is the most critical — tests ManifestWork pruning when both RS features disabled.

### Phase 11: ConfigMap propagation test (only if `--mode-switch` requested)

Tests that modifying RS ConfigMap content (e.g., `recommendationPercentage`) propagates to PrometheusRule content on spokes. Tests the data flow end-to-end, not just resource existence.

**Test 11a — ConfigMap propagation in MCO mode:**

Ensure MCO is in MCO mode (annotation absent), both features enabled. Verify baseline PrometheusRule content:

```bash
# Check current recommendationPercentage in Policy
oc --context=hub get policy rs-prom-rules-policy -n open-cluster-management-global-set -o json | \
  jq -r '.spec.["policy-templates"][0].objectDefinition.spec.["object-templates"][0].objectDefinition' | \
  grep -i "recommendation\|110"
```

Modify the ConfigMap:

```bash
oc --context=hub get configmap rs-namespace-config -n open-cluster-management-observability -o json | \
  jq '.data.config = (.data.config | fromjson | .prometheusRuleConfig.recommendationPercentage = 120 | tojson)' | \
  oc --context=hub apply -f -
```

Wait 90s. Verify:
- Policy `rs-prom-rules-policy` updated with new percentage (120 instead of 110)
- On spoke (if reachable): PrometheusRule content reflects 120

Revert:

```bash
oc --context=hub get configmap rs-namespace-config -n open-cluster-management-observability -o json | \
  jq '.data.config = (.data.config | fromjson | .prometheusRuleConfig.recommendationPercentage = 110 | tojson)' | \
  oc --context=hub apply -f -
```

**Test 11b — ConfigMap propagation in MCOA mode:**

Switch to MCOA mode. Modify the ConfigMap with the same percentage change. Wait 60s. Verify:
- ManifestWork updated with new PrometheusRule content containing 120
- On spoke (if reachable): PrometheusRule reflects 120

Revert the change.

**Result:** PASS if PrometheusRule content updates after ConfigMap change in both modes. FAIL if content stays stale.

### Phase 12: MCO reinstall after MCOA mode (only if `--mode-switch` requested)

Tests the full lifecycle: delete MCO while in MCOA mode → reinstall → verify clean start in MCO mode → switch to MCOA → verify works again. This tests `IsMCOTerminating` recovery and stale state cleanup.

**Test 12a — Delete MCO in MCOA mode and reinstall:**

Ensure MCO is in MCOA mode with both RS features enabled. Then delete:

```bash
echo "y" | bin/setup-observability uninstall
```

Wait for uninstall to complete. Verify ALL RS resources cleaned up (Placements, ConfigMaps, CMA, MCA, ManifestWorks).

Then reinstall:

```bash
bin/setup-observability install
```

Wait for MCO Ready (up to 120s). Verify:
- MCO starts in MCO mode (default — no annotation)
- RS features auto-enabled by `ensureRightSizingDefaults` (check MCO spec)
- MCO Policy resources created (default MCO mode)
- No stale MCOA resources (no CMA, no MCOA-managed ManifestWorks)
- Operator logs do NOT show `IsMCOTerminating` skip messages

**Test 12b — Mode switch round-trip after reinstall:**

Verifies mode switching works after a full uninstall/reinstall cycle (tests `IsMCOTerminating` recovery and stale state cleanup). Same checks as Phase 5a/5b but after a reinstall.

```bash
# Switch to MCOA
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable=true
```

Wait 60s. Verify MCOA mode active (Policies deleted, ManifestWorks with PrometheusRules, specHash populated, ADC enabled).

```bash
# Switch back to MCO
oc --context=hub annotate mco observability observability.open-cluster-management.io/right-sizing-capable-
```

Wait 60s. Verify MCO mode restored (Policies recreated, ADC disabled).

**Result:** PASS if MCO survives full uninstall/reinstall/mode-switch cycle. FAIL if stale state blocks recovery.

### Phase 13: Summary

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

Test                                    Result    Notes
----                                    ------    -----
0.  Pre-flight                          PASS      <state detected>
1.  Baseline resources exist            PASS/FAIL <missing resources>
2a. Disable namespace RS                PASS/FAIL <unexpected resources>
2b. Swap features (ns on, virt off)     PASS/FAIL
2c. Disable both features               PASS/FAIL
2d. Re-enable both features             PASS/FAIL
3.  Spoke PrometheusRules               PASS/FAIL/SKIP
4a. Uninstall cleanup (MCO mode)        PASS/FAIL/SKIP
4b. Uninstall cleanup (MCOA mode)       PASS/FAIL/SKIP
5a. MCO -> MCOA switch                  PASS/FAIL/SKIP
5b. MCOA -> MCO switch                  PASS/FAIL/SKIP
6a. Version mismatch (any annotation)   PASS/FAIL/SKIP
6b. Remove annotation (back to MCO)     PASS/FAIL/SKIP
7.  SpecHash freshness after ADC change PASS/FAIL/SKIP
8.  ConfigMap predicate side-effect     PASS/FAIL/SKIP
9.  Placement filter (cluster select)   PASS/FAIL/SKIP
10a.Disable both (MCOA mode)            PASS/FAIL/SKIP  ← critical
10b.Re-enable both (MCOA mode)          PASS/FAIL/SKIP
11a.ConfigMap propagation (MCO mode)    PASS/FAIL/SKIP
11b.ConfigMap propagation (MCOA mode)   PASS/FAIL/SKIP
12a.MCOA uninstall + reinstall          PASS/FAIL/SKIP
12b.Mode switch after reinstall         PASS/FAIL/SKIP
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
- Wait at least 90 seconds after MCO spec patches for controllers to reconcile (increased from 30s — rapid patches cause MCOA framework controller conflicts and exponential backoff)
- Wait at least 60 seconds after mode switch (annotation change) for full reconciliation (CMA creation, MCOA startup, ManifestWork generation)
- Phase 4 (uninstall) and Phase 5 (mode switch) are destructive — always ask user confirmation
- If any step fails, report the failure clearly but continue with remaining steps
- Use `bin/rs-status` for quick visual checks between steps
- The `IsMCOTerminating` flag persists in operator memory after MCO deletion. If the operator wasn't restarted between MCO delete and recreate, the analytics controller will skip all reconciles. Detect this in Phase 0 and restart the operator.
- MCO mode partial disable cleanup (Phase 2) is handled by the upstream `HandleComponentRightSizing` function. Full MCO deletion cleanup (Phase 4) is handled by the `CleanupRightSizingResources` function in the MCO finalizer.
