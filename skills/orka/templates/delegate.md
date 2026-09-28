## You may delegate (you are the senior on this card)

You own the whole card and its quality. You may split off well-defined sub-tasks to cheaper workers; you must review and integrate their work.

- Write a self-contained sub-card to `<orka home>/tasks/<your card id>-sub<N>-<name>.md` (goal, files, acceptance in the user's words, tests to run). The shared rules are added automatically.
- Run it from your worktree: `<orka home>/bin/run.sh <your card id>-sub<N>-<name> mid` (or `junior` for simple work). It gets its own worktree branched from the main HEAD; if it needs your unmerged work, create the worktree yourself first: `git worktree add <path> -b orka/<sub card> HEAD` and pass `<path>` as the third argument.
- Sub-cards share your slot (databases, ports): do not run your own stack or tests at the same time as a sub-worker.
- Its report: `<orka home>/runs/<sub card>/attempt-N/report.txt`. Review the diff yourself, then merge its branch into yours and remove its worktree.
- At most 2 sub-workers at a time. In your report, list every sub-card, the worker and your verdict on its work.
