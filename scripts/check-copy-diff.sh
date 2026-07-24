#!/bin/sh
# =============================================================================
# check-copy-diff.sh -- Stitch copy-lane path & size guard (FAIL-CLOSED)
# -----------------------------------------------------------------------------
# The SINGLE source of truth for "what a copy-lane agent PR is allowed to touch."
# It is run in THREE places (see ../README.md):
#   1. copy-agent.yml Phase A (host-side, before any PR exists).
#   2. copy-agent.yml Phase B (post-apply, defense in depth).
#   3. agent-guard.yml in every enrolled TARGET repo, which FETCHES this exact
#      file pinned by full commit SHA from Stitch-TEC/agent-runner and runs it
#      against the PR diff. The target repo NEVER executes a copy of this script
#      taken from the PR head (the self-neutering fix).
#
# POLICY
#   ALLOW (prose only): paths ending in .md, .mdx, or .txt -- anywhere, which
#          covers *.md/*.mdx/*.txt as well as content/** and src/content/**.
#   DENY  (WINS over allow): .github/** ; code/config/lockfiles
#          (.js .jsx .ts .tsx .mjs .cjs .json .lock, package*.json) ; anything
#          containing "auth" ; .env* ; Dockerfile ; wrangler.* ; *.yml/*.yaml ;
#          and executable/markup content (*.html .htm .svg .xml .xhtml).
#   SIZE: at most 5 changed files AND at most 600 ADDED lines AND at most 40 DELETED lines
#         (v2 2026-07-23 — additions/deletions split so a human-approved publish (a new prose
#         file) fits while the defacement direction stays tightly capped; see MAX_* below).
#
# Any changed path outside the allowlist OR inside the denylist -> exit 1 naming
# the offending path. Oversize -> exit 1. Unverifiable size -> exit 1. A clean
# prose-only diff -> exit 0. There is NO code path that "passes on error": every
# failure branch exits non-zero. The denylist deliberately over-matches (e.g.
# "author.md" trips the "auth" rule) because fail-closed beats fail-open here.
#
# INPUT (auto-detected on stdin; falls back to the working-tree diff):
#   * `git diff --numstat [RANGE]`   -> richest: paths + per-file line counts.
#                                        Use this to guard an arbitrary RANGE
#                                        (e.g. base...head in CI).
#   * `git diff --name-only [RANGE]` -> paths only; line counts are then derived
#                                        from `git diff --numstat` on the current
#                                        working tree (correct only when the diff
#                                        you care about IS the working tree).
#   * (no stdin)                     -> the script runs `git diff --numstat`
#                                        itself against the working tree.
# When relying on the working-tree fallback for line counts, run the script with
# the target repo as the current directory. Callers should pass --no-renames so
# a rename shows as delete+add and each side is path-checked independently.
# =============================================================================

set -eu

# SIZE POLICY v2 (2026-07-23, publish lane): additions and deletions are capped SEPARATELY.
#   * MAX_DELETED=40 -- deletions are the defacement direction (wiping live copy); the original
#     copy-tweak envelope keeps its tight bound.
#   * MAX_ADDED=600  -- additions are the publish direction (a full human-approved blog post as a
#     new prose file). Still small enough that a reviewer reads every line before merging; the
#     required `guard` check + >=1 approval on enrolled repos is what makes the cap meaningful.
#   * MAX_FILES=5    -- unchanged.
# v1 capped TOTAL changed lines at 40, which structurally blocked publishing any real post.
MAX_FILES=5
MAX_ADDED=600
MAX_DELETED=40
# PUBLISH MODE (STITCH_GUARD_MODE=publish — set ONLY by trusted workflow code: the runner keys it
# off the repository_dispatch event type, the target repo's agent-guard off the runner-minted
# stitch/agent/publish-* branch prefix; a PR author can set neither): a re-publish OVERWRITES the
# existing post verbatim, so the diff legitimately deletes every changed old line — the deletion
# cap matches the addition cap there. Copy mode keeps the tight 40-line deletion bound.
if [ "${STITCH_GUARD_MODE:-copy}" = "publish" ]; then
  MAX_DELETED=$MAX_ADDED
fi
TAB="$(printf '\t')"

fail() {
  # $1 = human-readable reason. Always exits non-zero (fail-closed).
  echo "check-copy-diff: BLOCKED -- $1" >&2
  exit 1
}

# ---- 1. gather raw input ----------------------------------------------------
STDIN_DATA=""
if [ ! -t 0 ]; then
  # `|| true` so an empty pipe under `set -e` does not abort here.
  STDIN_DATA="$(cat 2>/dev/null || true)"
fi

WORK="$(mktemp)"
PATHS="$(mktemp)"
trap 'rm -f "$WORK" "$PATHS"' EXIT INT TERM

if [ -n "$STDIN_DATA" ]; then
  printf '%s\n' "$STDIN_DATA" > "$WORK"
else
  # No stdin -> derive from the working tree. Fail closed if git is unavailable.
  git diff --numstat --no-renames > "$WORK" 2>/dev/null \
    || fail "no stdin and 'git diff --numstat' failed (run inside the target repo)"
fi

# ---- 2. detect input form (numstat vs name-only) ----------------------------
# A numstat line is "<added>\t<deleted>\t<path>" where added/deleted are digits
# or '-' (binary). If ANY non-blank line is not numstat-shaped, treat the whole
# input as name-only.
HAVE_COUNTS=1
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *"$TAB"*"$TAB"*)
      a="${line%%"$TAB"*}"
      case "$a" in
        ''|*[!0-9-]*) HAVE_COUNTS=0 ;;   # first field is not a pure count
        *) : ;;
      esac
      ;;
    *)
      HAVE_COUNTS=0
      ;;
  esac
done < "$WORK"

# ---- 3. normalise to a path list + added/deleted line counts ----------------
ADDED_LINES=0
DELETED_LINES=0
: > "$PATHS"

if [ "$HAVE_COUNTS" -eq 1 ]; then
  # numstat form: authoritative counts come straight from the input.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    a="${line%%"$TAB"*}"
    rest="${line#*"$TAB"}"
    d="${rest%%"$TAB"*}"
    p="${rest#*"$TAB"}"
    [ "$a" = "-" ] && a=0        # binary file: count as 0 lines (path still checked)
    [ "$d" = "-" ] && d=0
    ADDED_LINES=$((ADDED_LINES + a))
    DELETED_LINES=$((DELETED_LINES + d))
    printf '%s\n' "$p" >> "$PATHS"
  done < "$WORK"
else
  # name-only form: the lines are the paths; derive counts from the working tree.
  grep -v '^[[:space:]]*$' "$WORK" > "$PATHS" || true
  if COUNTS="$(git diff --numstat --no-renames 2>/dev/null)"; then
    ADDED_LINES=0
    DELETED_LINES=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      a="${line%%"$TAB"*}"
      rest="${line#*"$TAB"}"
      d="${rest%%"$TAB"*}"
      [ "$a" = "-" ] && a=0
      [ "$d" = "-" ] && d=0
      case "$a$d" in *[!0-9]*) continue ;; esac
      ADDED_LINES=$((ADDED_LINES + a))
      DELETED_LINES=$((DELETED_LINES + d))
    done <<EOF
$COUNTS
EOF
  else
    fail "could not verify diff size (name-only input and no working-tree git context)"
  fi
fi

# ---- 4. enforce path allow/deny + size caps (fail-closed) -------------------
FILE_COUNT=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  FILE_COUNT=$((FILE_COUNT + 1))

  # Reject unparseable / renamed / quoted paths outright (fail-closed).
  case "$p" in
    *' => '*) fail "renamed path (not allowed in copy lane): $p" ;;
    *'{'*|*'}'*) fail "rename-braced path (not allowed in copy lane): $p" ;;
    '"'*) fail "quoted/special-char path (not allowed in copy lane): $p" ;;
  esac

  # DENYLIST FIRST -- it WINS over the allowlist.
  case "$p" in
    .github/*|*/.github/*)            fail "workflow/CI path: $p" ;;
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) fail "code file: $p" ;;
    *.json|*.lock)                    fail "config/lockfile: $p" ;;
    package*.json|*/package*.json)    fail "package manifest: $p" ;;
    *auth*)                           fail "auth-related path: $p" ;;
    .env|.env.*|*/.env|*/.env.*)      fail "environment file: $p" ;;
    Dockerfile|*/Dockerfile)          fail "Dockerfile: $p" ;;
    wrangler.*|*/wrangler.*)          fail "wrangler config: $p" ;;
    *.yml|*.yaml)                     fail "YAML file: $p" ;;
    *.html|*.htm|*.svg|*.xml|*.xhtml) fail "markup/executable-content file: $p" ;;
  esac

  # ALLOWLIST -- prose only. Anything not matched here is denied.
  case "$p" in
    *.md|*.mdx|*.txt) : ;;                        # allowed
    *) fail "not a prose file (only .md/.mdx/.txt allowed): $p" ;;
  esac
done < "$PATHS"

# ---- 5. size caps -----------------------------------------------------------
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "check-copy-diff: no changes to check -- OK" >&2
  exit 0
fi
if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
  fail "too many files changed ($FILE_COUNT > $MAX_FILES)"
fi
if [ "$ADDED_LINES" -gt "$MAX_ADDED" ]; then
  fail "too many added lines ($ADDED_LINES > $MAX_ADDED)"
fi
if [ "$DELETED_LINES" -gt "$MAX_DELETED" ]; then
  fail "too many deleted lines ($DELETED_LINES > $MAX_DELETED)"
fi

echo "check-copy-diff: OK -- $FILE_COUNT file(s), +$ADDED_LINES/-$DELETED_LINES line(s), prose-only." >&2
exit 0
