# Cluster Debug

Diagnose issues with ACM/MCO/MCE on the hub cluster. Systematically checks all layers before proposing fixes.

## Workflow

Work through the diagnostic steps below in order. Analyze each step's output before moving to the next.
Always check actual state first — never assume resource names or patterns.
Once you identify a likely root cause, stop further diagnostics and propose the fix immediately — continuing to run steps delays the user. Only investigate further if the fix doesn't resolve it or the user asks for more depth.

### Step 1: Cluster overview

```bash
oc --context=hub get mch -A --no-headers
oc --context=hub get mco -A --no-headers
oc --context=hub get mce -A --no-headers
oc --context=hub get nodes --no-headers
```

### Step 2: Operator health

```bash
oc --context=hub get csv -n open-cluster-management --no-headers
oc --context=hub get csv -n multicluster-engine --no-headers
oc --context=hub get pods -n open-cluster-management --no-headers | grep -v Running
oc --context=hub get pods -n open-cluster-management-observability --no-headers | grep -v Running
oc --context=hub get pods -n multicluster-engine --no-headers | grep -v Running
```

Report any pods not in Running state.

### Step 3: MCH/MCO conditions

If MCH exists, check conditions:

```bash
oc --context=hub get mch <name> -n open-cluster-management -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

If MCO exists, check conditions:

```bash
oc --context=hub get mco observability -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Look for: stuck `Installing`, `Terminating`, or error messages.

### Step 4: Observability pipeline health

Check specific observability deployments — pod count alone misses partially-ready deployments:

```bash
for dep in observability-rbac-query-proxy observability-grafana observability-observatorium-api \
           observability-thanos-query observability-thanos-compact \
           observability-thanos-receive-default observability-thanos-rule; do
  oc --context=hub get deployment "$dep" -n open-cluster-management-observability \
    -o jsonpath="{.metadata.name}: {.status.readyReplicas}/{.spec.replicas}" 2>/dev/null
  echo
done
```

Check critical secrets:

```bash
oc --context=hub get secret thanos-object-storage -n open-cluster-management-observability --no-headers 2>/dev/null
```

If `thanos-object-storage` is missing, MCO cannot start — object storage must be configured before install. See `bin/setup-observability install`.

**IsMCOTerminating stale flag**: After MCO deletion, the operator caches a terminating flag in memory. If MCO reinstall hangs or conditions show stale state, restart the operator pod:

```bash
oc --context=hub delete pod -n open-cluster-management -l name=multicluster-observability-operator
```

Or use the shortcut: `bin/setup-observability status` shows the full pipeline health in one command.

### Step 5: MCOA addon health

Check MCOA deployment and addon status:

```bash
# MCOA deployment
oc --context=hub get deployment multicluster-observability-addon-manager \
  -n open-cluster-management-observability --no-headers

# ManagedClusterAddon (one per managed cluster)
oc --context=hub get managedclusteraddon -A --no-headers | grep multicluster-observability-addon

# AddOnDeploymentConfig (ADC) — controls MCOA feature flags
oc --context=hub get addondeploymentconfig multicluster-observability-addon \
  -n open-cluster-management-observability \
  -o jsonpath='{.spec.customizedVariables}' 2>/dev/null | python3 -m json.tool
```

**specHash validation**: If MCOA is deployed but ManifestWorks are not created, check for empty specHash — MCOA silently skips ManifestWork creation when the addon framework hasn't computed a specHash:

```bash
oc --context=hub get managedclusteraddon multicluster-observability-addon -n <cluster> \
  -o jsonpath='{.status.configReferences[?(@.name=="multicluster-observability-addon")].desiredConfig.specHash}'
```

An empty specHash means the addon framework hasn't reconciled the ADC yet. Restart MCOA:

```bash
oc --context=hub rollout restart deployment/multicluster-observability-addon-manager \
  -n open-cluster-management-observability
```

### Step 6: MCH stuck Uninstalling

If MCH is stuck in `Uninstalling`, check components:

```bash
oc --context=hub get mch <name> -n open-cluster-management -o jsonpath='{.status.components}' | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'{k}: {v[\"message\"]}') for k,v in d.items() if v.get('status','') != 'True']"
```

Common blocker: `hypershift-addon` MCA with stale lease. Check:

```bash
oc --context=hub get managedclusteraddon -A --no-headers
oc --context=hub get lease -n open-cluster-management-agent-addon --no-headers
```

### Step 7: Namespace stuck Terminating

If any namespace is stuck in Terminating:

```bash
oc --context=hub get ns <namespace> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Check for resources with finalizers blocking deletion:

```bash
oc --context=hub api-resources --verbs=list --namespaced -o name | xargs -I {} oc --context=hub get {} -n <namespace> --no-headers 2>/dev/null | head -20
```

### Step 8: ManagedCluster health

```bash
oc --context=hub get managedcluster --no-headers
oc --context=hub get managedclusteraddon -A --no-headers
```

If any ManagedCluster shows `Available: Unknown`, this commonly happens after hibernating and resuming SNO dev clusters. Check for stale `bootstrap-hub-kubeconfig`:

```bash
# Check lease renewal time (should be within last few minutes)
oc --context=hub get lease managed-cluster-lease -n <cluster-name> -o jsonpath='{.spec.renewTime}'

# Check what hub the klusterlet thinks it's talking to.
# For local-cluster only, the spoke and hub are the same context.
oc --context=<spoke-ctx> get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep "server:"

# Compare with actual hub API
oc --context=hub cluster-info | head -1
```

If the server URLs don't match, the klusterlet is registered with a **previous hub**. Fix with `add-managed-cluster`:
```bash
# For spoke clusters:
bin/add-managed-cluster add <spoke-ctx> --force-import

# For local-cluster:
bin/add-managed-cluster add hub --force-import
```

This does a full klusterlet cleanup (delete klusterlet CR, namespaces, CRD, RBAC) and re-applies import manifests. Simple secret deletion is NOT enough — the old klusterlet's work agent re-poisons the bootstrap secret from ManifestWorks on the old hub.

### Step 9: ManagedClusterAddon CRD stuck terminating

If Step 8 shows `managedclusteraddon` resources missing or "server could not find the requested resource":

```bash
# Check if CRD is terminating (non-empty deletionTimestamp = stuck)
oc --context=hub get crd managedclusteraddons.addon.open-cluster-management.io \
  -o jsonpath='{.metadata.deletionTimestamp}'

# Check for stuck instances with finalizers blocking CRD deletion
oc --context=hub get managedclusteraddon -A --no-headers 2>/dev/null

# Check addon controller logs
oc --context=hub logs -n open-cluster-management-hub \
  -l app=cluster-manager-addon-manager-controller --tail=20 2>/dev/null | grep -i "terminating"
```

A terminating CRD blocks ALL addon creation hub-wide. Fix:

1. Patch out finalizers on stuck instances:
   ```bash
   for addon in $(oc --context=hub get managedclusteraddon -n <stuck-namespace> -o name 2>/dev/null); do
     oc --context=hub patch $addon -n <stuck-namespace> --type=merge \
       -p '{"metadata":{"finalizers":null}}'
   done
   ```

2. Wait for CRD to finish deleting, then restart cluster-manager to re-create it:
   ```bash
   oc --context=hub rollout restart deploy/cluster-manager -n multicluster-engine
   oc --context=hub rollout status deploy/cluster-manager -n multicluster-engine --timeout=120s
   ```

3. Restart addon controllers (informers are stuck after CRD was missing):
   ```bash
   oc --context=hub delete pod -n open-cluster-management-hub --all
   oc --context=hub delete pod -n open-cluster-management -l component=klusterlet-addon-controller
   ```

4. Verify CRD is back and addons are being created:
   ```bash
   oc --context=hub get crd managedclusteraddons.addon.open-cluster-management.io
   oc --context=hub get managedclusteraddon -n <cluster-name> --no-headers
   ```

### Step 10: Stuck ManifestWorks (local-cluster)

If MCOA is not creating ManifestWorks or COO is not installed:

```bash
# Check for ManifestWorks stuck in Deleting
oc --context=hub get manifestwork -n local-cluster -o json | \
  jq '.items[] | select(.metadata.deletionTimestamp) |
      {name: .metadata.name, deletionTimestamp: .metadata.deletionTimestamp,
       finalizers: .metadata.finalizers}'
```

This is a self-referential deadlock on `local-cluster` — the work-agent can't confirm cleanup during MCO teardown because the hub IS the spoke. Common during repeated install/uninstall cycles.

Fix with setup-observability:
```bash
bin/setup-observability install --force-cleanup-mw
```

Or manually:
```bash
oc --context=hub patch manifestwork <name> -n local-cluster \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
oc --context=hub rollout restart deployment/multicluster-observability-addon-manager \
  -n open-cluster-management-observability
```

### Step 11: Image override not taking effect

If custom images are not being picked up after `bin/image-override apply`:

```bash
# Check current pod images
oc --context=hub get pod -n open-cluster-management \
  -l name=multicluster-observability-operator \
  -o jsonpath='{.items[0].spec.containers[0].image}'

oc --context=hub get pod -n open-cluster-management-observability \
  -l app=multicluster-observability-addon-manager \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# Check MCH phase — Pending state blocks ConfigMap-based overrides
oc --context=hub get mch -n open-cluster-management -o jsonpath='{.items[0].status.phase}'
```

**MCH in Pending state**: MCH won't reconcile image overrides to deployments. Patch deployments directly:

```bash
oc --context=hub set image deployment/multicluster-observability-operator \
  -n open-cluster-management multicluster-observability-operator="<registry>/<image>:<tag>"
```

**MCOA image source**: MCO reads the MCOA image from `mch-image-manifest-*` ConfigMap in `open-cluster-management`, NOT from the `image-override` ConfigMap. Check and patch:

```bash
# Find the manifest ConfigMap
MANIFEST_CM=$(oc --context=hub get configmap -n open-cluster-management --no-headers | awk '/^mch-image-manifest/{print $1}' | tail -1)

# Check current MCOA image in manifest
oc --context=hub get configmap "$MANIFEST_CM" -n open-cluster-management \
  -o jsonpath='{.data.multicluster_observability_addon}'

# Patch if needed
oc --context=hub patch configmap "$MANIFEST_CM" -n open-cluster-management --type merge \
  -p '{"data":{"multicluster_observability_addon":"<registry>/<image>:<tag>"}}'
```

MCH uses `imagePullPolicy: IfNotPresent` — always increment the image tag when rebuilding, never reuse tags.

### Step 12: COO/Perses not working

If Perses dashboards are not appearing or COO is not installed:

```bash
# Check COO operator CSV (installed via OLM in openshift-operators)
oc --context=hub get csv -n openshift-operators --no-headers 2>/dev/null | grep cluster-observability-operator

# Check COO pods (run in their own namespace)
oc --context=hub get pods -n openshift-cluster-observability-operator --no-headers 2>/dev/null

# Check UIPlugin
oc --context=hub get uiplugin monitoring --no-headers 2>/dev/null

# Check Perses dashboards
oc --context=hub get persesdashboard -A --no-headers 2>/dev/null

# Check PersesDatasource
oc --context=hub get persesdatasource -A --no-headers 2>/dev/null
```

COO is installed by MCOA via ManifestWork. If COO is missing, check MCOA health (Step 5) and stuck ManifestWorks (Step 10) first.

### Step 13: OLM Subscription issues

ACM registers its own `Subscription` CRD under `apps.open-cluster-management.io`, causing API group collision with OLM's `operators.coreos.com` Subscription. Always use the fully-qualified resource:

```bash
# WRONG — may hit ACM's Subscription CRD
oc --context=hub get subscription -n <namespace>

# CORRECT — targets OLM subscriptions
oc --context=hub get subscription.operators.coreos.com -n <namespace>
```

Check OLM subscription health:

```bash
# ACM subscription
oc --context=hub get subscription.operators.coreos.com -n open-cluster-management --no-headers

# Verify channel exists in package manifest before creating/updating
oc --context=hub get packagemanifest advanced-cluster-management \
  -o jsonpath='{.status.channels[*].name}'
```

### Step 14: Analysis and recommendations

After gathering all data:
1. Identify the root cause
2. Propose a fix with the exact commands
3. Ask for confirmation before running any destructive fix (delete finalizers, force-delete resources, etc.)

**Available diagnostic tools** — use these before manual investigation:

| Tool | Purpose |
|------|---------|
| `bin/setup-observability status` | Full observability pipeline health (MCO, pods, storage, managed clusters) |
| `bin/install-custom-acm status` | ACM/MCE install status and operator health |

## Important notes

- Default to `--context=hub` for hub diagnostics; use the spoke context only for commands that explicitly repair or inspect spoke-side klusterlet resources.
- Check actual state BEFORE proposing fixes
- Never delete finalizers or force-delete without user confirmation
- Common issues: stale leases, orphaned CRs, stuck MCA finalizers, missing CRDs
- Propose the fix as soon as you find a likely root cause — do not run all steps first
