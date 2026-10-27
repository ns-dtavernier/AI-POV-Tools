#!/bin/bash
# AIG certificate setup — runs on the bastion at every boot (aig-cert-setup.service).
#
# Works through the checks below. If any step fails, it waits 1 minute and
# restarts all the checks. When every check passes it writes
# /etc/aig-cert-setup-complete, after which later boots exit immediately.
#
#   1. Exit 0 if /etc/aig-cert-setup-complete exists
#   2. AIG EC2 instance is running
#   3. AIG public FQDN (the AWS-generated DNS name of its Elastic IP)
#   4. SSH to the AIG and generate a 1 hour AIG Config API token
#   5. AIG bootstrap status is "completed"
#   6. If the AIG has no certificate: request a CSR, sign it with the lab root
#      CA, and install the signed certificate
#   7. AIG certificate status is "Active"
#
# Settings (including the CA key, certificate and serial file paths) come from
# /etc/aig-cert-setup.conf, written by the bastion user-data.
# Steps and errors are logged with timestamps to /var/log/aig-cert-setup.log.
# Runs as root; the key, CA and generated certificate files live in /home/ssm-user.

CONF=/etc/aig-cert-setup.conf
LOG=/var/log/aig-cert-setup.log
DONE=/etc/aig-cert-setup-complete

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
err() { log "ERROR: $*"; return 1; }

if [ -e "$DONE" ]; then
  log "AIG certificate setup already complete ($DONE exists); nothing to do"
  exit 0
fi

# shellcheck disable=SC1090
. "$CONF" || { err "cannot read $CONF"; exit 1; }

AWS=/snap/bin/aws
BASE="https://$AIG_PRIVATE_IP:8443"
HOME_DIR=/home/ssm-user
CSR=$HOME_DIR/aig-cert-request.csr
SIGNED=$HOME_DIR/aig-cert-signed.pem
NOT_FOUND='resource not found: failed to get certificate status'

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

TOKEN=
HTTP_CODE=
BODY=

# ── helpers ──────────────────────────────────────────────────────────────────

# api <method> <path> [json-body] — sets HTTP_CODE and BODY; fails only when
# curl itself fails (HTTP error statuses are left for the caller to interpret).
api() {
  local args=(-sk --max-time 30 -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  local out
  out=$(curl "${args[@]}" "$BASE$2" 2>"$ERRF") || { err "curl $1 $2 failed: $(cat "$ERRF")"; return 1; }
  HTTP_CODE=${out##*$'\n'}
  BODY=${out%$'\n'*}
}

# jget <jq-filter> — print a field of $BODY (empty if missing or not JSON)
jget() { printf '%s' "$BODY" | jq -r "$1 // empty" 2>/dev/null; }

# ── steps ────────────────────────────────────────────────────────────────────

check_prereqs() {
  local f
  for f in "$SSH_KEY" "$CA_KEY" "$CA_CERT"; do
    [ -s "$f" ] || { err "$f is missing (not downloaded from Secrets Manager yet?)"; return 1; }
  done
  command -v jq >/dev/null || { err "jq is not installed"; return 1; }
  log "Prerequisites present (SSH key, lab root CA key and certificate, jq)"
}

check_aig_running() {
  local n
  n=$("$AWS" ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Name,Values=$AIG_NAME" "Name=instance-state-name,Values=running" \
        --query 'length(Reservations[].Instances[])' --output text 2>"$ERRF") \
    || { err "ec2 describe-instances failed: $(cat "$ERRF")"; return 1; }
  [ "$n" -ge 1 ] 2>/dev/null || { err "AIG EC2 instance '$AIG_NAME' is not running"; return 1; }
  log "AIG EC2 instance '$AIG_NAME' is running"
}

get_fqdn() {
  [ -n "$AIG_FQDN" ] || { err "AIG public FQDN is empty"; return 1; }
  log "AIG public FQDN: $AIG_FQDN"
}

get_token() {
  local out
  out=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
          "nsadmin@$AIG_PRIVATE_IP" 'enable-api --ttl 1h' 2>"$ERRF") \
    || { err "ssh enable-api on $AIG_PRIVATE_IP failed: $(cat "$ERRF")"; return 1; }
  TOKEN=$(printf '%s' "$out" | jq -r '.token // empty' 2>/dev/null)
  [ -n "$TOKEN" ] || { err "enable-api response has no \"token\" key"; return 1; }
  log "Generated 1 hour AIG Config API token"
}

check_bootstrap() {
  api GET /v1/config/bootstrap || return 1
  local s
  s=$(jget .status)
  [ "${s,,}" = completed ] || { err "AIG bootstrap status is '$s' (HTTP $HTTP_CODE), expected 'completed'"; return 1; }
  log "AIG bootstrap status is completed"
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
    2*) log "Posted the signed certificate to the AIG (HTTP $HTTP_CODE)" ;;
    *) err "certificate install failed (HTTP $HTTP_CODE): $BODY"; return 1 ;;
  esac
}

setup_certificate() {
  api GET /v1/config/certificate/status || return 1
  local msg st
  msg=$(jget .message)
  st=$(jq -r '[.. | objects | .status? | strings] | first // empty' <<<"$BODY" 2>/dev/null)

  if [ "$msg" = "$NOT_FOUND" ]; then
    log "AIG has no certificate yet; requesting a CSR"
    request_csr || return 1
  elif [ "${st,,}" = active ]; then
    log "AIG certificate is already Active; skipping CSR, signing and install"
    return 0
  elif [ -s "$CSR" ]; then
    log "AIG certificate status is '$st'; reusing the saved CSR $CSR"
  else
    err "unexpected certificate status (HTTP $HTTP_CODE) and no saved CSR: $BODY"
    return 1
  fi
  sign_csr && install_cert
}

verify_active() {
  api GET /v1/config/certificate/status || return 1
  local st
  st=$(jq -r '[.. | objects | .status? | strings] | first // empty' <<<"$BODY" 2>/dev/null)
  [ "${st,,}" = active ] || { err "AIG certificate status is '$st' (HTTP $HTTP_CODE), expected 'Active'"; return 1; }
  log "AIG certificate status is Active"
}

run_checks() {
  check_prereqs && check_aig_running && get_fqdn && get_token \
    && check_bootstrap && setup_certificate && verify_active
}

# ── main ─────────────────────────────────────────────────────────────────────

log "AIG certificate setup started"
until run_checks; do
  log "Checks did not complete; restarting them in 1 minute"
  sleep 60
done
touch "$DONE"
log "AIG certificate setup complete; wrote $DONE"
exit 0
