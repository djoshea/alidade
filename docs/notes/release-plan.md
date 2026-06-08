# Release plan, workflows, and secrets management

Captured during Phase 0 after the first lockstep `0.0.1` release shipped
through CI to all four registries. This is the canonical reference for
"how does a release work in this repo, and how was the trust set up to
make it happen."

If you want to ship a new version and don't want to read this whole
document, jump to the [release cheat sheet](#release-cheat-sheet) at
the bottom.

---

## Goal and shape

One canonical version number ships to four registries together:

| Registry  | Artifact(s)                                         | Install command                           |
|-----------|-----------------------------------------------------|-------------------------------------------|
| crates.io | `alidade-protocol`, `alidade-core`, `alidade`        | `cargo install alidade`                   |
| PyPI      | `alidade`                                           | `pip install alidade`                     |
| npm       | `alidade`, `@alidade-app/protocol`                   | `npm install alidade` / `@alidade-app/protocol` |

"Lockstep versioning" (see [PLAN.md §5](../PLAN.md#5-versioning-ci-and-release))
means all of these always carry the same `MAJOR.MINOR.PATCH`. Cargo's
`[workspace.package]` inheritance keeps the three crates in sync
automatically; everything else is held in line by either the bash script
or release-please (both described below).

Releases happen in two halves:

1. **Prepare**: rewrite the 11 version references across the workspace,
   refresh the three lockfiles, run the verification gate. End state:
   a clean commit that bumps everything to the new version.
2. **Publish**: push the `vX.Y.Z` tag. CI takes over: builds artifacts,
   exchanges GitHub OIDC tokens for registry-specific upload tokens,
   pushes to all four registries in parallel.

The publish half is the same regardless of how the prepare half was
done. The prepare half has two patterns; see
[two ways to prepare a release](#two-ways-to-prepare-a-release).

---

## The publish pipeline (`release.yml`)

Triggered by any tag matching `v*` pushed to the repo. Three parallel
jobs, each publishing to one registry, each gated on the tag NOT being
a pre-release (no `-` suffix in the tag name).

```
push tag v0.0.2
       │
       ▼
release.yml ─┬─ publish-crates  (sequential: protocol → core → alidade)
             ├─ publish-pypi
             └─ publish-npm     (sequential: alidade → @alidade-app/protocol)
```

Each job uses [OIDC trusted publishing](#oidc-trusted-publishing) — no
long-lived API tokens live in the repo's secrets. The GitHub
Environment for each job is its registry's name:

| Job              | Environment | Registry-side config target                |
|------------------|-------------|--------------------------------------------|
| `publish-crates` | `crates-io` | three trusted-publisher entries on crates.io |
| `publish-pypi`   | `pypi`      | one trusted-publisher entry on pypi.org    |
| `publish-npm`    | `npm`       | two trusted-publisher entries on npmjs.com |

Pre-release tags like `v0.0.1-rc.1` are deliberately ignored by every
job. TestPyPI has its own separate workflow (below); rc tags would
not give us anything additional and would clutter the tag history.

---

## Two ways to prepare a release

Both patterns produce the same end state: a commit on `main` with all
11 version refs bumped + refreshed lockfiles + a tag `vX.Y.Z` that
fires `release.yml`. Pick whichever fits the moment.

### Pattern A: `scripts/bump-version.sh`

A bash script you run locally. The script:

1. Validates the new version string is semver
2. Rewrites every version reference (Cargo.toml, crates' path-dep pins,
   pyproject.toml, `__version__`, the smoke test, four `package.json`
   files)
3. Refreshes Cargo.lock, pnpm-lock.yaml, python/uv.lock
4. Runs the CI-equivalent verification suite (cargo test/clippy/fmt,
   ruff/ty/pytest, pnpm typecheck/build)
5. Prints the exact commit/tag/push commands; does NOT execute them

```bash
scripts/bump-version.sh 0.0.2          # full run
scripts/bump-version.sh 0.0.2 --dry-run # preview only
```

Then `git diff`, `git commit`, `git tag -a v0.0.2 -m 'v0.0.2'`,
`git push origin main v0.0.2`.

Pros: predictable, fast, no third-party tools, you see exactly what's
about to ship. Cons: requires running a script + executing several git
commands manually; no automated changelog.

### Pattern B: release-please + reusable update-lockfiles

A bot watches `main` for conventional-commit messages. When relevant
changes have landed since the last release, it opens (and maintains)
a "release PR" that bumps versions across all files and updates a
generated `CHANGELOG.md` entry. Merging the PR auto-creates the `vX.Y.Z`
tag, which fires `release.yml`.

Conventional-commit semantics drive the bump:

| Commit type                | Effect                          |
|----------------------------|---------------------------------|
| `fix:`                     | patch (0.0.1 → 0.0.2)           |
| `feat:`                    | minor (0.0.1 → 0.1.0)           |
| `feat!:` / `BREAKING CHANGE:` | major                        |
| `chore:` / `docs:` / `refactor:` / `test:` / `ci:` | no bump, not in changelog |

Workflows involved:

```
push to main
     │
     ▼
release-please.yml ──┬── release-please job
                     │     (opens / updates release PR; outputs prs_created)
                     │
                     └── refresh-lockfiles job
                           (if prs_created == 'true', calls update-lockfiles.yml
                            via uses: ./.github/workflows/update-lockfiles.yml;
                            checks out the PR branch, refreshes lockfiles,
                            pushes the commit back)
```

`update-lockfiles.yml` is a **reusable workflow** (its trigger is
`workflow_call`), not directly fired by an event. It also has a
`workflow_dispatch` trigger so you can fire it manually from the Actions
UI to recover from lockfile drift on any branch.

Pros: review-then-merge UX (single click ships a release), changelog
auto-maintained, conventional commits become load-bearing in a useful
way. Cons: requires conventional-commit discipline; depends on a
third-party action and its quirks; setup is more involved.

#### When to use which

| Situation                                        | Recommended pattern |
|--------------------------------------------------|---------------------|
| Low cadence, single contributor, Phase 0/1       | A                   |
| Daily/weekly releases, multiple contributors     | B                   |
| Need to ship something out-of-band               | A (B can be slow if the PR-machinery is mid-flight) |
| Want a maintained CHANGELOG.md                   | B                   |
| Don't want to think about conventional commits   | A                   |

Both are kept available; they don't conflict.

---

## OIDC trusted publishing

Each publish job authenticates to its registry **not** with a stored
API token, but with a short-lived token minted at job-start time. The
mechanism:

1. GitHub Actions issues an OIDC token signed by GitHub's own JWKS,
   carrying claims like `repo: djoshea/alidade`, `ref: refs/tags/v0.0.2`,
   `workflow: release.yml`, `environment: pypi`, `actor: djoshea`.
2. The job sends this token to the registry's auth endpoint.
3. The registry verifies the token's signature against GitHub's keys
   and checks whether the claims (`repo`, `workflow`, `environment`,
   tag pattern, etc.) match a pre-registered "trusted publisher" entry.
4. If they match, the registry returns a short-lived upload token
   (typically valid for 15 min – 1 hour).
5. The job uses that short-lived token to upload the artifact.

The long-lived secret in this picture is the **trusted-publisher
configuration on the registry side** — not a token in the repo.
Compromising the repo's GitHub Actions secrets does NOT compromise
publishing, because there are no useful secrets to steal.

The downside: each registry needs the trust pre-registered before the
first publish (covered next).

### Registry-side configuration

These are the seven trusted-publisher entries currently configured.
Replicate them if the repo is ever transferred or rebuilt.

Shared identifiers everywhere:
- **Repository owner**: `djoshea`
- **Repository name**: `alidade`
- **Workflow file**: `release.yml` (or `testpypi.yml` for the TestPyPI smoke-test workflow)

| Registry | Project / scope          | UI                                                                | Environment |
|----------|--------------------------|-------------------------------------------------------------------|-------------|
| PyPI      | `alidade`                | pypi.org/manage/project/alidade/settings/publishing/              | `pypi`      |
| TestPyPI  | `alidade` (pending)      | test.pypi.org/manage/account/publishing/                          | `testpypi`  |
| npm       | `alidade`                | npmjs.com/package/alidade/access                                  | `npm`       |
| npm       | `@alidade-app/protocol`  | npmjs.com/package/@alidade-app/protocol/access                    | `npm`       |
| crates.io | `alidade-protocol`       | crates.io/crates/alidade-protocol/settings → Trusted Publishers   | `crates-io` |
| crates.io | `alidade-core`           | crates.io/crates/alidade-core/settings → Trusted Publishers       | `crates-io` |
| crates.io | `alidade`                | crates.io/crates/alidade/settings → Trusted Publishers            | `crates-io` |

TestPyPI uses a "**pending publisher**" because the `alidade` project
doesn't exist on TestPyPI yet — pending publishers configure trust for
a project that doesn't yet exist; the first publish creates the
project under that publisher's trust.

For npm, the "Allowed actions" picker should be set to **Allow npm
publish** only (leave "npm stage publish" unchecked unless we later
add a staged-publish flow).

### Action tooling per registry

The OIDC dance is opaque inside well-maintained actions:

| Registry  | Action                                       | Notes                                                           |
|-----------|----------------------------------------------|-----------------------------------------------------------------|
| crates.io | `rust-lang/crates-io-auth-action@v1`         | Exchanges the GitHub OIDC token for a short-lived crates.io token, exposes it as an output. We then `cargo publish` with that token in `CARGO_REGISTRY_TOKEN`. |
| PyPI / TestPyPI | `pypa/gh-action-pypi-publish@release/v1` | Handles OIDC exchange + upload in one shot. Need `permissions: id-token: write` at the job level. |
| npm       | `actions/setup-node@v6` + `npm publish --provenance` | npm CLI v10+ detects the GitHub Actions environment and uses OIDC automatically when trusted publishing is configured for the package; `--provenance` adds the signed attestation showing what source revision built the artifact. |

All three need `permissions: id-token: write` at the job level for
GitHub Actions to issue the OIDC token in the first place. The repo
has no further token configuration.

---

## TestPyPI: separate workflow, dev-version suffix

`testpypi.yml` is a `workflow_dispatch` workflow you fire from the
Actions UI when you want to validate that the python package builds
and uploads cleanly *without* consuming a real PyPI version slot.

Mechanics:

1. Workflow checks out the current `main` (or whatever branch you
   dispatch against).
2. It mutates `python/pyproject.toml`'s version field in place to
   `<base>.dev<run-number>` (e.g. `0.0.2.dev42`). This is PEP 440's
   dev-release syntax; PyPI / TestPyPI accepts it.
3. `uv build` produces wheel + sdist.
4. `twine check dist/*` runs the same metadata validation PyPI applies
   at upload time.
5. `pypa/gh-action-pypi-publish@release/v1` with `repository-url`
   pointing at TestPyPI uploads via the pending trusted publisher.

Why per-run dev versions: every TestPyPI publish gets a unique version
slot, so even if an upload fails mid-way, the next run picks a fresh
number and no version is ever "burned" in a way that would force a
real-version bump.

Why TestPyPI is NOT in the tag-driven release: it's not on the critical
path. The CI gate (next section) catches the same class of bugs faster.

---

## CI metadata-validation gate

`python.yml` runs `uv build && twine check dist/*` on every PR. This
runs PyPI's own metadata validator against the built artifacts before
they would ever touch a registry. The class of bug it catches:

- Bad license-files paths (the issue that produced our wheel-only
  `0.0.0` on PyPI)
- Missing or malformed classifiers
- Version-string regressions
- README rendering errors
- Wheel filename collisions

This is the cheapest way to fail-loud-early. TestPyPI exists as a
backstop when something *non-metadata* needs validation (e.g., does
`pip install` actually work end-to-end against the wheel) — but most
issues land in this gate first.

---

## Secrets and tokens: what's where

| Where                                      | What                                              |
|--------------------------------------------|---------------------------------------------------|
| Repo secrets (Settings → Secrets)         | **None for publishing.** GitHub's OIDC handles auth. The only repo secret in use is the default `GITHUB_TOKEN` (auto-managed). |
| Repo settings → Actions → General         | "Allow GitHub Actions to create and approve pull requests" (enabled, for release-please). "Workflow permissions" defaults are fine; we elevate per-job. |
| GitHub Environments (Settings → Environments) | `pypi`, `testpypi`, `crates-io`, `npm`. Created on first workflow reference. Can be given protection rules (required reviewers, deployment-branch policies) post hoc; currently none. |
| Per-registry trusted publisher entries     | See [registry-side configuration](#registry-side-configuration) above. These are the load-bearing trust artifacts. |
| Local developer machines                  | crates.io / npm login state (only needed if a developer publishes manually — not for the CI-driven path). |

If trusted publishing ever fails to set up on a registry (we hit
something the registry doesn't support), the fallback is a scoped API
token stored as a GitHub repo secret. Currently no registry needs this.

---

## Release cheat sheet

### Pattern A: bash script

```bash
scripts/bump-version.sh 0.0.2 --dry-run    # preview
scripts/bump-version.sh 0.0.2              # do it
git diff                                   # review
git add -A
git commit -m 'chore: bump lockstep version to 0.0.2'
git tag -a v0.0.2 -m 'v0.0.2'
git push origin main v0.0.2
# ↑ tag push fires release.yml → publishes to all four registries
```

### Pattern B: release-please

```
1. Write code, push commits to main using conventional-commit prefixes.
2. release-please.yml opens / updates a release PR automatically.
3. update-lockfiles (reusable workflow) refreshes lockfiles on the PR
   branch within the same workflow run.
4. Review the PR diff + changelog entry.
5. Click "Merge pull request" on GitHub.
   → release-please creates the v0.0.2 tag automatically
   → tag push fires release.yml → publishes everywhere
```

### Smoke-test against TestPyPI (optional, both patterns)

Actions tab → `testpypi` workflow → "Run workflow" → main. Uploads a
`<current>.devN` version that doesn't consume any real version slot.

### Verify a release after publish

```bash
# crates.io
for c in alidade alidade-core alidade-protocol; do
  curl -s "https://crates.io/api/v1/crates/$c" -H "User-Agent: alidade-release-check" \
    | python3 -c "import json,sys; print('$c:', json.load(sys.stdin)['crate']['newest_version'])"
done

# PyPI
curl -s https://pypi.org/pypi/alidade/json | python3 -c "import json,sys; print('alidade:', json.load(sys.stdin)['info']['version'])"

# npm
for p in alidade @alidade-app/protocol; do
  echo "$p: $(npm view "$p" version)"
done
```

---

## Common pitfalls and recoveries

### Wrong version published

PyPI and crates.io versions are **permanent**. You can yank a version
on crates.io (hidden from default resolution; still on disk) and
delete-within-72h on PyPI / npm, but you can never re-use the same
version number. Always bump forward: if `0.0.2` shipped wrong, fix and
ship `0.0.3`; don't try to re-publish `0.0.2`.

### Partial-upload version burn

What happened with our `0.0.0` PyPI publish: the wheel uploaded
successfully but the sdist failed metadata validation, leaving PyPI
permanently at "0.0.0 (wheel only)". Same risk on any registry.
Mitigations:

1. Always run the CI metadata gate (`python.yml`'s `twine check`) on
   the artifact-bearing commit before tagging.
2. For multi-artifact registries, prefer to upload all artifacts in a
   single API call when possible (PyPI's `twine upload dist/*` does
   this; some bespoke scripts do not).

### Lockfile drift from manual edits

If someone hand-edits a `Cargo.toml` dependency line and forgets to
run `cargo build`, `Cargo.lock` falls out of sync. Recovery: fire the
`update-lockfiles` workflow manually from the Actions UI on the
affected branch, or run the equivalent commands locally:

```bash
cargo update --workspace
pnpm install --lockfile-only
(cd python && uv lock)
```

### Tag pushed but `release.yml` failed mid-way

The publish jobs are independent. If, say, the crates.io publish
succeeded but the npm publish failed, you have:
- crates.io at the new version ✓
- PyPI at the new version (probably) ✓
- npm at the previous version ✗

Recovery: fix the npm-job problem, then re-run just that failed job
from the Actions UI ("Re-run failed jobs"). The OIDC-based publishes
are idempotent — re-running won't try to re-upload to a registry where
the version already exists.

### Conventional-commit mistakes break release-please

If you push a `feat:` when the change was actually a `fix:` and don't
notice, release-please opens a release PR for a minor bump instead of
a patch. The PR is open and reviewable — you can close it without
merging, push a follow-up amending the commit message, and release-
please will re-open with the corrected proposal.

If the bad commit message already shipped a release, you're stuck —
the version is what it is. The downstream pain is small unless the
mistake was BREAKING-CHANGE-vs-feat.

---

## Notes from Phase 0

Things that came up the first time we did this end-to-end, recorded
here so they're not lessons that have to be re-learned:

- **The `alidade` npm org name was already taken** by an unrelated
  party. We use `@alidade-app/*` for the scope on npm. Bare `alidade`
  is still ours on the unscoped namespace.
- **`license-files = ["../LICENSE.md"]` is rejected by PyPI** with
  "parent directory indicators are not allowed". Each Python package
  needs a local LICENSE copy. This took out our `0.0.0` PyPI sdist.
- **`astral-sh/setup-uv` doesn't ship a floating major-version tag**
  for `v8` (only specific `v8.x.y`). Pin to the specific version;
  bump on Dependabot's schedule.
- **GitHub's cascade-prevention rule** blocks workflows from being
  triggered by other workflows that authenticated via the default
  `GITHUB_TOKEN`. The lesson: reusable workflows (`workflow_call`)
  bypass this elegantly; PAT-based workarounds are correct but heavier.
- **Repo setting "Allow GitHub Actions to create and approve pull
  requests"** must be enabled before release-please can open PRs. Easy
  to miss; failure is one-line in the workflow logs.
- **TestPyPI works** but is famously flaky. Trust the CI metadata gate
  more than TestPyPI's uptime.
