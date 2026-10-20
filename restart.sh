#!/usr/bin/env bash
# Restarts a Fly.io app's machines through the Fly Machines API, one at a time,
# waiting for each to come back up before moving on.
#
# Required: FLY_APP, and FLY_API_TOKEN (a restart-only token, see README).
# Optional: HEALTH_URL, PROCESS_GROUP, WAIT_SECONDS.
set -euo pipefail

: "${FLY_APP:?FLY_APP is not set}"
: "${FLY_API_TOKEN:?FLY_API_TOKEN is not set}"
HEALTH_URL="${HEALTH_URL:-}"
# The process group `fly deploy` manages. Machines outside it are left alone.
PROCESS_GROUP="${PROCESS_GROUP:-app}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"

case "$FLY_API_TOKEN" in
  FlyV1\ *) auth="$FLY_API_TOKEN" ;;
  *) auth="Bearer $FLY_API_TOKEN" ;;
esac
machines_url="https://api.machines.dev/v1/apps/$FLY_APP/machines"

# On an error status, Fly's message goes to stderr instead of being parsed as a
# response.
fly_api() {
  local out
  if ! out="$(curl -sS --fail-with-body -m 30 -H "Authorization: $auth" "$@")"; then
    echo "Fly API: $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

summary() {
  echo "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >>"$GITHUB_STEP_SUMMARY"
}

machines="$(fly_api "$machines_url")"
ids="$(jq -r --arg g "$PROCESS_GROUP" '.[] | select(.config.metadata.fly_process_group == $g) | .id' <<<"$machines")"
if [ -z "$ids" ]; then
  summary "No machines in the $PROCESS_GROUP process group."
  exit 1
fi

for id in $ids; do
  machine="$(fly_api "$machines_url/$id")"
  state="$(jq -r .state <<<"$machine")"
  # Newest event before we act. An exit or start event after it means the old
  # process is gone, so whatever answers next is the new one.
  before="$(jq '[.events[]?.timestamp] | max // 0' <<<"$machine")"

  case "$state" in
    started)
      # Stop the way a deploy does: the app's kill_signal and kill_timeout from
      # fly.toml. Unset ones fall back to Fly's defaults.
      query="force_stop=false"
      signal="$(jq -r '.config.stop_config.signal // empty' <<<"$machine")"
      timeout="$(jq -r '.config.stop_config.timeout // empty' <<<"$machine")"
      [ -z "$signal" ] || query="$query&signal=$signal"
      [ -z "$timeout" ] || query="$query&timeout=$timeout"
      echo "Restarting $id (${signal:-default signal}, ${timeout:-default timeout} to stop)"
      # Fly holds this request open until the machine has stopped. When that
      # takes about a minute, as it does for a stuck app that uses its whole
      # kill_timeout, Fly answers 408 but finishes the restart anyway. The wait
      # below checks that it really happened, so a 408 isn't a failure.
      out="$(curl -sS -m 300 -w '\n%{http_code}' -X POST -H "Authorization: $auth" \
        "$machines_url/$id/restart?$query")"
      code="${out##*$'\n'}"
      case "$code" in
        2??) ;;
        408) echo "  Fly's API timed out waiting for $id to stop; waiting for the restart to finish" ;;
        *)
          echo "Fly API: $code ${out%$'\n'*}" >&2
          exit 1
          ;;
      esac
      ;;
    stopped | suspended)
      # Fly gave up restarting a crashing process, or someone stopped it.
      echo "$id is $state, starting it"
      fly_api -X POST "$machines_url/$id/start" >/dev/null
      ;;
    *)
      summary "$id is $state, not started or stopped. A deploy may be rolling it; try again in a minute."
      exit 1
      ;;
  esac

  deadline=$((SECONDS + WAIT_SECONDS))
  last=""
  up=false
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 3
    # A Machines API blip mid-restart shouldn't fail the run; keep polling.
    machine="$(fly_api "$machines_url/$id" 2>/dev/null)" || continue
    now="$(jq -r .state <<<"$machine")"
    [ "$now" = "$last" ] || echo "  $id: $now"
    last="$now"
    [ "$now" = started ] || continue
    jq -e --argjson t "$before" 'any(.events[]?; .timestamp > $t and (.type == "exit" or .type == "start"))' \
      <<<"$machine" >/dev/null || continue
    # Fly's own health checks for the machine, if it has any.
    jq -e 'all(.checks[]?; .status == "passing")' <<<"$machine" >/dev/null || continue
    # Quiet: the URL refuses or errors for a few seconds while the app boots.
    if [ -n "$HEALTH_URL" ]; then
      curl -fs -m 5 -o /dev/null "$HEALTH_URL" || continue
    fi
    up=true
    break
  done

  if ! $up; then
    summary "$id didn't come back within ${WAIT_SECONDS}s (last state: ${last:-unknown}). Check \`fly status\` and the app's logs."
    exit 1
  fi
  # What it's running: the commit when flyctl deployed from GitHub Actions
  # (it labels the image), otherwise the image tag.
  version="$(jq -r '.image_ref.labels.GH_SHA // "" | .[0:7]' <<<"$machine")"
  [ -n "$version" ] || version="$(jq -r '.image_ref.tag // "unknown"' <<<"$machine")"
  summary "$id is back up, running \`$version\`."
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "version=$version" >>"$GITHUB_OUTPUT"
done
