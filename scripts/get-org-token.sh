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

# Mints a real, org-scoped access token for one of an organization's users
# (e.g. "<org>admin" or "<org>user", as created by onboard-tenant.sh) — the
# same token a browser login or the Developer Portal itself would end up
# with, carrying that user's roles claim (dp_admin/dp_subscriber).
#
# NOT the same thing as the org's own OAuth2 "key manager" client
# (onboard-tenant.sh's <org>-key-manager, client_credentials only) — that
# one has no user/role association and can't be used to call anything
# requiring dp:*:manage scopes. This script logs in as a real user instead:
#   1. Resolves the organization's id from ORG_NAME.
#   2. Locates that organization's own copy ("fragment application") of the
#      shared root app named by ROOT_APP_ID.
#   3. Reads that fragment application's own client_id/client_secret, via a
#      client_credentials + organization_switch token minted from the ROOT
#      app's credentials (internal_org_application_mgt_view scope).
#   4. Logs in as ORG_USERNAME/ORG_PASSWORD against the fragment app
#      (grant_type=password), which is what actually carries the user's
#      role claim into the resulting token.
#
# Usage:
#   ORG_NAME=publicorg ORG_USERNAME=publicorgadmin ORG_PASSWORD='...' \
#   ROOT_APP_CLIENT_ID=... ROOT_APP_CLIENT_SECRET=... ROOT_APP_ID=... \
#     ./scripts/get-org-token.sh
#
# NOTE: the env vars are deliberately named ORG_USERNAME/ORG_PASSWORD, not
# USERNAME/PASSWORD — USERNAME in particular is a variable most shells
# (macOS included) already export as the OS login name, and a bare
# `USERNAME=foo ./script` prefix assignment does NOT reliably override an
# already-exported value for scripts run this way (confirmed directly: a
# fresh bash invocation's own startup files re-export it) — using the
# generic name would silently authenticate as the wrong account.
#
# Prints ONLY the raw access token to stdout (everything else goes to
# stderr) — designed to be captured directly:
#   TOKEN=$(ORG_NAME=... ORG_USERNAME=... ORG_PASSWORD=... ... ./scripts/get-org-token.sh)
#
# SCOPE (default "openid") and IS_URL / IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD
# override their defaults below.

set -euo pipefail

IS_URL="${IS_URL:-https://is.wso2.com:9444}"
IS_ADMIN_USERNAME="${IS_ADMIN_USERNAME:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
SCOPE="${SCOPE:-openid}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
fi

# Diagnostic output only — deliberately on stderr so stdout stays clean for
# `TOKEN=$(./scripts/get-org-token.sh ...)` to capture just the token.
log() { echo "${C_DIM}[get-org-token]${C_RESET} $*" >&2; }
fail() { echo "${C_RED}[get-org-token] ERROR:${C_RESET} $*" >&2; exit 1; }
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq   >/dev/null 2>&1 || fail "jq is required but not found on PATH."

[ -n "${ORG_NAME:-}" ] || fail "ORG_NAME is required — the organization to log in to (e.g. publicorg)."
[ -n "${ORG_USERNAME:-}" ] || fail "ORG_USERNAME is required — e.g. \${ORG_NAME}admin."
[ -n "${ORG_PASSWORD:-}" ] || fail "ORG_PASSWORD is required."
[ -n "${ROOT_APP_CLIENT_ID:-}" ] || fail "ROOT_APP_CLIENT_ID is required — the root-org API Portal application's client ID."
[ -n "${ROOT_APP_CLIENT_SECRET:-}" ] || fail "ROOT_APP_CLIENT_SECRET is required."
[ -n "${ROOT_APP_ID:-}" ] || fail "ROOT_APP_ID is required — the root-org API Portal application's id (not its client ID)."

log "Looking up organization '$ORG_NAME' ..."
ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations?filter=name+eq+$(urlencode "$ORG_NAME")" \
    | jq -r '.organizations[0].id // empty')
[ -n "$ORG_ID" ] || fail "organization '$ORG_NAME' not found."
log "  org id: $ORG_ID"

ROOT_ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ORG_ID" | jq -r '.parent.id // empty')
[ -n "$ROOT_ORG_ID" ] || fail "could not resolve '$ORG_NAME''s parent organization."

log "Locating '$ORG_NAME''s copy of the root application ..."
FRAGMENT_APP_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ROOT_ORG_ID/applications/$ROOT_APP_ID/shared-apps" \
    | jq -r --arg org "$ORG_ID" '.sharedApplications[]? | select(.organizationId==$org) | .applicationId')
[ -n "$FRAGMENT_APP_ID" ] || fail "the root application ($ROOT_APP_ID) is not shared to '$ORG_NAME'."
log "  fragment app id: $FRAGMENT_APP_ID"

log "Reading '$ORG_NAME''s fragment application's own client credentials ..."
CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=internal_org_application_mgt_view" | jq -r '.access_token // empty')
[ -n "$CC_TOKEN" ] || fail "failed to obtain a client_credentials token — check ROOT_APP_CLIENT_ID/ROOT_APP_CLIENT_SECRET."
SWITCHED_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=organization_switch&token=$CC_TOKEN&switching_organization=$ORG_ID&scope=internal_org_application_mgt_view" | jq -r '.access_token // empty')
[ -n "$SWITCHED_TOKEN" ] || fail "failed to switch into '$ORG_NAME' — is ROOT_APP_CLIENT_ID authorized for internal_org_application_mgt_view on the Application Management API?"

FRAGMENT_OIDC=$(curl -sk -H "Authorization: Bearer $SWITCHED_TOKEN" \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc")
FRAGMENT_CLIENT_ID=$(echo "$FRAGMENT_OIDC" | jq -r '.clientId // empty')
FRAGMENT_CLIENT_SECRET=$(echo "$FRAGMENT_OIDC" | jq -r '.clientSecret // empty')
[ -n "$FRAGMENT_CLIENT_ID" ] && [ -n "$FRAGMENT_CLIENT_SECRET" ] || fail "could not read '$ORG_NAME''s fragment application's own OIDC client credentials."

log "Logging in as '$ORG_USERNAME' ..."
TOKEN_RESP=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
    -u "$FRAGMENT_CLIENT_ID:$FRAGMENT_CLIENT_SECRET" \
    -d "grant_type=password&username=$(urlencode "$ORG_USERNAME")&password=$(urlencode "$ORG_PASSWORD")&scope=$(urlencode "$SCOPE")")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
[ -n "$ACCESS_TOKEN" ] || fail "failed to obtain an access token for '$ORG_USERNAME': $TOKEN_RESP"
log "  ${C_GREEN}✓${C_RESET} token acquired (expires_in: $(echo "$TOKEN_RESP" | jq -r '.expires_in // "?"')s)"

echo "$ACCESS_TOKEN"
