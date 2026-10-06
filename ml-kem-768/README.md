# ML-KEM-768: post-quantum key exchange

Companion to the video **Your Browser Already Uses Post-Quantum Crypto (ML-KEM Explained)**.
ML-KEM-768 is the key encapsulation mechanism standardised by NIST in FIPS 203 (August 2024).

## Check your own setup (OpenSSL 3.5+, OpenSSH 10+)

```bash
echo | openssl s_client -connect google.com:443 |& grep group   # Negotiated TLS1.3 group: X25519MLKEM768
ssh -Q kex | grep -E 'mlkem|sntrup'                               # what your SSH client supports
ssh -v git@github.com |& grep 'kex: algorithm'                    # what a server actually picks
```

Ubuntu 26.04 and Debian 13 ship OpenSSL 3.5 and OpenSSH 10. Older releases (Ubuntu 24.04, Debian 12) need an upgrade.

## Run the demos

| Folder | Run | Needs |
|---|---|---|
| [openssl/](openssl/) | `bash openssl/demo.sh` | OpenSSL 3.5+ |
| [go/](go/) | `cd go && go run .` | Go 1.24+ |
| [math/](math/) | `python3 math/mlkem768_math.py` | Python 3 |

The Go demo skips error checks so it fits on one screen in the video; handle errors in real code.
The Python file shows the math (t = A·s + e, compression, rounding the noise away) and is for learning only.

## Sizes (bytes)

| | Public key | Private key | Ciphertext | Shared secret |
|---|---|---|---|---|
| ML-KEM-512 | 800 | 1632 | 768 | 32 |
| ML-KEM-768 | 1184 | 2400 | 1088 | 32 |
| ML-KEM-1024 | 1568 | 3168 | 1568 | 32 |
| X25519 (for comparison) | 32 | 32 | n/a | 32 |

## Why hybrid

ML-KEM is new, so TLS (`X25519MLKEM768`) and OpenSSH (`mlkem768x25519-sha256`) combine it with X25519.
An attacker has to break both.

Source: [NIST FIPS 203](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.203.pdf)
