# Plan — acm-tools support for configurable right-sizing evaluation intervals

Upstream change: [stolostron/multicluster-observability-addon#728](https://github.com/stolostron/multicluster-observability-addon/pull/728)
(`feat(rightsizing): make evaluation intervals configurable via ConfigMap`, merged 2026-10-26 into `main`).

Status: **rev 6** — revised after architecture / PE / QE review (§7 records the adjudication, including
the findings rejected as false positives), W10 (§8), and the strict **ACM >= 5.1** gate with an
explicit `--release 5.1` interval-only opt-in.

### Applicability — ACM >= 5.1

The evaluation-interval feature ships in **ACM 5.1 and later**. Verified against the `upstream` remote
(not `origin`, which is a personal fork):

| Branch | `COMPONENT_VERSION` | Has the feature |
|--------|---------------------|-----------------|
| `upstream/main` | 5.1.0 | yes |
| `upstream/release-5.0` | 5.0.0 | no |

**acm-tools cannot express `>= 5.1` as an auto-detected behavior token today**, and the obvious fix is
the wrong one. `detect_release`
(`lib/common.sh:241-263`) collapses *any* major-5 hub to the token `5.0`, so `release_is_50` is true on
5.1 too and there is no `release_is_51`. Adding one (W8) means touching 28 `release_is_50` call sites
and all six tools' `--release` regexes — a bigger, riskier diff than the feature itself. This change
adds only the explicit 5.1 override to `rs-e2e` and inherited-release validation; it does not change
the global behavior token or other tools' CLI contracts.

There is a much cheaper route, because `detect_release` **already fetches the exact version and then
throws it away**: `version=$(… '{.status.currentVersion}')` at `lib/common.sh:250` is read, reduced to
`major`/`minor`, and afterwards used only in a log line. Exporting it costs one line and lets the gate
be a real numeric comparison (W1a), which also means 5.2, 6.0 and so on need no further edits.

So the gate is expressed directly rather than through release tokens, and **W8 stays out of scope**
(see D9). The capability probe (D1) remains as the second gate, because `>= 5.1` and "the deployed MCOA
actually has the feature" are different questions. A detected pre-5.1 release always skips these tests,
even with a custom image; a user can deliberately opt in with `--release 5.1`, which selects only the
interval phases by default and then probes the deployed MCOA.

> **Ground-truth note.** The local MCOA working tree at `$MCOA_REPO_DIR` is checked out on the
> **pre-merge** branch `feat/rightsizing-configurable-evaluation-intervals`, whose `handler.go` still
> *backfills* the interval keys — the opposite of what merged. Its `origin` is a personal fork, not
> stolostron; use the `upstream` remote. Treat `gh pr diff 728` (saved at `/tmp/pr728.diff`) as the
> authority, and pin any `--build mcoa` to the merge commit.

---

## 1. What the upstream feature actually does

Two new keys under `prometheusRuleConfig` in the `rs-namespace-config` and `rs-virt-config` ConfigMaps
(namespace `open-cluster-management-observability`).

| Key | Controls | Allowed (inclusive) | Default |
|-----|----------|---------------------|---------|
| `evaluationInterval` | `Interval` of the rolling-window rule groups (`…-5m.rule`) **and** the PromQL subquery lookback inside them (`[5m:]` → `[<value>:]`) | `5m` … `1h` | `5m` |
| `evaluationInterval1d` | `Interval` of the daily-aggregation rule groups (`…-1d.rule` / `…-1d.rules`). The `[1d]` aggregation window itself is unchanged | `15m` … `6h` | `15m` |

Bounds are **inclusive** — `validateInterval` rejects only `d < min || d > max`, and upstream's table
tests list `5m, 300s, 300000ms, 1h, 60m, 3600s` and `15m, 900s, 900000ms, 6h, 360m, 21600s` as valid.
Any single-unit Prometheus duration (`ms|s|m|h|d|w|y`) is accepted, so `1800s` and `30m` are equivalent
and both flow verbatim into the rendered rule. An empty / absent key is **valid** and means "default".

Facts that drive the acm-tools work — all verified against the merged diff, not the PR description:

1. **MCOA-only.** `multicluster-observability-operator` has no interval handling (`grep -rn
   prometheusRuleConfig operators/` → no hits; on `main` the `rs-utility` package no longer generates
   rules). In MCO (Policy) mode the keys are inert.
2. **Names are stable.** Group names keep their `-5m` / `-1d` suffixes and recorded series keep their
   `:5m` suffix at every interval. Dashboards and the federation list are untouched. Only
   `spec.groups[].interval` and the subquery `[X:]` change.
3. **The VM CPU `rate()` window is pinned.** `rate(kubevirt_vmi_cpu_usage_seconds_total{…}[5m:])` stays
   `[5m:]` at every interval (`cpuUsageRateWindow` const); only the outer `max_over_time(…)[X:]` follows
   the setting. Consequence: a blanket "no `[5m:]`" assertion is **wrong** for the virt rule.
4. **Validation is per key, with a write-back.** An invalid value is replaced by the operator's last
   cached valid value for that key, or by the hardcoded default when nothing is cached (e.g. after an
   operator restart), and the ConfigMap is rewritten. Rejected: not a single-unit duration (`1h30m`),
   zero, out of range, and a bare YAML number (`evaluationInterval: 5` parses to the string `"5"`).
5. **MCOA serialises `prometheusRuleConfig` as YAML, always.** `FormatJSON` has **zero callers**:
   `GetDefaultNamespaceConfigData` / `GetDefaultVirtualizationConfigData` (`builder.go:160,170`) and
   `revertConfigMap` (`handler.go:368`) all use `FormatYAML`. **YAML is the primary path, not a
   fallback.** The comments at `bin/rs-e2e:2931` and `:2977` ("MCOA stores it as JSON") are stale and
   should be corrected in this change.
6. **Write-back does not touch `placementConfiguration`** and does not add the interval keys when they
   were absent (both carry `omitempty`). It writes them unquoted: `evaluationInterval: 5m`.
7. **No backfill.** Unlike the aggregator keys, the interval keys are deliberately *not* added to an
   existing ConfigMap. A missing key means its default. Only a *newly created* ConfigMap gets them.
   Rationale upstream: every write re-renders the addon for all managed clusters and would loop against
   a GitOps/policy owner.
8. **Wasteful ordering is a log-only warning.** `evaluationInterval` coarser than `evaluationInterval1d`
   is legal and never reverted; logged once per *change of the pair* (`recordOrderingState`), so absence
   of the line proves nothing.
9. **Rejections and the ordering warning are observable only in the MCOA addon-manager log** — no status
   condition, no event. They are `Logger.Info`, not errors.
10. **Changing an interval perturbs the data once.** Upstream `types.go`: "Prometheus moves a rule group
    to new run times when its interval changes, and each run looks back only one interval, so the
    stretch between the last run at the old interval and the first run at the new one can be covered by
    no run at all… After any change the percentile profiles take about a day to settle."
11. **MCOA ignores ConfigMap *delete* events on purpose.** `RSConfigMapPredicate` sets
    `DeleteFunc: func(e event.DeleteEvent) bool { return false }`
    (`handlers/rs_resources.go:28`), so `oc delete configmap rs-namespace-config` triggers **no**
    reconcile. Recreation only happens inside `Build()`, on a trigger from some other source.

### Current acm-tools coverage (corrected)

* Existence assertions on both ConfigMaps throughout `rs-e2e`, `rs-status`, `rs-mode-switch`,
  `rs-collect-must-gather`, `cluster-diagnose`.
* `recommendationPercentage` edits — phases 4 (`bin/rs-e2e:2934`) and 10 (`:2980`).
* `.data.config` edit — phase 7 (`:2527`). `.data.placementConfiguration` whole-blob rewrite — phase 8
  (`:2604`, `:2663`), **including an "MCOA did not auto-detect the ConfigMap change" restart fallback
  (`:2612`, `:2673`) that the new phases will need**. Phase 8 is the precedent template, not phase 10.
* `mcoTrigger` patch — `bin/rs-mode-switch:301`.
* Three pre-existing defects in the above, all caused by assuming JSON — see §8 and **W10**.
* No coverage at all of `cpuAggregator` / `memoryAggregator`.

---

## 2. Design decisions

### D1 — strict `>= 5.1` version gate, explicit override, then a capability probe

Two gates in series, cheapest first:

| Version / invocation | Deployed MCOA | Outcome |
|---|---|---|
| Detected version >= 5.1 | any | probe, then run (a 5.1+ hub is expected to support it; a probe failure is a **FAIL**, not a SKIP) |
| Detected version < 5.1 | any, including custom/post-#728 | **SKIP** with the detected version; a custom image does not bypass the release gate |
| Unknown/unreadable version, no explicit override | any | **SKIP** and log that ACM >= 5.1 or an explicit override is required |
| Explicit `--release 5.1` (detection bypassed) | any | opt in, probe, then run if supported; by default select only 10a–10c |

The release gate **narrows and explains**; after a supported release or explicit opt-in, the probe
**confirms capability**. Keeping both matters:

* Without the version gate, an older hub pays a probe to learn what its MCH version already said.
* Without the probe, an explicitly opted-in 5.0/custom-image setup or a 5.1 hub with a dead pipeline
  could report PASS-by-assumption.

A pre-#728 MCOA silently ignores the unknown keys (`ParseConfigMapData` uses non-strict
`sigYaml.Unmarshal`) rather than erroring, so the explicit-override path must distinguish unsupported
images from a dead pipeline — hence the sentinel and resourceVersion precondition below.

Probe mechanics: in one edit set a **sentinel `recommendationPercentage` of `125`** (deliberately not
phase 10's `120`) plus the two interval keys, then require an observed change of the ManifestWork's
`resourceVersion` before reading either signal.

* percentage propagated **and** interval propagated → **supported**
* percentage propagated **and** interval did not → unsupported (`deployed MCOA predates MCOA#728`)
* no resourceVersion change at all → **FAIL** (pipeline dead) — never SKIP

Cached in `RS_EVAL_INTERVAL_SUPPORT=unknown|yes|no` so 10b/10c reuse it; each phase re-probes when run
standalone. The sentinel and the resourceVersion precondition exist because phase 10 reverts 120→110
**without waiting for propagation** (`bin/rs-e2e:3008-3011`) and runs immediately before 10a — without
them, a dead pipeline reports SKIP, which reads as green in `print_summary`.

### D2 — Phase numbering `10a` / `10b` / `10c`, listed explicitly in the default sets

`phase_selected` prefix-matches `^[0-9]+[a-z]$` (`bin/rs-e2e:247`), so `--phases 10` goes from one phase
to four and there is no way to decline. That is acceptable only because 10c no longer deletes anything
by hand (D3), but it must be **visible**: list `10a,10b,10c` explicitly in the 5.x default set rather
than relying on inheritance, and document in `--help` that `--phases 10` selects all four. Since
`detect_release` collapses every major-5 hub into the `5.0` behavior token, the runtime gate skips an
actual 5.0 hub; a manual `--release 5.1` instead defaults to only 10a–10c.
Note `--phases 10a-10c` does **not** expand — `expand_phase_ranges` only matches `^[0-9]+-[0-9]+$`.

### D3 — 10c drives ConfigMap recreation through the feature toggle, never a raw delete

Fact 11 makes "delete the ConfigMap and wait" unimplementable. Instead reuse the path phases 9a/9b
already exercise: `patch_rs_features false true` makes MCOA delete `rs-namespace-config`
(`bin/rs-e2e:2719`), `patch_rs_features true true` makes it recreate it with defaults (`:2761`). That is
a supported API, generates real events, and is no more destructive than the 9a/9b pair that already runs
in the default 5.0 set. Capture the **whole `prometheusRuleConfig` *and* `placementConfiguration`**
before the toggle — `createDefaultConfigMap` writes `GetDefaultRSPrometheusRuleConfig()` wholesale, which
also resets `namespaceFilterCriteria`, `recommendationPercentage` and both aggregators.

### D4 — Make the restored value deterministic instead of weakening the assertion

The restored value after a rejection comes from the operator's **in-memory** cache, so `== "5m"` is
flaky — and `ensure_mode` has a `rollout restart` fallback (`bin/rs-e2e:630`) that clears it
non-deterministically. Rather than settle for "changed and in range" (which a broken implementation that
always writes the wrong field's default would still pass), **write the invalid value first, then
`rollout restart` MCOA**. The first reconcile after restart has an empty `lastValidIntervals`, so the
cold-cache branch must write exactly `5m` / `15m` — a hard equality assertion that *also* covers the
branch a real user hits most. Pair it with the field-specific reason string
(`outside the allowed range 5m to 1h` vs `15m to 6h`) so the two keys cannot be confused.

### D5 — Restore the *captured original blob*, not hardcoded defaults

Writing literal `5m` / `15m` on cleanup would permanently backfill keys that fact 7 says must stay
absent, corrupting the precondition for 10c and making `rs-status`'s `(default)` display wrong forever.
Each phase captures the original `prometheusRuleConfig` string up front, stashes it in a global, and
`e2e_on_exit` restores that exact string — the `E2E_STOPPED_VM` pattern (`bin/rs-e2e:942`), but carrying
a payload rather than a flag.

### D6 — Split the helper into a pure parser, a cluster wrapper, and a writer

`rs-collect-must-gather analyze` runs **offline** — it dispatches and `exit 0`s before
`init_acm_tools` and explicitly supports `--release` with no cluster (`bin/rs-collect-must-gather:742`).
A helper that does a live `$KUBE_CLI get` cannot serve it. And every phase needs to **write** keys, which
the existing `try fromjson … catch gsub` idiom cannot do: `gsub` only rewrites a key that is already
present with a known literal, so it cannot add an absent key (the no-backfill state) or remove one.
Hence: pure blob parser + thin cluster/file wrappers + an explicit writer.

### D7 — Mutually exclusive with `--data-plane` in the same invocation

Fact 10 plus phases 21a/21b running the deployed dashboard's own `1d` queries means ~10 interval
transitions shortly before the data-plane phases is avoidable risk for no benefit. Skip 10a/10b/10c when
`DATA_PLANE=true`, with a reason. (Phases 20/21 themselves query only rolling `:5m` series — no `:1d`
series appears anywhere in `rs-e2e` — so their exposure is one interval against phase 19's 30-minute
wait. The constraint is cheap insurance, not a hard correctness fix.)

### D8 — Detect bound drift rather than trusting copied constants

`MaxEvaluationInterval = AggregationWindow / MinSamplesPerAggregationWindow` (24h/24) and
`MaxEvaluationInterval1d = AggregationWindow / MinDailyRunsPerAggregationWindow` (24h/4) are **derived**,
and the floors already moved once (`7f577f0 fix(rightsizing): raise the evaluation interval floors to
the defaults`). Hardcoding `1h` / `6h` in `lib/common.sh` will silently drift. Two cheap detectors:
the operator's rejection message embeds the live range (`outside the allowed range %s to %s`), so W6 can
parse it out and compare; and when `--build mcoa` runs, grep the four constants out of
`$MCOA_REPO_DIR/internal/analytics/rightsizing/rulebuilder.go` and warn on mismatch.

### D9 — W1a delivers the `>= 5.1` gate; W8 (the 5.1 release *token*) stays out of scope

W1a satisfies the gating requirement additively and at ~10 lines. W8 is a separate concern: making
`RS_RELEASE` itself precise. What W8 would additionally buy, none of it needed here:

* `rs-status` and must-gather stop printing `Release: 5.0` on a 5.1 hub, so artifacts collected from a
  5.1 cluster stop being mislabelled — the one real defect left, and a reporting one;
* a distinct auto-detected 5.1 behavior token. `rs-e2e` does have a narrow explicit `--release 5.1`
  path that defaults to `10a,10b,10c`; auto-detected 5.1 retains the existing 5.x phase set.

Cost: 28 `release_is_50` call sites plus six `--release` regexes across six files, all-or-nothing
because of the `lib/common.sh:243` inherited-value trap, and requiring a judgement call at each site
about whether it means "5.0 exactly" or "5.x" — the kind of audit that is cheap to get subtly wrong and
expensive to detect. Larger and riskier than the feature itself.

Recommendation: **ship the feature with W1a; track W8 separately.** Do not interleave them — if W8 is
taken later, W1a keeps working unchanged, since it reads the MCH version rather than the token.

---

## 3. Work items

Suggested order — **W1a → W1 → W10 → W2/W3/W4 → W5/W6 → W7**. W10 is numbered last only because it was found
last; it should land second, right after the helpers it consumes. Retrofitting the four existing call
sites proves the helpers against real cluster data before three new phases depend on them, and it is
the only part of this change that needs neither a 5.x hub nor an MCOA rebuild. W8 is not in scope.

### W1a — `>= 5.1` version comparison in `lib/common.sh`

Deliberately **narrow**: it does not change auto-detection of `RS_RELEASE`, `release_is_50/217/216`, or
any of the 28 call sites. It accepts `5.1` only in the `rs-e2e` override and common inherited-release
validation so the explicit opt-in works through child commands; the other tools' CLI regexes remain
unchanged. W8 remains out of scope.

1. In `detect_release`, export the version it already fetched (`lib/common.sh:250`) instead of
   discarding it: `export RS_MCH_VERSION="$version"`. Set it **in both branches** — on the
   short-circuit path at `:242` (an explicit `--release` or a parent export) `$version` is never
   fetched, so `RS_MCH_VERSION` must be left empty there rather than stale. Empty means "unknown";
   only explicit `--release 5.1` opts in to the probe, while other overrides and undetected releases
   skip (D1).
2. `release_at_least <major.minor>` — numeric compare of `RS_MCH_VERSION`'s first two components.
   Returns rc 1 when `RS_MCH_VERSION` is empty **or** unparseable, and callers must treat that as
   "unknown" (skip unless explicitly opted in), not "below". Compare components as integers (`10#` prefix to avoid an octal reading of
   e.g. `08`), never lexically — `"5.10" < "5.9"` as strings.
3. Export `RS_MCH_VERSION` so child tools inherit it, matching how `RS_RELEASE` is already propagated.

Why not reuse `RS_RELEASE`: it is a deliberately coarse *behaviour* token, inherited across processes
and validated against a closed regex at `:243`. Overloading it with precision would make that regex a
version whitelist needing an edit per z-stream. Keep the coarse token for behaviour, add a precise
value for comparisons.

### W1 — Helpers in `lib/common.sh`

Constants (in the file's `export X="${X:-…}"` form):

```
RS_EVAL_INTERVAL_DEFAULT=5m      RS_EVAL_INTERVAL_MIN=5m      RS_EVAL_INTERVAL_MAX=1h
RS_EVAL_INTERVAL_1D_DEFAULT=15m  RS_EVAL_INTERVAL_1D_MIN=15m  RS_EVAL_INTERVAL_1D_MAX=6h
```

| Function | Behaviour |
|----------|-----------|
| `rs_rule_config_get <blob> <key>` | **Pure string parser.** YAML first (the primary path, fact 5), JSON second. Empty + rc 1 when absent. |
| `rs_rule_config_set <blob> <key> <value>` | Returns the blob with `key` set, **inserting it when absent**. Normalises to YAML. |
| `rs_rule_config_unset <blob> <key>` | Returns the blob with `key` removed. |
| `rs_rule_config_from_cluster <cm> <ns>` | Thin wrapper: `$KUBE_CLI get … -o jsonpath='{.data.prometheusRuleConfig}'`. |
| `rs_rule_config_from_file <path>` | Offline wrapper for must-gather artifacts. |
| `rs_duration_ms <value>` | Single-unit Prometheus duration → **milliseconds**. Mirrors upstream `^[0-9]+(ms\|s\|m\|h\|d\|w\|y)$`; rejects compound, zero, non-numeric. |
| `rs_eval_interval_check <value> <min> <max>` | rc 0 valid (**including empty = default**), rc 1 malformed, rc 2 out of range. Bounds **inclusive**. |

Implementation constraints, each tied to a concrete trap:

* **YAML regex must be anchored.** `evaluationInterval` is a strict prefix of `evaluationInterval1d`;
  an unanchored match returns the wrong value whenever only the 1d key is set. Use
  `^[[:space:]]*evaluationInterval:[[:space:]]*`. Add "only `evaluationInterval1d` set" as a helper
  test case.
* **Tolerate user quotes** (`evaluationInterval: "10m"`) — MCOA accepts them and re-emits unquoted.
* **Milliseconds, not seconds** — `500ms` is legal-but-out-of-range; a seconds-based helper floors it to
  0 and reports "malformed" instead of "out of range", defeating the rc 1 / rc 2 distinction.
* **rc-returning helpers abort `set -e` scripts.** `run_phase` wraps phase bodies in `set +e`
  (`bin/rs-e2e:271`), but `rs-status` and `rs-collect-must-gather` run under plain `set -euo pipefail`.
  Every call site there needs `|| rc=$?` or an `if`.
* Repo pitfalls from `AGENTS.md`: stderr inside command-substituted functions; `grep … >/dev/null` not
  `grep -q` in pipes; no `|| echo 0` after `grep -c`; `$KUBE_CLI --request-timeout=10s`, never GNU
  `timeout`. For early-exit parsing, capture into a variable first and parse the here-string — the
  `producer | head -1` SIGPIPE hazard is not fixed by swapping `head` for `awk`, since awk is then the
  early exiter. (This is a local guideline for new code, not a repo-wide cleanup.)
* **Writes use `patch --type=merge` on `.data.prometheusRuleConfig`**, not `kube_apply_json` — the
  phases deliberately race the operator's own `Update`, and a whole-object `apply` (`lib/common.sh:137`)
  invites a lost update in either direction.

### W2 — `bin/rs-e2e` phase `10a` — "Evaluation interval propagation (MCOA)"

Gate per D1's table: `release_at_least 5.1`, then the capability probe. Skip on `DATA_PLANE=true` (D7).
`ensure_mode mcoa`. Capture the original blobs (D5). Phases 10b and 10c carry the same gates.

Assertions are per-ManifestWork, per-rule-name, per-group, via `jq` **equality** —
`manifestwork_contains` is a raw grep over every ManifestWork on every managed cluster
(`bin/rs-e2e:525-537`), so it cannot tell the namespace rule from the virt rule and a partial rollout
reads as success.

`acm-rs-namespace-prometheus-rules`, at `evaluationInterval=10m` / `evaluationInterval1d=30m`:

* `acm-right-sizing-namespace-5m.rule`, `acm-right-sizing-cluster-5m.rule` → `interval == 10m`
* `acm-right-sizing-namespace-1d.rules` (**plural**), `acm-right-sizing-cluster-1d.rule` (**singular**)
  → `interval == 30m`
* rolling-group exprs contain `[10m:]` and **no** `[5m:]`
* `record` names still end in `:5m`; 1d-group exprs still contain `[1d]`

`acm-rs-virt-prometheus-rules` — group names carry a `-vm-` infix
(`acm-vm-right-sizing-namespace-5m.rule` etc.), and the "no `[5m:]`" rule **does not apply**:

* same four interval equalities, under the `-vm-` names
* `acm_rs_vm:namespace:cpu_usage:5m` and `acm_rs_vm:cluster:cpu_usage:5m` keep
  `rate(kubevirt_vmi_cpu_usage_seconds_total{…}[5m:])` while their outer window is `[10m:]` (fact 3)
* the other six virt rolling rules contain `[10m:]` and no `[5m:]`

Live-only coverage — the part no upstream unit test can reach:

* **Hard** (not soft) assertion on every reachable spoke, following phase 3's shape (`bin/rs-e2e:2087`):
  the real `PrometheusRule` in `openshift-monitoring` has the expected `spec.groups[].interval`, and the
  group reports no `lastError` in `/api/v1/rules`. This is the only check that proves prometheus-operator
  **admits** a non-default interval and that Prometheus **runs** the `[X:]` subquery.
* One boundary pass at the inclusive maxima `1h` / `6h`, and one in `s` units (`1800s` / `3600s`) — both
  legal, both unverified against the CRD's `Duration` pattern and the spoke admission path.

Revert to the captured blobs; assert the ManifestWork returns to `5m` / `15m`.

### W3 — `bin/rs-e2e` phase `10b` — "Evaluation interval validation + write-back (MCOA)"

Cut from eight cases to four. Upstream already table-tests every bound, unit and malformed shape
(`TestValidateEvaluationInterval`, `…1d`, `…_OutOfRangeDurationsAreRejected`,
`…_ZeroValueDurationIsInvalid`, `…_YAMLNumberIntervalIsRejected`, plus `TestBuild_EvaluationIntervals`).
The live-only signal is that the write-back **reaches the API server and survives contention** — one
case proves that; the rest buy a write-back wait each. Both keys are validated by independent
`sanitizeInterval` calls, so pair them in a single write.

| Case | Write | Asserts |
|------|-------|---------|
| 1. cold-cache, both keys | `evaluationInterval: 3m` + `evaluationInterval1d: 12h`, **then `rollout restart` MCOA** | hard equality `5m` / `15m` after rollout (D4); log carries both field-specific ranges |
| 2. malformed shape | `evaluationInterval: 1h30m` | rewritten to a valid in-range duration, **unquoted** |
| 3. aggregator × interval | `cpuAggregator: [M80]` + `evaluationInterval: 10m` | aggregator reverted, `10m` **preserved** — untested upstream in this direction |
| 4. virt ConfigMap | one invalid value on `rs-virt-config` | written back there and **not** on `rs-namespace-config` (per-ConfigMap cache isolation) |

Invariants, asserted on **parsed values** not bytes (`recommendationPercentage` has no `omitempty`, so a
blob that omitted it is written back as `0`), and only for keys present beforehand:
`placementConfiguration` byte-identical; `namespaceFilterCriteria` and the aggregators preserved; and —
once, at the end, not per case — the ManifestWork group intervals equal the restored values by `jq`
equality. A substring search would be actively wrong here: `0m` is a substring of `10m` and `30m`.

Soft check: `Invalid evaluationInterval` (prefix, so it matches the `1d` variant too) in the MCOA log.

### W4 — `bin/rs-e2e` phase `10c` — "Evaluation interval defaults / no-backfill (MCOA)"

1. **Fresh ConfigMap carries both keys at defaults.** Capture `prometheusRuleConfig` +
   `placementConfiguration`; `patch_rs_features false true` → wait for `rs-namespace-config` to go away;
   `patch_rs_features true true` → wait for recreation; assert `evaluationInterval: 5m` and
   `evaluationInterval1d: 15m` are present; restore the captured keys (D3).
2. **No backfill on an existing ConfigMap.** Remove both keys, then establish a **positive witness**
   before asserting the negative: change `recommendationPercentage` to a fresh sentinel, wait for *that*
   to appear in the ManifestWork, and only then assert the ConfigMap's `metadata.resourceVersion` is
   unchanged by the operator and the rendered intervals are still `5m` / `15m`. Without the witness a
   merely-slow reconcile passes the test.
3. **Wasteful ordering is accepted.** Set `evaluationInterval: 30m` with `evaluationInterval1d: 15m`;
   hard-assert both survive and the ManifestWork renders `30m` / `15m`; soft-assert the warning line
   (fact 8 means its absence proves nothing — say so in the output wording). Revert.

### W5 — `bin/rs-status`

```
  ConfigMaps (open-cluster-management-observability):
    rs-namespace-config: exists   eval=10m  eval1d=30m
    rs-virt-config: exists        eval=5m (default)  eval1d=15m (default)
```

* absent key renders as `(default)`, never as an error (empty is valid);
* yellow on `evaluationInterval > evaluationInterval1d`; red on malformed / out of range, naming the
  allowed range and that MCOA will revert it;
* MCOA mode: compare against the rendered ManifestWork group intervals and flag drift — **comparing
  normalised durations, not strings**, since `300s` and `5m` are the same interval and the write-back
  preserves the user's spelling;
* `show_status_json` gains `rs_config: {namespace: {evaluation_interval, evaluation_interval_1d, source,
  rendered}, virtualization: {…}}`.

### W6 — `bin/rs-collect-must-gather`

* **Collection does need a change**: the ConfigMaps are captured with `-o yaml` (`:551`), which nests
  `prometheusRuleConfig` as a block scalar under `data:` — awkward to parse without `yq`. Also collect
  them as `-o json` alongside. ManifestWorks (`:592`) and both MCOA logs (`:517`, `:531`) are already
  JSON/text and need nothing.
* `analyze` (offline, so it uses `rs_rule_config_from_file`): print both intervals per ConfigMap,
  validate against the bounds, flag wasteful ordering, compare against the collected ManifestWork group
  intervals, and grep the MCOA logs for `Invalid evaluationInterval` / the ordering line.
* Parse the live bound out of the rejection message and compare against the local constants (D8).
* Note in the output that these are `Logger.Info` lines and `LOG_LINES=500` by default (`:765`), so
  absence is not evidence — the existing MCOA log check only greps for `error` (`:366`) and will never
  see them.

### W7 — Documentation

* `README.md` — new subsection on both keys (**ACM >= 5.1, MCOA mode only**; bounds **inclusive**;
  defaults; YAML-always serialisation; no-backfill); rows for 10a/10b/10c; note that `--phases 10`
  selects all four and `10a-10c` is not a valid range; rs-status description; new env vars. State
  plainly that the phases need detected ACM >= 5.1 or an explicit `--release 5.1` opt-in; older/unknown
  releases skip even with a custom MCOA image, so readers can tell a legitimate SKIP from a broken setup.
  Also fix the existing "**Group 2** … (`--mode-switch` required)"
  label at `README.md:481`, which is already inaccurate for phase 10 on 5.0.
* `docs/TROUBLESHOOTING.md` — "Evaluation interval not taking effect": value keeps reverting (out of
  range / compound / bare number, with the exact per-key ranges), rules still at `5m` on an older MCOA,
  a GitOps owner fighting the write-back, where the operator logs the reason. **`1h30m` is rejected
  because it is compound; `90m` is rejected for `evaluationInterval` too because the ceiling is `1h` —
  it is legal only for `evaluationInterval1d`.**
* `.claude/skills/rs-e2e/SKILL.md` — the three phases plus diagnosis rows for the SKIP reason and the
  restart-dependent case 1.
* `AGENTS.md` — the `rs-e2e` one-liner says "22 phases"; update the count.

### W8 — *(NOT part of this change — track separately; see D9)* ACM 5.1 release token

Superseded as a gating mechanism by W1a. Kept so the analysis is not lost: the remaining real defect is
that a 5.1 hub reports `Release: 5.0` in `rs-status` and must-gather output. Corrected scope if taken:

* **28 call sites** of `release_is_50` + 1 definition — rs-e2e 19, rs-mode-switch 3, must-gather 2,
  rs-status 2, setup-observability 1, cluster-diagnose 1, lib/common.sh 1 (def).
* **Six `--release` validation regexes**, not one: `bin/rs-e2e:186`, `bin/rs-status:45`,
  `bin/rs-mode-switch:584`, `bin/rs-collect-must-gather:748` and `:782`, and — critically —
  `lib/common.sh:243`, which validates an **inherited** `RS_RELEASE` and hard-exits. Since
  `detect_release` exports `RS_RELEASE` to children, emitting `5.1` without updating that line makes
  every `rs-e2e → setup-observability` / `rs-mode-switch` call `exit 1` on a 5.1 hub.
* **Not every site means "MCOA-only".** `apply_release_phase_defaults` (`bin/rs-e2e:141`) selects a
  *phase set* — if it becomes `release_is_5x`, any later `5.1` branch is unreachable. And `phase_0a`
  (`:1623`, "auto-migration is 5.0-only") is a product judgement, not a mechanical rename. Keep exact
  matching at those two; use `release_is_5x` only for the MCOA-only gates.
* Auto-detected 5.1 still uses the existing 5.x default set; manual `--release 5.1` is a narrowly
  scoped `rs-e2e` opt-in that selects only `10a,10b,10c` by default, without changing other tools' 5.0
  behavior token.

Risk if dropped: an ACM 5.1 hub reports `Release: 5.0` in `rs-status` and must-gather output. Behaviour
stays correct everywhere, because every 5.x gate — including this feature's — is satisfied by the
collapsed token.

### W9 — `config.sh`

```bash
export TIMEOUT_RS_INTERVAL_PROPAGATION="${TIMEOUT_RS_INTERVAL_PROPAGATION:-180}"
export RS_EVAL_INTERVAL_TEST="${RS_EVAL_INTERVAL_TEST:-10m}"
export RS_EVAL_INTERVAL_1D_TEST="${RS_EVAL_INTERVAL_1D_TEST:-30m}"
```

### W10 — Fix the three pre-existing JSON-assumption defects (see §8 for evidence)

These are not caused by #728; they are caused by the same wrong belief that fact 5 corrects, and W1's
helpers fix all three for free. **Do W10 first** — it converts the helpers from new-code-only into
something four existing call sites depend on, which is the cheapest possible proof that they work
before three new phases are built on them. It touches no new behaviour and needs no MCOA rebuild.

| # | Site | Defect | Fix |
|---|------|--------|-----|
| 1 | `bin/rs-e2e:3469-3471`, `:3630-3632` | `jq -r '.recommendationPercentage // 110' … \|\| echo "110"` on a YAML blob: `jq` always fails, so the value is **always** `110`. A hub with a customised percentage silently gets the wrong expected recommendation, and the tier-1 fallback assertions then pass or fail for the wrong reason. | `rp=$(rs_rule_config_get "$(rs_rule_config_from_cluster …)" recommendationPercentage)`, defaulting to `110` on empty **and on `0`** — upstream treats `0` as "use the default" (`namespace/prometheusrule.go:126`, `virtualization/prometheusrule.go:124`), and `0` is what the blob carries whenever the key was absent before a write-back (no `omitempty`). |
| 2 | `bin/rs-e2e:3630` | Reads **`rs-namespace-config`** inside the VM data-plane phase. The VM recommendation is built from `rs-virt-config` (`VirtualizationConfigMapName`, consumed at `virtualization/prometheusrule.go:124`). Latent only because both default to `110`. | Read `rs-virt-config`. |
| 3 | `bin/rs-e2e:2935`, `:2954`, `:2981`, `:3010` | The `try fromjson … catch gsub` writers in phases 4 and 10 are coupled to the string literals `recommendationPercentage: 110` / `: 120`. On a hub whose percentage is anything else the `gsub` matches nothing, the patch is a silent no-op, and the phase then times out waiting for a change that was never written — a confusing failure, not a false pass. | `rs_rule_config_set`. Also lets phases 4 and 10 capture/restore the original value instead of hardcoding the revert to `110`. |
| 4 | `bin/rs-e2e:2931`, `:2977` | Comments say "MCO stores prometheusRuleConfig as YAML; MCOA stores it as JSON." Both halves of the MCOA claim are wrong (fact 5), and these comments are why defects 1 and 3 exist. | Correct them; they are the only in-repo statement of the serialisation contract. |

Severity: defect 1 is a **silent wrong value**, defects 2-4 are latent or produce loud failures. All four
are invisible on a default-configured hub, which is why no existing run has caught them.

Scope guard: W10 changes only *how* these sites read and write the percentage. It does not alter what
phases 4, 10 or the data-plane phases assert.

---

## 4. Runtime budget

Primitives: `wait_until` polls at 5s (`bin/rs-e2e:330`); phase 10's ManifestWork wait is a hardcoded
120s (`:2986`); phase 8's non-detection fallback is `rollout restart` + `rollout status` + reconcile ≈
150s.

| Phase | Happy | Worst (every wait times out, one restart fallback) |
|-------|-------|----------------------------------------------------|
| 10a | 60-90 s (3 propagation waits + boundary case + spoke checks) | ~11 min |
| 10b | 3-4 min (case 1 includes a deliberate MCOA restart) | ~14 min |
| 10c | 2-3 min | ~12 min |
| **Total added** | **~7 min** | **~37 min** |

The tail is dominated by MCOA failing to auto-detect ConfigMap changes — the same limitation phases 8
and 10 already carry (`bin/rs-e2e:2616`). Do **one** shared restart up front if the probe is slow,
rather than a fallback per case.

W10 adds no runtime: it swaps `jq`/`gsub` expressions for helper calls at sites that already run. If
anything it *removes* the ~120 s timeout that defect 3 currently inflicts on phases 4 and 10 whenever
the hub is not at `110`.

On hubs below 5.1 the added cost is **zero** — the three phases skip at the version gate before probing,
even with a post-#728 MCOA. Passing `--release 5.1` is the deliberate opt-in and selects only these
phases by default.

## 5. Risks

| # | Risk | Mitigation |
|---|------|------------|
| R1 | A dead pipeline is reported as SKIP, which reads as green | D1's `125` sentinel + required resourceVersion change |
| R2 | Cleanup backfills keys that must stay absent | D5 — restore the captured blob, never literals |
| R3 | Interval churn perturbs data-plane phases | D7 — mutually exclusive with `--data-plane` |
| R4 | Reader handles only JSON and goes blind after a write-back | Fact 5 — YAML is the primary branch; both covered, with the 1d-prefix case tested |
| R5 | Log-grep assertions are suppressed by `recordOrderingState` or trimmed by `LOG_LINES` | Soft checks only; output wording says absence proves nothing |
| R6 | Local constants drift from upstream's derived bounds | D8 — parse the live range from the rejection message; compare against `$MCOA_REPO_DIR` on `--build` |
| R7 | `--phases 10` silently becomes four phases | D2 — explicit listing + `--help` note |
| R8 | On pre-5.1 hubs the phases SKIP, and a long run of SKIPs reads as coverage that does not exist | SKIP reason states the detected release and says custom images do not bypass the gate; README documents explicit 5.1 opt-in |
| R9 | `RS_MCH_VERSION` empty on the `--release` short-circuit path is misread | Only explicit `--release 5.1` opts in; other overrides/unknown versions skip, and validation checks the default phase selection |
| R10 | W8, if ever taken, half-applied breaks every child-tool invocation | `lib/common.sh:243` called out; W8 is all-or-nothing and out of this change |

## 6. Out of scope

* **Hubs below ACM 5.1** — per the >= 5.1 applicability. Although a custom MCOA may technically support
  the keys, the tests intentionally skip on these hubs; a user must explicitly pass `--release 5.1` to
  opt in, which defaults to only the interval phases.
* Verifying the real sample cadence changed on the spoke (needs ≥2 intervals of Thanos data).
* MCO (Policy) mode — the keys are inert there (fact 1).
* `bin/rs-mode-switch` — nothing it does reads or writes these keys.
* `bin/cluster-diagnose` — it does assert the RS ConfigMaps exist (`:612`), so an interval check would
  not be off-theme; it is simply low value next to `rs-status`.
* **W8** (ACM 5.1 release *token*) — superseded for gating by W1a; see D9. The residual `Release: 5.0`
  mislabelling on 5.1 hubs is real but independent, and should be tracked on its own.

## 7. Review adjudication

Accepted and folded in above: missing writer helper; YAML-is-primary inversion; offline `analyze`
consumer; `DeleteFunc` blocker; probe sentinel collision with phase 10; restore-the-blob; `jq` equality
over substring search; vacuous negative assertions; cold-cache restart for determinism; virt assertion
split (`-vm-` names, `[5m:]` exception, `.rules`/`.rule`); inclusive bounds; `s`/`ms` coverage;
aggregator × interval gap; anchored YAML regex; milliseconds; empty-is-valid; rc-under-`set -e`;
unit-normalised drift comparison; `90m` doc error; unquoted write-back; log-grep prefix;
`recommendationPercentage` lacking `omitempty`; config.sh export form; W8 census (28, not 31) plus the
five extra `--release` regexes and the self-contradiction; collection needs `-o json`; bound-drift
detection; AGENTS.md phase count.

Rejected or downgraded after checking:

* **"10a's rule-content assertions are cost without signal" — rejected.** They are `jq` filters over one
  already-fetched ManifestWork; marginal wall-clock is ~zero. The prioritisation point was right and is
  honoured by *adding* the live-only checks, not by deleting these. The same argument against W3's
  eight rows **is** valid — each needed its own write-back wait — and W3 is cut to four.
* **"Interval churn breaks data-plane phases 20/21" — downgraded.** No `:1d` series appears anywhere in
  `rs-e2e`; phases 20/21 query only rolling `:5m` series, so their exposure is one interval against a
  30-minute wait. Real exposure is indirect, through 21a/21b executing the deployed dashboard's own 1d
  queries. D7 adopted anyway because it is free.
* **"`sed | head -1` must become `awk`" — downgraded to a local guideline.** The SIGPIPE hazard is real
  but is not fixed by swapping the early exiter; the fix is to capture first. It is not an `AGENTS.md`
  pitfall and the repo already uses the pattern in several places, so no repo-wide cleanup.
* **"`kube_apply_json` definitely loses updates" — unproven, mitigated anyway.** Whether `kubectl apply`
  carries a resourceVersion precondition here was not settled without a live cluster; `patch
  --type=merge` on the single key removes the question at no cost.
* **GitOps-owner fight — documented, not tested.** Worth a troubleshooting entry; a synthetic test would
  mostly re-assert the write-back already covered by case 1.

## 8. Evidence for W10 — the three pre-existing defects

All found while reviewing, all pre-existing, none caused by #728. **Now in scope as W10.** A full
census of `prometheusRuleConfig` in `bin/` and `lib/` returns exactly seven sites, all accounted for:

1. **`bin/rs-e2e:3469-3471` and `:3630-3632`** — `… -o jsonpath='{.data.prometheusRuleConfig}' | jq -r
   '.recommendationPercentage // 110' 2>/dev/null || echo "110"`. MCOA writes YAML (fact 5), so `jq`
   parses nothing and the value is **always** `110`. Both feed `awk "… usage * (rp/100)"` to compute
   the expected tier-1 recommendation, so on a hub with a customised percentage the comparison is
   silently against the wrong number. Applies to the namespace path (`:3469`) and the VM path (`:3630`).
2. **`bin/rs-e2e:3630` reads the wrong ConfigMap** — `rs-namespace-config`, inside the VM data-plane
   phase. Confirmed upstream that the VM rule takes its percentage from `rs-virt-config`
   (`VirtualizationConfigMapName`, `types.go:31`) via `configData.PrometheusRuleConfig.
   RecommendationPercentage` at `virtualization/prometheusrule.go:124`. Latent only while both
   ConfigMaps hold the default. Note upstream maps `0 → 110` at `:126`, so the helper must too.
3. **`bin/rs-e2e:2935`, `:2954`, `:2981`, `:3010`** — the `try fromjson … catch gsub` writers in phases
   4 and 10. `fromjson` always fails on YAML, so the `gsub` branch is the real path, and it is pinned to
   the literals `recommendationPercentage: 110` / `: 120`. On a hub at any other percentage the
   substitution matches nothing, the patch is a no-op, and the phase times out waiting for a change
   that was never written. Loud, but misdiagnosed as a propagation failure.
4. **`bin/rs-e2e:2931`, `:2977`** — "MCO stores prometheusRuleConfig as YAML; MCOA stores it as JSON."
   The MCOA half is false and is the proximate cause of 1 and 3.

## 9. Validation plan

1. `shellcheck` on every touched script (`.shellcheckrc` exists; `shellcheck` itself is **not** installed
   here — `brew install shellcheck` first).
2. `--help` on `rs-e2e`, `rs-status`, `rs-collect-must-gather` (no cluster needed).
3. `bin/rs-status` and `--json` against a live hub before any phase runs.

**W1a — the version gate and override defaults, no cluster mutation:**

4. `release_at_least` table: `5.1.0`/`5.1`/`5.2.3`/`6.0.0` → true; `5.0.0`/`2.17.1` → false;
   `""`/garbage → rc 1 **and callers treat it as unknown**. Include `5.10.0` vs `5.9.0` to prove the
   comparison is numeric, and a `08`-style component to prove no octal misparse.
5. On a 5.x hub: `detect_release` logs the collapsed token *and* exports the exact version;
   `release_is_50` behaviour is **unchanged** from before W1a (the additive guarantee).
6. `RS_RELEASE=5.0 bin/rs-e2e --phases 10a` (short-circuit path) → skip with a clear gate reason;
   custom images do not bypass it and no ConfigMap is written.
7. `RS_RELEASE=5.1` with no `--phases` → selected phases are exactly `10a,10b,10c`; explicit
   `--phases` continues to take precedence.

**W10 next, since W1's helpers carry it:**

8. Unit-exercise the helpers on fixture blobs: YAML, JSON, only-`evaluationInterval1d`-set (the prefix
   trap), quoted values, absent key, `recommendationPercentage: 0`.
9. On a hub left at the default `110`, run `--phases 4,10` and the data-plane phases → results
   **unchanged** from a pre-W10 run. This is the regression gate.
10. Set the hub's `recommendationPercentage` to `125`, re-run `--phases 4` → passes (today it hangs and
   fails, defect 3), and the data-plane phases compute against `125` not `110` (defect 1).

**Then the feature phases:**

11. `bin/rs-e2e --phases 10a` on a **2.17 or 5.0 hub, even with a post-#728 custom MCOA** → SKIP naming the version gate,
    with no cluster write and the ConfigMap untouched.
12. On a pre-5.1 hub, explicitly pass `--release 5.1` with no `--phases` → only 10a/10b/10c are
    selected; the deployed MCOA capability probe decides whether they pass or fail.
13. Build MCOA **at PR #728's merge commit** from the `upstream` remote — not `$MCOA_REPO_DIR` HEAD,
    which is the pre-merge branch whose `backfillConfigKeys` would make W4 step 2 fail for the wrong
    reason, and not `origin`, which is a personal fork. Make that a precondition check inside 10c, not
    just a line here. Then `--phases 10,10a,10b,10c` → PASS.
14. On a genuine **5.1** hub: same run → PASS, and a probe failure there reports **FAIL, not SKIP**.
15. `bin/rs-e2e --phases 10b` standalone (exercises the re-probe path).
16. Interrupt 10a mid-wait with Ctrl-C → `e2e_on_exit` restores the captured blob byte-for-byte.
17. `bin/rs-e2e --data-plane --yes` → 10a/10b/10c SKIP with the `--data-plane` reason.
18. `rs-collect-must-gather collect` + `analyze` → intervals reported, bounds parsed from the log, no
    false findings.
