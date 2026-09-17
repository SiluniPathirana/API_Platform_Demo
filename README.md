# API Platform Demo Flow

A walkthrough of the WSO2 API Platform end to end: APIs land in the gateway, get discovered by the API Publisher, get mirrored into the Developer Portal's default (`public`) catalog, and then a new tenant org is onboarded with its own users, catalog, and credentials.

## Prerequisites

This demo assumes the platform is already set up and the `public` catalog is already seeded. Before
starting, the following must be true:

- WSO2 IS is configured with the root service provider (`scripts/setup_idp.sh` has been run), and you
  have its `ROOT_APP_CLIENT_ID` / `ROOT_APP_CLIENT_SECRET` / `ROOT_APP_ID`.
- The `public` org is onboarded, and you have `publicadmin`'s password.
- The gateway holds the `public` catalog, and the API Publisher has discovered it:

  | Type | Gateway artifact | Context |
  |---|---|---|
  | REST | `AgentChatAPI-v1.0` | `/agent/v1.0` |
  | REST | `AirQualityAPI-v1.0` | `/air-quality` |
  | REST | `WeatherAPI-v1.0` | `/weather` |
  | MCP | `geo-mcp-server-v1.0` | `/mcp/geo` |
  | MCP | `weather-mcp-server-v1.0` | `/mcp/weather` |

- You know the `WEBHOOK_SECRET` — it must equal the subscription-mediator's own `SM_WEBHOOK_SECRET`.

### Endpoints

| | URL |
|---|---|
| WSO2 IS | https://is.wso2.com:9444 |
| API Manager (Publisher/Admin) | https://am.wso2.com:9443 |
| Developer Portal | https://api-portal.wso2.com:9543 |
| Gateway — traffic | https://platform.gw.wso2.com:8443 |
| Gateway — management | http://platform.gw.wso2.com:9090 |

Both Postman collections already default to these. Every TLS endpoint is self-signed, so turn
**Settings → General → SSL certificate verification OFF** in Postman, and pass `-k` to curl. The
`/etc/hosts` entries for these hostnames must exist on the machine running the demo.

### The bundle this demo deploys

`order-management-dynamic-routing/` — the one bundle deliberately left out of the
scripted seeding, so it can be added by hand while the audience watches. Like every bundle here it has
two independent halves, and an API needs both to be usable:

- the **gateway** half — `OrderManagementAPI-v1.0.yaml` at the bundle root, which makes it routable
  (Step 1);
- the **portal** half — `api-portal/api.yaml` + `api-portal/definition.yaml`, which makes it
  discoverable and subscribable (Step 2).

---

## Step 1: Walk the existing catalog

1. Open the **API Publisher** (https://am.wso2.com:9443/publisher). It shows every API already deployed to the gateway.
2. Open the Developer Portal's **`public`** org (https://api-portal.wso2.com:9543/api-portal/public/views/default/). It shows the same APIs and MCP servers, already published.

## Step 2: Add the OrderManagement API live

3. Deploy another REST API, `order-management-dynamic-routing`, to the gateway via the Gateway REST API.

> **Postman:** `API-Platform-Demo-Gateway-Management-Postman-Collection.json` →
> `2. Deploy OrderManagementAPI > 2a. Create OrderManagementAPI-v1.0`.
>
> The request body is the verbatim contents of
> `order-management-dynamic-routing/OrderManagementAPI-v1.0.yaml` — the source of truth for this API's
> gateway definition. If the API already exists the create returns `409` — use
> `3f. Update OrderManagementAPI-v1.0` instead.

4. Back in the **API Publisher**, the newly deployed REST API now shows up there too.

5. Publish it into the Developer Portal's `public` org

   Get an admin token for the `public` org:

   ```bash
   TOKEN=$(ORG_NAME=public \
     ORG_USERNAME=publicadmin \
     ORG_PASSWORD='***' \
     IS_URL=https://is.wso2.com:9444 \
     ROOT_APP_CLIENT_ID=*** \
     ROOT_APP_CLIENT_SECRET=*** \
     ROOT_APP_ID=*** \
     ./scripts/get-org-token.sh)
   echo "$TOKEN"
   ```

   This is a *user* token carrying the `dp_admin` role.

   > **Postman:** `API-Platform-Demo-Postman-Collection.json` →
   > `2. API Portal - Publish OrderManagementAPI > 2a. Publish OrderManagementAPI to the public org`.
   >
   > The request uploads `api-portal/{api.yaml, definition.yaml}` straight from that API's own
   > bundle at the repo root — `order-management-dynamic-routing/api-portal/`.
   >
   > Paste `$TOKEN` into the `portal_access_token` collection variable first. The requests upload
   > files off disk, so point Postman's working directory (Settings → General) at this
   > `API_Platform_Demo` folder and allow access to files outside it; if the file boxes on the Body
   > tab look empty, re-select the files by hand.

6. Back in the Developer Portal's `public` org, this REST API now shows up there too.

## Step 3: Onboard the `acme` org

1. Run the tenant onboarding script against `acme`. It:
   - Creates the `acme` organization in WSO2 IS and shares the root app to it
   - Onboards `acme`'s users (`acmeadmin` / `acmeuser`)
   - Creates `acme`'s own OAuth2 client and wires it up as `acme`'s key manager
   - Registers the webhook subscriber that delivers subscription events to the gateway
   - Publishes `acme`'s APIs and MCP servers into its own portal catalog

   To onboard the tenant, run the following script with relevant parameters.

   ```bash
   ORG_NAME=acme \
   SAMPLE_DIR=acme \
   IS_URL=https://is.wso2.com:9444 \
   API_PORTAL_URL=https://api-portal.wso2.com:9543 \
   ROOT_APP_CLIENT_ID=*** \
   ROOT_APP_CLIENT_SECRET=*** \
   ROOT_APP_ID=*** \
   WEBHOOK_SECRET='***' \
   ./scripts/onboard-tenant.sh
   ```

   `WEBHOOK_SECRET` must equal the mediator's `SM_WEBHOOK_SECRET`.

   **Note:** Copy down, from the script's output: `acme`'s client id/secret, and its users'
   usernames/passwords.

2. Log in to the Developer Portal's `acme` org using the copied
   username/password. It shows only `acme`'s own catalog.
3. Subscribe to the required APIs and copy each subscription's token.
4. Generate an access token using the token endpoint and `acme`'s client
   id/secret (from step 1).
5. Call the subscribed APIs using the generated token.

## Step 4: Repeat for `railco`

Repeat Step 3 in full, substituting `ORG_NAME=railco SAMPLE_DIR=railco`.

## Step 5: Subscribe, then invoke

### Subscribe, as each org

1. Log in to the Developer Portal's `acme` org using the copied username/password. It shows only
   `acme`'s own catalog.
2. Create an application, subscribe it to **OrderManagementAPI**, and copy the subscription's key - the portal shows it once.
3. Repeat for `railco`.

> **Note.** As the gateway definitions currently stand, neither demo API enforces the key —
> `order-management-dynamic-routing/OrderManagementAPI-v1.0.yaml` carries no
> `subscription-validation` policy either, so the `Subscription-Key` the Postman requests send is
> accepted but never checked. Re-add the policy to that file and re-push it (gateway-management
> collection, `3f`) if you want the subscription gate back in the demo.

### What each call must send

Neither demo API carries `subscription-validation`, and `jwt-auth` only authenticates the
caller — org identity for both routing and rate-limiting comes from the `X-Org-Name`
**request header**, not from any JWT claim:

| Policy | Applies to | What the caller must send |
|---|---|---|
| `jwt-auth` | both | `Authorization: Bearer <token>` from the org's own key-manager client |
| `dynamic-routing` | OrderManagementAPI | `X-Org-Name: railco` \| `acme` — picks the upstream |
| `advanced-ratelimit` | AgentChatAPI | `X-Org-Name: railco` \| `acme` — picks the org budget; plus `X-Use-Case-Id: <use case>` for the per-use-case budget |

**AgentChatAPI needs no subscription at all.** It carries no `subscription-validation`
policy and advertises no subscription plans in the portal (its `api-portal/api.yaml`
ships a deliberately empty `subscriptionPlans:` block, which `seed-samples.sh` leaves
alone rather than filling in from the org's plan set). A valid JWT gets a caller in;
the token budget is the only thing that limits them after that. Any `Subscription-Key`
header sent to it is ignored.

### Fill in the collection variables

In `API-Platform-Demo-Postman-Collection.json`:

| Variable | Where it comes from |
|---|---|
| `railco_client_id` / `railco_client_secret` | `railco`'s onboarding output (Step 4) |
| `acme_client_id` / `acme_client_secret` | `acme`'s onboarding output (Step 3) |
| `railco_order_management_subscription_key` | portal subscription, railco → OrderManagementAPI |
| `acme_order_management_subscription_key` | portal subscription, acme → OrderManagementAPI |

### Generate access tokens

1. Generate a token for `railco`'s client app (fill in `railco_client_id` / `railco_client_secret` in the collection variables first).

   > **Postman:** `3. OrderManagementAPI - Dynamic Routing > 1a. Generate Token - Railco (Client Credentials)`

2. Generate a token for `acme`'s client app (fill in `acme_client_id` / `acme_client_secret` first).

   > **Postman:** `3. OrderManagementAPI - Dynamic Routing > 1b. Generate Token - Acme (Client Credentials)`

### Invoke OrderManagementAPI

3. Invoke OrderManagementAPI as `railco` -- routes to Railco's own order backend via dynamic-routing.

   > **Postman:** `3. OrderManagementAPI - Dynamic Routing > 2a. Invoke OrderManagementAPI - Railco`

4. Invoke OrderManagementAPI as `acme` -- routes to Acme's own order backend.

   > **Postman:** `3. OrderManagementAPI - Dynamic Routing > 2b. Invoke OrderManagementAPI - Acme`

### Invoke AgentChatAPI

5. Exhaust `railco`'s `usecase1` token budget -- click Send 5 times; the 5th call is blocked with `429`.

   > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 1. Railco usecase1 (run 5x -- 1-4 succeed, 5th blocked at 429)`

6. Exhaust `railco`'s `usecase2` token budget -- click Send 3 times; the 3rd call is blocked with `429`.

   > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 2. Railco usecase2 (run 3x -- 1-2 succeed, 3rd blocked at 429)`

7. Confirm `railco`'s org-wide budget still has room for a different use-case, even with both named use-cases above exhausted.

   > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 3. Railco org quota STILL has room (different use-case, after 1+2 exhausted)`

8. Exhaust `acme`'s `usecase1` token budget -- click Send twice; the 2nd call is blocked with `429`.

   > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 4. Acme usecase1 (run 2x -- 1st succeeds, 2nd blocked at 429)`

9. Exhaust `acme`'s `usecase2` token budget -- click Send 3 times; the 3rd call is blocked with `429`.

   > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 5. Acme usecase2 (run 3x -- 1-2 succeed, 3rd blocked at 429)`

10. Confirm `acme`'s org-wide budget is ALSO exhausted for a different use-case -- unlike `railco` in step 7, Acme's per-use-case limits happen to sum exactly to its org limit, so there's no room left.

    > **Postman:** `4. AgentChatAPI - Token Rate Limiting > 6. Acme org quota ALSO exhausted (different use-case, after 4+5 exhausted -- unlike Railco)`

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `401` from any demo API | No/expired `Authorization` token, or the token was issued by a key manager the API's `jwt-auth` `issuers` list doesn't name (`IS-railco`, `IS-acme`) |
| `403` from either demo API | Neither API carries `subscription-validation` as deployed, so a subscription problem is not the cause — check the token's scopes and the `jwt-auth` `issuers` list instead |
| `503` from OrderManagementAPI | No `X-Org-Name` header, or its value names no `upstreamDefinitions` entry (only `railco` and `acme` exist; there is deliberately no fallback) |
| `502` from OrderManagementAPI | The mock backend for that org isn't running — see the prerequisites table |
| AgentChatAPI never returns `429`, and the gateway logs `Rate limit key not found for cost extraction` for every quota | No quota matched the request, so nothing is counted and no budget is ever spent. Send `X-Org-Name: railco` \| `acme` — the value is matched case-sensitively against `^railco$` / `^acme$`. A deployed copy still keyed on `authproperty: org_name` will always land here: a `client_credentials` token from `<org>-key-manager` carries no `org_name`, because that client lives in the **root** org. Re-push the API from `agent-chat-rate-limiting/AgentChatAPI-v1.0.yaml` |
| Postman multipart upload sends nothing | Working directory not set, or the file reference went stale — re-select the files on the Body tab |
| `409 Conflict` on any Create request | Already deployed; use the matching Update request |

**Source of truth.** Each demo API's gateway definition and portal artifacts live together at the
repo root, and nowhere else:

| API | Gateway definition | Portal artifacts |
|---|---|---|
| AgentChatAPI | `agent-chat-rate-limiting/AgentChatAPI-v1.0.yaml` | `agent-chat-rate-limiting/api-portal/` |
| OrderManagementAPI | `order-management-dynamic-routing/OrderManagementAPI-v1.0.yaml` | `order-management-dynamic-routing/api-portal/` |

Both Postman collections read from exactly those files — the gateway-management collection embeds the
two gateway YAMLs verbatim in its create/update bodies, and folder 2 of the main collection uploads
the two `api-portal/` folders. Edit the file and re-import; never edit a body in Postman.

## Starting over

```bash
ORG_NAME=acme \
IS_URL=https://is.wso2.com:9444 \
API_PORTAL_URL=https://api-portal.wso2.com:9543 \
ROOT_APP_CLIENT_ID=*** ROOT_APP_CLIENT_SECRET=*** ROOT_APP_ID=*** \
./scripts/cleanup-tenant.sh
```

Deletes the org's subscriptions, applications, portal APIs/MCPs, and the org itself in IS. It is
destructive and prompts for nothing. It does **not** remove anything from the gateway — use the
management API's `DELETE /rest-apis/{name}` for that.

WSO2 IS does not free a deleted organization's name, so re-onboarding needs a new `ORG_NAME` with
`SAMPLE_DIR` still pointing at the original bundle: `ORG_NAME=acme-demo SAMPLE_DIR=acme`.

## Also in the collections

`API-Platform-Demo-Postman-Collection.json` folder `1. API Manager - DCR & admin token` registers the
DCR application and exchanges it for an admin token (`{{apim_access_token}}`) for API Manager's own
REST APIs. Nothing in this demo needs it — it is there for driving the Publisher/Admin APIs directly.

`API-Platform-Demo-Gateway-Management-Postman-Collection.json` folder
`1. Seed the public catalog (prerequisite)` deploys the five prerequisite artifacts, for rebuilding an
environment from scratch. `./scripts/seed-gateway.sh` does the same from the command line.
