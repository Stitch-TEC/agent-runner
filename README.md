# agent-runner

The **Stitch-owned, sandboxed execution half** of the tickets → agent-PR
**copy lane**. This repo (published as the private `Stitch-TEC/agent-runner`)
holds the GitHub Actions workflow that a copy-lane run actually executes, plus
the one path-guard script that defines what such a run is allowed to touch.

The other half — the **dispatcher** — lives in `feedback-worker`
(`POST /agent/dispatch` + the OIDC/nonce callback routes `/agent/read-token`,
`/agent/brief`, `/agent/git-token`, `/agent/complete`). See
`STAGE-2-AGENT-DESIGN.md` for the whole design; the runner half is deliberately
minimal and holds **no crown-jewel secret**.

> Posture: this repo is inert until the operator (a) pins the SHAs/image and
> (b) provisions the GitHub App + branch protection. Nothing here can act on a
> client repo on its own — every capability is a short-lived token minted by the
> dispatcher after it re-checks everything server-side.

## What is in here

| Path | Role |
|---|---|
| `.github/workflows/copy-agent.yml` | The runner. Fires on `repository_dispatch: stitch-agent-copy`. Phase A generates a prose diff inside a **Docker filesystem jail**; Phase B opens the PR with a write token minted only then. |
| `scripts/check-copy-diff.sh` | The **fail-closed prose-only path + size guard**. Single source of truth, run in three places (Phase A, Phase B, and every target repo's `agent-guard`). |
| `scripts/check-workflow-pins.rb` | CI regression guard that parses every checked-in workflow and requires immutable external action SHAs / Docker digests while allowing local `./` actions and reusable workflows. Independent of the copy-policy `GUARD_SHA` drift check. |
| `target-repo-files/.github/workflows/agent-guard.yml` | Copy this into **each enrolled client repo**. A required PR check that **fetches** `check-copy-diff.sh` pinned by commit SHA and runs it against the PR diff — it never executes a script taken from the PR head. |
| `README.md` | This file. |

## One repo per install

The "Stitch Agent" GitHub App is installed **one repository per installation** —
on each enrolled target repo *and* on `Stitch-TEC/agent-runner` itself. That
one-repo scope is the **primary** guarantee that a run can only ever touch the
single repo it was dispatched for; the dispatcher's response-scope validation is
a backstop. Never widen an installation to "all repositories".

## How a run flows

1. Operator clicks **Dispatch** in POM → dispatcher `POST /agent/dispatch`
   re-resolves client/attribution/repo/branch-protection, reserves budget, mints
   purpose-bound nonces + a 20-min `$2` gateway token, and fires
   `repository_dispatch` at this repo with
   `{ ticketId, repo, runId, nonces:{readToken,brief,gitToken,complete}, runBudgetUsd, gatewayToken }`.
2. **Phase A (`agent`)** — requests an OIDC token (audience `AGENT_OIDC_AUDIENCE`),
   calls `/agent/read-token` for a `contents:read` token, checks out the client
   repo read-only, calls `/agent/brief` for the **operator-authored** instruction
   + context (never ticket text), runs Claude Code in the FS jail, then runs the
   host-side path-guard and uploads the patch.
3. **Phase B (`open_pr`)** — downloads the patch, calls `/agent/git-token` for a
   `contents+PR:write` token, applies the patch on a `stitch/agent/ticket-<id>`
   branch, **re-runs the guard**, commits with a trusted workflow-authored
   message, pushes, opens the PR (labels `agent-copy` + `unreviewed`, the
   "UNREVIEWED — assume hostile…" banner), and calls `/agent/complete`.
4. The target repo's `agent-guard` runs on the PR as a **required** check.
5. A human reviews and merges. **The agent never merges** — the App has
   Contents+PR only, no Administration/merge capability.

## How the two headline security fixes are realized

**Filesystem jail (S2-fatal-1).** Phase A runs Claude Code as
`docker run --rm --user 1000 --cap-drop ALL --security-opt no-new-privileges
-v "$RUNNER_TEMP/target:/work" -w /work …`. The checkout is **moved** out of the
workspace into `$RUNNER_TEMP/target` and **only that directory** is mounted, so
`$GITHUB_EVENT_PATH` (which lives under `$RUNNER_TEMP/_github_workflow/` and
carries the nonces + gatewayToken), the other minted tokens, and the guard
script (in `$GITHUB_WORKSPACE`) are neither mounted nor in the container env. The
tool allowlist is `Read Write Edit Glob Grep` only — **no Bash/WebFetch/git/gh**.
A prompt-injected agent therefore cannot lift the payload secrets or overwrite
the guard, and the guard runs **on the host**, outside the container.

**Pinned-guard fetch, self-neutering fix (S2-mustfix).**
`target-repo-files/agent-guard.yml` does **not** vendor + execute the guard from
the PR head (a PR can write non-workflow `.github/` paths). It `curl`s
`check-copy-diff.sh` from
`raw.githubusercontent.com/Stitch-TEC/agent-runner/<COMMIT_SHA>/scripts/check-copy-diff.sh`
into `$RUNNER_TEMP` (outside the PR tree) and runs **that**. A commit SHA names an
immutable blob, so the pin is the integrity guarantee.

## Operator setup — before enabling

### 1. Pin every third-party action by full commit SHA

Replace each placeholder with the real 40-char SHA of the pinned tag (verify
against the action's releases; do not trust the tag alone):

| Placeholder | Action (current tag in the comment) | Files |
|---|---|---|
| `<REPLACE_WITH_CHECKOUT_SHA>` | `actions/checkout` (v4.2.2) | `copy-agent.yml` ×4, `agent-guard.yml` ×1 |
| `<REPLACE_WITH_UPLOAD_ARTIFACT_SHA>` | `actions/upload-artifact` (v4.4.3) | `copy-agent.yml` |
| `<REPLACE_WITH_DOWNLOAD_ARTIFACT_SHA>` | `actions/download-artifact` (v4.1.8) | `copy-agent.yml` |

### 2. Publish + pin the Claude Code CLI image

Set `env.CLAUDE_CODE_IMAGE` in `copy-agent.yml` to a **published** Claude Code
CLI image pinned by digest
(`REPLACE_WITH_CLAUDE_CODE_IMAGE@sha256:REPLACE_WITH_IMAGE_DIGEST`). Requirements:

- The image **ENTRYPOINT is the Claude Code CLI**, so `--allowedTools`,
  `--max-turns`, and `-p` apply directly.
- Confirm it runs **non-interactively** with the allowlist (some versions also
  need a permission-mode flag, e.g. `--permission-mode acceptEdits`).
- Confirm the CLI can write to `/work` when run as `--user 1000` (the workflow
  `chmod -R a+rwX`s the mount so any uid can write).
- **Never** use a floating tag — re-pin + re-audit on any bump (a compromised
  image exfiltrating via the gateway is the residual GH-runner risk).

### 3. Repo variables (this repo)

| Variable | Value |
|---|---|
| `DISPATCHER_URL` | `https://feedback.stitchtec.dev` |
| `AGENT_OIDC_AUDIENCE` | e.g. `stitch-agent-dispatcher` — **must equal** the dispatcher's `AGENT_OIDC_AUDIENCE` |

No repo **secret** is needed here **by design** — the runner holds no crown-jewel
secret. The dispatcher additionally asserts the OIDC `repository`,
`repository_owner`, and pinned `job_workflow_ref` of `copy-agent.yml`.

### 4. Enroll a target repo (`agent-guard.yml`)

Copy `target-repo-files/.github/workflows/agent-guard.yml` into the client repo,
then:

- Pin `<REPLACE_WITH_CHECKOUT_SHA>` and set
  `<REPLACE_WITH_AGENT_RUNNER_COMMIT_SHA>` to the exact `agent-runner` commit
  that holds the `scripts/check-copy-diff.sh` you want enforced (re-pin when you
  change the policy). Optionally record the script's sha256 in the commented
  `sha256sum -c` line for a stronger pin.
- If `Stitch-TEC/agent-runner` is **private**, add target-repo secret
  `AGENT_RUNNER_READ_TOKEN` (a read-only, agent-runner-scoped fine-grained PAT);
  the fetch uses it automatically and works unauthenticated if the repo is public.
- On the protected branch (`main`): add the `guard` job as a **required status
  check**, require ≥1 review, forbid force-push, and ensure the **Stitch Agent
  App is NOT in the bypass list**.
- (Optional cosmetic) create `agent-copy` and `unreviewed` labels so Phase B can
  apply them; labeling is best-effort and never fails a run.
- Install the App on the repo (one-repo), enable branch protection, and enable
  Cloudflare Pages preview-on-branch (for `previewUrl` backfill).

## The guard policy (`scripts/check-copy-diff.sh`)

- **ALLOW**: paths ending `.md`, `.mdx`, `.txt` (covers `content/**` and
  `src/content/**`).
- **DENY (wins)**: `.github/**`; `.js .jsx .ts .tsx .mjs .cjs .json .lock`,
  `package*.json`; anything containing `auth`; `.env*`; `Dockerfile`;
  `wrangler.*`; `*.yml/*.yaml`; and executable/markup `*.html .htm .svg .xml
  .xhtml`.
- **SIZE**: ≤ 5 files and ≤ 40 changed lines.
- Renamed/quoted/unparseable paths are rejected; the denylist deliberately
  over-matches (fail-closed). Every failure exits non-zero.

Input auto-detects `git diff --numstat [RANGE]` (richest — use for CI ranges) or
`git diff --name-only` (line counts derived from the working tree); with no
stdin it runs `git diff --numstat` itself. `agent-guard.yml` additionally flags
any **new http(s) egress host** added in prose and fails red.
