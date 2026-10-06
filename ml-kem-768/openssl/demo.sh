#!/usr/bin/env bash
# ML-KEM-768 key exchange with OpenSSL 3.5+, in a throwaway directory (keys never land in the repo).
set -euo pipefail
openssl version
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"

openssl genpkey -algorithm ML-KEM-768 -out alice.key                                  # Alice: key pair
openssl pkey -in alice.key -pubout -out alice.pub                                     # Alice: share the public key
openssl pkeyutl -encap -pubin -inkey alice.pub -out ct.bin -secret bob.secret         # Bob: ciphertext + secret
openssl pkeyutl -decap -inkey alice.key -in ct.bin -secret alice.secret               # Alice: same secret back

wc -c ct.bin bob.secret
cmp bob.secret alice.secret && echo "same secret on both sides"
