#!/usr/bin/env bash
# End-to-end run on a disposable destination instance:
#   reset the instance, convert a legacy snapshot, then prepare, import every
#   .csys and import the history, as the procedure does.
#
#   test/e2e.sh LEGACY.cslegacy
#
# Environment:
#   SG_WORK            work directory (default ~/snapshots_gen-work)
#   SG_DEPLOY          cosmoSys_deploy checkout (default $SG_WORK/deploy)
#   SG_INSTANCE_ENV    instance environment file (default $SG_WORK/instances/sgtest.env)
#   SG_CONTAINER       Redmine container of that instance (default sg_test-redmine-1)
#   SG_KEEP=1          do not reset the instance first
set -euo pipefail

legacy="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${SG_WORK:-$HOME/snapshots_gen-work}"
deploy="${SG_DEPLOY:-$work/deploy}"
env_file="${SG_INSTANCE_ENV:-$work/instances/sgtest.env}"
container="${SG_CONTAINER:-sg_test-redmine-1}"
out="$work/e2e/$(basename "$legacy" .cslegacy)"

step() { printf '\n== %s\n' "$*"; }

if [ "${SG_KEEP:-0}" != 1 ]; then
  step "reset destination instance"
  (cd "$deploy" && COSMOSYS_ENV_FILE="$env_file" sh scripts/compose.sh down -v </dev/null >/dev/null 2>&1 || true)
  (cd "$deploy" && COSMOSYS_ENV_FILE="$env_file" sh scripts/compose.sh up -d </dev/null >/dev/null 2>&1)
  for _ in $(seq 1 120); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null)" = healthy ] && break
    sleep 5
  done
fi

step "convert"
rm -rf "$out"
mkdir -p "$(dirname "$out")"
docker run --rm -u "$(id -u):$(id -g)" -v "$here:/repo:ro" -v "$(dirname "$legacy"):/in:ro" -v "$(dirname "$out"):/out" \
  sg-converter ruby /repo/converter/convert.rb "/in/$(basename "$legacy")" "/out/$(basename "$out")" </dev/null || true
ls "$out"

step "copy into the instance"
docker exec -u 0 "$container" rm -rf /tmp/sg
docker exec -u 0 "$container" mkdir -p /tmp/sg/pkg
docker cp "$here/exporter" "$container:/tmp/sg/exporter"
docker cp "$here/importer" "$container:/tmp/sg/importer"
for file in "$out"/*.csys "$out"/*.cshistory; do docker cp "$file" "$container:/tmp/sg/pkg/"; done
docker exec -u 0 "$container" chown -R redmine:redmine /tmp/sg

runner() {
  docker exec -u redmine "$container" bash -c "cd /usr/src/redmine && bundle exec rails runner /tmp/sg/importer/import.rb $*" </dev/null 2>&1 |
    grep -v ' INFO -- \| WARN -- '
}
history="/tmp/sg/pkg/$(basename "$(ls "$out"/*.cshistory)")"

step "prepare"
runner prepare "$history"
for package in "$out"/*.csys; do
  step "csys $(basename "$package")"
  runner csys "/tmp/sg/pkg/$(basename "$package")" confirm=yes
done
step "history"
runner history "$history" "${SG_HISTORY_OPTIONS:-}"
