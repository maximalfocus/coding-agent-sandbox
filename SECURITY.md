# Security model & limits

## What this protects against

This sandbox contains the **blast radius on your own machine** if Claude Code (or a tool/agent
it runs, or a prompt-injection in some file or web page) does something you didn't intend:

- **Filesystem scope.** The container only mounts the one folder you point it at (`WORKSPACE_DIR`,
  or the current dir for `claude-safe`) as `/workspace`, plus its own config volume. Whatever you
  don't mount — the rest of your home, SSH keys, cloud credentials, browser profiles — is **not
  visible**. The launchers (`run.sh`/`run.ps1` and `claude-safe`) **refuse** to mount `/`, your home,
  or known credential dirs, so a typo can't widen the mount. (If you bypass them and mount a broad
  path yourself, that guarantee is only as good as the path you chose.)
- **Network egress lockdown, by hostname.** All outbound HTTP(S) is forced through an in-container
  allowlist proxy (`tinyproxy`) that permits only approved **domain names** (Anthropic, GitHub, npm,
  and any `EXTRA_ALLOWED_DOMAINS`) and refuses the rest with `403 Filtered`. A kernel `iptables`
  rule sets `OUTPUT` to **DROP** and allows internet egress **only for the proxy's user** — so any
  process that tries to skip the proxy and connect directly to an IP is dropped (fail-closed).
  Filtering by name (not IP) means it isn't fooled by shared CDN IPs or look-alike domains
  (`evil-anthropic.com` is refused), and it doesn't go stale when a CDN rotates IPs. The **IPv6**
  stack is locked to `DROP` too (no silent v6 bypass); **DNS** is allowed *only for the proxy user*
  (Claude/tools can't query the resolver directly, closing the DNS-tunnelling channel); and
  **private/internal ranges** (RFC1918, link-local incl. `169.254.169.254` metadata, CGNAT, the
  Docker host subnet) are rejected on egress **even for the proxy** — so an allowlisted hostname
  that resolves (or rebinds) to an internal IP can't be used for SSRF or lateral movement.
- **Not root.** Claude Code runs as the unprivileged `node` user; only the brief startup that
  installs firewall rules runs as root.
- **Localhost-only terminal.** The ttyd web terminal is published to `127.0.0.1` only and is
  password-protected, so it isn't reachable from your LAN.

## What this does NOT protect against — read this

- **Your code is still sent to Anthropic.** The whole point is to let Claude read/edit your
  files, and it does that by sending their contents to the model. This sandbox does **not** make
  your source private from Anthropic. Don't put secrets you wouldn't share into `WORKSPACE_DIR`.
- **Allowlisted destinations are trusted fully.** Egress to GitHub, npm, and your extra domains
  is open, and a parent domain allows **all** its subdomains (`github.com` ⇒ any `*.github.com`).
  Data *could* still leave via an allowlisted host (e.g. pushing to a GitHub repo you control).
  Keep `EXTRA_ALLOWED_DOMAINS` minimal.
- **Name-based, not content inspection.** The proxy filters on the requested hostname (the
  CONNECT target); it does **not** decrypt TLS or inspect payloads/paths. For per-path control or
  request logging you'd add a TLS-intercepting proxy (heavier; needs a CA cert in the container).
- **DNS is restricted to the proxy user** (queries to `127.0.0.11` from Claude/tools are dropped;
  only `tinyproxy` resolves). This closes the direct DNS-tunnelling channel. It is not a *hermetic*
  seal — the proxy still forwards lookups for allowlisted names daemon-side — but a non-proxy
  process can no longer smuggle data out in query names.
- **The `tinyproxy` UID is the egress trust anchor.** The firewall lets *any* process running as
  that UID reach the public internet unfiltered — the hostname allowlist is enforced by the
  tinyproxy daemon, not the kernel. So a compromise that executes code *as the tinyproxy user*
  would bypass the allowlist. Claude/tools run as `node` (a different UID); the tinyproxy account is
  a non-login system user. This is an accepted assumption, not a hole, but worth stating.
- **Proxy-only egress can break a tool that ignores `HTTPS_PROXY`.** This is fail-closed by design
  (such a tool is blocked, not leaking), but if something can't reach the network, check it honors
  the proxy env. git/npm must use HTTPS remotes — SSH egress (port 22) is not opened.
- **Anything inside `/workspace` is fair game.** Within the mounted folder, Claude can overwrite
  or delete files. There is no automatic backup. Use git and commit often; mount a throwaway
  copy if you're testing untrusted instructions. Note too that the bind mount can't distinguish
  ordinary project files from **hardlinks or secrets already copied under `WORKSPACE_DIR`** — if a
  file is reachable inside the mounted tree, it's readable. Don't keep credentials in the project.
- **Container isolation, not a VM.** Docker shares the host kernel. A kernel-level escape is out
  of scope here; this is strong defense-in-depth, not a hypervisor boundary.
- **Build-time network is open.** The firewall applies at *runtime*. The image build (`npm i`,
  downloading ttyd) reaches the internet normally — review the `Dockerfile` if that matters to you.

## Hardening options

- Set a strong `TTYD_PASS`; consider an SSH tunnel instead of publishing the port if remote.
- Keep `EXTRA_ALLOWED_DOMAINS` as small as possible; trim `BASE_DOMAINS` in `entrypoint.sh` if you
  don't need GitHub or npm. Telemetry egress is already off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`).
- The Claude CLI version is pinned and its **runtime auto-updater is disabled** (`DISABLE_AUTOUPDATER=1`),
  so the binary can't change mid-session. Bump `CLAUDE_CODE_VERSION` and rebuild to update it.
- Mount `WORKSPACE_DIR` read-only (`:ro` in `docker-compose.yml`) if you only want analysis, not edits.
- For per-path control or full request logging, swap `tinyproxy` for a TLS-intercepting proxy
  (e.g. mitmproxy) and trust its CA inside the container — heavier, but gives content-level mediation.
