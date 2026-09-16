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

# Deploys one tenant's gateway API definitions (the RestApi YAMLs that live at
# the root of each artifacts/via-script/<org>/apis/<bundle>/ directory) into a
# running WSO2 API Platform gateway, via its management API.
#
# This is the GATEWAY half of a tenant's catalog — the runtime routes, policies
# and upstreams. seed-samples.sh (driven by onboard-tenant.sh) seeds the
# PORTAL half from the same bundles' api-portal/ subdirectories. The two are
# independent: neither reads the other's files, and either can be run alone.
#
# Which files get deployed: every *.yaml sitting directly inside
# artifacts/via-script/$ORG/apis/*/ (one level down, so the api-portal/ and
# mock-services/ subdirectories are never picked up) whose `kind:` is RestApi.
# For the default ORG=public that is exactly:
#   - apis/agent-chat-rate-limiting/AgentChatAPI-v1.0.yaml
#   - apis/air-quality-api-v1.0/AirQualityAPI-v1.0.yaml
#   - apis/weather-api-v1.0/WeatherAPI-v1.0.yaml
# and for acme/railco it additionally picks up OrderManagementAPI-v1.0.yaml.
# Pass explicit file paths as arguments to deploy just those instead.
#
# Usage:
#   ./scripts/seed-gateway.sh                        # all of public's gateway APIs
#   ORG=acme ./scripts/seed-gateway.sh               # all of acme's
#   ./scripts/seed-gateway.sh path/to/SomeAPI.yaml   # just these files
#
# GW_MGMT_URL (default http://platform.gw.wso2.com:9090) is the gateway's
# management listener — note this is the MANAGEMENT port, not the traffic port
# APIs are invoked on. GW_USER / GW_PASS (default admin/admin) are its basic
# auth credentials. ORG (default "public") / ARTIFACTS_ROOT select the bundle
# directory when no explicit file arguments are given.
#
# Safe to re-run: an API the gateway already has is updated in place with a PUT
# (the same YAML produces the same deployed state), so re-running only ever
# converges the gateway on what is in these files. DRY_RUN=1 lists what would
# be deployed and exits without touching the gateway.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$THIS_DIR/.." && pwd)"

GW_MGMT_URL="${GW_MGMT_URL:-http://platform.gw.wso2.com:9090}"
GW_MGMT_BASE="${GW_MGMT_BASE:-/api/management/v1}"
GW_USER="${GW_USER:-admin}"
GW_PASS="${GW_PASS:-admin}"
ORG="${ORG:-public}"
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-$PROJECT_DIR/artifacts/via-script}"

# Colors/symbols only when writing to an interactive terminal (respects the
# NO_COLOR convention: https://no-color.org/) — a piped/CI log gets plain
# ASCII instead of ANSI escapes and unicode glyphs.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
    SYM_OK="✓"; SYM_SKIP="•"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
    SYM_OK="OK"; SYM_SKIP="-"
fi

log() { echo "${C_DIM}[seed-gateway]${C_RESET} $*"; }
fail() { echo "${C_RED}[seed-gateway] ERROR:${C_RESET} $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."

# --- Which YAMLs to deploy ---------------------------------------------------

FILES=()
if [ "$#" -gt 0 ]; then
    for f in "$@"; do
        [ -f "$f" ] || fail "no such file: $f"
        FILES+=("$f")
    done
else
    ORG_APIS_DIR="$ARTIFACTS_ROOT/$ORG/apis"
    [ -d "$ORG_APIS_DIR" ] || fail "no apis directory for org '$ORG' at $ORG_APIS_DIR (available: $(ls -1 "$ARTIFACTS_ROOT" 2>/dev/null | tr '\n' ' '))"
    # Only one level down: api-portal/ and mock-services/ subdirectories hold
    # portal metadata and mock backends, neither of which the gateway accepts.
    # `kind: RestApi` is then what distinguishes a gateway definition from any
    # other stray YAML a bundle might grow later.
    while IFS= read -r f; do
        grep -qE '^kind:[[:space:]]*RestApi[[:space:]]*$' "$f" && FILES+=("$f")
    done < <(find "$ORG_APIS_DIR" -mindepth 2 -maxdepth 2 -name '*.yaml' | sort)
    [ "${#FILES[@]}" -gt 0 ] || fail "no gateway RestApi YAMLs found under $ORG_APIS_DIR."
fi

# metadata.name is the id the management API addresses an API by — the PUT
# path below needs it, and it is not always the file's basename.
api_name_from() {
    local name
    name=$(awk '
        /^metadata:[[:space:]]*$/ { in_md = 1; next }
        in_md && /^[^[:space:]]/  { exit }
        in_md && /^[[:space:]]+name:/ {
            sub(/^[[:space:]]+name:[[:space:]]*/, "")
            gsub(/["'"'"']/, ""); sub(/[[:space:]]+$/, "")
            print; exit
        }' "$1")
    [ -n "$name" ] || name="$(basename "$1" .yaml)"
    echo "$name"
}

log "Gateway: ${C_BOLD}$GW_MGMT_URL$GW_MGMT_BASE${C_RESET}"
if [ "$#" -gt 0 ]; then
    log "Deploying ${#FILES[@]} file(s) given on the command line ..."
else
    log "Deploying org '${C_BOLD}$ORG${C_RESET}''s ${#FILES[@]} gateway API(s) ..."
fi

if [ -n "${DRY_RUN:-}" ]; then
    for f in "${FILES[@]}"; do
        echo "  $(api_name_from "$f")  ${C_DIM}${f#$PROJECT_DIR/}${C_RESET}"
    done
    log "DRY_RUN set — nothing was deployed."
    exit 0
fi

# --- Deploy ------------------------------------------------------------------
# POST creates; an API the gateway already knows is updated with a PUT to
# .../rest-apis/{name} instead. The create is attempted first and its
# "already exists" rejection used as the signal to switch, rather than listing
# first and matching names, so a name the listing spells differently from
# metadata.name can never silently turn an update into a duplicate-create
# attempt.
deploy_one() {
    local file="$1"
    local name; name=$(api_name_from "$file")
    local body_file="/tmp/seed-gateway-$$.out"
    local status

    status=$(curl -s -o "$body_file" -w "%{http_code}" -m 60 \
        -u "$GW_USER:$GW_PASS" -X POST "$GW_MGMT_URL$GW_MGMT_BASE/rest-apis" \
        -H "Content-Type: text/yaml" --data-binary "@$file")
    local body; body=$(cat "$body_file")

    case "$status" in
        200|201)
            rm -f "$body_file"
            log "  ${C_GREEN}${SYM_OK}${C_RESET} $name ${C_DIM}(created)${C_RESET}"
            return 0
            ;;
        409|400|422|500)
            # Only a genuine "already exists" is retried as an update — any
            # other 4xx/5xx here is a bad definition and must surface as a
            # failure, not be re-sent as a PUT that would 404 confusingly.
            if ! printf '%s' "$body" | grep -qiE 'already[ _-]?exist|duplicate|conflict'; then
                rm -f "$body_file"
                fail "failed to deploy '$name' from $file (HTTP $status): $body"
            fi
            ;;
        *)
            rm -f "$body_file"
            fail "failed to deploy '$name' from $file (HTTP $status): $body"
            ;;
    esac

    status=$(curl -s -o "$body_file" -w "%{http_code}" -m 60 \
        -u "$GW_USER:$GW_PASS" -X PUT "$GW_MGMT_URL$GW_MGMT_BASE/rest-apis/$name" \
        -H "Content-Type: text/yaml" --data-binary "@$file")
    body=$(cat "$body_file"); rm -f "$body_file"
    case "$status" in
        200|201|204) log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $name ${C_DIM}(already deployed — updated in place)${C_RESET}" ;;
        *) fail "'$name' already exists but updating it failed (HTTP $status): $body" ;;
    esac
}

for f in "${FILES[@]}"; do
    deploy_one "$f"
done

# --- Report what the gateway holds now ---------------------------------------

echo
DEPLOYED=$(curl -s -m 30 -u "$GW_USER:$GW_PASS" "$GW_MGMT_URL$GW_MGMT_BASE/rest-apis" || true)
if command -v jq >/dev/null 2>&1 && printf '%s' "$DEPLOYED" | jq -e . >/dev/null 2>&1; then
    log "${C_GREEN}${C_BOLD}Done.${C_RESET} APIs now deployed on this gateway:"
    printf '%s' "$DEPLOYED" | jq -r '
        (.apis // .list // .data // [])[]
        | "  - \(.name // .metadata.name // .id // "?")"
          + (if (.context // .spec.context) then "  \(.context // .spec.context)" else "" end)'
else
    log "${C_GREEN}${C_BOLD}Done.${C_RESET} Gateway listing: $DEPLOYED"
fi
