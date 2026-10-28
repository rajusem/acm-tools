#!/usr/bin/env python3
"""konflux-pr-image.py: find the Konflux image built for a GitHub PR.

Works for stolostron MCO and MCOA, and for any repo whose .tekton/*-pull-request.yaml
pipelines push an `output-image`. For the PR head commit (or the commit in the URL) it
prints, per image: the Konflux build check, the image reference, and whether the tag is in
quay.io, with its push time and expiry (MCO/MCOA PR images expire 5 days after the build).
Then it prints image override entries in the format of the acm-tools image-override.json
(the same format an MCH image-override ConfigMap uses). More in utility/README.md.

Needs python3 and gh (logged in). quay.io is read without a login. Times are local time.

The full GitHub URL names the repo, so nothing depends on how a repo is called. Forms:
  https://github.com/<owner>/<repo>/pull/<number>                 the PR head
  https://github.com/<owner>/<repo>/pull/<number>/commits/<sha>   one commit of the PR
  https://github.com/<owner>/<repo>/commit/<sha>                  a commit, no PR

Examples:
  utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/748
  utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-operator/pull/2829
  utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/746 --wait
  utility/konflux-pr-image.py https://github.com/stolostron/multicluster-observability-addon/pull/746 --sha eea9cd5

Exit codes: 0 every image is in quay and not expired; 2 not all ready (building, failed,
missing or expired); 3 --wait timed out; 1 error.
"""
import argparse
import base64
import datetime
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import yaml
except ImportError:
    yaml = None

CHECK_PREFIX = "Red Hat Konflux / "
URL_RE = re.compile(
    r"^https?://(?:www\.)?github\.com/([^/\s]+/[^/\s]+)/"
    r"(?:pull/(\d+)(?:/commits/([0-9a-fA-F]{7,40}))?|commit/([0-9a-fA-F]{7,40}))(?:[/?#].*)?$")
URL_EXAMPLE = "https://github.com/stolostron/multicluster-observability-addon/pull/748"


class Error(Exception):
    pass


class Parser(argparse.ArgumentParser):
    """Exit 1 on a bad command line (argparse uses 2, which here means "not ready")."""

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise Error(f"gh {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return r.stdout


def gh_json(*args):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def parse_url(url):
    """(owner/repo, PR number or None, commit or None) from a GitHub PR or commit URL."""
    m = URL_RE.match(url.strip())
    if not m:
        return None
    repo, number, pr_commit, commit = m.groups()
    return repo, (int(number) if number else None), (pr_commit or commit)


def pr_info(repo, number):
    return gh_json("pr", "view", str(number), "--repo", repo, "--json",
                   "number,title,state,url,headRefOid,headRefName,baseRefName,headRepositoryOwner")


def read_pipeline(text):
    """Return (PipelineRun name, output-image) of one .tekton PipelineRun file."""
    if yaml:
        doc = yaml.safe_load(text) or {}
        params = {p.get("name"): p.get("value")
                  for p in (doc.get("spec") or {}).get("params") or [] if isinstance(p, dict)}
        return (doc.get("metadata") or {}).get("name"), params.get("output-image")
    name = re.search(r"^metadata:[ \t]*\n(?:[ \t]+.*\n|[ \t]*\n)*?  name:[ \t]*(\S+)", text, re.M)
    image = re.search(r"-[ \t]*name:[ \t]*output-image[ \t]*\n[ \t]*value:[ \t]*(\S+)", text)
    return (name.group(1) if name else None), (image.group(1) if image else None)


def pull_request_pipelines(repo, sha):
    """The Konflux pull-request pipelines at this commit and the image each one pushes."""
    try:
        listing = gh_json("api", f"repos/{repo}/contents/.tekton?ref={sha}")
    except Error as e:
        if "404" in str(e):
            return []
        raise
    out = []
    for f in listing or []:
        if f.get("type") != "file" or not f["name"].endswith("-pull-request.yaml"):
            continue
        body = gh_json("api", f"repos/{repo}/contents/{f['path']}?ref={sha}")
        name, image = read_pipeline(base64.b64decode(body["content"]).decode())
        if not image:
            continue
        out.append({
            "pipeline": name or f["name"].replace("-pull-request.yaml", "-on-pull-request"),
            "image": re.sub(r"\{\{\s*revision\s*\}\}", sha, image),
        })
    return sorted(out, key=lambda p: p["pipeline"])


def konflux_checks(repo, sha):
    """Latest Konflux check run per PipelineRun name on this commit."""
    out = gh("api", "--paginate", f"repos/{repo}/commits/{sha}/check-runs?per_page=100",
             "--jq", ".check_runs[] | @json")
    latest = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        run = json.loads(line)
        name = run.get("name") or ""
        if not name.startswith(CHECK_PREFIX):
            continue
        key = name[len(CHECK_PREFIX):]
        if key not in latest or run["id"] > latest[key]["id"]:
            latest[key] = run
    return latest


def quay_tag(image):
    ref, tag = image.rsplit(":", 1)
    host, _, path = ref.partition("/")
    if host != "quay.io":
        return {"state": "unknown", "why": f"not a quay.io image ({host}), not checked"}
    url = (f"https://quay.io/api/v1/repository/{path}/tag/?"
           + urllib.parse.urlencode({"specificTag": tag, "limit": 100}))
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            tags = json.load(r).get("tags") or []
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {"state": "missing", "why": "quay repository not found"}
        return {"state": "unknown", "why": f"quay API answered HTTP {e.code} (private repository?)"}
    except (urllib.error.URLError, TimeoutError) as e:
        return {"state": "unknown", "why": f"quay API not reachable: {e}"}
    tags = [t for t in tags if t.get("name") == tag]
    if not tags:
        return {"state": "missing", "why": "tag not in quay (not pushed yet, or expired and purged)"}
    t = max(tags, key=lambda x: x.get("start_ts") or 0)
    end = t.get("end_ts")
    return {"state": "active" if end is None or end > time.time() else "expired",
            "digest": t.get("manifest_digest"), "pushed": t.get("start_ts"), "expires": end}


def local(ts):
    return datetime.datetime.fromtimestamp(ts).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def iso_ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp()


def span(seconds):
    seconds = int(abs(seconds))
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {rem // 60}m"
    return f"{rem // 60}m"


def check_text(run):
    if not run:
        return "not started (no Konflux check on this commit yet)"
    if run.get("status") != "completed":
        started = run.get("started_at")
        return f"{run.get('status')}" + (f" since {local(iso_ts(started))}" if started else "")
    start, end = iso_ts(run["started_at"]), iso_ts(run["completed_at"])
    return f"{run.get('conclusion')} at {local(end)} (took {span(end - start)})"


def quay_text(q):
    if q["state"] == "active":
        if q.get("expires") is None:
            return f"in quay, pushed {local(q['pushed'])}, no expiry"
        left = q["expires"] - time.time()
        warn = ", less than a day left" if left < 86400 else ""
        return f"in quay, pushed {local(q['pushed'])}, expires {local(q['expires'])} (in {span(left)}{warn})"
    if q["state"] == "expired":
        return (f"EXPIRED {local(q['expires'])} ({span(time.time() - q['expires'])} ago): "
                "a new pod cannot pull it; it needs a new Konflux build")
    return f"{q['state'].upper()}: {q['why']}"


def custom_entry(image):
    ref, tag = image.rsplit(":", 1)
    remote, name = ref.rsplit("/", 1)
    return {"image-key": re.sub(r"-acm-\d+$", "", name).replace("-", "_"),
            "image-name": name, "image-remote": remote, "image-tag": tag}


def report(repo, sha, pr, pipelines, checks):
    """Print the report. True when every image is in quay and not expired."""
    if pr:
        owner = (pr.get("headRepositoryOwner") or {}).get("login") or "?"
        print(f"PR #{pr['number']} {repo} [{pr['state']}]: {pr['title']}")
        print(f"  {pr['baseRefName']} <- {owner}:{pr['headRefName']}")
        print(f"  {pr['url']}")
        head = "" if sha == pr["headRefOid"] else f" (not the PR head; head is {pr['headRefOid']})"
        print(f"  commit {sha}{head}")
    else:
        print(f"{repo} commit {sha}")
    if not pipelines:
        print("\nNo Konflux pull-request pipelines (.tekton/*-pull-request.yaml) at this commit.")
        return False
    ready = []
    for p in pipelines:
        run = checks.get(p["pipeline"])
        q = quay_tag(p["image"])
        print(f"\n{p['image'].rsplit('/', 1)[-1].rsplit(':', 1)[0]}")
        print(f"  build : {check_text(run)}")
        if run and run.get("details_url"):
            print(f"          {run['details_url']}")
        print(f"  image : {p['image']}")
        print(f"  quay  : {quay_text(q)}")
        if q.get("digest"):
            print(f"  digest: {q['digest']}")
        if q["state"] == "active":
            ready.append(p["image"])
    if ready:
        print("\nImage override entries for image-override.json (keep only the ones you need):")
        print(json.dumps([custom_entry(i) for i in ready], indent=4))
    return len(ready) == len(pipelines)


def main():
    ap = Parser(
        description="Find the Konflux image built for a GitHub PR, with its build status and quay expiry.",
        epilog=__doc__.split("\n\n", 2)[2], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url", help=f"full GitHub PR URL, for example {URL_EXAMPLE} (forms below)")
    ap.add_argument("--sha", help="look at this commit of the PR instead of its head")
    ap.add_argument("--wait", action="store_true",
                    help="poll until every Konflux build on the commit has finished")
    ap.add_argument("--interval", type=int, default=60, help="seconds between polls with --wait (default 60)")
    ap.add_argument("--timeout", type=int, default=60, help="minutes to wait at most with --wait (default 60)")
    args = ap.parse_args()
    parsed = parse_url(args.url)
    if not parsed:
        ap.error(f"not a GitHub PR or commit URL: {args.url}\n  example: {URL_EXAMPLE}")
    repo, number, url_sha = parsed
    if url_sha and args.sha:
        ap.error("the URL already names a commit; drop --sha")

    sha = None
    if url_sha or args.sha:
        # The image tag holds the full commit SHA.
        sha = gh("api", f"repos/{repo}/commits/{url_sha or args.sha}", "--jq", ".sha").strip()

    deadline = time.time() + args.timeout * 60
    pipelines_by_sha = {}
    pr = last = None
    while True:
        if number is not None:
            pr = pr_info(repo, number)
        commit = sha or pr["headRefOid"]
        if commit not in pipelines_by_sha:
            pipelines_by_sha[commit] = pull_request_pipelines(repo, commit)
        pipelines = pipelines_by_sha[commit]
        checks = konflux_checks(repo, commit)
        runs = {p["pipeline"]: checks.get(p["pipeline"]) or {} for p in pipelines}
        done = all(r.get("status") == "completed" for r in runs.values())
        if not args.wait or done or not pipelines:
            return 0 if report(repo, commit, pr, pipelines, checks) else 2
        state = (commit, tuple(sorted((k, r.get("status"), r.get("conclusion")) for k, r in runs.items())))
        if state != last:
            if last and last[0] != commit:
                print(f"PR head moved: {last[0]} -> {commit}", flush=True)
            now = datetime.datetime.now().astimezone().strftime("%H:%M:%S %Z")
            parts = [f"{k.replace('-on-pull-request', '')}: {r.get('conclusion') or r.get('status') or 'not started'}"
                     for k, r in sorted(runs.items())]
            print(f"{now} {commit[:12]}  " + ", ".join(parts), flush=True)
            last = state
        if time.time() > deadline:
            print(f"\nTimed out after {args.timeout} min. State now:\n", flush=True)
            report(repo, commit, pr, pipelines, checks)
            return 3
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Error as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
