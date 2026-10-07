#!/bin/sh
# Runs on the private test server: print time + public IP every second.
while true; do
  echo "$(date +%T) $(curl -s -m 2 https://checkip.amazonaws.com || echo '---')"
  sleep 1
done
