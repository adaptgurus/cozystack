#!/usr/bin/env bash
set +e

umask 077
error_file="$(mktemp /tmp/layersentry-dump-error.XXXXXX)" || exit 1
trap 'rm -f "$error_file"' EXIT

mysqldump \
  --defaults-extra-file=/etc/layersentry/db-backup/client.cnf \
  --single-transaction \
  --quick \
  --routines \
  --events \
  --triggers \
  --hex-blob \
  --no-tablespaces \
  --set-gtid-purged=OFF \
  --databases cloud cloud_usage \
  >/dev/null 2>"$error_file"
dump_rc=$?

printf 'DUMP_RC=%s\n' "$dump_rc"
sed -E \
  -e 's/([Pp]assword[^[:space:]]*)/[PASSWORD_REDACTED]/g' \
  -e 's/(IDENTIFIED[[:space:]]+BY[[:space:]]+).*/\1[REDACTED]/Ig' \
  "$error_file" | head -n 5

exit 0
