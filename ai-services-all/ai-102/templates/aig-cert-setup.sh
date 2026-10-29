#!/bin/bash
# AIG setup and readiness reporter — runs on the bastion as aig-cert-setup.service
# (Restart=always). It never exits on its own.
#
# Each step below is retried until it reads back positive; a step that is not
# yet true is fixed through the AIG Configuration API where possible, then read
# back again before moving on. Every state change is reported to the SSM
# parameter READY_PARAM, which the Terraform aig_ready gate polls.
#
# The AIG Config API rejects the DLP host while DLPoD is not responding, and the
# AI Guardrails host while Guardrails is not responding. When the AIG boots before
# them (the wait_for_* variables are false) its bootstrap completes but fails to
# set those hosts, and the dlp and guardrails steps keep retrying until the
# instances are healthy and the API accepts the settings.
#
#   prereqs      SSH key, lab root CA key and certificate, jq are present
#   instance     the AIG EC2 instance (Name tag AIG_NAME) is running
#   api          AIG public FQDN is known; SSH to the AIG and generate a 1 hour
#                Config API token (regenerated on HTTP 401 or after ~50 minutes)
#   enrollment   GET /v1/config/bootstrap status is "completed"
#   certificate  no certificate: request a CSR, sign it with the lab root CA and
#                install it; then GET /v1/config/certificate/status is "Active"
#   dlp          GET /v1/config/dlp has certificate_configured and
#                host_config.host_url == DLPOD_HOST; if not, PUT dlp/ca-cert
#                (the lab root CA) and PUT dlp/hostconfig, then GET again
#   guardrails   GET /v1/config/ai-guardrails host_config.host_url ==
#                GUARDRAILS_HOST; if not, PUT ai-guardrails/hostconfig, then
#                GET again
#
# READY_PARAM holds one line listing the steps that have passed, the step being
# waited on, and the steps still to come, e.g.
#   passed: prereqs, instance, api, enrollment | waiting on: certificate | then: dlp, guardrails | last error: <error>
# When every step has passed it holds "healthy:<AIG instance id>". A permanent
# failure (bootstrap status failed) starts the line with "FAILED: <step> | " and
# lasts until that AIG instance is replaced. After "healthy" the script keeps
# watching the AIG instance and starts over if it is replaced.
#
# Settings come from /etc/aig-cert-setup.conf, written by the bastion user-data.
# Steps and errors are logged with timestamps to /var/log/aig-cert-setup.log.
# Runs as root; the key, CA and generated certificate files live in /home/ssm-user.

CONF=/etc/aig-cert-setup.conf
LOG=/var/log/aig-cert-setup.log

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
err() { LAST_ERR="$*"; log "ERROR: $*"; return 1; }

# shellcheck disable=SC1090
. "$CONF" || { log "ERROR: cannot read $CONF"; exit 1; }

AWS=/snap/bin/aws
BASE="https://$AIG_PRIVATE_IP:8443"
HOME_DIR=/home/ssm-user
CSR=$HOME_DIR/aig-cert-request.csr
SIGNED=$HOME_DIR/aig-cert-signed.pem
NOT_FOUND='resource not found: failed to get certificate status'
GR_PATH=/v1/config/ai-guardrails
DLP_PATH=/v1/config/dlp
RETRY=60        # seconds between attempts at a step
WATCH=30        # seconds between checks that the AIG instance is unchanged
REFRESH=600     # seconds before an unchanged status is written to SSM again

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

STEPS=(prereqs instance api enrollment certificate dlp guardrails)
declare -A STATE

AIG_ID=
CUR_ID=
TOKEN=
TOKEN_AT=0
HTTP_CODE=
BODY=
LAST_ERR=
LAST_REPORTED=
LAST_REPORTED_AT=0
CERT_POSTED_AT=
GR_CUR=
DLP_HOST=
DLP_CERT=

# ── helpers ──────────────────────────────────────────────────────────────────

# render — one-line status for READY_PARAM
render() {
  local s out= passed= waiting= todo= failed= e=${LAST_ERR//$'\n'/ }
  for s in "${STEPS[@]}"; do
    case "${STATE[$s]:-pending}" in
      ok) passed+="$s, " ;;
      waiting) waiting+="$s, " ;;
      failed) failed+="$s, " ;;
      *) todo+="$s, " ;;
    esac
  done
  [ -n "$failed" ] && out+="FAILED: ${failed%, } | "
  out+="passed: ${passed%, }"
  [ -z "$passed" ] && out+="none"
  [ -n "$waiting" ] && out+=" | waiting on: ${waiting%, }"
  [ -n "$todo" ] && out+=" | then: ${todo%, }"
  [ -n "$e" ] && out+=" | last error: ${e:0:300}"
  printf '%s' "$out"
}

# report [value] — write the status (default: render) to READY_PARAM. Skips an
# unchanged value unless it was last written more than REFRESH seconds ago.
report() {
  local v=${1:-$(render)} now
  now=$(date +%s)
  if [ "$v" = "$LAST_REPORTED" ] && [ $((now - LAST_REPORTED_AT)) -lt "$REFRESH" ]; then
    return 0
  fi
  if "$AWS" ssm put-parameter --name "$READY_PARAM" --value "$v" --type String \
        --overwrite --region "$REGION" >/dev/null 2>"$ERRF"; then
    LAST_REPORTED=$v
    LAST_REPORTED_AT=$now
  else
    log "WARNING: could not write $READY_PARAM: $(cat "$ERRF")"
  fi
}

# api <method> <path> [json-body] — sets HTTP_CODE and BODY; fails only when
# curl itself fails (HTTP error statuses are left for the caller to interpret).
# Generates a token when there is none or it is old, and again after a 401.
api() {
  local attempt out args
  for attempt in 1 2; do
    if [ -z "$TOKEN" ] || [ $(($(date +%s) - TOKEN_AT)) -ge 3000 ]; then
      get_token || return 1
    fi
    args=(-sk --max-time 30 -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN")
    [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
    out=$(curl "${args[@]}" "$BASE$2" 2>"$ERRF") \
      || { TOKEN=; err "curl $1 $2 failed: $(cat "$ERRF")"; return 1; }
    HTTP_CODE=${out##*$'\n'}
    BODY=${out%$'\n'*}
    if [ "$HTTP_CODE" = 401 ] && [ "$attempt" = 1 ]; then
      log "AIG rejected the API token (HTTP 401); generating a new one"
      TOKEN=
      continue
    fi
    return 0
  done
}

# jget <jq-filter> — print a field of $BODY (empty if missing, false or not JSON)
jget() { printf '%s' "$BODY" | jq -r "$1 // empty" 2>/dev/null; }

# current_aig_id — set CUR_ID to the running AIG instance id (empty if none)
current_aig_id() {
  local out
  out=$("$AWS" ec2 describe-instances --region "$REGION" \
          --filters "Name=tag:Name,Values=$AIG_NAME" "Name=instance-state-name,Values=running" \
          --query 'Reservations[].Instances[].InstanceId' --output text 2>"$ERRF") \
    || { err "ec2 describe-instances failed: $(cat "$ERRF")"; return 1; }
  CUR_ID=${out%%[[:space:]]*}
}

# watch_aig — block until the running AIG instance is no longer $AIG_ID,
# reporting the final status periodically so the SSM parameter stays current
watch_aig() {
  while sleep "$WATCH"; do
    [ -z "$1" ] || report "$1"
    current_aig_id || continue
    [ "$CUR_ID" = "$AIG_ID" ] && continue
    log "AIG instance changed (was $AIG_ID, now ${CUR_ID:-<none running>}); starting over"
    return 0
  done
}

# wait_for <step> <function> — retry the function until it returns 0. Return
# code 2 from the function is permanent for this AIG instance: report "failed"
# and wait for the instance to be replaced (this returns 3 so the caller starts over).
wait_for() {
  local name=$1 fn=$2 rc
  STATE[$name]=waiting
  while true; do
    "$fn"; rc=$?
    [ "$rc" -eq 0 ] && break
    if [ "$rc" -eq 2 ]; then
      STATE[$name]=failed
      report
      log "$name failed permanently for $AIG_ID; waiting for the AIG to be replaced"
      watch_aig
      return 3
    fi
    report
    log "$name is not ready; retrying in ${RETRY}s"
    sleep "$RETRY"
  done
  STATE[$name]=ok
  LAST_ERR=
  log "$name: ok"
  report
}

# ── steps ────────────────────────────────────────────────────────────────────

check_prereqs() {
  local f
  for f in "$SSH_KEY" "$CA_KEY" "$CA_CERT"; do
    [ -s "$f" ] || { err "$f is missing (not downloaded from Secrets Manager yet?)"; return 1; }
  done
  command -v jq >/dev/null || { err "jq is not installed"; return 1; }
  log "Prerequisites present (SSH key, lab root CA key and certificate, jq)"
}

check_instance() {
  current_aig_id || return 1
  [ -n "$CUR_ID" ] || { err "AIG EC2 instance '$AIG_NAME' is not running"; return 1; }
  AIG_ID=$CUR_ID
  log "AIG EC2 instance '$AIG_NAME' ($AIG_ID) is running"
}

get_token() {
  local out
  out=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
          "nsadmin@$AIG_PRIVATE_IP" 'enable-api --ttl 1h' 2>"$ERRF") \
    || { err "ssh enable-api on $AIG_PRIVATE_IP failed: $(cat "$ERRF")"; return 1; }
  TOKEN=$(printf '%s' "$out" | jq -r '.token // empty' 2>/dev/null)
  [ -n "$TOKEN" ] || { err "enable-api response has no \"token\" key"; return 1; }
  TOKEN_AT=$(date +%s)
  log "Generated 1 hour AIG Config API token"
}

check_api() {
  [ -n "$AIG_FQDN" ] || { err "AIG public FQDN is empty"; return 1; }
  log "AIG public FQDN: $AIG_FQDN"
  get_token
}

check_enrollment() {
  api GET /v1/config/bootstrap || return 1
  local s
  s=$(jget .status)
  case "${s,,}" in
    completed)
      log "AIG bootstrap status is completed (dlp=$(jget .dlp), ai_guardrails=$(jget .ai_guardrails))"
      ;;
    failed)
      err "AIG bootstrap failed (dlp=$(jget .dlp), ai_guardrails=$(jget .ai_guardrails)); the AIG must be replaced"
      return 2
      ;;
    *)
      err "AIG bootstrap status is '$s' (HTTP $HTTP_CODE), expected 'completed'"
      return 1
      ;;
  esac
}

request_csr() {
  local body csr
  body=$(jq -cn --arg cn "$AIG_FQDN" --argjson rest "$CSR_FIELDS" '{common_name: $cn} + $rest') \
    || { err "could not build the CSR request body"; return 1; }
  api POST /v1/config/certificate/csr "$body" || return 1
  csr=$(jget .csr)
  [ -n "$csr" ] || { err "CSR request failed (HTTP $HTTP_CODE): $BODY"; return 1; }
  csr=${csr//\\n/$'\n'}   # tolerate literal \n sequences
  printf '%s\n' "$csr" > "$CSR"
  if ! openssl req -in "$CSR" -noout -verify 2>"$ERRF"; then
    err "response key \"csr\" is not a valid CSR: $(cat "$ERRF")"
    rm -f "$CSR"
    return 1
  fi
  chown ssm-user:ssm-user "$CSR"
  log "Saved CSR for $AIG_FQDN to $CSR"
}

sign_csr() {
  local ext
  ext=$(mktemp)
  printf 'subjectAltName = DNS:%s\nextendedKeyUsage = serverAuth\n' "$AIG_FQDN" > "$ext"
  if ! openssl x509 -req -in "$CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" \
         -CAserial "$CA_SERIAL" -CAcreateserial -days "$CERT_DAYS" -sha256 \
         -extfile "$ext" -out "$SIGNED" 2>"$ERRF"; then
    rm -f "$ext"
    err "signing the CSR failed: $(cat "$ERRF")"
    return 1
  fi
  rm -f "$ext"
  openssl verify -CAfile "$CA_CERT" "$SIGNED" >/dev/null 2>"$ERRF" \
    || { err "signed certificate does not verify against the lab root CA: $(cat "$ERRF")"; return 1; }
  chown ssm-user:ssm-user "$SIGNED" "$CA_SERIAL" 2>/dev/null
  log "Signed the CSR (valid $CERT_DAYS days, SAN DNS:$AIG_FQDN, serverAuth) and saved $SIGNED"
}

install_cert() {
  local body
  body=$(jq -cn --rawfile cert "$SIGNED" '{certificate: $cert}') \
    || { err "could not build the install request body"; return 1; }
  api POST /v1/config/certificate/install "$body" || return 1
  case "$HTTP_CODE" in
    2*) log "Posted the signed certificate to the AIG (HTTP $HTTP_CODE)"; CERT_POSTED_AT=$(date +%s) ;;
    *) err "certificate install failed (HTTP $HTTP_CODE): $BODY"; return 1 ;;
  esac
}

# Reads the certificate status; installs a signed certificate when there is none
# (or when a saved CSR exists and the last install was over 5 minutes ago);
# succeeds only when the status reads back "Active".
check_certificate() {
  api GET /v1/config/certificate/status || return 1
  local msg st
  msg=$(jget .message)
  st=$(jq -r '[.. | objects | .status? | strings] | first // empty' <<<"$BODY" 2>/dev/null)

  if [ "$msg" = "$NOT_FOUND" ]; then
    log "AIG has no certificate yet; requesting a CSR"
    request_csr || return 1
  elif [ "${st,,}" = active ]; then
    log "AIG certificate status is Active"
    return 0
  elif [ -n "$CERT_POSTED_AT" ] && [ $(($(date +%s) - CERT_POSTED_AT)) -lt 300 ]; then
    err "AIG certificate status is '$st' (HTTP $HTTP_CODE); waiting for it to become Active after install"
    return 1
  elif [ -s "$CSR" ]; then
    log "AIG certificate status is '$st'; reusing the saved CSR $CSR"
  else
    err "unexpected certificate status (HTTP $HTTP_CODE) and no saved CSR: $BODY"
    return 1
  fi
  sign_csr && install_cert || return 1

  api GET /v1/config/certificate/status || return 1
  st=$(jq -r '[.. | objects | .status? | strings] | first // empty' <<<"$BODY" 2>/dev/null)
  [ "${st,,}" = active ] || { err "AIG certificate status is '$st' (HTTP $HTTP_CODE), expected 'Active'"; return 1; }
  log "AIG certificate status is Active"
}

# put_config <path> <json-body> <what> — PUT and require a 2xx
put_config() {
  api PUT "$1" "$2" || return 1
  case "$HTTP_CODE" in
    2*) log "Set $3 (HTTP $HTTP_CODE)" ;;
    *) err "setting $3 failed (HTTP $HTTP_CODE): $BODY"; return 1 ;;
  esac
}

# read_dlp — set DLP_HOST (configured host_url, empty if none) and DLP_CERT
# ("true" when a trust certificate is configured)
read_dlp() {
  api GET "$DLP_PATH" || return 1
  [ "$HTTP_CODE" = 200 ] || { err "GET $DLP_PATH failed (HTTP $HTTP_CODE): $BODY"; return 1; }
  DLP_HOST=$(jget .host_config.host_url)
  DLP_CERT=$(jget .certificate_configured)
}

check_dlp() {
  [ -n "$DLPOD_HOST" ] || { err "DLPOD_HOST is not set in $CONF"; return 1; }
  local body
  read_dlp || return 1
  if [ "$DLP_CERT" != true ]; then
    log "DLP trust certificate is not configured; uploading the lab root CA"
    body=$(jq -cn --rawfile cert "$CA_CERT" '{certificate: $cert}') \
      || { err "could not build the DLP ca-cert request body"; return 1; }
    put_config "$DLP_PATH/ca-cert" "$body" "the DLP trust certificate" || return 1
  fi
  if [ "${DLP_HOST%/}" != "${DLPOD_HOST%/}" ]; then
    log "DLP host_url is '${DLP_HOST:-<not set>}'; setting it to $DLPOD_HOST"
    body=$(jq -cn --arg host_url "$DLPOD_HOST" '{host_url: $host_url}') \
      || { err "could not build the DLP hostconfig request body"; return 1; }
    put_config "$DLP_PATH/hostconfig" "$body" "the DLP host_url" || return 1
  fi
  read_dlp || return 1
  [ "$DLP_CERT" = true ] || { err "DLP trust certificate is still not configured"; return 1; }
  [ "${DLP_HOST%/}" = "${DLPOD_HOST%/}" ] \
    || { err "DLP host_url is '$DLP_HOST', expected '$DLPOD_HOST'"; return 1; }
  log "DLP trust certificate is configured and host_url is $DLP_HOST"
}

# read_guardrails_host — set GR_CUR to the configured AI Guardrails host_url
# (empty when no host is configured)
read_guardrails_host() {
  api GET "$GR_PATH" || return 1
  [ "$HTTP_CODE" = 200 ] || { err "GET $GR_PATH failed (HTTP $HTTP_CODE): $BODY"; return 1; }
  GR_CUR=$(jget .host_config.host_url)
}

# The bootstrap secret's ai_guardrails block is applied once after enrollment and
# a failure there is silent (enrollment still succeeds), so check the host here
# and set it through the config API if it is missing or different.
check_guardrails() {
  [ -n "$GUARDRAILS_HOST" ] || { err "GUARDRAILS_HOST is not set in $CONF"; return 1; }
  local body
  read_guardrails_host || return 1
  if [ "$GR_CUR" != "$GUARDRAILS_HOST" ]; then
    log "AI Guardrails host_url is '${GR_CUR:-<not set>}'; setting it to $GUARDRAILS_HOST"
    body=$(jq -cn --arg host_url "$GUARDRAILS_HOST" '{host_url: $host_url}') \
      || { err "could not build the AI Guardrails hostconfig request body"; return 1; }
    put_config "$GR_PATH/hostconfig" "$body" "the AI Guardrails host_url" || return 1
    read_guardrails_host || return 1
  fi
  [ "$GR_CUR" = "$GUARDRAILS_HOST" ] \
    || { err "AI Guardrails host_url is '$GR_CUR', expected '$GUARDRAILS_HOST'"; return 1; }
  log "AI Guardrails host_url is $GR_CUR"
}

# run_sequence — every step in order; 0 when all passed, 3 when the AIG was
# replaced during a permanent failure and the sequence must start over
run_sequence() {
  local s
  for s in "${STEPS[@]}"; do STATE[$s]=pending; done
  AIG_ID=
  TOKEN=
  CERT_POSTED_AT=
  LAST_ERR=
  report

  wait_for prereqs check_prereqs \
    && wait_for instance check_instance \
    && wait_for api check_api \
    && wait_for enrollment check_enrollment \
    && wait_for certificate check_certificate \
    && wait_for dlp check_dlp \
    && wait_for guardrails check_guardrails
}

# ── main ─────────────────────────────────────────────────────────────────────

log "AIG setup started"
while true; do
  run_sequence || continue
  log "AIG $AIG_ID is enrolled, has an Active certificate, and has its DLP and AI Guardrails hosts configured"
  report "healthy:$AIG_ID"
  watch_aig "healthy:$AIG_ID"
done
