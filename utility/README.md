# Utilities

Stand-alone helpers. Unlike the tools in `bin/`, they do not use `lib/common.sh` or
`config.sh`, and they never connect to a cluster.

| Utility | Purpose |
|---------|---------|
| [`konflux-pr-image.py`](#konflux-pr-imagepy) | Find the Konflux image built for a GitHub PR: build status, image, quay.io expiry, and `image-override.json` entries |

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
