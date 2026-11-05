#!/usr/bin/env bash
set -euo pipefail

# Ephemeral GitHub Actions runner entrypoint.
#
# Authentication uses a GitHub App instead of a PAT. The app private key is the
# only long-lived credential on the runner path; it is mounted read-only as the
# compose secret file /run/secrets/github_app_key. Each registration cycle signs
# a short-lived JWT with the app client ID as the issuer, exchanges it for a
# one-hour installation token that requests only the administration:write
# permission, and exchanges that for a runner registration token. No credential
# value is printed or written to disk.

APP_KEY_FILE="/run/secrets/github_app_key"

# ────────────────────────────────────────────────────────────────
#  Validate inputs
# ────────────────────────────────────────────────────────────────

if [[ ! -f "${APP_KEY_FILE}" || ! -r "${APP_KEY_FILE}" || ! -s "${APP_KEY_FILE}" ]]; then
  echo "ERROR: the App private key file ${APP_KEY_FILE} is missing, unreadable, or empty."
  echo "Place the key on the host and mount it as a compose secret; see README Part 2."
  exit 1
fi

if [[ -z "${CLIENT_ID:-}" || ! "${CLIENT_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: CLIENT_ID must be set to the client ID of the GitHub App; GitHub recommends it as the JWT issuer."
  echo "Set the value statically in the compose environment; see README Part 2."
  exit 1
fi

if [[ -z "${INSTALLATION_ID:-}" || ! "${INSTALLATION_ID}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: INSTALLATION_ID must be set to its numeric value from the GitHub App record."
  echo "Set both values statically in the compose environment; see README Part 2."
  exit 1
fi

TOKEN_API=""
RUNNER_URL=""

if [[ -n "${REPO_URL:-}" ]]; then
  owner=$(echo "$REPO_URL" | awk -F/ '{print $(NF-1)}')
  repo=$(echo "$REPO_URL" | awk -F/ '{print $NF}')
  TOKEN_API="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
  RUNNER_URL="$REPO_URL"
elif [[ "${RUNNER_SCOPE:-}" == "org" && -n "${ORG_NAME:-}" ]]; then
  TOKEN_API="https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token"
  RUNNER_URL="https://github.com/${ORG_NAME}"
else
  echo "ERROR: set REPO_URL=https://github.com/owner/repo (repo scope), or ORG_NAME=org with RUNNER_SCOPE=org (org scope)."
  echo "Each runner service defines its values statically in the compose file; see README Part 4."
  exit 1
fi

# The runner name. The cache layout keys on it below, and the stale-runner
# cleanup section matches it exactly.
name="${RUNNER_NAME:-ephemeral-$(hostname)-$RANDOM}"

# ────────────────────────────────────────────────────────────────
#  GitHub App credentials
# ────────────────────────────────────────────────────────────────

# Encode stdin as unpadded base64url, per RFC 7515.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '=\n'; }

# Print a GitHub App JWT: RS256 over the {"alg","typ"} header and a
# {"iss","iat","exp"} payload. The issuer is the app client ID, which
# GitHub recommends over the numeric app ID. The issue time sits 60
# seconds in the past for clock drift (GitHub's current guidance), and
# exp stays 9 minutes after iat, inside the 10-minute future cap GitHub
# accepts. The key file is signed directly, so the key content never
# enters a shell variable.
mint_jwt() {
  local client_id="$1" key_file="$2" iat exp header payload signature
  iat=$(( $(date +%s) - 60 ))
  exp=$((iat + 540))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iss":"%s","iat":%s,"exp":%s}' "$client_id" "$iat" "$exp" | b64url)
  signature=$(printf '%s' "${header}.${payload}" | openssl dgst -binary -sha256 -sign "${key_file}" | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# Drop every value that held a credential. Runs once through the EXIT trap on
# error paths, and once explicitly below, because exec replaces the process
# without running EXIT traps.
clear_credentials() {
  unset -v jwt install_token reg_token install_body reg_body install_response reg_response
}
trap clear_credentials EXIT

echo "Minting the App JWT (9-minute window)..."
# CLIENT_ID and INSTALLATION_ID come from the compose environment, not this script.
# shellcheck disable=SC2153
jwt=$(mint_jwt "${CLIENT_ID}" "${APP_KEY_FILE}") || {
  echo "ERROR: the key file is not a usable RSA private key for a GitHub App; see README Part 2."
  exit 1
}

echo "Requesting the installation access token..."
install_response=$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  -d '{"permissions":{"administration":"write"}}' \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens") || {
  echo "ERROR: could not reach the GitHub API; verify host connectivity; see README Part 4."
  exit 1
}
install_status=${install_response##*$'\n'}
install_body=${install_response%$'\n'*}
unset -v install_response

case "${install_status}" in
  200|201)
    install_token=$(printf '%s' "${install_body}" | jq -r '.token // empty')
    ;;
  401)
    echo "ERROR: HTTP 401 from the access-token endpoint; the private key does not match CLIENT_ID ${CLIENT_ID}. Download the app key again and replace the secret file; see README Part 2."
    exit 1
    ;;
  404)
    echo "ERROR: HTTP 404 from the access-token endpoint; INSTALLATION_ID ${INSTALLATION_ID} does not exist, or the app is not installed on the target repo; see README Part 1."
    exit 1
    ;;
  403)
    echo "ERROR: HTTP 403 from the access-token endpoint; the app lacks the Administration repository permission at Read and write; see README Part 1."
    exit 1
    ;;
  *)
    echo "ERROR: unexpected HTTP ${install_status} from the access-token endpoint; see README Part 1."
    exit 1
    ;;
esac
unset -v install_body jwt

if [[ -z "${install_token}" ]]; then
  echo "ERROR: the access-token response carried no token; see README Part 1."
  exit 1
fi

# Pre-registration cleanup. docker compose down can kill a runner container
# while its session is still live, and the actions service keeps that orphaned
# session for a short time. A re-created same-name runner cannot create its
# own session until the orphan expires and reports "A session for this
# runner already exists." for that whole time. Delete the stale same-name
# runner record first; that is the API equivalent of removing the runner in
# the web UI. Best effort: on any failure here the register step and the
# runner's own session retries still clear the conflict.
runners_api="${TOKEN_API%/registration-token}"
runners_response=$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' \
  -H "Authorization: Bearer ${install_token}" \
  -H "Accept: application/vnd.github+json" \
  "${runners_api}?per_page=100") || true
if [[ -z "${runners_response}" ]]; then
  echo "WARNING: could not reach the runners API; skipping the stale-runner cleanup."
else
  runners_status=${runners_response##*$'\n'}
  runners_body=${runners_response%$'\n'*}
  if [[ "${runners_status}" == "200" ]]; then
    truncated=$(printf '%s' "${runners_body}" | jq -r 'if (.total_count // 0) > (.runners | length) then "yes" else "no" end')
    if [[ "${truncated}" == "yes" ]]; then
      echo "WARNING: the runners list has more than one page; the first 100 entries were checked." >&2
    fi
    stale_ids=$(printf '%s' "${runners_body}" | jq -r --arg n "${name}" '.runners[]? | select(.name == $n) | .id')
    for stale_id in ${stale_ids}; do
      delete_status=$(curl -sS -o /dev/null --connect-timeout 15 --max-time 60 -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer ${install_token}" \
        -H "Accept: application/vnd.github+json" \
        "${runners_api}/${stale_id}") || true
      echo "Processed the stale runner ${name} (id ${stale_id}); HTTP ${delete_status}."
    done
  else
    echo "WARNING: HTTP ${runners_status} from the runners API; skipping the stale-runner cleanup."
  fi
fi
unset -v runners_response runners_status runners_body truncated stale_ids

echo "Requesting the runner registration token from GitHub..."
reg_response=$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${install_token}" \
  -H "Accept: application/vnd.github+json" \
  "${TOKEN_API}") || {
  echo "ERROR: could not reach the GitHub API; verify host connectivity; see README Part 4."
  exit 1
}
reg_status=${reg_response##*$'\n'}
reg_body=${reg_response%$'\n'*}
unset -v reg_response

case "${reg_status}" in
  200|201)
    reg_token=$(printf '%s' "${reg_body}" | jq -r '.token // empty')
    ;;
  403)
    echo "ERROR: HTTP 403 from the registration-token endpoint; the app lacks the Administration repository permission at Read and write; see README Part 1."
    exit 1
    ;;
  401)
    echo "ERROR: HTTP 401 from the registration-token endpoint; the installation token was rejected; see README Part 1."
    exit 1
    ;;
  *)
    echo "ERROR: unexpected HTTP ${reg_status} from the registration-token endpoint; see README Part 1."
    exit 1
    ;;
esac
unset -v reg_body

if [[ -z "${reg_token}" ]]; then
  echo "ERROR: Failed to get registration token from GitHub; see README Part 1."
  exit 1
fi
echo "Registration token obtained."

# ────────────────────────────────────────────────────────────────
#  Shared caches on /srv/cache
# ────────────────────────────────────────────────────────────────

install -d \
  /srv/cache/cargo \
  /srv/cache/cargo/bin \
  "/srv/cache/cargo-target/${name}" \
  /srv/cache/sccache

export RUSTUP_HOME=/usr/local/rustup
export PATH="/usr/local/cargo/bin:${PATH}"
export CARGO_HOME=/srv/cache/cargo
export PATH="${CARGO_HOME}/bin:${PATH}"
export RUSTC_WRAPPER=sccache
export SCCACHE_DIR=/srv/cache/sccache
export SCCACHE_CACHE_SIZE=50G
export CARGO_TARGET_DIR="/srv/cache/cargo-target/${name}"

# Best-effort prune of build dirs idle for over 14 days. A pruned dir rebuilds
# largely from the sccache cache, so the policy costs little re-work. Must
# never block registration.
if pruned=$(find /srv/cache/cargo-target -mindepth 1 -maxdepth 1 -type d -mtime +14 -print -exec rm -rf {} + 2>/dev/null); then
  if [[ -n "${pruned}" ]]; then
    echo "Pruned build dirs idle for over 14 days:"
    printf '  %s\n' "${pruned}"
  fi
else
  echo "WARNING: the stale build-dir prune failed; continuing without it." >&2
fi

# ────────────────────────────────────────────────────────────────
#  Register and start the runner
# ────────────────────────────────────────────────────────────────

echo ""
echo "Registering runner:"
echo "  Name:   ${name}"
echo "  URL:    ${RUNNER_URL}"
echo "  Labels: ${LABELS:-none}"
echo ""

cd /actions-runner

label_args=()
if [[ -n "${LABELS:-}" ]]; then
  label_args=(--labels "${LABELS}")
fi

./config.sh \
  --url "${RUNNER_URL}" \
  --token "${reg_token}" \
  --name "${name}" \
  --ephemeral \
  --unattended \
  --replace \
  --disableupdate \
  "${label_args[@]}"

echo ""
echo "Runner configured successfully. Launching."
echo ""

clear_credentials
exec ./run.sh
