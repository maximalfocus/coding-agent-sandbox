# certs/ — corporate / proxy root CAs (local only)

Drop your organisation's **root CA certificate(s)** here as PEM files named
`*.crt` if you run this sandbox behind a **TLS-inspecting proxy** — e.g.
**Cloudflare WARP / Zero Trust** or **Zscaler**. They are trusted at **build
time** (so `npm install`/`curl` in the `Dockerfile` succeed) and at **runtime**
(so `claude`, `codex`, and `git` trust the intercepted TLS).

```
certs/
  Cloudflare_CA.crt     # example: your WARP root CA
```

**SEED laptops — zero-touch:** instead of locating the cert by hand, run the
fetcher (it downloads the WARP CA, verifies it against a pinned SHA-256, and
writes `certs/Cloudflare_CA.crt`):

```bash
./certs/fetch-warp-ca.sh
./run.sh
```

Otherwise, drop the cert in manually and rebuild: `./run.sh` (or `docker compose build`).

- Files must be **PEM-encoded** and end in **`.crt`** (`update-ca-certificates`
  ignores other extensions). Convert a `.pem` with: `cp my-ca.pem my-ca.crt`.
- `*.crt` / `*.pem` here are **git-ignored** — never committed. The directory is
  kept by `.gitkeep`, and an empty `certs/` is a **no-op** (default builds are
  unchanged).
- Not sure where to get the cert, or on a WSL SEED laptop? See
  [`docs/wsl-warp.md`](../docs/wsl-warp.md).
