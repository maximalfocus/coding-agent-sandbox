# Credential custody

Signing an agent in and choosing where its credential lives are two different things, and the
product used to state only the first. An operator could sign Codex in from the host, get a working
CLI, and never be told that the token it wrote is readable by every process running as the agent
user — which is the whole population an agent sandbox exists to contain.

This file states, for every bundled agent, **which custody tier holds its credential**, and each
host-side sign-in command reads its answer from here rather than restating it. An agent for which no
better tier is available says so; it is not omitted, because "no isolation" and "nobody wrote it
down" must not look the same.

## The three tiers

| Tier | Who can read the credential | Where it lives |
|---|---|---|
| `agent-readable` | any process running as the agent user, including a compromised or prompt-injected agent | a container volume mounted into the agent service |
| `proxy-vault` | the same-container proxy only; the agent holds an inert placeholder | a volume mounted into the egress service alone (`SL-08`/`SL-09`) |
| `sidecar-owned` | the egress sidecar only; the agent never sees the value | a volume mounted into the sidecar alone (`SL-12`) |

`none` is the fourth value and means the tool needs no credential at all.

**`agent-readable` is not a defect to be hidden.** It is the tier the shipped configuration puts
Claude, Codex, and `gh` in today, and for Codex it is the tier in force *because* `SL-13` is a
standing vendor `NO-GO`. Stating it plainly is this file's job; improving it is separate work with
its own acceptance.

## The sign-in commands

Every credential-requiring bundled tool has one host-run sign-in command in both supported host
shells, and they behave the same way:

- the stack is not running → refuse, naming that condition;
- the capability gate the tool's provider needs is off → refuse, naming the gate and where to set it;
- success → print where the credential persists and which tier holds it.

A refusal never enters the underlying flow, so an unmet condition arrives as a named condition
rather than as a transport error several steps later. None of these commands moves a credential
between tiers, weakens a tier, or grants egress. Moving the Claude token into the proxy vault is
[`scripts/auth/claim-token.*`](../scripts/auth/), a separate custody operation.

## Running the check

```bash
scripts/check-credential-custody.sh          # human-readable
scripts/check-credential-custody.sh --json   # machine-readable
```

It reads no credential, makes no network call, and starts no container. It proves the command set is
complete across both shells, that every rostered agent has a row here, and that each row's stated
tier is the tier the shipped Compose wiring actually implements — a credential volume mounted into
an agent service is `agent-readable` whatever this table claims.

| Outcome | Meaning |
|---|---|
| `PASS` | The row agrees with the shipped configuration and its commands exist in both shells. |
| `MISSING` | A rostered agent has no row, or a row's sign-in command is absent from a supported shell. |
| `MISMATCH` | The stated tier contradicts the Compose wiring, or a declared volume, path, or gate is not the one shipped. |

Both failures are an error exit.

## Machine-readable custody table

Fields are `|`-separated; surrounding whitespace is ignored. Notes must not contain `|`.

- `id` — the agent id, matching [`agent-roster.md`](agent-roster.md) for a rostered agent.
- `tool` — display name.
- `command` — the base name under `scripts/auth/`, present as both `.sh` and `.ps1`, or `-`.
- `gate` — `NAME:probe`, the capability variable that must be on and the string its grant leaves in
  the running allowlist, or `-` when the tool needs no gate.
- `volume` — the Compose volume holding the credential, or `-`.
- `path` — where it persists inside the container that owns it, or `-`.
- `tier` — `agent-readable`, `proxy-vault`, `sidecar-owned`, or `none`.
- `isolation` — `applied` (already in a non-agent-readable tier), `available` (a supported operation
  can move it there), `unavailable` (none exists today), or `na` (no credential).
- `note` — required on every row; it is where `unavailable` has to say why.

```credential-custody
# id | tool | command | gate | volume | path | tier | isolation | note
claude | Claude Code | claude-login | - | claude-config | /home/node/.claude | agent-readable | available | the mitm and sidecar stacks can move this token into the proxy-owned vault afterwards with scripts/auth/claim-token.*; until that runs, any process running as the agent user can read it
codex | Codex | codex-login | ALLOW_OPENAI:openai | claude-codex | /home/node/.codex/auth.json | agent-readable | unavailable | no isolation exists at the pinned Codex version: SL-13 is a standing vendor NO-GO recorded in docs/codex-subscription-broker-feasibility.md, so this is the tier in force rather than an oversight
pi | Pi | deepseek-key | ALLOW_DEEPSEEK:- | deepseek-secret | /var/lib/sandbox/deepseek/api-key | sidecar-owned | applied | the key is mounted only into the sidecar; Pi receives an inert placeholder and the agent container never holds a usable value (CAS-R110-CAS-R113)
herdr | Herdr | - | - | - | - | none | na | Herdr multiplexes panes and holds no provider identity, so there is no credential to place in a tier
gh | GitHub CLI | gh-login | ALLOW_GITHUB:github | claude-gh | /home/node/.config/gh | agent-readable | unavailable | not an agent, but a bundled tool that holds a credential; its token carries the workflow scope, so any process running as the agent user can push workflow files with it

```

## Services the check treats as the agent boundary

A volume mounted into any of these is readable by the agent user; a credential volume mounted only
elsewhere is not.

```credential-custody-agent-services
# compose file | service | why
docker-compose.yml | claude-sandbox | the default stack's agent container
docker-compose.sidecar.yml | claude-sandbox-node | the sidecar stack's agent container, which has no egress route
```
