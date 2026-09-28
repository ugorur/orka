#!/usr/bin/env bash
# End-to-end check of the Orka plumbing with a fake worker (no model, no network).
#   bash tests/smoke.sh
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

proj="$tmp/app"
mkdir -p "$proj" && cd "$proj" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
echo hi > README.md && git add . && git commit -qm init

bash "$repo/skills/orka/scripts/init.sh" "$proj" > "$tmp/init.out" || fail "init"
for p in bin/orka bin/run.sh bin/workers/codex.sh COMMON.md ledger.jsonl decisions.md backlog.md templates/card.md; do
  [ -e ".orka/$p" ] || fail "init did not create .orka/$p"
done
[ -z "$(git status --porcelain)" ] || fail ".orka is not git-excluded: $(git status --porcelain)"
grep -q "No .orka/orka.json yet" "$tmp/init.out" || fail "init should ask for a team"
ok "init"

cp "$repo/tests/workers/fake.sh" .orka/bin/workers/fake.sh
cat > .orka/orka.json <<'EOF'
{ "team": { "senior": { "cli": "fake", "model": "m-senior", "effort": "high" },
            "junior": { "cli": "fake", "model": "m-junior", "effort": "low" } },
  "parallel": 2, "timeoutMinutes": 1 }
EOF
printf '# Card c01 — hello\nDo the thing.\n' > .orka/tasks/c01-hello.md
printf 'APP_PORT=4101\n' > .orka/env/c01.env

.orka/bin/orka run c01-hello senior > /dev/null || fail "run by role"
a=.orka/runs/c01-hello/attempt-1
[ -d "$tmp/app-wt/c01-hello" ] || fail "default worktree not created"
[ "$(git -C "$tmp/app-wt/c01-hello" branch --show-current)" = orka/c01-hello ] || fail "worktree branch"
head -1 $a/prompt.md | grep -q "^ORKA_WORKER" || fail "worker marker not first line"
grep -q "Rules for every card" $a/prompt.md || fail "COMMON.md not in prompt"
grep -q "Do the thing" $a/prompt.md || fail "card not in prompt"
grep -q "APP_PORT=4101" $a/prompt.md || fail "slot env not in prompt"
grep -q "model=m-senior effort=high" $a/report.txt || fail "role not resolved: $(cat $a/report.txt)"
jq -e '.rc == 0 and .commits == 1 and .role == "senior" and .timedOut == false' $a/meta.json > /dev/null || fail "meta: $(cat $a/meta.json)"
[ ! -e $a/running ] || fail "running marker left behind"
ok "run by role (worktree, prompt, report, meta)"

.orka/bin/orka run c01-hello fake m-x medium > /dev/null || fail "explicit run"
grep -q "model=m-x effort=medium" .orka/runs/c01-hello/attempt-2/report.txt || fail "explicit override"
ok "explicit override + attempt numbering"

printf '# Card c02\nleak\n' > .orka/tasks/c02-leak.md
ORKA_FAKE_LEAK='OPENAI_API_KEY=sk-abcdefghijklmnop1234 and Bearer abc.def.ghi' .orka/bin/orka run c02-leak junior > /dev/null
grep -q 'sk-abcdefghijklmnop1234\|abc.def.ghi' .orka/runs/c02-leak/attempt-1/report.txt && fail "secret not redacted"
ok "report redaction"

printf '# Card c03\nslow\n' > .orka/tasks/c03-slow.md
jq '.timeoutMinutes = 0.05' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
ORKA_FAKE_SLEEP=30 .orka/bin/orka run c03-slow junior > /dev/null && fail "timeout should fail"
jq -e '.timedOut == true' .orka/runs/c03-slow/attempt-1/meta.json > /dev/null || fail "timeout not recorded"
ok "timeout"

jq '.timeoutMinutes = 1' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
for c in q1 q2 q3; do printf '# Card %s\n' $c > .orka/tasks/$c-job.md; done
start=$(date +%s)
ORKA_FAKE_SLEEP=6 .orka/bin/orka queue "q1-job junior" "q2-job junior" "q3-job senior" > "$tmp/queue.out" || fail "queue"
for c in q1 q2 q3; do jq -e '.rc == 0' .orka/runs/$c-job/attempt-1/meta.json > /dev/null || fail "queue job $c"; done
grep -q "queue done" "$tmp/queue.out" || fail "queue output"
ok "queue ($(( $(date +%s) - start ))s for 3 jobs, parallel 2)"

.orka/bin/orka status > "$tmp/status.out"
grep -q "c01-hello .*done" "$tmp/status.out" && grep -q "c03-slow .*timeout" "$tmp/status.out" || fail "status: $(cat "$tmp/status.out")"
ok "status"

.orka/bin/orka score c01-hello predicted 80 10 60 70 "senior for the schema work" > /dev/null || fail "score predicted"
.orka/bin/orka score c01-hello actual 85 5 70 70 "clean" > /dev/null || fail "score actual"
.orka/bin/orka score c01-hello actual 101 0 0 0 "x" 2> /dev/null && fail "score accepts >100"
tail -1 .orka/ledger.jsonl | jq -e '.worker == "fake/m-x/medium" and .attempts == 2' > /dev/null || fail "actual score lacks worker: $(tail -1 .orka/ledger.jsonl)"
.orka/bin/orka score --summary | grep -q "fake/m-x/medium" || fail "summary"
ok "score + summary"

bash "$repo/skills/orka/scripts/init.sh" "$proj" > "$tmp/init2.out" || fail "re-init"
grep -q "senior: fake m-senior" "$tmp/init2.out" && [ -s .orka/ledger.jsonl ] || fail "re-init lost state"
[ -x .orka/bin/workers/fake.sh ] || fail "re-init removed a custom adapter"
ok "re-init keeps team, ledger and custom adapters"

echo "all smoke checks passed"
