#!/bin/bash
#
# Remnawave ↔ SHM template (v1.3, resolve internal squad by NAME only, no cache)
# Значения берутся из server.settings.remnawave.* — UUID внутреннего сквада НЕ используется.
#
set -euo pipefail

# ---- SHM placeholders ----
EVENT="{{ event_name }}"
SESSION_ID="{{ user.gen_session.id }}"
API_URL="{{ config.api.url }}"

# ---- server.settings.remnawave.* ----
PANEL_URL="{{ server.settings.remnawave.api }}"
REMNAWAVE_API_TOKEN="{{ server.settings.remnawave.token }}"
DEFAULT_INTERNAL_SQUAD_NAME="{{ server.settings.remnawave.default_internal_squad_name }}"

# New: tz & safety minutes pulled from server settings (with sane defaults)
# If SHM's {{ us.expire }} is in Moscow time, set shm_tz: Europe/Moscow
REMNAWAVE_SHM_TZ="{{ server.settings.remnawave.shm_tz }}"
REMNAWAVE_EXPIRE_SAFETY_MINUTES="{{ server.settings.remnawave.expire_safety_minutes }}"

USERNAME="us_{{ us.id }}"
STATUS_ACTIVE="ACTIVE"
STATUS_DISABLED="DISABLED"

log() { echo "[$(date +'%F %T')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

_auth_header() {
  [[ -n "${REMNAWAVE_API_TOKEN:-}" ]] || fail "server.settings.remnawave.token is empty"
  echo "Authorization: Bearer ${REMNAWAVE_API_TOKEN}"
}

# HTTP helpers (Remnawave)
_http_get()   { local p="$1"; shift; curl -skS -H "$(_auth_header)" "$@" "${PANEL_URL}${p}"; }
_http_post()  { local p="$1"; shift; curl -skS -X POST -H "$(_auth_header)" -H 'Content-Type: application/json' "$@" "${PANEL_URL}${p}"; }
_http_patch() { local p="$1"; shift; curl -skS -X PATCH -H "$(_auth_header)" -H 'Content-Type: application/json' "$@" "${PANEL_URL}${p}"; }

# Helpers
# Expire: interpret {{ us.expire }} as LOCAL time in SHM TZ (or system TZ), then output UTC (Z)
_expire_iso() {
  local base="{{ us.expire }}"
  local mins="${REMNAWAVE_EXPIRE_SAFETY_MINUTES:-0}"

  local base_epoch
  if [[ -n "${REMNAWAVE_SHM_TZ}" ]]; then
    base_epoch="$(TZ="${REMNAWAVE_SHM_TZ}" date -d "${base}" +%s)" || fail "cannot parse us.expire in ${REMNAWAVE_SHM_TZ}"
  else
    base_epoch="$(date -d "${base}" +%s)" || fail "cannot parse us.expire (system TZ)"
  fi

  local final_epoch=$(( base_epoch + mins*60 ))
  date -u -d "@${final_epoch}" +"%Y-%m-%dT%H:%M:%SZ"
}

_user_uuid_by_username() {
  local username="$1"
  _http_get "/api/users/by-username/${username}" | jq -r '.response.uuid // .response.user.uuid // empty'
}

_subscription_json_by_username() {
  local username="$1"
  _http_get "/api/subscriptions/by-username/${username}"
}

_normalize_subscription_json() {
  # Adds legacy alias .response.subscription_url = .response.subscriptionUrl (if exists)
  jq '.response |= (if has("subscriptionUrl") then . + {subscription_url: .subscriptionUrl} else . end)'
}

# Всегда резолвим UUID внутреннего сквада по ИМЕНИ (без кеша)
_resolve_internal_squad_uuid_by_name() {
  [[ -n "${DEFAULT_INTERNAL_SQUAD_NAME:-}" ]] || fail "server.settings.remnawave.default_internal_squad_name is empty"
  local uuid
  uuid="$(_http_get "/api/internal-squads" | jq -r --arg NAME "${DEFAULT_INTERNAL_SQUAD_NAME}" '.response.internalSquads[] | select(.name==$NAME) | .uuid' | head -n1)"
  [[ -n "${uuid}" ]] || fail "Internal Squad '${DEFAULT_INTERNAL_SQUAD_NAME}' not found on panel ${PANEL_URL}"
  echo "${uuid}"
}

# Actions
_bulk_delete_users()        { local uuid="$1"; _http_post "/api/users/bulk/delete" --data "{\"uuids\":[\"${uuid}\"]}" >/dev/null; }
_bulk_revoke_subscription() { local uuid="$1"; _http_post "/api/users/bulk/revoke-subscription" --data "{\"uuids\":[\"${uuid}\"]}" >/dev/null; }
_reset_user_traffic()       { local uuid="$1"; _http_post "/api/users/${uuid}/actions/reset-traffic" --data '{}' >/dev/null; }
_disable_user()             { local uuid="$1"; _http_post "/api/users/${uuid}/actions/disable" --data '{}' >/dev/null; }
_enable_user()              { local uuid="$1"; _http_post "/api/users/${uuid}/actions/enable" --data '{}' >/dev/null; }

# Payloads
_build_create_payload() {
  local expire_iso="$(_expire_iso)"
  local squad_uuid="$(_resolve_internal_squad_uuid_by_name)"
  cat <<JSON
{
  "username": "${USERNAME}",
  "status": "${STATUS_ACTIVE}",
  "trafficLimitBytes": 0,
  "trafficLimitStrategy": "NO_RESET",
  "expireAt": "${expire_iso}",
  "description": "SHM: login={{ user.login }}, name={{ user.full_name }}, url=https://t.me/{{ user.settings.telegram.login }}",
  "tag": null,
  "telegramId": null,
  "email": null,
  "hwidDeviceLimit": 0,
  "activeInternalSquads": ["${squad_uuid}"],
  "externalSquadUuid": null
}
JSON
}

_build_update_payload() {
  local uuid="$1"
  local expire_iso="$(_expire_iso)"
  cat <<JSON
{
  "uuid": "${uuid}",
  "status": "${STATUS_ACTIVE}",
  "expireAt": "${expire_iso}"
}
JSON
}

log "Remnawave Template v1.3 (resolve by name only)"
log "EVENT=${EVENT}"

case "${EVENT}" in
  INIT)
    log "Check SHM API: ${API_URL}"
    code="$(curl -sk -o /dev/null -w "%{http_code}" "${API_URL}/shm/v1/test")" || true
    [[ "${code}" == "200" ]] || fail "Incorrect SHM API URL: ${API_URL} (status ${code})"
    log "OK"
    ;;

  CREATE)
    log "Create user ${USERNAME}"
    payload="$(_build_create_payload)"
    resp="$(_http_post '/api/users' --data "${payload}")"
    uuid="$(echo "${resp}" | jq -r '.response.user.uuid // .response.uuid // empty')"
    [[ -n "${uuid}" ]] || fail "Create user failed: ${resp}"

    log "Fetch subscription JSON"
    sub_json="$(_subscription_json_by_username "${USERNAME}")"
    sub_json_body="$(echo "${sub_json}" | _normalize_subscription_json | jq -c '.response')"

    log "Upload JSON to SHM key vpn_mrzb_{{ us.id }}"
    echo "${sub_json_body}" | jq -c '.' > /tmp/payload.json
    curl -skS -X PUT \
      -H "session-id: ${SESSION_ID}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data-binary @/tmp/payload.json \
      "${API_URL}/shm/v1/storage/manage/vpn_mrzb_{{ us.id }}" >/dev/null
    rm -f /tmp/payload.json

    log "done"
    ;;

  ACTIVATE)
    log "Activate ${USERNAME}"
    uuid="$(_user_uuid_by_username "${USERNAME}")"
    [[ -n "${uuid}" ]] || fail "User not found: ${USERNAME}"

    _enable_user "${uuid}"
    payload="$(_build_update_payload "${uuid}")"
    _http_patch "/api/users" --data "${payload}" >/dev/null
    log "done"
    ;;

  BLOCK)
    log "Block ${USERNAME}"
    uuid="$(_user_uuid_by_username "${USERNAME}")"
    [[ -n "${uuid}" ]] || fail "User not found: ${USERNAME}"
    _disable_user "${uuid}"
    log "done"
    ;;

  REMOVE)
    log "Remove ${USERNAME}"
    uuid="$(_user_uuid_by_username "${USERNAME}")"
    [[ -n "${uuid}" ]] || fail "User not found: ${USERNAME}"

    _bulk_revoke_subscription "${uuid}"
    _bulk_delete_users "${uuid}"

    log "Delete SHM key vpn_mrzb_{{ us.id }}"
    curl -skS -X DELETE -H "session-id: ${SESSION_ID}" "${API_URL}/shm/v1/storage/manage/vpn_mrzb_{{ us.id }}" >/dev/null || true
    log "done"
    ;;

  PROLONGATE)
    log "Prolongate ${USERNAME} + reset traffic"
    uuid="$(_user_uuid_by_username "${USERNAME}")"
    [[ -n "${uuid}" ]] || fail "User not found: ${USERNAME}"

    _reset_user_traffic "${uuid}"
    payload="$(_build_update_payload "${uuid}")"
    _http_patch "/api/users" --data "${payload}" >/dev/null
    log "done"
    ;;

  UPDATE)
    log "Update SHM JSON for ${USERNAME}"
    sub_json="$(_subscription_json_by_username "${USERNAME}")"
    sub_json_body="$(echo "${sub_json}" | _normalize_subscription_json | jq -c '.response')"
    echo "${sub_json_body}" | jq -c '.' > /tmp/payload.json
    curl -skS -X PUT \
      -H "session-id: ${SESSION_ID}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data-binary @/tmp/payload.json \
      "${API_URL}/shm/v1/storage/manage/vpn_mrzb_{{ us.id }}" >/dev/null
    rm -f /tmp/payload.json
    log "done"
    ;;

  *)
    log "Unknown event: ${EVENT}"
    ;;
esac
