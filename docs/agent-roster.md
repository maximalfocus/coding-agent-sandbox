# Bundled agent-CLI roster

The image installs a set of agent CLIs. Until now that set existed only as whatever the `Dockerfile`
happened to install, and each agent's *other* entries — an always-on egress host, a pin-acceptance
row, an entry in the host pin updater, a line in the bundled-CLI verifier, a paragraph in the README
— were scattered across nine files with nothing joining them.

That is fine while a roster only grows. It is not fine when one leaves. A removal that edits the
build but misses one of the other surfaces leaves an always-on allowlist entry for a tool that is no
longer installed: egress surface with nothing behind it, and no check that would notice. Deprecating
in place has the same shape — an alias or a retained grant for something the image does not ship.

So the roster is stated here, and [`../scripts/check-agent-roster.sh`](../scripts/check-agent-roster.sh)
derives it **from the image build** rather than from this file. Each agent's install in
[`../Dockerfile`](../Dockerfile) carries an `# agent-cli: <id>` marker; the check requires those
markers and the `shipped` rows below to name the same set, and then requires every other surface to
name no agent the roster does not.

## Running the check

```bash
scripts/check-agent-roster.sh          # human-readable
scripts/check-agent-roster.sh --json   # machine-readable
```

It reads no credential, makes no network call, and starts no container.

### What the three outcomes mean

| Outcome | Meaning |
|---|---|
| `PASS` | The surface names exactly the agents the roster does. |
| `MISSING` | A `shipped` agent has no entry on a surface it must appear on — its pin, its bundled-CLI check, its pin-acceptance row, its host-updater entry, or its documentation. |
| `RESIDUE` | A surface names an agent the roster does not ship — a pin, an always-on host, a pin-acceptance row, a host-updater entry, a verification invocation, or documentation presenting it as available. |

Both failures are an error exit. `RESIDUE` is the one this file exists for: it is what a removal
leaves behind when it edits the build and stops there.

### What is *not* checked here

The repository's account of its own history, and the check's own negative controls. `PROBLEM.md`
records a review that actually ran through the OpenCode fallback, and rewriting it to match the
current roster would be falsifying a record to satisfy a check. `scripts/test-check-agent-roster.sh`
reintroduces a retired agent one surface at a time, which is the only way to prove the check refuses
residue at all — a check that cannot be shown to fail is not evidence of anything.

Both exemptions are listed below by exact path with their reason stated, never as a glob or a hidden
constant, and each is covered by a case proving that removing it makes the same file fail.

## Machine-readable roster

Fields are `|`-separated; surrounding whitespace is ignored. Notes must not contain `|`.

- `id` — the name the host pin updater accepts, and the marker id in `Dockerfile`.
- `name` — the display name, which must appear in `README.md` for a shipped agent.
- `command` — the executable the image installs.
- `arg` — the `Dockerfile` `ARG` that pins it.
- `domains` — always-on first-party hosts it claims in every stack's `BASE_DOMAINS`, or `-` for none.
- `bundle-check` — the script that runs it from the built image, or `-`.
- `status` — `shipped` or `retired`.
- `note` — `-`, or free text. Required for a `retired` row.

A `retired` row keeps the tokens the agent used to hold, because those are what the residue scan
looks for. Recording a withdrawal is not the same as retaining a grant.

```agent-roster
# id | name | command | arg | domains | bundle-check | status | note
claude | Claude Code | claude | CLAUDE_CODE_VERSION | anthropic.com,claude.ai,claude.com | verify-npm-bundle.sh | shipped | -
codex | Codex | codex | CODEX_VERSION | - | verify-npm-bundle.sh | shipped | model and auth egress is gated by ALLOW_OPENAI, so it holds no always-on host
pi | Pi | pi | PI_VERSION | pi.dev | verify-npm-bundle.sh | shipped | -
herdr | Herdr | herdr | HERDR_VERSION | herdr.dev | - | shipped | not npm-published, so verify-npm-bundle.sh does not run it; its bytes are sha256-pinned per architecture
opencode | OpenCode | opencode | OPENCODE_VERSION | opencode.ai | - | retired | withdrawn 2026-09-02 with its pin, its always-on host in all three stacks, its pin-acceptance row, both host-updater entries, its bundled-CLI invocation, and its documentation
```

## Always-on hosts that belong to no agent

Every entry in a stack's `BASE_DOMAINS` must be claimed by a shipped agent above or listed here.
An unclaimed always-on host is exactly the residue this check refuses, so shared infrastructure is
named rather than tolerated.

```agent-roster-infrastructure
# domain | why it is always on
npmjs.org | npm registry and tarballs — shared by every npm-published agent, and by npm itself
npmjs.com | the same registry's other domain
```

## Files the residue scan does not read

```agent-roster-exempt
# path | why
PROBLEM.md | historical record of a review that ran through the OpenCode fallback
docs/agent-roster.md | this roster, which must be able to name what it withdrew
scripts/test-check-agent-roster.sh | the check's negative controls, which reintroduce a retired agent one surface at a time to prove the check refuses it
```
