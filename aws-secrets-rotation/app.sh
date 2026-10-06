#!/usr/bin/env bash
# The "app": logs in to Postgres every second with the password from Secrets Manager.
# It keeps the secret in memory like a real app. Login failed? Read the secret again.
read_secret() { aws secretsmanager get-secret-value --secret-id rotation-demo/app-db --query SecretString --output text; }
s=$(read_secret)
while true; do
  if PGPASSWORD=$(jq -r .password <<<"$s") psql "host=$(jq -r .host <<<"$s") user=app dbname=neondb sslmode=require" -tAc 'select 1' >/dev/null 2>&1; then
    echo "$(date +%T) ok"
  else
    echo "$(date +%T) login FAILED, reading the secret again"
    s=$(read_secret)
  fi
  sleep 1
done
