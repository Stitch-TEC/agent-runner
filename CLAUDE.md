# agent-runner — repo orientation (auto-loaded)

The **Stitch-owned, sandboxed execution half** of the tickets → agent-PR **copy lane** — the half that gets
the repo write token. Published as the private `Stitch-TEC/agent-runner`. The **dispatcher** half lives in
`feedback-worker` (`POST /agent/dispatch` + `/agent/{read-token,brief,git-token,complete}`).

**Read `../STAGE-2-AGENT-DESIGN.md` before touching anything here** — it is the threat model this repo
implements, and every file is load-bearing against a specific attack.

> **Status (2026-07-14): BUILT + LIVE, NOT SEALED.** The lane is deployed and wired (GitHub App 4267006,
> all secrets set, D1 + R2 live). **Outstanding:** the pilot repo `Stitch-TEC/Stitch-TEC` has
> `required_approving_review_count: 0` and **no required status checks**, so `agent-guard` runs but nothing
> blocks a merge over a red guard — meaning *"the agent never merges, by capability"* is currently only policy.
> Fix = require the `agent-guard` check + set approvals to 1. Until then, treat any agent PR as unmerged-by-luck.

## Layout

| Path | Role |
|---|---|
| `.github/workflows/copy-agent.yml` | The runner. Fires on `repository_dispatch: stitch-agent-copy`. **Phase A** generates a prose diff inside a Docker FS jail with **no token in env**; **Phase B** (`needs:`-gated) mints a write token and opens the PR. |
| `scripts/check-copy-diff.sh` | The **fail-closed prose-only path + size guard**. Single source of truth, run in **three** places (Phase A, Phase B, and every target repo's `agent-guard`). |
| `target-repo-files/.github/workflows/agent-guard.yml` | Copy into **each enrolled target repo**. Fetches `check-copy-diff.sh` **pinned by commit SHA** and runs it against the PR diff — it never executes a script from the PR head. |
| `Dockerfile` | The Claude Code image. Published to GHCR and **pinned by digest** in `copy-agent.yml`. |

## Invariants — don't break these

- **One repo per install.** The App is installed one repository per installation (each target repo *and* this
  repo). That scope is the **primary** guarantee a run can only touch the repo it was dispatched for; the
  dispatcher's response-scope validation is the backstop. **Never widen an installation to "all repositories".**
- **No crown-jewel secret lives here.** The App private key lives ONLY in the dispatcher's secret store. Every
  capability is a short-lived token the dispatcher mints after re-checking server-side. The
  "let the Action mint its own token from repo secrets" shortcut is **rejected outright** — one curious client
  repo would mean write access to every client.
- **Phase A never sees a token.** The write token exists only in step-scoped Phase B steps. Verify this holds
  after any workflow edit.
- **The guard is fail-closed and runs 3×.** If you change `check-copy-diff.sh`, re-pin `GUARD_SHA` in every
  target repo's `agent-guard.yml` — they fetch it by SHA on purpose.
- **Pin everything.** Third-party action SHAs and the container image digest are pinned deliberately; a floating
  tag is a supply-chain hole. Workflow permissions default-none; no `pull_request_target`.
- **The agent never merges — ⚠️ by POLICY, not capability (corrected 2026-07-14).** The design claims this is
  structural; it currently isn't. Merging a PR needs **Contents:write**, *not* Administration — and Phase B mints
  exactly `{contents:'write', pull_requests:'write'}` on the target repo (`feedback-worker/src/index.ts:4572`).
  So the App **can** merge its own PR; only the workflow declining to call merge stops it, and the pilot ruleset
  requires **0 approvals and no status checks**. **Seal it** (require `agent-guard` + 1 approval) and this becomes
  the structural guarantee the design describes. Until then, don't repeat the "by capability" claim.
- **The agent sees OPERATOR-AUTHORED context only** (locked 2026-07-09). `/agent/brief` returns the operator's
  instruction + approved client context, **never ticket text** — this structurally severs the
  prompt-injection→agent loop. Do not "helpfully" pass the ticket body through.

## Gotchas

- **Node 25 in this env** → prefix wrangler calls with `NODE_OPTIONS=--dns-result-order=ipv4first`.
- Dispatcher config is **payload-first** (`dispatcherUrl` + `oidcAudience` ride the `repository_dispatch`
  payload) with repo-var fallback — change both halves together.
- Phase A records `base.sha` → Phase B branches from it and applies with `git apply --3way` (base-drift fix).
- Nonce/token TTLs are tuned to the runner's wall-clock (token 40m < nonces 45m < sweep 50m). Shortening them
  re-introduces the 403-on-slow-run bug.
