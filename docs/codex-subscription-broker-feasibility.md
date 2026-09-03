# Codex subscription broker feasibility

> **Re-established at `0.153.0` on 2026-09-03.** The verdict below was first reached against
> `0.140.0`. The pin has since moved thirteen minor versions, so the assessment was re-run against
> the shipped CLI through the reproduction path recorded further down. **Same verdict, same decisive
> evidence, and the probe needed no change to produce it.** What follows is therefore a live
> statement about the bundled Codex, not a historical one. `SL-13` stays `Deferred`.

## Verdict: NO-GO

The repository-pinned Codex CLI does not expose a supported, credential-only contract that can keep
a personal ChatGPT subscription credential in the egress sidecar while Codex continues to execute as
the untrusted agent. Established at `0.140.0` on 2026-08-10 and re-established at `0.153.0` on
2026-09-03. Do not implement the proposed
sidecar adapter by parsing `auth.json`, copying cached credentials, using the external-token App
Server mode, or substituting an OpenAI API key.

This verdict is deliberately narrower than “Codex cannot use a subscription in a container.” The
existing default stack supports subscription login. What is not feasible at the pinned contract is
the additional security property: **all reusable authentication and refresh state stays in a
credential-only sidecar that runs no agent code and mounts no workspace**.

## Assessed contract, at `0.140.0`

This table is the **original** evidence, gathered on 2026-08-10. It is kept as recorded rather than
rewritten; the re-assessment against the shipped `0.153.0` is its own section below, and states what
changed between the two and what did not.

| Evidence class | Pinned evidence | Finding |
|---|---|---|
| Repository pin | `Dockerfile`: `ARG CODEX_VERSION=0.140.0` | The decision applies only to this exact bundled version. |
| Upstream release | [`rust-v0.140.0`](https://github.com/openai/codex/releases/tag/rust-v0.140.0), commit [`6506579`](https://github.com/openai/codex/commit/6506579001c322927a3e4bd440563267a7ac6c1f), published 2026-06-15 | Release/tag and executable were matched before inspecting the generated protocol. |
| Official authentication documentation | [Codex authentication](https://learn.chatgpt.com/docs/auth), retrieved 2026-08-10 | `codex login` and `--device-auth` support ChatGPT subscription login. Credentials are cached in `auth.json` or a keyring, active sessions refresh automatically, `codex login status` reports the mode, and `codex logout` clears credentials. OpenAI says `auth.json` contains access tokens. |
| Official App Server documentation | [Auth endpoints](https://learn.chatgpt.com/docs/app-server#auth-endpoints), retrieved 2026-08-10 | Managed ChatGPT login exists. Host-supplied `chatgptAuthTokens` and its refresh callback are documented as experimental. |
| Pinned CLI help | `codex --help`, `codex login --help`, `codex logout --help`, and `codex app-server --help` from `0.140.0` | Login, device auth, status, and logout are supported. The TUI can connect to a remote App Server, but App Server is explicitly experimental and there is no credential-only broker command. |
| Pinned generated protocol | `codex app-server generate-json-schema` from `codex-cli 0.140.0` | The external-token variant is stronger than merely experimental: it says `[UNSTABLE] FOR OPENAI INTERNAL USE ONLY - DO NOT USE`, requires client-supplied `accessToken` and `chatgptAccountId`, and returns replacement credential material through the client refresh response. |
| Pinned upstream source | [`account.rs`](https://github.com/openai/codex/blob/6506579001c322927a3e4bd440563267a7ac6c1f/codex-rs/app-server-protocol/src/protocol/v2/account.rs#L44-L82), [`account_processor.rs`](https://github.com/openai/codex/blob/6506579001c322927a3e4bd440563267a7ac6c1f/codex-rs/app-server/src/request_processors/account_processor.rs#L549-L615), and [`manager.rs`](https://github.com/openai/codex/blob/6506579001c322927a3e4bd440563267a7ac6c1f/codex-rs/login/src/auth/manager.rs#L705-L722) | The external mode is guarded as experimental, receives the access token from its client, and installs it in the Codex process's ephemeral auth store. |

The generated `GetAccountParams` contract also states that proactive `refreshToken=true` is ignored
for external auth: the client must refresh and call `account/login/start` with new
`chatgptAuthTokens`. The generated `ChatgptAuthTokensRefreshResponse` requires a new `accessToken`
and `chatgptAccountId`. This is a credential-bearing client protocol, not a credential-injection
interface.

## Boundary analysis

The supported managed-login path and the internal external-token path each fail a required
placement invariant:

| Placement | Credential result | Execution result | Decision |
|---|---|---|---|
| Run normal Codex / App Server in the agent container | Managed login caches reusable state in the agent namespace. External mode sends the access token and every replacement token across agent-controlled IPC and retains it in the Codex process. | Codex can access the workspace and run tools. | Fails credential isolation. |
| Run App Server in the credential sidecar | Reusable state can remain in the sidecar process. | App Server is a full agent execution surface, not an auth broker. Its pinned client protocol includes `thread/shellCommand`, `command/exec`, `fs/readFile`, and `fs/writeFile`. Without a workspace mount it cannot provide the normal coding-agent boundary; with one, the credential container runs agent-controlled commands and ceases to be a credential-only sidecar. | Fails the sidecar trust boundary. |
| Copy `auth.json` or expose a keyring | The agent receives the documented reusable access-token cache. | Codex works normally. | Explicitly rejected. |
| Use `OPENAI_API_KEY` / `--with-api-key` | A different reusable credential enters the agent or proxy path. | Billing and workspace semantics change to API usage. | Explicitly rejected. |

WebSocket capability-token or signed-bearer transport authentication does not repair this. It can
exclude unrelated clients, but the authorized agent client still controls the App Server's
credential-bearing login/refresh protocol and its command/filesystem execution surface.

Therefore no candidate satisfies all of these at once:

1. a documented, non-internal, pin-testable interface;
2. no access token, refresh token, session credential, or replacement credential crosses into the
   agent namespace or an agent-controlled payload;
3. login, refresh, and logout are sidecar-owned;
4. the credential container remains a narrow proxy/vault with no workspace and no agent command
   execution; and
5. ChatGPT subscription billing semantics are retained without API-key fallback.

## Live-test stop and endpoint inventory

No subscription login, model inference, or token refresh was attempted. The issue requires a safe,
supported broker boundary before a live credential is introduced; the protocol inspection failed
that prerequisite. Proceeding would have exposed a real credential to the very channel under
evaluation and would not have produced valid GO evidence.

No issue-specific Compose project, persistent container, network, volume, credential-bearing Codex
home, login, or account state was created. The only runtime check uses an ephemeral
`docker run --rm` container without an auth volume and asks the bundled CLI to generate its
secret-free JSON schema.

Exact authentication, refresh, and inference host/request allowlists are intentionally not proposed.
That inventory is GO-only acceptance; adding routes after a NO-GO would create egress without a
supported credential boundary. `docker-compose.sidecar.yml` therefore remains free of
`ALLOW_OPENAI`, Codex mounts, and OpenAI/ChatGPT routes.

## Logout, revocation, and reevaluation

For managed authentication, official documentation says `codex logout` clears the current local
credentials. In the pinned source, App Server logout attempts token revocation and then clears both
ephemeral and configured credential stores; revocation errors are logged and do not prevent local
cleanup. Remote revocation is therefore best-effort rather than a property this spike can claim.
External-token mode additionally requires its owning client to manage the upstream credential
lifecycle, reinforcing that it is not a sidecar refresh primitive.

Reevaluate this NO-GO only after OpenAI publishes a non-internal, versioned credential-broker or
credential-injection interface that separates auth lifecycle from the App Server execution surface.
At reevaluation time, bump the pinned evidence, run the compatibility probe, and open a separate
implementation issue for exact routes, default-off `ALLOW_OPENAI`, login, refresh, two real
subscription inferences, placeholder-only agent state, logout, and direct-egress denial.

## Re-assessment at `0.153.0` (2026-09-03)

Re-run because the `0.141`–`0.153` release notes carried **named candidates** rather than a vague
possibility: proxy-aware authentication in `0.143` and `0.146`, host-provided authentication at
runtime in `0.144`, and managed-authentication enforcement in `0.147`. `SL-08`/`SL-09` are built on
a credential-injecting proxy, and part of the original `NO-GO` was that Codex did not respect that
path — so these were worth checking rather than assuming either way.

**They did not change the answer.** The two schema strings that carry the decision are unchanged:

> `v2/LoginAccountParams.json` — *"[UNSTABLE] FOR OPENAI INTERNAL USE ONLY - DO NOT USE. The access
> token must contain the same scopes that Codex-managed ChatGPT auth tokens have."*

> `v2/AccountUpdatedNotification.json` — *"[UNSTABLE] FOR OPENAI INTERNAL USE ONLY - DO NOT USE.
> ChatGPT auth tokens are supplied by an external host app and are only stored in memory. Token
> refresh must be handled by the external host app."*

The second is worth quoting rather than paraphrasing. In-memory-only tokens whose refresh is owned
by an external host is **close to the shape a sidecar broker would want**, and it is still
explicitly not for use. That is the whole finding: the capability exists and the contract withholds
it. Building on it anyway would be exactly the brittle adaptation `CAS-R121` and `CAS-R174` refuse.

`app-server` also remains `[experimental]` and still exposes `thread/shellCommand`, `command/exec`,
`fs/readFile`, and `fs/writeFile`. Hosting it in the credential sidecar would still collapse the
sidecar's defining property — the credential holder runs no agent code and mounts no workspace — so
the second half of the original reasoning is intact too.

**One contract observation, recorded because something depends on it.** `codex login --device-auth`
still exists and is still accepted at `0.153.0`, but its `--help` entry now has an empty
description: the flag is supported and no longer documented. `scripts/auth/codex-login.sh` drives
it and `codex.cli-login-command` in [`provider-contracts.md`](provider-contracts.md) pins it, so a
future removal would break the host-side sign-in. Only a live run can observe that, which is why
that contract is recorded as needing one.

**What would reopen this** is unchanged: a supported, versioned, non-internal credential-only
interface. A marker moving from `[UNSTABLE] FOR OPENAI INTERNAL USE ONLY - DO NOT USE` to a stable
one is the single signal to watch, and re-running the probe is how to check it.

## Reproduce the compatibility evidence

The probe reads the exact `CODEX_VERSION` from `Dockerfile`, rejects any different executable,
generates the pinned App Server schema without authenticating, and fails closed if the decisive
protocol fields or stability markers change:

```bash
docker run --rm \
  --entrypoint bash \
  --mount "type=bind,src=$PWD,dst=/workspace,readonly" \
  --workdir /workspace \
  coding-agent-sandbox:latest \
  scripts/probe-codex-subscription-broker.sh

scripts/test-codex-subscription-broker.sh
```

Expected final fields at `0.153.0`, captured 2026-09-03 through exactly the command above:

```text
managed_login_modes=chatgpt,chatgptDeviceCode
external_mode=chatgptAuthTokens
external_stability=unstable-openai-internal-only-do-not-use
external_login_payload=accessToken,chatgptAccountId
external_refresh_owner=client
external_refresh_payload=accessToken,chatgptAccountId
app_server_execution_surface=thread/shellCommand,command/exec,fs/readFile,fs/writeFile
codex_version=0.153.0
cli_lifecycle=login,device-auth,status,logout
remote_execution_transport=experimental-app-server
verdict=NO-GO
reason=no-supported-credential-only-subscription-broker
```

At `0.140.0` the recorded fields were `codex_version`, `verdict`, and `reason`. The probe has
reported the fuller set since; the three that carried the decision then carry it now, with
`codex_version` the only one whose value moved.
