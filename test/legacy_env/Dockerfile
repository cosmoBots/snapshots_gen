# Old cosmoSys runtime for tests: the official Redmine 4.2.10 image plus the
# build tools that the old plugins' gems need. The application tree (Redmine,
# plugins and files) is mounted from a copy or from a synthetic instance.
FROM redmine:4.2.10-passenger
USER root
# Debian 11 left the main mirrors; its packages live on archive.debian.org.
RUN set -eux; \
    printf '%s\n' \
      'deb http://archive.debian.org/debian bullseye main' \
      'deb http://archive.debian.org/debian bullseye-updates main' \
      'deb http://archive.debian.org/debian-security bullseye-security main' \
      > /etc/apt/sources.list; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install -y --no-install-recommends build-essential default-libmysqlclient-dev \
      libxml2-dev libxslt1-dev zlib1g-dev pkg-config git graphviz default-mysql-client; \
    rm -rf /var/lib/apt/lists/*
