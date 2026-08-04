#!/usr/bin/env python3
"""
Generate a RabbitMQ-compatible salted SHA-256 password hash.

RabbitMQ's `rabbit_password_hashing_sha256` algorithm encodes a user's
password as:

    base64( salt[4] || sha256(salt || password) )

where salt is 4 random bytes. Paste the output into values.yaml as a
user's `passwordHash`.

Usage:
    bin/gen-hash.py <plaintext>
    echo -n <plaintext> | bin/gen-hash.py

Example:
    bin/gen-hash.py 'my-new-password'
"""
import base64
import hashlib
import os
import sys


def rabbit_hash(plaintext: str) -> str:
    salt = os.urandom(4)
    digest = hashlib.sha256(salt + plaintext.encode()).digest()
    return base64.b64encode(salt + digest).decode()


def main() -> int:
    if len(sys.argv) > 1:
        pw = sys.argv[1]
    elif not sys.stdin.isatty():
        pw = sys.stdin.read().rstrip("\n")
    else:
        print("usage: gen-hash.py <plaintext>", file=sys.stderr)
        return 1
    print(rabbit_hash(pw))
    return 0


if __name__ == "__main__":
    sys.exit(main())
