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
2. **Data minimization** — it can see exactly **one folder** you choose. SSH keys, cloud
   credentials, and the rest of the machine are never mounted, so they are invisible to it.
3. **Fail-closed egress** — all network traffic is forced through an allowlist proxy, and a kernel
   firewall ensures **nothing can go around it** (direct IPs, DNS, IPv6, and cloud-metadata are
   dropped). The agent can reach approved hosts (Anthropic, npm, optionally GitHub) and **nothing
   else** — so it cannot beacon out or exfiltrate to an arbitrary server.

The optional **content-mediation mode** goes a layer deeper: it terminates TLS to inspect the
traffic itself (GitHub read-only, blocks the Anthropic file-upload endpoint, pins the credential,
defeats Host/SNI spoofing) and writes a full audit log.

## Honest boundary (what it does *not* do)

- Your code **is** sent to Anthropic for inference — by design. This contains the blast radius on
  *your machine*; it does not make source private from the model provider.
- An allowlisted host is a *trust grant*: data could still leave via a host you explicitly approve
  (that is why GitHub is a deliberate, separable toggle and the allowlist is kept minimal).
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
    WS["📂 /workspace<br/>= your project folder — the ONLY files it can see"]
    PROXY["🚦 Allowlist egress proxy<br/>Default: filter by hostname (tinyproxy)<br/>Opt-in: TLS-intercept + content rules (mitmproxy)"]
    FW["🧱 Kernel firewall — FAIL-CLOSED<br/>only the proxy may reach the internet<br/>DNS · IPv6 · private and cloud-metadata ranges dropped"]
  end

  subgraph NET["🌐 Internet"]
    ALLOW(["✅ Approved hosts only<br/>Anthropic · npm · GitHub (optional)"])
    BLOCK(["⛔ Anything else<br/>exfiltration / beaconing blocked"])
  end

  BROWSER ==> AGENT
  PROJ <-->|bind mount| WS
  SECRETS -. "not mounted, invisible" .-> BOX
  AGENT --> WS
  AGENT ==>|every connection forced through the proxy| PROXY
  PROXY ==> FW
  FW ==>|approved| ALLOW
  FW -. dropped .-> BLOCK
  AGENT -. "bypass attempt (raw IP / DNS / metadata)" .-> FW

  RULES["🔍 Content-mediation mode adds:<br/>• GitHub read-only (clone yes, push no)<br/>• block Anthropic file-upload endpoint<br/>• pin to your credential, strip stray API keys<br/>• Host + TLS-SNI must match allowlist (no fronting)<br/>• every request logged to an audit trail"]
  PROXY -.-> RULES

  classDef host fill:#eef2ff,stroke:#6366f1,color:#1e1b4b;
  classDef secret fill:#fef9c3,stroke:#ca8a04,color:#713f12;
  classDef boxn fill:#ecfdf5,stroke:#10b981,color:#064e3b;
  classDef allow fill:#dcfce7,stroke:#16a34a,color:#14532d;
  classDef block fill:#fee2e2,stroke:#dc2626,color:#7f1d1d;
  classDef notes fill:#f8fafc,stroke:#94a3b8,color:#0f172a;

  class BROWSER,PROJ host;
  class SECRETS secret;
  class AGENT,WS,PROXY,FW boxn;
  class ALLOW allow;
  class BLOCK block;
  class RULES notes;
```

</details>
