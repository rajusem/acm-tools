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

## Cluster Unreachable After Hibernate/Resume (Pending CSRs)

**Symptom**: After resuming hibernated ClusterPool clusters (via ACM console or cronjob), the console URLs return `SSL_ERROR_SYSCALL` or connection refused. The API server (port 6443) may still respond, but `*.apps` routes on port 443 do not. The ClusterDeployment may misleadingly show `Ready: True` / `Unreachable: False` even though the console is not accessible — these conditions reflect API server reachability (port 6443), not ingress/console health.

**Root cause**: During hibernation, kubelet client certificates and internal signing CAs (CSR signer, aggregator client signer) expire. On resume, kubelets fall back to the bootstrap token (`node-bootstrapper` service account) and request new certificates via CSRs. The `cluster-machine-approver` cannot auto-approve these because:

- **Missing Machine objects**: Some ClusterPool-provisioned SNO clusters (e.g., `obsint-sno-4xlarge-*`) have no Machine resources in `openshift-machine-api`, so the machine-approver has nothing to validate CSRs against.
- **Bootstrap re-enrollment**: The CSR requestor is `node-bootstrapper` (not the kubelet), which the machine-approver treats more cautiously.

This cascades: kubelet TLS broken → API server can't talk to kubelets → OVN/CNI restarts → console pods not ready → ingress router can't serve traffic through the ELB.

**Diagnosis**:
```bash
# 1. Check ClusterDeployment status from hub (may show Ready even when console is broken)
CD_NAME="<cluster-name>"  # e.g., obsint-sno-4xlarge-422-22vct (same as namespace)
oc get clusterdeployment "$CD_NAME" -n "$CD_NAME" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'

# 2. Extract admin kubeconfig and API/console URLs from ClusterDeployment
KUBECONFIG_SECRET=$(oc get clusterdeployment "$CD_NAME" -n "$CD_NAME" \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')
oc get secret "$KUBECONFIG_SECRET" -n "$CD_NAME" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/kubeconfig-spoke

API_URL=$(oc get clusterdeployment "$CD_NAME" -n "$CD_NAME" \
  -o jsonpath='{.status.apiURL}')
CONSOLE_URL=$(oc get clusterdeployment "$CD_NAME" -n "$CD_NAME" \
  -o jsonpath='{.status.webConsoleURL}')

# 3. Verify API server responds but console doesn't
curl -sk -o /dev/null -w "API: %{http_code}\n" "${API_URL}/healthz"        # expect 200
curl -sk -o /dev/null -w "Console: %{http_code}\n" "${CONSOLE_URL}"        # expect 000

# 4. Check for pending CSRs (the smoking gun)
KUBECONFIG=/tmp/kubeconfig-spoke oc get csr | grep Pending

# 5. Verify kubelet TLS is broken (confirms CSR issue is the cause)
KUBECONFIG=/tmp/kubeconfig-spoke oc logs -n openshift-ingress deploy/router-default --tail=1
# Expected error: "tls: internal error" or "certificate signed by unknown authority"

# 6. Check if Machine objects exist (explains why auto-approve failed)
KUBECONFIG=/tmp/kubeconfig-spoke oc get machines -n openshift-machine-api
```

**Fix**:
```bash
export KUBECONFIG=/tmp/kubeconfig-spoke

# Step 1: Approve all pending CSRs (Round 1 — kubelet client certs)
oc get csr --no-headers | grep Pending | awk '{print $1}' | \
  xargs oc adm certificate approve

# Step 2: Wait 15-30 seconds for kubelet serving cert CSRs to appear (Round 2)
sleep 20
oc get csr --no-headers | grep Pending

# Step 3: Approve Round 2 CSRs (kubelet-serving + any addon CSRs)
oc get csr --no-headers | grep Pending | awk '{print $1}' | \
  xargs oc adm certificate approve

# Step 4: Wait for kube-apiserver to roll out with new CA bundles (1-2 minutes)
# During hibernation, internal signing CAs (CSR signer, aggregator-client) also expire.
# The cert-recovery-controller regenerates them automatically on resume.
# The kube-apiserver-operator detects new CAs and rolls out a new static pod revision.
# During rollout, API server briefly goes unavailable — this is expected.
sleep 60

# Step 5: Verify recovery
curl -sk -o /dev/null -w "API: %{http_code}\n" "${API_URL}/healthz"
curl -sk -o /dev/null -w "Console: %{http_code}\n" "${CONSOLE_URL}"
oc get co --no-headers | awk '{print $1, $3, $4, $5}'

# Step 6: Check for any remaining pending CSRs (repeat steps 1-3 until none)
oc get csr --no-headers | grep Pending

# Cleanup
unset KUBECONFIG
rm -f /tmp/kubeconfig-spoke
```

**What happens during recovery**: After approving CSRs, expect a cascade of restarts over 1-2 minutes:
1. Kubelet gets new client cert → re-registers with API server
2. Kubelet gets new serving cert → API server can talk to kubelet again
3. Expired signing CAs (CSR signer, aggregator client) are regenerated by cert-recovery-controller
4. kube-apiserver-operator detects new CAs → rolls out new static pod revision (API briefly unavailable)
5. OVN/CNI pods restart → console pods restart → readiness probes pass
6. Ingress router serves traffic through ELB again

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

## Never use `oc delete ip` (InstallPlan vs IPAddress)

**Symptom**: After a typed `oc delete ip --all` (intending OLM InstallPlans), cluster networking breaks — `IPAddress` objects from `networking.k8s.io` are deleted cluster-wide. Hub API / console can become unreachable for hours.

**Root cause**: The short resource name `ip` matches `ipaddress.networking.k8s.io`, **not** `installplan.operators.coreos.com`.

**Fix / prevention**:
```bash
# WRONG — deletes IPAddress CRs
oc delete ip --all

# RIGHT — always use the fully qualified OLM resource
oc get installplan.operators.coreos.com -A
oc delete installplan.operators.coreos.com <name> -n <namespace>
```

`install-custom-acm` never uses the short name `ip`. Do not add it to scripts or runbooks.

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

**See also**: [MCO Operator Deadlocked by Stuck MCOA ManagedClusterAddon](#mco-operator-deadlocked-by-stuck-mcoa-managedclusteraddon) — individual MCA instances (not the CRD) stuck with finalizers can also deadlock MCO.

---

## MCO Operator Deadlocked by Stuck MCOA ManagedClusterAddon

**Symptom**: MCO operator logs show "Waiting for MCOA ManifestWorks to be deleted" and never progresses. No `ObservabilityAddon` CRs are created on any managed cluster. MCOA addon-manager logs show "ClusterManagementAddOn not found". The hub-wide observability pipeline is blocked — no spoke receives metrics-collector.

**Root cause**: A `ManagedClusterAddon` for `multicluster-observability-addon` on an unreachable managed cluster has a pre-delete finalizer (`addon.open-cluster-management.io/pre-delete`) that cannot complete because the spoke is unreachable. This keeps the MCOA ManifestWorks alive, and the MCO operator sees them and refuses to proceed — creating a hub-wide deadlock that affects ALL managed clusters, not just the unreachable one.

Common triggers:
- QE test clusters with fake API URLs (e.g., `https://acmqe-*.com`)
- Managed clusters that were hibernated or decommissioned without proper cleanup
- Spoke clusters whose API server is temporarily down during addon uninstall

**Diagnosis**:

```bash
# 1. Check MCO operator logs for the deadlock message
oc logs -n open-cluster-management \
  -l name=multicluster-observability-operator --tail=20 | \
  grep -i "ManifestWork"

# 2. Find MCAs with deletionTimestamp (stuck deleting)
oc get managedclusteraddon -A -o json | \
  jq '.items[] | select(.metadata.deletionTimestamp) |
      {ns: .metadata.namespace, name: .metadata.name,
       since: .metadata.deletionTimestamp, finalizers: .metadata.finalizers}'

# 3. Check if the managed cluster is reachable
oc get managedcluster <cluster-name> -o jsonpath='{.status.conditions}' | \
  python3 -m json.tool
# Look for Available: False or Unknown

# 4. Verify ManifestWorks are being recreated (MCOA keeps recreating them)
oc get manifestwork -n <cluster-name> --no-headers | \
  grep addon-multicluster-observability-addon
```

**Fix**:

1. **Patch out the finalizer** on the stuck MCA (safe if the spoke is unreachable):
   ```bash
   oc patch managedclusteraddon multicluster-observability-addon \
     -n <stuck-cluster-namespace> --type=merge \
     -p '{"metadata":{"finalizers":null}}'
   ```

2. The stale ManifestWorks clear automatically once the MCA is deleted. MCO operator unblocks within seconds and begins creating `ObservabilityAddon` CRs on all healthy clusters.

3. **Verify recovery**:
   ```bash
   # MCO operator should stop logging the deadlock message
   oc logs -n open-cluster-management \
     -l name=multicluster-observability-operator --tail=5

   # ObservabilityAddons should appear on healthy clusters
   oc get observabilityaddon -A --no-headers

   # metrics-collector pods should start on spokes
   oc --context=<spoke-ctx> get pods -n open-cluster-management-addon-observability \
     --no-headers | grep metrics-collector
   ```

**Prevention**: Before removing a managed cluster, ensure its addons are cleanly uninstalled. If a cluster becomes permanently unreachable, remove its `ManagedCluster` CR from the hub — this triggers addon cleanup. If cleanup hangs, patch out finalizers on the stuck MCAs.

**See also**: [ManagedClusterAddon CRD Stuck Terminating](#managedclusteraddon-crd-stuck-terminating) — for the case where the entire CRD (not individual instances) is stuck terminating.

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

**See also**: [COO Namespace Stuck Terminating on Perses Finalizer](#coo-namespace-stuck-terminating-on-perses-finalizer) — if COO never installs because its namespace is deadlocked.

---

## COO Namespace Stuck Terminating on Perses Finalizer

**Symptom**: Right-sizing appears "not enabled by default" even though **all configuration is correct** — the MCO CR spec has both RS features `enabled: true`, the ADC has `rightSizingDelegated=true` with both RS keys `enabled`, and the ManifestWork was delivered. But the `multicluster-observability-addon` ManagedClusterAddon on `local-cluster` shows `Available=False` ("N of 18 resources are not available") and `ManifestApplied=False` ("failed to apply the manifests of addon"). The Cluster Observability Operator (COO) never installs, so no Perses dashboards or UIPlugin appear.

The failing manifests are the COO `OperatorGroup` and `Subscription`, both with:
```
forbidden: unable to create new content in namespace
  openshift-cluster-observability-operator because it is being terminated
```

**Root cause**: Finalizer deadlock. The `openshift-cluster-observability-operator` namespace is stuck in `Terminating` because a leftover `Perses` CR (`perses.perses.dev`) still holds `perses.dev/finalizer`. The controller that clears that finalizer — the `perses-operator` — runs *inside that same namespace*, so once namespace deletion begins the operator is torn down and can never process the finalizer. The namespace is blocked forever, which blocks MCOA from recreating the `OperatorGroup`/`Subscription`, which blocks COO reinstall, which blocks all right-sizing dashboards/UIPlugin.

Common triggers: disabling right-sizing, COO uninstall/reinstall churn, or the COO namespace being deleted while the `Perses` CR still exists — frequent in dev/test install-uninstall cycles.

**Secondary blocker**: The namespace may *also* be held by a transient `NamespaceDeletionDiscoveryFailure` (e.g. `metrics.k8s.io/v1beta1: stale GroupVersion discovery`) when an aggregated APIService is briefly unavailable. This usually self-resolves once the backing APIService reports `Available=True`; the namespace controller retries on its own.

**Diagnosis**:
```bash
# 1. Namespace stuck Terminating, and WHY (conditions name the blocker)
oc get ns openshift-cluster-observability-operator \
  -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}: {.message}{"\n"}{end}'
# Look for: NamespaceContentRemaining "perses.perses.dev has 1 resource instances"
#           NamespaceFinalizersRemaining "perses.dev/finalizer in 1 resource instances"

# 2. Find the stuck Perses CR and confirm its finalizer
oc get perses.perses.dev -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} finalizers={.metadata.finalizers} deletionTimestamp={.metadata.deletionTimestamp}{"\n"}{end}'

# 3. Confirm NO perses-operator pod is running anywhere (nothing will clear the finalizer)
oc get pods -A | grep -iE "perses|observability-operator"

# 4. See the exact addon failure
oc get manifestwork addon-multicluster-observability-addon-deploy-0 -n local-cluster -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['resourceMeta']['kind'], m['resourceMeta'].get('namespace',''), m['resourceMeta']['name'], '->', [c['message'] for c in m.get('conditions',[]) if c['status']=='False']) for m in d['status']['resourceStatus']['manifests'] if any(c['status']=='False' for c in m.get('conditions',[]))]"
```

**Fix**: Remove the finalizer from the stuck `Perses` CR. This is safe when the perses-operator is gone and the namespace is already being deleted — the CR is orphaned and nothing else will ever act on it.
```bash
oc patch perses.perses.dev/perses -n openshift-cluster-observability-operator \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
```

The recovery then self-heals — no operator restarts needed:
1. Namespace finishes deleting (seconds to a couple minutes).
2. MCOA's ManifestWork recreates the `Namespace`, `OperatorGroup`, and `Subscription` on its next reconcile.
3. OLM installs COO (CSV reaches `Succeeded`); `perses-operator`, `perses-0`, and `monitoring` pods start.
4. Perses dashboards, datasources, and the `monitoring` UIPlugin apply; the addon flips to `Available=True`.

**Verify**:
```bash
# Namespace deletes, then MCOA recreates it Active
oc get ns openshift-cluster-observability-operator

# COO installs
oc get csv -n openshift-cluster-observability-operator | grep observability   # -> Succeeded
oc get pods -n openshift-cluster-observability-operator                        # perses-operator, perses-0, monitoring Running

# Right-sizing resources land
oc get persesdashboard -n observability-analytics
oc get uiplugin monitoring
oc get prometheusrule -n openshift-monitoring | grep acm-rs

# Addon healthy
oc get managedclusteraddon multicluster-observability-addon -n local-cluster \
  -o jsonpath='{range .status.conditions[?(@.type=="Available")]}Available={.status}{"\n"}{end}'
```

**Prevention**: This deadlock recurs any time the COO namespace is deleted while the `Perses` CR still carries its finalizer. When intentionally tearing down COO/right-sizing, delete the `Perses` CR (and let the perses-operator finalize it) *before* the namespace goes, or remove the finalizer as above once the operator is gone.

**See also**: [Perses Not Deploying](#perses-not-deploying) — for other reasons Perses dashboards may be absent when the COO namespace is healthy.

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

---

## Thanos Receive PVC Full / Bucket Quota Exceeded

**Symptom**: MCO shows `Failed` with `StatefulSetNotReady`. One or more `observability-thanos-receive-default-*` pods are `0/1` with hundreds of restarts. RS Policies may disappear. No new metrics reach Thanos.

**Root cause**: The MinIO/S3 bucket backing object storage hit its quota. Thanos receive can't upload blocks → local TSDB fills the PVC → pod crashes → StatefulSet not ready → MCO Failed.

**Diagnosis**:
```bash
# Check receive pods
oc get pods -n open-cluster-management-observability -l app.kubernetes.io/name=thanos-receive

# Check compact for bucket errors
oc logs -n open-cluster-management-observability -l app.kubernetes.io/name=thanos-compact --tail=10 | grep 'Bucket quota'

# Check receive for upload errors
oc logs -n open-cluster-management-observability -l app.kubernetes.io/name=thanos-receive --tail=10 | grep 'Bucket quota'

# Check PVC usage
oc exec observability-thanos-receive-default-2 -n open-cluster-management-observability -- df -h /var/thanos/receive
```

**Fix**: Increase the MinIO bucket quota or reduce retention to free space. The bucket quota must be increased first — without it, receive and compact can't upload regardless of PVC size.

```bash
# Option 1: Increase bucket quota (from MinIO admin)
mc admin bucket quota <alias>/acm-obs-bucket --hard 500Gi

# Option 2: Reduce retention to purge old data from the bucket
oc patch mco observability --type merge -p '{
  "spec": {
    "advanced": {
      "retentionConfig": {
        "retentionResolutionRaw": "3d",
        "retentionResolution5m": "14d",
        "retentionResolution1h": "21d"
      }
    }
  }
}'
```

After the bucket has space, compact will resume uploading and receive PVCs will free up as local TSDB retention cleans old data.

---

## Thanos Compact Crash — retentionResolution5m Too Low

**Symptom**: `observability-thanos-compact-0` is in `CrashLoopBackOff`. Logs show: `5m resolution retention must be higher than the minimum block size after which 1h resolution downsampling will occur (10 days)`.

**Root cause**: Thanos requires `retentionResolution5m` to be **greater than 10 days** because 1h downsampling creates blocks of up to 10 days. Setting it to `7d` or `10d` causes compact to refuse to start.

**Fix**: Set `retentionResolution5m` to at least `11d` (recommended `14d`):
```bash
oc patch mco observability --type merge -p '{"spec":{"advanced":{"retentionConfig":{"retentionResolution5m":"14d"}}}}'

# Delete the crash-looping pod to pick up the new config immediately
oc delete pod observability-thanos-compact-0 -n open-cluster-management-observability
```

---

## Spoke Metrics Not Reaching Hub (enableMetrics: false)

**Symptom**: Spoke cluster is `Available`, RS PrometheusRules exist on the spoke, but no RS metrics appear in hub Thanos. The `open-cluster-management-addon-observability` namespace on the spoke is empty (no metrics-collector pod).

**Root cause**: The `ObservabilityAddon` CR for the spoke has `enableMetrics: false`. The `endpoint-observability-operator` won't deploy the metrics-collector when this is false.

**Diagnosis**:
```bash
# Check enableMetrics for a specific spoke
oc get observabilityaddon observability-addon -n <spoke-name> -o jsonpath='{.spec.enableMetrics}'

# Check all spokes
for cluster in $(oc get observabilityaddon -A --no-headers | awk '{print $1}'); do
  enabled=$(oc get observabilityaddon observability-addon -n "$cluster" -o jsonpath='{.spec.enableMetrics}')
  echo "  $cluster: enableMetrics=$enabled"
done
```

**Fix**: If metrics should be enabled:
```bash
oc patch observabilityaddon observability-addon -n <spoke-name> --type merge -p '{"spec":{"enableMetrics":true}}'
```

Note: `enableMetrics: false` may be intentionally set by the cluster admin. Verify before changing.

---

## Stale MCO Operator Pod (In-Memory Cache Drift)

**Symptom**: MCO shows `Ready=True` but RS Policies are missing, metrics-collector not deployed on spokes, or ManifestWorks not being updated. The operator logs show `"already existed/unchanged"` for resources that don't actually exist. Toggling RS features or mode switching doesn't trigger reconciliation.

**Root cause**: Long-running MCO operator pods (weeks/months) accumulate stale in-memory state. The controller's informer cache drifts from actual cluster state, especially after infrastructure disruptions (disk pressure, Thanos crashes, node restarts). The operator believes resources exist because its cache says so, but they were deleted externally.

**Diagnosis**:
```bash
# Check operator pod age
oc get pods -n open-cluster-management -l name=multicluster-observability-operator \
  -o jsonpath='{.items[0].metadata.creationTimestamp}'

# Check if operator is producing any logs
oc logs -n open-cluster-management -l name=multicluster-observability-operator --since=5m | wc -l
# If 0 lines: controller is completely unresponsive

# Check RS controller activity
oc logs -n open-cluster-management -l name=multicluster-observability-operator --since=10m | grep 'rs -'
```

**Fix**:
```bash
oc rollout restart deployment/multicluster-observability-operator -n open-cluster-management
```

This forces a fresh informer cache sync and triggers reconciliation of all resources including RS Policies, ManifestWorks, and observability addon deployments.

---

## Kyverno Policy CRD Collision (RS Policies Not Visible)

**Symptom**: `oc get policy -n open-cluster-management-global-set` shows no RS Policies, but the MCO operator logs confirm they were created. RS features appear broken when they're actually working.

**Root cause**: Kyverno registers its own `Policy` CRD (`policies.kyverno.io`). When both Kyverno and ACM Policy are installed, `oc get policy` resolves to Kyverno's CRD instead of ACM's `policies.policy.open-cluster-management.io`.

**Diagnosis**:
```bash
# Check which CRD "policy" resolves to
oc api-resources | grep -i policy

# Query ACM policies explicitly
oc get policy.policy.open-cluster-management.io -n open-cluster-management-global-set
```

**Fix**: Always use the fully-qualified resource name on clusters with Kyverno:
```bash
# Instead of:
oc get policy -n open-cluster-management-global-set

# Use:
oc get policy.policy.open-cluster-management.io -n open-cluster-management-global-set
```

---

## Node Disk Pressure Blocking Observability Pods

**Symptom**: Observability pods (MinIO, Thanos compact, Grafana) stuck in `Pending`. Node shows `disk-pressure` taint. MCO shows `Failed` with `DeploymentNotReady`.

**Root cause**: Node disk full — commonly from accumulated stale pods (hundreds of `ContainerStatusUnknown` pods from repeated crashes/restarts), container images, or PVC data.

**Diagnosis**:
```bash
# Check node taint
oc get nodes -o jsonpath='{.items[0].spec.taints}'

# Count stale pods
oc get pods -A --no-headers | grep -c 'Unknown\|ContainerStatusUnknown'
```

**Fix**:
```bash
# Clean stale pods
oc delete pods --field-selector=status.phase==Failed -A --force --grace-period=0
oc delete pods --field-selector=status.phase==Succeeded -A --force --grace-period=0

# If observability is severely broken, uninstall and reinstall cleanly
echo "y" | bin/setup-observability uninstall
bin/setup-observability install
```

## Forcing VM Right-Sizing UNDERestimation (Fixture Design)

The RS dashboard's **Underestimation** stat/table panels fire when
`floor(request - recommendation) < 0`, i.e. when `usage > request / 1.1` (~90.9% utilization,
since `recommendation = usage × 1.1`). Getting a VM to underestimate *consistently* is subtle
because of how the KubeVirt recording rules define request and usage:

- `acm_rs_vm:namespace:memory_request = max by(name,namespace)(kubevirt_vm_resource_requests{resource="memory"})`.
  KubeVirt emits three `source` variants (`domain` = `resources.requests.memory`, `guest`,
  `guest_effective`) and `max()` **always picks the guest RAM**. Lowering
  `resources.requests.memory` is therefore *ignored* — the RS request equals `domain.memory.guest`.
- `acm_rs_vm:namespace:memory_usage = sum(kubevirt_vmi_memory_available_bytes - kubevirt_vmi_memory_usable_bytes)`
  (guest-reported "used"). Memory underestimation thus requires guest usage > ~90.9% of guest RAM
  → intrinsically **near-OOM**. For a 4Gi guest the underest window is only ~3.64–3.71 GiB wide.
- `acm_rs_vm:namespace:cpu_request = count(kubevirt_vmi_vcpu_seconds_total)` = **guest vCPU count**
  (NOT `resources.requests.cpu`); set by `domain.cpu.cores`. `cpu_usage` is capped at that count.

**Deterministic fixtures** (`manifests/workloads/vm/`, deployed by `bin/rs-e2e` phase 18, asserted
in phase 21a):

- `fedora-vm-cpu-underest.yaml` (`cpu-underest-vm`): 1 guest vCPU pegged by a base-image shell
  busy loop (`while :; do :; done`) → cpu usage → 1.0, reco 1.1, `floor(1 - 1.1) = -1`. Keep guest
  memory small/unpressured (2Gi) so the loop is not starved of cycles.
- `fedora-vm-mem-underest.yaml` (`mem-underest-vm`): 4Gi guest filled with **anonymous** memory
  (`python3 -c "a=bytearray(3400*1024*1024)"`, python3 ships in the fedora cloud image). 3400 MiB
  is the validated sweet spot — usage lands ~3.70 GiB (~65 MiB over the threshold) with ~110 MiB
  headroom.

**Pitfalls that cause non-determinism** (all learned the hard way):

- **`dnf install stress-ng`** — network-dependent, silently fails on a spoke without egress → the
  workload never runs. Use base-image-only workloads (shell loop / python3).
- **tmpfs / page-cache fill** (`mount -t tmpfs` + `dd`) — drifts over time and straddles the
  90.9% threshold (three identical VMs after 16h landed 3.674 / 3.666 / 3.544 GiB = 2 underest +
  1 ideal). Anonymous `bytearray` is resident and does not drift.
- **Combining CPU + memory load in one single-vCPU VM** — memory pressure (tight ~110 MiB free)
  steals cycles from the CPU loop, capping cpu usage ~0.73 and flipping CPU to *over*estimation.
  Use **separate** fixtures for CPU-underest and memory-underest.

> Note: phase 21 uses the *ratio* classifier (`ratio > 1.2` = underestimated), under which VM
> underestimation can never register (max ratio = 1.1). The floor-based panels above are validated
> in phase 21a instead.
