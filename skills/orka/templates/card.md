# Card <id> — <short title>

<!-- One card = one worker = one worktree. Self-contained: the worker has not seen the conversation. -->

**Spec:** <where the user's words / decisions live, e.g. `.orka/backlog.md` → item 4, `docs/bugs.md` → B12>. Those words are the definition of done.

## Goal
<What the user should see or be able to do when this is done, in their words.>

## The hard point
<The one thing that makes this card difficult or risky — the part a careless worker gets wrong. Say it plainly.>

## Facts I measured
<What the orchestrator already verified (commands, file:line, API responses). Saves the worker from re-discovering it. Omit if none.>

## Scope
- <files / modules in scope>
- **Out of scope:** <what not to touch>

## Environment
<Databases, ports, services, test accounts for this card's slot — or "none". Budget limits for paid calls.>

## Acceptance (I will re-run these)
- <exact commands that must pass>
- <observable behaviour to check, e.g. route → click → expected text>
- <evidence to save, e.g. screenshots to `.orka-evidence/<id>-*.png`>

## Bug (only for a bug card — delete otherwise)
- Reproduce first and paste the failing output in the report before changing code.
- Check for a regression (`git log -S`, `git bisect` or blame) and find the first place things go wrong.
- Fix the root cause there, and every caller with the same fault.
- Revert anything you added for a guess the evidence refuted.
- Write the failing test first when that is cheap.
- Report the repro output before and after.
