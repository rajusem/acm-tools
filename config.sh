#!/bin/bash
# =============================================================================
# ACM Tools Configuration
# =============================================================================
# Override any of these via environment variables before running tools.

# --- Registry ---
export ACM_TOOLS_REGISTRY="${ACM_TOOLS_REGISTRY:-quay.io/rzalavad}"

# --- Image Names ---
export MCO_IMAGE_NAME="${MCO_IMAGE_NAME:-multicluster-observability-operator}"
export MCOA_IMAGE_NAME="${MCOA_IMAGE_NAME:-multicluster-observability-addon}"

# --- Cluster Contexts ---
export HUB_CONTEXT="${HUB_CONTEXT:-hub}"

# Hub that owns the SNO ClusterDeployments sno-virt operates on. Every cluster
# it manages is claimed from a pool here, so this is the default rather than the
# generic HUB_CONTEXT, which points at whatever hub the other tools target.
# Accepts an API server URL or a kubeconfig context name.
export SNO_VIRT_HUB="${SNO_VIRT_HUB:-https://api.collective.aws.red-chesterfield.com:6443}"
export NAMESPACE_SPOKE_CONTEXT="${NAMESPACE_SPOKE_CONTEXT:-namespace-spoke}"
export VM_SPOKE_CONTEXT="${VM_SPOKE_CONTEXT:-vm-spoke}"

# --- Source Repos (relative to acm-tools root, or absolute) ---
_ACM_TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MCO_REPO_DIR="${MCO_REPO_DIR:-${_ACM_TOOLS_ROOT}/../multicluster-observability-operator}"
export MCOA_REPO_DIR="${MCOA_REPO_DIR:-${_ACM_TOOLS_ROOT}/../multicluster-observability-addon}"
export MCO_DOCKERFILE="${MCO_DOCKERFILE:-operators/multiclusterobservability/Dockerfile.local}"
export MCOA_DOCKERFILE="${MCOA_DOCKERFILE:-Dockerfile}"

# --- Container Engine ---
export CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)}"

# --- Build Platform ---
export BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"

# --- Timeouts (seconds) ---
export TIMEOUT_ROLLOUT="${TIMEOUT_ROLLOUT:-120}"
export TIMEOUT_MCO_READY="${TIMEOUT_MCO_READY:-300}"
export TIMEOUT_MCH_READY="${TIMEOUT_MCH_READY:-900}"
export TIMEOUT_MODE_SWITCH="${TIMEOUT_MODE_SWITCH:-30}"
export TIMEOUT_COO_INSTALL="${TIMEOUT_COO_INSTALL:-120}"
export TIMEOUT_PERSES_READY="${TIMEOUT_PERSES_READY:-90}"
export TIMEOUT_RS_CLEANUP="${TIMEOUT_RS_CLEANUP:-60}"
export TIMEOUT_CLUSTER_IMPORT="${TIMEOUT_CLUSTER_IMPORT:-120}"
export TIMEOUT_MW_STUCK="${TIMEOUT_MW_STUCK:-120}"

# --- E2E Test Timeouts ---
export TIMEOUT_E2E_RECONCILE="${TIMEOUT_E2E_RECONCILE:-90}"
export TIMEOUT_E2E_MODE_SWITCH="${TIMEOUT_E2E_MODE_SWITCH:-60}"
export TIMEOUT_RS_INTERVAL_PROPAGATION="${TIMEOUT_RS_INTERVAL_PROPAGATION:-180}"

# --- Right-sizing evaluation intervals (MCOA, ACM 5.1+) ---
# Defaults and inclusive bounds of the MCOA contract, shared by rs-e2e, rs-status
# and rs-collect-must-gather. The *_TEST values are what phase 10b writes.
export RS_EVAL_INTERVAL_DEFAULT="${RS_EVAL_INTERVAL_DEFAULT:-5m}"
export RS_EVAL_INTERVAL_MIN="${RS_EVAL_INTERVAL_MIN:-5m}"
export RS_EVAL_INTERVAL_MAX="${RS_EVAL_INTERVAL_MAX:-1h}"
export RS_EVAL_INTERVAL_1D_DEFAULT="${RS_EVAL_INTERVAL_1D_DEFAULT:-15m}"
export RS_EVAL_INTERVAL_1D_MIN="${RS_EVAL_INTERVAL_1D_MIN:-15m}"
export RS_EVAL_INTERVAL_1D_MAX="${RS_EVAL_INTERVAL_1D_MAX:-6h}"
export RS_EVAL_INTERVAL_TEST="${RS_EVAL_INTERVAL_TEST:-10m}"
export RS_EVAL_INTERVAL_1D_TEST="${RS_EVAL_INTERVAL_1D_TEST:-30m}"

# --- Non-OpenShift vendor simulation (rs-e2e phase 9f) ---
# MCOA honours the mcoa-override-vendor annotation ahead of the vendor label
# (internal/addon/common/managedcluster.go), which lets an OpenShift spoke
# exercise the non-OpenShift rendering and probe paths. The annotation alone
# never re-renders: MCOA's AgentDeployTriggerClusterFilter compares labels only,
# so phase 9f also touches RS_VENDOR_TRIGGER_LABEL to raise the event.
export RS_VENDOR_OVERRIDE_ANNOTATION="${RS_VENDOR_OVERRIDE_ANNOTATION:-mcoa-override-vendor}"
export RS_VENDOR_OVERRIDE_VALUE="${RS_VENDOR_OVERRIDE_VALUE:-AKS}"
export RS_VENDOR_TRIGGER_LABEL="${RS_VENDOR_TRIGGER_LABEL:-rs-e2e-vendor-trigger}"
# Phase 9f prefers a real spoke. On a hub with none, it falls back to
# local-cluster so the coverage still runs; set this false to skip instead.
export RS_VENDOR_ALLOW_LOCAL_CLUSTER="${RS_VENDOR_ALLOW_LOCAL_CLUSTER:-true}"
export TIMEOUT_VENDOR_RERENDER="${TIMEOUT_VENDOR_RERENDER:-120}"
export TIMEOUT_MCA_AVAILABLE="${TIMEOUT_MCA_AVAILABLE:-120}"
# Lifting the override makes MCOA re-render the OpenShift-only resources, which
# the work agent must delete and recreate on the spoke before the addon can be
# probed green again. Measured at ~2.5 min on a SNO hub, so this is deliberately
# more generous than the two above — phase 9f must not hand a degraded addon to
# the phases that follow it.
export TIMEOUT_MCA_RECOVERY="${TIMEOUT_MCA_RECOVERY:-300}"

# --- Monitoring UIPlugin ACM block (ACM-48605) ---
# The ACM console reads these two endpoints out of the UIPlugin. They are
# cluster-internal Services, so the names are fixed unless MCO is installed in
# a non-default namespace.
# MCOA rewrites the whole UIPlugin spec in one reconcile, so a check that runs
# straight after a feature toggle needs a convergence budget of its own.
export TIMEOUT_UIPLUGIN_ACM="${TIMEOUT_UIPLUGIN_ACM:-60}"
export RS_UIPLUGIN_NAME="${RS_UIPLUGIN_NAME:-monitoring}"
export RS_UIPLUGIN_ALERTMANAGER_URL="${RS_UIPLUGIN_ALERTMANAGER_URL:-https://alertmanager.open-cluster-management-observability.svc:9095}"
export RS_UIPLUGIN_THANOS_URL="${RS_UIPLUGIN_THANOS_URL:-https://rbac-query-proxy.open-cluster-management-observability.svc:8443}"

# --- Data-plane Workloads ---
export RS_NS_WORKLOAD_NS="${RS_NS_WORKLOAD_NS:-offline-workload}"
export RS_NS_OVERESTIMATED_NS="${RS_NS_OVERESTIMATED_NS:-rs-test-overestimated}"
export RS_NS_IDEAL_NS="${RS_NS_IDEAL_NS:-rs-test-ideal}"
export RS_VM_WORKLOAD_NS="${RS_VM_WORKLOAD_NS:-auto-vm-test}"
export RS_VM_SSH_PUBLIC_KEY="${RS_VM_SSH_PUBLIC_KEY:-}"
export TIMEOUT_METRICS_WAIT="${TIMEOUT_METRICS_WAIT:-1800}"
export TIMEOUT_VM_BOOT="${TIMEOUT_VM_BOOT:-600}"
export TIMEOUT_HUB_METRIC_PROPAGATION="${TIMEOUT_HUB_METRIC_PROPAGATION:-600}"
