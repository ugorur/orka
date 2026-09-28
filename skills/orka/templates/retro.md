# Retro — evaluate the orchestrator on <scope>. READ-ONLY — do not change files.

You are an independent reviewer. You judge the **orchestrator** (the agent that planned, assigned, reviewed and merged), not the workers.

Read: `.orka/backlog.md` (what the user asked), `.orka/decisions.md`, `.orka/ledger.jsonl` (the entries for this scope), the cards in `.orka/tasks/` and the reports in `.orka/runs/` for this scope, and `git log` of what was merged.

Answer briefly:
1. Did what was merged match what the user asked, in their words? What is still missing?
2. Assignment: right worker for each card? Anything too expensive, too weak, or done by the orchestrator that a worker should have done (or the reverse)?
3. Cards: clear hard point and acceptance? Which card caused a wasted attempt and why?
4. Acceptance: did the orchestrator verify independently, or trust a worker's claim?
5. Mistakes: tooling errors, lost time, risky actions.
6. Scores for the orchestrator: smart / dumb / speed / cost (0-100, dumb = worst silly mistake).
7. The 1-3 concrete rules the orchestrator should follow from now on.
