# Plan Feature Epics

Generate a set of Jira Epics for an ACM feature based on proven patterns from past releases (OBSDA-576, OBSDA-1045, OBSDA-1094).

## Arguments

The user should provide (prompt if missing):
- **feature_name**: Short name of the feature (e.g., "Right-Sizing MCOA Addon Change")
- **phase**: `Dev Preview`, `TP` (Tech Preview), or `GA` (General Availability)
- **acm_version**: Target ACM release (e.g., "2.17")

Optional:
- **parent_ticket**: Jira ticket key from any board (e.g., "OBSDA-1234", "ACM-5678"). If provided, fetch it via MCP to extract title and description for context. Ask the user: "Do you have a parent ticket key for this feature?" with options to provide a key or select "No parent ticket".
- **epic_project**: Jira project for non-ACM epics. Default: `OBSINTA`. User can specify a different project.
- **dry_run**: Default `true`. When `true`, only output the plan for review. When `false`, create the epics in Jira via MCP after user confirms the plan.
- **extra_epics**: Comma-separated list of additional custom epic categories to include beyond the template.

## Workflow

### Step 0: Load defaults from config

Read `.claude/skills/plan-feature-epics/config.env` to load default values:
- `JIRA_SITE` — used as `cloudId` in all MCP calls
- `EPIC_PROJECT` — default project for non-ACM epics
- `ACM_COMPONENT` — default component for ACM epic
- `DEFAULT_LABEL_PREFIX` — label prefix (e.g., `obsint-analytics`)
- `ACTIVITY_TYPE` — default activity type

These are pre-filled defaults. The user can override any of them during Step 2 confirmation.

### Step 1: Ask for parent ticket and fetch context

Ask the user: **"Do you have a parent ticket key for this feature?"** with these options:
- **"Yes, I have one"** — user provides the ticket key (can be from any Jira board: OBSDA, ACM, OBSINT, etc.)
- **"No parent ticket"** — skip parent linking; epics will be created without a parent link

If the user provides a `parent_ticket`, use the Atlassian MCP tool to fetch it:

```
getJiraIssue(cloudId: "{JIRA_SITE}", issueIdOrKey: "<parent_ticket>")
```

Extract the parent's title and description to inform the epic descriptions. If MCP is not connected, skip this step and proceed with user-provided context.

### Step 2: Ask for confirmations

Ask the user to confirm or change the following defaults before generating the plan:
- **ACM Component**: Default `Observability`
- **Epic Project**: Default `OBSINTA` — the Jira project for all non-ACM epics. User can specify a different project (e.g., `OBSDA`, `OBSINT`).

### Step 3: Generate epic list

Build the epic list from the template below. Substitute `{FEATURE}` with the feature name, `{PHASE}` with Dev Preview/TP/GA, and `{VERSION}` with the ACM version.

**Label**: `obsint-analytics-<feature-slug>` (kebab-case of the feature name, e.g., `obsint-analytics-rightsizing`)

**Projects**: The ACM tracking epic goes to **ACM**. All other epics go to **{EPIC_PROJECT}** (default: OBSINTA, user-configurable).

**Fix Version**:
- ACM epic: Set to the ACM release version in `ACM X.Y.0` format (e.g., `ACM 5.0.0`, `ACM 2.17.0`)
- {EPIC_PROJECT} epics: Set to the target quarter (e.g., `2026Q3`). Ask the user to confirm the quarter.

**Parent linking**: If a `parent_ticket` is provided, ALL generated epics must be linked to it as children. If no parent ticket, omit the `parent` field.

**Activity Type**: ALL epics default to `Product / Portfolio Work` (customfield_10464).

### Step 4: Output the plan

Output a formatted table of all epics with:
- Epic # (sequence number)
- Project (ACM or {EPIC_PROJECT})
- Title (summary)
- Epic Name (board display name — customfield_10011, may differ from title)
- Description (brief summary for {EPIC_PROJECT} epics; full structured format for ACM epic)
- Suggested Assignee Role (Dev Lead, Dev, QE, Tech Lead)
- Priority (Major or Normal)
- Phase applicability (ALL, TP-only, GA-only)
- Labels
- Component (ACM epic only)
- Fix Version

After outputting the table, ask the user:
1. Whether they want to adjust any epic titles/descriptions
2. Whether they want to add or remove any epics
3. Whether they are ready to proceed

### Step 5: Create or finish (based on dry_run flag)

#### If `dry_run=true` (default):
Do NOT create any Jira issues. End with:
> Plan complete (dry run). To create these epics, run the skill again with `dry_run=false`.

#### If `dry_run=false`:
After user confirms the plan, create each epic sequentially using MCP. For each epic:

1. **Create the epic** using `createJiraIssue`:
   ```
   createJiraIssue(
     cloudId: "{JIRA_SITE}",
     projectKey: "<ACM or {EPIC_PROJECT}>",
     issueTypeName: "Epic",
     summary: "<title>",
     description: "<description>",
     contentFormat: "markdown",
     additional_fields: {
       "customfield_10011": "<epic_name>",
       "customfield_10464": {"value": "Product / Portfolio Work", "id": "10610"},
       "customfield_10795": {"value": "<XS|S|M|L|XL>"},
       "priority": {"name": "<Major or Normal>"},
       "labels": ["<label1>", "<label2>"],
       "fixVersions": [{"name": "<version>"}],
       "parent": {"key": "<parent_ticket>"},  // omit if no parent
       "components": [{"name": "Observability"}]  // ACM epic only
     }
   )
   ```

2. **Report the created issue key** (e.g., `ACM-12345`, `OBSINTA-678`) after each creation.

3. **If creation fails**, report the error and continue with the next epic. Do not stop the entire batch.

After all epics are created, output a summary table:

```
## Created Epics Summary

| # | Key | Project | Title | Status |
|---|-----|---------|-------|--------|
| 1 | ACM-12345 | ACM | [GA] ... | Created |
| 2 | OBSINTA-678 | OBSINTA | Design Proposal... | Created |
| 3 | — | OBSINTA | [Dev] ... | FAILED: <error> |
...
```

**Important**: Always ask for explicit user confirmation before creating any issues. Never auto-create without the user saying "yes" or "create".

## Epic Template

### Core Epics (ALL phases — always created)

#### 1. ACM Tracking Epic
- **Project**: ACM
- **Title**: `[{PHASE}] {FEATURE} with MCO`
  - Use phase prefix exactly: `[Dev Preview]`, `[TP]`, or `[GA]`
- **Epic Name**: `[{PHASE}] {FEATURE} with MCO`
- **Labels**: 
  - If phase is `GA` or `TP`: `["doc-required", "qe-required"]`
  - If phase is `Dev Preview`: `["qe-not-required", "doc-not-required"]`
- **Component**: `Observability` (confirm with user if different)
- **Fix Version**: ACM release version (e.g., `ACM 5.0.0`)
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Priority**: Major
- **Size**: XL
- **Assignee Role**: Tech Lead
- **Description**: Use the **ACM Epic Description Template** below (full structured format)

##### ACM Epic Description Template

The ACM tracking epic uses a detailed structured description format. Fill in the sections based on the parent ticket context and feature details:

```markdown
# Epic Goal

The goal of this Epic is to {describe what the epic aims to achieve} as part of the ACM (MCO) deployment based on a configuration/feature flag for [{parent_ticket}]({parent_ticket_url}) feature request.

## Why is this important?

{Business justification — why this feature matters, customer demand, strategic importance. Reference prior work if this is TP→GA or Dev Preview→TP progression.}

## Scenarios

N/A

## Acceptance Criteria

* {Feature} must enable automatically when multicluster observability is enabled on the hub.
* {Feature-specific acceptance criteria based on parent ticket context}
* All necessary {PHASE} code changes must be implemented along with updated/added unit tests.
* All CI test cases must pass.
* Changes must be validated by deploying a custom image in an ACM cluster before raising a PR.
* PR must obtain required approval from the MCO team before merge.
* After merge and ACM build availability, validate that the feature works as expected.
* Feature must be compatible with supported OpenShift versions.

## Dependencies (internal and external)

N/A

## Previous Work (Optional):

N/A

## Open questions:

N/A

## Done Checklist

* **CI** - CI is running, tests are automated and merged.
* **Release Enablement** <link to Feature Enablement Presentation>
* **DEV** - Upstream code and tests merged: <link to meaningful PR or GitHub Issue>
* **DEV** - Upstream documentation merged: <link to meaningful PR or GitHub Issue>
* **DEV** - Downstream build attached to advisory: <link to errata>
* **QE** - Test plans in Polarion: <link or reference to Polarion>
* **QE** - Automated tests merged: <link or reference to automated tests>
* **DOC** - Doc issue opened with a completed template. Separate doc issue opened for any deprecation, removal, or any current known issue/troubleshooting removal from the doc, if applicable.
* Considerations were made for Extended Update Support (EUS)
```

#### 2. Design Proposal
- **Project**: {EPIC_PROJECT}
- **Title**: 
  - If phase is `GA`: `[Placeholder] Design Proposal for {FEATURE}`
  - If phase is `TP` or `Dev Preview`: `Design Proposal for {FEATURE}`
- **Epic Name**: `Design Proposal for {FEATURE}`
- **Description**: `Design and architecture proposal for {FEATURE}. Covers solution approach, API changes, component interactions, and integration with MCO/MCOA. Includes review with stakeholders and sign-off.`
- **Fix Version**: Target quarter (e.g., `2026Q3`)
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: Tech Lead
- **Priority**: Major

#### 3. Development
- **Project**: {EPIC_PROJECT}
- **Title**: `[Dev] {FEATURE} - {PHASE} Implementation`
- **Epic Name**: `[Dev] {PHASE} changes for {FEATURE}`
- **Description**: `Core development work for {FEATURE} {PHASE} enablement in ACM {VERSION}. Includes code changes in multicluster-observability-operator and/or multicluster-observability-addon, unit tests, and PR reviews.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: L
- **Assignee Role**: Dev
- **Priority**: Major

#### 4. QE Automation Tests
- **Project**: {EPIC_PROJECT}
- **Title**: `[QE] Automation test development for {FEATURE}`
- **Epic Name**: `{FEATURE} Automation Tests`
- **Description**: `Develop and maintain automation tests for {FEATURE}. Includes test case definition, automation framework integration, fixing test failures, code refactoring, and adding new test coverage.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: L
- **Assignee Role**: QE
- **Priority**: Normal

#### 5. QE Release Testing
- **Project**: {EPIC_PROJECT}
- **Title**: `[QE] {VERSION} {PHASE} release testing for {FEATURE}`
- **Epic Name**: `[QE] {VERSION} {PHASE} release testing for {FEATURE}`
- **Description**: `End-to-end release testing of {FEATURE} on ACM {VERSION} {PHASE} builds. Verify feature works correctly in the release candidate before GA/TP ship date.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: QE
- **Priority**: Major

#### 6. Documentation
- **Project**: {EPIC_PROJECT}
- **Title**: `[Doc] {PHASE} documentation for {FEATURE}`
- **Epic Name**: `[Doc] {PHASE} Doc changes for {FEATURE}`
- **Description**: `Create or update product documentation for {FEATURE} in ACM {VERSION}. Includes rhacm-docs PRs, stage validation, and production doc release coordination.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: S
- **Assignee Role**: Tech Lead
- **Priority**: Normal

#### 7. Blog Post
- **Project**: {EPIC_PROJECT}
- **Title**: `[Blog] {PHASE} blog post for {FEATURE}`
- **Epic Name**: `[Blog] {PHASE} Blogpost for {FEATURE}`
- **Description**: `Write and publish a developer blog post for {FEATURE} {PHASE} release on developers.redhat.com. Includes draft preparation, Arcade demo coordination, editorial review, and publication.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: S
- **Assignee Role**: Dev
- **Priority**: Normal

#### 8. CEE / Support Enablement
- **Project**: {EPIC_PROJECT}
- **Title**: `[CEE] {FEATURE} {PHASE} Skill Transfer`
- **Epic Name**: `[CEE] {FEATURE} Tech Enablement`
- **Description**: `Technical enablement session for Customer Experience & Engagement (CEE/Support) team. Cover feature overview, troubleshooting guidance, known limitations, and common customer scenarios for {FEATURE}.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: S
- **Assignee Role**: Tech Lead
- **Priority**: Normal

#### 9. Enhancements
- **Project**: {EPIC_PROJECT}
- **Title**: `{FEATURE} Issues and Enhancements`
- **Epic Name**: `{FEATURE} Enhancements`
- **Description**: `Catch-all epic for follow-up improvements, bug fixes, and enhancement requests discovered during {FEATURE} {PHASE} development and testing cycle.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: Tech Lead
- **Priority**: Normal

### Tech Preview Extras (TP-only)

#### 10. QE Manual Testing
- **Project**: {EPIC_PROJECT}
- **Title**: `[QE] Manual verification of {FEATURE}`
- **Epic Name**: `[QE] Manual verification of {FEATURE}`
- **Description**: `Manual testing and verification of {FEATURE} functionality. Covers scenarios that cannot yet be automated and exploratory testing to identify edge cases before TP release.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: QE
- **Priority**: Normal

#### 11. Performance & Scale Testing
- **Project**: {EPIC_PROJECT}
- **Title**: `Performance & Scale testing for {FEATURE} {PHASE}`
- **Epic Name**: `Perf Scale for {FEATURE} {PHASE}`
- **Description**: `Performance and scalability validation for {FEATURE}. Test with representative cluster counts and workload sizes to identify resource limits and performance baselines.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: L
- **Assignee Role**: QE
- **Priority**: Major

### GA Extras (GA-only)

#### 12. Threat Modeling
- **Project**: {EPIC_PROJECT}
- **Title**: `Threat modeling for {FEATURE}`
- **Epic Name**: `Threat modeling for {FEATURE}`
- **Description**: `Security threat modeling exercise for {FEATURE} GA readiness. Identify attack surfaces, data flow risks, and mitigation strategies. Required for GA compliance.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: Tech Lead
- **Priority**: Major

#### 13. Multi-cluster Version Testing
- **Project**: {EPIC_PROJECT}
- **Title**: `[Dev] {PHASE} testing on multiple cluster versions`
- **Epic Name**: `[Dev] {PHASE} testing on multiple cluster versions`
- **Description**: `Validate {FEATURE} across multiple OCP cluster versions (N, N-1, N-2) and hub/spoke version combinations for ACM {VERSION} GA compatibility matrix.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: M
- **Assignee Role**: Dev
- **Priority**: Major

#### 14. z-stream Regression Testing
- **Project**: {EPIC_PROJECT}
- **Title**: `[QE] {VERSION} z-stream regression testing for {FEATURE}`
- **Epic Name**: `[QE] {VERSION} z-stream regression testing`
- **Description**: `Regression testing of {FEATURE} on ACM {VERSION} z-stream (patch) releases. Ensure no regressions are introduced in maintenance updates.`
- **Activity Type**: `Product / Portfolio Work`
- **Parent**: Link to `{parent_ticket}` (if provided)
- **Size**: S
- **Assignee Role**: QE
- **Priority**: Normal

## Output Format

Present the plan as a markdown table:

```
## Feature Epics Plan: {FEATURE} ({PHASE}, ACM {VERSION})
Parent: {parent_ticket} — {parent_title}
Label: obsint-analytics-{feature-slug}
Component (ACM): {component}
Activity Type: Product / Portfolio Work (all epics)
Fix Version (ACM): {acm_fix_version} | Fix Version ({EPIC_PROJECT}): {quarter}

| # | Project | Title | Fix Version | Size | Labels | Assignee Role | Priority |
|---|---------|-------|-------------|------|--------|---------------|----------|
| 1 | ACM     | ...   | ACM 5.0.0   | XL   | ...    | Tech Lead     | Major    |
| 2 | {EPIC_PROJECT} | ... | 2026Q3 | M    | —      | Tech Lead     | Major    |
...

Total: N epics (9 core + M phase-specific)
All epics linked to parent: {parent_ticket}
```

Then show the full ACM Epic description (from the ACM Epic Description Template) separately below the table.

Then ask (behavior depends on mode):

**If dry_run=true:**
> Plan complete (dry run). You can:
> 1. Adjust any titles or descriptions
> 2. Add or remove epics
> 3. Re-run with `dry_run=false` to create these epics in Jira

**If dry_run=false:**
> Ready to create? You can:
> 1. Adjust any titles or descriptions
> 2. Add or remove epics
> 3. Say **"create"** to create all epics in Jira now

## Jira Field Reference

These are the key fields used when creating epics (for future MCP creation):

| Field | Jira Field | Notes |
|-------|-----------|-------|
| Summary | `summary` | Epic title |
| Epic Name | `customfield_10011` | Board display name |
| Description | `description` | Brief for OBSINTA; structured template for ACM |
| Parent | `parent` | Parent feature ticket key (any board) — omit if none |
| Size | `customfield_10795` | `{"value": "XL"}` — allowed: XS, S, M, L, XL |
| Labels | `labels` | ACM: `["doc-required", "qe-required"]` (GA/TP) or `["qe-not-required", "doc-not-required"]` (Dev Preview). OBSINTA: `["obsint-analytics-<slug>"]` |
| Priority | `priority` | `{"name": "Major"}` or `{"name": "Normal"}` |
| Fix Version | `fixVersions` | Quarterly, e.g., `{"name": "2026Q2"}` |
| Issue Type | `issuetype` | `{"name": "Epic"}` |
| Project | `project` | ACM or OBSINTA |
| Activity Type | `customfield_10464` | `{"value": "Product / Portfolio Work", "id": "10610"}` |
| Component | `components` | ACM epic only: `[{"name": "Observability"}]` |

## Phase Reference

| Phase | ACM Title Prefix | ACM Labels | Design Epic Prefix |
|-------|-----------------|------------|-------------------|
| Dev Preview | `[Dev Preview]` | `qe-not-required`, `doc-not-required` | (none) |
| TP | `[TP]` | `doc-required`, `qe-required` | (none) |
| GA | `[GA]` | `doc-required`, `qe-required` | `[Placeholder]` |
