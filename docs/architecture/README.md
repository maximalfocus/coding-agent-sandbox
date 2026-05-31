# Claude Code Sandbox — Security Architecture

One-page executive view of how we run the real Claude Code agent while **containing what it can
touch**. It mirrors the *environment layer* of Anthropic's
["How we contain Claude"](https://www.anthropic.com/engineering/how-we-contain-claude)
defense-in-depth model, and was independently peer-reviewed (cross-vendor) to convergence.

![Claude Code Sandbox security architecture](./security-architecture.png)

> Rendered image above (works everywhere). Source of truth: [`security-architecture.mmd`](./security-architecture.mmd).
> High-resolution vector: [`security-architecture.svg`](./security-architecture.svg).
> To edit: paste the `.mmd` into <https://mermaid.live> and re-export the PNG/SVG.

## The three controls that matter (read the diagram top → bottom)

1. **Containment** — the agent runs inside a Docker sandbox, as an unprivileged user, with Linux
   capabilities dropped, `no-new-privileges`, and memory/PID limits. A compromised or
   prompt-injected agent is confined to the box.
2. **Data minimization** — of *your machine*, the only thing mounted in is the **one project folder**
   you choose. SSH keys, cloud credentials, and the rest of your home are never mounted, so they are
   invisible to it. (Inside the box it can of course read the container's own OS files and its
   `~/.claude` config — which includes the login token; see *Honest boundary*.)
3. **Fail-closed egress** — all traffic is forced through an allowlist proxy that **decides allow/deny
   by hostname**, and a kernel firewall enforces that **only the proxy's own traffic may leave**
   (a service-account gate). The agent's direct DNS, IPv6, and private/cloud-metadata ranges are
   blocked, so it **cannot go around the proxy**. It can reach approved hosts (Anthropic/Claude, npm,
   GitHub by default, plus any extras you add) and no unapproved host — so it cannot beacon to an
   arbitrary server. (The default mode matches on the *requested hostname*; a shared-CDN host that
   also serves an approved domain could in principle be domain-fronted — the opt-in content-mediation
   mode closes that by checking the inner `Host`/TLS-SNI.)

The optional **content-mediation mode** goes a layer deeper: it terminates TLS to inspect the
traffic itself — GitHub read-only (clone yes, push no), blocks the Anthropic file-upload endpoint,
strips stray API keys (with an optional strict token pin), rejects any `Host`/TLS-SNI outside the
allowlist (no domain fronting), and writes a persisted request-decision log.

## Honest boundary (what it does *not* do)

- Your code **is** sent to Anthropic for inference — by design. This contains the blast radius on
  *your machine*; it does not make source private from the model provider.
- An allowlisted host is a *trust grant*: data could still leave via a host you explicitly approve
  (that is why GitHub is a deliberate, separable toggle and the allowlist is kept minimal).
- The subscription **login token is stored and readable inside the sandbox** (`~/.claude` config
  volume), so the agent can read its own credential — it is contained, not hidden from the model.
- It is a strong container boundary, not a full VM/hypervisor boundary (gVisor is a one-line opt-in
  if a kernel-escape boundary is required).

---

<details>
<summary>Mermaid source (for tools that render Mermaid inline)</summary>

```mermaid
flowchart TB
  subgraph HOST["🖥️ Developer machine (host)"]
    direction LR
    BROWSER["🌐 Browser → web terminal<br/>(127.0.0.1 only, password)"]
    PROJ["📁 One project folder"]
    SECRETS["🔑 SSH keys · cloud creds · browser profiles<br/>+ everything else on your machine"]
  end

  subgraph BOX["🛡️ Docker sandbox — trust boundary (contains the blast radius)"]
    direction TB
    AGENT["🤖 Claude Code CLI<br/>unprivileged 'node' user · capabilities dropped<br/>no-new-privileges · memory / PID limits"]
    WS["📂 /workspace<br/>= your project folder — the only part of<br/>your machine mounted in"]
    PROXY["🚦 Allowlist egress proxy — decides allow / deny by hostname<br/>Run ONE mode:<br/>Default: hostname filter (tinyproxy)<br/>Opt-in: TLS-intercept + content rules (mitmproxy)"]
    FW["🧱 Kernel firewall — FAIL-CLOSED<br/>only the proxy's traffic may exit (service-account gate)<br/>agent's direct DNS · IPv6 · private and cloud-metadata blocked"]
  end

  subgraph NET["🌐 Internet"]
    ALLOW(["✅ Approved hosts<br/>Anthropic / Claude · npm · GitHub (on by default, removable)<br/>+ approved extras"])
    BLOCK(["⛔ Unapproved hosts<br/>blocked (no direct path out)"])
  end

  BROWSER ==> AGENT
  PROJ <-->|bind mount| WS
  SECRETS -. "not mounted, invisible" .-> BOX
  AGENT --> WS
  AGENT ==>|every connection| PROXY
  PROXY ==>|allowed by hostname| FW
  PROXY -. "blocked by hostname (403)" .-> BLOCK
  FW ==>|only the proxy may exit| ALLOW
  FW -. "non-proxy traffic dropped" .-> BLOCK
  AGENT -. "bypass attempt (raw IP / DNS / metadata)" .-> FW

  RULES["🔍 Content-mediation mode (opt-in) adds:<br/>• GitHub read-only (clone yes, push no) · block file-upload endpoint<br/>• strip stray API keys (optional strict token pin)<br/>• reject Host / TLS-SNI outside the allowlist (no fronting)<br/>• every decision logged (persisted)"]
  PROXY -.-> RULES

  NOTE["⚠️ Honest boundary: your project content IS sent to Anthropic for inference (by design).<br/>Approved hosts are trust grants — keep the allowlist minimal. The login token is stored<br/>and readable inside the sandbox. Strong container isolation, not a full VM boundary.<br/>Default mode matches the requested hostname (a shared-CDN host could be domain-fronted);<br/>the opt-in TLS mode closes that by checking the inner Host / TLS-SNI."]
  ALLOW ~~~ NOTE

  classDef host fill:#eef2ff,stroke:#6366f1,color:#1e1b4b;
  classDef secret fill:#fef9c3,stroke:#ca8a04,color:#713f12;
  classDef boxn fill:#ecfdf5,stroke:#10b981,color:#064e3b;
  classDef allow fill:#dcfce7,stroke:#16a34a,color:#14532d;
  classDef block fill:#fee2e2,stroke:#dc2626,color:#7f1d1d;
  classDef notes fill:#f8fafc,stroke:#94a3b8,color:#0f172a;
  classDef warn fill:#fff7ed,stroke:#ea580c,color:#7c2d12;

  class BROWSER,PROJ host;
  class SECRETS secret;
  class AGENT,WS,PROXY,FW boxn;
  class ALLOW allow;
  class BLOCK block;
  class RULES notes;
  class NOTE warn;
```

</details>
