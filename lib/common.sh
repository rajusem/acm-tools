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
    printf "\r%-80s\r" " " >&2
}

# Retry a command on transient API server errors (connection lost, timeout, etc.)
# Usage: kube_retry <command...>
# Stdout passes through unchanged (safe in pipes). Retries up to 3 times with
# exponential backoff (2s, 4s, 8s) when stderr contains transient error patterns.
kube_retry() {
    local max_retries=3 attempt=0 rc=0
    local stderr_file
    stderr_file=$(mktemp) || return 1
    while true; do
        "$@" 2>"$stderr_file"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            cat "$stderr_file" >&2
            rm -f "$stderr_file"
            return 0
        fi
        if grep -qE 'connection lost|request canceled|Client\.Timeout|connection refused|TLS handshake timeout|unexpected EOF|server unavailable|transport is closing|connection reset' "$stderr_file" 2>/dev/null; then
            attempt=$((attempt + 1))
            if [[ $attempt -le $max_retries ]]; then
                local delay=$((2 ** attempt))
                log_warn "Transient API error (attempt $attempt/$max_retries), retrying in ${delay}s..." >&2
                sleep "$delay"
                continue
            fi
        fi
        cat "$stderr_file" >&2
        rm -f "$stderr_file"
        return $rc
    done
}

# Apply JSON content with retry on transient API errors.
# Pipes content on each attempt so stdin is never exhausted.
# Usage: kube_apply_json "$json_content"
kube_apply_json() {
    local content="$1"
    local max_retries=3 attempt=0 rc stderr_file
    stderr_file=$(mktemp) || return 1
    while true; do
        echo "$content" | $KUBE_CLI apply -f - 2>"$stderr_file"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            cat "$stderr_file" >&2; rm -f "$stderr_file"; return 0
        fi
        if grep -qE 'connection lost|request canceled|Client\.Timeout|connection refused|TLS handshake timeout|unexpected EOF|server unavailable|transport is closing|connection reset' "$stderr_file" 2>/dev/null; then
            attempt=$((attempt + 1))
            if [[ $attempt -le $max_retries ]]; then
                local delay=$((2 ** attempt))
                log_warn "Transient API error (attempt $attempt/$max_retries), retrying in ${delay}s..." >&2
                sleep "$delay"; continue
            fi
        fi
        cat "$stderr_file" >&2; rm -f "$stderr_file"; return $rc
    done
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

# Confirm action (returns 0 for yes).
# Non-interactive / CI: set ACM_TOOLS_YES=true or pass --yes / --force-import.
confirm() {
    local message="${1:-Continue?}"
    if [[ "${ACM_TOOLS_YES:-}" == "true" ]]; then
        log_info "$message [yes]"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "$message — non-interactive stdin; pass --yes or --force-import"
        return 1
    fi
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

# detect_acm_namespace — finds the MCH namespace dynamically.
# Users can install MCH in any namespace (e.g., "ocm" instead of "open-cluster-management").
# Must be called after switch_context to hub (so it queries the hub, not whatever was active).
detect_acm_namespace() {
    local namespaces count ns
    namespaces=$($KUBE_CLI get mch -A --no-headers \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' \
        --request-timeout=10s 2>/dev/null || echo "")
    [[ -z "$namespaces" ]] && return
    count=$(echo "$namespaces" | wc -l | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
        log_warn "Multiple MCH CRs found ($count); using first. Set ACM_NAMESPACE to override." >&2
    fi
    ns=$(echo "$namespaces" | head -1)
    [[ -n "$ns" ]] && ACM_NAMESPACE="$ns"
}

# RS_RELEASE: set by --release flag, inherited from parent via export, or auto-detected.
# The "${RS_RELEASE:-}" form is required for set -euo pipefail — referencing an unset
# variable would exit immediately; this form preserves any value exported by a parent
# process (e.g. rs-e2e → setup-observability) while defaulting to empty if unset.
RS_RELEASE="${RS_RELEASE:-}"

# detect_release — sets RS_RELEASE from MCH status.currentVersion.
# Short-circuits if RS_RELEASE already set (--release flag or parent export wins).
# Exports RS_RELEASE so subprocess calls (setup-observability, rs-mode-switch) inherit.
# Must be called after init_acm_tools() (needs $KUBE_CLI and $ACM_NAMESPACE).
detect_release() {
    if [[ -n "$RS_RELEASE" ]]; then
        [[ "$RS_RELEASE" =~ ^(2\.16|2\.17|5\.0)$ ]] || {
            log_error "Inherited RS_RELEASE='$RS_RELEASE' is not a recognized release — set --release or unset RS_RELEASE"
            exit 1
        }
        export RS_RELEASE; return
    fi
    local version major minor
    version=$(get_resource_field mch multiclusterhub "$ACM_NAMESPACE" \
        '{.status.currentVersion}' 2>/dev/null || echo "")
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    if   [[ "$major" == "5"  ]];                    then RS_RELEASE="5.0"
    elif [[ "$major" == "2" && "$minor" == "17" ]]; then RS_RELEASE="2.17"
    elif [[ "$major" == "2" && "$minor" == "16" ]]; then RS_RELEASE="2.16"
    else
        log_warn "MCH version '${version:-<not found>}' not recognized — defaulting to 2.17; use --release to override"
        RS_RELEASE="2.17"
    fi
    export RS_RELEASE
    log_info "Release: $RS_RELEASE (auto-detected from MCH $version)"
}

release_is_50()  { [[ "$RS_RELEASE" == "5.0"  ]]; }
release_is_217() { [[ "$RS_RELEASE" == "2.17" ]]; }
release_is_216() { [[ "$RS_RELEASE" == "2.16" ]]; }

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
    detect_acm_namespace
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

# --- Version-cycle helpers (OBSINTA-1606 T1/T3/T6/T7) -------------------------

# Clear OCM CRDs stuck Terminating after ACM uninstall/reinstall (T1).
clear_terminating_ocm_crds() {
    local crd resource ns name ts
    for crd in \
        managedclusteraddons.addon.open-cluster-management.io \
        manifestworks.work.open-cluster-management.io
    do
        ts=$($KUBE_CLI get crd "$crd" -o jsonpath='{.metadata.deletionTimestamp}' \
            --request-timeout=10s 2>/dev/null || echo "")
        [[ -z "$ts" ]] && continue
        resource="${crd%%.*}"
        log_warn "CRD $crd is terminating — clearing instance and CRD finalizers"
        while read -r ns name; do
            [[ -z "${name:-}" ]] && continue
            if [[ -n "${ns:-}" && "$ns" != "<none>" && "$ns" != "null" ]]; then
                $KUBE_CLI patch "$resource" "$name" -n "$ns" --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' --request-timeout=15s 2>/dev/null || true
            else
                $KUBE_CLI patch "$resource" "$name" --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' --request-timeout=15s 2>/dev/null || true
            fi
        done < <($KUBE_CLI get "$resource" -A --no-headers \
            -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
            --request-timeout=15s 2>/dev/null || true)
        $KUBE_CLI patch crd "$crd" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' --request-timeout=15s 2>/dev/null || true
    done
}

# MCH validating/mutating webhooks can block uninstall (T7).
remove_mch_admission_webhooks() {
    local webhooks
    webhooks=$($KUBE_CLI get validatingwebhookconfiguration,mutatingwebhookconfiguration \
        -o name --request-timeout=15s 2>/dev/null | grep -Ei 'multiclusterhub|multicluster-hub|mch-operator' || true)
    [[ -z "$webhooks" ]] && return 0
    log_substep "Removing MCH admission webhooks that can block uninstall"
    while IFS= read -r wh; do
        [[ -z "$wh" ]] && continue
        log_info "  Deleting $wh"
        $KUBE_CLI delete "$wh" --ignore-not-found --timeout=30s 2>/dev/null || true
    done <<< "$webhooks"
}

# Leftover MCE CSV/CR from a prior ACM major blocks the next install (T3).
cleanup_mce_leftovers() {
    local mce_ns="multicluster-engine"
    if ! $KUBE_CLI get namespace "$mce_ns" --request-timeout=10s &>/dev/null; then
        return 0
    fi
    log_substep "Removing leftover MCE (namespace $mce_ns)"
    local mce_list
    mce_list=$($KUBE_CLI get mce -o name --request-timeout=15s 2>/dev/null || true)
    if [[ -n "$mce_list" ]]; then
        $KUBE_CLI delete mce --all --timeout=180s 2>/dev/null || true
        while IFS= read -r mce; do
            [[ -z "$mce" ]] && continue
            $KUBE_CLI patch "$mce" --type=merge -p '{"metadata":{"finalizers":[]}}' \
                --request-timeout=15s 2>/dev/null || true
        done <<< "$mce_list"
        $KUBE_CLI delete mce --all --timeout=60s --ignore-not-found 2>/dev/null || true
    fi
    $KUBE_CLI delete subscription.operators.coreos.com --all -n "$mce_ns" \
        --timeout=60s --ignore-not-found 2>/dev/null || true
    local csv
    while IFS= read -r csv; do
        [[ -z "$csv" ]] && continue
        $KUBE_CLI delete "$csv" -n "$mce_ns" --timeout=60s --ignore-not-found 2>/dev/null || true
    done < <($KUBE_CLI get csv -n "$mce_ns" -o name --request-timeout=15s 2>/dev/null | \
        grep -Ei 'multicluster-engine|mce' || true)
}

# Fail install if an existing MCE CSV major.minor does not match the target channel (T3).
preflight_mce_csv_channel() {
    local expected_channel="${1:-}"
    [[ -z "$expected_channel" ]] && return 0
    local csv_names expected_ver csv_name leftover
    csv_names=$($KUBE_CLI get csv -n multicluster-engine --no-headers \
        -o custom-columns=NAME:.metadata.name --request-timeout=15s 2>/dev/null || true)
    [[ -z "$csv_names" ]] && return 0
    expected_ver="${expected_channel#stable-}"
    while IFS= read -r csv_name; do
        [[ -z "$csv_name" ]] && continue
        if [[ "$csv_name" =~ \.v([0-9]+)\.([0-9]+) ]]; then
            leftover="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            if [[ "$leftover" != "$expected_ver" ]]; then
                log_error "Leftover MCE CSV '$csv_name' does not match channel $expected_channel"
                log_info "Uninstall first: bin/install-custom-acm uninstall --force-remove"
                return 1
            fi
        fi
    done <<< "$csv_names"
    return 0
}
