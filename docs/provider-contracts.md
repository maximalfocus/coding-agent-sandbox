# Provider contract inventory and drift detection

Every credential path in this sandbox depends on something this project does not control: an
authentication endpoint, a grant shape, a client identifier, an injection destination and its header
contract, or a credential file whose schema is written by somebody else's CLI. None of those can be
checksummed the way a downloaded binary can, and any of them can change server-side without notice.

This file is the one place those dependencies are recorded. `scripts/check-provider-contracts.sh`
reads the machine-readable block at the bottom and reports, per dependency, whether the pin still
agrees with this repository, whether it is known to have drifted, or whether confirming it would
require something this environment does not have.

Recording a dependency here does **not** guarantee it keeps working. `PRD §7` is explicit that a
provider may change a contract at any time; the requirement is that such a change is pinned against,
detected, and fails closed — not that it cannot happen.

## Running the check

```bash
scripts/check-provider-contracts.sh          # human-readable table
scripts/check-provider-contracts.sh --json   # machine-readable
```

It reads only files in this repository. It makes no network connection, needs no credential and no
provider subscription, and prints no credential material.

**Exit status:** `0` when nothing recorded here is contradicted, `1` when at least one dependency has
drifted. A non-zero exit is not a broken repository — it is the check doing its job, and it means a
capability that depends on that contract is currently unavailable.

### What the three outcomes mean

| Outcome | Meaning |
|---|---|
| `PASS` | The pin recorded here is still present where this file says it lives, and nothing beyond this repository is needed to confirm it. |
| `DRIFTED` | Either the pinned literal is gone from the file that is supposed to hold it, or the value is recorded below as one the provider has stopped accepting. Fail-closed: this is an error exit. |
| `UNEVALUATED` | The in-repository half is intact, but agreement with the provider can only be established by a live call this check deliberately does not make. Never reported as a pass. |

The distinction that matters is between **two different kinds of drift**:

1. **Repository drift** — the pin recorded here no longer matches the source file it names. This is
   fully checkable offline, and it is what keeps this inventory from silently rotting as the code
   changes around it.
2. **Provider drift** — the value is still in the code exactly as recorded, and the provider has
   stopped honouring it. Only a live call can observe this. The check reports `UNEVALUATED` rather
   than guessing, except where a drift has actually been observed and recorded below.

`claude.oauth-client-id` is currently the second kind. It is unchanged in the source and reported
`DRIFTED` because a live claim on 2026-08-14 proved the provider no longer recognises it.

### What is recorded here

Every place the **product** depends on the value — including each entrypoint that exports a default,
because a value that lives in four files can drift apart in three of them. Tests and smoke tools that
*assert* a contract are deliberately not listed: they already fail loudly on their own, and listing
them would turn this inventory into a grep index instead of a record of what the product depends on.

## Claude subscription path (`SL-04`, `SL-08`, `SL-09`)

Used by `mitm/claim-token` (validate a login, then vault it) and by `mitm/filter_addon.py` (inject
the vaulted bearer, own the refresh).

| Dependency | Where the value lives | What breaks if the provider changes it |
|---|---|---|
| OAuth token endpoint | `mitm/claim-token`, `mitm/filter_addon.py`, and the two entrypoints that export the default (`mitm/entrypoint.sh`, `mitm/sidecar-entrypoint.sh`) — `OAUTH_TOKEN_URL`, env-overridable | Claiming refuses and vault refresh stops rotating. `CAS-R072` token isolation becomes uncompletable in both the MITM and sidecar variants. |
| OAuth client registration | the same four files — `OAUTH_CLIENT_ID`, env-overridable | The refresh grant is refused, so no login can be vaulted. Drifted once already (2026-08-14) and was re-pinned on 2026-08-16; see the provenance section. Load-bearing because the CLI no longer writes a `clientId` of its own. |
| Refresh grant shape | `mitm/claim-token`, `mitm/filter_addon.py` (JSON body: `grant_type`, `refresh_token`, `client_id`, `scope`) | The grant is rejected or silently returns a narrower token than the caller expects. |
| Credential file schema | `mitm/claim-token`, `mitm/filter_addon.py` — the `claudeAiOauth` root object. As written by CLI `2.1.233` (observed 2026-08-16): `accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `rateLimitTier`, `scopes`, `subscriptionType`. It has **gained** `refreshTokenExpiresAt` and `rateLimitTier`, and **lost `clientId`**, since this contract was first recorded | Written by the Claude Code CLI, not by this project. A schema change means the claim finds nothing to move, or the placeholder stops convincing the CLI it is logged in. The pin is the root object key; the field-level semantics are covered by `mitm/test_token_isolation.py`, which fails loudly on its own. |
| Injection destination and header | `mitm/filter_addon.py` (`api.anthropic.com`, `authorization: Bearer`) | The vaulted token is injected on a host the API no longer serves, or in a form it no longer accepts — requests fail with the agent holding only a placeholder. |
| Pinned CLI whose schema is consumed | `Dockerfile` (`CLAUDE_CODE_VERSION`) | This project's own pin, not the provider's. Recorded because the credential file schema above is only meaningful relative to a known CLI version. |
| Refresh client identification | `mitm/filter_addon.py` — `REFRESH_USER_AGENT`, env-overridable via `TOKEN_REFRESH_USER_AGENT` | The refresh POST is rejected **before it reaches the OAuth endpoint**. Observed 2026-08-17: with no `User-Agent`, Cloudflare answers `403` with `error code: 1010` as `text/plain` — a client-fingerprint ban, not a provider auth error; with one, the identical request returns `200` and rotates. Because `TokenVault` fails closed by continuing to serve the still-valid token, a break here is silent for the token's remaining lifetime and then takes the whole sidecar Claude path down. The observed access-token TTL is **8 hours**, so that is the delay between cause and symptom. |

## DeepSeek API-key path (`SL-12`)

| Dependency | Where the value lives | What breaks if the provider changes it |
|---|---|---|
| API host (injection) | `mitm/filter_addon.py` (exact-host match on `api.deepseek.com`) | Injection stops matching. The request is denied or leaves without the sidecar key; it never leaves *with* an agent-supplied one. |
| API host (egress grant) | `mitm/sidecar-entrypoint.sh` (`EXACT_ALLOW_HOSTS` / `EXACT_AUTH_HOSTS`) | Recorded separately from the line above because the two must agree: a host that is injected but not granted is denied, and one granted but not injected would leave without a credential. |
| Authorization header contract | `mitm/filter_addon.py` (`authorization: Bearer <key>`) | The provider rejects the injected credential; the key is never exposed to the agent either way. |
| Sidecar-only key path | `docker-compose.sidecar.yml`, `mitm/sidecar-entrypoint.sh`, `mitm/filter_addon.py`, `mitm/deepseek-key` (`/var/lib/sandbox/deepseek/api-key`) | This project's own pin. Recorded across all four so the Compose value, the entrypoint default, the reader, and the provisioning tool cannot drift apart unnoticed. |

## Pi harness (`SL-12`)

Pi is the CLI that *consumes* DeepSeek here. Its contract is separate from DeepSeek's own.

| Dependency | Where the value lives | What breaks if the provider changes it |
|---|---|---|
| Provider-selection variable | `docker-compose.sidecar.yml` (`DEEPSEEK_API_KEY`, set to the inert placeholder) | Pi stops selecting its built-in DeepSeek provider from the placeholder, so the agent either loses the provider or starts looking for a real key. |
| Local credential file | `~/.pi/agent/auth.json` — **not present in this repository** | This is an *asserted* contract, not a consumed one: the project never reads or writes that file, but `CAS-R110` asserts no usable key is visible in it. If Pi changes where or how it stores provider credentials, that assertion stops being true and nothing here would notice. It has no in-tree literal, so the check reports it `UNEVALUATED` rather than skipping it. |
| Pinned CLI | `Dockerfile` (`PI_VERSION`) | This project's own pin; the assertion above is only meaningful relative to a known Pi version. |

## Codex / OpenAI subscription path (`SL-13`)

No adapter exists. `SL-13` stands at a documented `NO-GO`, and `CAS-R121` already required this
discipline for this provider before `SL-18` generalised it. What is pinned is the version the verdict
was reached against, so a CLI bump cannot quietly invalidate the recorded conclusion.

**The pair agreed again on 2026-09-03, and how it got there is the point.** Adopting `0.153.0`
left `codex.cli-version` ahead of `codex.verdict-anchor`, which stayed at `0.140.0` because no
assessment had been run against the new CLI. The anchor moved only once one had been — the probe was
re-run against the shipped binary and returned the same `NO-GO`. Both rows now read `0.153.0`.

They are still pinned **separately** on purpose, and must not be made a `pin-coupling` (the block in
[`pin-acceptance.md`](pin-acceptance.md) that forces a pin and its coupled literals to move
together). A coupling would drag the anchor along with every future bump and thereby assert a
verdict nobody reached — the opposite of what this pair is for. The anchor follows a re-assessment,
never a rebuild.

| Dependency | Where the value lives | What breaks if it changes |
|---|---|---|
| Pinned CLI version | `Dockerfile` (`CODEX_VERSION`) | The feasibility verdict no longer describes the shipped CLI. |
| Verdict version anchor | `docs/codex-subscription-broker-feasibility.md` | The recorded `NO-GO` loses the version it was established against. |

`scripts/probe-codex-subscription-broker.sh` remains the deeper, Codex-specific probe: it runs the
pinned binary and asserts its actual command surface. That probe needs Codex installed; this check
does not, and covers the pin rather than the surface.

## Telling a drifted contract from a revoked credential

A contract that fails closed is only half of what `CAS-R172` asks for. The other half is that you can
tell *why* it failed. The mediation layer's own denials are `403`s, and a provider can return `403`
too, so without a marker "the sandbox refused this" and "the provider refused this" look alike — and
a drifted contract becomes indistinguishable from a revoked or expired key.

**Every refusal this project authors carries `X-Sandbox-Filter: deny` and a `Filtered: …` body. A
provider response never does.** `mitm/filter_addon.py` constructs a response in exactly one place and
has no `response` hook, so a reply that came from the provider reaches the agent verbatim — status,
body, and headers.

Verified live against `api.deepseek.com` on 2026-08-16, all three on the same host:

| What happened | Status | `X-Sandbox-Filter` | Body | Audit trail |
|---|---|---|---|---|
| The sidecar's key storage is missing, empty, or unsafe | `403` | `deny` | `Filtered: DeepSeek credential is unavailable or unsafe` | `DENY … deepseek-key-unavailable-or-unsafe` |
| The host is not the exact allowlisted destination | `403` | `deny` | `Filtered: host not on allowlist` | `DENY … not-allowlisted` |
| **The provider rejected the injected key** | `401` (the provider's) | **absent** | the provider's own error document | `INJECT` then `ALLOW` |

So: a `DENY` line in `./audit.sh --mitm`, or an `X-Sandbox-Filter` header on the response, means this
project refused before the provider was ever consulted. Their absence means the request reached the
provider and the verdict is the provider's own — which is where a drifted contract shows up.

### One residual, stated rather than hidden

DeepSeek's authentication error echoes the **last four characters** of the key it was sent, in the
form `Your api key: ****XXXX is invalid`. That is the provider's own redaction, in the provider's own
response, and this project deliberately does not rewrite it: rewriting a provider error is precisely
what `CAS-R172` forbids, and doing so would trade a real diagnostic for a token improvement.

The consequence is that an agent which triggers an authentication failure learns four characters of
the sidecar-held key. Four characters of a key the agent otherwise never sees is far below anything
usable — it does not make the key guessable — but it is a real detail of the boundary, so it is
recorded here rather than left for someone to discover. If a provider ever echoed materially more
than this, the correct response would be to stop sending requests to it under injection, not to start
editing its errors.

## Provenance and re-pinning (`CAS-R174`)

Every value recorded here came from this repository's own source at the commit that added this file.
None was extracted from a compiled or obfuscated provider artifact, and none may be — `PRD §7` names
that an explicit non-goal.

### The one re-pin performed so far

**`claude.oauth-client-id`, re-pinned 2026-08-16.**

| | |
|---|---|
| Previous value | `22422756-60c9-4084-8eb7-27705fd5cf9a` — retired by the provider; rejected with `Client with id … not found` |
| New value | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| Source | the `client_id` query parameter of the authorization URL that Claude Code prints for the operator to open during `/login` |
| CLI version that emitted it | `2.1.233` |
| Observed | 2026-08-16, during a real subscription login in an isolated sandbox stack |
| Verified | the claim succeeded against the live provider with this value: *"validated subscription token moved to the vault; placeholder installed for the agent"* |

This is the source `CAS-R174` permits — "a provider's own artifacts **or observed traffic**". The value
is emitted in plain text by the provider's own client, to the user, as part of the documented login
flow. Nothing was extracted from a compiled or obfuscated artifact, which `PRD §7` forbids.

**To obtain it again:** run `/login` in an agent container and read `client_id=` from the URL the CLI
prints, before approving. An OAuth *client* registration is a public identifier, not a credential.

Why this constant is load-bearing at all: `claim-token` uses `oauth.get("clientId") or
OAUTH_CLIENT_ID`, and CLI `2.1.233` writes no `clientId` into its credential file, so the fall-back is
always taken. If a future CLI starts storing one again, the recorded value stops being used and the
check's `UNEVALUATED` status for this dependency becomes the honest one.

When a pin has to change:

1. Record where the replacement came from — official provider documentation, a supported API
   response, or an observed request from the provider's own client — and the date it was taken.
2. Update the value in the source file **and** the machine-readable block below in the same change,
   so the two cannot disagree.
3. Clear or update the `observed` column, and state in the commit what evidence retired the drift.
4. If no supported source exists, stop at a documented result rather than adapting to an unversioned
   one. That is the precedent `SL-13` already set.

## CLI auth surfaces (`SL-04`)

`claude auth login` and `codex login --device-auth` are the subcommands the host-side sign-in
commands in [`../scripts/auth/`](../scripts/auth/) drive. They are provider-controlled surfaces of a
pinned CLI, so they belong here for the same reason a token endpoint does: `CAS-R170`'s rule is that
a dependency existing only as a literal inside a script is not recorded. A vendor that renames or
removes one breaks the sign-in path, and only a live run can observe that — so both are `required`,
never reported as confirmed by this check.

The `claude.oauth-client-id` drift has deliberately **not** been repaired here. Choosing a
replacement registration is a `CAS-R174` decision, and it is a smaller decision now that a check
exists to prove whether a candidate works.

## Machine-readable pins

Fields are `|`-separated; surrounding whitespace is ignored.

- `files` — repository-relative paths that must contain `pin`, comma-separated, or `-` when the
  dependency has no in-tree literal.
- `pin` — the exact literal expected in each of those files.
- `live` — `na` when this repository is sufficient to confirm the pin; `required` when agreement with
  the provider can only be established by a live call.
- `observed` — `-`, or `drifted:YYYY-MM-DD` for a drift actually observed on that date.

```contract-pins
# id | provider | surface | files | pin | live | observed
claude.oauth-token-endpoint | Claude | endpoint | mitm/claim-token,mitm/entrypoint.sh,mitm/filter_addon.py,mitm/sidecar-entrypoint.sh | https://platform.claude.com/v1/oauth/token | required | -
claude.oauth-client-id | Claude | identifier | mitm/claim-token,mitm/entrypoint.sh,mitm/filter_addon.py,mitm/sidecar-entrypoint.sh | 9d1c250a-e61b-44d9-88ed-5944d1962f5e | required | -
claude.oauth-grant-shape | Claude | grant shape | mitm/claim-token,mitm/filter_addon.py | "grant_type": "refresh_token" | required | -
claude.credential-file-schema | Claude | credential schema | mitm/claim-token,mitm/filter_addon.py | claudeAiOauth | required | -
claude.injection-destination | Claude | injection destination | mitm/filter_addon.py | _matches(host, "api.anthropic.com") | required | -
claude.injection-header | Claude | header contract | mitm/filter_addon.py | flow.request.headers["authorization"] = f"Bearer {tok}" | required | -
claude.cli-version | Claude | pinned CLI | Dockerfile | ARG CLAUDE_CODE_VERSION=2.1.258 | na | -
claude.oauth-refresh-user-agent | Claude | client identification | mitm/filter_addon.py | claude-cli/2.1.258 (external, cli) | required | -
claude.cli-login-command | Claude | CLI auth surface | scripts/auth/claude-login.sh,scripts/auth/claude-login.ps1 | claude auth login | required | -
deepseek.injection-host | DeepSeek | injection destination | mitm/filter_addon.py | _exact(host, ("api.deepseek.com",)) | required | -
deepseek.exact-host-grant | DeepSeek | egress grant | mitm/sidecar-entrypoint.sh | export EXACT_ALLOW_HOSTS="api.deepseek.com" | required | -
deepseek.auth-header | DeepSeek | header contract | mitm/filter_addon.py | flow.request.headers["authorization"] = f"Bearer {key}" | required | -
deepseek.key-path | DeepSeek | local secret path | docker-compose.sidecar.yml,mitm/deepseek-key,mitm/filter_addon.py,mitm/sidecar-entrypoint.sh | /var/lib/sandbox/deepseek/api-key | na | -
pi.deepseek-env-var | Pi | provider selection | docker-compose.sidecar.yml | DEEPSEEK_API_KEY | required | -
pi.auth-file-schema | Pi | asserted credential schema | - | ~/.pi/agent/auth.json | required | -
pi.cli-version | Pi | pinned CLI | Dockerfile | ARG PI_VERSION=0.84.4 | na | -
codex.cli-version | Codex | pinned CLI | Dockerfile | ARG CODEX_VERSION=0.153.0 | na | -
codex.verdict-anchor | Codex | verdict version anchor | docs/codex-subscription-broker-feasibility.md | 0.153.0 | na | -
codex.cli-login-command | Codex | CLI auth surface | scripts/auth/codex-login.sh,scripts/auth/codex-login.ps1 | codex login --device-auth | required | -
```
