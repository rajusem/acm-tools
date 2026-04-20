#!/bin/bash
# =============================================================================
# Common library for ACM Tools
# =============================================================================
# Source this file from any tool script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/common.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}==> ${BOLD}$*${NC}"; }
log_substep() { echo -e "    ${BLUE}-> $*${NC}"; }

# Separator
print_separator() {
    echo -e "${CYAN}$(printf '%.0s─' {1..60})${NC}"
}

# Load configuration
load_config() {
    local tools_root
    tools_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "$tools_root/config.sh" ]]; then
        source "$tools_root/config.sh"
    fi
}

# Ensure oc/kubectl is available
ensure_cli() {
    if command -v oc &>/dev/null; then
        KUBE_CLI="oc"
    elif command -v kubectl &>/dev/null; then
        KUBE_CLI="kubectl"
    else
        log_error "Neither 'oc' nor 'kubectl' found in PATH"
        exit 1
    fi
}

# Check cluster connectivity
check_cluster_connection() {
    local context
    context=$($KUBE_CLI config current-context 2>/dev/null || echo "")
    if [[ -z "$context" ]]; then
        log_error "No active kubeconfig context. Log in to a cluster first."
        exit 1
    fi
    if ! $KUBE_CLI cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster (context: $context)"
        log_error "The cluster may be hibernating, unreachable, or credentials may have expired."
        log_info "Try: $KUBE_CLI cluster-info"
        exit 1
    fi
}

# Switch context with validation
switch_context() {
    local ctx="$1"
    if ! $KUBE_CLI config use-context "$ctx" &>/dev/null; then
        log_error "Failed to switch to context: $ctx"
        log_info "Available contexts:"
        $KUBE_CLI config get-contexts -o name 2>/dev/null | sed 's/^/  /'
        return 1
    fi
    return 0
}

# Wait with a countdown message
wait_with_message() {
    local seconds=$1
    local message="${2:-Waiting}"
    for ((i=seconds; i>0; i--)); do
        printf "\r  ${BLUE}%s (%ds remaining)...${NC}  " "$message" "$i" >&2
        sleep 1
    done
    printf "\r%-60s\r" " " >&2
}

# Check if a resource exists
resource_exists() {
    local type="$1" name="$2" namespace="${3:-}"
    if [[ -n "$namespace" ]]; then
        $KUBE_CLI get "$type" "$name" -n "$namespace" &>/dev/null
    else
        $KUBE_CLI get "$type" "$name" &>/dev/null
    fi
}

# Get a jsonpath value from a resource
get_resource_field() {
    local type="$1" name="$2" namespace="${3:-}" jsonpath="$4"
    if [[ -n "$namespace" ]]; then
        $KUBE_CLI get "$type" "$name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null
    else
        $KUBE_CLI get "$type" "$name" -o jsonpath="$jsonpath" 2>/dev/null
    fi
}

# Confirm action (returns 0 for yes)
confirm() {
    local message="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}$message [y/N]: ${NC}")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Common constants
MCO_NAME="observability"
MCOA_NAME="multicluster-observability-addon"
MCOA_DEPLOY="multicluster-observability-addon-manager"
MCOA_MW_PATTERN="addon-multicluster-observability-addon-deploy"
OBS_NAMESPACE="open-cluster-management-observability"
ACM_NAMESPACE="open-cluster-management"
GLOBAL_SET_NAMESPACE="open-cluster-management-global-set"
RS_ANNOTATION="observability.open-cluster-management.io/right-sizing-capable"
ANALYTICS_NAMESPACE="observability-analytics"

# Load config at source time (safe — no CLI dependency).
# CLI detection is deferred to init_acm_tools so --help works without oc/kubectl.
load_config

init_acm_tools() {
    ensure_cli
    check_cluster_connection
}

# Save current context, set EXIT trap to restore it, and switch to hub.
# Call after init_acm_tools (requires $KUBE_CLI and $HUB_CONTEXT).
init_hub_context() {
    ORIGINAL_CONTEXT=$($KUBE_CLI config current-context 2>/dev/null || echo "")
    trap '$KUBE_CLI config use-context "$ORIGINAL_CONTEXT" &>/dev/null 2>&1 || true' EXIT
    switch_context "$HUB_CONTEXT" || { log_error "Failed to switch to hub context"; exit 1; }
}

# Map a ManagedCluster name to its kubeconfig context.
# Falls back to the cluster name itself if no mapping exists.
mc_to_context() {
    case "$1" in
        local-cluster)   echo "$HUB_CONTEXT" ;;
        namespace-spoke) echo "$NAMESPACE_SPOKE_CONTEXT" ;;
        vm-spoke)        echo "$VM_SPOKE_CONTEXT" ;;
        *)               echo "$1" ;;
    esac
}

# Check if Cluster Observability Operator (COO) is installed.
check_coo_installed() {
    $KUBE_CLI get csv -n openshift-operators --no-headers 2>/dev/null | \
        awk '{print $1}' | grep "^cluster-observability-operator" >/dev/null 2>&1
}
