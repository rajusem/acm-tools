#!/bin/bash
# =============================================================================
# ACM Tools Configuration
# =============================================================================
# Override any of these via environment variables before running tools.

# --- Cluster Contexts ---
export HUB_CONTEXT="${HUB_CONTEXT:-hub}"
export NAMESPACE_SPOKE_CONTEXT="${NAMESPACE_SPOKE_CONTEXT:-namespace-spoke}"
export VM_SPOKE_CONTEXT="${VM_SPOKE_CONTEXT:-vm-spoke}"

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
