#!/usr/bin/env bash
# capture.sh <name> [VAR=value ...] -- <claude args...>
# Runs Claude Code behind mitmproxy, with an empty environment and a throwaway config folder.
# Every request is redacted (redact.py) and saved to $LAB/flows/<name>.jsonl (LAB defaults to the current folder).
set -e
H=$(cd "$(dirname "$0")" && pwd); LAB=${LAB:-$PWD}   # lab folder: flows/, home/ (throwaway config), mitm/ (CA)
name=$1; shift; vars=()
while [ "$1" != "--" ]; do vars+=("$1"); shift; done; shift
mkdir -p "$LAB/flows" "$LAB/home"
uvx --from mitmproxy mitmdump -q -p 18080 --set confdir="$LAB/mitm" \
  -s "$H/redact.py" --set out="$LAB/flows/$name" &
proxy=$!; trap 'kill $proxy' EXIT
until (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null; do sleep 0.2; done
env -i HOME="$LAB/home" CLAUDE_CONFIG_DIR="$LAB/home/.claude" PATH="$PATH" TERM="$TERM" \
  HTTPS_PROXY=http://127.0.0.1:18080 HTTP_PROXY=http://127.0.0.1:18080 \
  NODE_EXTRA_CA_CERTS="$LAB/mitm/mitmproxy-ca-cert.pem" \
  "${vars[@]}" claude "$@" </dev/null
sleep 3   # background requests (telemetry) finish after the answer
