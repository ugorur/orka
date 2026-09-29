# Privacy

Orka collects no data. It has no telemetry, no analytics and no server of its own.

- **Everything stays in your repository.** Task cards, prompts, worker reports, run logs and the ledger are written to `.orka/` in your project, which Orka excludes from git.
- **Orka's scripts make no network calls.** The only exception is `install.sh`, which clones this repository from GitHub.
- **Workers are third-party CLIs.** The coding-agent CLIs you configure in `orka.json` (Codex, Grok, Claude Code, Cursor, Gemini, OpenCode, Copilot, or your own) receive the task card, the prompt and access to their git worktree, and send that to their provider under that provider's own terms and privacy policy. Orka chooses which CLI runs a card; it does not add any destination of its own.
- **Secrets in reports are masked.** Values that look like API keys, tokens or passwords are redacted from worker reports before they are stored, but workers can still read whatever is in their worktree. Keep secrets out of the repository.

Questions: [open an issue](https://github.com/ugorur/orka/issues).
