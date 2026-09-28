# Card <id>q — QA of branch `<branch>` (<title>). VERIFY ONLY — do not change application code, do not commit.

You are the QA tester. You MAY set up your own environment (slot databases, migrations, seed data, dev servers, test data through the app or API) — that is not changing anything.

**Your reference is the user's words:** <where they live>. The developer's checklist below is a starting point, not the definition of done. Check every place the request applies.

## Checklist
<numbered steps: route/screen/command · exact input or clicks · expected visible result>

## How
- Build / typecheck / test the packages the branch touched (`git diff --stat <base>...HEAD`) and paste the last lines.
- Browser: headless only, your own session (`-s=<id>q`), screenshot every checked state to `.orka-evidence/<id>q-<n>.png`. Mobile/CLI: run it and capture the output.
- If a check needs data that does not exist, create it. "No data" is not a result.
- If something fails, try another way before giving up. NOT RUN needs the exact error.
- Stop only the processes you started; close your browser session.

## Report
A table: step | PASS / FAIL / NOT RUN | what you did | what you saw (exact text) | evidence. Then build/test tails. Then "New problems noticed". When in doubt it is FAIL, not PASS.
