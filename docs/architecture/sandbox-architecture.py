"""
Coding-Agent Sandbox — containment architecture (resource / deployment view).

Companion to the conceptual "CONTAIN, DON'T TRUST" diagram
(docs/architecture/security-architecture.{mmd,svg,png}). That one is the
editorial trust-boundary hero; this one is the resource-graph view in the same
Python-`diagrams` style (and pastel cluster palette) as the GCC CDE render,
showing the actual components and the three egress variants
(default tinyproxy · opt-in mitmproxy · sidecar).

Grounded in: docker-compose{,.mitm,.sidecar}.yml, Dockerfile{,.mitm},
entrypoint.sh, init-firewall.sh, tinyproxy.conf, mitm/filter_addon.py, shell.sh.

Prereqs:
    brew install graphviz
    pip install diagrams

Run:
    python3 sandbox-architecture.py     # writes sandbox-architecture.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.onprem.container import Docker
from diagrams.onprem.network import HAProxy, Internet
from diagrams.onprem.client import Client
from diagrams.onprem.vcs import Github
from diagrams.generic.network import Firewall, Switch
from diagrams.generic.storage import Storage
from diagrams.programming.language import NodeJS

GRAPH_ATTR = {"fontsize": "16", "bgcolor": "white", "pad": "0.5", "splines": "spline"}

# Pastel cluster palette — matches the GCC CDE render (diagrams default cycle).
BG_BLUE = "#E5F5FD"
BG_GREEN = "#EBF3E0"
BG_PURPLE = "#ECE8F6"
BG_YELLOW = "#FDF7E3"

ALLOW = "#16a34a"   # green — permitted
DENY = "#dc2626"    # red — dropped/denied
FLOW = "#1e293b"    # slate — primary data path

with Diagram(
    "Coding-Agent Sandbox — containment architecture  (default · mitm · sidecar)",
    filename="sandbox-architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    with Cluster("Your host machine", graph_attr={"bgcolor": BG_BLUE}):
        browser = Client("Browser → ttyd web terminal\n(127.0.0.1:7681 · password)")
        term = Client("Terminal / iTerm2\n(./shell.sh · docker compose exec)")
        proj = Storage("Chosen project tree(s)\n→ /workspace (e.g. work · personal)\nhost secrets stay out")
        secrets = Storage("NOT mounted — invisible:\n~/.ssh · ~/.aws · host home\nbrowser profiles")

        with Cluster("Docker sandbox — trust boundary  (default & mitm · gVisor opt-in: runtime runsc)",
                     graph_attr={"bgcolor": BG_GREEN}):
            agent = NodeJS("Agent — claude / codex\n(UNTRUSTED workload — the thing contained)\nunprivileged 'node' · cap_drop ALL\n(+NET_ADMIN/SETUID/SETGID/CHOWN/DAC_OVERRIDE)\nno-new-privileges · mem/PID limits")
            ws = Storage("/workspace (+ work · personal)\n+ named config/audit volumes")
            proxy = HAProxy("Allowlist proxy\ntinyproxy = hostname (default)\nmitmproxy = TLS + content (opt-in)")
            fw = Firewall("iptables — default-DROP\nONLY proxy UID may egress\nDNS · IPv6 · private · IMDS blocked")
            audit = Storage("Audit log (proxy-owned · tamper-resistant)\ntinyproxy: rotated · mitm decisions: appended")
            vault = Storage("Token vault (mitm/sidecar only)\nreal cred unreadable by agent;\nagent holds placeholder")

    with Cluster("Sidecar variant  (token isolation · experimental)", graph_attr={"bgcolor": BG_PURPLE}):
        net = Switch("internal Docker network\n(agent has NO internet route)")
        agent_c = Docker("agent container\nplaceholder cred (after claim-token;\nclaude-config shared)")
        egress_c = Docker("egress sidecar\nmitmproxy + vault + firewall")

    with Cluster("Internet", graph_attr={"bgcolor": BG_YELLOW}):
        allow = Github("Approved hosts (trust grants)\napi.anthropic.com · claude.ai/.com · npm\ngithub.com (default, removable) · + EXTRA_ALLOWED_DOMAINS")
        deny = Internet("Everything else — DENIED\ndirect IP · DNS · IPv6\nprivate / cloud-metadata")

    # ---- host → container (two equal entry points, same container/isolation;
    #      ./shell.sh --attach shares the 'claude' tmux session) ----
    browser >> Edge(label="web terminal", color=FLOW) >> agent
    term >> Edge(label="local terminal\n(same isolation)", color=FLOW) >> agent
    proj >> Edge(label="bind mount", style="dashed", color=FLOW) >> ws
    secrets >> Edge(label="not mounted", style="dotted", color="gray") >> agent

    # ---- the fail-closed egress chain ----
    agent >> Edge(label="every connection\n(HTTPS_PROXY)", color=FLOW) >> proxy
    agent >> Edge(label="bypass attempt\n(raw IP / DNS / metadata)", style="dotted", color=DENY) >> fw
    proxy >> Edge(label="allowed by hostname", color=ALLOW) >> fw
    proxy >> Edge(label="blocked hostname (403)", style="dotted", color=DENY) >> deny
    proxy >> Edge(label="decision log", style="dotted", color="gray") >> audit
    vault >> Edge(label="injects bearer per-request", style="dotted", color=FLOW) >> proxy
    fw >> Edge(label="only the proxy may exit", color=ALLOW) >> allow
    fw >> Edge(label="non-proxy traffic dropped", style="dotted", color=DENY) >> deny

    # ---- sidecar variant (two-container split) ----
    agent_c >> Edge(label="proxy :8888\n(internal DNS only)", color=FLOW) >> net
    net >> Edge(color=FLOW) >> egress_c
    egress_c >> Edge(label="allowlist egress", color=ALLOW) >> allow
