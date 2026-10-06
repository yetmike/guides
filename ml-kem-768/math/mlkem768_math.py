#!/usr/bin/env python3
"""The math inside ML-KEM-768, in plain Python: one K-PKE run with the real parameters
(FIPS 203: n=256, k=3, q=3329, eta=2, du=10, dv=4), including ciphertext compression.
For learning only: no NTT, no SHAKE sampling, not constant time. Use a real library (Go crypto/mlkem, OpenSSL) for anything real.
Run: python3 mlkem768_math.py"""
import random
n, k, q, eta, du, dv = 256, 3, 3329, 2, 10, 4
rnd = random.Random(203)

def mul(a, b):                                   # a*b in Z_q[X]/(X^256+1), schoolbook
    r = [0] * n
    for i, x in enumerate(a):
        if x:
            for j, y in enumerate(b):
                if i + j < n: r[i + j] += x * y
                else: r[i + j - n] -= x * y
    return [c % q for c in r]
add = lambda a, b: [(x + y) % q for x, y in zip(a, b)]
sub = lambda a, b: [(x - y) % q for x, y in zip(a, b)]
cbd = lambda: [sum(rnd.getrandbits(1) for _ in range(eta)) - sum(rnd.getrandbits(1) for _ in range(eta)) for _ in range(n)]
uni = lambda: [rnd.randrange(q) for _ in range(n)]
comp = lambda p, d: [round((2 ** d / q) * x) % 2 ** d for x in p]
decomp = lambda p, d: [round((q / 2 ** d) * y) for y in p]
dot = lambda xs, ys: [sum(c) % q for c in zip(*[mul(x, y) for x, y in zip(xs, ys)])]
centered = lambda p: [x - q if x > q // 2 else x for x in p]

# KeyGen: t = A*s + e
A = [[uni() for _ in range(k)] for _ in range(k)]
s, e = [cbd() for _ in range(k)], [cbd() for _ in range(k)]
t = [add(dot(A[i], s), e[i]) for i in range(k)]

# Encrypt: u = A^T*r + e1, v = t^T*r + e2 + m*(q+1)/2, then compress
m = [rnd.getrandbits(1) for _ in range(n)]
r, e1, e2 = [cbd() for _ in range(k)], [cbd() for _ in range(k)], cbd()
AT = [[A[j][i] for j in range(k)] for i in range(k)]
u = [add(dot(AT[i], r), e1[i]) for i in range(k)]
mu = [b * ((q + 1) // 2) for b in m]
v = add(add(dot(t, r), e2), mu)
cu, cv = [comp(p, du) for p in u], comp(v, dv)
ct_bytes = k * n * du // 8 + n * dv // 8

# Decrypt: w = v' - s^T*u', round each coefficient to 0 or q/2
u2, v2 = [decomp(p, du) for p in cu], decomp(cv, dv)
w = sub(v2, dot(s, u2))
m2 = comp(w, 1)
assert m2 == m and ct_bytes == 1088, 'decryption failed'
noise = [min(x, q - x) if b == 0 else abs(x - (q + 1) // 2) for x, b in zip(w, m)]

print("t = A*s + e      first coefficients of t[0]:", t[0][:4])
print("message bits     first 16:", m[:16])
print("w = v - s*u      first 8 (near 0 -> bit 0, near 1665 -> bit 1):", w[:8])
print(f"recovered 256/256 bits, worst noise {max(noise)} (rounding forgives up to {q // 4}), ciphertext {ct_bytes} bytes")
