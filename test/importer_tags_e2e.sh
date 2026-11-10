#!/usr/bin/env bash
# End-to-end test of the tags importer on a disposable destination instance
# (PostgreSQL, with the "tags" option of the deploy): converts the synthetic
# snapshot of test/importer_tags_fixture.rb, imports it as the procedure does
# and compares what PostgreSQL holds, byte by byte, with what the fixture
# expects. It also checks the dry run, the second import and the refusals.
#
#   test/importer_tags_e2e.sh
#
# Environment:
#   SG_WORK            work directory (default ~/snapshots_gen-work)
#   SG_DEPLOY          cosmoSys_deploy checkout (default $SG_WORK/deploy)
#   SG_INSTANCE_ENV    instance environment file (default $SG_WORK/instances/sgtest.env)
#   SG_CONTAINER       Redmine container of that instance (default sg_test-redmine-1)
#   SG_DB_CONTAINER    its PostgreSQL container (default: the same project, -db-1)
#   SG_CONVERTER       converter image (default snapshots_gen-converter)
#   SG_KEEP=1          do not reset the instance first (it must be freshly created)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${SG_WORK:-$HOME/snapshots_gen-work}"
deploy="${SG_DEPLOY:-$work/deploy}"
env_file="${SG_INSTANCE_ENV:-$work/instances/sgtest.env}"
container="${SG_CONTAINER:-sg_test-redmine-1}"
database="${SG_DB_CONTAINER:-${container%-redmine-1}-db-1}"
image="${SG_CONVERTER:-snapshots_gen-converter}"
out="$work/e2e/importer-tags"
failures=0

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf 'ok: %s\n' "$*"; }

if [ "${SG_KEEP:-0}" != 1 ]; then
  step "reset destination instance"
  (cd "$deploy" && COSMOSYS_ENV_FILE="$env_file" sh scripts/compose.sh down -v </dev/null >/dev/null 2>&1 || true)
  (cd "$deploy" && COSMOSYS_ENV_FILE="$env_file" sh scripts/compose.sh up -d </dev/null >/dev/null 2>&1)
  for _ in $(seq 1 120); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null)" = healthy ] && break
    sleep 5
  done
fi

step "fixture and conversion"
rm -rf "$out"
mkdir -p "$out"
docker run --rm -u "$(id -u):$(id -g)" -v "$here:/repo:ro" -v "$out:/out" "$image" \
  bash -c 'ruby /repo/test/importer_tags_fixture.rb /out/fixture && ruby /repo/converter/convert.rb /out/fixture/legacy /out/converted' </dev/null
ls "$out/converted"

step "copy into the instance"
docker exec -u 0 "$container" rm -rf /tmp/sg
docker exec -u 0 "$container" mkdir -p /tmp/sg/pkg
for directory in exporter importer converter; do docker cp -q "$here/$directory" "$container:/tmp/sg/$directory"; done
for file in "$out"/converted/*.csys "$out"/converted/*.cshistory "$out"/converted/*.cstags; do docker cp -q "$file" "$container:/tmp/sg/pkg/"; done
docker exec -u 0 "$container" chown -R redmine:redmine /tmp/sg

# Runs the importer; its output, without the Rails log, goes to $out/<name>.log.
runner() {
  local name="$1"
  shift
  local status=0
  docker exec -u redmine -w /usr/src/redmine "$container" bundle exec rails runner /tmp/sg/importer/import.rb "$@" </dev/null >"$out/$name.raw" 2>&1 || status=$?
  grep -v -E ' (INFO|WARN) -- |^\s+from ' "$out/$name.raw" >"$out/$name.log" || true
  cat "$out/$name.log"
  return "$status"
}
expect_refusal() {
  local name="$1" message="$2"
  shift 2
  if runner "$name" "$@"; then
    fail "$name: the importer did not refuse"
  elif grep -q -- "$message" "$out/$name.log"; then
    pass "$name: refused ($message)"
  else
    fail "$name: refused without \"$message\""
  fi
}
psql() { docker exec -i "$database" psql -U "${POSTGRES_USER:-redmine}" -d "${POSTGRES_DB:-redmine}" -X -A -t -q "$@"; }
# Every row of the tag tables and of the plugin setting, as stored.
raw_state() {
  psql -c "COPY (SELECT * FROM additional_tags ORDER BY id) TO STDOUT" -c "COPY (SELECT * FROM additional_taggings ORDER BY id) TO STDOUT" \
    -c "COPY (SELECT id, value, updated_on FROM settings WHERE name = 'plugin_additional_tags') TO STDOUT"
}
# The destination in the shape of expected.tsv: names as hexadecimal bytes.
logical_state() {
  psql <<'SQL' | LC_ALL=C sort
\set ts 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
SELECT concat_ws(E'\t', 'tag', encode(convert_to(name, 'UTF8'), 'hex'), taggings_count, to_char(created_at, :'ts'), to_char(updated_at, :'ts'))
FROM additional_tags
UNION ALL
SELECT concat_ws(E'\t', 'tagging', g.taggable_type, p.identifier, encode(convert_to(i.subject, 'UTF8'), 'hex'),
                 encode(convert_to(t.name, 'UTF8'), 'hex'), COALESCE(to_char(g.created_at, :'ts'), 'NULL'))
FROM additional_taggings g JOIN additional_tags t ON t.id = g.tag_id
JOIN issues i ON g.taggable_type = 'Issue' AND i.id = g.taggable_id JOIN projects p ON p.id = i.project_id
UNION ALL
SELECT concat_ws(E'\t', 'tagging', g.taggable_type, p.identifier, encode(convert_to(w.title, 'UTF8'), 'hex'),
                 encode(convert_to(t.name, 'UTF8'), 'hex'), COALESCE(to_char(g.created_at, :'ts'), 'NULL'))
FROM additional_taggings g JOIN additional_tags t ON t.id = g.tag_id
JOIN wiki_pages w ON g.taggable_type = 'WikiPage' AND w.id = g.taggable_id JOIN wikis k ON k.id = w.wiki_id JOIN projects p ON p.id = k.project_id
UNION ALL
SELECT concat_ws(E'\t', 'tag_list', p.identifier, encode(convert_to(i.subject, 'UTF8'), 'hex'),
                 COALESCE(encode(convert_to(d.old_value, 'UTF8'), 'hex'), 'NULL'), COALESCE(encode(convert_to(d.value, 'UTF8'), 'hex'), 'NULL'))
FROM journal_details d JOIN journals j ON j.id = d.journal_id AND j.journalized_type = 'Issue'
JOIN issues i ON i.id = j.journalized_id JOIN projects p ON p.id = i.project_id
WHERE d.property = 'attr' AND d.prop_key = 'tag_list'
UNION ALL SELECT concat_ws(E'\t', 'count', 'tags', (SELECT COUNT(*) FROM additional_tags))
UNION ALL SELECT concat_ws(E'\t', 'count', 'taggings', (SELECT COUNT(*) FROM additional_taggings));
SQL
}
same() {
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3"; diff "$1" "$2" | head -20 || true; fi
}
history="/tmp/sg/pkg/$(basename "$out"/converted/*.cshistory)"
tags="/tmp/sg/pkg/$(basename "$out"/converted/*.cstags)"

step "prepare and .csys"
runner prepare prepare "$history"
for package in "$out"/converted/*.csys; do
  runner "csys-$(basename "$package" .csys)" csys "/tmp/sg/pkg/$(basename "$package")" confirm=yes
done
raw_state >"$out/state-empty.txt"

step "tags before the history: refused"
expect_refusal tags-before-history 'the history is not imported yet' tags "$tags"

step "history"
runner history history "$history"

step "tags without one of the .csys: refused"
first="$(basename "$(ls "$out"/converted/*.csys | head -1)")"
docker exec "$container" mv "/tmp/sg/pkg/$first" /tmp/sg/
expect_refusal tags-missing-csys 'not the ones this tags package was converted with' tags "$tags"
docker exec "$container" mv "/tmp/sg/$first" /tmp/sg/pkg/

step "tags, dry run"
runner tags-dry tags "$tags" dry_run=yes || fail "the dry run failed"
grep -q 'Dry run: everything was rolled back.' "$out/tags-dry.log" || fail "the dry run did not say it rolled back"
raw_state >"$out/state-dry.txt"
same "$out/state-empty.txt" "$out/state-dry.txt" "the dry run left the tag tables and the setting as they were"

step "tags"
runner tags-import tags "$tags" || fail "the import failed"
grep -q '^Tags imported.$' "$out/tags-import.log" || fail "the import did not say it imported"
grep -q 'lack the view_issue_tags permission.*: Reporter\.$' "$out/tags-import.log" || fail "the import did not warn about the role without view_issue_tags"
grep -q 'additional_tags 14/0/0' "$out/tags-import.log" || fail "the import did not write exactly 14 tags"
raw_state >"$out/state-first.txt"
logical_state >"$out/actual.tsv"
LC_ALL=C sort "$out/fixture/expected.tsv" >"$out/expected.tsv"
same "$out/expected.tsv" "$out/actual.tsv" "PostgreSQL holds exactly the tags, taggings, dates, counters and tag changes of the fixture ($(wc -l <"$out/expected.tsv") lines)"

step "tags, second time"
runner tags-again tags "$tags" || fail "the second import failed"
grep -q '^Nothing to import' "$out/tags-again.log" || fail "the second import did not say there was nothing to import"
raw_state >"$out/state-second.txt"
same "$out/state-first.txt" "$out/state-second.txt" "the second import changed no row, date or counter"

step "a tag that differs only in case from one of the package: refused"
psql -c "INSERT INTO additional_tags (name, taggings_count, created_at, updated_at) VALUES ('Lonely Tag', 0, now(), now())"
raw_state >"$out/state-conflict.txt"
expect_refusal tags-case-conflict 'differs only in case' tags "$tags"
raw_state >"$out/state-conflict-after.txt"
same "$out/state-conflict.txt" "$out/state-conflict-after.txt" "the refusal wrote nothing"
psql -c "DELETE FROM additional_tags WHERE name = 'Lonely Tag'"

step "a tagging that is not in the package on an item of the package: refused"
psql -c "INSERT INTO additional_taggings (tag_id, taggable_type, taggable_id, created_at)
         SELECT (SELECT id FROM additional_tags WHERE name = 'lonely tag'), 'Issue', id, now() FROM issues WHERE subject = 'Chapter'"
expect_refusal tags-extra-tagging 'which is not in the package' tags "$tags"
psql -c "DELETE FROM additional_taggings WHERE tag_id = (SELECT id FROM additional_tags WHERE name = 'lonely tag')"

step "a tagging removed by hand: imported again, and only that"
psql -c "DELETE FROM additional_taggings WHERE tag_id = (SELECT id FROM additional_tags WHERE name = 'A,B') AND taggable_type = 'WikiPage'"
runner tags-repair tags "$tags" || fail "the repair import failed"
grep -q 'Taggings: 2 created, 16 already there. Counters corrected: 0.' "$out/tags-repair.log" || fail "the repair did not create exactly the two missing taggings"
logical_state >"$out/actual-repaired.tsv"
same "$out/expected.tsv" "$out/actual-repaired.tsv" "after the repair PostgreSQL holds the fixture again"

step "a trigger on a tag table: refused before writing"
psql -c "CREATE FUNCTION sg_e2e_noop() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'" \
  -c "CREATE TRIGGER sg_e2e_noop BEFORE INSERT ON additional_tags FOR EACH ROW EXECUTE FUNCTION sg_e2e_noop()"
expect_refusal tags-trigger 'has 1 triggers this importer does not know' tags "$tags"
psql -c "DROP TRIGGER sg_e2e_noop ON additional_tags" -c "DROP FUNCTION sg_e2e_noop()"

step "a write of the import that changes another table: verification fails and everything is rolled back"
# The plugin setting is removed so that the import has to write it, and a
# trigger on settings (a table the preflight does not inspect) adds a watcher.
psql -c "DELETE FROM settings WHERE name = 'plugin_additional_tags'" \
  -c "DELETE FROM additional_taggings WHERE tag_id = (SELECT id FROM additional_tags WHERE name = 'A,B') AND taggable_type = 'WikiPage'" \
  -c "CREATE FUNCTION sg_e2e_side_effect() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN INSERT INTO watchers (watchable_type, watchable_id, user_id) VALUES (''Issue'', 0, 0); RETURN NEW; END'" \
  -c "CREATE TRIGGER sg_e2e_side_effect AFTER INSERT OR UPDATE ON settings FOR EACH ROW EXECUTE FUNCTION sg_e2e_side_effect()"
raw_state >"$out/state-side-effect.txt"
expect_refusal tags-side-effect 'verification failed, nothing was written' tags "$tags"
grep -q 'table watchers changed during the import' "$out/tags-side-effect.log" || fail "the verification did not name the table that changed"
grep -q 'the import wrote to watchers' "$out/tags-side-effect.log" || fail "the verification did not report the rows written elsewhere"
raw_state >"$out/state-side-effect-after.txt"
same "$out/state-side-effect.txt" "$out/state-side-effect-after.txt" "the failed verification left the tag tables and the setting as they were"
[ "$(psql -c "SELECT COUNT(*) FROM watchers WHERE watchable_id = 0")" = 0 ] && pass "the side effect was rolled back too" || fail "the side effect stayed"
psql -c "DROP TRIGGER sg_e2e_side_effect ON settings" -c "DROP FUNCTION sg_e2e_side_effect()"
runner tags-restore tags "$tags" || fail "the import after removing the trigger failed"
logical_state >"$out/actual-restored.tsv"
same "$out/expected.tsv" "$out/actual-restored.tsv" "without the trigger the import completes and PostgreSQL holds the fixture again"
[ "$(psql -c "SELECT COUNT(*) FROM settings WHERE name = 'plugin_additional_tags' AND value LIKE '%active_issue_tags: ''1''%'")" = 1 ] && pass "the source settings are stored again" || fail "the source settings are not stored"

step "result"
if [ "$failures" -eq 0 ]; then echo "PASSED"; else echo "FAILED ($failures)"; exit 1; fi
