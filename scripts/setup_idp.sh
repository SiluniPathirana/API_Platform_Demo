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

# One-time WSO2 IS 7.1+ setup for the Developer Portal: creates and fully
# configures the root-org OIDC application everything else in this repo
# depends on (browser login, onboard-tenant.sh, cleanup-tenant.sh), then
# prints exactly what to paste into the portal's own config.toml. This
# script does NOT touch config.toml itself — apply the printed values by
# hand (or however your deployment manages that file).
#
# Distills everything found empirically while building this against a real
# WSO2 IS 7.3 instance (see docs/administer/wso2-is-setup.md for the
# narrative version of each of these):
#   - orgHandle-equivalent gotchas don't apply here (that's per-organization,
#     this script only ever touches the one root-org application), but two
#     app-level ones do:
#   - enhancedOrgAuthenticationEnabled=true is REQUIRED for a browser login's
#     roles claim to actually populate — without it, an org-scoped login
#     succeeds but silently carries no roles at all (confirmed by decoding
#     real tokens from both states, not assumed).
#   - Turning that flag on resets authenticationSequence to a bare
#     BasicAuthenticator-only step — this script re-asserts the intended
#     {BasicAuthenticator, OrganizationIdentifierHandler} combo afterward,
#     and attaches an adaptive script that forces OrganizationIdentifierHandler
#     even under enhanced mode, which is what makes the "which org?" discovery
#     prompt (org_handle.do) reachable again alongside working roles — the
#     combination that was previously an either/or trade-off.
#   - claimConfiguration.role.claim.uri MUST reference a claim already
#     declared in claimMappings under CUSTOM dialect (IS 400s otherwise:
#     "Application Claim URI ... is not defined"), and
#     http://wso2.org/claims/role (singular) isn't a real registered local
#     claim on a stock instance at all (IS 400s: "Local claim ... is not
#     available in the server") — this script uses the plural
#     http://wso2.org/claims/roles throughout, confirmed working.
#
# Usage:
#   IS_URL=https://is.wso2.com:9444 \
#   PORTAL_CALLBACK_URL=http://your-portal-host:9543/api-portal/default/callback \
#   PORTAL_LOGOUT_REDIRECT_URL=http://your-portal-host:9543/api-portal/logout \
#     ./scripts/setup_idp.sh
#
# IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD (default admin/admin), APP_NAME
# (default "API Portal") override their defaults. IS_INTERNAL_URL (default:
# same as IS_URL) is the IS hostname the PORTAL CONTAINER itself can reach —
# set it separately from IS_URL when the portal runs in Docker on a host
# where IS isn't reachable at the same address the browser/this script uses
# (e.g. host.docker.internal) — see the printed token_url/jwks_url note.
#
# Safe to re-run: an existing application (same APP_NAME) is reused and
# reconfigured to the same idempotent target state every time; existing
# dp_admin/dp_subscriber roles and API authorizations are detected and
# skipped rather than duplicated.

set -euo pipefail

IS_URL="${IS_URL:-https://is.wso2.com:9444}"
IS_INTERNAL_URL="${IS_INTERNAL_URL:-$IS_URL}"
IS_ADMIN_USERNAME="${IS_ADMIN_USERNAME:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
APP_NAME="${APP_NAME:-API Portal}"
PORTAL_CALLBACK_URL="${PORTAL_CALLBACK_URL:-http://localhost:9543/api-portal/default/callback}"
PORTAL_LOGOUT_REDIRECT_URL="${PORTAL_LOGOUT_REDIRECT_URL:-http://localhost:9543/api-portal/logout}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
    SYM_OK="✓"; SYM_SKIP="•"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
    SYM_OK="OK"; SYM_SKIP="-"
fi

log() { echo "${C_DIM}[setup_idp]${C_RESET} $*"; }
fail() { echo "${C_RED}[setup_idp] ERROR:${C_RESET} $*" >&2; exit 1; }
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq   >/dev/null 2>&1 || fail "jq is required but not found on PATH."

IS_AUTH=(-u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD")

# --- Step 1: create (or find) the root application --------------------------

log "Registering application '$APP_NAME' in WSO2 IS at $IS_URL ..."
# POST /applications returns 201 with an EMPTY body on success — the new
# app's id is only in the Location header, not a JSON payload (confirmed by
# testing directly; every other create endpoint used elsewhere in this repo
# does return a body, so don't assume this one does too).
CREATE_HEADERS=$(curl -sk -D - -o /dev/null -w "%{http_code}" \
    "${IS_AUTH[@]}" -X POST "$IS_URL/api/server/v1/applications" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$APP_NAME\", \"description\": \"WSO2 API Platform developer portal\", \"templateId\": \"custom-application-oidc\",
         \"inboundProtocolConfiguration\": {\"oidc\": {
             \"grantTypes\": [\"authorization_code\", \"refresh_token\", \"organization_switch\", \"password\", \"client_credentials\"],
             \"callbackURLs\": [\"regexp=($PORTAL_CALLBACK_URL|$PORTAL_LOGOUT_REDIRECT_URL)\"],
             \"publicClient\": false
         }}}")
CREATE_STATUS="${CREATE_HEADERS: -3}"
CREATE_HEADERS="${CREATE_HEADERS%???}"

if [ "$CREATE_STATUS" = "201" ]; then
    APP_ID=$(echo "$CREATE_HEADERS" | grep -i '^location:' | sed -E 's#.*/applications/##; s#[[:space:]\r]*$##')
    [ -n "$APP_ID" ] || fail "application created (HTTP 201) but could not parse its id from the Location header."
    log "  ${C_GREEN}${SYM_OK}${C_RESET} created (id: $APP_ID)"
else
    APP_ID=$(curl -sk "${IS_AUTH[@]}" \
        "$IS_URL/api/server/v1/applications?filter=name+eq+$(urlencode "$APP_NAME")" \
        | jq -r '.applications[0].id // empty')
    if [ -n "$APP_ID" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists (id: $APP_ID)"
    else
        fail "failed to create application '$APP_NAME' (HTTP $CREATE_STATUS)."
    fi
fi

# --- Step 2: OIDC access token config ----------------------------------------

log "Configuring JWT access tokens with roles/groups/email/username ..."
CURRENT_OIDC=$(curl -sk "${IS_AUTH[@]}" "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc")
MERGED_OIDC=$(echo "$CURRENT_OIDC" | jq '
    .accessToken.type = "JWT" |
    .accessToken.accessTokenAttributes = ["groups", "roles", "email", "username"]
')
OIDC_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    "${IS_AUTH[@]}" -X PUT "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" \
    -H "Content-Type: application/json" -d "$MERGED_OIDC")
[ "$OIDC_STATUS" = "200" ] || fail "failed to update OIDC config (HTTP $OIDC_STATUS)."
# PUT .../inbound-protocols/oidc returns 200 with an EMPTY body (confirmed by
# testing directly) — a separate GET is required to read back clientId/
# clientSecret, same story as Step 1's Location-header-only response.
OIDC_AFTER=$(curl -sk "${IS_AUTH[@]}" "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc")
CLIENT_ID=$(echo "$OIDC_AFTER" | jq -r '.clientId')
CLIENT_SECRET=$(echo "$OIDC_AFTER" | jq -r '.clientSecret')
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || fail "could not read back client credentials after configuring OIDC."
log "  ${C_GREEN}${SYM_OK}${C_RESET} configured"

# --- Step 3: claim configuration ---------------------------------------------
# role.claim.uri deliberately uses the plural /claims/roles — see header note.

log "Configuring claim mappings (username/email/roles/givenname/lastname) ..."
CLAIM_STATUS=$(curl -sk -o /tmp/setup-idp-claims.$$.json -w "%{http_code}" \
    "${IS_AUTH[@]}" -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID" \
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
CLAIM_BODY=$(cat /tmp/setup-idp-claims.$$.json); rm -f /tmp/setup-idp-claims.$$.json
[ "$CLAIM_STATUS" = "200" ] || fail "failed to update claim configuration (HTTP $CLAIM_STATUS): $CLAIM_BODY"
log "  ${C_GREEN}${SYM_OK}${C_RESET} configured"

# --- Step 4: enable enhanced organization authentication ---------------------
# Required for a browser login's roles claim to populate at all — see header
# note. Resets authenticationSequence to bare BasicAuthenticator, which
# step 5 below re-asserts.

log "Enabling enhanced organization authentication ..."
curl -sk "${IS_AUTH[@]}" -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID" \
    -H "Content-Type: application/json" \
    -d '{"enhancedOrgAuthenticationEnabled": true}' -o /dev/null -w "  ${C_GREEN}${SYM_OK}${C_RESET} (HTTP %{http_code})\n"

# --- Step 5: authentication sequence + adaptive script -----------------------
# The step options make a plain, non-discovery login (org already known via
# org=<handle>) work. The adaptive script is what makes discovery
# (org_handle.do, reached when no org is known yet) reachable *at the same
# time* as enhanced mode being on — without it, enhanced mode forces
# discovery attempts straight into an unrecoverable "domain.unknown" failure
# instead of the prompt.

log "Setting authentication sequence (BasicAuthenticator + OrganizationIdentifierHandler) ..."
curl -sk "${IS_AUTH[@]}" -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID" \
    -H "Content-Type: application/json" \
    -d '{
        "authenticationSequence": {
            "type": "USER_DEFINED",
            "steps": [
                {"id": 1, "options": [
                    {"idp": "LOCAL", "authenticator": "BasicAuthenticator"},
                    {"idp": "LOCAL", "authenticator": "OrganizationIdentifierHandler"}
                ]}
            ],
            "subjectStepId": 1,
            "attributeStepId": 1
        }
    }' -o /dev/null -w "  ${C_GREEN}${SYM_OK}${C_RESET} (HTTP %{http_code})\n"

log "Setting adaptive authentication script ..."
ADAPTIVE_SCRIPT=$'var onLoginRequest = function(context) {\n\n    executeStep(1, { authenticationOptions:[{authenticator: \'OrganizationIdentifierHandler\'}]}, {});\n};'
SCRIPT_BODY=$(jq -n --arg s "$ADAPTIVE_SCRIPT" '{script: $s}')
curl -sk "${IS_AUTH[@]}" -X PUT "$IS_URL/api/server/v1/applications/$APP_ID/authenticationSequence/script" \
    -H "Content-Type: application/json" -d "$SCRIPT_BODY" -o /dev/null -w "  ${C_GREEN}${SYM_OK}${C_RESET} (HTTP %{http_code})\n"

# --- Step 6: skip login/logout consent ---------------------------------------

log "Disabling login/logout consent prompts ..."
curl -sk "${IS_AUTH[@]}" -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID" \
    -H "Content-Type: application/json" \
    -d '{"advancedConfigurations": {"skipLoginConsent": false, "skipLogoutConsent": false}}' \
    -o /dev/null -w "  ${C_GREEN}${SYM_OK}${C_RESET} (HTTP %{http_code})\n"

# --- Step 7: share to all sub-organizations ----------------------------------
# This only reaches the organizations that exist right now — an organization
# created later has no copy of the application until the share is re-issued,
# so onboard-tenant.sh repeats this call for any organization it finds
# without one. Nothing here has to be re-run by hand when adding a tenant.

log "Sharing to all sub-organizations ..."
SHARE_STATUS=$(curl -sk -o /tmp/setup-idp-share.$$.json -w "%{http_code}" \
    "${IS_AUTH[@]}" -X POST "$IS_URL/api/server/v1/applications/$APP_ID/share" \
    -H "Content-Type: application/json" \
    -d '{"shareWithAllChildren": true}')
SHARE_BODY=$(cat /tmp/setup-idp-share.$$.json); rm -f /tmp/setup-idp-share.$$.json
case "$SHARE_STATUS" in
    200|201|202|204) log "  ${C_GREEN}${SYM_OK}${C_RESET} (HTTP $SHARE_STATUS)" ;;
    *) fail "failed to share the application with sub-organizations (HTTP $SHARE_STATUS): $SHARE_BODY" ;;
esac

# --- Step 8: authorize the scopes onboard-tenant.sh/cleanup-tenant.sh need ---
# API resource ids are looked up by identifier rather than hardcoded — they
# differ per IS instance.

# On a fresh app this POSTs a brand-new authorization. On an app that
# already has SOME scopes authorized for this API resource (e.g. re-running
# this script after adding a new scope to the list below), the POST 409s —
# in that case PATCH the existing authorization with addedScopes instead of
# treating 409 as "nothing to do", or a scope added here later would never
# actually reach an already-configured IS instance.
authorize_api() {
    local identifier="$1"; shift
    local scopes=("$@")
    local api_id
    api_id=$(curl -sk "${IS_AUTH[@]}" "$IS_URL/api/server/v1/api-resources?limit=250" \
        | jq -r --arg id "$identifier" '.apiResources[]? | select(.identifier==$id) | .id' | head -1)
    [ -n "$api_id" ] || fail "API resource '$identifier' not found on this IS instance."

    local scopes_json; scopes_json=$(printf '%s\n' "${scopes[@]}" | jq -R . | jq -s .)
    local status
    status=$(curl -sk -o /tmp/setup-idp-authz.$$.json -w "%{http_code}" \
        "${IS_AUTH[@]}" -X POST "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"$api_id\", \"policyIdentifier\": \"RBAC\", \"scopes\": $scopes_json}")
    local body; body=$(cat /tmp/setup-idp-authz.$$.json); rm -f /tmp/setup-idp-authz.$$.json
    if [ "$status" = "200" ] || [ "$status" = "201" ]; then
        log "  ${C_GREEN}${SYM_OK}${C_RESET} $identifier"
        return
    fi
    if [ "$status" != "409" ]; then
        fail "failed to authorize '$identifier' (HTTP $status): $body"
    fi

    # Already authorized for this API resource — diff against what's
    # currently granted and PATCH in only what's missing.
    local current_scopes missing_scopes
    current_scopes=$(curl -sk "${IS_AUTH[@]}" \
        "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis" \
        | jq -c --arg id "$api_id" '.[] | select(.id==$id) | [.authorizedScopes[]?.name // .authorizedScopes[]?]')
    [ -n "$current_scopes" ] || current_scopes='[]'
    missing_scopes=$(jq -c -n --argjson current "$current_scopes" --argjson wanted "$scopes_json" \
        '$wanted - $current')
    if [ "$missing_scopes" = "[]" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $identifier (already authorized)"
        return
    fi
    local patch_status patch_body
    patch_status=$(curl -sk -o /tmp/setup-idp-authz-patch.$$.json -w "%{http_code}" \
        "${IS_AUTH[@]}" -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis/$api_id" \
        -H "Content-Type: application/json" \
        -d "{\"addedScopes\": $missing_scopes, \"removedScopes\": []}")
    patch_body=$(cat /tmp/setup-idp-authz-patch.$$.json); rm -f /tmp/setup-idp-authz-patch.$$.json
    [ "$patch_status" = "200" ] || fail "failed to add missing scopes to '$identifier' (HTTP $patch_status): $patch_body"
    log "  ${C_GREEN}${SYM_OK}${C_RESET} $identifier (added: $(echo "$missing_scopes" | jq -r 'join(", ")'))"
}

log "Authorizing required API scopes ..."
authorize_api "/o/api/server/v1/applications" "internal_org_application_mgt_view" "internal_org_application_mgt_update" "internal_org_application_mgt_create"
authorize_api "/o/scim2/Users" "internal_org_user_mgt_create" "internal_org_user_mgt_list" "internal_org_user_mgt_view" "internal_org_user_mgt_update" "internal_org_user_mgt_delete"
authorize_api "/o/scim2/Roles" "internal_org_role_mgt_view" "internal_org_role_mgt_update"

# --- Step 9: create dp_admin / dp_subscriber shared roles --------------------
# These propagate automatically to every org's fragment application copy of
# this app, purely because the app itself is shared (step 7) — no explicit
# per-role "share" step exists or is needed, confirmed empirically.

ensure_role() {
    local role_name="$1"
    local existing
    existing=$(curl -sk "${IS_AUTH[@]}" "$IS_URL/scim2/v2/Roles" \
        | jq -r --arg role "$role_name" --arg app "$APP_ID" \
            '.Resources[]? | select(.displayName==$role and .audience.value==$app) | .id // empty')
    if [ -n "$existing" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} '$role_name' already exists"
        return
    fi
    local status
    status=$(curl -sk -o /tmp/setup-idp-role.$$.json -w "%{http_code}" \
        "${IS_AUTH[@]}" -X POST "$IS_URL/scim2/v2/Roles" \
        -H "Content-Type: application/json" \
        -d "{\"displayName\": \"$role_name\", \"audience\": {\"value\": \"$APP_ID\", \"type\": \"application\"}}")
    local body; body=$(cat /tmp/setup-idp-role.$$.json); rm -f /tmp/setup-idp-role.$$.json
    [ "$status" = "201" ] || fail "failed to create role '$role_name' (HTTP $status): $body"
    log "  ${C_GREEN}${SYM_OK}${C_RESET} '$role_name' created"
}

log "Creating dp_admin / dp_subscriber roles ..."
ensure_role "dp_admin"
ensure_role "dp_subscriber"

# --- Done: print what to paste into the portal's config.toml ----------------

END_SESSION_ENDPOINT=$(curl -sk "$IS_URL/oauth2/oidcdiscovery/.well-known/openid-configuration" | jq -r '.end_session_endpoint // empty')

echo
log "${C_GREEN}${C_BOLD}Done.${C_RESET} Paste this into the Developer Portal's config.toml:"
echo
cat <<EOF
[api_portal.auth]
mode = "idp"

[api_portal.auth.idp]
client_id = "$CLIENT_ID"
client_secret = "$CLIENT_SECRET"
authorization_url = "$IS_URL/oauth2/authorize"
token_url = "$IS_INTERNAL_URL/oauth2/token"
callback_url = "$PORTAL_CALLBACK_URL"
jwks_url = "$IS_INTERNAL_URL/oauth2/jwks"
logout_url = "${END_SESSION_ENDPOINT:-$IS_URL/oidc/logout}"
logout_redirect_uri = "$PORTAL_LOGOUT_REDIRECT_URL"

[api_portal.auth.authorization]
enabled = true
mode    = "role"
role_to_scope_mapping = "./resources/role-to-scope-mapping.yaml"
page_role_validation = true

[api_portal.auth.authorization.portal_roles]
admin      = "dp_admin"
subscriber = "dp_subscriber"
EOF
echo
log "Also useful for onboard-tenant.sh / cleanup-tenant.sh (same application):"
echo "  ROOT_APP_CLIENT_ID=$CLIENT_ID"
echo "  ROOT_APP_CLIENT_SECRET=$CLIENT_SECRET"
echo "  ROOT_APP_ID=$APP_ID"
echo
log "${C_YELLOW}Note:${C_RESET} authorization_url/logout_url above use IS_URL (must be reachable"
log "from the BROWSER); token_url/jwks_url use IS_INTERNAL_URL (must be reachable"
log "from the PORTAL CONTAINER) — set IS_INTERNAL_URL explicitly if those differ"
log "in your deployment (e.g. Docker's host.docker.internal)."
