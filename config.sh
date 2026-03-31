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
