# System design — host, WSL, container & the workspace mapping

How the pieces fit together on a Windows + WSL2 install, and **how your `personal` / `work`
project trees map into the sandbox**. For the egress/trust-boundary view, see
[`security-architecture`](./README.md).
This diagram describes the default, contained configuration; the host Docker override is outside
that boundary and is documented in [`SECURITY.md`](../../SECURITY.md).

```mermaid
flowchart TB
  subgraph WIN["🪟 Windows host — your laptop"]
    direction TB
    DEV["💻 You · VS Code · Explorer · git<br/>edit &amp; review the real files"]
    subgraph HOME["📁 C:/Users/you"]
      direction LR
      PERSONALH["👤 personal/<br/><i>personal projects</i>"]
      WORKH["💼 work/<br/><i>work projects</i>"]
      REPO["⚙️ coding-agent-sandbox/<br/><b>control plane — keep OUTSIDE personal/ &amp; work/</b><br/>.env · firewall · compose · CA · scripts"]
    end
    BROWSER["🌐 Browser → http://127.0.0.1:7681<br/>localhost only · password"]
  end

  subgraph WSL["🐧 WSL2 Ubuntu — Docker Engine + systemd"]
    direction TB
    subgraph BOX["🛡️ claude-sandbox container — trust boundary"]
      direction TB
      TTYD["🖥️ ttyd → Herdr<br/>unprivileged 'node' user"]
      subgraph WSP["📂 /workspace — the only host files the agent sees"]
        direction LR
        PERSONALC["/workspace/personal"]
        WORKC["/workspace/work"]
      end
      VOLS["🔒 sandbox-private volumes<br/>config · codex · gh · audit"]
      PROXY["🚦 tinyproxy allowlist<br/>🧱 fail-closed firewall"]
    end
  end

  NET(["🌐 Approved hosts only<br/>Anthropic · npm · GitHub · extras"])

  PERSONALH <==>|bind mount via /mnt/c| PERSONALC
  WORKH <==>|bind mount via /mnt/c| WORKC
  REPO -. "NOT mounted — invisible to the agent" .-> BOX

  DEV --- PERSONALH
  DEV --- WORKH
  DEV -.->|run.sh / setup-wsl.sh| REPO
  BROWSER ==> TTYD
  TTYD --> WSP
  TTYD ==>|every connection| PROXY
  PROXY ==>|allowed by hostname| NET

  classDef dev fill:#f1f5f9,stroke:#64748b,color:#0f172a;
  classDef repo fill:#fef9c3,stroke:#ca8a04,color:#713f12;
  classDef tree fill:#ede9fe,stroke:#7c3aed,color:#4c1d95;
  classDef box fill:#ecfdf5,stroke:#10b981,color:#064e3b;
  classDef vol fill:#fae8ff,stroke:#c026d3,color:#701a75;
  classDef net fill:#dcfce7,stroke:#16a34a,color:#14532d;

  class DEV,BROWSER dev;
  class PERSONALH,WORKH,PERSONALC,WORKC tree;
  class REPO repo;
  class TTYD,WSP,PROXY box;
  class VOLS vol;
  class NET net;
```

## How to read it

- **Two project trees, kept separate.** Your host `personal/` and `work/` folders bind-mount to
  `/workspace/personal` and `/workspace/work`. Inside one session the agent can work across both
  while they stay organised as distinct trees — and because they're **live bind mounts**, every
  change is the same file on the host: edit/inspect it in **VS Code**, review it with **git**, or
  open it in **Explorer** — no copy, no sync.
- **The sandbox repo is the control plane and stays OUTSIDE both trees.**
  `coding-agent-sandbox/` holds the things that *contain* the agent — `.env` (the web-terminal
  password and any `GITHUB_TOKEN`), the egress allowlist (`init-firewall.sh`, `tinyproxy.conf`),
  the `docker-compose.yml` capability drops, and the CA. The agent only ever sees `/workspace`, so
  if the repo lived inside `personal/` or `work/` the agent could **read those secrets and rewrite
  its own guard rails**. Keeping it outside means the machinery is invisible and unmodifiable from
  inside the box. (`run.sh` / `run.ps1` also refuse to mount `$HOME` or sensitive dirs for the same
  reason.)
- **Logins persist in sandbox-private named volumes** (`config`, `codex`, `gh`, `audit`) — not on
  your project trees — so they survive restarts without widening what the agent can read.
- **All egress is mediated**: the agent reaches only approved hosts through the hostname allowlist,
  behind a fail-closed kernel firewall.
