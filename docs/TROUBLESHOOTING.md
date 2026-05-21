# Right-Sizing Troubleshooting Guide

Learnings and common issues encountered while developing and testing the right-sizing migration (MCO Policy-based to MCOA ManifestWork-based).

---

## MCOA Cluster Selection: In-Memory Predicate Evaluation

MCOA no longer creates Placement or PlacementDecision CRs. Instead, it uses **in-memory predicate evaluation**: placement predicates are stored inside the `rs-namespace-config` and `rs-virt-config` ConfigMaps (as a `placementConfiguration` YAML key) and evaluated against ManagedCluster objects during `Build()`. This eliminates the Placement scheduler dependency and the `ManagedClusterSetBinding` requirement.

- MCO mode still creates real Placement CRs (`rs-placement`, `rs-virt-placement`) in `open-cluster-management-global-set`
- MCOA mode uses in-memory predicate evaluation — no Placement CRs, no separate placement ConfigMaps

## ManifestWork PrometheusRules: 0

**Symptom**: `rs-status` shows ManifestWork PrometheusRules: 0 even though MCOA mode is active and ADC has RS "enabled".

**Root cause**: The `rs-namespace-config` / `rs-virt-config` ConfigMaps may have restrictive `placementConfiguration` predicates that don't match any clusters, or MCOA may not have reconciled after an ADC change.

**Diagnosis**:
```bash
# Check RS config ConfigMaps exist and inspect placement predicates
kubectl get configmap rs-namespace-config rs-virt-config \
  -n open-cluster-management-observability -o yaml

# Restart MCOA addon manager to force ManifestWork regeneration
kubectl rollout restart deployment/multicluster-observability-addon-manager \
  -n open-cluster-management-observability
```

**Fix**: If the `placementConfiguration` key in the config ConfigMaps has restrictive label selectors, verify that the target ManagedCluster objects have the required labels. If MCOA hasn't reconciled, restart the addon manager deployment.

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

## ManifestWork Stuck in Deleting (local-cluster)

**Symptom**: `setup-observability status` shows "Stuck ManifestWorks (blocking MCOA reconciliation)". COO is not installed, Perses dashboards are missing, and `rs-mode-switch mcoa` fails to produce ManifestWork PrometheusRules.

**Root cause**: Self-referential deadlock on `local-cluster`. The hub IS the spoke, so during MCO teardown the work-agent can't confirm cleanup of spoke-side resources while MCO is being deleted. The finalizer `cluster.open-cluster-management.io/manifest-work-cleanup` never clears, leaving the ManifestWork stuck in `Deleting`. The API server rejects any updates to resources with a `deletionTimestamp`, so MCOA cannot create or update ManifestWorks for `local-cluster`.

This commonly occurs during repeated MCO install/uninstall cycles in dev/test environments.

**Diagnosis**:
```bash
# Check for stuck ManifestWorks
kubectl get manifestwork -n local-cluster -o json | \
  jq '.items[] | select(.metadata.deletionTimestamp) |
      {name: .metadata.name, deletionTimestamp: .metadata.deletionTimestamp,
       finalizers: .metadata.finalizers}'

# Quick status check (detects stuck MWs older than 120s)
bin/setup-observability status
```

**Fix**:
```bash
# Automated cleanup during install
bin/setup-observability install --force-cleanup-mw

# Or manual fix: remove finalizers, then restart MCOA
kubectl patch manifestwork <name> -n local-cluster \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl rollout restart deployment/multicluster-observability-addon-manager \
  -n open-cluster-management-observability
```

The `--force-cleanup-mw` flag removes all finalizers from stuck MCOA ManifestWorks on `local-cluster`, waits for deletion, then restarts the MCOA addon manager to trigger ManifestWork re-creation.

---

## ManagedClusterLeaseUpdateStopped

**Symptom**: `kubectl get managedcluster <name>` shows `ManagedClusterConditionAvailable: Unknown` with reason `ManagedClusterLeaseUpdateStopped`.

**Common trigger (dev)**: Hibernating and resuming SNO dev clusters. The klusterlet's `bootstrap-hub-kubeconfig` or derived `hub-kubeconfig-secret` becomes stale after resume, so the registration agent cannot renew its lease. This is primarily a dev/test concern — production 3-node hub clusters typically don't hibernate.

**Impact**: Work agent cannot process ManifestWork updates. PrometheusRules, COO Subscription, Perses dashboards all pending.

**Diagnosis**:
```bash
kubectl get managedcluster -o json | \
  jq '.items[] | {name: .metadata.name,
      available: (.status.conditions[] | select(.type=="ManagedClusterConditionAvailable") | .status)}'

# Check lease renewal time (should be recent)
kubectl get lease managed-cluster-lease -n <cluster-name> \
  -o jsonpath='{.spec.renewTime}'
```

**Fix** (escalating):

1. **Restart klusterlet agent**:
   ```bash
   kubectl delete pod -n open-cluster-management-agent -l app=klusterlet-agent
   ```

2. **Delete stale lease + restart all klusterlet pods** (if step 1 doesn't help):
   ```bash
   kubectl delete lease managed-cluster-lease -n <cluster-name>
   kubectl delete pod -n open-cluster-management-agent --all
   # Wait 60s, then check:
   kubectl get managedcluster <cluster-name> -o json | \
     jq '.status.conditions[] | select(.type=="ManagedClusterConditionAvailable")'
   ```

3. **Check for stale bootstrap-hub-kubeconfig** (especially on `local-cluster`):
   ```bash
   # Check what hub the klusterlet is trying to talk to
   kubectl --context=<spoke-ctx> get secret bootstrap-hub-kubeconfig \
     -n open-cluster-management-agent \
     -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"

   # Also check the derived hub-kubeconfig-secret (agent uses this for lease renewal)
   kubectl --context=<spoke-ctx> get secret hub-kubeconfig-secret \
     -n open-cluster-management-agent \
     -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"

   # Compare with actual hub API
   kubectl --context=hub cluster-info | head -1
   ```

   If either secret points to a wrong hub URL, you must delete BOTH secrets before
   re-applying import manifests. Deleting only `hub-kubeconfig-secret` is NOT enough —
   the agent will re-derive it from the stale `bootstrap-hub-kubeconfig` and the
   lease will stop again within minutes:

   ```bash
   # Delete BOTH secrets (critical — must delete bootstrap too)
   kubectl --context=<spoke-ctx> delete secret \
     bootstrap-hub-kubeconfig hub-kubeconfig-secret \
     -n open-cluster-management-agent

   # Re-apply import manifests (creates correct bootstrap-hub-kubeconfig)
   kubectl --context=hub get secret <cluster-name>-import -n <cluster-name> \
     -o jsonpath='{.data.crds\.yaml}' | base64 -d | \
     kubectl --context=<spoke-ctx> apply -f -
   kubectl --context=hub get secret <cluster-name>-import -n <cluster-name> \
     -o jsonpath='{.data.import\.yaml}' | base64 -d | \
     kubectl --context=<spoke-ctx> apply -f -

   # Restart all agent pods to force fresh registration
   kubectl --context=<spoke-ctx> delete pod -n open-cluster-management-agent --all

   # Verify BOTH secrets now point to the correct hub
   kubectl --context=<spoke-ctx> get secret bootstrap-hub-kubeconfig \
     -n open-cluster-management-agent \
     -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"
   kubectl --context=<spoke-ctx> get secret hub-kubeconfig-secret \
     -n open-cluster-management-agent \
     -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"

   # Verify lease is being renewed (renewTime should be recent)
   kubectl --context=hub get lease managed-cluster-lease -n <cluster-name> \
     -o jsonpath='{.spec.renewTime}'
   ```

   This commonly happens when the spoke was previously attached to a different hub.
   The old `bootstrap-hub-kubeconfig` persists and the registration agent keeps
   re-deriving a `hub-kubeconfig-secret` that points to the wrong hub.

   **Automated fix**: `bin/add-managed-cluster` handles the full klusterlet cleanup
   and re-import in a single command:
   ```bash
   # For spoke clusters:
   bin/add-managed-cluster add <spoke-ctx> --force-import

   # For local-cluster (hub is both spoke and hub):
   bin/add-managed-cluster add hub --force-import
   ```

4. **Manual ManifestWork application** (bypass stuck work agent entirely):
   ```bash
   # Extract and apply resources directly on the hub
   kubectl get manifestwork addon-multicluster-observability-addon-deploy-0 \
     -n local-cluster -o json | \
     jq -c '.spec.workload.manifests[]' | \
     while read -r m; do echo "$m" | kubectl apply -f - 2>&1; done
   ```
   Note: Apply Namespace resources first, then OperatorGroup/Subscription (for COO),
   wait for CRDs, then apply PersesDashboard/PersesDatasource/UIPlugin.

If none of the above work, the spoke cluster may be unreachable (powered off, network issues).

---

## Managed Cluster Import Fails (Auto-Import)

**Symptom**: `add-managed-cluster add` creates the ManagedCluster CR but the cluster never becomes Available. The import condition shows `i/o timeout` errors.

**Root cause**: Auto-import requires hub→spoke network connectivity. The hub tries to push klusterlet manifests to the spoke API server, which fails if the spoke is on a different network (e.g., PSI lab vs dev cluster pool).

**Diagnosis**:
```bash
# Check import condition
kubectl get managedcluster <name> -o jsonpath='{.status.conditions}' | jq '.'
# Look for: "dial tcp <ip>:6443: i/o timeout"
```

**Fix**: The `add-managed-cluster` script handles this automatically — it uses manual import (applies klusterlet manifests on the spoke via `--context`) which only requires spoke→hub connectivity.

---

## Managed Cluster Import Blocked (Existing Klusterlet)

**Symptom**: `add-managed-cluster add` fails with "Spoke cluster is already attached to a hub".

**Root cause**: The spoke cluster already has a klusterlet installed from a previous hub attachment. This can happen when:
- The spoke was detached from the hub but the klusterlet wasn't cleaned up (hub couldn't reach spoke for detach)
- The spoke is still attached to a different hub

**Diagnosis**:
```bash
# Check for klusterlet on spoke
kubectl --context=<spoke-ctx> get namespace open-cluster-management-agent
kubectl --context=<spoke-ctx> get klusterlet klusterlet

# Check which hub it's attached to
kubectl --context=<spoke-ctx> get secret bootstrap-hub-kubeconfig \
  -n open-cluster-management-agent -o jsonpath='{.data.kubeconfig}' | \
  base64 -d | grep "server:"
```

**Fix**: Use `--force-import` to clean up the existing klusterlet and re-import:
```bash
bin/add-managed-cluster add <context> --name <name> --force-import
```

Or manually clean up the klusterlet on the spoke:
```bash
kubectl --context=<spoke-ctx> delete klusterlet klusterlet
kubectl --context=<spoke-ctx> delete namespace open-cluster-management-agent
kubectl --context=<spoke-ctx> delete namespace open-cluster-management-agent-addon
kubectl --context=<spoke-ctx> delete crd klusterlets.operator.open-cluster-management.io
```

---

## OLM Subscription API Group Collision

**Symptom**: `install-custom-acm` fails to detect the ACM operator CSV, or `install-custom-acm status` shows "Subscription: not found" even though ACM is installed.

**Root cause**: Once ACM is installed, `kubectl get subscription` resolves to ACM's `apps.open-cluster-management.io/v1` (app subscriptions) instead of OLM's `operators.coreos.com/v1alpha1`. Both API groups register a `Subscription` resource.

**Diagnosis**:
```bash
# See both subscription types
kubectl api-resources 2>/dev/null | grep -i subscription

# Check OLM subscription explicitly
kubectl get subscription.operators.coreos.com acm-operator-subscription \
  -n open-cluster-management
```

**Fix**: Always use the fully-qualified resource name `subscription.operators.coreos.com` when working with OLM subscriptions on clusters that have ACM installed. This is already fixed in `install-custom-acm`.

---

## Policy Addons Not Deployed on Spoke (Missing KlusterletAddonConfig)

**Symptom**: `rs-mode-switch status` or `rs-status` shows PrometheusRules deployed on `local-cluster` but not on spoke clusters. Policy-based right-sizing doesn't work on spokes.

**Root cause**: The spoke cluster is missing a `KlusterletAddonConfig`, which controls which addons ACM deploys on the spoke. Without it, `config-policy-controller` and `governance-policy-framework` addons are not installed — these are required for Policy-based right-sizing to enforce PrometheusRules.

The ACM console creates `KlusterletAddonConfig` automatically when importing clusters via UI, but CLI import may skip it.

**Diagnosis**:
```bash
# Check if KlusterletAddonConfig exists for the spoke
kubectl get klusterletaddonconfig -n <spoke-name>

# Compare addons between working (local-cluster) and broken spoke
kubectl get managedclusteraddon -n local-cluster
kubectl get managedclusteraddon -n <spoke-name>

# Look for missing: config-policy-controller, governance-policy-framework
```

**Fix**: Create the KlusterletAddonConfig for the spoke:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: <spoke-name>
  namespace: <spoke-name>
spec:
  clusterName: <spoke-name>
  clusterNamespace: <spoke-name>
  applicationManager:
    enabled: true
  certPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
EOF
```

This is now handled automatically by `add-managed-cluster add`.

---

## MCH Uninstall Blocked by ManagedClusters

**Symptom**: `install-custom-acm uninstall` fails with: `admission webhook denied the request: cannot delete MultiClusterHub resource because ManagedCluster resource(s) exist`.

**Root cause**: MCH has a validating webhook that prevents deletion while ManagedCluster resources exist, to avoid orphaning managed clusters.

**Diagnosis**:
```bash
kubectl get managedcluster
```

**Fix**: Use `--force-remove` to automatically detach all managed clusters before uninstalling:
```bash
bin/install-custom-acm uninstall --force-remove
```

This removes all non-local-cluster ManagedClusters first, then deletes MCH. If MCH deletion stalls due to `local-cluster` finalizers, it automatically removes `local-cluster` and patches finalizers.

Or manually remove managed clusters first:
```bash
kubectl delete managedcluster --all
bin/install-custom-acm uninstall
```

---

## ManagedClusterAddon CRD Stuck Terminating

**Symptom**: No `ManagedClusterAddon` resources are created for any cluster. `kubectl get managedclusteraddon -n <cluster>` returns "the server could not find the requested resource". GPU or RS policies show `compliant: null` (violations) on all clusters.

**Root cause**: The `managedclusteraddons.addon.open-cluster-management.io` CRD is stuck in a terminating state. This blocks ALL addon creation hub-wide. Typically caused by stale `ManagedClusterAddon` instances with finalizers that can't be processed (e.g., on a detached or unreachable spoke).

**Diagnosis**:
```bash
# Check if CRD is terminating
kubectl get crd managedclusteraddons.addon.open-cluster-management.io \
  -o jsonpath='{.metadata.deletionTimestamp}'
# Non-empty = CRD is terminating

# Check for stuck instances blocking deletion
kubectl get managedclusteraddon --all-namespaces

# Check addon controller logs for errors
kubectl logs -n open-cluster-management-hub \
  -l app=cluster-manager-addon-manager-controller --tail=20
# Look for: "create not allowed while custom resource definition is terminating"
```

**Fix**:

1. **Remove stuck addon instances** (patch out finalizers if delete hangs):
   ```bash
   for addon in $(kubectl get managedclusteraddon -n <stuck-namespace> -o name); do
     kubectl patch $addon -n <stuck-namespace> --type=merge \
       -p '{"metadata":{"finalizers":null}}'
   done
   ```

2. **Wait for CRD to finish deleting**, then restart `cluster-manager` to re-create it:
   ```bash
   kubectl rollout restart deploy/cluster-manager -n multicluster-engine
   kubectl rollout status deploy/cluster-manager -n multicluster-engine --timeout=120s
   ```

3. **Restart addon controllers** (their informers are stuck after CRD was missing):
   ```bash
   kubectl delete pod -n open-cluster-management-hub --all
   kubectl delete pod -n open-cluster-management -l component=klusterlet-addon-controller
   ```

4. **Verify recovery**:
   ```bash
   # CRD is back
   kubectl get crd managedclusteraddons.addon.open-cluster-management.io
   # Addons being created
   kubectl get managedclusteraddon -n <cluster-name>
   ```

---

## Spoke Cluster Registered But Klusterlet Not Deployed

**Symptom**: `ManagedCluster` exists on hub and shows `Joined: True` briefly, then `Available: Unknown`. `ManagedClusterAddon` resources exist on the hub but all show `Available: Unknown`. No klusterlet pods on the spoke.

**Root cause**: The spoke was registered on the hub (ManagedCluster CR created, import secret generated) but the klusterlet manifests were never applied on the spoke. This happens with clusters imported via API/CLI without applying the import YAML on the spoke side.

**Diagnosis**:
```bash
# Check for import secret on hub
kubectl get secret <cluster-name>-import -n <cluster-name>

# Check klusterlet on spoke (should exist but doesn't)
kubectl --kubeconfig=<spoke-kubeconfig> get ns open-cluster-management-agent
kubectl --kubeconfig=<spoke-kubeconfig> get klusterlet
```

**Fix**: Manually apply the import manifests from the hub to the spoke:
```bash
# Apply CRDs first
kubectl get secret <cluster-name>-import -n <cluster-name> \
  -o jsonpath='{.data.crds\.yaml}' | base64 -d | \
  kubectl --kubeconfig=<spoke-kubeconfig> apply -f -

# Apply import manifests (klusterlet, bootstrap secret, etc.)
kubectl get secret <cluster-name>-import -n <cluster-name> \
  -o jsonpath='{.data.import\.yaml}' | base64 -d | \
  kubectl --kubeconfig=<spoke-kubeconfig> apply -f -

# Verify klusterlet pods start
kubectl --kubeconfig=<spoke-kubeconfig> get pods \
  -n open-cluster-management-agent

# Verify cluster becomes Available on hub
kubectl get managedcluster <cluster-name>
```

The `add-managed-cluster add` script handles this automatically when a `--context` is provided.

---

## Duplicate "Grafana" Links in ACM Console (MCOA Mode)

**Symptom**: In MCOA mode, the ACM console "Launch dashboard" dropdown shows two "Grafana" entries instead of one.

**Root cause**: Two `ClusterManagementAddOn` resources both have `console.open-cluster-management.io/launch-link-text: "Grafana"` annotations:
- `observability-controller` — always exists, Grafana link for MCO dashboards
- `multicluster-observability-addon` — only in MCOA mode, had its own Grafana link

**Diagnosis**:
```bash
# Check launch-link annotations on all CMAs
kubectl get cma -o json | \
  jq '.items[] | select(.metadata.annotations["console.open-cluster-management.io/launch-link-text"]) |
      {name: .metadata.name, text: .metadata.annotations["console.open-cluster-management.io/launch-link-text"]}'
```

**Fix**: The MCOA CMA renderer no longer sets launch-link annotations. Delete the stale CMA to force re-creation:
```bash
kubectl delete cma multicluster-observability-addon
# MCO will re-create it without launch-link annotations
```

Perses dashboards are accessible separately via "Observe > Dashboards (Perses)" in the OpenShift console.

---

## Image Override Not Taking Effect

**Symptom**: Applied image override but pod still shows old/upstream image.

**Causes & fixes**:

1. **MCH uses `imagePullPolicy: IfNotPresent`**: If you rebuild an image with the same tag, the node won't pull the new version. Always increment the tag (v51 -> v52).

2. **ConfigMap must be in both namespaces**:
   - `open-cluster-management` (for MCO operator)
   - `open-cluster-management-observability` (for MCOA addon)

   The `image-override apply` command handles this automatically.

3. **MCH in Pending state won't reconcile overrides**: When MCH is `Pending` (not `Running`), it does not reconcile image-override ConfigMap changes to deployments. Workaround — patch deployments directly:
   ```bash
   # Patch MCO deployment directly
   oc --context=hub set image deployment/multicluster-observability-operator \
     -n open-cluster-management \
     multicluster-observability-operator=<registry>/<image>:<tag>
   ```

4. **MCO reads MCOA image from `mch-image-manifest`, not `image-override`**: The MCO operator reads the MCOA image from the `mch-image-manifest-*` ConfigMap in `open-cluster-management`, not from the `image-override` ConfigMap. You must also patch this ConfigMap:
   ```bash
   # Find the manifest ConfigMap name
   MANIFEST_CM=$(oc --context=hub get configmap -n open-cluster-management \
     --no-headers | awk '/^mch-image-manifest/{print $1}' | head -1)

   # Patch with the correct MCOA image
   oc --context=hub patch configmap "$MANIFEST_CM" -n open-cluster-management \
     --type merge \
     -p '{"data":{"multicluster_observability_addon":"<registry>/<image>:<tag>"}}'
   ```

5. **Force reconcile needed**: Use `image-override apply --force-reconcile` to toggle the MCH annotation and trigger pod rollout.

6. **Verify the image**:
   ```bash
   # MCO operator
   kubectl get pod -n open-cluster-management \
     -l name=multicluster-observability-operator \
     -o jsonpath='{.items[0].spec.containers[0].image}'

   # MCOA addon manager
   kubectl get pod -n open-cluster-management-observability \
     -l app=multicluster-observability-addon-manager \
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

The CMA auto-creates when RS is enabled, giving users a resource to annotate.

---

## Perses Not Deploying

**Symptom**: MCOA mode active, PrometheusRules deployed, but no Perses pod/dashboards on hub.

**How Perses deploys**: MCOA adds COO (Cluster Observability Operator) resources to `local-cluster`'s ManifestWork:
1. `Namespace` for `observability-analytics` (where RS/analytics dashboards live)
2. `OperatorGroup` + `Subscription` for COO in `openshift-cluster-observability-operator` namespace
3. COO installs → provides Perses CRDs (`PersesDashboard`, `PersesDatasource`, `UIPlugin`)
4. RS dashboards + datasource applied in `observability-analytics` namespace

**Diagnosis**:
```bash
# Check if COO + Perses resources are in the ManifestWork
kubectl get manifestwork addon-multicluster-observability-addon-deploy-0 \
  -n local-cluster -o json | \
  jq '[.spec.workload.manifests[] |
       select(.kind | test("Perses|Subscription|OperatorGroup|UIPlugin|Namespace")) |
       {kind, name: .metadata.name, namespace: .metadata.namespace}]'

# Check if COO subscription exists
kubectl get subscription.operators.coreos.com -n openshift-cluster-observability-operator

# Check COO operator pod + Perses pod
kubectl get pods -n openshift-cluster-observability-operator

# Check analytics namespace exists
kubectl get ns observability-analytics

# Check Perses dashboards (RS + incident detection)
kubectl get persesdashboard -n observability-analytics

# Check datasource in analytics namespace
kubectl get persesdatasource -n observability-analytics
```

**Common causes**:
- `local-cluster` klusterlet has stale `bootstrap-hub-kubeconfig` pointing to a previous hub (see "ManagedClusterLeaseUpdateStopped" step 3 above). ManifestWork status may show "Applied=True" from a previous hub session while resources don't actually exist. Fix the bootstrap kubeconfig first.
- `local-cluster` klusterlet agent is stale — restart with `kubectl delete pod -n open-cluster-management-agent --all`
- COO CRDs not yet installed — check if COO CSV reached `Succeeded` phase
- `observability-analytics` namespace not created — check ManifestWork includes Namespace resource

---

## Placement/ConfigMap GC Cascade During MCOA→MCO Switch

> **Historical**: This issue applied when MCOA created Placement CRs. MCOA now uses in-memory predicate evaluation with ConfigMap-stored predicates — no Placement CRs are created, so the GC cascade for Placements no longer occurs. ConfigMap ownerRef issues may still apply if running an older MCOA version.

**Symptom**: After switching from MCOA to MCO mode (`rs-mode-switch mco`), Placements and/or ConfigMaps (`rs-namespace-config`, `rs-virt-config`) are deleted within ~3 seconds of being recreated. `rs-status` shows missing Policies/Placements.

**Root cause**: MCOA sets Kubernetes `ownerReferences` on Placements and ConfigMaps pointing to the `ClusterManagementAddOn` (CMA). When MCO deletes the CMA during mode switch (because MCOA is no longer needed), K8s garbage collector cascades the deletion to all resources with ownerRef → CMA.

A misleading code comment in MCOA claims "cross-scope ownerReferences don't enable garbage collection" — this is wrong. K8s disallows cross-*namespace* ownerRefs, but cluster-scoped (CMA) → namespace-scoped (Placement/ConfigMap) IS valid and DOES trigger GC.

**Diagnosis**:
```bash
# Check if Placements or ConfigMaps have ownerReferences pointing to CMA
kubectl get placement rs-placement -n open-cluster-management-global-set -o json | \
  jq '.metadata.ownerReferences'

kubectl get configmap rs-namespace-config -n open-cluster-management-observability -o json | \
  jq '.metadata.ownerReferences'

# Check kube-apiserver audit logs for GC deletions
# Look for user "system:serviceaccount:kube-system:generic-garbage-collector"
```

**Fix**: Two-part fix across MCOA and MCO:

1. **MCOA**: Remove ownerReferences from Placements and ConfigMaps (root cause fix). Labels (`app.kubernetes.io/managed-by`) provide sufficient tracking.
2. **MCO**: Reset `ComponentState.Enabled` after delegation cleanup + freshEnable detection recreates resources on first reconcile after mode switch (independent ComponentState bug).

**Workaround**: If running an older MCOA version that still sets ownerRefs, restart the MCO operator pod after mode switch to force resource recreation:
```bash
kubectl rollout restart deployment/multicluster-observability-operator \
  -n open-cluster-management
```

---

## Mode Switch Not Taking Effect

**Symptom**: `rs-mode-switch mcoa/mco` runs but state doesn't change.

**Things to check**:

1. **MCO CR annotation**: The authoritative signal for mode.
   ```bash
   kubectl get mco observability \
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

3. **MCOA pod restart**: After MCOA→MCO switch, MCOA pod may need restart to pick up new ADC values. The freshEnable detection handles resource creation automatically without requiring restarts, but if state is stale:
   ```bash
   kubectl rollout restart deployment/multicluster-observability-addon-manager \
     -n open-cluster-management-observability
   ```

4. **MCO reconcile trigger**: The `rs-mode-switch` script auto-triggers this via MCO CR annotation touch.

5. **GC cascade**: If resources disappear within seconds of being created, see "Placement/ConfigMap GC Cascade During MCOA→MCO Switch" above.

---

## Quick Diagnostic Commands

```bash
# Full status dashboard
bin/rs-status

# Check all managed cluster health
kubectl get managedcluster

# Check MCOA pod logs
kubectl logs -n open-cluster-management-observability \
  -l app=multicluster-observability-addon-manager --tail=50

# Check MCO operator logs for right-sizing
kubectl logs -n open-cluster-management \
  -l name=multicluster-observability-operator --tail=100 | grep -i "right-siz"

# List all RS-related resources on hub
# MCO mode:
kubectl get placement,placementdecision -n open-cluster-management-global-set | grep rs-
kubectl get policy -n open-cluster-management-global-set | grep rs-
# MCOA mode (in-memory predicates, ConfigMap-stored):
kubectl get configmap -n open-cluster-management-observability | grep rs-

# Check ManifestWork contents for a spoke
kubectl get manifestwork -n <spoke-name> -o json | \
  jq '.items[] | select(.metadata.name | test("observ")) |
      {name: .metadata.name, kinds: [.spec.workload.manifests[] | .kind]}'
```

---

## ManifestWork Stale PrometheusRules After Disabling Both RS Features

**Symptom**: In MCOA mode, disabling both RS features (namespace + virtualization) in the MCO CR leaves stale PrometheusRules in ManifestWorks. `rs-status` shows `ManifestWork PrometheusRules: 2` even though ADC has both RS keys set to `disabled`.

**Root cause**: MCOA's `BuildOptions()` in `options.go` only set `Platform.Enabled = true` when an RS key had the value `"enabled"`. When both keys were `"disabled"`, `Platform.Enabled` remained `false`. The rendering pipeline in `values.go` has an early return at line 53:
```go
if !opts.Platform.Enabled && !opts.UserWorkloads.Enabled {
    return addonfactory.JsonStructToValues(HelmChartValues{})
}
```
This returned empty `HelmChartValues`, which the addon framework interpreted as "nothing to render" — it left the existing ManifestWork untouched with stale PrometheusRules.

**Diagnosis**:
```bash
# Check if ManifestWork still has PrometheusRules after both RS features disabled
oc get manifestwork addon-multicluster-observability-addon-deploy-0 \
  -n <cluster-name> -o json | \
  jq '[.spec.workload.manifests[] | select(.kind=="PrometheusRule") |
       select(.metadata.name | test("acm-rs"))] | length'
# Expected: 0 (if both disabled). If > 0 with both disabled: staleness bug

# Check ADC state
oc get addondeploymentconfig multicluster-observability-addon \
  -n open-cluster-management-observability \
  -o jsonpath='{range .spec.customizedVariables[*]}{.name}={.value}{"\n"}{end}'
```

**Fix**: `options.go` now sets `Platform.Enabled = true` whenever an RS key is *present* in ADC, regardless of value (`"enabled"` or `"disabled"`). This ensures the rendering pipeline always runs and produces a manifest set (with or without PrometheusRules), allowing the addon framework to prune stale content.

---

## Placement Orphaning During MCO Deletion in MCOA Mode

> **Historical**: This issue applied when MCOA created Placement CRs. MCOA now uses in-memory predicate evaluation — no Placement CRs are created or orphaned.

**Symptom**: After MCO CR deletion in MCOA mode, RS Placements (`rs-placement`, `rs-virt-placement`) are recreated and orphaned in `open-cluster-management-global-set`. They persist even after the observability namespace is deleted.

**Root cause**: Race condition in the MCO analytics finalizer. The finalizer calls `CleanupRightSizingResources` (deletes Placements/ConfigMaps) but doesn't sync "disabled" to ADC first. During the race window between RS resource cleanup and CMA deletion, MCOA's `ReconcileRSResources` sees stale `"enabled"` values in ADC and recreates the Placements.

**Diagnosis**:
```bash
# Check for orphaned RS Placements after MCO deletion
oc get placement rs-placement rs-virt-placement \
  -n open-cluster-management-global-set 2>&1

# If they exist but MCO is deleted, they're orphaned
oc get mco observability 2>&1  # should be NotFound
```

**Fix**: The analytics finalizer now calls `syncRightSizingStateToADC(ctx, instance, false)` before `CleanupRightSizingResources`. This sets both RS ADC keys to `"disabled"` first, preventing MCOA from recreating resources during the cleanup window.

---

## Architecture Reference

| Mode | Deployment Mechanism | Cluster Selection | RS Signal |
|------|---------------------|-------------------|-----------|
| MCO (Policy) | Policy + PlacementBinding | Placement CRs in `open-cluster-management-global-set` | MCO CR capabilities |
| MCOA (ManifestWork) | ManifestWork via addon framework | In-memory predicate evaluation (predicates stored in ConfigMaps) | MCO CR annotation `right-sizing-capable` present |

| Component | Hub Namespace | Created By |
|-----------|--------------|------------|
| MCO Operator | `open-cluster-management` | MCH |
| MCOA Addon Manager | `open-cluster-management-observability` | MCO |
| RS Placements | `open-cluster-management-global-set` | MCO (Policy mode only) |
| RS ConfigMaps | `open-cluster-management-observability` | MCO or MCOA (shared, never deleted during mode switch) |
| RS Policies | `open-cluster-management-global-set` | MCO (Policy mode only) |
| RS ManifestWorks | per managed cluster namespace | MCOA (ManifestWork mode only) |
| CMA | cluster-scoped | MCO |
| ADC | `open-cluster-management-observability` | MCO |
