# Manual Setup & Login (macOS / Linux)

A single, linear runbook to set up the sandbox **and log Claude Code in**, by hand,
without an agent driving it. Follow top to bottom. Windows users: see the
`setup-windows.*` scripts and the README "Easiest Windows setup" section instead.

Everything below is run from the repo root (`cd` into this directory first).

---

## 0. Prerequisites

- **A Docker engine.** Any one of OrbStack (recommended on macOS), Docker Desktop,
  or Colima. If `docker` isn't installed, `./setup.sh` will offer to install OrbStack
  via Homebrew on macOS; on Linux install Docker Engine first.
- That's it. `git`, `claude`, `node`, `gh`, `codex` all live **inside** the container —
  you don't need them on the host.

### Verify the engine is actually reachable

```bash
docker info >/dev/null 2>&1 && echo "engine OK" || echo "engine NOT reachable"
```

> **Gotcha — multiple Docker contexts.** A machine that has had OrbStack, Docker
> Desktop, and/or Colima installed ends up with several `docker context`s, and the
> *active* one may point at a dead socket while another works fine. If the check above
> says "NOT reachable", find a live context and switch to it:
>
> ```bash
> for c in $(docker context ls --format '{{.Name}}'); do
>   docker --context "$c" info >/dev/null 2>&1 && echo "LIVE: $c" || echo "dead: $c"
> done
> docker context use <a-live-context>     # e.g. orbstack, colima, desktop-linux
> ```
>
> Then start the engine's app (OrbStack / Docker Desktop) if nothing is live, and
> re-run the verify. `./setup.sh` does this probe-and-switch automatically, but when
> setting up by hand you may need to do it yourself.

---

## 1. First-run setup

```bash
./setup.sh
```

What it does, in order:

1. Confirms a Docker engine is up (installs/starts OrbStack on macOS if missing).
2. Creates `.env` from `.env.example` and fills in:
   - `WORKSPACE_DIR` — leave blank (an inert umbrella volume); `personal` + `work`
     mount inside it.
   - `PERSONAL_DIR` → `/workspace/personal` — it **prompts**; default `~/personal`.
   - `WORK_DIR` → `/workspace/work` — it **prompts**; default `~/work`.
   - `TTYD_USER` = `coder`, `TTYD_PASS` = a freshly generated 20-char password.
     **Write the password down** — you log into the web terminal with it.
3. Builds the image, runs an advisory vulnerability scan (non-blocking), starts the
   container, and opens `http://127.0.0.1:7681`.

Accept the directory defaults by pressing Enter at each prompt unless you want other
host folders mounted.

> Non-interactive (accept all defaults): `printf '\n\n' | ./setup.sh`

Day-to-day after this first run, you only need `./run.sh` (rebuild + restart).

---

## 2. Log in to Claude Code

The login uses your **Claude subscription**, not an API key. Pick ONE of the two
paths below. Path A is simplest; Path B survives a full rebuild.

### Path A — interactive (simplest)

1. Open **http://127.0.0.1:7681** and log in with `coder` / the `TTYD_PASS` from `.env`.
2. In the terminal:
   ```
   claude
   /login
   ```
   Choose **"Claude account / subscription"**, open the URL it prints in your browser,
   approve, and paste the code back.

This writes credentials to the persisted `claude-config` volume, so it survives
container **restarts** — but a full image rebuild that recreates the volume means
logging in again. For rebuild-proof login, use Path B.

### Path B — headless token (persists across rebuilds)

1. Mint a long-lived (1-year) token. In the web terminal **or** via exec:
   ```bash
   docker exec -it claude-sandbox claude setup-token
   ```
   Open the URL it prints, approve in your browser, paste the returned `code#state`
   string back. It prints a token like `sk-ant-oat01-...`.
   **Copy it now — it is shown only once.**

2. Put that token in `.env` (this repo's `docker-compose.yml` already passes
   `CLAUDE_CODE_OAUTH_TOKEN` through to the container):
   ```
   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...your-token...
   ```

3. Recreate the container so it picks up the new env:
   ```bash
   ./run.sh        # or: docker compose up -d
   ```

Now every terminal you open is already authenticated — no `/login` needed, and it
survives rebuilds because the token lives in `.env`.

> If you only need it for the *current* container (not future `./run.sh` runs) and
> don't want to edit `.env`, you can instead pass it inline once:
> ```bash
> CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-... docker compose up -d
> ```

---

## 3. Verify it works

```bash
# Container is healthy and the web terminal is serving (401 = auth gate is up):
docker ps --filter name=claude-sandbox --format '{{.Names}} {{.Status}}'
curl -s -o /dev/null -w 'ttyd HTTP %{http_code}\n' http://127.0.0.1:7681/

# Tooling is present:
docker exec claude-sandbox bash -lc 'claude --version; which codex node git gh'

# Login works — a real inference round-trip (expect: LOGIN_OK):
docker exec -u node claude-sandbox bash -lc 'claude -p "Reply with exactly: LOGIN_OK"'

# Egress firewall: allowed host reachable, everything else blocked:
docker exec claude-sandbox bash -lc 'curl -s -o /dev/null -w "anthropic:%{http_code}\n" --max-time 10 https://api.anthropic.com/'
docker exec claude-sandbox bash -lc 'curl -s -o /dev/null -w "blocked-host:%{http_code}\n" --max-time 8 https://example.com/ || echo "example.com blocked (good)"'
```

Expected: container `Up ... (healthy)`, ttyd `HTTP 401`, a version + tool paths,
`LOGIN_OK`, `anthropic:` a real HTTP code (e.g. 404 on `/`), and `example.com`
returning `000`/blocked.

---

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker info` fails but an engine is installed | Wrong active context — see the §0 gotcha; `docker context use <live>`. |
| `./run.sh` says "Docker isn't running" | Start OrbStack / Docker Desktop, or switch to a live context, then retry. |
| `compose up` warns about **orphan containers** (`claude-sandbox-node`, `claude-sandbox-egress`) | Leftovers from the experimental sidecar variant. Remove: `docker rm -f claude-sandbox-node claude-sandbox-egress`. |
| `claude -p` → `401 Invalid bearer token` | The saved login is stale/expired. Re-do §2 (Path A `/login`, or mint a fresh Path B token). |
| Web terminal won't accept the password | It's the `TTYD_PASS` value in `.env`, user `coder`. The setup refuses default/placeholder passwords. |
| Logged in, but a fresh `./run.sh` logs you out | You used Path A or an inline token. Use Path B (token in `.env`) for rebuild-proof login. |

---

## 5. Day-to-day

```bash
./run.sh                      # rebuild + (re)start
docker compose logs -f        # follow logs
docker compose down           # stop
```

Open `http://127.0.0.1:7681`, log in as `coder`, run `claude`. Your `personal`/`work`
host folders are mounted at `/workspace/personal` and `/workspace/work`.
