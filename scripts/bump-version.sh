#!/usr/bin/env bash
# Bump the lockstep version across the alidade monorepo.
#
# Usage:
#   scripts/bump-version.sh 0.1.0          # rewrite versions, refresh lockfiles, verify
#   scripts/bump-version.sh 0.1.0 --dry    # show what would change without writing
#
# Files updated:
#   Cargo.toml ([workspace.package].version)
#   crates/alidade/Cargo.toml, crates/alidade-core/Cargo.toml   (path-dep version pins)
#   python/pyproject.toml
#   python/src/alidade/__init__.py
#   python/tests/test_smoke.py
#   package.json (workspace root)
#   app/package.json
#   packages/protocol/package.json
#   npm/alidade/package.json
#
# Lockfile refresh runs cargo build, pnpm install, and uv sync.
# Verification runs cargo test, cargo clippy, pytest, pnpm typecheck, and
# the workspace package builds — the same surface CI guards on every PR.
#
# The script does not commit, tag, or push. It leaves you with a clean
# working tree of edits to review; the final summary prints the exact
# commit + tag + push commands.

set -euo pipefail

# ── colors / output helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi
section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_RESET"; }
ok()      { printf '  %s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
warn()    { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
die()     { printf '  %s✗%s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; exit 1; }

# ── parse args ────────────────────────────────────────────────────────────────
DRY=0
NEW=""
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    -*) die "unknown flag: $arg" ;;
    *) [[ -z "$NEW" ]] && NEW="$arg" || die "extra positional arg: $arg" ;;
  esac
done
[[ -n "$NEW" ]] || die "usage: $0 NEW_VERSION [--dry-run]"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?(\+[A-Za-z0-9.-]+)?$ ]] \
  || die "$NEW is not valid semver (expected MAJOR.MINOR.PATCH[-PRE][+BUILD])"

# ── locate repo root ──────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repo"
cd "$REPO_ROOT"

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight"
if (( ! DRY )); then
  [[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash first"
  ok "working tree clean"
fi

CURRENT=$(awk -F\" '/^version = "/ {print $2; exit}' Cargo.toml)
[[ -n "$CURRENT" ]] || die "could not parse current version from Cargo.toml"
ok "current: ${CURRENT}    →    new: ${NEW}"
[[ "$CURRENT" != "$NEW" ]] || die "new version equals current; nothing to do"

# Soft check: warn (don't fail) if going backwards numerically. semver-cmp
# is fiddly to do portably in bash, so this is a string sort and only
# meaningful for monotonic semvers without pre-release suffixes.
if [[ ! "$CURRENT" =~ - && ! "$NEW" =~ - ]] && [[ "$(printf '%s\n%s' "$CURRENT" "$NEW" | sort -V | tail -1)" != "$NEW" ]]; then
  warn "new version $NEW is older than current $CURRENT — proceeding anyway"
fi

# ── rewrite version references ────────────────────────────────────────────────
section "Updating version references"
FILES=(
  Cargo.toml
  crates/alidade/Cargo.toml
  crates/alidade-core/Cargo.toml
  package.json
  app/package.json
  python/pyproject.toml
  python/src/alidade/__init__.py
  python/tests/test_smoke.py
  npm/alidade/package.json
  packages/protocol/package.json
)
MISSING=()
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    warn "$f  (file does not exist; skipping)"
    continue
  fi
  if ! grep -q "\"${CURRENT}\"" "$f"; then
    warn "$f  (no '\"${CURRENT}\"' substring; skipping — verify by hand if surprising)"
    MISSING+=("$f")
    continue
  fi
  if (( DRY )); then
    matches=$(grep -c "\"${CURRENT}\"" "$f")
    ok "$f  (${matches} occurrence(s) would update)"
  else
    # `-i.bak` is the BSD/GNU-portable in-place form; remove the backup
    # after a successful write.
    sed -i.bak "s|\"${CURRENT}\"|\"${NEW}\"|g" "$f" && rm "${f}.bak"
    ok "$f"
  fi
done

if (( DRY )); then
  section "Dry run complete"
  echo "  No files written. Re-run without --dry-run to apply."
  exit 0
fi

# ── refresh lockfiles ─────────────────────────────────────────────────────────
section "Refreshing lockfiles"
cargo build --quiet                                 && ok "Cargo.lock"
pnpm install --silent --frozen-lockfile=false       && ok "pnpm-lock.yaml"
(cd python && uv sync --quiet)                      && ok "python/uv.lock"

# ── verify ────────────────────────────────────────────────────────────────────
section "Verifying (CI-equivalent)"
cargo test --quiet                                                           >/dev/null 2>&1 && ok "cargo test"
cargo clippy --all-targets --all-features --quiet -- -D warnings             >/dev/null 2>&1 && ok "cargo clippy"
cargo fmt --all -- --check                                                                   && ok "cargo fmt --check"
(cd python && uv run --quiet ruff check)                                     >/dev/null      && ok "ruff check"
(cd python && uv run --quiet ruff format --check)                            >/dev/null      && ok "ruff format --check"
(cd python && uv run --quiet ty check)                                       >/dev/null      && ok "ty check"
(cd python && uv run --quiet pytest -q)                                      >/dev/null      && ok "pytest"
pnpm --filter @alidade-app/protocol run build                                >/dev/null 2>&1 && ok "build @alidade-app/protocol"
pnpm -r run typecheck                                                        >/dev/null 2>&1 && ok "pnpm typecheck"
pnpm --filter @alidade-app/app run build                                     >/dev/null 2>&1 && ok "build @alidade-app/app"

# ── next steps ────────────────────────────────────────────────────────────────
section "Next steps"
cat <<NEXT
  Review the diff:
      git diff

  Commit:
      git add -A
      git commit -m 'chore: bump lockstep version to ${NEW}'

  Tag and push (this fires release.yml):
      git tag -a v${NEW} -m 'v${NEW}'
      git push origin main v${NEW}

NEXT
