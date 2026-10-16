# Security policy — SOBER-STT-8GB

## Model

The runner listens on loopback only (`127.0.0.1`) and additionally requires:

- a `Host` of `127.0.0.1` / `localhost` / `::1` (blocks DNS rebinding),
- no `Origin` header (a browser page always sends one),
- the per-boot token `X-SOBER-Token` (a custom header forces a CORS
  preflight, which a simple page request can't pass).

Request bodies are capped at 100 KB (413 above). The installer can pin
SHA-256 per download (`sha256` in `installer/downloads.json`, verified by
Inno Setup); empty means not pinned yet. The last WAV is deleted after every
dictation; the last transcript is kept only for debugging
(`"keepLastJson": false` disables it).

## Reporting

This is a personal project without a bounty program. Report vulnerabilities
via a private GitHub Security Advisory (preferred) or a public issue;
a one-line "I think X is reachable from a web page" is already useful.
