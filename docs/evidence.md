# Evidence: what the numbers in the README come from

Orka was extracted from two private production projects, run between August and September 2026:

- **Project A:** a fitness/nutrition product: Nitro API, Nuxt admin panel, Expo React Native app, Postgres. Bug-fix and feature rounds driven by customer feedback.
- **Project B:** an AI image pipeline: Nuxt app, job queue, several image models behind an OpenAI-compatible gateway, human review UI.

In both, **Claude Code (Opus) was the orchestrator** and **Codex CLI and Grok CLI were the workers**. Every worker run went through a bash runner like the one in this repo and left a `meta.json`. Most runs were then scored by the orchestrator in a ledger. Customer names, bug details and credentials are removed below; the numbers are unchanged.

## Runs

**217 worker runs · 170 task cards · 67 worker-hours · 10 non-zero exits.** (Counted from every `meta.json` the two runners wrote.)

| Worker / model (Sep 2026 ids) | Runs | Non-zero exit | Median minutes | Used as |
|---|---:|---:|---:|---|
| codex / gpt-6-luna | 68 | 6 | 10 | junior: QA, research, simple fixes |
| grok / grok-4.7 | 41 | 1 | 23 | mid: development |
| codex / gpt-6-astra | 38 | 1 | 4 | lead: reviews |
| codex / gpt-6-sol | 31 | 2 | 27 | senior |
| codex / gpt-5.6-terra | 25 | 0 | 19 | mid / sub-worker |
| codex / gpt-5.6-sol | 13 | 0 | 20 | senior |
| grok / grok-4.7-build-fast | 1 | 0 | 11 | tried once; about 2× the cost, dropped |

Grok CLI reports its own cost: the 26 Grok cards scored in the Project A ledger cost **$1.47–$9.35 each, median $3.70**. Codex reports tokens, not dollars.

A non-zero exit is not the same as bad work. Most bad work exited 0 and was caught by acceptance, review or QA. That is the point of the rules.

## Ledger scores (orchestrator-assigned, 0–100)

96 runs were scored by hand. `smart` = cleared the hard point; `dumb` = the worst silly mistake (lower is better).

| Model | Scored runs | Avg smart | Avg dumb |
|---|---:|---:|---:|
| gpt-6-astra (lead reviews) | 19 | 93 | 4 |
| gpt-5.6-sol | 9 | 87 | 7 |
| grok-4.7 | 28 | 84 | 7 |
| gpt-6-sol | 14 | 82 | 20 |
| gpt-6-luna | 22 | 66 | 20 |
| **the orchestrator itself** (claude-opus, per day) | 2 | 82 | 32 |

These are one orchestrator's judgements, not a benchmark. They were good enough to steer assignment: Astra became the default reviewer, Luna was kept on QA and research, and Grok took over development when Codex quota ran low.

## First-round lead reviews

Project A had **16 first-round lead reviews** (the lead's first look at a branch whose author reported builds and tests passing). **15 came back REQUEST CHANGES; 1 was APPROVE WITH NITS.** Median time: about 4 minutes (fastest 1:25, slowest 12:41).

The 9 below are the ones scored in the ledger, with what the lead found:

| Review of | Time | What the lead found |
|---|---:|---|
| Registration form contract change | 2:17 | Stricter validation made **old stored records disappear** from the admin page (reproduced base vs branch); a new test file was never run by the test script |
| Admin session / auth | 3:32 | 3 majors with in-memory probes: an expired-token renewal grace period **not revoked by logout** (45-minute replay window), sleep/wake bypassing idle expiry, PII in 4xx logs |
| Meal-plan migration and reminders | 2:38 | Migration matched names exactly only (verified in Postgres against real variants); yesterday's miss cleared by today's upload; bulk send ignored exclusions |
| Checkout / payments | 2:44 | Order status not tied to provider-confirmed payment; **non-idempotent order creation (double orders)**; a stock guard lost in the refactor; the test only checked source strings |
| Recipe ingredient resolution | 1:25 | UI/API name-normalisation mismatch changed unrelated records; a stale save could undo a resolution; a duplicate race with no unique constraint |
| Reference-data sync (destructive) | 3:22 | Reproduced a **referenced record being deleted**; a concurrent-writer race |
| Spreadsheet import/export | 6:02 | Formula injection; measured quadratic parse time; duplicate on day swap; concurrent note loss (5 of 6 reproduced at runtime) |
| Refund / renewal flow | 4:35 | Pending refund cut access early; refund not bound to the payment that funded it (reproduced) |
| Payment callback hardening | 3:57 | A placeholder IP in refunds; unconditional `X-Forwarded-For` trust; a repair script that ran on import |

Most of these branches went through 2–4 review rounds until APPROVE. The re-reviews mostly confirmed the fixes, and several found one more issue.

## Incidents behind the rules

- **Worker overclaims** (Project B, day 1): two workers reported success that independent acceptance disproved; one reported a reference-image test as working when the output was a near-copy of the input. → *A worker's "done" is a claim.*
- **Synthetic test data** (Project A): a senior's fix passed its unit test twice against a hand-trimmed object. A junior's browser QA showed it still failed on the real stored row; the third attempt built the test from real stored JSON. → *Tests use real data shapes.*
- **Green tests, broken button** (Project B): a review UI shipped with its main button blocked by CSP; attempt 2 was required to include a browser check. → *UI changed = seen in a browser.*
- **Simulated defaults in production config** (Project B): a Docker card shipped placeholder values in the production compose file. → *No mocks, no fake success.*
- **The 10% re-check** (Project A): after a round where QA used the developers' own checklists, the owner checked staging and found only about 10% of the reported items fully done. Re-check cards were rewritten to use only the owner's original words. → *Done = the user's words.*
- **Shared browser session** (Project A): parallel testers using the default `playwright-cli` session jumped onto each other's pages. → *Own browser session per card.*
- **Leftover browsers** (Project A): headless browsers and dev servers left running after cards exhausted the machine's memory. → *Clean up; kill by PID.*
- **Orchestrator mistakes** (both, from its own retro lines): a worker hung on stdin (fixed with `< /dev/null`); the runner was edited while jobs were running (2 crashed runs, lost timing); a research card was sent without web access and cited from memory; a token was printed by a `grep`; a `pkill` killed the orchestrator's own shell. → *These are now in the runner or the skill.*
