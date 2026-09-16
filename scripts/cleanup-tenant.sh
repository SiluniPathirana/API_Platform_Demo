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

# Tears down everything onboard-tenant.sh creates for one organization, so it
# can be re-run from scratch for testing:
#   1. Locates the organization and its fragment application (same lookups
#      as onboard-tenant.sh) — no-ops cleanly if the organization doesn't
#      exist (nothing to clean up).
#   2. Resets each of the org's users' passwords to a freshly generated one
#      (so this script works even if you don't know/recall the current
#      password — same trick onboard-tenant.sh itself uses on re-run) and
#      logs in as each.
#   3. Deletes, through the Developer Portal's own REST API: subscriptions
#      and applications (as the SUBSCRIBER user — onboard-tenant.sh creates
#      these under that user's own identity, and the portal's application
#      list/delete endpoints are scoped to their creator, so deleting them
#      as the admin user would silently find none), then APIs and MCP
#      servers (as the admin user). Subscriptions before applications (an
#      application with an active subscription can't be deleted first).
#   4. Deletes the organization from WSO2 IS — this cascades away the
#      fragment application and both users with it.
#
# What this does NOT do: delete subscription plans (Bronze/Gold/Platinum/
# etc.) — they're harmless to leave and onboard-tenant.sh's plan upserts are
# idempotent either way. It also does not touch any OTHER organization's
# data, and never operates on more than the one ORG_NAME given.
#
# This is a genuinely destructive script — it deletes real data with no
# confirmation prompt, on the assumption you're running it deliberately
# against a test/demo organization. Never point ORG_NAME at one you care
# about.
#
# Prerequisites: same as onboard-tenant.sh — ROOT_APP_CLIENT_ID must be
# authorized for the same SCIM2 Users/Roles + Application Management API
# scopes listed in that script's header (this script uses the identical
# client_credentials + organization_switch pattern to reach the org).
#
# Usage:
#   ORG_NAME=org1 ROOT_APP_CLIENT_ID=... ROOT_APP_CLIENT_SECRET=... ROOT_APP_ID=... \
#     ./scripts/cleanup-tenant.sh
#
# IS_URL / API_PORTAL_URL / IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD / SYSTEM_USERNAME /
# ORG_USER_USERNAME override the defaults/conventions below (SYSTEM_USERNAME
# defaults to "${ORG_NAME}admin", ORG_USER_USERNAME to "${ORG_NAME}user",
# matching onboard-tenant.sh — the latter is skipped cleanly if it doesn't
# exist, e.g. an org onboarded with no applications).
#
# Safe to re-run: every step no-ops (with a log line) if there's nothing
# left to delete — running this twice in a row is harmless.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IS_URL="${IS_URL:-https://is.wso2.com:9444}"
IS_ADMIN_USERNAME="${IS_ADMIN_USERNAME:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
API_PORTAL_URL="${API_PORTAL_URL:-https://localhost:9543}"
API_PORTAL_API_BASE="/api-portal/api/v0.9"
SYSTEM_USERNAME="${SYSTEM_USERNAME:-${ORG_NAME:-}admin}"
ORG_USER_USERNAME="${ORG_USER_USERNAME:-${ORG_NAME:-}user}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
    SYM_OK="✓"; SYM_SKIP="•"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
    SYM_OK="OK"; SYM_SKIP="-"
fi

log() { echo "${C_DIM}[cleanup-tenant]${C_RESET} $*"; }
fail() { echo "${C_RED}[cleanup-tenant] ERROR:${C_RESET} $*" >&2; exit 1; }
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq   >/dev/null 2>&1 || fail "jq is required but not found on PATH."

[ -n "${ORG_NAME:-}" ] || fail "ORG_NAME is required — the organization to tear down (e.g. org1)."
[ -n "${ROOT_APP_CLIENT_ID:-}" ] || fail "ROOT_APP_CLIENT_ID is required — the root-org API Portal application's client ID."
[ -n "${ROOT_APP_CLIENT_SECRET:-}" ] || fail "ROOT_APP_CLIENT_SECRET is required."
[ -n "${ROOT_APP_ID:-}" ] || fail "ROOT_APP_ID is required — the root-org API Portal application's id (not its client ID)."

# --- Step 1: locate the organization (no-op if it doesn't exist) ------------

log "Looking up organization '$ORG_NAME' in WSO2 IS at $IS_URL ..."
ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations?filter=name+eq+$(urlencode "$ORG_NAME")" \
    | jq -r '.organizations[0].id // empty')

if [ -z "$ORG_ID" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} organization not found — nothing to clean up."
    exit 0
fi
log "  found (id: $ORG_ID)"

ROOT_ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ORG_ID" | jq -r '.parent.id // empty')
[ -n "$ROOT_ORG_ID" ] || fail "could not resolve '$ORG_NAME''s parent organization."

FRAGMENT_APP_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ROOT_ORG_ID/applications/$ROOT_APP_ID/shared-apps" \
    | jq -r --arg org "$ORG_ID" '.sharedApplications[]? | select(.organizationId==$org) | .applicationId')

# --- Step 2: reset each of the org's users' passwords and log in as each ----
# Skipped (with a warning) if the app isn't shared to this org, or a given
# user doesn't exist — the org still gets deleted below either way, just
# without that user's portal-side content cleanup step first. Not finding
# ORG_USER_USERNAME is routine (an org onboarded with no applications never
# gets one), so that particular case logs as a skip, not an error.

SWITCHED_TOKEN=""
if [ -z "$FRAGMENT_APP_ID" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} API Portal application not shared to '$ORG_NAME' — skipping portal-side content cleanup."
else
    USER_MGT_SCOPES="internal_org_user_mgt_list internal_org_user_mgt_view internal_org_user_mgt_update internal_org_application_mgt_view"
    CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
        -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
        -d "grant_type=client_credentials&scope=$USER_MGT_SCOPES" | jq -r '.access_token // empty')
    [ -n "$CC_TOKEN" ] || fail "failed to obtain a client_credentials token — check ROOT_APP_CLIENT_ID/ROOT_APP_CLIENT_SECRET."
    SWITCHED_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
        -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
        -d "grant_type=organization_switch&token=$CC_TOKEN&switching_organization=$ORG_ID&scope=$USER_MGT_SCOPES" | jq -r '.access_token // empty')
    [ -n "$SWITCHED_TOKEN" ] || fail "failed to switch into '$ORG_NAME' for user management."

    FRAGMENT_OIDC=$(curl -sk -H "Authorization: Bearer $SWITCHED_TOKEN" \
        "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc")
    FRAGMENT_CLIENT_ID=$(echo "$FRAGMENT_OIDC" | jq -r '.clientId // empty')
    FRAGMENT_CLIENT_SECRET=$(echo "$FRAGMENT_OIDC" | jq -r '.clientSecret // empty')
fi

# Resets $1's password and logs in, setting the global LOGIN_ACCESS_TOKEN (or
# leaving it empty, with an explanatory log line, on any expected reason not
# to — no fragment app, no client credentials, or the user not existing).
login_as() {
    local username="$1"
    LOGIN_ACCESS_TOKEN=""
    [ -n "$SWITCHED_TOKEN" ] || return 0
    if [ -z "$FRAGMENT_CLIENT_ID" ] || [ -z "$FRAGMENT_CLIENT_SECRET" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} could not read fragment application credentials — skipping cleanup as '$username'."
        return 0
    fi

    local user_id
    user_id=$(curl -sk "$IS_URL/t/carbon.super/o/scim2/Users?filter=userName+eq+$(urlencode "$username")" \
        -H "Authorization: Bearer $SWITCHED_TOKEN" | jq -r '.Resources[0].id // empty')
    if [ -z "$user_id" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} user '$username' not found — skipping cleanup as this user."
        return 0
    fi

    local new_password reset_status reset_body
    new_password="Aa1$(openssl rand -hex 6)!"
    reset_status=$(curl -sk -o /tmp/cleanup-tenant-pwreset.$$.json -w "%{http_code}" \
        -X PATCH "$IS_URL/t/carbon.super/o/scim2/Users/$user_id" \
        -H "Authorization: Bearer $SWITCHED_TOKEN" -H "Content-Type: application/json" \
        -d "{\"schemas\": [\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"], \"Operations\": [{\"op\": \"replace\", \"value\": {\"password\": \"$new_password\"}}]}")
    reset_body=$(cat /tmp/cleanup-tenant-pwreset.$$.json); rm -f /tmp/cleanup-tenant-pwreset.$$.json
    [ "$reset_status" = "200" ] || fail "failed to reset password for '$username' (HTTP $reset_status): $reset_body"

    local token_resp
    token_resp=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
        -u "$FRAGMENT_CLIENT_ID:$FRAGMENT_CLIENT_SECRET" \
        -d "grant_type=password&username=$(urlencode "$username")&password=$(urlencode "$new_password")&scope=openid")
    LOGIN_ACCESS_TOKEN=$(echo "$token_resp" | jq -r '.access_token // empty')
    [ -n "$LOGIN_ACCESS_TOKEN" ] || fail "failed to log in as '$username' after password reset: $token_resp"
    log "  ${C_GREEN}${SYM_OK}${C_RESET} logged in as '$username'"
}

login_as "$SYSTEM_USERNAME"
ADMIN_ACCESS_TOKEN="$LOGIN_ACCESS_TOKEN"
login_as "$ORG_USER_USERNAME"
USER_ACCESS_TOKEN="$LOGIN_ACCESS_TOKEN"
# Applications/subscriptions are deleted under whichever of the two actually
# has a session — onboard-tenant.sh creates them as the subscriber user when
# one exists, but an org with none (e.g. one onboarded with no applications)
# never had a subscriber user to begin with, so the admin session (which can
# also manage applications/subscriptions — see dp_admin's scope grant) covers
# that case with nothing left to delete anyway.
APPS_ACCESS_TOKEN="${USER_ACCESS_TOKEN:-$ADMIN_ACCESS_TOKEN}"

# --- Step 3: delete portal-side content, in dependency order ----------------
# Subscriptions before applications (an application with an active
# subscription can't be deleted first), applications before APIs/MCP servers
# is not required but keeps the log output in the same intuitive order as
# before.

# Repeatedly re-fetches page 1 rather than paging through offsets — every
# delete shrinks the collection, so what was page 2 becomes page 1, and this
# naturally terminates once the collection is empty regardless of how many
# entries it started with.
delete_all() {
    local resource="$1" id_field="$2" label="$3" token="$4"
    local list_resp count
    while true; do
        list_resp=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/$resource?limit=100" \
            -H "Authorization: Bearer $token")
        count=$(echo "$list_resp" | jq -r '.list | length')
        [ "$count" -gt 0 ] || break
        echo "$list_resp" | jq -r --arg f "$id_field" '.list[][$f]' | while IFS= read -r item_id; do
            [ -n "$item_id" ] || continue
            del_status=$(curl -sk -o /dev/null -w "%{http_code}" -X DELETE \
                "$API_PORTAL_URL$API_PORTAL_API_BASE/$resource/$item_id" \
                -H "Authorization: Bearer $token")
            if [ "$del_status" -ge 200 ] && [ "$del_status" -lt 300 ]; then
                log "  ${C_GREEN}${SYM_OK}${C_RESET} deleted $label $item_id"
            else
                fail "failed to delete $label '$item_id' (HTTP $del_status)"
            fi
        done
    done
}

if [ -n "$APPS_ACCESS_TOKEN" ]; then
    log "Deleting subscriptions ..."
    delete_all "subscriptions" "subscriptionId" "subscription" "$APPS_ACCESS_TOKEN"
    log "Deleting applications ..."
    delete_all "applications" "id" "application" "$APPS_ACCESS_TOKEN"
fi
if [ -n "$ADMIN_ACCESS_TOKEN" ]; then
    log "Deleting APIs ..."
    delete_all "apis" "id" "API" "$ADMIN_ACCESS_TOKEN"
    log "Deleting MCP servers ..."
    delete_all "mcp-servers" "id" "MCP server" "$ADMIN_ACCESS_TOKEN"
fi

# --- Step 4: delete the organization from WSO2 IS ---------------------------
# Cascades away the fragment application and the system user with it.

log "Deleting organization '$ORG_NAME' from WSO2 IS ..."
DELETE_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    -X DELETE "$IS_URL/api/server/v1/organizations/$ORG_ID")
if [ "$DELETE_STATUS" = "204" ]; then
    log "  ${C_GREEN}${SYM_OK}${C_RESET} organization deleted"
else
    fail "failed to delete organization '$ORG_NAME' (HTTP $DELETE_STATUS)"
fi

log "${C_GREEN}Done.${C_RESET} '$ORG_NAME' is torn down — re-run onboard-tenant.sh to recreate it from scratch."
