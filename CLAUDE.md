# agent-runner — repo orientation (auto-loaded)

The **Stitch-owned, sandboxed execution half** of the tickets → agent-PR **copy lane** — the half that gets
the repo write token. Published as the private `Stitch-TEC/agent-runner`. The **dispatcher** half lives in
`feedback-worker` (`POST /agent/dispatch` + `/agent/{read-token,brief,git-token,complete}`).

**Read `../STAGE-2-AGENT-DESIGN.md` before touching anything here** — it is the threat model this repo
implements, and every file is load-bearing against a specific attack.

> **Status (2026-07-23): BUILT + LIVE + SEALED.** The lane is deployed and wired (GitHub App 4267006, all
> secrets set, D1 + R2 live), and the pilot ruleset (`Stitch-TEC/Stitch-TEC` #18784930) now **requires the
> `guard` status check + 1 approving review** (repository-admin bypass for the human operator; the App has
> none) — *"the agent never merges"* is finally **by capability**. `Stitch-TEC/Lyf-Fit` is enrolled the same
> way (classic branch protection: `guard` required + 1 review). **This repo is PUBLIC (2026-07-24,
> operator-delegated call):** the guard's SHA-pinned script fetch needs no credential anywhere — chosen over
> an `AGENT_RUNNER_READ_TOKEN` PAT because that token would live in EVERY enrolled repo's Actions secrets
> (readable by any workflow there) and need rotation forever. Nothing here was ever secret (full-history
> scan: clean); every control is capability-enforced (SHA pins, OIDC+nonces, App permissions, sealed
> rulesets), so disclosure weakens nothing. Do NOT add secrets to this repo — it is public by design.
>
> **Two lanes since 2026-07-23:** `stitch-agent-copy` (Phase A = Claude Code in the FS jail, prose tweaks
> from an operator brief) and **`stitch-agent-publish`** — DETERMINISTIC: the dispatcher stores an
> operator-approved Spool draft (sha256-pinned) and Phase A writes those exact bytes to the staged path.
> No model call, no AI spend, no brief-injection surface. Publish branches are `stitch/agent/publish-*`
> (the target-repo guard waives only its no-new-URLs rule there). Guard v2 caps: ≤5 files, ≤600 added,
> ≤40 deleted lines.

## Layout

| Path | Role |
|---|---|
| `.github/workflows/copy-agent.yml` | The runner. Fires on `repository_dispatch: stitch-agent-copy`. **Phase A** generates a prose diff inside a Docker FS jail with **no token in env**; **Phase B** (`needs:`-gated) mints a write token and opens the PR. |
| `scripts/check-copy-diff.sh` | The **fail-closed prose-only path + size guard**. Single source of truth, run in **three** places (Phase A, Phase B, and every target repo's `agent-guard`). |
| `target-repo-files/.github/workflows/agent-guard.yml` | Copy into **each enrolled target repo**. Fetches `check-copy-diff.sh` **pinned by commit SHA** and runs it against the PR diff — it never executes a script from the PR head. |
| `Dockerfile` | The Claude Code image. Published to GHCR and **pinned by digest** in `copy-agent.yml`. |

## Invariants — don't break these

- **Small enrolled set, single-repo tokens (policy evolved 2026-07-23 for multi-repo enrollment).** The org
  installation holds ONLY the enrolled repos (`repository_selection: selected`; the dispatcher's installs
  audit alerts past `AGENT_ENROLLED_REPOS_MAX`), and every per-run token is minted for EXACTLY the dispatched
  repo (`repositories:[repo]`, response-validated) — that per-run scope is the primary guarantee a run can
  only touch its own repo. **Never widen the installation to "all repositories".**
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
- **The agent never merges — by CAPABILITY since 2026-07-23.** Merging needs the ruleset/protection satisfied:
  both enrolled repos require the `guard` check + 1 approving review, and the App has no bypass — a
  Contents:write token alone can no longer merge. Keep it that way: never grant the App a bypass, never drop
  the required check or the review count when touching rulesets/protection.
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
