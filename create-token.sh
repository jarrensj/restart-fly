#!/usr/bin/env bash
# Creates a restart-only Fly token for an app, checks that it can't do more
# than restart, and saves it to this repo as the FLY_RESTART_TOKEN secret, along
# with the FLY_APP variable. The token is never printed.
#
#   ./create-token.sh <fly-app>
#
# Needs flyctl (logged in with access to the app), gh, curl and jq. Run it from
# your copy of this repo, or set GH_REPO=owner/repo.
set -euo pipefail

app="${1:?usage: ./create-token.sh <fly-app>}"
name="${TOKEN_NAME:-restart-fly (restart only, no exec)}"

# Machines rC: machines can be read and controlled (start, stop, restart,
# signal) but not changed, created or deleted, and anything that isn't a
# machine (secrets, logs, deploys, SSH) is refused.
# IfPresent + empty Commands: rC alone still allows exec, which could read the
# app's secrets from its environment. This applies only to exec requests and
# allows no commands, so exec is refused and nothing else changes.
caveats='[
  {"type":"Machines","body":{"machines":{"":"rC"}}},
  {"type":"IfPresent","body":{"ifs":[{"type":"Commands","body":[]}],"else":"rwcdC"}}
]'

base="$(fly tokens create deploy -a "$app" -n "$name")"
token="$(printf '%s' "$caveats" | FLY_API_TOKEN="$base" fly tokens attenuate)"
unset base

api="https://api.machines.dev/v1/apps/$app"
status() { curl -s -o /dev/null -w '%{http_code}' -m 30 -H "Authorization: $token" "$@"; }

fail() {
  echo "$1" >&2
  echo "Not saved. Revoke \"$name\": fly tokens list -a $app, then fly tokens revoke <id>." >&2
  exit 1
}

list="$(status "$api/machines")"
[ "$list" = 200 ] || fail "Listing machines returned $list, expected 200."
machine="$(curl -sS -m 30 -H "Authorization: $token" "$api/machines" | jq -r '.[0].id // empty')"
[ -n "$machine" ] || fail "$app has no machines to restart."

# If exec were allowed this would run `true` on the machine, which does nothing.
exec="$(status -X POST -H 'content-type: application/json' \
  -d '{"command":["true"],"timeout":5}' "$api/machines/$machine/exec")"
secrets="$(status "$api/secrets")"
echo "list machines: $list (want 200), exec: $exec (want 403), secrets: $secrets (want 403)"
[ "$exec" != 200 ] || fail "The token can run commands on machines."
[ "$secrets" != 200 ] || fail "The token can read secrets."

printf '%s' "$token" | gh secret set FLY_RESTART_TOKEN
unset token
gh variable set FLY_APP --body "$app"
echo "Saved the FLY_RESTART_TOKEN secret and the FLY_APP variable."
