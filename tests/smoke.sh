#!/usr/bin/env bash
# End-to-end check of the Orka plumbing with a fake worker (no model, no network).
#   bash tests/smoke.sh
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)   # canonical: macOS /var is a symlink to /private/var
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
# Fake credential for the redaction checks; split so secret scanners do not flag the fixture.
fake_key='sk-''abcdefghijklmnop1234'

proj="$tmp/app"
mkdir -p "$proj" && cd "$proj" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
echo hi > README.md && git add . && git commit -qm init

bash "$repo/skills/orka/scripts/init.sh" "$proj" > "$tmp/init.out" || fail "init"
for p in bin/orka bin/run.sh bin/finish.sh bin/prune.sh bin/lib.sh bin/workers/codex.sh COMMON.md ledger.jsonl decisions.md backlog.md templates/card.md; do
  [ -e ".orka/$p" ] || fail "init did not create .orka/$p"
done
[ -z "$(git status --porcelain)" ] || fail ".orka is not git-excluded: $(git status --porcelain)"
grep -q "No .orka/orka.json yet" "$tmp/init.out" || fail "init should ask for a team"
ok "init"

# pre-v0.3 COMMON.md (shared rules + project section) is migrated to the project section only
cp .orka/COMMON.md "$tmp/common.new"
{ cat "$repo/skills/orka/scripts/rules.md"; echo; echo '<!-- Project-specific rules go below: x -->'; echo '- project rule X'; } > .orka/COMMON.md
bash "$repo/skills/orka/scripts/init.sh" "$proj" > "$tmp/init2.out" || fail "re-init"
grep -q "Migrated" "$tmp/init2.out" && grep -qx -- '- project rule X' .orka/COMMON.md && ! grep -q "Rules for every card" .orka/COMMON.md \
  && [ -f .orka/COMMON.md.bak ] || fail "COMMON.md migration: $(cat .orka/COMMON.md)"
cp "$tmp/common.new" .orka/COMMON.md
ok "COMMON.md migration"

# templates: project edits survive, skill changes merge in, only conflicts are handed to the orchestrator
T=.orka/templates; B=$T/.base
echo LOCAL-CARD >> $T/card.md                                        # project edit, skill unchanged
sed 1d $B/review.md > "$tmp/b" && cp "$tmp/b" $B/review.md && { cat "$tmp/b"; echo LOCAL-REVIEW; } > $T/review.md   # clean merge
sed '1s/.*/BASE/' $B/retro.md > "$tmp/b" && cp "$tmp/b" $B/retro.md && sed '1s/.*/MINE/' "$tmp/b" > $T/retro.md     # conflict
rm $B/qa.md && echo LOCAL-QA >> $T/qa.md                              # no base
bash "$repo/skills/orka/scripts/init.sh" "$proj" > "$tmp/init3.out" || fail "re-init templates"
grep -q LOCAL-CARD $T/card.md || fail "project template edit lost"
grep -q LOCAL-REVIEW $T/review.md && cmp -s <(sed '$d' $T/review.md) "$repo/skills/orka/templates/review.md" || fail "clean merge: $(cat $T/review.md)"
grep -q '^<<<<<<< project' $T/retro.md && grep -q "retro.md: conflict" "$tmp/init3.out" || fail "conflict not reported"
[ -f $T/qa.md.new ] && grep -q LOCAL-QA $T/qa.md && grep -q "qa.md: compare" "$tmp/init3.out" || fail "no-base case"
grep -q "card.md\|review.md" "$tmp/init3.out" && fail "clean files listed for reconcile"
cp "$repo"/skills/orka/templates/* $T/ && rm $T/qa.md.new
ok "template reconcile"

cp "$repo/tests/workers/fake.sh" .orka/bin/workers/fake.sh
cat > .orka/orka.json <<'EOF'
{ "team": { "senior": { "cli": "fake", "model": "m-senior", "effort": "high" },
            "junior": { "cli": "fake", "model": "m-junior", "effort": "low" },
            "native": { "cli": "subagent", "model": "sonnet", "effort": "medium" } },
  "parallel": 2, "timeoutMinutes": 1 }
EOF
printf '# Card c01 — hello\nDo the thing.\n' > .orka/tasks/c01-hello.md
printf 'APP_PORT=4101\n' > .orka/env/c01.env

.orka/bin/orka run c01-hello senior > /dev/null || fail "run by role"
a=.orka/runs/c01-hello/attempt-1
[ -d "$tmp/app-wt/c01-hello" ] || fail "default worktree not created"
[ "$(git -C "$tmp/app-wt/c01-hello" branch --show-current)" = orka/c01-hello ] || fail "worktree branch"
head -1 $a/prompt.md | grep -q "^ORKA_WORKER" || fail "worker marker not first line"
grep -q "Rules for every card" $a/prompt.md || fail "rules.md not in prompt"
grep -q "^## Project" $a/prompt.md || fail "COMMON.md not in prompt"
grep -q "Do the thing" $a/prompt.md || fail "card not in prompt"
grep -q "APP_PORT=4101" $a/prompt.md || fail "slot env not in prompt"
grep -q "model=m-senior effort=high" $a/report.txt || fail "role not resolved: $(cat $a/report.txt)"
jq -e '.rc == 0 and .commits == 1 and .role == "senior" and .timedOut == false' $a/meta.json > /dev/null || fail "meta: $(cat $a/meta.json)"
[ ! -e $a/running ] || fail "running marker left behind"
ok "run by role (worktree, prompt, report, meta)"

.orka/bin/orka run c01-hello fake m-x medium > /dev/null || fail "explicit run"
grep -q "model=m-x effort=medium" .orka/runs/c01-hello/attempt-2/report.txt || fail "explicit override"
ok "explicit override + attempt numbering"

# --- Native sub-agent prepare / finish lifecycle ------------------------------------------
printf '# Card c10\nnative work\n' > .orka/tasks/c10-native.md
.orka/bin/orka run c10-native native > "$tmp/subagent.out" || fail "subagent prepare"
sa=.orka/runs/c10-native/attempt-1
native_wt="$tmp/app-wt/c10-native"
grep -q '^subagent c10-native attempt 1$' "$tmp/subagent.out" || fail "subagent output: $(cat "$tmp/subagent.out")"
grep -q "model:    sonnet" "$tmp/subagent.out" || fail "subagent model output"
grep -q "worktree: $native_wt" "$tmp/subagent.out" || fail "subagent worktree output"
grep -q "prompt:   $proj/$sa/prompt.md" "$tmp/subagent.out" || fail "subagent prompt output"
grep -q "report:   $proj/$sa/report.txt" "$tmp/subagent.out" || fail "subagent report output"
[ -f "$sa/prompt.md" ] && [ -f "$sa/pending" ] && [ ! -f "$sa/meta.json" ] || fail "subagent prepare files"
sed -n '2p' "$sa/prompt.md" | grep -Fq "Your working directory is \`$native_wt\`" \
  || fail "subagent prompt does not lead with its absolute worktree: $(sed -n '1,3p' "$sa/prompt.md")"
subagent_lock=".orka/runs/.locks/$(printf '%s' "$(cd "$native_wt" && pwd -P)" | tr '/ ' '__')"
[ ! -L "$subagent_lock" ] || fail "subagent prepare left its pid lock"
subagent_card_lock=".orka/runs/.locks/card-c10-native"
[ "$(readlink "$subagent_card_lock" 2>/dev/null)" = "$proj/$sa/pending" ] || fail "subagent card marker missing"
.orka/bin/orka status c10-native > "$tmp/subagent.status"
grep -q "c10-native .*running .*subagent/sonnet" "$tmp/subagent.status" || fail "pending status: $(cat "$tmp/subagent.status")"

printf '# Card c11\nother work\n' > .orka/tasks/c11-other.md
.orka/bin/orka run c11-other junior "$native_wt" > /dev/null 2> "$tmp/pending.err" && fail "worker entered a pending subagent worktree"
grep -q "subagent card c10-native is still pending" "$tmp/pending.err" || fail "pending exclusion message: $(cat "$tmp/pending.err")"
.orka/bin/orka queue "c11-other junior" "c10-native native" > /dev/null 2> "$tmp/subqueue.err" && fail "queue accepted a subagent job"
grep -q "queue cannot run subagent job c10-native" "$tmp/subqueue.err" || fail "subagent queue message: $(cat "$tmp/subqueue.err")"
[ ! -d .orka/runs/c11-other ] || fail "mixed queue started work before rejecting its subagent job"
if .orka/bin/orka finish c10-native > /dev/null 2> "$tmp/finish.err"; then
  fail "finish accepted a missing report"
else
  finish_rc=$?
fi
[ "$finish_rc" -eq 2 ] || fail "finish without a report did not exit 2"
grep -q "missing .*report.txt" "$tmp/finish.err" || fail "missing report message: $(cat "$tmp/finish.err")"

printf 'native\n' > "$native_wt/native.txt"
git -C "$native_wt" add native.txt && git -C "$native_wt" commit -qm native
printf 'done OPENAI_API_KEY=%s Bearer abc.def.ghi\n' "$fake_key" > "$sa/report.txt"
.orka/bin/orka finish c10-native > /dev/null || fail "subagent finish"
[ ! -f "$sa/pending" ] || fail "finish left pending state"
[ ! -L "$subagent_card_lock" ] || fail "finish left subagent card marker"
[ "$(jq -S 'keys' "$sa/meta.json")" = "$(jq -S 'keys' .orka/runs/c01-hello/attempt-1/meta.json)" ] || fail "subagent meta keys differ from CLI meta"
jq -e '.cli == "subagent" and .cliVersion == "" and .model == "sonnet" and .effort == "medium" and
       .rc == 0 and .commits == 1 and .stopped == false and .timedOut == false and .usage == null' "$sa/meta.json" > /dev/null \
  || fail "subagent meta: $(cat "$sa/meta.json")"
grep -q "$fake_key\\|abc.def.ghi" "$sa/report.txt" && fail "subagent report secret not redacted: $(cat "$sa/report.txt")"
.orka/bin/orka score c10-native actual 90 0 90 90 "native clean" > /dev/null || fail "score native attempt"
tail -1 .orka/ledger.jsonl | jq -e '.worker == "subagent/sonnet/medium" and .attempts == 1' > /dev/null || fail "native actual score metadata"
ok "subagent prepare, exclusion, status, finish, masking, meta and score"

printf '# Card c12\nabandon\n' > .orka/tasks/c12-abandon.md
.orka/bin/orka run c12-abandon native > /dev/null || fail "prepare abandoned subagent"
abandon_wt="$tmp/app-wt/c12-abandon"
.orka/bin/orka finish c12-abandon --abandon > /dev/null || fail "abandon subagent"
jq -e '.rc == 130 and .stopped == true and .timedOut == false' .orka/runs/c12-abandon/attempt-1/meta.json > /dev/null || fail "abandon meta"
[ ! -f .orka/runs/c12-abandon/attempt-1/pending ] || fail "abandon left pending state"
printf '# Card c13\nreuse\n' > .orka/tasks/c13-reuse.md
.orka/bin/orka run c13-reuse junior "$abandon_wt" > /dev/null || fail "abandoned worktree remained blocked"
ok "subagent abandon frees its worktree"

# Pause runner B immediately before its first ln(1), let A prepare a subagent in the same
# worktree, then release B. The pending scan must happen after B acquires the worktree lock.
gate_bin="$tmp/gate-bin"
mkdir -p "$gate_bin"
real_ln=$(command -v ln)
cat > "$gate_bin/ln" <<EOF
#!/bin/sh
if [ "\${ORKA_GATE_LOCK:-}" = 1 ] && [ ! -e "\$ORKA_GATE_READY" ]; then
  : > "\$ORKA_GATE_READY"
  while [ ! -e "\$ORKA_GATE_RELEASE" ]; do sleep 0.05; done
fi
exec "$real_ln" "\$@"
EOF
chmod +x "$gate_bin/ln"
printf '# Card c16 owner\n' > .orka/tasks/c16-owner.md
printf '# Card c16 racer\n' > .orka/tasks/c16-racer.md
race_wt="$tmp/app-wt/c16-shared"
git worktree add -q -b orka/c16-shared "$race_wt" HEAD || fail "create pending race worktree"
gate_ready="$tmp/pending-race.ready"
gate_release="$tmp/pending-race.release"
PATH="$gate_bin:$PATH" ORKA_GATE_LOCK=1 ORKA_GATE_READY="$gate_ready" ORKA_GATE_RELEASE="$gate_release" \
  .orka/bin/orka run c16-racer junior "$race_wt" > /dev/null 2> "$tmp/pending-race.err" &
race_pid=$!
for _ in $(seq 1 100); do [ -e "$gate_ready" ] && break; sleep 0.05; done
[ -e "$gate_ready" ] || fail "runner did not reach the pending race gate"
.orka/bin/orka run c16-owner native "$race_wt" > /dev/null || fail "prepare pending race owner"
: > "$gate_release"
wait "$race_pid" && fail "runner entered a worktree after a subagent became pending"
grep -q "subagent card c16-owner is still pending" "$tmp/pending-race.err" \
  || fail "pending race message: $(cat "$tmp/pending-race.err")"
.orka/bin/orka finish c16-owner --abandon > /dev/null || fail "clean pending race owner"
ok "pending exclusion is checked under the worktree lock"

# Pause one finisher after it has read all pending fields. A concurrent abandonment wins;
# when released, the first finisher must re-check pending and refuse to overwrite its meta.
printf '# Card c17 finish race\n' > .orka/tasks/c17-finish-race.md
.orka/bin/orka run c17-finish-race native > /dev/null || fail "prepare finish race"
finish_race_a=.orka/runs/c17-finish-race/attempt-1
printf 'finished by native agent\n' > "$finish_race_a/report.txt"
jq_gate_bin="$tmp/jq-gate-bin"
mkdir -p "$jq_gate_bin"
real_jq=$(command -v jq)
cat > "$jq_gate_bin/jq" <<EOF
#!/bin/sh
pause=0
for arg do [ "\$arg" = .effort ] && pause=1; done
output=\$("$real_jq" "\$@")
rc=\$?
if [ "\$pause" -eq 1 ] && [ "\${ORKA_GATE_FINISH:-}" = 1 ] && [ ! -e "\$ORKA_GATE_READY" ]; then
  : > "\$ORKA_GATE_READY"
  while [ ! -e "\$ORKA_GATE_RELEASE" ]; do sleep 0.05; done
fi
printf '%s\n' "\$output"
exit "\$rc"
EOF
chmod +x "$jq_gate_bin/jq"
finish_ready="$tmp/finish-race.ready"
finish_release="$tmp/finish-race.release"
PATH="$jq_gate_bin:$PATH" ORKA_GATE_FINISH=1 ORKA_GATE_READY="$finish_ready" ORKA_GATE_RELEASE="$finish_release" \
  .orka/bin/orka finish c17-finish-race 0 > /dev/null 2> "$tmp/finish-race.err" &
finish_pid=$!
for _ in $(seq 1 100); do [ -e "$finish_ready" ] && break; sleep 0.05; done
[ -e "$finish_ready" ] || fail "finisher did not reach the concurrency gate"
.orka/bin/orka finish c17-finish-race --abandon > /dev/null || fail "concurrent abandonment"
: > "$finish_release"
wait "$finish_pid" && fail "a second finisher overwrote an abandonment"
grep -q "already finished or abandoned" "$tmp/finish-race.err" \
  || fail "concurrent finish message: $(cat "$tmp/finish-race.err")"
jq -e '.rc == 130 and .stopped == true' "$finish_race_a/meta.json" > /dev/null \
  || fail "concurrent finish overwrote abandonment meta"
ok "finish is serialized and re-checks pending"

# One card cannot have two native agents open in caller-supplied worktrees.
printf '# Card c18 two prepares\n' > .orka/tasks/c18-two-prepares.md
.orka/bin/orka run c18-two-prepares native > /dev/null || fail "prepare first card attempt"
two_wt="$tmp/app-wt/c18-second"
git worktree add -q -b orka/c18-second "$two_wt" HEAD || fail "create second card worktree"
.orka/bin/orka run c18-two-prepares native "$two_wt" > /dev/null 2> "$tmp/two-prepares.err" \
  && fail "same subagent card prepared twice"
grep -q "already has an open attempt" "$tmp/two-prepares.err" \
  || fail "second prepare message: $(cat "$tmp/two-prepares.err")"
[ ! -d .orka/runs/c18-two-prepares/attempt-2 ] || fail "refused prepare left a shadow attempt"
.orka/bin/orka finish c18-two-prepares --abandon > /dev/null || fail "abandon single open attempt"
git worktree remove "$two_wt" || fail "remove second card worktree"
[ ! -L .orka/runs/.locks/card-c18-two-prepares ] || fail "abandon left per-card marker"
ok "one open subagent attempt per card"

# Abandonment must close state even if the native agent's worktree disappeared.
printf '# Card c19 missing worktree\n' > .orka/tasks/c19-missing-worktree.md
.orka/bin/orka run c19-missing-worktree native > /dev/null || fail "prepare missing worktree attempt"
missing_a=.orka/runs/c19-missing-worktree/attempt-1
missing_wt="$tmp/app-wt/c19-missing-worktree"
missing_base=$(jq -r '.base' "$missing_a/pending")
git worktree remove --force "$missing_wt" || fail "remove pending worktree"
.orka/bin/orka finish c19-missing-worktree --abandon > /dev/null || fail "abandon missing worktree"
[ ! -f "$missing_a/pending" ] || fail "missing worktree abandonment left pending"
jq -e --arg base "$missing_base" '.rc == 130 and .stopped == true and .head == $base and
      .commits == 0 and .worktreeMissing == true' "$missing_a/meta.json" > /dev/null \
  || fail "missing worktree abandonment meta: $(cat "$missing_a/meta.json")"
ok "abandon closes an attempt whose worktree is gone"

printf '# Card c14\nparallel slot\n' > .orka/tasks/c14-pending.md
printf '# Card c15\nqueued worker\n' > .orka/tasks/c15-queued.md
.orka/bin/orka run c14-pending native > /dev/null || fail "prepare pending slot test"
ORKA_PARALLEL=1 .orka/bin/orka queue "c15-queued junior" > /dev/null 2>&1 &
pending_queue=$!
for _ in $(seq 1 20); do [ -L .orka/runs/.locks/queue ] && break; sleep 0.1; done
sleep 1
[ ! -d .orka/runs/c15-queued ] || fail "queue did not count a pending subagent toward parallel"
kill -TERM "$pending_queue" 2>/dev/null
wait "$pending_queue" 2>/dev/null
.orka/bin/orka finish c14-pending --abandon > /dev/null || fail "clean pending slot test"
ok "pending subagents count toward queue parallelism"

printf '# Card c02\nleak\n' > .orka/tasks/c02-leak.md
ORKA_FAKE_LEAK='OPENAI_API_KEY='"$fake_key"' and Bearer abc.def.ghi FIXTURE_API_''KEY="quotedsecret1 tail1" DB_PASS''WORD='"'"'single1 tail2'"'"'' \
  .orka/bin/orka run c02-leak junior > /dev/null
grep -q "$fake_key\\|abc.def.ghi\\|quotedsecret1\\|single1\\|tail1\\|tail2" .orka/runs/c02-leak/attempt-1/report.txt && fail "secret not redacted: $(cat .orka/runs/c02-leak/attempt-1/report.txt)"
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

# --- Guards found by the lead review -------------------------------------------------------
.orka/bin/orka run c01-hello senior "$proj" > /dev/null 2>&1 && fail "ran a worker in the main checkout"
mkdir -p "$tmp/not-a-worktree"
.orka/bin/orka run c01-hello senior "$tmp/not-a-worktree" > /dev/null 2>&1 && fail "ran a worker outside a worktree"
ok "refuses main checkout and foreign directories"

rm -rf .orka/runs/c01-hello/attempt-1
.orka/bin/orka run c01-hello senior > /dev/null || fail "run after deleting an old attempt"
[ -d .orka/runs/c01-hello/attempt-3 ] && [ -f .orka/runs/c01-hello/attempt-2/meta.json ] || fail "attempt numbering reused a directory"
ok "attempt numbering never overwrites"

printf '# Card c04\nlong\n' > .orka/tasks/c04-long.md
ORKA_FAKE_SLEEP=37 .orka/bin/orka run c04-long junior > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do [ -f .orka/runs/c04-long/attempt-1/running ] && grep -q . .orka/runs/c04-long/attempt-1/running && break; sleep 0.2; done
sleep 1
[ "$(cat .orka/runs/c04-long/attempt-1/worktree)" = "$(cd "$tmp/app-wt/c04-long" && pwd -P)" ] \
  || fail "running attempt did not record its worktree"
.orka/bin/orka status c04-long | grep -q "c04-long .*running" || fail "status does not show a running card"
.orka/bin/orka run c04-long junior > /dev/null 2>&1 && fail "second worker allowed in a busy worktree"
mkdir -p "$tmp/app-wt/c04-long/sub"
.orka/bin/orka run c04-long junior "$tmp/app-wt/c04-long/sub" > /dev/null 2>&1 && fail "a subdirectory bypassed the worktree lock"
kill -TERM $runner; sleep 0.3; kill -TERM $runner 2>/dev/null; wait $runner
jq -e '.stopped == true and .timedOut == false' .orka/runs/c04-long/attempt-1/meta.json > /dev/null || fail "stop not recorded: $(cat .orka/runs/c04-long/attempt-1/meta.json)"
pgrep -f "^sleep 37$" > /dev/null && fail "worker survived its stopped runner"
[ ! -e .orka/runs/c04-long/attempt-1/running ] || fail "running marker left after stop"
ok "running status, one worker per worktree, stop (even twice) kills the worker"

printf '# Card c07\ntrap\n' > .orka/tasks/c07-trap.md
ORKA_FAKE_TRAP=1 ORKA_FAKE_SLEEP=37 .orka/bin/orka run c07-trap junior > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do grep -qs . .orka/runs/c07-trap/attempt-1/running && break; sleep 0.2; done
sleep 1; kill -TERM $runner; wait $runner && fail "a cancelled run exited 0"
ok "a cancelled run is never a success"

printf '# Card c08\nstubborn\n' > .orka/tasks/c08-stubborn.md
ORKA_FAKE_STUBBORN=1 ORKA_FAKE_TRAP=1 ORKA_FAKE_SLEEP=37 .orka/bin/orka run c08-stubborn junior > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do grep -qs . .orka/runs/c08-stubborn/attempt-1/running && break; sleep 0.2; done
sleep 1; kill -TERM $runner; wait $runner
pgrep -f "^sleep 39$" > /dev/null && fail "a child that ignored TERM outlived its runner"
ok "cancel kills the whole worker process group"

# Cancel while the runner is already cleaning up after a successful worker.
printf '# Card c09\ncleanup\n' > .orka/tasks/c09-cleanup.md
ORKA_FAKE_STUBBORN=1 .orka/bin/orka run c09-cleanup junior > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do [ -s .orka/runs/c09-cleanup/attempt-1/report.txt ] && break; sleep 0.2; done
sleep 1.5; kill -TERM $runner; wait $runner && fail "a run cancelled during cleanup exited 0"
jq -e '.stopped == true and .rc != 0' .orka/runs/c09-cleanup/attempt-1/meta.json > /dev/null || fail "cleanup cancel meta"
ok "a cancel during cleanup is not a success either"

wtlock=".orka/runs/.locks/$(printf '%s' "$(cd "$tmp/app-wt/c01-hello" && pwd -P)" | tr '/ ' '__')"
ln -s 999999 "$wtlock"
.orka/bin/orka run c01-hello senior 2> "$tmp/stale.err" > /dev/null && fail "ran despite a stale lock"
grep -q "stale lock" "$tmp/stale.err" || fail "stale lock message: $(cat "$tmp/stale.err")"
rm -f "$wtlock"
ln -s 999999 .orka/runs/.locks/queue
.orka/bin/orka queue "c01-hello senior" 2> "$tmp/stale.err" > /dev/null && fail "queue ran despite a stale lock"
grep -q "stale queue lock" "$tmp/stale.err" || fail "stale queue lock message"
rm -f .orka/runs/.locks/queue
ok "stale locks fail closed with a clear message"

printf '# Card c05\nbad usage\n' > .orka/tasks/c05-usage.md
i=0
for bad in 'not json' '{}\n{}' '1\n{}'; do
  i=$((i + 1))
  ORKA_FAKE_BADUSAGE=$bad .orka/bin/orka run c05-usage junior > /dev/null || fail "run with bad usage.json '$bad'"
  jq -e '.usage == null and .rc == 0' .orka/runs/c05-usage/attempt-$i/meta.json > /dev/null || fail "bad usage.json '$bad' broke meta.json"
done
ok "invalid usage.json does not break meta.json"

printf '# Card c06\nfails\n' > .orka/tasks/c06-fails.md
ORKA_FAKE_RC=7 .orka/bin/orka queue "c06-fails junior" > /dev/null && fail "queue hid a failed job"
ok "queue exit code reports failures"

trace="$tmp/trace"
for c in p1 p2 p3 p4; do printf '# Card %s\n' $c > .orka/tasks/$c-par.md; done
jq '.parallel = 1' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
ORKA_FAKE_TRACE=$trace ORKA_FAKE_SLEEP=3 .orka/bin/orka queue "p1-par junior" "p2-par junior" > /dev/null &
q1=$!
ORKA_FAKE_TRACE=$trace ORKA_FAKE_SLEEP=3 .orka/bin/orka queue "p3-par junior" "p4-par junior" > /dev/null &
q2=$!
wait $q1 $q2
[ ! -e "$trace/overlap" ] || fail "two queues ran workers at the same time with parallel 1"
set -- .orka/runs/*-par; [ $# = 4 ] || fail "not all queued jobs ran"
ok "two queues share the parallel limit"

# --- Runner features: SLOW status, budget, model fallback -------------------------------
now=$(date +%s)
for c in hist1 hist2 hist3; do
  printf '# Card %s\n' "$c" > ".orka/tasks/$c-slow.md"
  mkdir -p ".orka/runs/$c-slow/attempt-1"
  jq -n --arg card "$c-slow" \
    '{card:$card,role:"slowrole",rc:0,stopped:false,timedOut:false,seconds:60}' \
    > ".orka/runs/$c-slow/attempt-1/meta.json"
done
printf '# Card slow running\n' > .orka/tasks/slow-running.md
mkdir -p .orka/runs/slow-running/attempt-1
echo "$$ $((now - 301)) slowrole" > .orka/runs/slow-running/attempt-1/running
.orka/bin/orka status slow-running > "$tmp/slow.status"
grep -q "slow-running .*running .*slowrole SLOW (>2x slowrole median 1m)" "$tmp/slow.status" \
  || fail "slow running status: $(cat "$tmp/slow.status")"

for c in short1 short2; do
  printf '# Card %s\n' "$c" > ".orka/tasks/$c-short.md"
  mkdir -p ".orka/runs/$c-short/attempt-1"
  jq -n --arg card "$c-short" \
    '{card:$card,role:"shortrole",rc:0,stopped:false,timedOut:false,seconds:10}' \
    > ".orka/runs/$c-short/attempt-1/meta.json"
done
printf '# Card short running\n' > .orka/tasks/short-running.md
mkdir -p .orka/runs/short-running/attempt-1
echo "$$ $((now - 301)) shortrole" > .orka/runs/short-running/attempt-1/running
.orka/bin/orka status short-running > "$tmp/short.status"
grep -q "SLOW" "$tmp/short.status" && fail "status flagged a role with fewer than 3 finished attempts"

for c in zero1 zero2 zero3; do
  printf '# Card %s\n' "$c" > ".orka/tasks/$c-zero.md"
  mkdir -p ".orka/runs/$c-zero/attempt-1"
  jq -n --arg card "$c-zero" \
    '{card:$card,role:"zerorole",rc:0,stopped:false,timedOut:false,seconds:0}' \
    > ".orka/runs/$c-zero/attempt-1/meta.json"
done
printf '# Card zero running\n' > .orka/tasks/zero-running.md
mkdir -p .orka/runs/zero-running/attempt-1
echo "$$ $((now - 30)) zerorole" > .orka/runs/zero-running/attempt-1/running
.orka/bin/orka status zero-running > "$tmp/zero.status"
grep -q "SLOW" "$tmp/zero.status" && fail "status flagged a run shorter than 60 seconds"

printf '# Card slow pending\n' > .orka/tasks/slow-pending.md
mkdir -p .orka/runs/slow-pending/attempt-1
jq -n --argjson started "$((now - 301))" \
  '{card:"slow-pending",role:"slowrole",model:"native-test",started:$started}' \
  > .orka/runs/slow-pending/attempt-1/pending
.orka/bin/orka status slow-pending > "$tmp/slow-pending.status"
grep -q "subagent/native-test SLOW (>2x slowrole median 1m)" "$tmp/slow-pending.status" \
  || fail "slow pending status: $(cat "$tmp/slow-pending.status")"
rm -f .orka/runs/slow-running/attempt-1/running .orka/runs/short-running/attempt-1/running \
  .orka/runs/zero-running/attempt-1/running .orka/runs/slow-pending/attempt-1/pending
ok "status SLOW uses one role-median pass, requires 3 attempts, and ignores runs shorter than 60s"

printf '# Card budget config\n' > .orka/tasks/budget-config.md
printf '# Card budget env\n' > .orka/tasks/budget-env.md
printf '# Card budget explicit\n' > .orka/tasks/budget-explicit.md
printf '# Card budget native\n' > .orka/tasks/budget-native.md
printf '# Card budget clamp\n' > .orka/tasks/budget-clamp.md
printf '# Card budget minimal\n' > .orka/tasks/budget-minimal.md
jq '.budget = 2' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
.orka/bin/orka run budget-config senior > /dev/null 2> "$tmp/budget.err" || fail "config budget"
jq -e '.effort == "low"' .orka/runs/budget-config/attempt-1/meta.json > /dev/null \
  || fail "config budget effort"
grep -q "budget 2: senior effort high -> low" "$tmp/budget.err" || fail "budget notice"
ORKA_BUDGET=1 .orka/bin/orka run budget-env senior > /dev/null 2> "$tmp/budget-env.err" || fail "env budget"
jq -e '.effort == "medium"' .orka/runs/budget-env/attempt-1/meta.json > /dev/null \
  || fail "env budget did not override config"
ORKA_BUDGET=9 .orka/bin/orka run budget-clamp senior > /dev/null 2> "$tmp/budget-clamp.err" \
  || fail "large budget clamp"
jq -e '.effort == "low"' .orka/runs/budget-clamp/attempt-1/meta.json > /dev/null \
  || fail "large budget went below low"
jq '.team.minimal = {"cli":"fake","model":"minimal-model","effort":"minimal"}' \
  .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
ORKA_BUDGET=9 .orka/bin/orka run budget-minimal minimal > /dev/null 2>&1 || fail "minimal budget"
jq -e '.effort == "minimal"' .orka/runs/budget-minimal/attempt-1/meta.json > /dev/null \
  || fail "budget changed configured minimal effort"
.orka/bin/orka run budget-explicit fake explicit-model max > /dev/null 2>&1 || fail "explicit budget run"
jq -e '.effort == "max" and .role == "custom"' .orka/runs/budget-explicit/attempt-1/meta.json > /dev/null \
  || fail "budget changed explicit run"
jq '.budget = 1' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
.orka/bin/orka run budget-native native > /dev/null 2>&1 || fail "native budget prepare"
jq -e '.effort == "low"' .orka/runs/budget-native/attempt-1/pending > /dev/null \
  || fail "budget did not affect subagent preparation"
.orka/bin/orka finish budget-native --abandon > /dev/null || fail "clean budget native"
for bad in false '"2"' -1 1.5; do
  jq ".budget = $bad" .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
  ORKA_BUDGET=1 .orka/bin/orka run budget-config senior > /dev/null 2> "$tmp/budget-bad.err" \
    && fail "bad config budget $bad accepted while ORKA_BUDGET was set"
  grep -q "budget must be an integer >= 0" "$tmp/budget-bad.err" || fail "bad budget message"
done
ok "budget clamps high at low, preserves minimal, validates config, supports env override, and leaves explicit runs untouched"

printf '# Card fallback configured\n' > .orka/tasks/fallback-configured.md
printf '# Card fallback default\n' > .orka/tasks/fallback-default.md
printf '# Card fallback normal\n' > .orka/tasks/fallback-normal.md
printf '# Card fallback cancelled\n' > .orka/tasks/fallback-cancelled.md
jq '.budget = 0 | .team.senior.model = "bad-model" | .team.senior.fallbackModel = "good-model"' \
  .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
calls="$tmp/fallback-configured.calls"
ORKA_FAKE_BADMODEL=bad-model ORKA_FAKE_CALLS="$calls" \
  .orka/bin/orka run fallback-configured senior > /dev/null 2> "$tmp/fallback-configured.err" \
  || fail "configured model fallback"
[ "$(wc -l < "$calls" | tr -d ' ')" = 2 ] || fail "configured fallback did not run exactly twice"
fa=.orka/runs/fallback-configured/attempt-1
jq -e '.rc == 0 and .model == "good-model" and .modelFallback.from == "bad-model" and
       (.modelFallback.reason | test("not supported"; "i"))' "$fa/meta.json" > /dev/null \
  || fail "configured fallback meta: $(cat "$fa/meta.json")"
[ -s "$fa/err.first.txt" ] && grep -q "retrying with good-model" "$fa/fallback.txt" \
  || fail "configured fallback evidence"

jq 'del(.team.senior.fallbackModel)' .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
calls="$tmp/fallback-default.calls"
ORKA_FAKE_BADMODEL=bad-model ORKA_FAKE_CALLS="$calls" \
  .orka/bin/orka run fallback-default senior > /dev/null 2> "$tmp/fallback-default.err" \
  || fail "default model fallback"
[ "$(wc -l < "$calls" | tr -d ' ')" = 2 ] || fail "default fallback did not run exactly twice"
fa=.orka/runs/fallback-default/attempt-1
jq -e '.rc == 0 and .model == "" and .modelFallback.from == "bad-model"' "$fa/meta.json" > /dev/null \
  || fail "default fallback meta: $(cat "$fa/meta.json")"
grep -q "retrying with the CLI default" "$fa/fallback.txt" || fail "default fallback message"

jq '.team.senior.model = "working-model" | .team.senior.fallbackModel = "other-model"' \
  .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
calls="$tmp/fallback-normal.calls"
ORKA_FAKE_FAIL=1 ORKA_FAKE_CALLS="$calls" \
  .orka/bin/orka run fallback-normal senior > /dev/null 2> "$tmp/fallback-normal.err" \
  && fail "normal failure succeeded"
[ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || fail "normal failure retried"
[ ! -e .orka/runs/fallback-normal/attempt-1/fallback.txt ] || fail "normal failure recorded fallback"
ok "rejected models retry once with configured or CLI-default fallback; normal failures do not"

jq '.team.senior.model = "bad-model" | .team.senior.fallbackModel = "good-model"' \
  .orka/orka.json > "$tmp/j" && mv "$tmp/j" .orka/orka.json
calls="$tmp/fallback-cancelled.calls"
ORKA_FAKE_BADMODEL=bad-model ORKA_FAKE_BADMODEL_SLEEP=30 ORKA_FAKE_CALLS="$calls" \
  .orka/bin/orka run fallback-cancelled senior > /dev/null 2> "$tmp/fallback-cancelled.err" &
runner=$!
for _ in $(seq 1 50); do
  [ -s "$calls" ] && [ -f .orka/runs/fallback-cancelled/attempt-1/running ] && break
  sleep 0.1
done
[ -s "$calls" ] || fail "cancelled fallback adapter did not start"
kill -TERM "$runner"
wait "$runner"
[ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || fail "cancelled model rejection was retried"
fa=.orka/runs/fallback-cancelled/attempt-1
jq -e '.stopped == true and (has("modelFallback") | not)' "$fa/meta.json" > /dev/null \
  || fail "cancelled fallback meta: $(cat "$fa/meta.json")"
[ ! -e "$fa/fallback.txt" ] || fail "cancelled fallback evidence was recorded"
ok "cancelled or timed-out model rejections are not retried"

# Prune gets its own repository so the other smoke worktrees remain available.
prune_proj="$tmp/prune-app"
prune_wtdir="$tmp/prune-wt"
mkdir -p "$prune_proj" && git -C "$prune_proj" init -q -b main
git -C "$prune_proj" config user.email t@t
git -C "$prune_proj" config user.name t
echo prune > "$prune_proj/README.md"
printf '.env\nnode_modules/\n' > "$prune_proj/.gitignore"
git -C "$prune_proj" add README.md .gitignore && git -C "$prune_proj" commit -qm init
bash "$repo/skills/orka/scripts/init.sh" "$prune_proj" > /dev/null || fail "prune init"
printf '{"worktreeDir":"%s"}\n' "$prune_wtdir" > "$prune_proj/.orka/orka.json"
for kind in clean dry dirty unmerged running removefail afterfail; do
  git -C "$prune_proj" worktree add -q -b "orka/prune-$kind" "$prune_wtdir/$kind" HEAD \
    || fail "create prune $kind worktree"
done
mkdir -p "$prune_wtdir/clean/node_modules"
echo local > "$prune_wtdir/clean/.env"
echo package > "$prune_wtdir/clean/node_modules/package.txt"
echo dirty > "$prune_wtdir/dirty/untracked.txt"
echo unique > "$prune_wtdir/unmerged/unique.txt"
git -C "$prune_wtdir/unmerged" add unique.txt && git -C "$prune_wtdir/unmerged" commit -qm unmerged
mkdir -p "$prune_proj/.orka/runs/prune-running/attempt-1" "$prune_proj/.orka/runs/.locks"
echo "$$ $(date +%s) junior" > "$prune_proj/.orka/runs/prune-running/attempt-1/running"
running_path=$(cd "$prune_wtdir/running" && pwd -P)
printf '%s\n' "$running_path" > "$prune_proj/.orka/runs/prune-running/attempt-1/worktree"

"$prune_proj/.orka/bin/orka" prune --dry-run > "$tmp/prune-dry.out" || fail "prune dry run"
grep -q "would remove $prune_wtdir/dry" "$tmp/prune-dry.out" || fail "dry-run listing"
[ -d "$prune_wtdir/dry" ] && git -C "$prune_proj" show-ref --verify --quiet refs/heads/orka/prune-dry \
  || fail "dry-run changed a worktree or branch"
prune_bin="$tmp/prune-bin"
mkdir -p "$prune_bin"
real_git=$(command -v git)
cat > "$prune_bin/git" <<EOF
#!/bin/sh
if [ "\$1" = -C ] && [ "\$3" = worktree ] && [ "\$4" = remove ] &&
   [ "\$5" = "$prune_wtdir/removefail" ]; then
  echo "simulated worktree removal failure" >&2
  exit 1
fi
exec "$real_git" "\$@"
EOF
chmod +x "$prune_bin/git"
PATH="$prune_bin:$PATH" "$prune_proj/.orka/bin/orka" prune > "$tmp/prune.out" || fail "prune"
grep -q "removed $prune_wtdir/clean" "$tmp/prune.out" || fail "clean prune output: $(cat "$tmp/prune.out")"
grep -q "also deleted ignored:.*\\.env.*node_modules/" "$tmp/prune.out" \
  || fail "ignored paths not listed: $(cat "$tmp/prune.out")"
grep -q "kept $prune_wtdir/dirty: 1 uncommitted files" "$tmp/prune.out" || fail "dirty prune reason"
grep -q "kept $prune_wtdir/unmerged: not merged into" "$tmp/prune.out" || fail "unmerged prune reason"
grep -q "kept $prune_wtdir/running: in use by prune-running" "$tmp/prune.out" || fail "running prune reason"
grep -q "kept $prune_wtdir/removefail: simulated worktree removal failure" "$tmp/prune.out" \
  || fail "prune removal failure reason"
[ -d "$prune_wtdir/removefail" ] || fail "prune removed worktree after git refused"
[ ! -d "$prune_wtdir/afterfail" ] || fail "prune stopped after a removal failure"
[ ! -d "$prune_wtdir/clean" ] && ! git -C "$prune_proj" show-ref --verify --quiet refs/heads/orka/prune-clean \
  || fail "prune left clean worktree or branch"
grep -q "worktree disk before:" "$tmp/prune.out" && grep -q "freed: .* KB (.* MB)" "$tmp/prune.out" \
  || fail "prune disk summary"
ok "prune is inert in dry-run, lists ignored deletions, keeps live/dirty/unmerged work, and continues after git errors"

h="$tmp/home"
mkdir -p "$h/.agents/skills/orka" "$h/.agents/skills/orka.new" "$h/.agents/skills/orka.old" && echo mine > "$h/.agents/skills/orka/notes.txt"
HOME=$h bash "$repo/install.sh" > /dev/null 2>&1 && fail "installer replaced a directory it does not own"
[ -f "$h/.agents/skills/orka/notes.txt" ] || fail "installer deleted user files"
rm -rf "$h/.agents/skills/orka"
HOME=$h bash "$repo/install.sh" > /dev/null && HOME=$h bash "$repo/install.sh" > /dev/null || fail "install / re-install"
[ -d "$h/.agents/skills/orka.new" ] && [ -d "$h/.agents/skills/orka.old" ] || fail "installer removed sibling directories it did not create"
[ -f "$h/.agents/skills/orka/SKILL.md" ] && [ -L "$h/.claude/skills/orka" ] || fail "install layout"
ok "installer: owns only what it installed, re-install works"

[ "$(jq -r .version "$repo/.claude-plugin/plugin.json")" = "$(jq -r .version "$repo/.codex-plugin/plugin.json")" ] || fail "plugin manifest versions differ"
ok "manifest versions match"

echo "all smoke checks passed"
