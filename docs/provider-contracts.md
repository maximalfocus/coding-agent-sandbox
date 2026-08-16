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
| OAuth client registration | the same four files — `OAUTH_CLIENT_ID`, env-overridable | The refresh grant is refused, so no login can be vaulted. **This is the observed 2026-08-14 drift.** |
| Refresh grant shape | `mitm/claim-token`, `mitm/filter_addon.py` (JSON body: `grant_type`, `refresh_token`, `client_id`, `scope`) | The grant is rejected or silently returns a narrower token than the caller expects. |
| Credential file schema | `mitm/claim-token`, `mitm/filter_addon.py` (`claudeAiOauth` object: `accessToken`, `refreshToken`, `expiresAt`, `scopes`) | Written by the Claude Code CLI, not by this project. A schema change means the claim finds nothing to move, or the placeholder stops convincing the CLI it is logged in. |
| Injection destination and header | `mitm/filter_addon.py` (`api.anthropic.com`, `authorization: Bearer`) | The vaulted token is injected on a host the API no longer serves, or in a form it no longer accepts — requests fail with the agent holding only a placeholder. |
| Pinned CLI whose schema is consumed | `Dockerfile` (`CLAUDE_CODE_VERSION`) | This project's own pin, not the provider's. Recorded because the credential file schema above is only meaningful relative to a known CLI version. |

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

| Dependency | Where the value lives | What breaks if it changes |
|---|---|---|
| Pinned CLI version | `Dockerfile` (`CODEX_VERSION`) | The feasibility verdict no longer describes the shipped CLI. |
| Verdict version anchor | `docs/codex-subscription-broker-feasibility.md` | The recorded `NO-GO` loses the version it was established against. |

`scripts/probe-codex-subscription-broker.sh` remains the deeper, Codex-specific probe: it runs the
pinned binary and asserts its actual command surface. That probe needs Codex installed; this check
does not, and covers the pin rather than the surface.

## Provenance and re-pinning (`CAS-R174`)

Every value recorded here came from this repository's own source at the commit that added this file.
None was extracted from a compiled or obfuscated provider artifact, and none may be — `PRD §7` names
that an explicit non-goal.

When a pin has to change:

1. Record where the replacement came from — official provider documentation, a supported API
   response, or an observed request from the provider's own client — and the date it was taken.
2. Update the value in the source file **and** the machine-readable block below in the same change,
   so the two cannot disagree.
3. Clear or update the `observed` column, and state in the commit what evidence retired the drift.
4. If no supported source exists, stop at a documented result rather than adapting to an unversioned
   one. That is the precedent `SL-13` already set.

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
claude.oauth-client-id | Claude | identifier | mitm/claim-token,mitm/entrypoint.sh,mitm/filter_addon.py,mitm/sidecar-entrypoint.sh | 22422756-60c9-4084-8eb7-27705fd5cf9a | required | drifted:2026-08-14
claude.oauth-grant-shape | Claude | grant shape | mitm/claim-token,mitm/filter_addon.py | "grant_type": "refresh_token" | required | -
claude.credential-file-schema | Claude | credential schema | mitm/claim-token,mitm/filter_addon.py | claudeAiOauth | required | -
claude.injection-destination | Claude | injection destination | mitm/filter_addon.py | _matches(host, "api.anthropic.com") | required | -
claude.injection-header | Claude | header contract | mitm/filter_addon.py | flow.request.headers["authorization"] = f"Bearer {tok}" | required | -
claude.cli-version | Claude | pinned CLI | Dockerfile | ARG CLAUDE_CODE_VERSION=2.1.158 | na | -
deepseek.injection-host | DeepSeek | injection destination | mitm/filter_addon.py | _exact(host, ("api.deepseek.com",)) | required | -
deepseek.exact-host-grant | DeepSeek | egress grant | mitm/sidecar-entrypoint.sh | export EXACT_ALLOW_HOSTS="api.deepseek.com" | required | -
deepseek.auth-header | DeepSeek | header contract | mitm/filter_addon.py | flow.request.headers["authorization"] = f"Bearer {key}" | required | -
deepseek.key-path | DeepSeek | local secret path | docker-compose.sidecar.yml,mitm/deepseek-key,mitm/filter_addon.py,mitm/sidecar-entrypoint.sh | /var/lib/sandbox/deepseek/api-key | na | -
pi.deepseek-env-var | Pi | provider selection | docker-compose.sidecar.yml | DEEPSEEK_API_KEY | required | -
pi.auth-file-schema | Pi | asserted credential schema | - | ~/.pi/agent/auth.json | required | -
pi.cli-version | Pi | pinned CLI | Dockerfile | ARG PI_VERSION=0.81.1 | na | -
codex.cli-version | Codex | pinned CLI | Dockerfile | ARG CODEX_VERSION=0.140.0 | na | -
codex.verdict-anchor | Codex | verdict version anchor | docs/codex-subscription-broker-feasibility.md | 0.140.0 | na | -
```
