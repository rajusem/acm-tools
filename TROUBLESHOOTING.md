# Right-Sizing Troubleshooting Guide

Learnings and common issues encountered while developing and testing the right-sizing migration (MCO Policy-based to MCOA ManifestWork-based).

---

## ManifestWork PrometheusRules: 0

**Symptom**: `rs-mode-switch status` shows ManifestWork PrometheusRules: 0 even though MCOA mode is active and ADC has RS "enabled".

**Root cause**: Placements must be created in a namespace that has a `ManagedClusterSetBinding`. Without it, the Placement scheduler cannot select any clusters.

**Diagnosis**:
```bash
# Check Placement status — look for "NoManagedClusterSetBindings"
kubectl get placement -n open-cluster-management-observability
kubectl get placement -n open-cluster-management-global-set

# Check which namespaces have ManagedClusterSetBindings
kubectl get managedclustersetbinding -A
```

**Fix**: RS Placements should be in `open-cluster-management-global-set` which already has a `ManagedClusterSetBinding` named `global`. This matches MCO's Policy-based approach (MCO uses `DefaultNamespace = "open-cluster-management-global-set"` in `rs-utility/types.go`).

If stale Placements exist in the wrong namespace, delete them:
```bash
kubectl delete placement rs-placement rs-virt-placement \
  -n open-cluster-management-observability
```

---

## ManifestWork Not Being Applied (observedGeneration Lag)

**Symptom**: ManifestWork spec has the right resources but status shows fewer resources applied. `generation` != `observedGeneration`.

**Diagnosis**:
```bash
kubectl get manifestwork addon-multicluster-observability-addon-deploy-0 \
  -n <cluster-name> -o json | \
  jq '{generation: .metadata.generation,
       observedGeneration: .status.conditions[0].observedGeneration,
       resourceCount: (.status.resourceStatus.manifests | length),
       specManifestCount: (.spec.workload.manifests | length)}'
```

**Root cause**: The klusterlet work agent on the spoke/local-cluster is stale or stuck.

**Fix**: Restart the klusterlet agent:
```bash
# For local-cluster (hub)
kubectl delete pod -n open-cluster-management-agent -l app=klusterlet-agent

# Verify new pod started
kubectl get pods -n open-cluster-management-agent
```

---

## ManagedClusterLeaseUpdateStopped

**Symptom**: `kubectl get managedcluster <name>` shows `ManagedClusterConditionAvailable: Unknown` with reason `ManagedClusterLeaseUpdateStopped`.

**Impact**: Work agent cannot process ManifestWork updates. PrometheusRules, COO Subscription, Perses dashboards all pending.

**Diagnosis**:
```bash
kubectl get managedcluster -o json | \
  jq '.items[] | {name: .metadata.name,
      available: (.status.conditions[] | select(.type=="ManagedClusterConditionAvailable") | .status)}'
```

**Fix**: Restart klusterlet components:
```bash
kubectl delete pod -n open-cluster-management-agent -l app=klusterlet-agent
```

If that doesn't help, the spoke cluster may be unreachable (powered off, network issues).

---

## Image Override Not Taking Effect

**Symptom**: Applied image override but pod still shows old/upstream image.

**Causes & fixes**:

1. **MCH uses `imagePullPolicy: IfNotPresent`**: If you rebuild an image with the same tag, the node won't pull the new version. Always increment the tag (v51 -> v52).

2. **ConfigMap must be in both namespaces**:
   - `open-cluster-management` (for MCO operator)
   - `open-cluster-management-observability` (for MCOA addon)

   The `image-override apply` command handles this automatically.

3. **Force reconcile needed**: Use `image-override apply --force-reconcile` to toggle the MCH annotation and trigger pod rollout.

4. **Verify the image**:
   ```bash
   # MCO operator
   kubectl get pod -n open-cluster-management \
     -l name=multicluster-observability-operator \
     -o jsonpath='{.items[0].spec.containers[0].image}'

   # MCOA addon manager
   kubectl get pod -n open-cluster-management-observability \
     -l app=multicluster-observability-addon \
     -o jsonpath='{.items[0].spec.containers[0].image}'
   ```

---

## CMA Not Created (Bootstrap Problem)

**Symptom**: `kubectl get cma multicluster-observability-addon` returns NotFound when only right-sizing is enabled (no other MCOA capabilities like logs/metrics/traces).

**Root cause**: `MCOAEnabled()` excludes right-sizing. Without a CMA, user cannot annotate it for MCOA delegation — chicken-and-egg.

**Fix (code)**: Three-tier rendering in MCO's `renderer.go`:
- `MCOAEnabled || rightSizingDelegated` → Full MCOA stack
- `RightSizingEnabled(r.cr)` only → CMA only (no pod)
- Neither → Nothing

This was fixed in MCO v52. The CMA auto-creates when RS is enabled, giving users a resource to annotate.

---

## Perses Not Deploying

**Symptom**: MCOA mode active, PrometheusRules deployed, but no Perses pod/dashboards on hub.

**How Perses deploys**: MCOA adds COO (Cluster Observability Operator) resources to `local-cluster`'s ManifestWork:
1. `OperatorGroup` + `Subscription` for COO in `openshift-cluster-observability-operator` namespace
2. COO installs → provides Perses CRDs
3. `PersesDashboard`, `PersesDatasource`, `UIPlugin` applied

**Diagnosis**:
```bash
# Check if COO resources are in the ManifestWork
kubectl get manifestwork addon-multicluster-observability-addon-deploy-0 \
  -n local-cluster -o json | \
  jq '[.spec.workload.manifests[] |
       select(.kind | test("Perses|Subscription|OperatorGroup|UIPlugin")) |
       {kind, name: .metadata.name}]'

# Check if COO subscription exists
kubectl get subscription -n openshift-cluster-observability-operator

# Check COO operator pod
kubectl get pods -n openshift-cluster-observability-operator

# Check Perses dashboards
kubectl get persesdashboard -n open-cluster-management-observability
```

**Common cause**: `local-cluster` klusterlet agent is stale (see "ManifestWork Not Being Applied" above).

---

## Mode Switch Not Taking Effect

**Symptom**: `rs-mode-switch mcoa/mco` runs but state doesn't change.

**Things to check**:

1. **CMA annotation**: The authoritative signal for mode.
   ```bash
   kubectl get cma multicluster-observability-addon \
     -o jsonpath='{.metadata.annotations.observability\.open-cluster-management\.io/right-sizing-capable}'
   ```

2. **ADC state**: Must reflect the current mode.
   ```bash
   kubectl get addondeploymentconfig multicluster-observability-addon \
     -n open-cluster-management-observability -o json | \
     jq '.spec.customizedVariables[] |
         select(.name | test("RightSizing"))'
   ```
   - MCOA mode: values should be `"enabled"`
   - MCO mode: values should be `"disabled"`

3. **MCOA pod restart**: After mode switch, MCOA pod may need restart to pick up new ADC values:
   ```bash
   kubectl rollout restart deployment/multicluster-observability-addon-manager \
     -n open-cluster-management-observability
   ```

4. **MCO reconcile trigger**: The `rs-mode-switch` script auto-triggers this via MCO CR annotation touch.

---

## Quick Diagnostic Commands

```bash
# Full status dashboard
bin/rs-mode-switch status

# Check all managed cluster health
kubectl get managedcluster

# Check MCOA pod logs
kubectl logs -n open-cluster-management-observability \
  -l app=multicluster-observability-addon --tail=50

# Check MCO operator logs for right-sizing
kubectl logs -n open-cluster-management \
  -l name=multicluster-observability-operator --tail=100 | grep -i "right-siz"

# List all RS-related resources on hub
kubectl get placement,placementdecision -n open-cluster-management-global-set | grep rs-
kubectl get configmap -n open-cluster-management-observability | grep rs-
kubectl get policy -n open-cluster-management-global-set | grep rs-

# Check ManifestWork contents for a spoke
kubectl get manifestwork -n <spoke-name> -o json | \
  jq '.items[] | select(.metadata.name | test("observ")) |
      {name: .metadata.name, kinds: [.spec.workload.manifests[] | .kind]}'
```

---

## Architecture Reference

| Mode | Deployment Mechanism | Placement Namespace | RS Signal |
|------|---------------------|---------------------|-----------|
| MCO (Policy) | Policy + PlacementBinding | `open-cluster-management-global-set` | MCO CR capabilities |
| MCOA (ManifestWork) | ManifestWork via addon framework | `open-cluster-management-global-set` | CMA annotation `right-sizing-capable=v1` |

| Component | Hub Namespace | Created By |
|-----------|--------------|------------|
| MCO Operator | `open-cluster-management` | MCH |
| MCOA Addon Manager | `open-cluster-management-observability` | MCO |
| RS Placements | `open-cluster-management-global-set` | MCO (Policy mode) / MCOA (ManifestWork mode) |
| RS ConfigMaps | `open-cluster-management-observability` | MCO (Policy mode) / MCOA (ManifestWork mode) |
| RS Policies | `open-cluster-management-global-set` | MCO (Policy mode only) |
| CMA | cluster-scoped | MCO |
| ADC | `open-cluster-management-observability` | MCO |
