#!/bin/bash

# --------------------------------------------------------------------
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# --------------------------------------------------------------------

# Onboards one tenant end to end against WSO2 Identity Server + the Developer
# Portal, driven entirely by that tenant's own sample directory
# (resources/samples/$ORG_NAME/ — apis/, mcps/, applications.yaml,
# subscription-plans.yaml). Six steps:
#
#   1. Registers the organization in IS (safe to re-run — an existing org is
#      looked up rather than re-created), configures its fragment copy of the
#      API Portal SP (password grant, JWT access tokens with roles/groups,
#      profile claim mappings — a freshly shared application does NOT
#      inherit any of this), and provisions its users:
#        - "${ORG_NAME}admin" (role dp_admin) — always. Does every
#          admin-level step below (plans, APIs/MCPs, key manager) since
#          dp_subscriber cannot.
#        - "${ORG_NAME}user" (role dp_subscriber) — only when this org's
#          applications.yaml lists at least one application. Owns that
#          application and its subscriptions.
#      Credentials for both are printed once, right after creation.
#   2. Creates this organization's OWN OAuth2 application directly in IS
#      (client_credentials grant) — its client_id/secret are what a caller
#      outside the portal uses to get a token, and what step 5 links into
#      the portal's own application record.
#   3. Seeds this organization's subscription plans from
#      subscription-plans.yaml (design-mode schema) via the real
#      subscription-plans REST API — PUT is an upsert, one plan per request
#      (the API silently no-ops on an array body when
#      organization.autoCreateSubscriptionPlans is enabled, which it is by
#      default). An org whose plans file has no entries (see "public" in the
#      bundled samples) keeps its auto-seeded defaults
#      (Bronze/Silver/Gold/Unlimited) instead.
#   4. Seeds this organization's APIs and MCP servers from apis/ and mcps/,
#      via seed-samples.sh (SAMPLES_DIR pointed at this org's directory),
#      each rewritten to advertise exactly the plans from step 3
#      (PLAN_OVERRIDE) rather than whatever its sample api.yaml originally
#      listed.
#   5. Configures a key manager (KEY_MANAGER_HANDLE) pointing at this
#      organization's own IS token endpoint — this portal's key managers are
#      deliberately thin (no DCR, no stored secret; just a displayName + the
#      tokenEndpoint the portal proxies client_credentials requests to — see
#      docs/administer/key-manager-integration.md). Then, for every entry in
#      applications.yaml, creates a portal application (owned by
#      "${ORG_NAME}user") and links step 2's client_id to it via
#      generate-keys.
#   6. If this org has applications, subscribes "${ORG_NAME}user" to every
#      deployed REST API at one of this org's own plans (MCP servers aren't
#      subscribable yet). Then prints the token endpoint and every
#      consumer key/secret pair this org now has, plus example curl
#      commands to redeem them for a token.
#
# Prerequisites — one-time IS setup, done once for the whole deployment, not
# per tenant (see scripts/setup_idp.sh, which automates all of this):
#   - An OIDC application ("API Portal" or similar) registered in the root
#     organization, shared to organizations with shareWithAllChildren
#     (POST /api/server/v1/applications/{appId}/share) — this covers every
#     organization created *after* the share call too, so it is not repeated
#     per tenant. That root application's own client_id/client_secret and id
#     are passed as ROOT_APP_CLIENT_ID / ROOT_APP_CLIENT_SECRET / ROOT_APP_ID.
#   - "dp_admin" and "dp_subscriber" roles must exist on the root application
#     as SHARED roles (Console > that application > Roles > Add Role, with
#     "Share with all organizations" on) — this is what makes them appear on
#     every organization's fragment application automatically, so step 1
#     only ever has to assign a user to them, never create them. Both names
#     must match keys in the Developer Portal's own
#     [api_portal.auth.authorization.portal_roles] config ("admin"/
#     "subscriber" respectively) for the resulting tokens to authorize
#     anything.
#   - ROOT_APP_CLIENT_ID must be authorized (Console > that application >
#     API Authorization, or POST .../authorized-apis) for:
#       * internal_org_application_mgt_view, internal_org_application_mgt_update,
#         internal_org_application_mgt_create on the "Application Management
#         API" (identifier /o/api/server/v1/applications) — configures each
#         organization's fragment application AND creates its own OAuth2
#         application (steps 1/2). The _create scope is a new prerequisite
#         as of this script's 6-step redesign — re-run setup_idp.sh (or
#         PATCH the authorization by hand) on an already-configured IS
#         instance to pick it up.
#       * internal_org_user_mgt_create, internal_org_user_mgt_list,
#         internal_org_user_mgt_view on the "SCIM2 Users API" (identifier
#         /o/scim2/Users) — creates and looks up the org's users (step 1).
#       * internal_org_role_mgt_view, internal_org_role_mgt_update on the
#         "SCIM2 Roles API" (identifier /o/scim2/Roles) — assigns roles to
#         those users (step 1).
#
# Usage:
#   ORG_NAME=acme ROOT_APP_CLIENT_ID=... ROOT_APP_CLIENT_SECRET=... ROOT_APP_ID=... \
#     ./scripts/onboard-tenant.sh
#
# SAMPLE_DIR (optional, default: ORG_NAME) names which resources/samples/
# subdirectory to seed from — set it when the IS organization name can't (or
# shouldn't) match the sample bundle's own directory name, e.g. WSO2 IS
# refuses to reuse a deleted organization's name (deleting an organization
# only deactivates its underlying tenant record, it does not free the name):
#   ORG_NAME=acme-demo SAMPLE_DIR=acme ROOT_APP_CLIENT_ID=... ... \
#     ./scripts/onboard-tenant.sh
#
# ORG_ADMIN_PASSWORD / ORG_USER_PASSWORD (optional) pin the two users'
# passwords instead of generating (and re-printing, on every run without
# one) a random one each time.
#
# KEY_MANAGER_HANDLE (default "wso2-is") names the portal-side key manager
# step 5 configures. IS_INTERNAL_URL (default "https://host.docker.internal:9443")
# is that key manager's token endpoint's HOST — it must be reachable from the
# PORTAL CONTAINER (not this script, not a browser), a different
# reachability requirement than every other *_URL var below.
#
# IS_URL / API_PORTAL_URL / IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD override the
# defaults below. Safe to re-run: an existing organization/user/application/
# plan/key manager is reused rather than duplicated, and re-running never
# demotes or removes anything a previous run created.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IS_URL="${IS_URL:-https://localhost:9443}"
IS_ADMIN_USERNAME="${IS_ADMIN_USERNAME:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
API_PORTAL_URL="${API_PORTAL_URL:-https://localhost:9543}"
API_PORTAL_API_BASE="/api-portal/api/v0.9"
IS_INTERNAL_URL="${IS_INTERNAL_URL:-https://host.docker.internal:9443}"
KEY_MANAGER_HANDLE="${KEY_MANAGER_HANDLE:-wso2-is}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
    SYM_OK="✓"; SYM_SKIP="•"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
    SYM_OK="OK"; SYM_SKIP="-"
fi

log() { echo "${C_DIM}[onboard-tenant]${C_RESET} $*"; }
fail() { echo "${C_RED}[onboard-tenant] ERROR:${C_RESET} $*" >&2; exit 1; }
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

command -v curl    >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq      >/dev/null 2>&1 || fail "jq is required but not found on PATH."
command -v openssl >/dev/null 2>&1 || fail "openssl is required but not found on PATH."

[ -n "${ORG_NAME:-}" ] || fail "ORG_NAME is required — the organization to onboard (e.g. acme)."
[ -n "${ROOT_APP_CLIENT_ID:-}" ] || fail "ROOT_APP_CLIENT_ID is required — the root-org API Portal application's client ID."
[ -n "${ROOT_APP_CLIENT_SECRET:-}" ] || fail "ROOT_APP_CLIENT_SECRET is required."
[ -n "${ROOT_APP_ID:-}" ] || fail "ROOT_APP_ID is required — the root-org API Portal application's id (not its client ID)."

SAMPLES_ROOT="$THIS_DIR/../resources/samples"
[ -d "$SAMPLES_ROOT" ] || SAMPLES_ROOT="$THIS_DIR/../samples"
[ -d "$SAMPLES_ROOT" ] || fail "no samples directory found next to $THIS_DIR/.."
# SAMPLE_DIR (optional) decouples which sample bundle gets seeded from the IS
# organization name — e.g. ORG_NAME=acme-demo SAMPLE_DIR=acme onboards an org
# named "acme-demo" using acme's own apis/mcps/plans/applications. Defaults
# to ORG_NAME, so the common case (they match) needs nothing extra.
SAMPLE_DIR="${SAMPLE_DIR:-$ORG_NAME}"
ORG_SAMPLE_DIR="$SAMPLES_ROOT/$SAMPLE_DIR"
[ -d "$ORG_SAMPLE_DIR" ] || fail "no sample directory '$SAMPLE_DIR' at $ORG_SAMPLE_DIR"

PLANS_YAML="$ORG_SAMPLE_DIR/subscription-plans.yaml"
APPLICATIONS_YAML="$ORG_SAMPLE_DIR/applications.yaml"

# Whether this org gets a subscriber user, portal applications and
# subscriptions is derived entirely from whether applications.yaml lists
# anything — no separate flag needed. ("public" in the bundled samples has
# an empty applications.yaml and ends up with only its dp_admin user.)
HAS_APPLICATIONS=0
if [ -f "$APPLICATIONS_YAML" ] && grep -q '^  - metadata:' "$APPLICATIONS_YAML"; then
    HAS_APPLICATIONS=1
fi

# --- Step 1a: register the organization (idempotent) -------------------------

log "Registering organization '$ORG_NAME' in WSO2 IS at $IS_URL ..."
# orgHandle is set explicitly to ORG_NAME — left unset, IS silently defaults it
# to the org's own UUID instead, which breaks org discovery/SSO login entirely
# (org_handle.do, the fidp=OrganizationSSO discovery prompt, and org=<handle>
# on /oauth2/authorize all expect a human-readable handle, not a UUID — this
# was found and confirmed by testing directly against a running instance, not
# from documentation alone). orgHandle is immutable once set — there is no
# update path for it (PATCH .../organizations/{id} with path "/orgHandle"
# 400s: "Provided path :/orgHandle is invalid") — so an org created without it
# explicit can only be fixed by deleting and recreating it (cleanup-tenant.sh
# + a re-run of this script), not by patching in place.
CREATE_STATUS=$(curl -sk -o /tmp/onboard-tenant-org.$$.json -w "%{http_code}" \
    -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" -X POST "$IS_URL/api/server/v1/organizations" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$ORG_NAME\", \"orgHandle\": \"$ORG_NAME\", \"description\": \"Tenant $ORG_NAME\"}")
CREATE_BODY=$(cat /tmp/onboard-tenant-org.$$.json); rm -f /tmp/onboard-tenant-org.$$.json

if [ "$CREATE_STATUS" = "201" ]; then
    ORG_ID=$(echo "$CREATE_BODY" | jq -r '.id')
    log "  ${C_GREEN}${SYM_OK}${C_RESET} created (id: $ORG_ID)"
else
    # IS reports a name already taken by an existing organization as 400
    # ORG-60076, not 409 — so any non-201 falls back to a lookup-by-name rather
    # than matching on a specific status code, and only fails if that also
    # comes up empty.
    ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
        "$IS_URL/api/server/v1/organizations?filter=name+eq+$(urlencode "$ORG_NAME")" \
        | jq -r '.organizations[0].id // empty')
    if [ -n "$ORG_ID" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists (id: $ORG_ID)"
    else
        fail "failed to create organization '$ORG_NAME' (HTTP $CREATE_STATUS): $CREATE_BODY"
    fi
fi

# --- Step 1b: configure the organization's fragment application (idempotent) -
# A freshly shared application's per-organization copy starts with none of
# this — password grant disabled, opaque access tokens, no claim mappings —
# so every organization needs it applied once. Re-running always PUTs/PATCHes
# the same target state, so this is safe on an already-configured org too.
#
# The same org-scoped token (APP_MGT_TOKEN, obtained once below) is reused
# for step 2's org-owned OAuth2 application, since both need the same
# Application Management API scopes.

log "Locating '$ORG_NAME''s copy of the API Portal application ..."
ROOT_ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ORG_ID" | jq -r '.parent.id // empty')
[ -n "$ROOT_ORG_ID" ] || fail "could not resolve '$ORG_NAME''s parent organization."

FRAGMENT_APP_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ROOT_ORG_ID/applications/$ROOT_APP_ID/shared-apps" \
    | jq -r --arg org "$ORG_ID" '.sharedApplications[]? | select(.organizationId==$org) | .applicationId')
[ -n "$FRAGMENT_APP_ID" ] || fail "the API Portal application ($ROOT_APP_ID) is not shared to '$ORG_NAME' — share it first: POST $IS_URL/api/server/v1/applications/$ROOT_APP_ID/share with {\"shareWithAllChildren\": true}."
log "  found (application id: $FRAGMENT_APP_ID)"

log "Obtaining an org-scoped admin token to configure applications ..."
APP_MGT_SCOPES="internal_org_application_mgt_view internal_org_application_mgt_update internal_org_application_mgt_create"
CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=$APP_MGT_SCOPES" \
    | jq -r '.access_token // empty')
[ -n "$CC_TOKEN" ] || fail "failed to obtain a client_credentials token — check ROOT_APP_CLIENT_ID/ROOT_APP_CLIENT_SECRET."
APP_MGT_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=organization_switch&token=$CC_TOKEN&switching_organization=$ORG_ID&scope=$APP_MGT_SCOPES" \
    | jq -r '.access_token // empty')
[ -n "$APP_MGT_TOKEN" ] || fail "failed to switch into '$ORG_NAME' — is ROOT_APP_CLIENT_ID authorized for internal_org_application_mgt_view/update/create on the Application Management API (/o/api/server/v1/applications)?"

log "Configuring grant types and access token attributes ..."
CURRENT_OIDC=$(curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc")
FRAGMENT_CLIENT_ID=$(echo "$CURRENT_OIDC" | jq -r '.clientId // empty')
FRAGMENT_CLIENT_SECRET=$(echo "$CURRENT_OIDC" | jq -r '.clientSecret // empty')
[ -n "$FRAGMENT_CLIENT_ID" ] && [ -n "$FRAGMENT_CLIENT_SECRET" ] || fail "could not read '$ORG_NAME''s fragment application's own OIDC client credentials."

# Merged onto whatever is already configured — preserves callbackURLs and
# anything an operator customized — rather than replaced outright: password
# and refresh_token are added to the existing grant list, not assumed to be
# the only ones.
MERGED_OIDC=$(echo "$CURRENT_OIDC" | jq '
    .grantTypes = ((.grantTypes // []) + ["password", "refresh_token"] | unique) |
    .accessToken.type = "JWT" |
    .accessToken.accessTokenAttributes = ["roles", "groups"]
')
OIDC_STATUS=$(curl -sk -o /tmp/onboard-tenant-oidc.$$.json -w "%{http_code}" \
    -H "Authorization: Bearer $APP_MGT_TOKEN" -X PUT \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc" \
    -H "Content-Type: application/json" -d "$MERGED_OIDC")
OIDC_BODY=$(cat /tmp/onboard-tenant-oidc.$$.json); rm -f /tmp/onboard-tenant-oidc.$$.json
[ "$OIDC_STATUS" = "200" ] || fail "failed to update OIDC config for '$ORG_NAME' (HTTP $OIDC_STATUS): $OIDC_BODY"
log "  ${C_GREEN}${SYM_OK}${C_RESET} grant types + access token configured"

# The Developer Portal reads firstName/lastName/email/roles out of the token,
# not out of a separate profile lookup — without these mappings the user shows
# up logged in but nameless, and (for "roles") authorization fails outright.
log "Configuring profile claim mappings ..."
CLAIM_STATUS=$(curl -sk -o /tmp/onboard-tenant-claims.$$.json -w "%{http_code}" \
    -H "Authorization: Bearer $APP_MGT_TOKEN" -X PATCH \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID" \
    -H "Content-Type: application/json" \
    -d '{
        "claimConfiguration": {
            "dialect": "CUSTOM",
            "claimMappings": [
                {"applicationClaim": "http://wso2.org/claims/roles", "localClaim": {"uri": "http://wso2.org/claims/roles"}},
                {"applicationClaim": "http://wso2.org/claims/username", "localClaim": {"uri": "http://wso2.org/claims/username"}},
                {"applicationClaim": "http://wso2.org/claims/emailaddress", "localClaim": {"uri": "http://wso2.org/claims/emailaddress"}},
                {"applicationClaim": "http://wso2.org/claims/givenname", "localClaim": {"uri": "http://wso2.org/claims/givenname"}},
                {"applicationClaim": "http://wso2.org/claims/lastname", "localClaim": {"uri": "http://wso2.org/claims/lastname"}}
            ],
            "requestedClaims": [
                {"claim": {"uri": "http://wso2.org/claims/roles"}, "mandatory": false},
                {"claim": {"uri": "http://wso2.org/claims/username"}, "mandatory": false},
                {"claim": {"uri": "http://wso2.org/claims/emailaddress"}, "mandatory": false},
                {"claim": {"uri": "http://wso2.org/claims/givenname"}, "mandatory": false},
                {"claim": {"uri": "http://wso2.org/claims/lastname"}, "mandatory": false}
            ],
            "subject": {"includeUserDomain": false, "includeTenantDomain": false, "useMappedLocalSubject": true, "mappedLocalSubjectMandatory": false},
            "role": {"includeUserDomain": true, "claim": {"uri": "http://wso2.org/claims/roles"}}
        }
    }')
CLAIM_BODY=$(cat /tmp/onboard-tenant-claims.$$.json); rm -f /tmp/onboard-tenant-claims.$$.json
[ "$CLAIM_STATUS" = "200" ] || fail "failed to update claim configuration for '$ORG_NAME' (HTTP $CLAIM_STATUS): $CLAIM_BODY"
log "  ${C_GREEN}${SYM_OK}${C_RESET} claim mappings configured"

# --- Step 2: this organization's own OAuth2 application (idempotent) --------
# Created directly inside the sub-org (not shared from the root) — this is
# what an external caller (or this script's own step 6 curl) uses to get a
# token, and what step 5 links to a portal application via generate-keys.
# client_credentials is the only grant it needs for that.

ORG_APP_NAME="${ORG_NAME}-key-manager"
log "Creating '$ORG_NAME''s own OAuth2 application ('$ORG_APP_NAME') in IS ..."

ORG_APP_ID=$(curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" \
    "$IS_URL/o/api/server/v1/applications?limit=100" \
    | jq -r --arg n "$ORG_APP_NAME" '.applications[]? | select(.name==$n) | .id' | head -1)

if [ -n "$ORG_APP_ID" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists (id: $ORG_APP_ID)"
else
    # POST /applications returns 201 with an EMPTY body — the new app's id is
    # only in the Location header (confirmed directly; see setup_idp.sh's own
    # note on this for the root-org equivalent).
    # accessToken is deliberately NOT included here — embedding it in this
    # create-time body 500s (APP-65006), confirmed by direct reproduction.
    # JWT is applied afterward instead, by the exact same convergence check
    # this runs unconditionally below for an already-existing app too.
    ORG_APP_CREATE=$(curl -sk -D - -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $APP_MGT_TOKEN" -X POST "$IS_URL/o/api/server/v1/applications" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$ORG_APP_NAME\", \"description\": \"Key manager OAuth2 client for $ORG_NAME\", \"templateId\": \"custom-application-oidc\",
             \"inboundProtocolConfiguration\": {\"oidc\": {\"grantTypes\": [\"client_credentials\"], \"publicClient\": false}}}")
    ORG_APP_CREATE_STATUS="${ORG_APP_CREATE: -3}"
    ORG_APP_CREATE_HEADERS="${ORG_APP_CREATE%???}"
    [ "$ORG_APP_CREATE_STATUS" = "201" ] || fail "failed to create '$ORG_NAME''s OAuth2 application (HTTP $ORG_APP_CREATE_STATUS)."
    ORG_APP_ID=$(echo "$ORG_APP_CREATE_HEADERS" | grep -i '^location:' | sed -E 's#.*/applications/##; s#[[:space:]\r]*$##')
    [ -n "$ORG_APP_ID" ] || fail "application created (HTTP 201) but could not parse its id from the Location header."
    log "  ${C_GREEN}${SYM_OK}${C_RESET} created (id: $ORG_APP_ID)"
fi

# PUT .../inbound-protocols/oidc returns 200 with an EMPTY body — a separate
# GET is required to read back clientId/clientSecret, same story as the app
# creation above.
ORG_APP_OIDC=$(curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" \
    "$IS_URL/o/api/server/v1/applications/$ORG_APP_ID/inbound-protocols/oidc")

# Converges an app that already existed from before this fix (accessToken.type
# defaults to opaque, not JWT, unless requested — the create body above only
# started requesting JWT once this check was added) to JWT too, so a re-run
# fixes a previously-onboarded org's client instead of leaving it opaque
# forever.
if [ "$(echo "$ORG_APP_OIDC" | jq -r '.accessToken.type // empty')" != "JWT" ]; then
    log "  converging '$ORG_APP_NAME' to JWT access tokens ..."
    MERGED_ORG_OIDC=$(echo "$ORG_APP_OIDC" | jq '.accessToken.type = "JWT"')
    ORG_OIDC_STATUS=$(curl -sk -o /tmp/onboard-tenant-orgoidc.$$.json -w "%{http_code}" \
        -H "Authorization: Bearer $APP_MGT_TOKEN" -X PUT \
        "$IS_URL/o/api/server/v1/applications/$ORG_APP_ID/inbound-protocols/oidc" \
        -H "Content-Type: application/json" -d "$MERGED_ORG_OIDC")
    ORG_OIDC_BODY=$(cat /tmp/onboard-tenant-orgoidc.$$.json); rm -f /tmp/onboard-tenant-orgoidc.$$.json
    [ "$ORG_OIDC_STATUS" = "200" ] || fail "failed to switch '$ORG_APP_NAME' to JWT access tokens (HTTP $ORG_OIDC_STATUS): $ORG_OIDC_BODY"
    ORG_APP_OIDC=$(curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" \
        "$IS_URL/o/api/server/v1/applications/$ORG_APP_ID/inbound-protocols/oidc")
fi

ORG_CLIENT_ID=$(echo "$ORG_APP_OIDC" | jq -r '.clientId // empty')
ORG_CLIENT_SECRET=$(echo "$ORG_APP_OIDC" | jq -r '.clientSecret // empty')
[ -n "$ORG_CLIENT_ID" ] && [ -n "$ORG_CLIENT_SECRET" ] || fail "could not read '$ORG_NAME''s OAuth2 application's own client credentials."
log "  client_id: $ORG_CLIENT_ID"

# --- Step 1c: create the organization's users and obtain their tokens -------
# Uses the SCIM2 org-user-mgt API at /t/carbon.super/o/scim2/Users — note the
# literal "carbon.super": the target organization comes from the *token's*
# org context (organization_switch below), not from any org id/handle in the
# URL. Confirmed against WSO2 IS 7.1's own org-user-mgt API docs
# (apis/organization-apis/scim2/scim2-org-user-mgt/), not just by trial.

USER_MGT_SCOPES="internal_org_user_mgt_create internal_org_user_mgt_list internal_org_user_mgt_view internal_org_user_mgt_update internal_org_role_mgt_view internal_org_role_mgt_update"
USER_MGT_CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=$USER_MGT_SCOPES" \
    | jq -r '.access_token // empty')
[ -n "$USER_MGT_CC_TOKEN" ] || fail "failed to obtain a client_credentials token for user/role management."
USER_MGT_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=organization_switch&token=$USER_MGT_CC_TOKEN&switching_organization=$ORG_ID&scope=$USER_MGT_SCOPES" \
    | jq -r '.access_token // empty')
[ -n "$USER_MGT_TOKEN" ] || fail "failed to switch into '$ORG_NAME' for user/role management — is ROOT_APP_CLIENT_ID authorized for the SCIM2 Users API and SCIM2 Roles API scopes listed in the header?"

# Assigns $2 (a user id) to the role named $1 on this org's fragment app,
# idempotently. Looks the role up fresh every call rather than caching, since
# nothing here relies on it being called more than once per user anyway, and
# a fresh lookup is what earlier versions of this script needed for their
# (now-removed) role-convergence step — kept for that same safety margin.
ensure_role_member() {
    local role_name="$1" user_id="$2"
    local roles_list role_id already_member status body
    roles_list=$(curl -sk "$IS_URL/t/carbon.super/o/scim2/v2/Roles" -H "Authorization: Bearer $USER_MGT_TOKEN")
    role_id=$(echo "$roles_list" | jq -r --arg role "$role_name" --arg app "$FRAGMENT_APP_ID" \
        '.Resources[]? | select(.displayName==$role and .audience.value==$app) | .id // empty')
    [ -n "$role_id" ] || fail "role '$role_name' not found on '$ORG_NAME''s fragment application ($FRAGMENT_APP_ID) — it must be a SHARED role on the root application (see setup_idp.sh)."
    already_member=$(echo "$roles_list" | jq -r --arg role_id "$role_id" --arg user_id "$user_id" \
        '.Resources[]? | select(.id==$role_id) | .users[]? | select(.value==$user_id) | .value // empty')
    if [ -n "$already_member" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already assigned '$role_name'"
        return
    fi
    status=$(curl -sk -o /tmp/onboard-tenant-role.$$.json -w "%{http_code}" \
        -X PATCH "$IS_URL/t/carbon.super/o/scim2/v2/Roles/$role_id" \
        -H "Authorization: Bearer $USER_MGT_TOKEN" -H "Content-Type: application/json" \
        -d "{\"schemas\": [\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"], \"Operations\": [{\"op\": \"add\", \"path\": \"users\", \"value\": [{\"value\": \"$user_id\"}]}]}")
    body=$(cat /tmp/onboard-tenant-role.$$.json); rm -f /tmp/onboard-tenant-role.$$.json
    [ "$status" = "200" ] || fail "failed to assign role '$role_name' to user $user_id (HTTP $status): $body"
    log "  ${C_GREEN}${SYM_OK}${C_RESET} assigned '$role_name'"
}

# Creates (or reuses) user $1 with role $3, assigns the role, and sets
# globals PROVISIONED_USER_ID / PROVISIONED_PASSWORD / PROVISIONED_GENERATED
# — a function return-by-echo would collide with log()'s own stdout output,
# so side-effect globals are used instead (same convention this script
# already used for ORG_ID/FRAGMENT_APP_ID/etc.).
provision_user() {
    local username="$1" password_in="$2" role="$3"
    PROVISIONED_GENERATED=0
    PROVISIONED_PASSWORD="$password_in"
    if [ -z "$PROVISIONED_PASSWORD" ]; then
        PROVISIONED_PASSWORD="Aa1$(openssl rand -hex 6)!"
        PROVISIONED_GENERATED=1
    fi

    log "Provisioning user '$username' (role: $role) in '$ORG_NAME' ..."
    local existing_id
    existing_id=$(curl -sk "$IS_URL/t/carbon.super/o/scim2/Users?filter=userName+eq+$(urlencode "$username")" \
        -H "Authorization: Bearer $USER_MGT_TOKEN" | jq -r '.Resources[0].id // empty')

    if [ -n "$existing_id" ]; then
        PROVISIONED_USER_ID="$existing_id"
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists (id: $PROVISIONED_USER_ID)"
        if [ "$PROVISIONED_GENERATED" = "1" ]; then
            # No password was supplied, so there's no way to know the
            # password this existing account already has — reset it to the
            # freshly generated one so the token step below always works.
            # This means re-running without an *_PASSWORD override rotates
            # it every time; pass one explicitly to keep it stable.
            local reset_status reset_body
            reset_status=$(curl -sk -o /tmp/onboard-tenant-pwreset.$$.json -w "%{http_code}" \
                -X PATCH "$IS_URL/t/carbon.super/o/scim2/Users/$PROVISIONED_USER_ID" \
                -H "Authorization: Bearer $USER_MGT_TOKEN" -H "Content-Type: application/json" \
                -d "{\"schemas\": [\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"], \"Operations\": [{\"op\": \"replace\", \"value\": {\"password\": \"$PROVISIONED_PASSWORD\"}}]}")
            reset_body=$(cat /tmp/onboard-tenant-pwreset.$$.json); rm -f /tmp/onboard-tenant-pwreset.$$.json
            [ "$reset_status" = "200" ] || fail "failed to reset password for existing user '$username' (HTTP $reset_status): $reset_body"
            log "  ${C_YELLOW}password reset (no password supplied — pass one to keep it stable across runs)${C_RESET}"
        fi
    else
        local create_resp
        create_resp=$(curl -sk -X POST "$IS_URL/t/carbon.super/o/scim2/Users" \
            -H "Authorization: Bearer $USER_MGT_TOKEN" -H "Content-Type: application/json" \
            -d "{\"schemas\": [], \"userName\": \"$username\", \"password\": \"$PROVISIONED_PASSWORD\"}")
        PROVISIONED_USER_ID=$(echo "$create_resp" | jq -r '.id // empty')
        [ -n "$PROVISIONED_USER_ID" ] || fail "failed to create user '$username': $create_resp"
        log "  ${C_GREEN}${SYM_OK}${C_RESET} created (id: $PROVISIONED_USER_ID)"
    fi

    ensure_role_member "$role" "$PROVISIONED_USER_ID"
}

ORG_ADMIN_USERNAME="${ORG_NAME}admin"
provision_user "$ORG_ADMIN_USERNAME" "${ORG_ADMIN_PASSWORD:-}" "dp_admin"
ORG_ADMIN_PASSWORD="$PROVISIONED_PASSWORD"
ORG_ADMIN_PASSWORD_GENERATED="$PROVISIONED_GENERATED"

ORG_USER_USERNAME=""
if [ "$HAS_APPLICATIONS" = "1" ]; then
    ORG_USER_USERNAME="${ORG_NAME}user"
    provision_user "$ORG_USER_USERNAME" "${ORG_USER_PASSWORD:-}" "dp_subscriber"
    ORG_USER_PASSWORD="$PROVISIONED_PASSWORD"
    ORG_USER_PASSWORD_GENERATED="$PROVISIONED_GENERATED"
fi

log "Credentials for '$ORG_NAME' (save these — generated passwords are shown once):"
log "  ${C_BOLD}$ORG_ADMIN_USERNAME${C_RESET} / $ORG_ADMIN_PASSWORD (dp_admin)"
[ -n "$ORG_USER_USERNAME" ] && log "  ${C_BOLD}$ORG_USER_USERNAME${C_RESET} / $ORG_USER_PASSWORD (dp_subscriber)"

log "Obtaining access tokens ..."
ADMIN_TOKEN=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
    -u "$FRAGMENT_CLIENT_ID:$FRAGMENT_CLIENT_SECRET" \
    -d "grant_type=password&username=$(urlencode "$ORG_ADMIN_USERNAME")&password=$(urlencode "$ORG_ADMIN_PASSWORD")&scope=openid" \
    | jq -r '.access_token // empty')
[ -n "$ADMIN_TOKEN" ] || fail "failed to obtain an access token for '$ORG_ADMIN_USERNAME'."

USER_TOKEN=""
if [ -n "$ORG_USER_USERNAME" ]; then
    USER_TOKEN=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
        -u "$FRAGMENT_CLIENT_ID:$FRAGMENT_CLIENT_SECRET" \
        -d "grant_type=password&username=$(urlencode "$ORG_USER_USERNAME")&password=$(urlencode "$ORG_USER_PASSWORD")&scope=openid" \
        | jq -r '.access_token // empty')
    [ -n "$USER_TOKEN" ] || fail "failed to obtain an access token for '$ORG_USER_USERNAME'."
fi
log "  ${C_GREEN}${SYM_OK}${C_RESET} tokens acquired"

# --- Step 3: seed subscription plans from subscription-plans.yaml -----------
# Design-mode schema (planName/displayName/description/requestCount) mapped
# to the real REST schema. PUT is an upsert (200 existed / 201 created) — an
# array body is a silent no-op here (apiMetadataService.js gates bulk
# creation behind organization.autoCreateSubscriptionPlans, on by default),
# so one request per plan, never a batch.

log "Seeding subscription plans from $PLANS_YAML ..."
ADMIN_AUTH_HEADER="Authorization: Bearer $ADMIN_TOKEN"

PLAN_LINES=$(awk '
    /^- planName:/ {
        if (planName != "") print planName "|" displayName "|" description "|" requestCount
        planName=$0; sub(/^- planName: */, "", planName)
        displayName=""; description=""; requestCount=""
        next
    }
    /^  displayName:/  { displayName=$0;  sub(/^  displayName: */,  "", displayName) }
    /^  description:/  { description=$0;  sub(/^  description: */,  "", description) }
    /^  requestCount:/  { requestCount=$0; sub(/^  requestCount: */, "", requestCount) }
    END { if (planName != "") print planName "|" displayName "|" description "|" requestCount }
' "$PLANS_YAML" 2>/dev/null || true)

ORG_PLANS=""
if [ -z "$PLAN_LINES" ]; then
    # No plans declared for this org (e.g. "public") — leave ORG_PLANS empty
    # rather than substituting a fallback list. Step 4 below only rewrites a
    # sample's subscriptionPlans: block when PLAN_OVERRIDE is non-empty, so
    # this org's samples are seeded exactly as authored (including a
    # deliberately emptied subscriptionPlans: block, i.e. "no plans at all")
    # instead of having some other plan set silently injected into them.
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} no plans declared — samples will be seeded with whatever subscriptionPlans they already declare (org keeps its auto-seeded defaults available, but nothing is forced onto any sample)"
else
    while IFS='|' read -r plan_id display_name description request_count; do
        [ -n "$plan_id" ] || continue
        display_name="${display_name:-$plan_id}"

        local_limits='[]'
        if [ -n "$request_count" ]; then
            local_limits=$(jq -cn --argjson rc "$request_count" \
                '[{limitType:"REQUEST_COUNT", timeUnit:"MINUTE", timeAmount:1, limitCount:$rc}]')
        fi
        plan_body=$(jq -cn --arg id "$plan_id" --arg dn "$display_name" --arg desc "$description" --argjson limits "$local_limits" \
            '{id:$id, displayName:$dn, description:$desc, limits:$limits}')

        plan_status=$(curl -sk -o /tmp/onboard-tenant-plan.$$.json -w "%{http_code}" \
            -X PUT "$API_PORTAL_URL$API_PORTAL_API_BASE/subscription-plans" \
            -H "$ADMIN_AUTH_HEADER" -H "Content-Type: application/json" \
            -d "$plan_body")
        plan_body_resp=$(cat /tmp/onboard-tenant-plan.$$.json); rm -f /tmp/onboard-tenant-plan.$$.json
        if [ "$plan_status" = "200" ] || [ "$plan_status" = "201" ]; then
            log "  ${C_GREEN}${SYM_OK}${C_RESET} $plan_id"
        else
            fail "failed to upsert subscription plan '$plan_id' for '$ORG_NAME' (HTTP $plan_status): $plan_body_resp"
        fi

        ORG_PLANS="${ORG_PLANS:+$ORG_PLANS|}$plan_id"
    done <<< "$PLAN_LINES"
fi

# --- Step 4: seed this organization's APIs and MCP servers ------------------
# Delegates to seed-samples.sh, pointed at this org's own directory and told
# to rewrite every sample's subscriptionPlans: block to $ORG_PLANS — so a
# seeded API never advertises a plan that doesn't exist in this org (this is
# also what resolves the REPLACE_WITH_PLATFORM_API_PLAN_ID placeholders that
# some bundled samples ship with).

log "Deploying '$ORG_NAME''s APIs and MCP servers from $ORG_SAMPLE_DIR ..."
ACCESS_TOKEN="$ADMIN_TOKEN" SAMPLES_DIR="$ORG_SAMPLE_DIR" PLAN_OVERRIDE="$ORG_PLANS" \
    API_PORTAL_URL="$API_PORTAL_URL" "$THIS_DIR/seed-samples.sh"

# --- Step 5a: configure a key manager pointing at this organization's own IS
# This portal's "key manager" is deliberately thin (see
# docs/administer/key-manager-integration.md): just a displayName + a token
# endpoint it proxies client_credentials requests to — the portal never
# performs Dynamic Client Registration and never stores a client secret.
#
# Since every organization here already *is* its own WSO2 IS sub-org, the
# natural key manager to register is that org's own org-scoped token
# endpoint — no external IDP needed. IS_INTERNAL_URL (not IS_URL) is used
# for the endpoint value itself: this URL is called by the PORTAL CONTAINER
# at proxy time (oauthTokenService.js, server-to-server), not by this
# script or a browser, so it needs the container-reachable hostname
# (host.docker.internal), the same reasoning as config.toml's
# auth.idp.token_url — see docs/administer/wso2-is-setup.md Section 4.

log "Configuring key manager '$KEY_MANAGER_HANDLE' for '$ORG_NAME' ..."
TARGET_TOKEN_ENDPOINT="$IS_INTERNAL_URL/o/$ORG_ID/oauth2/token"
EXISTING_KM=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/key-managers?limit=100" \
    -H "$ADMIN_AUTH_HEADER" | jq -c --arg h "$KEY_MANAGER_HANDLE" '.list[]? | select(.id==$h)')
EXISTING_TOKEN_ENDPOINT=$(echo "$EXISTING_KM" | jq -r '.tokenEndpoint // empty')

if [ -z "$EXISTING_KM" ]; then
    KM_STATUS=$(curl -sk -o /tmp/onboard-tenant-km.$$.json -w "%{http_code}" -X POST \
        "$API_PORTAL_URL$API_PORTAL_API_BASE/key-managers" \
        -H "$ADMIN_AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"id\": \"$KEY_MANAGER_HANDLE\", \"displayName\": \"WSO2 IS ($ORG_NAME)\", \"tokenEndpoint\": \"$TARGET_TOKEN_ENDPOINT\"}")
    KM_BODY=$(cat /tmp/onboard-tenant-km.$$.json); rm -f /tmp/onboard-tenant-km.$$.json
    if [ "$KM_STATUS" = "201" ]; then
        log "  ${C_GREEN}${SYM_OK}${C_RESET} created (token endpoint: $TARGET_TOKEN_ENDPOINT)"
    elif [ "$KM_STATUS" = "409" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists"
    else
        fail "failed to create key manager for '$ORG_NAME' (HTTP $KM_STATUS): $KM_BODY"
    fi
elif [ "$EXISTING_TOKEN_ENDPOINT" = "$TARGET_TOKEN_ENDPOINT" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists, token endpoint up to date"
else
    # This org was almost certainly torn down and recreated in IS since this
    # key manager was first configured — the portal's own key_managers row
    # persists (portal-side org identity is the org NAME, stable across IS
    # recreation; see cleanup-tenant.sh's own header notes on this), but a
    # freshly recreated org gets a brand-new IS org UUID, so the OLD stored
    # token endpoint now points at a URL that no longer exists. Reconciled
    # here rather than left stale and silently broken.
    log "  ${C_YELLOW}stale token endpoint (was: $EXISTING_TOKEN_ENDPOINT) — updating${C_RESET}"
    KM_UPDATE_STATUS=$(curl -sk -o /tmp/onboard-tenant-km.$$.json -w "%{http_code}" -X PUT \
        "$API_PORTAL_URL$API_PORTAL_API_BASE/key-managers/$KEY_MANAGER_HANDLE" \
        -H "$ADMIN_AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"tokenEndpoint\": \"$TARGET_TOKEN_ENDPOINT\"}")
    KM_UPDATE_BODY=$(cat /tmp/onboard-tenant-km.$$.json); rm -f /tmp/onboard-tenant-km.$$.json
    [ "$KM_UPDATE_STATUS" = "200" ] || fail "failed to update key manager for '$ORG_NAME' (HTTP $KM_UPDATE_STATUS): $KM_UPDATE_BODY"
    log "  ${C_GREEN}${SYM_OK}${C_RESET} updated (token endpoint: $TARGET_TOKEN_ENDPOINT)"
fi

# --- Step 5b: applications from applications.yaml, linked to step 2's client
# Owned by the subscriber user (USER_TOKEN) — skipped entirely when this org
# has none declared.

APP_KEY_MAPPINGS=""
if [ "$HAS_APPLICATIONS" = "1" ]; then
    log "Creating applications from $APPLICATIONS_YAML for '$ORG_NAME' ..."
    USER_AUTH_HEADER="Authorization: Bearer $USER_TOKEN"

    APPLICATION_LINES=$(awk '
        /^  - metadata:$/ {
            if (name != "") print name "|" displayName "|" description
            name=""; displayName=""; description=""
            next
        }
        /^      name:/         { name=$0;        sub(/^      name: */,        "", name) }
        /^      displayName:/  { displayName=$0;  sub(/^      displayName: */, "", displayName) }
        /^      description:/  { description=$0;  sub(/^      description: */, "", description) }
        END { if (name != "") print name "|" displayName "|" description }
    ' "$APPLICATIONS_YAML")

    while IFS='|' read -r app_id display_name description; do
        [ -n "$app_id" ] || continue
        display_name="${display_name:-$app_id}"

        app_body=$(jq -cn --arg id "$app_id" --arg dn "$display_name" --arg desc "$description" \
            '{id:$id, displayName:$dn, description:$desc}')
        app_status=$(curl -sk -o /tmp/onboard-tenant-app.$$.json -w "%{http_code}" -X POST \
            "$API_PORTAL_URL$API_PORTAL_API_BASE/applications" \
            -H "$USER_AUTH_HEADER" -H "Content-Type: application/json" \
            -d "$app_body")
        app_body_resp=$(cat /tmp/onboard-tenant-app.$$.json); rm -f /tmp/onboard-tenant-app.$$.json

        if [ "$app_status" = "201" ]; then
            log "  ${C_GREEN}${SYM_OK}${C_RESET} $app_id created"
        elif [ "$app_status" = "409" ]; then
            log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $app_id already exists"
        else
            fail "failed to create application '$app_id' for '$ORG_NAME' (HTTP $app_status): $app_body_resp"
        fi

        # Link this org's own OAuth2 client to the application. Idempotent:
        # if it's already mapped to this key manager, generate-keys 409s.
        gk_status=$(curl -sk -o /tmp/onboard-tenant-gk.$$.json -w "%{http_code}" -X POST \
            "$API_PORTAL_URL$API_PORTAL_API_BASE/applications/$app_id/generate-keys" \
            -H "$USER_AUTH_HEADER" -H "Content-Type: application/json" \
            -d "{\"keyManager\": \"$KEY_MANAGER_HANDLE\", \"consumerKey\": \"$ORG_CLIENT_ID\", \"type\": \"PRODUCTION\"}")
        gk_body=$(cat /tmp/onboard-tenant-gk.$$.json); rm -f /tmp/onboard-tenant-gk.$$.json
        if [ "$gk_status" = "200" ]; then
            key_mapping_id=$(echo "$gk_body" | jq -r '.keyMappingId // empty')
            log "    ${C_GREEN}${SYM_OK}${C_RESET} linked to client_id $ORG_CLIENT_ID"
            [ -n "$key_mapping_id" ] && APP_KEY_MAPPINGS="${APP_KEY_MAPPINGS:+$APP_KEY_MAPPINGS$'\n'}$app_id|$key_mapping_id"
        elif [ "$gk_status" = "409" ]; then
            log "    ${C_YELLOW}${SYM_SKIP}${C_RESET} already linked"
        else
            fail "failed to link client_id to application '$app_id' (HTTP $gk_status): $gk_body"
        fi
    done <<< "$APPLICATION_LINES"

    # --- Step 5c: subscribe the subscriber user to every deployed API -------
    # MCP servers are deliberately excluded — GET /apis never returns them
    # (they live under /mcp-servers), and subscriptions to MCP servers are
    # not supported yet. Uses the first plan in this org's own plan set
    # (e.g. Gold for acme, Silver for railco). Skipped outright if this org
    # declared no plans at all (ORG_PLANS empty) — nothing to subscribe at.
    if [ -z "$ORG_PLANS" ]; then
        log "No subscription plans declared for '$ORG_NAME' — skipping subscriptions."
        API_IDS=""
    else
        SUBSCRIPTION_PLAN="${ORG_PLANS%%|*}"
        log "Subscribing '$ORG_USER_USERNAME' to deployed APIs (plan: $SUBSCRIPTION_PLAN) ..."
        API_IDS=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/apis" -H "$USER_AUTH_HEADER" | jq -r '.list[]?.id // empty')
        if [ -z "$API_IDS" ]; then
            log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} no APIs found to subscribe to"
        fi
    fi
    while IFS= read -r api_id; do
        [ -n "$api_id" ] || continue

        # createSubscription enforces no api+plan uniqueness of its own, so
        # this script owns idempotency: skip if the user already has any
        # subscription to this API rather than creating a duplicate.
        EXISTING=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/subscriptions?artifactId=$(urlencode "$api_id")" \
            -H "$USER_AUTH_HEADER" | jq -r '.list[0].subscriptionId // empty')
        if [ -n "$EXISTING" ]; then
            log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $api_id (already subscribed)"
            continue
        fi

        SUB_STATUS=$(curl -sk -o /tmp/onboard-tenant-sub.$$.json -w "%{http_code}" -X POST \
            "$API_PORTAL_URL$API_PORTAL_API_BASE/subscriptions" \
            -H "$USER_AUTH_HEADER" -H "Content-Type: application/json" \
            -d "{\"artifactId\": \"$api_id\", \"subscriptionPlanId\": \"$SUBSCRIPTION_PLAN\"}")
        SUB_BODY=$(cat /tmp/onboard-tenant-sub.$$.json); rm -f /tmp/onboard-tenant-sub.$$.json
        if [ "$SUB_STATUS" = "201" ]; then
            log "  ${C_GREEN}${SYM_OK}${C_RESET} $api_id"
        elif [ "$SUB_STATUS" = "409" ]; then
            log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $api_id (already subscribed)"
        else
            log "  ${C_RED}✗${C_RESET} $api_id (HTTP $SUB_STATUS): $SUB_BODY"
        fi
    done <<< "$API_IDS"
else
    log "No applications declared for '$ORG_NAME' — skipping application creation and subscriptions."
fi

# --- Step 6: print how to get a token ----------------------------------------

ORG_TOKEN_ENDPOINT="$IS_URL/o/$ORG_ID/oauth2/token"

echo
echo "${C_BOLD}'$ORG_NAME' is onboarded.${C_RESET}"
echo
echo "Users:"
echo "  $ORG_ADMIN_USERNAME / $ORG_ADMIN_PASSWORD  (dp_admin)"
[ -n "$ORG_USER_USERNAME" ] && echo "  $ORG_USER_USERNAME / $ORG_USER_PASSWORD  (dp_subscriber)"
echo
echo "Token endpoint: $ORG_TOKEN_ENDPOINT"
echo "Consumer key/secret ('$ORG_APP_NAME'):"
echo "  client_id:     $ORG_CLIENT_ID"
echo "  client_secret: $ORG_CLIENT_SECRET"
echo
echo "Get a token directly from IS:"
echo "  curl -k -X POST $ORG_TOKEN_ENDPOINT \\"
echo "    -u '$ORG_CLIENT_ID:$ORG_CLIENT_SECRET' \\"
echo "    -d 'grant_type=client_credentials'"

if [ -n "$APP_KEY_MAPPINGS" ]; then
    echo
    echo "Or via the portal (no secret needed on the command line once linked):"
    while IFS='|' read -r app_id key_mapping_id; do
        [ -n "$app_id" ] || continue
        echo "  curl -k -X POST $API_PORTAL_URL$API_PORTAL_API_BASE/applications/$app_id/oauth-keys/$key_mapping_id/generate-token \\"
        echo "    -H \"Authorization: Bearer <${ORG_USER_USERNAME}'s token>\" -H 'Content-Type: application/json' \\"
        echo "    -d '{\"consumerSecret\": \"$ORG_CLIENT_SECRET\"}'"
    done <<< "$APP_KEY_MAPPINGS"
fi
