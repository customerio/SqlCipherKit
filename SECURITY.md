# Security Policy

## Supported Versions

Only the latest released version of SqlCipherKit receives security fixes.

| Version | Supported |
|---------|-----------|
| Latest  | ✅        |
| Older   | ❌        |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security issue in SqlCipherKit, please report it privately via GitHub's built-in [Security Advisories](../../security/advisories/new) feature (repository → **Security** tab → **Report a vulnerability**).

Include as much detail as possible:

- A description of the vulnerability and its potential impact.
- Steps to reproduce or a proof-of-concept.
- The version(s) affected.

You will receive an acknowledgment within **5 business days** and a resolution timeline once the issue is confirmed.

## Scope

SqlCipherKit is a Swift wrapper around the SQLCipher amalgamation. Vulnerabilities in the underlying **SQLCipher** or **OpenSSL** libraries should be reported upstream to [Zetetic](https://www.zetetic.net/sqlcipher/) and the OpenSSL project respectively.
