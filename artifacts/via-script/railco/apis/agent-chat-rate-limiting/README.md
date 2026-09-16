# AgentChatAPI — Token-Based Rate Limiting Demo

JWT-protected agent chat/completions API with per-org AND
per-org-per-use-case **token budgets** (not just request counts), using the
gateway's built-in `advanced-ratelimit` policy. Org identity is read from
the verified `org_name` JWT claim (`authproperty` keyExtraction) — never a
plain header. Use-case identity is still a plain header (`X-Use-Case-Id`).

## Contents

```
agent-chat-rate-limiting/
├── AgentChatAPI-v1.0.yaml     # API definition (deploy to the gateway)
└── mock-services/
    └── mock-agent-backend.js  # Mock agent backend, fixed token cost per call
```

## 1. Start the mock agent backend

Plain Node.js, no dependencies:

```bash
cd mock-services
PORT=7094 COMPLETION_TOKENS=50 node mock-agent-backend.js
```

- `PORT` — must match `upstream.main.url` in `AgentChatAPI-v1.0.yaml`
  (`http://host.docker.internal:7094` by default).
- `COMPLETION_TOKENS` — every response reports this many tokens used, via
  an `X-Completion-Tokens` header. `advanced-ratelimit`'s `costExtraction`
  reads that header and deducts it from every quota the request matched.
  Fixed here (a real agent's usage varies per call) so quota countdowns are
  predictable and easy to demo.

Verify it's up:
```bash
curl -X POST http://localhost:7094/anything
# -> {"result":"Agent response","usage":{"completion_tokens":50}}
```

## 2. Configure the JWT key manager

`AgentChatAPI-v1.0.yaml` attaches `jwt-auth` with `issuers:
["asgardeo-railco"]`. Add a matching key manager to the gateway's
`config.toml` (skip this if you already set it up for another API in this
repo, e.g. `order-management-dynamic-routing/` — it's the same key manager):

```toml
[policy_configurations.jwtauth_v1]

[[policy_configurations.jwtauth_v1.keymanagers]]
name = "asgardeo-railco"
issuer = "https://<your-IS-host>:9444/oauth2/token"

[policy_configurations.jwtauth_v1.keymanagers.jwks.remote]
uri = "https://<your-IS-host-reachable-from-the-gateway-container>:9444/oauth2/jwks"
# skipTlsVerify = true   # only if the IS cert isn't trusted
```

Restart the gateway containers after editing `config.toml`. No custom
policy code here — `advanced-ratelimit` and `jwt-auth` are both built-in,
so no image rebuild is needed, just a container restart to pick up the new
config.toml section.

## 3. Deploy the API

```bash
curl -X POST "http://localhost:<management-port>/api/management/v1/rest-apis" \
  -u "admin:admin" -H "Content-Type: application/yaml" \
  --data-binary @AgentChatAPI-v1.0.yaml
```

(Use `PUT .../rest-apis/AgentChatAPI-v1.0` for subsequent updates —
quota limits, for example, are config-only changes, no rebuild/restart
needed at all.)

## 4. Call it

You need a real user-level access token (not `client_credentials` — that
mints an app-level token whose `org_name` is the app's own default tenant,
which won't match any org quota below) whose `org_name` claim is `Railco`
or `Acme`.

```bash
curl -X POST "http://localhost:<runtime-port>/agent/v1.0/chat/completions" \
  -H "Authorization: Bearer <token>" \
  -H "X-Use-Case-Id: usecase1"
```

### Current demo limits (per minute, cost = 50 tokens/call)

| Quota | Railco | Acme |
|---|---|---|
| org-wide | 500 | 150 |
| usecase1 | 200 | 50 |
| usecase2 | 100 | 70 |

- No/invalid token → `401`
- Valid token, org quota exhausted → `429`
  (`x-ratelimit-quota` response header names which quota blocked it)
- Valid token, use-case quota exhausted (but org still has room) → `429`
- Both checked independently — **either** exhausted blocks the call, even
  if the other still has room
- A use-case with no dedicated quota configured (e.g. `X-Use-Case-Id:
  usecase-onboarding`) is only ever gated by the org-wide budget — useful
  to demonstrate that the org quota is still available even after every
  *named* use-case quota has been individually exhausted, since they all
  draw from the same org-wide pool independently of each other.
