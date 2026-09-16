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

# Prepares the DEFAULT organization's catalog for the demo:
#   1. Ensures a "Platinum" subscription plan exists (every organization
#      auto-seeds Bronze/Silver/Gold/Unlimited/AsyncUnlimited on creation —
#      see src/utils/constants.js's DEFAULT_SUBSCRIPTION_PLANS — so Platinum
#      is the only one actually missing).
#   2. Delegates to seed-samples.sh, unmodified, to deploy every bundled
#      sample API/MCP server (it already walks samples/apis/* and
#      samples/mcps/* generically, so newly added samples are picked up with
#      no changes to that script).
#
# This targets whichever organization the auth token/credentials resolve
# to — normally the default org, since that's what a plain admin login
# against this portal instance's own IDP/Platform API resolves to. To seed
# a SUBSET of samples into a sub-org instead (with a restricted set of
# subscription plans per artifact), use onboard-tenant.sh's TENANT_CATALOG
# option — this script always deploys everything, unfiltered.
#
# Usage (from the project root, or the standalone distribution zip):
#   ./scripts/seed-default-catalog.sh
#
# ACCESS_TOKEN supplies an already-issued bearer token and skips the
# Platform API login entirely (same convention as seed-samples.sh).
# ADMIN_USERNAME / ADMIN_PASSWORD skip the interactive credential prompt.
# API_PORTAL_URL / PLATFORM_API_URL override the default local URLs.
#
# Safe to re-run: the Platinum plan upsert is idempotent, and seed-samples.sh
# already skips entries that already exist.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

API_PORTAL_URL="${API_PORTAL_URL:-https://localhost:9543}"
PLATFORM_API_URL="${PLATFORM_API_URL:-https://localhost:9243}"
API_PORTAL_API_BASE="/api-portal/api/v0.9"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
    SYM_OK="✓"
else
    C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
    SYM_OK="OK"
fi

log() { echo "${C_DIM}[seed-default-catalog]${C_RESET} $*"; }
fail() { echo "${C_RED}[seed-default-catalog] ERROR:${C_RESET} $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq   >/dev/null 2>&1 || fail "jq is required but not found on PATH."

# Same auth convention as seed-samples.sh — ACCESS_TOKEN short-circuits the
# Platform API login entirely.
if [ -n "${ACCESS_TOKEN:-}" ]; then
    log "Using supplied ACCESS_TOKEN — skipping Platform API login."
    TOKEN="$ACCESS_TOKEN"
else
    if [ -z "${ADMIN_USERNAME:-}" ] && [ -t 0 ]; then
        read -r -p "API Portal admin username: " ADMIN_USERNAME
    fi
    [ -n "${ADMIN_USERNAME:-}" ] || fail "an admin username is required (set ADMIN_USERNAME/ADMIN_PASSWORD, or ACCESS_TOKEN, or run interactively)."

    if [ -z "${ADMIN_PASSWORD:-}" ] && [ -t 0 ]; then
        read -r -s -p "API Portal admin password: " ADMIN_PASSWORD
        echo
    fi
    [ -n "${ADMIN_PASSWORD:-}" ] || fail "an admin password is required (set ADMIN_USERNAME/ADMIN_PASSWORD, or ACCESS_TOKEN, or run interactively)."

    log "Logging in to Platform API at $PLATFORM_API_URL ..."
    urlencode() { jq -rn --arg v "$1" '$v|@uri'; }
    ENCODED_ADMIN_USERNAME="$(urlencode "$ADMIN_USERNAME")"
    ENCODED_ADMIN_PASSWORD="$(urlencode "$ADMIN_PASSWORD")"
    TOKEN=$(curl -sk -X POST "$PLATFORM_API_URL/api/portal/v0.9/auth/login" \
        -d "username=$ENCODED_ADMIN_USERNAME&password=$ENCODED_ADMIN_PASSWORD" | jq -r '.token // empty')
    [ -n "$TOKEN" ] || fail "failed to obtain a token — check the credentials and that Platform API is reachable at $PLATFORM_API_URL."
fi
AUTH_HEADER="Authorization: Bearer $TOKEN"

log "Ensuring the 'Platinum' subscription plan exists ..."
PLAN_STATUS=$(curl -sk -o /tmp/seed-default-catalog-plan.$$.json -w "%{http_code}" \
    -X PUT "$API_PORTAL_URL$API_PORTAL_API_BASE/subscription-plans" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d '{
        "id": "Platinum",
        "displayName": "Platinum",
        "description": "Allows 8000 requests per minute",
        "limits": [{"limitType": "REQUEST_COUNT", "timeUnit": "MINUTE", "timeAmount": 1, "limitCount": 8000}]
    }')
PLAN_BODY=$(cat /tmp/seed-default-catalog-plan.$$.json); rm -f /tmp/seed-default-catalog-plan.$$.json
if [ "$PLAN_STATUS" = "200" ] || [ "$PLAN_STATUS" = "201" ]; then
    log "  ${C_GREEN}${SYM_OK}${C_RESET} Platinum plan ready (HTTP $PLAN_STATUS)"
else
    fail "failed to upsert the Platinum subscription plan (HTTP $PLAN_STATUS): $PLAN_BODY"
fi

log "Deploying every bundled sample API/MCP server ..."
ACCESS_TOKEN="$TOKEN" API_PORTAL_URL="$API_PORTAL_URL" "$THIS_DIR/seed-samples.sh"
