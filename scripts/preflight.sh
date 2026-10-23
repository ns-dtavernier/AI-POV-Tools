#!/usr/bin/env bash
# preflight.sh — check the environment before `terraform apply`.
#
# Usage:  scripts/preflight.sh <template-dir>
#   e.g.  scripts/preflight.sh aig/new-vpc-private
#
# Checks Terraform version, AWS credentials, required environment variables,
# terraform.tfvars presence and required variables, EC2 key pairs, GPU quota
# and the Guardrails S3 image — only the checks relevant to the chosen template.
# Never prints secret values.

set -uo pipefail

DIR="${1:-}"
[[ -z "$DIR" || ! -d "$DIR" ]] && { echo "Usage: $0 <template-dir>"; exit 1; }
[[ -f "$DIR/variables.tf" ]] || { echo "ERROR: $DIR is not a Terraform root (no variables.tf)."; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

case "$DIR" in
  aig/*)              NEEDS_NS=1; NEEDS_DLP=0; NEEDS_GR=0;;
  gpu-guardrails/*)   NEEDS_NS=0; NEEDS_DLP=0; NEEDS_GR=1;;
  dlpod/*)            NEEDS_NS=0; NEEDS_DLP=1; NEEDS_GR=0;;
  ai-services-all/*)  NEEDS_NS=1; NEEDS_DLP=1; NEEDS_GR=1;;
  *)                  NEEDS_NS=0; NEEDS_DLP=0; NEEDS_GR=0;;
esac
[[ "$DIR" == aig/deployment-role ]] && NEEDS_NS=0

TFVARS="$DIR/terraform.tfvars"
tfvar() { # tfvar <name> → value from terraform.tfvars (unquoted) or empty
  [[ -f "$TFVARS" ]] || return 0
  grep -E "^\s*$1\s*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=\s*//; s/^"//; s/"\s*$//; s/\s*#.*$//'
}

echo "Preflight for $DIR"
echo

echo "Tooling"
if command -v terraform >/dev/null; then
  TFV=$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p')
  [[ -z "$TFV" ]] && TFV=$(terraform version | head -1 | sed -E 's/Terraform v//')
  MAJ=${TFV%%.*}; MIN=$(echo "$TFV" | cut -d. -f2)
  if [[ "$MAJ" -gt 1 || ( "$MAJ" -eq 1 && "$MIN" -ge 5 ) ]]; then ok "terraform $TFV (≥ 1.5)"; else bad "terraform $TFV — need ≥ 1.5"; fi
else bad "terraform not found"; fi
command -v aws >/dev/null && ok "aws cli present" || bad "aws cli not found"
echo

echo "AWS credentials"
if IDENT=$(aws sts get-caller-identity --output text --query 'Arn' 2>&1); then
  ok "authenticated as $IDENT"
else
  bad "aws sts get-caller-identity failed: $(echo "$IDENT" | head -1)"
fi
REGION=$(tfvar aws_region); [[ -z "$REGION" ]] && REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[[ -n "$REGION" ]] && ok "region: $REGION" || warn "aws_region not set in terraform.tfvars or environment; defaults in variables.tf will apply"
echo

echo "Environment variables (values not shown)"
if [[ $NEEDS_NS -eq 1 ]]; then
  [[ -n "${NETSKOPE_SERVER_URL:-}" ]] && ok "NETSKOPE_SERVER_URL set" || bad "NETSKOPE_SERVER_URL not set"
  [[ -n "${NETSKOPE_SERVER_URL:-}" && "${NETSKOPE_SERVER_URL}" != */api/v2 ]] && warn "NETSKOPE_SERVER_URL should end in /api/v2"
  [[ -n "${NETSKOPE_API_KEY:-}" ]]    && ok "NETSKOPE_API_KEY set"    || bad "NETSKOPE_API_KEY not set"
  grep -qE '^\s*netskope_api_key\s*=' "$TFVARS" 2>/dev/null && bad "netskope_api_key is in terraform.tfvars — remove it; it would be written to state"
fi
if [[ $NEEDS_DLP -eq 1 ]]; then
  if [[ -n "${TF_VAR_dlpod_licensekey:-}" ]]; then ok "TF_VAR_dlpod_licensekey set"
  elif grep -qE '^\s*dlpod_licensekey\s*=' "$TFVARS" 2>/dev/null; then warn "DLPoD license key is in terraform.tfvars (allowed, file is gitignored) — TF_VAR_dlpod_licensekey is preferred"
  else bad "DLPoD license key not set (export TF_VAR_dlpod_licensekey or set dlpod_licensekey in terraform.tfvars)"; fi
fi
[[ $NEEDS_NS -eq 0 && $NEEDS_DLP -eq 0 ]] && ok "no secrets required for this template"
echo

echo "terraform.tfvars"
if [[ -f "$TFVARS" ]]; then
  ok "present"
  # Variables with no default in variables.tf must be set
  awk '/^variable "/{name=$2; gsub(/"/,"",name); has=0} /^\s*default\s*=/{has=1} /^}/{if(name!=""){print name, has; name=""}}' "$DIR/variables.tf" \
  | while read -r v has; do
      [[ "$has" == 1 ]] && continue
      case "$v" in netskope_api_key|netskope_server_url|dlpod_licensekey) continue;; esac
      grep -qE "^\s*$v\s*=" "$TFVARS" && ok "$v set" || bad "$v has no default and is not in terraform.tfvars"
    done
else
  bad "missing — cp $DIR/terraform.tfvars.example $TFVARS and fill in REQUIRED values"
fi
echo

if [[ -n "$REGION" ]] && aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS resources in $REGION"
  for kv in key_name aig_key_name guardrails_key_pair_name key_pair_name dlpod_key_name bastion_key_name; do
    K=$(tfvar "$kv"); [[ -z "$K" ]] && continue
    aws ec2 describe-key-pairs --region "$REGION" --key-names "$K" >/dev/null 2>&1 && ok "key pair '$K' exists ($kv)" || bad "key pair '$K' not found in $REGION ($kv)"
  done
  for av in aig_ami_id dlpod_ami_id ami_id; do
    A=$(tfvar "$av"); [[ -z "$A" ]] && continue
    aws ec2 describe-images --region "$REGION" --image-ids "$A" >/dev/null 2>&1 && ok "AMI $A visible ($av)" || bad "AMI $A not visible in $REGION ($av) — wrong region or Marketplace terms not accepted"
  done
  if [[ $NEEDS_GR -eq 1 ]]; then
    B=$(tfvar image_s3_bucket); KEY=$(tfvar image_s3_key); [[ -z "$KEY" ]] && KEY="aisecurity-llm.tgz"
    if [[ -n "$B" ]]; then
      aws s3api head-object --bucket "$B" --key "$KEY" >/dev/null 2>&1 && ok "s3://$B/$KEY exists" || bad "s3://$B/$KEY not found or not readable"
      BL=$(aws s3api get-bucket-location --bucket "$B" --query LocationConstraint --output text 2>/dev/null); [[ "$BL" == "None" ]] && BL="us-east-1"
      [[ -n "$BL" && "$BL" != "$REGION" ]] && bad "bucket $B is in $BL, template region is $REGION — must match"
    else warn "image_s3_bucket not set in terraform.tfvars"; fi
    Q=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null)
    if [[ -n "$Q" && "$Q" != "None" ]]; then
      [[ "${Q%.*}" -ge 4 ]] && ok "G/VT on-demand vCPU quota: ${Q%.*}" || bad "G/VT on-demand vCPU quota is ${Q%.*}; need ≥ 4 for g4dn.xlarge"
    else warn "could not read G/VT quota (L-DB2E81BA); check Service Quotas → EC2 manually"; fi
  fi
  echo
fi

echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
