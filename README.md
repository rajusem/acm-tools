# acm-tools

CLI utilities for managing ACM (Advanced Cluster Management) observability and right-sizing development workflows.

## Prerequisites

- `oc` or `kubectl` in PATH
- `jq` for JSON processing
- `podman` or `docker` for image builds (used by config auto-detection)
- Kubeconfig contexts configured for hub and spoke clusters

## Configuration

### Setting up cluster contexts

The tools use named kubeconfig contexts to switch between hub and spoke clusters. Log in to each cluster and rename the context to a short name:

```bash
# Hub cluster
oc login --token=sha256~XXXX --server=https://api.<hub-cluster>:6443
oc config delete-context hub 2>/dev/null; oc config rename-context $(oc config current-context) hub

# Namespace spoke cluster
oc login --token=sha256~XXXX --server=https://api.<namespace-spoke-cluster>:6443
oc config delete-context namespace-spoke 2>/dev/null; oc config rename-context $(oc config current-context) namespace-spoke

# VM spoke cluster (optional, defaults to hub context)
oc login --token=sha256~XXXX --server=https://api.<vm-spoke-cluster>:6443
oc config delete-context vm-spoke 2>/dev/null; oc config rename-context $(oc config current-context) vm-spoke

# Switch back to hub
oc config use-context hub
```

Verify your contexts:

```bash
oc config get-contexts
```

Context names default to `hub`, `namespace-spoke`, and `vm-spoke`. Override via environment variables or `config.sh`:

```bash
export HUB_CONTEXT="hub"                        # default: hub
export NAMESPACE_SPOKE_CONTEXT="namespace-spoke" # default: namespace-spoke
export VM_SPOKE_CONTEXT="vm-spoke"               # default: hub (if no separate VM spoke)
```

## Tools

### install-custom-acm

Install or manage ACM on a hub cluster via OLM. Supports merging quay.io pull secrets and applying custom CatalogSources for pre-release builds.

```bash
bin/install-custom-acm                                    # Install ACM 2.16 + MCE 2.11 (defaults)
bin/install-custom-acm --version 2.15                     # Install ACM 2.15 (MCE 2.10 auto-derived)
bin/install-custom-acm --version 2.16 --mce-channel stable-2.11  # Explicit MCE channel
bin/install-custom-acm --pull-secret --catalog-source     # Full setup: pull secret + catalog + install
bin/install-custom-acm --catalog-source --catalog-tag 2.16-SNAPSHOT-2026-03-15  # Custom catalog tag
bin/install-custom-acm --skip-mch                         # Install operator only, skip MCH
bin/install-custom-acm status                             # Show installation status
bin/install-custom-acm uninstall                          # Remove ACM
bin/install-custom-acm uninstall --force-remove           # Remove managed clusters + ACM
```

Installs ACM operator and creates MultiClusterHub (MCH), which manages MCE (multicluster-engine) automatically. MCE channel is auto-derived from ACM version (ACM 2.x → MCE 2.(x-5)), e.g., ACM 2.16 → MCE `stable-2.11`.

The `--catalog-source` flag creates a CatalogSource using `quay.io:443/acm-d/acm-dev-catalog:latest-{version}` by default, waits for it to be READY, and configures the MCH to use it for both ACM and MCE. Use `--catalog-tag` to override the image tag (e.g., for snapshot builds), `--catalog-image` to change the image name, and `--catalog-registry` to change the registry.

The cluster needs `quay.io:443` in its global pull secret to pull operator images. Place your pull secret at `install-custom-acm/pull-secret.json` (see `.json.example` for format) and use `--pull-secret` to merge it. The global pull secret is also copied into the ACM namespace for MCH to use.

Environment variables (or use equivalent CLI flags):

```bash
export ACM_VERSION="2.16"                        # ACM version (--version)
export MCE_CHANNEL="stable-2.11"                 # MCE channel (--mce-channel), auto-derived if unset
export CATALOG_REGISTRY="quay.io:443/acm-d"      # Catalog registry (--catalog-registry)
export CATALOG_IMAGE="acm-dev-catalog"           # Catalog image name (--catalog-image)
```

### upgrade-acm

Upgrade ACM and MCE on an existing hub via OLM. Uses `subscription.operators.coreos.com` (not plain `subscription`). Auto-detects which catalog has the target channel (often `mce-dev-catalog`, not `redhat-operators`).

```bash
# Full ACM 5.0 + MCE 5.0 upgrade
bin/upgrade-acm --version 5.0 --apply-mce-catalog

# Dry-run to preview changes without applying
bin/upgrade-acm --version 5.0 --apply-mce-catalog --dry-run

# MCE only: stable-2.17 -> stable-5.0
bin/upgrade-acm fix-mce --mce-channel stable-5.0 --apply-mce-catalog

# Apply MCE dev catalog separately, then fix MCE
bin/upgrade-acm apply-mce-catalog
bin/upgrade-acm fix-mce --mce-channel stable-5.0

# See all MCE channels per catalog (matches console UI)
bin/upgrade-acm list-channels

# Check current state
bin/upgrade-acm status
```

**Version examples:**

| Command | ACM Channel | MCE Channel | Notes |
|---------|-------------|-------------|-------|
| `--version 5.0` | release-5.0 | stable-5.0 | ACM uses `release-`; MCE uses `stable-` |
| `--version 5.1` | release-5.1 | stable-5.1 | Minor is not hardcoded to 5.0 |
| `--version 2.17` | release-2.17 | stable-2.17 | ACM 2.17 |
| `--version 2.16` | release-2.16 | stable-2.11 | ACM 2.16 (MCE = ACM minor - 5) |
| `--channel release-2.17 --mce-channel stable-2.17` | release-2.17 | stable-2.17 | Explicit channels |

Channel derivation logic:
- **ACM** → always `release-<major>.<minor>` (same as `install-custom-acm`)
- **MCE 5.x and ACM 2.17+** → `stable-<major>.<minor>`
- **ACM 2.16 and below** → MCE `stable-2.<minor-5>`

`--mce-source` is honoured and is not overwritten when `--apply-mce-catalog` creates `mce-dev-catalog`. `--wait-timeout` applies to MCH, ACM/MCE CSV, MCE compliance, and CatalogSource waits.

**Environment variables:**

```bash
export TARGET_VERSION="5.0"                          # Target version (--version)
export ACM_CHANNEL="release-5.0"                     # ACM OLM channel (--channel)
export MCE_CHANNEL="stable-5.0"                      # MCE OLM channel (--mce-channel)
export MCE_SOURCE="mce-dev-catalog"                  # MCE catalog source (--mce-source)
export MCE_SOURCE_NS="openshift-marketplace"         # CatalogSource namespace
export MCE_CATALOG_IMAGE="mce-dev-catalog"           # Dev catalog image name
export MCE_CATALOG_REGISTRY="quay.io:443/acm-d"     # Dev catalog registry
export MCE_CATALOG_TAG="latest-5.0"                  # Dev catalog tag (--mce-catalog-tag)
export MCE_NAMESPACE="multicluster-engine"           # MCE subscription namespace
export ACM_SUB_NAME=""                               # ACM subscription name (auto-detected)
export MCE_SUB_NAME="multicluster-engine"            # MCE subscription name
export WAIT_TIMEOUT="900"                            # MCH / CSV / MCE / catalog wait timeout
```

The dev catalog image defaults to `quay.io:443/acm-d/mce-dev-catalog:latest-5.0`. Override with `--mce-catalog-tag`.

### setup-observability

Bootstrap MCO observability on a hub cluster with Minio storage.

```bash
bin/setup-observability                      # Full setup with Minio
bin/setup-observability --skip-minio         # Use existing object storage
bin/setup-observability --enable-rightsizing  # Also enable right-sizing
bin/setup-observability --mcoa-mode          # Enable right-sizing in MCOA mode
bin/setup-observability --force-cleanup-mw   # Clean stuck ManifestWorks before install
bin/setup-observability status               # Show observability status
bin/setup-observability uninstall            # Remove MCO CR
```

The `status` command detects MCOA ManifestWorks stuck in `Deleting` state on `local-cluster` (a self-referential deadlock that blocks COO installation and Perses dashboards). Use `--force-cleanup-mw` during install to remove finalizers and restart MCOA automatically.

**Environment variables:**

- `TIMEOUT_MW_STUCK` — Seconds before a deleting ManifestWork is considered stuck (default: 120)

### add-managed-cluster

Import or remove OpenShift clusters as ACM managed clusters.

```bash
bin/add-managed-cluster add namespace-spoke               # Import from kubeconfig context
bin/add-managed-cluster add vm-spoke --name my-vm-cluster  # Import with custom name
bin/add-managed-cluster add namespace-spoke --no-wait      # Import without waiting
bin/add-managed-cluster add vm-spoke --force-import        # Clean existing klusterlet and re-import
bin/add-managed-cluster add hub --force-import             # Repair local-cluster klusterlet
bin/add-managed-cluster add vm-spoke --sync-pull-secret    # Sync hub's quay.io credentials to spoke
bin/add-managed-cluster status                             # List managed clusters
bin/add-managed-cluster remove namespace-spoke             # Remove (with confirmation)
bin/add-managed-cluster remove namespace-spoke --force     # Remove without confirmation
```

Creates a ManagedCluster CR on the hub, then extracts the klusterlet import manifests and applies them on the spoke via `--context`. This works regardless of hub→spoke network connectivity (only requires spoke→hub). The ManagedCluster is labeled `vendor: OpenShift`. A `KlusterletAddonConfig` is also created to enable policy addons (policy controller, application manager, search collector) — these are required for MCO Policy-based right-sizing to enforce PrometheusRules on spokes. Observability addon auto-deploys via MCO/MCOA after import.

Before importing, the script checks if the spoke already has a klusterlet installed (from a previous hub attachment). If detected, it blocks with an error showing the existing hub URL. Use `--force-import` to clean up the existing klusterlet and re-import. For `local-cluster`, `--force-import` repairs the klusterlet in-place (full cleanup + re-apply import manifests) — useful when local-cluster shows `Available: Unknown` after a hub change.

**Pull secret sync for dev builds:** When using `--sync-pull-secret`, the script extracts `quay.io:443` credentials from the hub's global pull secret and merges them into the spoke's global pull secret. This is needed when using dev/pre-release ACM builds (installed via `--catalog-source`), because klusterlet images are pulled from `quay.io:443/acm-d` by digest reference and the spoke needs credentials to pull them. The sync is idempotent — if the spoke already has `quay.io:443` credentials, it skips. If the sync fails, import continues with a warning.

The `remove` command performs a **detach** — it removes ACM's management but leaves the spoke cluster intact. The klusterlet agent on the spoke may need manual removal if the spoke is unreachable.

### sno-virt

Enable and validate Red Hat OpenShift Virtualization on a single-node OpenShift (SNO) cluster running on AWS.

Standard EC2 instances do not expose Intel VT-x, so `/dev/kvm` is absent and OpenShift Virtualization cannot start VMs. On nested-virt-capable families (C7i/M7i/R7i/C8i/M8i/R8i and their variants) the capability can be switched on per instance via `ec2:ModifyInstanceCpuOptions`. Hive has no field for it, so it must be applied after installation — and again for every cluster claimed from the pool.

`setup` runs the whole path unattended and is the normal way to use this tool:

```bash
bin/sno-virt setup --cluster <cluster-ns> --hub-context <hub-ctx> --yes
```

`--cluster` is all the addressing it needs, but it only means something on the hub that
manages that cluster — be logged in to that hub (Collective for the Red Hat lab clusters)
and point `--hub-context` at it. The AWS credentials and the spoke's admin kubeconfig are
both read from there, so there is no separate spoke login and `--spoke-context` is only
for overriding it. See **Prerequisites** and **Spoke access** below.

It chains `enable` -> `check-node` -> `install` -> `smoke-test` -> `cleanup` -> `status`,
waiting for the node to report `Ready` after the resume before it runs anything spoke-side.
Every underlying step is re-runnable — `enable` exits early once nested virt is on, and
`install` and `smoke-test` use `oc apply` — so a `setup` that fails partway can simply be
run again and picks up where it stopped.

`smoke-test` waits for the `rhel9` DataSource to become Ready before it creates the VM.
HyperConverged reports `Available` well before the golden images finish importing, so a
smoke test run straight after `install` would otherwise always fail. Tune the wait with
`TIMEOUT_DATASOURCE_READY` (default 1800s).

By default the smoke-test VM and its namespace are deleted once the VM has proved KVM
works. A smoke-test namespace that already existed before `setup` ran is reused and never
deleted. Use `--skip-smoke-test` to stop after `install`, or `--keep-vm` to leave the VM
running.

The individual steps remain available:

```bash
bin/sno-virt status --cluster <cluster-ns>       # AWS, Hive, node and operator state
bin/sno-virt check-node --spoke-context current  # vmx flag, /dev/kvm, kvm modules
bin/sno-virt enable --cluster <cluster-ns>       # hibernate -> enable nested virt -> resume
bin/sno-virt install --spoke-context current     # operator + HyperConverged
bin/sno-virt smoke-test --spoke-context current  # boot a RHEL 9 VM to prove KVM works
bin/sno-virt cleanup --spoke-context current     # remove the smoke-test namespace
```

`enable` stops the cluster — a SNO cluster has one node, so it is fully down until the resume completes. It uses Hive's `powerState` rather than `aws ec2 stop-instances` so Hive stays authoritative over the node lifecycle. It requires AWS CLI 2.36+ (for `--nested-virtualization`) and an IAM principal with `ec2:ModifyInstanceCpuOptions`. It dry-runs `ModifyInstanceCpuOptions` before the hibernate, so a missing permission aborts while the cluster is still up rather than leaving it hibernating.

When `--cluster` is supplied, every spoke-side command cross-checks the spoke context's API URL against the ClusterDeployment's `status.apiURL` and refuses to act on a mismatch — it is easy to leave a kubeconfig pointed at a different spoke.

> OpenShift Virtualization on non-metal AWS instances is **not** a Red Hat supported configuration. Red Hat supports bare-metal instances (`c5n.metal`, `m5.metal`). Use this for lab and test clusters only.

**Prerequisites**

- **Access to the hub that manages the cluster — mandatory.** You must be logged in to the
  same hub whose Hive `ClusterDeployment` created and manages the target cluster; for the
  Red Hat lab clusters that is **Collective**. `sno-virt` resolves everything it needs
  through that ClusterDeployment — the AWS region, the installer's IAM credentials, the
  EC2 instance (via `infraID`) and the spoke's admin kubeconfig — so there is no offline
  or hub-less mode.

  `sno-virt` defaults to Collective, so logging in is all that is needed:

  ```bash
  oc login --web https://api.collective.aws.red-chesterfield.com:6443
  bin/sno-virt status --cluster <cluster-ns>
  ```

  The default lives in `config.sh` as `SNO_VIRT_HUB` and is deliberately separate from
  the generic `HUB_CONTEXT` the other tools use — those target whichever hub you are
  testing, while every cluster `sno-virt` manages is claimed from a pool on Collective.
  If you are not logged in to it, the run stops and says so rather than quietly using
  another context; targeting the wrong hub only shows up as a missing ClusterDeployment,
  which reads like a missing cluster instead of a missing login.

  Override per run with `--hub-context`, which takes a context name, `current` for the
  active context, or an API server URL. Override the default itself with `SNO_VIRT_HUB`:

  ```bash
  bin/sno-virt status --cluster <cluster-ns> --hub-context current
  bin/sno-virt status --cluster <cluster-ns> --hub-context https://api.my-hub.example.com:6443
  export SNO_VIRT_HUB=https://api.my-hub.example.com:6443     # change the default
  ```

  You need permission to `get clusterdeployment` and `get secret` in the cluster's
  namespace — on Hive, that namespace has the same name as the cluster. A hub that does
  not own this cluster will not have the ClusterDeployment and every command fails at
  the first step.

  Without `--cluster` only the spoke-only commands run (`check-node`, `install`,
  `smoke-test`, `cleanup`), and only against whatever `--spoke-context` points at.
  `status`, `enable` and `setup` always require `--cluster` and therefore the hub.

  No local AWS profile and no spoke login are required. See **Spoke access** and
  **AWS credentials** below.

- AWS CLI **2.36.0 or newer** — older versions have no `--nested-virtualization` and make `--core-count` / `--threads-per-core` mandatory.
- An IAM principal with **`ec2:ModifyInstanceCpuOptions`**. This is not part of the standard install permissions and usually has to be requested:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ec2:ModifyInstanceCpuOptions",
        "Resource": "arn:aws:ec2:us-west-2:<account-id>:instance/*"
      }
    ]
  }
  ```

- The cluster must already run on a nested-virt-capable instance type. Set it in the ClusterPool's install-config: `controlPlane.platform.aws.type: m7i.4xlarge` and `rootVolume.size: 200` (120 GB minimum, plus ~10 GiB virtualization overhead and room for VM disks). On OCP 5.0 `networking.networkType` must be `OVNKubernetes` — `OpenShiftSDN` was removed and provisioning fails in seconds.

**Spoke access**

Hive stores the cluster's admin kubeconfig in a secret the ClusterDeployment names
(`spec.clusterMetadata.adminKubeconfigSecretRef.name`). With `--cluster`, `sno-virt`
reads it from the hub and uses it for every spoke-side call, so no spoke context has to
exist in your kubeconfig.

The kubeconfig is fetched once into a shell variable and handed to each `oc` invocation
through a process substitution — it is never written to disk. Because it comes from the
cluster's own ClusterDeployment it cannot point at the wrong spoke, which removes the
whole class of wrong-cluster mistakes the API-URL cross-check exists to catch.

Resolution order is `--spoke-context` / `SNO_VIRT_SPOKE_CONTEXT` (explicit wins), then
the hub's admin kubeconfig when `--cluster` is given, then `VM_SPOKE_CONTEXT`. Use
`--spoke-context current` to act on whatever context is active, which is still the
quickest way to run the spoke-only commands against a cluster you are already logged in
to. `status` prints which source was used.

**AWS credentials**

No `aws configure` step is needed. `sno-virt` reads the region and the IAM keys straight
off the ClusterDeployment on the hub, so hub access is the only prerequisite:

| Value | Source on the hub |
|-------|-------------------|
| Region | `clusterdeployment.spec.platform.aws.region` |
| Access key / secret | the secret named by `clusterdeployment.spec.platform.aws.credentialsSecretRef.name` |
| EC2 instance | `clusterdeployment.spec.clusterMetadata.infraID` -> tag `<infraID>-master-0` |

Credentials are exported only inside the subshell running each `aws` call — never written
to disk and never logged. `status` prints which source was used.

Resolution order is `--profile` / `SNO_VIRT_AWS_PROFILE` (explicit wins), then the hub
secret, then the AWS CLI's own default chain. Use `--profile` when the hub secret is
missing, when it is an STS/AssumeRole setup with no static keys, or when you need a
different IAM principal:

```bash
bin/sno-virt status --cluster <cluster-ns> --profile my-profile
```

To inspect what the hub holds:

```bash
NS=<cluster-namespace>
oc get clusterdeployment $NS -n $NS \
  -o jsonpath='{.spec.platform.aws.region}{"\n"}{.spec.platform.aws.credentialsSecretRef.name}{"\n"}'
```

**Limitations**

- **Nested virtualization is per-instance and invisible to Hive.** Every cluster claimed from a pool needs `enable` run against it individually. If the node is replaced the setting reverts to `None` and VMs stop starting, with no explanatory error at the Kubernetes layer.
- **SNO restrictions.** No high availability, no pod disruption budgets, no live migration, and no VMs with an eviction strategy configured — hence `evictionStrategy: None` on the smoke-test VM.
- **AWS networking.** SR-IOV and bridge CNI (including VLAN) are unavailable. Use OVN-Kubernetes secondary overlay networks for layer-2 needs.
- **CPU headroom.** Roughly 6 of 16 vCPU go to virtualization overhead on SNO. Memory is comfortable; CPU is tight.
- Hosted control planes for OpenShift Virtualization are not supported on AWS.

**Troubleshooting**

| Symptom | Cause and fix |
|---|---|
| `UnauthorizedOperation ... ec2:ModifyInstanceCpuOptions` | IAM policy gap, not a state problem — `--dry-run` fails identically. Add the policy above. `enable` prints the resume command so the cluster is never left hibernating. |
| `Unknown options: --nested-virtualization` | AWS CLI older than 2.36. `brew upgrade awscli`. |
| `DataSource rhel9 is not Ready` | Golden images are still importing. `setup` waits for this; raise `TIMEOUT_DATASOURCE_READY` if the import is slow. Watch it with `oc get dv -n openshift-virtualization-os-images`. |
| `AuthFailure ... DescribeInstanceTypes, StatusCode: 401` | The pool's `credentialsSecretRef` is invalid or expired. Fails at `create manifests`, before any AWS resources exist. |
| `networkType OpenShiftSDN is not supported` | OpenShiftSDN was removed in OCP 5.0. Fix both the pool template and the `ClusterDeployment`'s own copy. |
| Cluster suddenly unreachable | Something hibernated it. Check `oc get clusterdeployment $NS -n $NS -o jsonpath='spec={.spec.powerState} status={.status.powerState}'`, and `.metadata.managedFields` for `manager=action` (console-driven) or `hibernateAfter` (timer). Hibernation is non-destructive — namespaces, VMs, DataVolumes, the operator and the `NestedVirtualization` attribute all survive. |

### image-override

Apply or revert custom image overrides on a hub cluster.

```bash
bin/image-override apply                     # Apply from image-override.json
bin/image-override apply --tag v44           # Apply with tag override
bin/image-override apply --force-reconcile   # Toggle MCH annotation to force re-pull
bin/image-override revert                    # Remove overrides
bin/image-override status                    # Show current override state
```

Reads `image-override.json` to determine which images to override. Edit the JSON to control which images are included — remove an entry to skip that image or add specific image entry:

```json
[
  {
    "image-name": "multicluster-observability-operator",
    "image-tag": "v43",
    "image-remote": "quay.io/rzalavad",
    "image-key": "multicluster_observability_operator"
  }
]
```

The `--tag` and `--registry` flags override all entries in the JSON without modifying the file. Handles the image-override ConfigMap in both `open-cluster-management` and `open-cluster-management-observability` namespaces, and the MCH `installer.open-cluster-management.io/image-overrides-configmap` annotation.

### rs-mode-switch

Switch right-sizing between MCO (Policy) and MCOA (ManifestWork) modes.

```bash
bin/rs-mode-switch status                    # Show current mode and state
bin/rs-mode-switch enable                    # Enable both namespace + virtualization
bin/rs-mode-switch enable --ns-only          # Enable namespace only
bin/rs-mode-switch enable --virt-only        # Enable virtualization only
bin/rs-mode-switch disable                   # Disable right-sizing
bin/rs-mode-switch mcoa                      # Switch to MCOA mode
bin/rs-mode-switch mco                       # Switch to MCO mode
```

Handles all workarounds automatically: ADC state sync wait, ConfigMap trigger for MCO mode, addon manager restart after mode switch.

**How mode switching works:**

The mode is controlled by a single annotation on the MCO CR (`MultiClusterObservability`):

```bash
# Switch to MCOA mode (ManifestWork-based)
kubectl annotate mco observability \
    observability.open-cluster-management.io/right-sizing-capable=true --overwrite

# Switch to MCO mode (Policy-based) — remove the annotation
kubectl annotate mco observability \
    observability.open-cluster-management.io/right-sizing-capable-
```

The `rs-mode-switch` script wraps these with additional steps (restarting the addon manager, patching ConfigMaps, waiting for COO/Perses) to speed up reconciliation.

**COO auto-installation:** When switching to MCOA mode with right-sizing enabled, MCOA automatically installs the Cluster Observability Operator (COO) and Perses dashboards. The script waits for COO installation and Perses pod readiness.

### rs-status

One-screen color-coded dashboard of right-sizing state across hub and spoke clusters.

```bash
bin/rs-status                                # Full status
bin/rs-status --hub-only                     # Skip spoke checks
bin/rs-status --spoke vm-spoke               # Check specific spoke
bin/rs-status --watch                        # Refresh every 10s
bin/rs-status --json                         # JSON output for scripting
```

Shows: mode (MCO/MCOA), MCO CR state, ADC state, ConfigMaps, mode-specific resources (Policies or Placements/ManifestWorks), spoke PrometheusRules, operator pods, images, and COO/Perses dashboard status (MCOA mode — checks all 4 RS dashboards: `acm-rs-namespace-overview`, `acm-rightsizing-openshift-virtualization`, `acm-rightsizing-vm-overestimation`, `acm-rightsizing-vm-underestimation`).

### rs-e2e

End-to-end validation of right-sizing resource lifecycle across MCO and MCOA modes.

```bash
bin/rs-e2e                                   # Phases 0-4a, 13-14 (core tests)
bin/rs-e2e --mode-switch                     # All phases 0-16 (includes MCOA mode switching)
bin/rs-e2e --skip-uninstall                  # Phases 0-4a only (no MCO deletion)
bin/rs-e2e --skip-uninstall --data-plane     # Control-plane + data-plane validation
bin/rs-e2e --mode-switch --data-plane --yes  # All phases + data-plane, auto-confirm
bin/rs-e2e --release 5.0 --data-plane --yes  # Test 5.0 images on 2.17 cluster + data-plane
bin/rs-e2e --release 5.0 --skip-uninstall    # 5.0 control-plane only (phases 0,0a,1,9a-9e,10)
bin/rs-e2e --phases 0-3,5,9a                 # Run specific phases (ranges OK)
bin/rs-e2e --phases 17-22 --skip-vm          # Data-plane only, no VMs
bin/rs-e2e --build mco                       # Build MCO image, then run tests
bin/rs-e2e --build both                      # Build MCO + MCOA images, then run tests
bin/rs-e2e --image-override                  # Apply image-override.json, then run tests
bin/rs-e2e --skip-perses-check               # Skip COO/Perses dashboard checks (incl. 21b stat panels)
bin/rs-e2e mcoa                              # Force testing in MCOA mode
```

Runs automated test phases that validate the full right-sizing resource lifecycle. The `--release` flag overrides the auto-detected ACM version (from MCH), allowing you to test 5.0 custom images on a 2.17 cluster — each release selects a different default phase set (2.16: MCO-only, 2.17: MCO+MCOA, 5.0: MCOA-only). Phases are grouped to minimize mode switches:

**Group 1: MCO-mode tests** (default run)

| Phase | Test | What it validates |
|-------|------|-------------------|
| 0 | Pre-flight | Cluster reachable, ACM installed, MCO installed and Ready, managed clusters available. Auto-installs MCO if missing, fixes stale IsMCOTerminating state, waits for RS auto-defaults. |
| 1 | Baseline verification | All RS resources exist for current mode: Placements, ConfigMaps, Policies (MCO) or ManifestWorks (MCOA), PlacementBindings, ADC state. |
| 2a | Disable namespace RS | Disables namespace RS only — verifies namespace resources deleted (Placement, ConfigMap, Policy) while virt resources retained. Checks ADC reflects partial state. |
| 2b | Swap features | Swaps to namespace on + virt off — verifies namespace resources restored and virt resources deleted. |
| 2c | Disable both | Disables both RS features — verifies all RS resources cleaned up. |
| 2d | Re-enable both | Re-enables both features — verifies full resource restoration. |
| 2e | NamespaceBinding change (MCO) | Patches `namespaceBinding` to a test namespace — verifies all 6 Policy resources (Placements, Policies, PlacementBindings) move to new namespace and are cleaned up from default. Resets binding and verifies resources return. ConfigMaps unaffected (always in observability namespace). |
| 3 | Spoke validation | Checks PlacementDecisions select managed clusters, verifies PrometheusRules exist on spokes (hub-side ManifestWork check + direct spoke `--context` check). |
| 4 | ConfigMap propagation (MCO) | Modifies `rs-namespace-config` ConfigMap (recommendationPercentage 110→120), verifies Policy updates with new value, then reverts. Tests MCO's ConfigMap→Policy pipeline. |
| 4a | ConfigMap coexistence (MCO+MCOA) | Enables incident detection to trigger MCOA deployment while RS stays in MCO mode. Verifies RS ConfigMaps survive, no ManifestWork PrometheusRules or Perses dashboards created, and ADC `rightSizingDelegated=false`. Tests delegation signal. |

**Group 2: MCOA-mode tests** (`--mode-switch` required)

| Phase | Test | What it validates |
|-------|------|-------------------|
| 5 | MCO → MCOA switch | Sets `right-sizing-capable` annotation, restarts addon manager. Verifies Policies deleted, ManifestWorks with PrometheusRules created, ADC shows enabled state, specHash populated, Perses dashboards created (4 total: 1 namespace + 3 virtualization). |
| 6 | SpecHash freshness | Disables virt RS to trigger ADC change, polls for specHash change (up to 60s). Re-enables and verifies hash restores. Tests that ADC spec changes propagate to ManifestWork specHash. |
| 7 | ConfigMap predicate | Edits ConfigMap data without MCO spec change. Verifies no Policy side-effects in MCOA mode (ConfigMap predicate should not trigger Policy creation). |
| 8 | Placement filter | Applies `placementConfiguration` with label selector to restrict cluster selection. Verifies ManifestWork PrometheusRule distribution filters to matching clusters only, then restores defaults. Uses yaml.v2 lowercased field names. |
| 9a | Disable namespace RS (MCOA) | Same as 2a but in MCOA mode — verifies MCOA handles partial feature disable. Also verifies namespace Perses dashboard (`acm-rs-namespace-overview`) removed while 3 virt dashboards retained. |
| 9b | Swap features (MCOA) | Same as 2b but in MCOA mode — verifies MCOA handles feature swap. Also verifies namespace dashboard present and 3 virt dashboards removed. |
| 9c | Disable both (MCOA) | Same as 2c but in MCOA mode — verifies MCOA cleans up all RS resources and all 4 Perses dashboards are absent. Placements may persist due to addon framework InstallStrategy (logged as warning, not failure). |
| 9d | Re-enable both (MCOA) | Same as 2d but in MCOA mode — verifies MCOA restores all RS resources including ManifestWorks and all 4 Perses dashboards. |
| 9e | NamespaceBinding change (MCOA) | Patches `namespaceBinding` in MCOA mode — verifies no Policies created in either namespace (MCOA uses ManifestWorks, not Policies). Verifies ManifestWorks and ConfigMaps unaffected. |
| 10 | ConfigMap propagation (MCOA) | Same as phase 4 but in MCOA mode — modifies ConfigMap, verifies ManifestWork PrometheusRules update with new value. Tests MCOA's ConfigMap→ManifestWork pipeline. |

**Group 3: Mode round-trip tests** (`--mode-switch` required)

| Phase | Test | What it validates |
|-------|------|-------------------|
| 11 | MCOA → MCO switch | Removes annotation, waits for Placement creation and stabilization (addon framework race). Verifies Policies restored, ManifestWork PrometheusRules removed, ADC shows managed-by-mco. |
| 12 | Version mismatch | Sets annotation to non-standard value (`v99`). Verifies delegation occurs regardless of annotation value (any truthy value triggers MCOA mode). Restores MCO mode afterwards. |

**Group 4: Destructive tests** (prompt for confirmation unless `--yes`)

| Phase | Test | What it validates |
|-------|------|-------------------|
| 13 | Uninstall cleanup (MCO) | Deletes MCO CR via `setup-observability uninstall`. Verifies all RS resources cleaned up: Placements, ConfigMaps, Policies, PlacementBindings deleted. |
| 14 | Uninstall cleanup (MCOA) | Reinstalls MCO, enables RS, switches to MCOA mode, then deletes MCO. Verifies MCOA-specific cleanup: ManifestWork PrometheusRules removed, ClusterManagementAddon deleted, all 4 Perses dashboards absent. |
| 15 | MCOA uninstall + reinstall | Deletes MCO in MCOA mode, reinstalls, verifies RS auto-defaults re-populate. Checks for stale IsMCOTerminating flag (operator caches terminating state in memory — requires pod restart). |
| 16 | Mode switch after reinstall | After fresh MCO install, performs full MCO→MCOA→MCO round-trip. Verifies ManifestWorks and Perses dashboards created in MCOA mode, Policies restored after switching back to MCO. |

**Group 5: Data-plane validation** (`--data-plane` required)

| Phase | Test | What it validates |
|-------|------|-------------------|
| 17 | Deploy namespace workloads | Verifies spoke connectivity and RS PrometheusRules present, deploys 5 CronJob stress workloads (CPU, memory, file I/O, network, combined) to namespace-spoke. |
| 18 | Deploy VM workloads | Checks OpenShift Virtualization installed on vm-spoke, deploys 5 VMs: `fedora-vm-1`/`fedora-vm-2` (Fedora), `rhel-vm1` (RHEL), plus deterministic underestimation fixtures `cpu-underest-vm` (pegs 1 vCPU) and `mem-underest-vm` (anonymous ~3.4 GiB fill). Skipped with `--skip-vm`. |
| 19 | Metrics collection wait | Waits `TIMEOUT_METRICS_WAIT` seconds (default: 1200/20 min) for Thanos to ingest metrics from spoke PrometheusRules. Skipped with `--no-metrics-wait`. |
| 20 | Namespace metrics validation | Discovers Thanos endpoint (rbac-query-proxy Route), queries all 6 `acm_rs:namespace:*` metrics for the workload namespace. Reports values or failures. |
| 21 | VM metrics validation | Queries all 6 `acm_rs_vm:namespace:*` metrics for the VM workload namespace (ratio classifier: ideal/overestimated). Skipped with `--skip-vm`. |
| 21a | VM dashboard stat/table consistency | Compares dashboard stat-panel totals against summed table-panel values for all 4 CPU/Memory × Over/Under categories, and asserts the underestimation fixtures (`cpu-underest-vm`, `mem-underest-vm`) actually make the floor-based Underestimation panels fire (non-zero). Skipped with `--skip-vm`. |
| 21b | Stopped VM exclusion + Perses stat check (ACM-41141, MCOA #620/#621/#623) | Checks that the hub Thanos query path returns data, waits until the hub counts `fedora-vm-2` as running, stops it, and verifies it is excluded from the running-VM-filtered stat/table queries. In MCOA mode it also reads the deployed `acm-rightsizing-openshift-virtualization` PersesDashboard: all 4 stat panels must be pinned with `@ end()`, the query path must keep `@ end()` fixed over a 1-week range, and the CPU/Memory overestimation stat queries — run as range queries, the way Perses runs stat panels — must count the stopped VM nowhere, while the pre-fix query (no `@ end()`) still shows its stale value. The VM is restarted on exit, including after Ctrl-C. Skipped with `--skip-vm`; the Perses part is skipped in MCO mode and with `--skip-perses-check`. See [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#phase-21b-perses-stat-panel-check-mcoa-620621623). |
| 22 | Data-plane cleanup | Deletes workload namespaces from spoke clusters. Robust to unreachable spokes. |

Phases 5-12, 15-16 require `--mode-switch`. Phases 17-22 require `--data-plane`. Both can be combined with explicit `--phases` selection. Destructive phases (13, 14, 15) prompt for confirmation unless `--yes` is passed. All phases auto-install MCO if not present and switch to the required mode before running.

**Environment variables:**

- `TIMEOUT_E2E_RECONCILE` — Seconds to wait after MCO spec patches (default: 90)
- `TIMEOUT_E2E_MODE_SWITCH` — Seconds to wait after annotation changes (default: 60)
- `TIMEOUT_PERSES_DASHBOARD` — Seconds to wait for Perses dashboard convergence (default: 60)
- `TIMEOUT_METRICS_WAIT` — Seconds to wait for Thanos metric ingestion (default: 1200)
- `TIMEOUT_VM_BOOT` — Seconds to wait for VM workloads to boot (default: 600)
- `RS_NS_WORKLOAD_NS` — Namespace for CronJob workloads on namespace-spoke (default: offline-workload)
- `RS_VM_WORKLOAD_NS` — Namespace for VM workloads on vm-spoke (default: auto-vm-test)

The `--build` flag reads repo paths from `config.sh` (`MCO_REPO_DIR`, `MCOA_REPO_DIR`), auto-increments the tag in `image-override.json`, builds with `$CONTAINER_ENGINE`, pushes to `$ACM_TOOLS_REGISTRY`, and applies the override before running tests.

### rs-collect-must-gather

Gather and analyze a diagnostic bundle for right-sizing troubleshooting.

```bash
bin/rs-collect-must-gather                          # Collect full bundle
bin/rs-collect-must-gather --analyze                # Collect then analyze
bin/rs-collect-must-gather analyze ./must-gather-*  # Analyze existing bundle
bin/rs-collect-must-gather --spoke vm-spoke         # Collect from specific spoke
bin/rs-collect-must-gather --skip-spoke             # Hub only
bin/rs-collect-must-gather --log-lines 1000         # More log lines
```

Collects MCO/MCOA operator logs, resource states (MCO CR, CMA, ADC, ConfigMaps, Policies, Placements, ManifestWorks), events, spoke PrometheusRules, and agent logs into a timestamped directory.

### cluster-diagnose

Automated cluster health diagnostic — runs 15 checks and prints issues + fix commands. Strictly read-only.

```bash
bin/cluster-diagnose              # Shows only issues + fix commands
bin/cluster-diagnose --verbose    # Shows all checks including PASS
bin/cluster-diagnose --quick      # Hub only (skip spoke checks)
bin/cluster-diagnose --release 5.0  # Override release detection
```

Checks 5 areas: Infrastructure (node health, operator pods, image overrides), Observability Pipeline (MCO conditions, Thanos health, stuck ManifestWorks), Addon Health (MCOA, MCA CRD, COO/Perses), Cluster Connectivity (ManagedClusters, metrics-collector, KlusterletAddonConfig), and Right-Sizing (RS resources, Thanos data). Mode-aware — detects MCO vs MCOA mode for RS resource validation.

The `analyze` subcommand examines collected data offline (no cluster connection needed) and checks for: pod health, ADC state consistency, resource mismatches, ManifestWork generation lag, log errors/panics, and missing ConfigMaps.

## Claude Code Skills

Interactive workflows available as `/skill-name` slash commands in Claude Code. These automate multi-step processes that combine CLI tools with external services.

### /plan-feature-epics

Generate and create a set of Jira Epics for an ACM feature based on proven patterns from past releases. Supports Dev Preview, Tech Preview, and GA phases.

```
/plan-feature-epics Rightsizing with MCOA as GA with ACM 5.0
```

- Creates 9 core epics + phase-specific extras (TP: +2, GA: +3)
- ACM tracking epic with full structured description template
- OBSINTA epics for Design, Dev, QE, Doc, Blog, CEE, Enhancements
- Default T-shirt sizing (XS/S/M/L/XL) per epic type
- Parent ticket linking from any Jira board (OBSDA, ACM, etc.)
- Dry-run mode (default) for review before Jira creation
- Requires: [Atlassian Rovo MCP Server](https://support.atlassian.com/atlassian-rovo-mcp-server/docs/getting-started-with-the-atlassian-remote-mcp-server/) configured in `.mcp.json`

Configuration: `.claude/skills/plan-feature-epics/config.env`

### /rs-e2e

Run end-to-end validation of right-sizing resource lifecycle on the current cluster.

```
/rs-e2e                           # Core tests (phases 0-4a, 13-14)
/rs-e2e --mode-switch             # Full suite including MCOA tests
/rs-e2e --build mco --phases 0-3  # Build image then run specific phases
```

**`/rs-e2e` (skill) vs `bin/rs-e2e` (script):**

| | `bin/rs-e2e` | `/rs-e2e` |
|---|---|---|
| **What** | Standalone bash script | Claude Code skill wrapping the script |
| **Input** | CLI flags (`--mode-switch`, `--phases 0-3`) | Natural language ("run a quick validation") |
| **On failure** | Prints PASS/FAIL summary | Interactive troubleshooting with diagnosis tables, debugging commands, and root-cause guidance |
| **Requires** | Terminal + cluster access | Claude Code + cluster access |

Use `bin/rs-e2e` directly when you know the flags. Use `/rs-e2e` when you want Claude to pick the right flags or help diagnose failures.

### /cluster-debug

Diagnose issues with ACM/MCO/MCE on the hub cluster. Systematically checks all layers (operators, CRDs, pods, logs) before proposing fixes.

```
/cluster-debug    # Start interactive diagnosis
```

Runs diagnostic steps sequentially: cluster overview, operator health, CRD status, pod logs, and resource state analysis.

## Deployment Architecture

Both MCO and MCOA are deployed via MCH image overrides:

| Component | Deployment Method | Image Key |
|-----------|------------------|-----------|
| **MCO** (multicluster-observability-operator) | MCH image override | `multicluster_observability_operator` |
| **MCOA** (multicluster-observability-addon) | MCH image override → MCO deploys MCOA | `multicluster_observability_addon` |

MCO creates the MCOA addon manager deployment when MCOA capabilities are active (metrics, logs, traces, incident detection) or when right-sizing is delegated to MCOA via the MCO CR annotation. The image override ConfigMap must be in **both** `open-cluster-management` (for MCO) and `open-cluster-management-observability` (for MCOA) namespaces — `image-override apply` handles this automatically.

**Important:** MCH uses `imagePullPolicy: IfNotPresent` — always increment the image tag when rebuilding (e.g., v55 → v56) to ensure the new image is pulled.

## Directory Structure

```
acm-tools/
  AGENTS.md                # Agent instructions (tool-agnostic, for Claude/Cursor/Copilot)
  CLAUDE.md                # Claude Code include (@AGENTS.md)
  docs/                    # Documentation
    TROUBLESHOOTING.md     # Right-sizing migration troubleshooting learnings
  config.sh                # Shared configuration (contexts, container engine)
  image-override.json      # Image override entries (edit to add/remove images)
  lib/common.sh            # Shared library (logging, helpers, constants)
  bin/                     # Tool scripts (all executable)
  install-custom-acm/      # Pull secret for ACM install
    pull-secret.json       # Your quay.io pull secret (gitignored)
    pull-secret.json.example
  manifests/               # Generated YAML manifests (by setup-observability)
  .claude/skills/          # Claude Code skill definitions
    plan-feature-epics/    # Jira epic planning workflow
    rs-e2e/                # Right-sizing E2E test runner
    cluster-debug/         # Cluster diagnostics
```

## Shared Library

All tools source `lib/common.sh` which provides:

- **Logging**: `log_info`, `log_success`, `log_warn`, `log_error`, `log_step`, `log_substep`
- **Helpers**: `switch_context`, `wait_with_message`, `resource_exists`, `get_resource_field`, `confirm`
- **Constants**: `MCO_NAME`, `MCOA_NAME`, `OBS_NAMESPACE`, `ACM_NAMESPACE`, `RS_ANNOTATION`
- **Auto-detection**: `oc`/`kubectl` CLI, config loading
