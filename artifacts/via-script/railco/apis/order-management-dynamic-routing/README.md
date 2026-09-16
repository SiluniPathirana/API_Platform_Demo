# OrderManagementAPI — Dynamic Routing Demo

A multi-tenant Order Management API on the WSO2 API Platform Gateway. Each
customer organization (`Railco`, `Acme`) is routed to its own backend, after
the caller's token is verified (`jwt-auth`) and exchanged for a
backend-specific token (the custom `dynamic-routing` policy).

## Contents

```
order-management-dynamic-routing/
├── OrderManagementAPI-v1.0.yaml   # API definition (deploy to the gateway)
├── policy/                        # Custom dynamic-routing policy source
│   ├── dynamic_routing.go
│   ├── dynamic_routing_test.go
│   ├── policy-definition.yaml
│   ├── go.mod
│   └── go.sum
└── mock-services/                 # Standalone Node.js mocks for local testing
    ├── mock-backend.js            # Generic backend, parameterized by NAME/PORT
    └── wk-token-exchange-service.js
```

## 1. Start the mock services

Each is a plain Node.js script (no dependencies) — run from anywhere, they
just need a `PORT` (and `NAME` for `mock-backend.js`).

```bash
cd mock-services

# Railco's order backend
NAME=railco_backend  PORT=7093 node mock-backend.js &

# Acme's order backend
NAME=acme_backend    PORT=7095 node mock-backend.js &

# Default/fallback backend (used when org_id/org_name has no matching entry)
NAME=default_backend PORT=7096 node mock-backend.js &

# Token-exchange service (issues backend-specific tokens)
PORT=7099 node wk-token-exchange-service.js &
```

Verify they're up:
```bash
curl http://localhost:7093/anything   # -> {"backend":"railco_backend", ...}
curl http://localhost:7095/anything   # -> {"backend":"acme_backend", ...}
curl http://localhost:7096/anything   # -> {"backend":"default_backend", ...}
```

## 2. Compile the custom policy into a gateway image

The `policy/` directory is a `filePath` policy, not a stock gomodule — it
must be compiled into a custom gateway image. From your WSO2 API Platform
Gateway distribution root:

1. Copy `policy/` into `policies/dynamic-routing/` in the gateway repo.
2. Add it to `build.yaml`:
   ```yaml
   policies:
     - name: dynamic-routing
       filePath: ./policies/dynamic-routing
   ```
3. Build:
   ```bash
   docker run --rm \
     -v "$(pwd):/workspace" -w /workspace \
     ghcr.io/wso2/api-platform/gateway-builder:1.2.0 \
     -build-file /workspace/build.yaml \
     -out-dir /workspace/.build-output \
     -log-level info

   docker build -t my-gateway-runtime:custom    .build-output/gateway-runtime
   docker build -t my-gateway-controller:custom .build-output/gateway-controller
   ```
4. Point `docker-compose.yaml`'s `gateway-controller`/`gateway-runtime`
   services at these custom image tags, then:
   ```bash
   docker compose up -d --force-recreate gateway-controller gateway-runtime
   ```

## 3. Configure the JWT key manager

`OrderManagementAPI-v1.0.yaml` attaches `jwt-auth` with `issuers:
["asgardeo-railco"]`. Add a matching key manager to the gateway's
`config.toml`:

```toml
[policy_configurations.jwtauth_v1]

[[policy_configurations.jwtauth_v1.keymanagers]]
name = "asgardeo-railco"
issuer = "https://<your-IS-host>:9444/oauth2/token"

[policy_configurations.jwtauth_v1.keymanagers.jwks.remote]
uri = "https://<your-IS-host-reachable-from-the-gateway-container>:9444/oauth2/jwks"
# skipTlsVerify = true   # only if the IS cert isn't trusted
```

Restart the gateway containers after editing `config.toml`.

## 4. Deploy the API

```bash
curl -X POST "http://localhost:<management-port>/api/management/v1/rest-apis" \
  -u "admin:admin" -H "Content-Type: application/yaml" \
  --data-binary @OrderManagementAPI-v1.0.yaml
```

(Use `PUT .../rest-apis/OrderManagementAPI-v1.0` instead for subsequent
updates.)

## 5. Call it

You need a real access token from the configured IS, with an `org_id` or
`org_name` claim (whichever `orgIDClaim` is set to in the API's
`dynamic-routing` params) equal to `Railco` or `Acme`:

```bash
curl -X POST "http://localhost:<runtime-port>/order-management/v1.0/orders" \
  -H "Authorization: Bearer <token>"
```

- No/invalid token → `401` (rejected by `jwt-auth`)
- Valid token, no org claim → `503`
- Valid token, org claim doesn't match `Railco`/`Acme` → `502`/`503`
  (`cluster_not_found` — no fallback map by design)
- Valid token, org claim = `Railco` or `Acme` → `200`, routed to that
  org's backend, with the caller's `Authorization` dropped and a
  `Backend-Token: Bearer <exchanged-token>` header set instead
