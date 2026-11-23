# Card <id> — Perf: <short title>. A card with a numeric target.

<!-- Append to or replace the body of templates/card.md when the card has a number to hit. -->

**Target:** <metric, unit, data set, the number that means done — e.g. p50 of `POST /export` under 200 ms on the 60k-row fixture>.

## How to measure
- Measure a baseline first, before any change. Record the command, the machine load, and what the timed region includes.
- Report the median of 5 or more runs, alternating baseline and candidate (A, B, A, B, …) so drift hits both sides.
- One change per measurement. Keep a change only if the number moves beyond the run-to-run spread; otherwise revert it.
- Stop when the target is met. Do not keep tuning past it.

## Report
A table: change | median (unit) | range | kept or reverted | why. Then the baseline command and one raw run's output.
