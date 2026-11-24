# Utilities

Stand-alone helpers. Unlike the tools in `bin/`, they do not use `lib/common.sh` or
`config.sh`.

| Utility | Purpose |
|---------|---------|
| [`konflux-pr-image.py`](#konflux-pr-imagepy) | Find the Konflux image built for a GitHub PR: build status, image, quay.io expiry, and `image-override.json` entries |
| [`rotate-pool-aws-credentials.py`](#rotate-pool-aws-credentialspy) | Validate and rotate the AWS IAM key in an ACM credential and the Hive Secrets that use it |

## rotate-pool-aws-credentials.py

The defaults are the Collective API at `https://api.collective.aws.red-chesterfield.com:6443`,
namespace and cluster set `obs-int-analytics`, and ACM credential `observability-llc-aws`.
The shared Hive key is identified by the AWS Secret referenced by `obsint-sno-4xlarge-422`.
The utility follows AWS Secret references on the pools and their Hive `ClusterDeployment`
objects, including per-cluster `obsint-*` namespaces on the hub. It rotates the ACM source
and the Hive Secrets using the anchor's old key. It updates a shared Secret once. The CCX
credential, its pool and deployment Secret references, and copies of those key IDs are
protected. The known Collective CCX pool `obsint-sno-m5metal-420` is also protected by
name, so a separate key in that pool or its deployments stays protected. Namespace names
alone do not put a Secret in scope.

### Usage

Requires Python 3.9+, `oc` or `kubectl`, AWS CLI, and a kubeconfig context with trusted TLS
for the selected hub. The hub user needs read access to the pools, claims, deployments, and
referenced Secrets, plus patch access to those Secrets for `--apply`.

```bash
# Validate just the replacement key with AWS, before checking Collective.
utility/rotate-pool-aws-credentials.py --validate-replacement

# Preview the affected Secret names and validate the new key in AWS.
utility/rotate-pool-aws-credentials.py

# Preflight, apply, and verify the hub Secret updates.
utility/rotate-pool-aws-credentials.py --apply
```

`--validate-replacement` prompts for just the new pair and checks STS and EC2 permission
in `us-west-2`. Use `--aws-region` to check another region. This mode skips hub access and
cannot be combined with `--apply`. A successful check confirms the key works in AWS.
The rotation preview still compares IAM identities and requires its own validation.
Progress logs identify the AWS check and show only the last four characters of the access
key ID. Secret access keys are omitted from all output.

The prompts hide both parts of the key. For automation, pipe a JSON object directly from
your secret manager into `--credentials-stdin`. The fields are `aws_access_key_id`,
`aws_secret_access_key`, and optional `old_access_key_id` and `old_hive_access_key_id`.
Supply `old_hive_access_key_id` when the anchor already uses the new key but there may be
copies on the previous key. An explicitly supplied previous key must agree with its source
or its source must already carry the replacement.
`--context` chooses among matching kubeconfig contexts. Use
`--target acm` or `--target hive` with the corresponding replacement if the two groups
use different IAM users. The default `--target both` requires the same IAM identity for
every old key it replaces.

### Environment defaults

Command-line flags take precedence over nonempty environment variables, followed by the
built-in defaults. The environment variables are for deployment settings. Enter the
replacement key at the prompts or pass it on stdin using the fixed Hive field names
`aws_access_key_id` and `aws_secret_access_key`.

| Flag | Environment variable | Built-in default |
| --- | --- | --- |
| `--server` | `ACM_TOOLS_ROTATION_HUB` | `https://api.collective.aws.red-chesterfield.com:6443` |
| `--namespace` | `ACM_TOOLS_ROTATION_NAMESPACE` | `obs-int-analytics` |
| `--cluster-set` | `ACM_TOOLS_ROTATION_CLUSTER_SET` | `obs-int-analytics` |
| `--credential` | `ACM_TOOLS_ROTATION_SOURCE` | `observability-llc-aws` |
| `--hive-anchor-pool` | `ACM_TOOLS_ROTATION_HIVE_ANCHOR_POOL` | `obsint-sno-4xlarge-422` |
| `--ccx-source` | `ACM_TOOLS_ROTATION_CCX_SOURCE` | `ccx-clusterpool-aws` |
| `--aws-region` | `ACM_TOOLS_ROTATION_AWS_REGION` | `us-west-2` |

The region override applies only to `--validate-replacement`. Rotation uses the regions
reported by Hive. The namespace and cluster set can be configured independently. Using
`--ccx-source` on Collective in `obs-int-analytics` adds a protected source alongside
the built-in CCX source.

### Rotation sequence

1. Create the replacement key for the same AWS IAM user and keep the old key active.
   Coordinate a window with pool operators so claims, scaling, and provisioning do not race
   with the rotation. Inventory other workloads that might also use the old key.
2. Review the default plan. The tool uses AWS STS to compare the IAM identity of both keys
   when the old key is still present, and checks EC2 `DescribeInstances` permission with an
   AWS dry run in the relevant regions. These checks do not prove provisioning or cleanup.
   An STS failure identifies the replacement, existing ACM key, or existing shared Hive key.
   For `InvalidClientTokenId`, check that the identified key is active and that its access
   key ID and secret are the matching pair in the expected AWS account.
3. Apply the plan. The utility runs Kubernetes server dry runs before writing and changes
   both key fields together with a resource version check. It reads back each update and
   checks the discovered scope again after the last write, including the protected CCX references.
   The Hive anchor and ACM source are written last. Kubernetes has no transaction across
   Secrets. If a run stops partway through, keep the IAM keys active and rerun the plan.
4. Check the Cloud Credential Operator (CCO) on the affected OpenShift clusters. If a cluster
   uses the old key in its cloud credential Secret, rotate it using the procedure for that
   cluster's OpenShift version and CCO mode. This is separate from Hive's copy on the hub.
5. Provision and clean up a disposable cluster, and resume an agreed hibernating cluster
   during the change window. Verify that the AWS lifecycle calls used the new key. After
   checking all consumers, deactivate the old key and monitor before deleting it. The utility
   does not change cluster power or pool size, modify spoke credentials, or manage IAM keys.

### Limited Hive rotation

If the hub account cannot list deployments cluster-wide, the utility can follow assigned
claims for pools whose desired and observed inventory are both zero. A normal apply
requires a cluster-wide deployment list. For a limited rotation in this situation, use
`--target hive --reviewed-hive-targets FILE` with both the preview and apply. The JSON
file must contain the expected `server`, `namespace`, and `clusterSet`, and a `secrets`
array of reviewed `namespace` and `name` references. It contains no credential values.
The live plan must match that list exactly, including targets that are already current.

From the repository root, set `reviewed` to the path of your local target file.
Run the preview first and check the listed Secret names and AWS validation result.

```bash
reviewed=./path/to/reviewed-hive-targets.json

./utility/rotate-pool-aws-credentials.py \
  --target hive --reviewed-hive-targets "$reviewed"
```

**Without `--apply`**, the script reads Collective, checks the reviewed list and AWS key,
and prints the proposed Secret updates. It makes no changes to Collective.

Once the preview passes and you have reviewed the targets, run the apply command in the
same terminal with the same target file.

```bash
./utility/rotate-pool-aws-credentials.py \
  --target hive --reviewed-hive-targets "$reviewed" --apply
```

**With `--apply`**, the script rebuilds and validates the plan, runs server dry runs,
updates the two AWS key fields in the reviewed Hive Secrets, and reads them back to verify
the writes. The ACM and CCX credentials are outside this Hive rotation.

Collect a rollback snapshot for the reviewed targets and keep the old key active. This
mode verifies only the reviewed Hive Secrets. A hub admin needs to check deployments
outside the claim inventory and outstanding cleanup requests before the old key can be
retired.

See [ACM credential management](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/clusters/cluster_mce_overview),
[OpenShift cloud credential rotation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/postinstallation_configuration/changing-cloud-credentials-configuration),
and [AWS IAM key management](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-keys-admin-managed.html).

## konflux-pr-image.py

PRs to MCO and MCOA get Konflux builds. Each build pushes an image to
`quay.io/redhat-user-workloads/crt-redhat-acm-tenant/<component>:on-pr-<full commit SHA>`.
For a PR (or one commit), the script prints, per image:

- the Konflux build check (running, success or failure) with a link to the PipelineRun
- the full image reference
- whether the tag is in quay.io, when it was pushed, and when it expires

At the end it prints entries you can paste into `image-override.json`.

It reads the image names from the commit's own `.tekton/*-pull-request.yaml` files, so
nothing is hardcoded per repo or per release branch.

### Requirements

- `python3` (tested with 3.9). PyYAML is optional; without it the script uses a small
  built-in parser.
- `gh`, logged in (`gh auth login`) with an account that can read the repo.
- Network access to `api.github.com` and `quay.io`. quay.io is read without a login.

### Usage

```bash
utility/konflux-pr-image.py <URL> [--sha SHA] [--wait [--interval SEC] [--timeout MIN]]
```

Pass the full GitHub URL. The repo comes from the URL, so forks and repos with other
names work as they are.

| URL | What it looks at |
|-----|------------------|
| `https://github.com/<owner>/<repo>/pull/<number>` | The PR head commit |
| `https://github.com/<owner>/<repo>/pull/<number>/commits/<sha>` | One commit of the PR |
| `https://github.com/<owner>/<repo>/commit/<sha>` | A commit, without a PR |

Anything after the PR number, like `/files` or `#issuecomment-...`, is ignored. Short
SHAs work.

| Option | Meaning |
|--------|---------|
| `--sha SHA` | Look at this commit of the PR instead of its head. Not allowed with a commit URL. |
| `--wait` | Poll until every Konflux build on the commit has finished, then print the report. With a PR URL and no `--sha`, it follows new pushes to the PR. |
| `--interval SEC` | Seconds between polls with `--wait` (default 60). |
| `--timeout MIN` | Minutes to wait at most with `--wait` (default 60). |

Examples:

```bash
utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/748
utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-operator/pull/2829
utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/746 --wait
utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/746 --sha eea9cd5
```

Example output for MCOA PR #746 (run on 2026-10-28). An MCOA PR builds one image. An MCO
PR builds five: `endpoint-monitoring-operator`, `grafana-dashboard-loader`,
`metrics-collector`, `multicluster-observability-operator` and `rbac-query-proxy`. Times
are in your local time zone.

```
PR #746 stolostron/multicluster-observability-addon [OPEN]: fix(addon): report health for non-OpenShift right-sizing-only clusters
  release-5.0 <- rajusem:release-5.0-fixes
  https://github.com/stolostron/multicluster-observability-addon/pull/746
  commit dd3db3b7017eac51f14fb2de0fc57e11f85ecbb4

multicluster-observability-addon-acm-50
  build : success at 2026-10-27 22:32:42 IST (took 15m)
          https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/crt-redhat-acm-tenant/pipelinerun/multicluster-observability-addon-acm-50-on-pull-request-t6666
  image : quay.io/redhat-user-workloads/crt-redhat-acm-tenant/multicluster-observability-addon-acm-50:on-pr-dd3db3b7017eac51f14fb2de0fc57e11f85ecbb4
  quay  : in quay, pushed 2026-10-27 22:31:38 IST, expires 2026-11-01 22:31:38 IST (in 4d 13h)
  digest: sha256:452f5f4a64d26330407c32d5c6ff3290a3600667c2a36102b107d1d0c49c5246

Image override entries for image-override.json (keep only the ones you need):
[
    {
        "image-key": "multicluster_observability_addon",
        "image-name": "multicluster-observability-addon-acm-50",
        "image-remote": "quay.io/redhat-user-workloads/crt-redhat-acm-tenant",
        "image-tag": "on-pr-dd3db3b7017eac51f14fb2de0fc57e11f85ecbb4"
    }
]
```

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | Every image is in quay.io and not expired |
| 2 | Not all ready: a build is running or failed, or a tag is missing or expired |
| 3 | `--wait` timed out |
| 1 | Error: bad URL, or a `gh` call failed |

### Use the image on a hub

1. Copy the entries you need into `image-override.json` in the acm-tools root. The fields
   are the same. For an MCO PR, keep only the images you want to replace.
2. Apply them. Do not pass `--tag` or `--registry`: they overwrite every entry.

   ```bash
   bin/image-override apply
   bin/image-override status
   ```

The entries also work in any image-override ConfigMap that the MCH annotation
`installer.open-cluster-management.io/image-overrides-configmap` points to.

### Things to know

- Tags expire 5 days after the build. After that, nobody can pull the image and the
  script shows `EXPIRED`. A new image needs a new Konflux build, for example from a new
  commit on the PR.
- A pod that already runs an expired image keeps running from the node's image cache. A
  pod that has to pull it, for example on another node, fails.
- The MCO and MCOA repos under `quay.io/redhat-user-workloads/crt-redhat-acm-tenant` are
  public (checked 2026-10-28). Pulling needs no login and no pull secret, only network
  access to quay.io. Images that run on managed clusters (MCO's `metrics-collector` and
  `endpoint-monitoring-operator`) are pulled by those clusters, so they need quay.io
  access too.
- Image names carry the ACM release: `-acm-50` on `release-5.0` and `-acm-51` on `main`
  (2026-10). `image-key` drops that suffix and uses underscores, for example
  `multicluster-observability-addon-acm-50` → `multicluster_observability_addon`.
