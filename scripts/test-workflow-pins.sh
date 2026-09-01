#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-workflow-pins.rb"
FIXTURES="$ROOT/scripts/test-fixtures/workflow-pins"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/workflow-pins.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT INT TERM

fail() {
  echo "test-workflow-pins: FAILED -- $1" >&2
  exit 1
}

expect_pass() {
  name="$1"
  fixture="$2"
  output="$(ruby "$GUARD" "$fixture" 2>&1)" \
    || fail "$name should pass; output: $output"
  printf '%s\n' "$output" | grep -F "check-workflow-pins: OK" >/dev/null \
    || fail "$name did not emit the success marker"
  echo "test-workflow-pins: PASS -- $name"
}

expect_fail() {
  name="$1"
  fixture="$2"
  marker="$3"
  if output="$(ruby "$GUARD" "$fixture" 2>&1)"; then
    fail "$name should fail closed"
  fi
  printf '%s\n' "$output" | grep -F "$marker" >/dev/null \
    || fail "$name did not emit expected marker '$marker'; output: $output"
  echo "test-workflow-pins: PASS -- $name rejected"
}

expect_default_fail() {
  name="$1"
  fixture_root="$2"
  marker="$3"
  if output="$(cd "$fixture_root" && ruby "$GUARD" 2>&1)"; then
    fail "$name should fail closed"
  fi
  printf '%s\n' "$output" | grep -F "$marker" >/dev/null \
    || fail "$name did not emit expected marker '$marker'; output: $output"
  echo "test-workflow-pins: PASS -- $name rejected"
}

expect_default_pass() {
  name="$1"
  fixture_root="$2"
  marker="$3"
  output="$(cd "$fixture_root" && ruby "$GUARD" 2>&1)" \
    || fail "$name should pass; output: $output"
  printf '%s\n' "$output" | grep -F "$marker" >/dev/null \
    || fail "$name did not emit expected marker '$marker'; output: $output"
  echo "test-workflow-pins: PASS -- $name"
}

expect_pass "literal SHA, digest, and local references" "$FIXTURES/valid.yml"
expect_fail "floating external tag" "$FIXTURES/floating-action.yml" "full 40-hex commit SHA"
expect_fail "flow-map floating external tag" "$FIXTURES/flow-map-floating-action.yml" "full 40-hex commit SHA"
expect_fail "floating Docker tag" "$FIXTURES/floating-docker.yml" "digest-pinned"
expect_fail "dynamic Docker image" "$FIXTURES/dynamic-docker.yml" "digest-pinned"
expect_fail "dynamic external reference" "$FIXTURES/dynamic-action.yml" "full 40-hex commit SHA"
expect_fail "aliased reference value" "$FIXTURES/aliased-action.yml" "workflow YAML aliases are not allowed"
expect_fail "aliased uses mapping key" "$FIXTURES/aliased-key.yml" "workflow YAML aliases are not allowed"
expect_fail "unpinned reference in a second YAML document" "$FIXTURES/multi-document.yml" "exactly one document"
expect_fail "fully pinned multi-document workflow" "$FIXTURES/multi-document-pinned.yml" "exactly one document"
expect_fail "malformed workflow YAML" "$FIXTURES/malformed.yml" "workflow YAML does not parse"

mkdir -p "$TEMP_ROOT/directory.yml"
ln -s "$FIXTURES/valid.yml" "$TEMP_ROOT/regular-link.yml"
ln -s "$TEMP_ROOT/missing.yml" "$TEMP_ROOT/dangling-link.yml"
expect_fail "directory workflow path" "$TEMP_ROOT/directory.yml" "must be a regular file; got directory"
expect_fail "workflow symlink to a regular file" "$TEMP_ROOT/regular-link.yml" "must be a regular file; got symbolic link"
expect_fail "dangling workflow symlink" "$TEMP_ROOT/dangling-link.yml" "must be a regular file; got symbolic link"

GIT_VALID="$TEMP_ROOT/git-valid"
mkdir -p "$GIT_VALID/.github/workflows" "$GIT_VALID/target-repo-files/.github/workflows"
cp "$FIXTURES/valid.yml" "$GIT_VALID/.github/workflows/valid.yml"
cp "$FIXTURES/valid.yml" "$GIT_VALID/target-repo-files/.github/workflows/template.yml"
git -C "$GIT_VALID" init -q
git -C "$GIT_VALID" add .github/workflows/valid.yml target-repo-files/.github/workflows/template.yml
expect_default_pass "Git enumeration includes regular target templates" "$GIT_VALID" "2 workflow file(s), 10 pinned uses reference(s)"

GIT_FIXTURE="$TEMP_ROOT/git-scan"
mkdir -p "$GIT_FIXTURE/.github/workflows" "$GIT_FIXTURE/target-repo-files/.github/workflows"
cp "$FIXTURES/valid.yml" "$GIT_FIXTURE/.github/workflows/valid.yml"
ln -s "$GIT_FIXTURE/missing.yml" "$GIT_FIXTURE/target-repo-files/.github/workflows/dangling.yml"
git -C "$GIT_FIXTURE" init -q
git -C "$GIT_FIXTURE" add .github/workflows/valid.yml target-repo-files/.github/workflows/dangling.yml
expect_default_fail "Git enumeration includes target-template symlinks" "$GIT_FIXTURE" "target-repo-files/.github/workflows/dangling.yml"

FILESYSTEM_FIXTURE="$TEMP_ROOT/filesystem-scan"
mkdir -p "$FILESYSTEM_FIXTURE/.github/workflows"
ln -s "$FILESYSTEM_FIXTURE/missing.yml" "$FILESYSTEM_FIXTURE/.github/workflows/dangling.yml"
expect_default_fail "filesystem fallback includes dangling workflow symlinks" "$FILESYSTEM_FIXTURE" "must be a regular file; got symbolic link"

echo "test-workflow-pins: all fixtures passed"
