#!/usr/bin/env bash
# Disposable old cosmoSys environments for tests: MySQL 5.7 and Redmine 4.2.10
# running a copied or synthetic application tree.
#
#   legacy-env.sh image                    build the runtime image
#   legacy-env.sh db                       start MySQL 5.7
#   legacy-env.sh restore NAME DUMP.sql.gz load a dump into database csys_NAME
#   legacy-env.sh create NAME              create an empty database csys_NAME
#   legacy-env.sh init NAME                migrate a fresh csys_NAME like the old entrypoint
#   legacy-env.sh dump NAME FILE.sql.gz    dump database csys_NAME
#   legacy-env.sh drop NAME                drop database csys_NAME
#   legacy-env.sh bundle NAME              install the gems of instance NAME
#   legacy-env.sh run NAME COMMAND...      run a command in instance NAME
#   legacy-env.sh runner NAME SCRIPT ARGS  rails runner in instance NAME
#   legacy-env.sh sql NAME 'SQL'           query database csys_NAME
#   legacy-env.sh down                     remove containers (volumes stay)
#
# Instances live in $SG_WORK/legacy/NAME/app (the Redmine tree with plugins).
set -euo pipefail

SG_WORK="${SG_WORK:-$HOME/snapshots_gen-work}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image=sg-legacy-redmine:4.2.10
network=sg-legacy
mysql=sg-legacy-mysql
secret="$SG_WORK/legacy/mysql-root-password"

password() {
  if [ ! -f "$secret" ]; then
    mkdir -p "$(dirname "$secret")"
    (umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$secret")
  fi
  cat "$secret"
}

mysql_exec() {
  docker exec -i -e MYSQL_PWD="$(password)" "$mysql" mysql -uroot --default-character-set=utf8mb4 "$@"
}

app_dir() {
  local dir="$SG_WORK/legacy/$1/app"
  [ -d "$dir" ] || { echo "no application tree at $dir" >&2; exit 1; }
  echo "$dir"
}

write_database_yml() {
  local dir; dir="$(app_dir "$1")"
  cat > "$dir/config/database.yml" <<YAML
production:
  adapter: mysql2
  database: csys_$1
  host: $mysql
  username: root
  password: "$(password)"
  encoding: utf8
YAML
  chmod 600 "$dir/config/database.yml"
}

run_in() {
  local name="$1"; shift
  local dir; dir="$(app_dir "$name")"
  # The image declares files/ as a volume; bind it so attachments stay in the tree.
  mkdir -p "$dir/files"
  write_database_yml "$name"
  docker run --rm -i --network "$network" \
    -v "$dir:/usr/src/redmine" -v "$dir/files:/usr/src/redmine/files" \
    -v sg-legacy-bundle:/usr/local/bundle \
    -v "$SG_WORK:/work" -w /usr/src/redmine -e RAILS_ENV=production \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    "$image" "$@"
}

case "${1:-}" in
  image)
    docker build -q -t "$image" "$here"
    ;;
  db)
    docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
    if ! docker inspect "$mysql" >/dev/null 2>&1; then
      docker run -d --name "$mysql" --network "$network" -v sg-legacy-mysql-data:/var/lib/mysql \
        -e MYSQL_ROOT_PASSWORD="$(password)" mysql:5.7.44 \
        --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null
    fi
    for _ in $(seq 1 60); do
      if mysql_exec -N -e 'SELECT 1' >/dev/null 2>&1; then echo "MySQL ready"; exit 0; fi
      sleep 2
    done
    echo "MySQL did not start" >&2; exit 1
    ;;
  create)
    mysql_exec -e "CREATE DATABASE IF NOT EXISTS csys_$2 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    ;;
  restore)
    mysql_exec -e "CREATE DATABASE csys_$2 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    gunzip -c "$3" | mysql_exec "csys_$2"
    ;;
  sql)
    mysql_exec "csys_$2" -e "$3"
    ;;
  drop)
    mysql_exec -e "DROP DATABASE IF EXISTS csys_$2"
    ;;
  dump)
    docker exec -e MYSQL_PWD="$(password)" "$mysql" mysqldump -uroot --single-transaction \
      --default-character-set=utf8mb4 --hex-blob "csys_$2" | gzip > "$3"
    ;;
  init)
    # Like the old entrypoint: core first with the plugins aside (some plugins
    # read tables at boot), then each plugin in dependency order.
    dir="$(app_dir "$2")"
    stash="$SG_WORK/legacy/$2/stash"
    mkdir -p "$stash"
    mv "$dir"/plugins/* "$stash"/
    "$0" create "$2"
    run_in "$2" bash -c 'bundle exec rake db:migrate >/dev/null && REDMINE_LANG=en bundle exec rake redmine:load_default_data >/dev/null' </dev/null || {
      mv "$stash"/* "$dir"/plugins/; exit 1; }
    mv "$stash"/* "$dir"/plugins/
    run_in "$2" bash -c 'bundle install --quiet >/dev/null && for p in computed_custom_field additionals additional_tags cosmosys cosmosys_req cosmosys_git cosmosys_req_poris; do [ -d plugins/$p ] && bundle exec rake redmine:plugins:migrate NAME=$p >/dev/null; done; bundle exec rake redmine:plugins:migrate >/dev/null && echo migrated' </dev/null
    ;;
  bundle)
    # Seed the shared gem volume from the image, then add each plugin's gems.
    run_in "$2" bash -c 'bundle config set --local without "development test" >/dev/null && bundle install --quiet && bundle list | wc -l'
    ;;
  run)
    name="$2"; shift 2
    run_in "$name" "$@"
    ;;
  runner)
    name="$2"; script="$3"; shift 3
    run_in "$name" bundle exec rails runner -e production "$script" "$@"
    ;;
  down)
    docker rm -f "$mysql" >/dev/null 2>&1 || true
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2
    ;;
esac
