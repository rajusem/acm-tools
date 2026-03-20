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

### setup-observability

Bootstrap MCO observability on a hub cluster with Minio storage.

```bash
bin/setup-observability                      # Full setup with Minio
bin/setup-observability --skip-minio         # Use existing object storage
bin/setup-observability --enable-rightsizing  # Also enable right-sizing
bin/setup-observability --mcoa-mode          # Enable right-sizing in MCOA mode
bin/setup-observability status               # Show observability status
bin/setup-observability uninstall            # Remove MCO CR
```

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
    observability.open-cluster-management.io/right-sizing-capable=v1 --overwrite

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

Shows: mode (MCO/MCOA), MCO CR state, ADC state, ConfigMaps, mode-specific resources (Policies or Placements/ManifestWorks), spoke PrometheusRules, operator pods, and images.

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

The `analyze` subcommand examines collected data offline (no cluster connection needed) and checks for: pod health, ADC state consistency, resource mismatches, ManifestWork generation lag, log errors/panics, and missing ConfigMaps.

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
  config.sh                # Shared configuration (contexts, container engine)
  image-override.json      # Image override entries (edit to add/remove images)
  lib/common.sh            # Shared library (logging, helpers, constants)
  bin/                     # Tool scripts (all executable)
  install-custom-acm/      # Pull secret for ACM install
    pull-secret.json       # Your quay.io pull secret (gitignored)
    pull-secret.json.example
  manifests/               # Generated YAML manifests (by setup-observability)
```

## Shared Library

All tools source `lib/common.sh` which provides:

- **Logging**: `log_info`, `log_success`, `log_warn`, `log_error`, `log_step`, `log_substep`
- **Helpers**: `switch_context`, `wait_with_message`, `resource_exists`, `get_resource_field`, `confirm`
- **Constants**: `MCO_NAME`, `MCOA_NAME`, `OBS_NAMESPACE`, `ACM_NAMESPACE`, `RS_ANNOTATION`
- **Auto-detection**: `oc`/`kubectl` CLI, config loading
