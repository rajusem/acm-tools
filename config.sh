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
export NAMESPACE_SPOKE_CONTEXT="${NAMESPACE_SPOKE_CONTEXT:-namespace-spoke}"
export VM_SPOKE_CONTEXT="${VM_SPOKE_CONTEXT:-vm-spoke}"

# --- Container Engine ---
export CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)}"

# --- Build Platform ---
export BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"
