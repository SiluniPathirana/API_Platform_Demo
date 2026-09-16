# API Platform Demo Flow

A walkthrough of the WSO2 API Platform end to end: APIs land in the gateway, get discovered by the API Publisher, get mirrored into the Developer Portal's default (`public`) catalog, and then a new tenant org is onboarded with its own users, catalog, and credentials.

## Prerequisites

- WSO2 IS is configured with the root service provider.
- The following APIs are already deployed to the gateway:

  | Type | Handle |
  |---|---|
  | REST | `agent-chat-rate-limiting` |
  | REST | `air-quality-api-v1.0` |
  | REST | `weather-api-v1.0` |
  | MCP | `geo-mcp-server-v1.0` |
  | MCP | `weather-mcp-server-v1.0` |

- The API Publisher has already discovered these deployed APIs.
- You have on hand:
  - the root app's `client_id` / `client_secret` / app id
  - the `public` org's admin username/password

---

## Step 1: Walk the existing catalog

1. Open the **API Publisher** (https://am.wso2.com:9443/publisher). It shows every API already deployed to the gateway.
2. Open the Developer Portal's **`public`** org (https://api-portal.wso2.com:9543/api-portal/public/views/default/). It shows the same APIs and MCP servers, already published.

## Step 2: Add a new API live

3. Deploy another REST API, `order-management-dynamic-routing`, to the gateway via the Gateway REST API.

   > **Postman:** *(steps to be filled in)*

4. Back in the **API Publisher**, the newly deployed REST API now shows up there too.
5. Publish that same REST API into the Developer Portal's `public` org.

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
   ```

   Publish the API to the Developer Portal's `public` org:

   > **Postman:** *(steps to be filled in)*

6. Back in the Developer Portal's `public` org this REST API now shows
   up there too.

## Step 3: Onboard the `acme` org

1. Run the tenant onboarding script against `acme`. It:
   - Creates the `acme` organization in WSO2 IS
   - Onboards `acme`'s users
   - Creates `acme`'s key manager
   - Register webhook subscriber to deliver subscription events to the gateway
   - Publishes `acme`'s APIs and MCP servers

    To onboard the tenant, run the following script with relevant parameters.

   ```bash
   ORG_NAME=acme \
   SAMPLE_DIR=acme \
   IS_URL=https://is.wso2.com:9444 \
   API_PORTAL_URL=https://api-portal.wso2.com:9543 \
   ROOT_APP_CLIENT_ID=*** \
   ROOT_APP_CLIENT_SECRET=*** \
   ROOT_APP_ID=*** \
   ./scripts/onboard-tenant.sh
   ```

   **Note:** Copy down, from the script's output: `acme`'s client id/secret, its
   users' usernames/passwords, and the token-endpoint curl example.

2. Log in to the Developer Portal's `acme` org using the copied
   username/password. It shows only `acme`'s own catalog.
3. Subscribe to the required APIs and copy each subscription's token.
4. Generate an access token using the token endpoint and `acme`'s client
   id/secret (from step 1).
5. Call the subscribed APIs using the generated token.

## Step 4: Repeat for `railco`

Repeat Phase 3 in full, substituting `ORG_NAME=railco SAMPLE_DIR=railco`.
