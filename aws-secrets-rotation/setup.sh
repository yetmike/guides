#!/usr/bin/env bash
# One-time setup before recording. Needs AWS_PROFILE set and a Neon project.
#   ./setup.sh 'postgresql://neondb_owner:...@ep-xxx.aws.neon.tech/neondb?sslmode=require'   (owner URL from the Neon console)
#   ./setup.sh destroy <region>   removes the AWS side (drop the Neon project in its console)
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = destroy ]; then
  terraform -chdir=terraform destroy -auto-approve -var region="${2:?region}" -var db_host=x -var db_password=x
  exit
fi
owner_url=${1/-pooler./.}   # direct endpoint, not the pooler
host=$(python3 -c 'import sys, urllib.parse as u; print(u.urlparse(sys.argv[1]).hostname)' "$owner_url")
region=$(sed -E "s/.*\.([a-z]+-[a-z]+-[0-9]+)\.aws\.neon\.tech$/\1/" <<<"$host")   # ...<region>.aws.neon.tech: put AWS next to the database
pw=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')   # 32 chars, passes Neon's entropy check

# the app role, created with SQL so it can change its own password
psql "$owner_url" -v ON_ERROR_STOP=1 -q -c "DROP ROLE IF EXISTS app" -c "CREATE ROLE app WITH LOGIN PASSWORD '$pw'"

rm -rf lambda/build && pip install -q --target lambda/build pg8000==1.31.5 && cp lambda/rotate.py lambda/build/
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -var region="$region" -var db_host="$host" -var db_password="$pw"
echo "region: $region"
