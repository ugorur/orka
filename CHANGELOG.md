# Changelog

## 0.4.0 — unreleased

- Reviews must prove a blocker or major with a command and its output. Style and naming never block. Problems already on the base branch are Pre-existing. A small diff gets a short review. Review rounds stop at `reviewRounds` (default 2); leftovers that do not block become follow-up cards.
- A card's acceptance is the whole bar. A test that fails once and passes on one rerun is reported as flaky, and is never skipped or disabled.
- Bug cards reproduce first, hunt the regression, fix the root cause and every caller with the same fault, and revert guesses the evidence refuted. Before a third attempt at the same hard point, the shared premise is tested directly.
- If `.orka/verify.md` exists, QA launches and drives the app from it. A QA card can write that guide; it counts only after one QA run has worked from it.
- Pausing mid-work commits unfinished edits as one `wip:` commit and writes `.orka/RESUME.md`. Pickup starts from that file and checks its claims against the repo.
- Optional `budget` (or `ORKA_BUDGET`) lowers every role's effort by N steps, never below `low`. Explicit one-off runs are not lowered.
- `orka prune [--dry-run]` removes worktrees that are merged, clean, and not in use, and lists the rest with the reason.
- `orka status` flags a running card `SLOW` when it has run more than twice its role's median (after 3 finished runs of that role). Look at the log; do not kill it for that alone.
- After a rebase, the same `git patch-id` means the review still stands. A different patch-id gets acceptance re-run and a lead check of the delta only.
- Perf cards measure a baseline first, report the median of 5 or more alternating runs, change one thing at a time, and keep a change only when the number moves.
- A retro asks, for each new rule, what script, lint, test or check could enforce it instead of more text.
- If a CLI rejects a role's model, the runner retries once with that role's `fallbackModel` and records `modelFallback`.
