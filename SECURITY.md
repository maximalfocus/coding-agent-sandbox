# Security model & limits

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue or pull request. Use GitHub's
private vulnerability reporting: open the repository's **Security → Advisories → Report a
vulnerability** ([new advisory](https://github.com/maximalfocus/coding-agent-sandbox/security/advisories/new)).

Include what you found, how to reproduce it, and the impact. You'll get an acknowledgement and,
once a fix is available, coordinated disclosure. Because this is a containment tool, reports about
egress bypass, firewall/proxy evasion, privilege escalation inside the container, or credential
exposure are especially valued. Please don't include real secrets or tokens in your report.

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
- **Name-based, not content inspection — and exfiltration through an allowed host is possible.**
  The proxy filters on the requested hostname (the CONNECT target); it does **not** decrypt TLS or
  inspect payloads/paths. This is the gap Anthropic's containment write-up calls out as the hard
  one: an allowlisted domain is a *capability*, and "every function reachable through it is now
  attack surface." A prompt-injected agent can still move data out through any allowed host it can
  write to — push to a GitHub repo/gist (if `ALLOW_GITHUB` is on), POST to a permitted API, or
  encode bytes into request paths to an allowed domain. Hostname allowlisting stops *arbitrary*
  beaconing, not exfiltration via a sanctioned destination. Mitigations: keep the allowlist
  minimal, turn off `ALLOW_GITHUB` for untrusted work, and for real content-level mediation run a
  TLS-intercepting proxy (see *Hardening*). Name-only filtering can also be **domain-fronted** on
  shared-CDN infrastructure (the CONNECT host is allowlisted but the inner TLS SNI/Host differs) —
  another thing only a TLS-terminating proxy closes.
- **Workspace-local Claude config & hooks are executed (and they're inside the box).** Claude Code
  reads project-local settings and hooks (`.claude/settings.json`, hook commands) from the folder
  you mount. Anthropic's write-up flags "pre-trust execution" — config/hooks that ran before the
  user accepted a trust prompt — as a real vulnerability they had to fix. **Treat `WORKSPACE_DIR`
  as untrusted:** if it carries a malicious `.claude/`, a hook can run automatically the moment
  `claude` starts. The sandbox is exactly the right containment for this — the hook is confined to
  `/workspace` and the egress allowlist — but combined with the allowed-host exfil path above it's
  a live channel. Review a project's `.claude/` before pointing the sandbox at it, prefer
  `ALLOW_GITHUB=false` and a minimal allowlist for code you don't trust, and mount `:ro` if you
  only need analysis.
- **The agent can read its own subscription token.** The login lives in the `claude-config` volume
  at `/home/node/.claude`, owned by and readable as `node` — the same user Claude and its tools run
  as. Anthropic's sealed-VM design keeps credentials in the host keychain, *never entering the
  guest*; a subscription login inside a container can't fully match that. The token only authorizes
  *your own* account, but it is reachable by the agent and therefore leakable via an allowed host.
  This is an accepted trade-off of running a real logged-in CLI, not a defect — but don't treat the
  container as a place where the token is hidden from the model.
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
  of scope here; this is strong defense-in-depth, not a hypervisor boundary. If you need a stronger
  boundary, install gVisor and uncomment `runtime: runsc` in `docker-compose.yml` (see *Hardening*)
  — a user-space kernel of the same class Anthropic uses for claude.ai.
- **One layer, mostly.** This is an *environment-layer* containment (sandbox + egress + caps).
  Anthropic's write-up stresses that defenses should overlap: model-layer and tool-permission
  checks exist precisely because no single layer is 100%. The cheap complementary layer here is
  Claude Code's **own permission prompts** — running fully unattended (auto-approving every action)
  removes the one in-the-box check the environment layer can't provide. Keep a human in the loop
  for untrusted work; lean on full autonomy only when the workspace and task are trusted.
- **Build-time network is open.** The firewall applies at *runtime*. The image build (`npm i`,
  downloading ttyd) reaches the internet normally — review the `Dockerfile` if that matters to you.

## Hardening options

- Set a strong `TTYD_PASS`; consider an SSH tunnel instead of publishing the port if remote.
- Keep `EXTRA_ALLOWED_DOMAINS` as small as possible; treat every entry as a capability grant.
  Set `ALLOW_GITHUB=false` to drop GitHub egress for analysis-only or untrusted-workspace runs, and
  trim `BASE_DOMAINS` in `entrypoint.sh` if you don't need npm. Telemetry egress is off by default
  (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`); set that var empty in `.env` to re-enable it. That
  is also required for `/remote-control` (`/rc`), which is feature-flag-gated and so silently stays
  unavailable while nonessential traffic is disabled.
- The Claude CLI version is pinned and its **runtime auto-updater is disabled** (`DISABLE_AUTOUPDATER=1`),
  so the binary can't change mid-session. Bump `CLAUDE_CODE_VERSION` and rebuild to update it.
- Mount `WORKSPACE_DIR` read-only (`:ro` in `docker-compose.yml`) if you only want analysis, not edits.
- **Stronger kernel boundary:** install [gVisor](https://gvisor.dev/) and uncomment `runtime: runsc`
  in `docker-compose.yml`. It runs the container under a user-space kernel that intercepts syscalls,
  narrowing the "shares the host kernel" gap above — the battle-tested-primitive approach the
  containment write-up favors over rolling your own isolation.
- **Content-level egress mediation (shipped, opt-in):** the default proxy filters by hostname only,
  so it can't stop exfiltration through an *allowed* host or domain-fronting. A TLS-intercepting
  variant is included — `docker compose -f docker-compose.mitm.yml up -d --build` — that swaps
  `tinyproxy` for mitmproxy (`Dockerfile.mitm`, `mitm/`). Because it terminates TLS it enforces the
  write-up's "defensive proxy" pattern: per-method/path rules (GitHub read-only — clone yes, push
  no, via `GITHUB_READONLY`), Anthropic API hardening (block the Files API, strip `x-api-key`,
  optional token pin), `Authorization`/`Cookie`/`x-api-key` stripping to non-first-party hosts, and
  per-request logging (`audit.sh --mitm`). Authorization is keyed on the real routing host
  (`request.host`, not the spoofable `Host` header), CONNECT is gated to allowlisted hosts on port
  443, and raw-TCP passthrough is disabled — so host-spoofing and raw tunnels can't slip a
  non-allowlisted destination through. It's a prototype (rules in `mitm/filter_addon.py`, extend as
  needed) and heavier (a CA the in-container tools must trust), so it's opt-in, not default.
