#!/usr/bin/env python3
"""Plan or apply an AWS IAM key rotation for Hive pools on an ACM hub."""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import warnings
from collections import defaultdict
from typing import NamedTuple


HUB = "https://api.collective.aws.red-chesterfield.com:6443"
CLUSTER_SET = "obs-int-analytics"
SOURCE = "observability-llc-aws"
HIVE_ANCHOR_POOL = "obsint-sno-4xlarge-422"
CCX_SOURCE = "ccx-clusterpool-aws"
# This Collective pool has no CCX name marker and can hold a different key from the CCX source.
CCX_POOL = "obsint-sno-m5metal-420"
DEFAULT_AWS_REGION = "us-west-2"
AWS_REGION_PATTERN = r"[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+"
SET_LABEL = "cluster.open-cluster-management.io/clusterset"
PROVIDER_LABEL = "cluster.open-cluster-management.io/credentials"
KEY_ID = "aws_access_key_id"
KEY_SECRET = "aws_secret_access_key"


class Inventory(NamedTuple):
    targets: dict
    pool_credentials: dict
    owners: dict
    deployments: dict
    claimed_only: bool


class Plan(NamedTuple):
    updates: list
    desired: set
    old_pairs: set
    protected: set


class RotationError(Exception):
    pass


class CommandError(RotationError):
    def __init__(self, operation, reason):
        super().__init__(f"{operation} failed ({reason})")
        self.reason = reason


def progress(message):
    print(message, file=sys.stderr, flush=True)


def masked_key_id(key_id):
    if re.fullmatch(r"[A-Z0-9]{20}", key_id):
        return f"...{key_id[-4:]}"
    return "unavailable"


def command_failure_reason(stderr):
    # Command diagnostics can include request data. Return only fixed messages.
    codes = ("Forbidden", "Unauthorized", "NotFound", "Conflict", "UnauthorizedOperation",
             "InvalidClientTokenId", "SignatureDoesNotMatch", "AccessDenied", "ExpiredToken")
    for code in codes:
        if f"({code})" in stderr:
            return code
    diagnostic = stderr.lower()
    errors = (
        ("server hostname did not resolve. Check DNS and the hub network connection",
         ("no such host", "could not resolve", "temporary failure in name resolution")),
        ("authentication required. Sign in again with the selected context",
         ("you must be logged in", "provide credentials", "unauthorized")),
        ("TLS certificate verification failed", ("x509:", "certificate verify failed", "failed to verify certificate")),
        ("the server connection timed out", ("i/o timeout", "deadline exceeded", "timed out")),
        ("the server connection failed", ("connection refused", "connection reset", "no route to host", "network is unreachable")),
        ("the kubeconfig login helper failed", ("error getting credentials", "exec: executable", "exec plugin")),
    )
    for reason, fragments in errors:
        if any(fragment in diagnostic for fragment in fragments):
            return reason
    return "see access and connectivity"


def command(args, operation, *, input_text=None, env=None, expected_error=None, parse_json=True):
    kwargs = {"stdin": subprocess.DEVNULL} if input_text is None else {"input": input_text}
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=45, env=env, **kwargs)
    except subprocess.TimeoutExpired:
        raise CommandError(operation, "timeout") from None
    except (OSError, UnicodeError):
        raise CommandError(operation, "could not run command") from None
    if result.returncode and expected_error and f"({expected_error})" in result.stderr:
        return None
    if result.returncode or expected_error:
        raise CommandError(operation, command_failure_reason(result.stderr))
    if not parse_json:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise CommandError(operation, "invalid JSON response") from None


def hub_client(args):
    cli = shutil.which("oc") or shutil.which("kubectl")
    if not cli or not shutil.which("aws"):
        raise RotationError("Install oc or kubectl, and the AWS CLI")
    config = command([cli, "config", "view", "-o", "json"], "Read kubeconfig contexts")
    clusters = {entry["name"]: entry["cluster"] for entry in config.get("clusters", [])}
    contexts = {entry["name"]: entry["context"] for entry in config.get("contexts", [])}
    candidates = [name for name, context in contexts.items()
                  if clusters.get(context["cluster"], {}).get("server", "").rstrip("/") == args.server]
    current = config.get("current-context")
    context = args.context or (current if current in candidates else None)
    if context is None and len(candidates) == 1:
        context = candidates[0]
    if context not in candidates:
        raise RotationError("Select a kubeconfig --context for the expected --server")
    if clusters[contexts[context]["cluster"]].get("insecure-skip-tls-verify"):
        raise RotationError("Configure trusted TLS for the selected hub context")
    return [cli, f"--context={context}", f"--server={args.server}", "--request-timeout=15s"]


def get(cli, resource, scope, name=None, selector=None):
    query = [*cli, "get", resource, *scope]
    if name:
        query.append(name)
    if selector:
        query += ["-l", selector]
    return command(query + ["-o", "json"], f"Read {resource} {' '.join(scope)} {name or ''}".strip())


def inventory(cli, namespace, cluster_set, source):
    """Return Secret references and the AWS regions of their scoped consumers."""
    scope = ["-n", namespace]
    pools = get(cli, "clusterpools.hive.openshift.io", scope, selector=f"{SET_LABEL}={cluster_set}")["items"]
    pools = {p["metadata"]["name"]: p for p in pools if p["spec"]["platform"].get("aws") is not None}
    if not pools:
        raise RotationError("No AWS ClusterPools found for the requested namespace and cluster set")

    targets = defaultdict(set)
    owners = defaultdict(set)

    def add_ref(obj, pool_name):
        meta, spec = obj["metadata"], obj["spec"]
        aws = spec["platform"]["aws"]
        name = aws.get("credentialsSecretRef", {}).get("name")
        if name:
            region = aws.get("region", "")
            if not re.fullmatch(AWS_REGION_PATTERN, region):
                raise RotationError(f"Missing or invalid AWS region on {meta['name']}")
            ref = (meta["namespace"], name)
            targets[ref].add(region)
            owners[ref].add(pool_name)
            return ref
        return None

    pool_credentials = {name: add_ref(pool, name) for name, pool in pools.items()}
    if not targets:
        raise RotationError("The AWS pools use no referenced credential Secrets")

    claims = get(cli, "clusterclaims.hive.openshift.io", scope)["items"]
    claims = [c for c in claims if c["spec"]["clusterPoolName"] in pools]
    resource = "clusterdeployments.hive.openshift.io"
    try:
        deployments = get(cli, resource, ["-A"])["items"]
        claimed_only = False
    except CommandError as exc:
        if exc.reason != "Forbidden":
            raise
        # Namespace RBAC on Collective permits walking claims, but may forbid listing all deployments.
        if any(p["spec"].get("size") != 0 or p.get("status", {}).get("size") != 0
               for p in pools.values()):
            raise RotationError("Cluster-wide deployment list permission is needed when pools have inventory")
        deployments = []
        claimed_only = True

    # A claim's namespace identifies where its deployment lives. Resolve it even when
    # the cluster-wide list is available, to catch incomplete inventory or pending claims.
    by_namespace = {d["metadata"]["namespace"]: d for d in deployments
                    if d["metadata"]["name"] == d["metadata"]["namespace"]}
    for claim in claims:
        claim_name = claim["metadata"]["name"]
        assigned = claim["spec"].get("namespace")
        if not assigned:
            raise RotationError(f"Claim {claim_name} is unassigned. Recheck after it settles")
        deployment = by_namespace.get(assigned) or get(cli, resource, ["-n", assigned], assigned)
        ref = deployment["spec"].get("clusterPoolRef", {})
        if (ref.get("namespace"), ref.get("poolName"), ref.get("claimName")) != (
            namespace, claim["spec"]["clusterPoolName"], claim_name
        ):
            raise RotationError(f"Hive ownership does not match claim {claim_name}")
        by_namespace[assigned] = deployment

    scoped_deployments = {}
    for deployment in [*deployments, *by_namespace.values()]:
        ref = deployment["spec"].get("clusterPoolRef", {})
        if ref.get("namespace") != namespace or ref.get("poolName") not in pools:
            continue
        meta = deployment["metadata"]
        scoped_deployments[meta["uid"]] = deployment

    deployments = {}
    for uid, deployment in scoped_deployments.items():
        if deployment["metadata"].get("deletionTimestamp") or not deployment["spec"].get("installed"):
            raise RotationError(f"Wait for provisioning or deletion of {deployment['metadata']['name']} to finish")
        pool_name = deployment["spec"]["clusterPoolRef"]["poolName"]
        deployments[uid] = (pool_name, add_ref(deployment, pool_name))

    targets.setdefault((namespace, source), set())
    return Inventory(dict(targets), pool_credentials, dict(owners), deployments, claimed_only)


def read_credentials(from_stdin, target=None):
    previous_id = None
    previous_hive_id = None
    if from_stdin:
        try:
            data = json.load(sys.stdin)
        except ValueError:
            raise RotationError("Expected a JSON credential object on stdin") from None
        if not isinstance(data, dict):
            raise RotationError("Expected a JSON credential object on stdin")
        key_id, secret = data.get(KEY_ID), data.get(KEY_SECRET)
        if target is not None:
            previous_id = data.get("old_access_key_id")
            previous_hive_id = data.get("old_hive_access_key_id")
    else:
        if not sys.stdin.isatty():
            raise RotationError("Use an interactive terminal or --credentials-stdin")
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            key_id = getpass.getpass("New AWS access key ID: ")
            secret = getpass.getpass("New AWS secret access key: ")
            if target in ("acm", "both"):
                previous_id = getpass.getpass("Previous ACM key ID, if already rotated (optional): ") or None
            if target in ("hive", "both"):
                previous_hive_id = getpass.getpass("Previous Hive key ID, if the anchor was already rotated (optional): ") or None
    if not isinstance(key_id, str) or not re.fullmatch(r"AKIA[A-Z0-9]{16}", key_id):
        raise RotationError("Provide a long-term AWS IAM access key ID")
    if not isinstance(secret, str) or not re.fullmatch(r"[A-Za-z0-9/+=]{40}", secret):
        raise RotationError("Provide a valid AWS secret access key")
    for supplied in (previous_id, previous_hive_id):
        if supplied is not None and (not isinstance(supplied, str) or not re.fullmatch(r"[A-Z0-9]{20}", supplied)):
            raise RotationError("Invalid previous access key ID")
    return (key_id, secret), previous_id, previous_hive_id


def aws_call(pair, region, *operation, expected_error=None):
    env = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
    env.update(AWS_ACCESS_KEY_ID=pair[0], AWS_SECRET_ACCESS_KEY=pair[1], AWS_CONFIG_FILE=os.devnull,
               AWS_SHARED_CREDENTIALS_FILE=os.devnull, AWS_EC2_METADATA_DISABLED="true", AWS_PAGER="",
               AWS_CLI_AUTO_PROMPT="off", AWS_STS_REGIONAL_ENDPOINTS="regional")
    return command(["aws", "--region", region, "--output", "json", *operation],
                   f"AWS {' '.join(operation[:2])} in {region}", env=env, expected_error=expected_error)


def aws_identity(pair, region, label):
    progress(f"Checking {label.lower()} (access key ID {masked_key_id(pair[0])}) with AWS STS in {region}.")
    try:
        identity = aws_call(pair, region, "sts", "get-caller-identity")
    except CommandError as exc:
        raise RotationError(f"{label}: {exc}") from None
    progress(f"{label} authenticated successfully.")
    return identity


def replacement_identity(pair, region):
    identity = aws_identity(pair, region, "Replacement key")
    if ":user/" not in identity["Arn"]:
        raise RotationError("The replacement credential must belong to an IAM user")
    return identity


def validate_ec2(pair, regions):
    for region in regions:
        progress(f"Checking EC2 DescribeInstances permission in {region}.")
        aws_call(pair, region, "ec2", "describe-instances", "--dry-run", expected_error="DryRunOperation")


def validate_replacement(args):
    if not shutil.which("aws"):
        raise RotationError("Install the AWS CLI")
    regions = sorted(set(args.aws_region or [DEFAULT_AWS_REGION]))
    print(f"Mode: replacement key validation only ({', '.join(regions)})")
    new_pair, _, _ = read_credentials(args.credentials_stdin)
    replacement_identity(new_pair, regions[0])
    validate_ec2(new_pair, regions)
    print("AWS accepted the replacement key and the EC2 DescribeInstances permission checks.")


def secret_pair(secret):
    try:
        return tuple(base64.b64decode(secret["data"][field], validate=True).decode("ascii")
                     for field in (KEY_ID, KEY_SECRET))
    except (KeyError, ValueError):
        ns, name = secret["metadata"]["namespace"], secret["metadata"]["name"]
        raise RotationError(f"Secret {ns}/{name} lacks a readable AWS key pair") from None


def ccx_protection(snapshot, pairs, ccx):
    protected = {ccx} | {ref for ref in pairs if ref[1] == CCX_SOURCE}
    source_ids = {pairs[ref][0] for ref in protected}
    pools = {name for name, ref in snapshot.pool_credentials.items()
             if name == CCX_POOL or re.search(r"(?:^|-)ccx(?:-|$)", name)
             or (ref is not None and pairs[ref][0] in source_ids)}
    protected.update(ref for ref, owners in snapshot.owners.items() if owners & pools)
    for ref in protected:
        if snapshot.owners.get(ref, set()) - pools:
            raise RotationError(f"CCX and another pool share Secret {ref[0]}/{ref[1]}. Review ownership before rotating")
    ids = {pairs[ref][0] for ref in protected}
    protected |= {ref for ref, pair in pairs.items() if pair[0] in ids}
    return protected, ids


def select_previous(pair, supplied, new_pair, label):
    if supplied is not None and (supplied == new_pair[0] or pair[0] not in (supplied, new_pair[0])):
        raise RotationError(f"Previous {label} key ID must match its current credential unless already rotated")
    return supplied or pair[0]


def plan(secrets, snapshot, source, ccx, anchor_name, target, new_pair, previous_id, previous_hive_id):
    pairs = {ref: secret_pair(secret) for ref, secret in secrets.items()}
    protected, ccx_ids = ccx_protection(snapshot, pairs, ccx)
    if source in protected or new_pair[0] in ccx_ids or {previous_id, previous_hive_id} & ccx_ids:
        raise RotationError("A requested credential overlaps CCX. No changes can be planned")

    desired = set()
    if target != "hive":
        select_previous(pairs[source], previous_id, new_pair, "ACM")
        desired.add(source)
    if target != "acm":
        anchor = snapshot.pool_credentials.get(anchor_name)
        if not anchor or anchor == source or anchor in protected:
            raise RotationError("Select an AWS Hive anchor pool with its own credential outside CCX")
        old_hive_id = select_previous(pairs[anchor], previous_hive_id, new_pair, "Hive")
        scope = set(snapshot.owners) - protected - {source}
        if pairs[anchor][0] == new_pair[0] and previous_hive_id is None and any(pairs[r][0] != new_pair[0] for r in scope):
            raise RotationError("The Hive anchor already uses the new key. Supply the previous Hive key ID to check remaining copies")
        desired.update(ref for ref in scope if pairs[ref][0] in (old_hive_id, new_pair[0]))
    if target == "hive" and pairs[source] != new_pair and any(pairs[ref][0] == pairs[source][0] for ref in desired):
        raise RotationError("The ACM source shares the selected Hive key. Use --target=both for this key")
    if target == "acm" and pairs[source] != new_pair and any(
        pairs[ref][0] == pairs[source][0] for ref in set(snapshot.owners) - protected - {source}
    ):
        raise RotationError("Hive uses the selected ACM key. Use --target=both for this key")

    updates = []
    old_pairs = {}
    for ref, pair in pairs.items():
        if ref in protected:
            state = "PROTECTED (CCX)"
        elif ref not in desired:
            state = "SKIP (out of scope)"
        elif pair[0] == new_pair[0]:
            if pair != new_pair:
                raise RotationError(f"The new access key ID has a different secret in {ref[0]}/{ref[1]}")
            state = "CURRENT"
        else:
            if secrets[ref].get("immutable"):
                raise RotationError(f"Secret {ref[0]}/{ref[1]} is immutable")
            if old_pairs.setdefault(pair[0], pair) != pair:
                raise RotationError("The same old key ID has inconsistent stored secrets")
            updates.append(ref)
            state = "UPDATE"
        print(f"{state:21} {ref[0]}/{ref[1]}")
    # Rotate the Hive anchor after its copies and the ACM source last, so a retry can infer both old IDs.
    anchor = snapshot.pool_credentials.get(anchor_name)
    updates.sort(key=lambda ref: (ref == source, ref == anchor, ref))
    return Plan(updates, desired, set(old_pairs.values()), protected)


def patch(cli, target, original, replacement, *, dry_run=False):
    ns, name = target
    ops = [{"op": "test", "path": "/metadata/resourceVersion", "value": original["metadata"]["resourceVersion"]}]
    for field, value in zip((KEY_ID, KEY_SECRET), replacement):
        ops.append({"op": "replace", "path": f"/data/{field}", "value": base64.b64encode(value.encode()).decode()})
    command([*cli, "patch", "secret", name, "-n", ns, "--type=json", "--patch-file=/dev/stdin", "-o", "name",
             *(["--dry-run=server"] if dry_run else [])],
            f"{'Preflight' if dry_run else 'Update'} Secret {ns}/{name}", input_text=json.dumps(ops), parse_json=False)


def load_secrets(cli, refs):
    return {ref: get(cli, "secret", ["-n", ref[0]], ref[1]) for ref in sorted(refs)}


def verify_secrets(cli, expected):
    for ref, secret in load_secrets(cli, expected).items():
        if secret_pair(secret) != expected[ref]:
            raise RotationError(f"Secret {ref[0]}/{ref[1]} changed unexpectedly. Review before continuing")


def read_reviewed_targets(path, server, namespace, cluster_set):
    try:
        with open(path, encoding="utf-8") as file:
            document = json.load(file)
    except (OSError, ValueError):
        raise RotationError("Could not read the reviewed Hive target file as JSON") from None
    scope = {"server": server, "namespace": namespace, "clusterSet": cluster_set}
    if not isinstance(document, dict) or any(document.get(key) != value for key, value in scope.items()):
        raise RotationError("The reviewed Hive target file does not match the server, namespace, and cluster set")
    refs = document.get("secrets")
    if not isinstance(refs, list) or not refs:
        raise RotationError("The reviewed Hive target file must contain a nonempty secrets list")
    targets = set()
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) != {"namespace", "name"}:
            raise RotationError("Each reviewed Hive target must contain only a namespace and a Secret name")
        names = (ref["namespace"], ref["name"])
        if any(not isinstance(name, str) or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", name)
               for name in names):
            raise RotationError("A reviewed Hive target has an invalid namespace or Secret name")
        if names in targets:
            raise RotationError("The reviewed Hive target file contains a duplicate Secret")
        targets.add(names)
    return targets


def verify_reviewed_targets(reviewed, discovered):
    if reviewed != discovered:
        for namespace, name in sorted(reviewed - discovered):
            progress(f"No longer selected: {namespace}/{name}")
        for namespace, name in sorted(discovered - reviewed):
            progress(f"New or unreviewed target: {namespace}/{name}")
        raise RotationError("The Hive rotation targets differ from the reviewed list. Recheck the scope and backups")
    progress(f"The rotation plan matches all {len(reviewed)} reviewed Hive targets.")


def run(args):
    cli = hub_client(args)
    source = (args.namespace, args.credential)
    ccx = (args.namespace, args.ccx_source)
    if source[1] in (CCX_SOURCE, args.ccx_source):
        raise RotationError("The CCX credential is excluded from rotation")
    scope = (args.namespace, args.cluster_set, args.credential)
    reviewed = (read_reviewed_targets(args.reviewed_hive_targets, args.server, args.namespace, args.cluster_set)
                if args.reviewed_hive_targets else None)
    print(f"Hub {args.server}, namespace {args.namespace}, cluster set {args.cluster_set}", flush=True)
    print("Mode: apply" if args.apply else "Mode: preview (read only)", flush=True)
    progress(f"Discovering Hive pools and deployments for {args.namespace}/{args.cluster_set}.")
    snapshot = inventory(cli, *scope)
    print(f"Found {len(snapshot.pool_credentials)} AWS pools and {len(snapshot.deployments)} deployments.")
    if snapshot.claimed_only:
        print("Cluster-wide listing is forbidden. Coverage is limited to zero-size pools and deployments reachable from their claims.")
        if args.apply and reviewed is None:
            raise RotationError("Apply requires cluster-wide ClusterDeployment list access or --reviewed-hive-targets for a limited Hive rotation")
        if reviewed is not None:
            progress("Limited Hive rotation. Keep the old AWS key active for deployments outside this inventory.")
    new_pair, previous_id, previous_hive_id = read_credentials(args.credentials_stdin, args.target)
    refs = set(snapshot.targets) | {ccx}
    # An override can add a protected source on Collective without unprotecting the known CCX source.
    if args.server == HUB and args.namespace == CLUSTER_SET:
        refs.add((args.namespace, CCX_SOURCE))
    progress(f"Reading {len(refs)} hub Secrets to build the rotation plan.")
    secrets = load_secrets(cli, refs)
    if PROVIDER_LABEL not in secrets[source]["metadata"].get("labels", {}):
        raise RotationError("The source Secret is missing the ACM credential label")

    rotation = plan(secrets, snapshot, source, ccx, args.hive_anchor_pool, args.target, new_pair, previous_id, previous_hive_id)
    if reviewed is not None:
        verify_reviewed_targets(reviewed, rotation.desired)
    regions = sorted({region for ref in rotation.desired for region in snapshot.targets[ref]})
    if not regions:
        regions = sorted({region for ref, values in snapshot.targets.items() if ref not in rotation.protected for region in values})
    if not regions:
        raise RotationError("No non-CCX AWS regions found for validation")
    identity = replacement_identity(new_pair, regions[0])
    source_pair = secret_pair(secrets[source])
    for old_pair in sorted(rotation.old_pairs, key=lambda pair: (pair != source_pair, pair[0])):
        label = "Existing ACM key" if old_pair == source_pair else "Existing shared Hive key"
        if aws_identity(old_pair, regions[0], label) != identity:
            raise RotationError(f"{label} belongs to a different IAM principal than the replacement. If ACM and Hive use different IAM users, rotate each with its own replacement and --target")
    validate_ec2(new_pair, regions)
    print("AWS accepted the replacement key and the EC2 DescribeInstances permission checks.")

    if not rotation.updates:
        print("No matching Secrets require an update.")
        return
    if not args.apply:
        print(f"Plan only. Found {len(rotation.updates)} Secrets to update.")
        return

    progress(f"Starting Kubernetes server dry runs for {len(rotation.updates)} Secret updates.")
    for ref in rotation.updates:
        patch(cli, ref, secrets[ref], new_pair, dry_run=True)
    if inventory(cli, *scope) != snapshot:
        raise RotationError("Pool or deployment references changed during preflight. Rerun the plan")
    original_pairs = {ref: secret_pair(secret) for ref, secret in secrets.items()}
    verify_secrets(cli, {ref: original_pairs[ref] for ref in rotation.protected})

    completed = 0
    try:
        progress("Server dry runs and inventory checks passed. Applying the rotation plan.")
        for ref in rotation.updates:
            patch(cli, ref, secrets[ref], new_pair)
            verify_secrets(cli, {ref: new_pair})
            completed += 1
            print(f"Verified {ref[0]}/{ref[1]}", flush=True)
        progress("Rechecking the deployment inventory and all Secret values after rotation.")
        if inventory(cli, *scope) != snapshot:
            raise RotationError("Pool or deployment references changed during rotation")
        verify_secrets(cli, {ref: new_pair if ref in rotation.desired else original
                             for ref, original in original_pairs.items()})
    except (RotationError, KeyboardInterrupt):
        print(f"Verified {completed}/{len(rotation.updates)} individual updates. Keep the old IAM keys active and rerun the plan to check current state.", file=sys.stderr)
        raise
    if snapshot.claimed_only:
        print("Reviewed Hive Secrets verified. Deployments outside this inventory may still use the old AWS key. Keep it active.")
    else:
        print("Hub rotation verified. See utility/README.md for spoke, lifecycle, and old key retirement checks.")


def rotation_default(setting, builtin):
    return os.environ.get(f"ACM_TOOLS_ROTATION_{setting}") or builtin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=rotation_default("HUB", HUB), help=f"expected hub API server (built-in default: {HUB})")
    parser.add_argument("--context", help="kubeconfig context for the expected server")
    parser.add_argument("--namespace", default=rotation_default("NAMESPACE", CLUSTER_SET),
                        help=f"pool and credential namespace (built-in default: {CLUSTER_SET})")
    parser.add_argument("--cluster-set", default=rotation_default("CLUSTER_SET", CLUSTER_SET),
                        help=f"pool cluster set label (built-in default: {CLUSTER_SET})")
    parser.add_argument("--credential", default=rotation_default("SOURCE", SOURCE),
                        help=f"ACM credential Secret name (built-in default: {SOURCE})")
    parser.add_argument("--hive-anchor-pool", default=rotation_default("HIVE_ANCHOR_POOL", HIVE_ANCHOR_POOL),
                        help=f"pool whose Secret identifies the shared Hive key (built-in default: {HIVE_ANCHOR_POOL})")
    parser.add_argument("--ccx-source", default=rotation_default("CCX_SOURCE", CCX_SOURCE),
                        help=f"protected CCX credential Secret name (built-in default: {CCX_SOURCE})")
    parser.add_argument("--target", choices=("both", "acm", "hive"), default="both", help="credential groups to rotate (default: both)")
    parser.add_argument("--reviewed-hive-targets", metavar="FILE",
                        help="require the Hive plan to match the reviewed Secret references in this JSON file")
    parser.add_argument("--credentials-stdin", action="store_true", help="read AWS key fields and optional old_access_key_id and old_hive_access_key_id as JSON on stdin")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write and verify the planned hub Secret changes")
    mode.add_argument("--validate-replacement", action="store_true", help="check only the new key in AWS, without connecting to the hub")
    parser.add_argument("--aws-region", action="append",
                        help=f"AWS region for --validate-replacement (repeatable, built-in default: {DEFAULT_AWS_REGION})")
    args = parser.parse_args()
    if args.reviewed_hive_targets and (args.target != "hive" or args.validate_replacement):
        parser.error("--reviewed-hive-targets requires a Hive preview or apply with --target hive")
    if args.aws_region and not args.validate_replacement:
        parser.error("--aws-region requires --validate-replacement")
    if args.validate_replacement and not args.aws_region:
        args.aws_region = [rotation_default("AWS_REGION", DEFAULT_AWS_REGION)]
    if any(not re.fullmatch(AWS_REGION_PATTERN, region) for region in args.aws_region or []):
        parser.error("--aws-region or ACM_TOOLS_ROTATION_AWS_REGION must be an AWS region name")
    if not args.validate_replacement:
        args.server = args.server.rstrip("/")
        if not re.fullmatch(r"https://[a-zA-Z0-9.-]+(?::[0-9]+)?", args.server):
            parser.error("--server must be an HTTPS Kubernetes API URL")
        for option, value in (("--namespace", args.namespace), ("--cluster-set", args.cluster_set),
                              ("--credential", args.credential), ("--hive-anchor-pool", args.hive_anchor_pool),
                              ("--ccx-source", args.ccx_source)):
            if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value):
                parser.error(f"{option} must be a Kubernetes resource name")
    try:
        if args.validate_replacement:
            validate_replacement(args)
        else:
            run(args)
    except RotationError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except (EOFError, getpass.GetPassWarning, KeyboardInterrupt):
        print("Credential rotation stopped", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError):
        print("Unexpected Kubernetes or AWS response. Check the selected context and resource schema.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
