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

# Print the cluster this script will act on. Call after init_hub_context so
# ACM_NAMESPACE has been detected. Logs to stdout (status banners, not captured).
log_target_cluster() {
    local api_url context
    api_url=$($KUBE_CLI cluster-info 2>/dev/null | grep -o 'https://[^ ]*' | head -1 || echo "unknown")
    context=$($KUBE_CLI config current-context 2>/dev/null || echo "unknown")
    echo -e "${BOLD}Target Cluster:${NC} $api_url"
    echo -e "${BOLD}Context:${NC}        $context"
    echo -e "${BOLD}ACM Namespace:${NC}  $ACM_NAMESPACE"
    echo ""
}

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
    local response
    if [[ "${ACM_TOOLS_YES:-}" == "true" ]]; then
        log_info "$message [yes]"
        return 0
    fi
    if [[ -t 0 ]]; then
        read -rp "$(echo -e "${YELLOW}$message [y/N]: ${NC}")" response
    else
        # Non-interactive stdin: honor piped input (the `echo "y" | ...` idiom that
        # rs-e2e and the documented recovery commands rely on), but fail loudly on
        # empty/EOF stdin so CI can't silently proceed or hang. Pass --yes /
        # --force-import (ACM_TOOLS_YES=true) for unattended runs.
        if ! read -r response; then
            log_error "$message — non-interactive stdin with no input; pass --yes or --force-import"
            return 1
        fi
    fi
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
RS_MCH_VERSION="${RS_MCH_VERSION:-}"

# Right-sizing evaluation interval bounds.  Keep these in one place so the
# e2e checks, status dashboard, and must-gather analysis agree with the MCOA
# contract.
export RS_EVAL_INTERVAL_DEFAULT="${RS_EVAL_INTERVAL_DEFAULT:-5m}"
export RS_EVAL_INTERVAL_MIN="${RS_EVAL_INTERVAL_MIN:-5m}"
export RS_EVAL_INTERVAL_MAX="${RS_EVAL_INTERVAL_MAX:-1h}"
export RS_EVAL_INTERVAL_1D_DEFAULT="${RS_EVAL_INTERVAL_1D_DEFAULT:-15m}"
export RS_EVAL_INTERVAL_1D_MIN="${RS_EVAL_INTERVAL_1D_MIN:-15m}"
export RS_EVAL_INTERVAL_1D_MAX="${RS_EVAL_INTERVAL_1D_MAX:-6h}"

# detect_release — sets RS_RELEASE from MCH status.currentVersion.
# Short-circuits if RS_RELEASE already set (--release flag or parent export wins).
# Exports RS_RELEASE so subprocess calls (setup-observability, rs-mode-switch) inherit.
# Must be called after init_acm_tools() (needs $KUBE_CLI and $ACM_NAMESPACE).
detect_release() {
    # An explicit --release is intentionally only a coarse behaviour token.
    # There is no exact MCH version to compare in this path.
    RS_MCH_VERSION=""
    if [[ -n "$RS_RELEASE" ]]; then
        [[ "$RS_RELEASE" =~ ^(2\.16|2\.17|5\.0|5\.1)$ ]] || {
            log_error "Inherited RS_RELEASE='$RS_RELEASE' is not a recognized release — set --release or unset RS_RELEASE"
            exit 1
        }
        export RS_RELEASE RS_MCH_VERSION; return
    fi
    local version major minor
    version=$(get_resource_field mch multiclusterhub "$ACM_NAMESPACE" \
        '{.status.currentVersion}' 2>/dev/null || echo "")
    RS_MCH_VERSION="$version"
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    if   [[ "$major" == "5"  ]];                    then RS_RELEASE="5.0"
    elif [[ "$major" == "2" && "$minor" == "17" ]]; then RS_RELEASE="2.17"
    elif [[ "$major" == "2" && "$minor" == "16" ]]; then RS_RELEASE="2.16"
    else
        log_warn "MCH version '${version:-<not found>}' not recognized — defaulting to 2.17; use --release to override"
        RS_RELEASE="2.17"
    fi
    export RS_RELEASE RS_MCH_VERSION
    log_info "Release: $RS_RELEASE (auto-detected from MCH $version)"
}

# Numeric comparison for the exact MCH version fetched by detect_release.
# Returns 1 for an unknown/unparseable version so callers can distinguish an
# unknown release from one known to be below the minimum supported version.
release_at_least() {
    local required="$1" version_major version_minor required_major required_minor

    [[ "$required" =~ ^([0-9]+)\.([0-9]+)$ ]] || return 1
    required_major="${BASH_REMATCH[1]}"
    required_minor="${BASH_REMATCH[2]}"
    [[ "$RS_MCH_VERSION" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?([+-].*)?$ ]] || return 1
    version_major="${BASH_REMATCH[1]}"
    version_minor="${BASH_REMATCH[2]}"

    if (( 10#$version_major > 10#$required_major )); then
        return 0
    fi
    if (( 10#$version_major < 10#$required_major )); then
        return 1
    fi
    (( 10#$version_minor >= 10#$required_minor ))
}

# Read a scalar top-level key from either the YAML representation used by
# MCOA or the legacy JSON representation.  The YAML expression is anchored so
# evaluationInterval cannot accidentally match evaluationInterval1d.
rs_rule_config_get() {
    local blob="$1" key="$2" value line yaml_key_re
    [[ -n "$blob" ]] || return 1

    yaml_key_re="^[[:space:]]*${key}:[[:space:]]*"
    line=$(printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '
        $0 ~ re { print; found=1; exit }
        END { if (!found) exit 1 }
    ' 2>/dev/null) || line=""
    if [[ -n "$line" ]]; then
        value="${line#*:}"
        value="${value#${value%%[![:space:]]*}}"
        value="${value%%[[:space:]]*}"
        # Remove a trailing YAML comment only when it is separated by space.
        value="${value%%[[:space:]]#*}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^'(.*)'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        # YAML arrays and objects are commonly emitted as block values.  Return
        # a compact JSON representation for those values so callers can compare
        # them semantically instead of losing the field at the blank key line.
        if command -v yq >/dev/null 2>&1; then
            value=$(printf '%s\n' "$blob" | yq -o=json '.' 2>/dev/null | jq -cer --arg key "$key" \
                'if type == "object" and has($key) and .[$key] != null then .[$key] else empty end' \
                2>/dev/null) || value=""
            [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
        fi
        return 1
    fi

    value=$(printf '%s\n' "$blob" | jq -er --arg key "$key" \
        'if type == "object" and has($key) and .[$key] != null then .[$key] | if type == "string" then . else tostring end else empty end' \
        2>/dev/null) || return 1
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

# Convert a JSON object to YAML when yq is available.  YAML callers already
# have a stable, human-readable representation and are edited in place below.
rs_rule_config_json_to_yaml() {
    if command -v yq >/dev/null 2>&1; then
        yq -P '.' 2>/dev/null
    else
        # Keep the helper usable on installations without yq for scalar-only
        # callers; callers that need to edit JSON receive an explicit error.
        return 1
    fi
}

rs_rule_config_set() {
    local blob="$1" key="$2" value="$3" yaml_key_re normalized value_json json_blob updated
    normalized="$value"
    if [[ "$normalized" =~ ^\"(.*)\"$ || "$normalized" =~ ^'(.*)'$ ]]; then
        normalized="${BASH_REMATCH[1]}"
    fi

    # Use a typed YAML round-trip whenever yq is available.  This preserves
    # numeric fields and block-list fields from legacy JSON/YAML blobs; a
    # string-only jq assignment would turn recommendationPercentage into a
    # quoted YAML string and leave orphaned list items behind.
    if command -v yq >/dev/null 2>&1; then
        value_json=$(printf 'value: %s\n' "$normalized" | yq -o=json '.value' 2>/dev/null) || return 1
        json_blob=$(printf '%s\n' "$blob" | yq -o=json '.' 2>/dev/null) || return 1
        updated=$(printf '%s\n' "$json_blob" | jq --arg key "$key" --argjson value "$value_json" \
            '.[$key] = $value' 2>/dev/null) || return 1
        printf '%s\n' "$updated" | rs_rule_config_json_to_yaml
        return $?
    fi

    yaml_key_re="^[[:space:]]*${key}:"
    if printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '$0 ~ re && $0 ~ /:[[:space:]]*$/ { found=1; exit } END { exit !found }' \
        >/dev/null 2>&1; then
        log_error "Editing block-valued prometheusRuleConfig key '$key' requires yq" >&2
        return 1
    fi
    if printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '$0 ~ re { found=1; exit } END { exit !found }' \
        >/dev/null 2>&1; then
        printf '%s\n' "$blob" | awk -v re="$yaml_key_re" -v key="$key" -v value="$normalized" '
            $0 ~ re { print key ": " value; replaced=1; next }
            { print }
            END { if (!replaced) print key ": " value }
        '
        return 0
    fi

    if printf '%s\n' "$blob" | jq -e . >/dev/null 2>&1; then
        normalized=$(printf '%s\n' "$blob" | jq --arg key "$key" --arg value "$normalized" '.[$key] = $value' 2>/dev/null) || return 1
        printf '%s\n' "$normalized" | rs_rule_config_json_to_yaml || {
            log_error "Editing JSON prometheusRuleConfig requires yq for YAML normalization" >&2
            return 1
        }
        return 0
    fi

    if [[ -n "$blob" ]]; then
        printf '%s\n' "$blob"
    fi
    printf '%s: %s\n' "$key" "$normalized"
}

rs_rule_config_unset() {
    local blob="$1" key="$2" yaml_key_re json_blob updated
    [[ -n "$blob" ]] || { printf '\n'; return 0; }
    if command -v yq >/dev/null 2>&1; then
        json_blob=$(printf '%s\n' "$blob" | yq -o=json '.' 2>/dev/null) || return 1
        updated=$(printf '%s\n' "$json_blob" | jq --arg key "$key" 'del(.[$key])' 2>/dev/null) || return 1
        printf '%s\n' "$updated" | rs_rule_config_json_to_yaml
        return $?
    fi

    yaml_key_re="^[[:space:]]*${key}:"
    if printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '$0 ~ re && $0 ~ /:[[:space:]]*$/ { found=1; exit } END { exit !found }' \
        >/dev/null 2>&1; then
        log_error "Removing block-valued prometheusRuleConfig key '$key' requires yq" >&2
        return 1
    fi
    if printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '$0 ~ re { found=1; exit } END { exit !found }' \
        >/dev/null 2>&1; then
        printf '%s\n' "$blob" | awk -v re="$yaml_key_re" '$0 !~ re { print }'
        return 0
    fi
    if printf '%s\n' "$blob" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "$blob" | jq --arg key "$key" 'del(.[$key])' 2>/dev/null | rs_rule_config_json_to_yaml || return 1
        return 0
    fi
    printf '%s\n' "$blob"
}

rs_rule_config_from_cluster() {
    local cm="$1" namespace="$2"
    $KUBE_CLI get configmap "$cm" -n "$namespace" \
        -o jsonpath='{.data.prometheusRuleConfig}' --request-timeout=10s
}

rs_rule_config_from_file() {
    local path="$1" value
    [[ -f "$path" ]] || return 1

    value=$(jq -er '.data.prometheusRuleConfig // empty' "$path" 2>/dev/null) || value=""
    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    if command -v yq >/dev/null 2>&1; then
        value=$(yq -r '.data.prometheusRuleConfig // empty' "$path" 2>/dev/null) || value=""
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    # Minimal fallback for a ConfigMap YAML artifact when yq is unavailable.
    awk '
        /^data:[[:space:]]*$/ { in_data=1; next }
        in_data && /^[^[:space:]]/ { exit }
        in_data && /^[[:space:]]+prometheusRuleConfig:[[:space:]]*\|[-+]?/ { in_blob=1; next }
        in_blob && /^[[:space:]]{2,}/ { sub(/^[[:space:]]{2}/, ""); print; next }
        in_blob { exit }
    ' "$path"
}

rs_duration_ms() {
    local value="$1" number unit multiplier
    [[ "$value" =~ ^([0-9]+)(ms|s|m|h|d|w|y)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    [[ "$number" =~ [1-9] ]] || return 1
    case "$unit" in
        ms) multiplier=1 ;;
        s)  multiplier=1000 ;;
        m)  multiplier=60000 ;;
        h)  multiplier=3600000 ;;
        d)  multiplier=86400000 ;;
        w)  multiplier=604800000 ;;
        y)  multiplier=31536000000 ;;
    esac
    awk -v number="$number" -v multiplier="$multiplier" 'BEGIN { printf "%.0f\n", number * multiplier }'
}

rs_eval_interval_check() {
    local value="$1" min="$2" max="$3" value_ms min_ms max_ms rc
    [[ -z "$value" ]] && return 0
    value_ms=$(rs_duration_ms "$value") || return 1
    min_ms=$(rs_duration_ms "$min") || return 1
    max_ms=$(rs_duration_ms "$max") || return 1
    # Keep the comparison in awk: Bash arithmetic is signed 64-bit and wraps
    # for sufficiently large, otherwise well-formed durations. The operator
    # rejects those values as overflow, so the local validator must not accept
    # a wrapped value as being inside the configured range.
    if awk -v value="$value_ms" -v minimum="$min_ms" -v maximum="$max_ms" \
        'BEGIN { if (value < minimum || value > maximum) exit 2; exit 0 }' \
        >/dev/null 2>&1; then
        return 0
    else
        rc=$?
    fi
    [[ "$rc" -eq 2 ]] && return 2
    return 1
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
