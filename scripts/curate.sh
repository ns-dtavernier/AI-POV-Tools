#!/usr/bin/env bash
# curate.sh — build a customer-specific package from this repo.
#
# SE-ONLY TOOL. Not shipped to customers.
#
# Usage:
#   scripts/curate.sh --customer acme --modules aig/new-vpc-private,gpu-guardrails/existing-vpc \
#                     [--region us-east-1] [--tests] [--remote-state] [--zip] [--out dist]
#
#   --customer      Short filesystem-safe name. Required.
#   --modules       Comma-separated Terraform roots to include. Required. Valid values:
#                     ai-services-all/new-vpc-public
#                     aig/existing-vpc  aig/new-vpc-public  aig/new-vpc-private
#                     gpu-guardrails/existing-vpc  gpu-guardrails/new-vpc-private
#                     dlpod/existing-vpc  dlpod/new-vpc-private
#   --region        Target AWS region, written into the generated README. Optional.
#   --tests         Include aig/tests/ (only meaningful when an aig/ root is selected).
#   --remote-state  Include aig/docs/state-management.md and backend.hcl.example files.
#   --zip           Also produce <out>/<customer>-<date>.zip
#   --out           Output parent directory. Default: dist
#   --force         Overwrite an existing output directory.
#
# What it does:
#   1. Copies the selected roots plus always-included shared docs and tooling.
#   2. Excludes state, tfvars, plans, .terraform, local Claude settings, IDE and
#      Python cache files, internal /docs, and SE-only tooling.
#   3. Generates README.md, CLAUDE.md and MANIFEST.md for the package.
#   4. Scans the result for secrets and region-specific IDs and reports them.
#      Exit code 2 if the scan finds anything — do not ship until clean.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CUSTOMER=""; MODULES=""; REGION=""; OUT="dist"
INCLUDE_TESTS=0; INCLUDE_REMOTE_STATE=0; MAKE_ZIP=0; FORCE=0

usage() { sed -n '2,30p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)     CUSTOMER="$2"; shift 2;;
    --modules)      MODULES="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --out)          OUT="$2"; shift 2;;
    --tests)        INCLUDE_TESTS=1; shift;;
    --remote-state) INCLUDE_REMOTE_STATE=1; shift;;
    --zip)          MAKE_ZIP=1; shift;;
    --force)        FORCE=1; shift;;
    -h|--help)      usage;;
    *) echo "Unknown argument: $1" >&2; usage;;
  esac
done

[[ -z "$CUSTOMER" || -z "$MODULES" ]] && { echo "ERROR: --customer and --modules are required." >&2; usage; }
[[ "$CUSTOMER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: --customer must be filesystem-safe ([A-Za-z0-9._-])." >&2; exit 1; }

VALID_MODULES=(
  ai-services-all/new-vpc-public
  aig/existing-vpc aig/new-vpc-public aig/new-vpc-private
  gpu-guardrails/existing-vpc gpu-guardrails/new-vpc-private
  dlpod/existing-vpc dlpod/new-vpc-private
)

IFS=',' read -r -a SELECTED <<< "$MODULES"
for m in "${SELECTED[@]}"; do
  ok=0; for v in "${VALID_MODULES[@]}"; do [[ "$m" == "$v" ]] && ok=1; done
  [[ $ok -eq 1 ]] || { echo "ERROR: unknown module '$m'." >&2; exit 1; }
  [[ -d "$m" ]]   || { echo "ERROR: module directory '$m' not found." >&2; exit 1; }
done

DATE="$(date +%Y%m%d)"
PKG="$OUT/$CUSTOMER-$DATE"
if [[ -e "$PKG" ]]; then
  [[ $FORCE -eq 1 ]] || { echo "ERROR: $PKG exists. Use --force to overwrite." >&2; exit 1; }
  rm -rf "$PKG"
fi
mkdir -p "$PKG"

# ---------------------------------------------------------------------------
# Exclusion rules (rsync filter syntax)
# ---------------------------------------------------------------------------
EXCLUDES=(
  --exclude='.terraform/'
  --exclude='.terraform.lock.hcl'
  --exclude='terraform.tfstate*'
  --exclude='*.tfvars'
  --exclude='tfplan*'
  --exclude='*.tfplan'
  --exclude='backend.hcl'
  --exclude='.claude/settings.local.json'
  --exclude='CLAUDE.md'            # module CLAUDE.md is copied explicitly below
  --exclude='.idea/'
  --exclude='.venv/'
  --exclude='__pycache__/'
  --exclude='.pytest_cache/'
  --exclude='test-results*.json'
  --exclude='.DS_Store'
  --exclude='tests/'               # re-added with --tests
)
[[ $INCLUDE_REMOTE_STATE -eq 1 ]] || EXCLUDES+=(--exclude='backend.hcl.example')

copy() { # copy <src-relative-path> — preserves path inside package
  local src="$1"
  mkdir -p "$PKG/$(dirname "$src")"
  if [[ -d "$src" ]]; then
    rsync -a "${EXCLUDES[@]}" "$src/" "$PKG/$src/"
  else
    cp "$src" "$PKG/$src"
  fi
}

INCLUDED=()
note() { INCLUDED+=("$1"); }

# ---------------------------------------------------------------------------
# Always included
# ---------------------------------------------------------------------------
copy HELP.md;        note "HELP.md"
copy .gitignore;     note ".gitignore"
mkdir -p "$PKG/scripts" "$PKG/.claude/commands"
cp scripts/preflight.sh "$PKG/scripts/";            note "scripts/preflight.sh"
for c in pov-preflight pov-deploy pov-troubleshoot pov-teardown; do
  [[ -f ".claude/commands/$c.md" ]] && { cp ".claude/commands/$c.md" "$PKG/.claude/commands/"; note ".claude/commands/$c.md"; }
done
[[ -f .claude/settings.json ]] && { cp .claude/settings.json "$PKG/.claude/"; note ".claude/settings.json"; }

# ---------------------------------------------------------------------------
# Selected modules and their module-level docs
# ---------------------------------------------------------------------------
HAS_AIG=0; HAS_GR=0; HAS_DLP=0; HAS_ALL=0
for m in "${SELECTED[@]}"; do
  copy "$m"; note "$m/"
  top="${m%%/*}"
  case "$top" in
    aig)             HAS_AIG=1;;
    gpu-guardrails)  HAS_GR=1;;
    dlpod)           HAS_DLP=1;;
    ai-services-all) HAS_ALL=1;;
  esac
done

if [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]]; then
  copy aig/README.md; note "aig/README.md"
  copy aig/deployment-role; note "aig/deployment-role/"
  mkdir -p "$PKG/aig/docs"
  # state-management.md is referenced by troubleshooting.md and HELP.md, so it always ships;
  # --remote-state only controls backend.hcl.example files.
  for d in iam-permissions.md troubleshooting.md state-management.md; do
    [[ -f "aig/docs/$d" ]] && { cp "aig/docs/$d" "$PKG/aig/docs/"; note "aig/docs/$d"; }
  done
  [[ $INCLUDE_TESTS -eq 1 && $HAS_AIG -eq 1 ]] && { rsync -a "${EXCLUDES[@]}" --include='tests/' aig/tests/ "$PKG/aig/tests/"; note "aig/tests/"; }
  [[ $HAS_AIG -eq 1 && -f aig/CLAUDE.md ]] && { cp aig/CLAUDE.md "$PKG/aig/CLAUDE.md"; note "aig/CLAUDE.md"; }
fi
if [[ $HAS_GR -eq 1 ]]; then
  copy gpu-guardrails/README.md; note "gpu-guardrails/README.md"
  [[ -f gpu-guardrails/CLAUDE.md ]] && { cp gpu-guardrails/CLAUDE.md "$PKG/gpu-guardrails/"; note "gpu-guardrails/CLAUDE.md"; }
fi
if [[ $HAS_DLP -eq 1 || $HAS_ALL -eq 1 ]]; then
  mkdir -p "$PKG/dlpod/docs"; cp dlpod/README.md "$PKG/dlpod/"; note "dlpod/README.md"
  cp dlpod/docs/ztp-bootstrap-reference.md "$PKG/dlpod/docs/"; note "dlpod/docs/ztp-bootstrap-reference.md"
  [[ $HAS_DLP -eq 1 && -f dlpod/CLAUDE.md ]] && { cp dlpod/CLAUDE.md "$PKG/dlpod/"; note "dlpod/CLAUDE.md"; }
fi
if [[ $HAS_ALL -eq 1 ]]; then
  copy ai-services-all/README.md; note "ai-services-all/README.md"
  [[ -f ai-services-all/new-vpc-public/CLAUDE.md ]] && { cp ai-services-all/new-vpc-public/CLAUDE.md "$PKG/ai-services-all/new-vpc-public/"; note "ai-services-all/new-vpc-public/CLAUDE.md"; }
elif [[ $HAS_GR -eq 1 || $HAS_DLP -eq 1 ]]; then
  # The combined-stack troubleshooting guide is the only Guardrails/DLPoD diagnostic doc.
  mkdir -p "$PKG/ai-services-all/new-vpc-public/docs"
  cp ai-services-all/new-vpc-public/docs/troubleshooting.md "$PKG/ai-services-all/new-vpc-public/docs/"; note "ai-services-all/new-vpc-public/docs/troubleshooting.md"
  if (( HAS_AIG + HAS_GR + HAS_DLP > 1 )); then cp STAGED-BUILD.md "$PKG/"; note "STAGED-BUILD.md"; fi
fi

# Drop the comment-only top-level main.tf redirects if their parent was copied
for f in aig/main.tf gpu-guardrails/main.tf ai-services-all/main.tf; do
  [[ -f "$PKG/$f" ]] && rm -f "$PKG/$f"
done

# ---------------------------------------------------------------------------
# Generated README.md
# ---------------------------------------------------------------------------
{
  echo "# Netskope POV Deployment Package — $CUSTOMER"
  echo
  echo "Prepared $(date +%Y-%m-%d). Contains only the Terraform templates selected for this proof of value."
  [[ -n "$REGION" ]] && echo "Target region: \`$REGION\`. AMI IDs in \`terraform.tfvars.example\` files are examples and must be replaced with the IDs for this region."
  echo
  echo "## Start here"
  echo
  echo "1. Read \`HELP.md\` — it answers \"I want to…\" questions and has a glossary."
  echo "2. Run \`scripts/preflight.sh\` to check Terraform, AWS credentials, quotas and environment variables."
  echo "3. Open the \`README.md\` inside the template directory you are deploying."
  echo
  echo "If you use Claude Code, open this folder and ask it to help — \`CLAUDE.md\` gives it the context it needs. Slash commands: \`/pov-preflight\`, \`/pov-deploy\`, \`/pov-troubleshoot\`, \`/pov-teardown\`."
  echo
  echo "## Templates in this package"
  echo
  echo "| Template | Directory | Guide |"
  echo "|----------|-----------|-------|"
  for m in "${SELECTED[@]}"; do
    echo "| ${m//\// — } | \`$m/\` | [README]($m/README.md) |"
  done
  if [[ $HAS_AIG -eq 1 ]]; then
    echo
    echo "**Run \`aig/deployment-role/\` first** (once per AWS account) to create the least-privilege IAM role. See \`aig/docs/iam-permissions.md\`."
  fi
  if (( HAS_AIG + HAS_GR + HAS_DLP > 1 )); then
    echo
    echo "## Staged build order"
    echo
    echo "This package was prepared for deploying one component at a time (the combined \`ai-services-all/new-vpc-public/\` stack was not selected). Deploy all stages into the same VPC: the first stage creates it (\`new-vpc-private/\`); later stages join it (\`existing-vpc/\`)."
    echo
    echo '```'
    n=1
    [[ $HAS_GR -eq 1 ]]  && { echo "Stage $n: gpu-guardrails/…   →  outputs: vpc_id, private_subnet_id, vpc_cidr, private_subnet_cidr, ai_guardrails_host"; n=$((n+1)); }
    [[ $HAS_DLP -eq 1 ]] && { echo "Stage $n: dlpod/…            →  outputs: dlp_host, ca_cert_pem (+ vpc/subnet outputs if it creates the VPC)"; n=$((n+1)); }
    [[ $HAS_AIG -eq 1 ]] && echo "Stage $n: aig/existing-vpc/  →  inputs:  vpc_id, subnet_id, appliance_host, guardrails_host, dlp_host, dlp_ca_cert_pem"
    echo '```'
    echo
    echo "The AIG goes last: it reads its bootstrap secret once at first boot, and the secret must already contain the Guardrails endpoint and the DLPoD endpoint + CA certificate. Those only exist after the earlier stages."
    [[ -f "$PKG/STAGED-BUILD.md" ]] && echo "Variable-by-variable mapping: \`STAGED-BUILD.md\`."
  fi
  echo
  echo "## You will need to supply"
  echo
  [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]] && echo "- AIG AMI ID — subscribe to Netskope AI Gateway on AWS Marketplace; the ID is region-specific"
  [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]] && echo "- Netskope REST API v2 token and tenant URL — set as \`NETSKOPE_API_KEY\` / \`NETSKOPE_SERVER_URL\` environment variables, never in a file"
  [[ $HAS_DLP -eq 1 || $HAS_ALL -eq 1 ]] && echo "- DLPoD AMI ID — from Netskope; region-specific"
  [[ $HAS_DLP -eq 1 || $HAS_ALL -eq 1 ]] && echo "- DLPoD license key — set as \`TF_VAR_dlpod_licensekey\`"
  [[ $HAS_GR -eq 1  || $HAS_ALL -eq 1 ]] && echo "- The Guardrails image \`aisecurity-llm.tgz\` uploaded to an S3 bucket in the target region"
  [[ $HAS_GR -eq 1  || $HAS_ALL -eq 1 ]] && echo "- EC2 quota for G-family GPU instances (≥ 4 vCPUs for \`g4dn.xlarge\`)"
  echo "- Terraform ≥ 1.5, AWS CLI with a configured profile, EC2 key pair(s) in the target region"
  echo
  echo "## Support"
  echo
  echo "Contact your Netskope SE. Troubleshooting guides are in \`aig/docs/\` and each template's README."
} > "$PKG/README.md"
note "README.md (generated)"

# ---------------------------------------------------------------------------
# Generated CLAUDE.md — customer-facing subset of the repo root CLAUDE.md
# ---------------------------------------------------------------------------
{
  echo "# CLAUDE.md — Netskope POV package for $CUSTOMER"
  echo
  echo "Context for Claude Code when helping this customer deploy the Netskope templates in this package."
  echo "Each template directory has its own README.md; module directories have a CLAUDE.md with design detail."
  echo
  echo "## Templates present"
  echo
  for m in "${SELECTED[@]}"; do echo "- \`$m/\`"; done
  [[ $HAS_AIG -eq 1 ]] && echo "- \`aig/deployment-role/\` — run once per AWS account before any AIG template"
  echo
  echo "Only run \`terraform\` inside one of the directories above. Each is a self-contained root."
  echo
  echo "## Rules"
  echo
  echo "- \`NETSKOPE_SERVER_URL\`, \`NETSKOPE_API_KEY\` and \`TF_VAR_dlpod_licensekey\` go in environment variables only. Never write them into \`terraform.tfvars\`."
  echo "- Never print or paste tokens, license keys, or \`.tfstate\` contents into the conversation. State contains TLS private keys."
  echo "- Always run and summarize \`terraform plan\` before \`terraform apply\`. Get an explicit yes before \`terraform destroy\`."
  echo "- Do not guess AMI IDs, license keys, regions, AZs, key pair names or S3 bucket names — ask. Any \`ami-…\` value in an \`.example\` file is a placeholder."
  echo "- Answer \"how does this work\" questions from the \`.tf\` files and README in the directory, not from memory. If they disagree, say so and prefer the code."
  echo
  echo "## Where to send common requests"
  echo
  echo "| Request | Go to |"
  echo "|---------|-------|"
  echo "| Am I ready to deploy? | \`/pov-preflight\` or \`scripts/preflight.sh\` |"
  echo "| Walk me through the deploy | \`/pov-deploy\`, then the directory README |"
  echo "| Not enrolling / not healthy / timed out | \`/pov-troubleshoot\`; \`aig/docs/troubleshooting.md\` if present |"
  echo "| Remove everything | \`/pov-teardown\` |"
  [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]] && echo "| Deployer IAM permissions | \`aig/docs/iam-permissions.md\` |"
  [[ $HAS_DLP -eq 1 || $HAS_ALL -eq 1 ]] && echo "| bootstrap.json schema | \`dlpod/docs/ztp-bootstrap-reference.md\` |"
  echo
  echo "## Constraints"
  echo
  [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]] && echo "- Appliance names are limited to 15 characters (enforced by a \`validation\` block)."
  [[ $HAS_AIG -eq 1 || $HAS_ALL -eq 1 ]] && echo "- The AIG enrollment token expires 24 h after apply. Re-run \`terraform apply\` to issue a new one."
  [[ $HAS_GR -eq 1  || $HAS_ALL -eq 1 ]] && echo "- Guardrails \`terraform apply\` finishes when EC2 exists (~2 min); the service needs 15–35 min more. Use \`ssm_connect_command\` and the log files, not a re-apply."
  [[ $HAS_ALL -eq 1 ]] && echo "- The combined stack apply blocks on readiness gates and takes 35–50 min. Do not interrupt it."
  [[ $HAS_DLP -eq 1 || $HAS_ALL -eq 1 ]] && echo "- AIG reaches DLPoD by hostname (\`dlp.aigw.internal\`) and checks the TLS SAN; a bare IP fails. The Route 53 private zone exists for this reason."
} > "$PKG/CLAUDE.md"
note "CLAUDE.md (generated)"

# ---------------------------------------------------------------------------
# Rewrite links to content that is not in this package
# ---------------------------------------------------------------------------
LINK_REPORT="$(mktemp)"
if command -v python3 >/dev/null; then
python3 -I - "$PKG" "$LINK_REPORT" <<'PY'
import os, re, sys
root, report = sys.argv[1], sys.argv[2]
pat = re.compile(r'\[([^\]]+)\]\(([^)#\s]+)(#[^)]*)?\)')
out = []
for dp, _, fs in os.walk(root):
    for fn in fs:
        if not fn.endswith(".md") or fn in ("MANIFEST.md",): continue
        f = os.path.join(dp, fn)
        txt = open(f, encoding="utf-8").read()
        def fix(m):
            text, target = m.group(1), m.group(2)
            if target.startswith(("http://", "https://", "mailto:")): return m.group(0)
            if os.path.exists(os.path.normpath(os.path.join(dp, target))): return m.group(0)
            out.append(f"{os.path.relpath(f, root)} -> {target}")
            return f"{text} *(not included in this package)*"
        new = pat.sub(fix, txt)
        if new != txt:
            open(f, "w", encoding="utf-8").write(new)
open(report, "w").write("\n".join(sorted(set(out))))
PY
else
  echo "WARN: python3 not found; links to excluded content were not rewritten." >&2
fi

# ---------------------------------------------------------------------------
# Secret / leak scan
# ---------------------------------------------------------------------------
SCAN_REPORT="$(mktemp)"
# Known placeholders that are safe to ship. Anything else matching a pattern is reported.
ALLOWLIST_RE='mycompany\.goskope\.com|123456789012|099720109477|X{8}-X{8}-X{8}-X{8}|<SERVER KEY PEM>|<[A-Z ]*PEM>'
scan() { # scan <label> <grep-pattern> [extra grep args]
  local label="$1" pat="$2"; shift 2
  grep -rnE "$@" "$pat" "$PKG" --exclude-dir=.git 2>/dev/null | grep -vE "$ALLOWLIST_RE" | sed "s|^$PKG/||" | sed "s/^/[$label] /" >> "$SCAN_REPORT" || true
}
scan "goskope-url"     'https?://[A-Za-z0-9.-]+\.goskope\.com' --exclude='*.md'
scan "aws-account-id"  '\b[0-9]{12}\b' --exclude='*.md'
scan "ami-id"          '\bami-[0-9a-f]{8,17}\b' --exclude='*.example' --exclude='*.md' --exclude='*.tf'
scan "license-key"     '\b[A-Z0-9]{8}-[A-Z0-9]{8}-[A-Z0-9]{8}-[A-Z0-9]{8}\b' --exclude='*.md'
scan "private-key"     'BEGIN (RSA |EC )?PRIVATE KEY'
scan "aws-access-key"  '\bAKIA[0-9A-Z]{16}\b'
scan "tfstate-file"    '.' --include='terraform.tfstate*' -l
scan "tfvars-file"     '.' --include='*.tfvars' -l
scan "local-settings"  '.' --include='settings.local.json' -l

# Hard-coded AMI maps inside .tf files are allowed (they're the regional lookup tables);
# flag them as informational so the SE knows they're there.
grep -rnE '\bami-[0-9a-f]{8,17}\b' "$PKG" --include='*.tf' 2>/dev/null | sed "s|^$PKG/||" | sed 's/^/[info: ami-in-tf] /' > "$SCAN_REPORT.info" || true

# ---------------------------------------------------------------------------
# MANIFEST.md
# ---------------------------------------------------------------------------
{
  echo "# Package manifest — $CUSTOMER — $(date +%Y-%m-%d)"
  echo
  echo "Generated by \`scripts/curate.sh\` from commit \`$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\`."
  echo
  echo "## Options"
  echo
  echo "- Modules: \`$MODULES\`"
  echo "- Region: \`${REGION:-not specified}\`"
  echo "- Tests included: $([[ $INCLUDE_TESTS -eq 1 ]] && echo yes || echo no)"
  echo "- Remote-state docs included: $([[ $INCLUDE_REMOTE_STATE -eq 1 ]] && echo yes || echo no)"
  echo
  echo "## Included"
  echo
  for i in "${INCLUDED[@]}"; do echo "- \`$i\`"; done
  echo
  echo "## Always excluded"
  echo
  echo '`/internal/`, `*.tfstate*`, `*.tfvars`, `tfplan*`, `.terraform/`, `.terraform.lock.hcl`, `backend.hcl`, `.claude/settings.local.json`, `.idea/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `test-results*.json`, `.DS_Store`, `scripts/curate.sh`, `/pov-curate`'
  echo
  echo "## Secret scan"
  echo
  if [[ -s "$SCAN_REPORT" ]]; then
    echo "**FINDINGS — review before shipping:**"
    echo
    echo '```'; cat "$SCAN_REPORT"; echo '```'
  else
    echo "Clean. No tokens, account IDs, private keys, state or tfvars files found."
  fi
  if [[ -s "$SCAN_REPORT.info" ]]; then
    echo
    echo "Informational — regional AMI lookup tables present in Terraform (expected):"
    echo
    echo '```'; cat "$SCAN_REPORT.info"; echo '```'
  fi
  echo
  echo "## Links rewritten (target not in this package)"
  echo
  if [[ -s "$LINK_REPORT" ]]; then
    echo "These cross-references pointed at modules or docs that were not selected. They were turned into plain text marked *(not included in this package)*."
    echo
    echo '```'; cat "$LINK_REPORT"; echo; echo '```'
  else
    echo "None."
  fi
  echo
  echo "## File tree"
  echo
  echo '```'
  (cd "$PKG" && find . -type f | sort)
  echo '```'
} > "$PKG/MANIFEST.md"

echo "Package written to $PKG"
echo "Files: $(find "$PKG" -type f | wc -l | tr -d ' ')"

RC=0
if [[ -s "$SCAN_REPORT" ]]; then
  echo
  echo "SECRET SCAN FINDINGS:"
  cat "$SCAN_REPORT"
  echo
  echo "Resolve these before shipping. Not zipping."
  RC=2
elif [[ $MAKE_ZIP -eq 1 ]]; then
  (cd "$OUT" && rm -f "$CUSTOMER-$DATE.zip" && zip -qr "$CUSTOMER-$DATE.zip" "$CUSTOMER-$DATE")
  echo "Zip: $OUT/$CUSTOMER-$DATE.zip"
fi
rm -f "$SCAN_REPORT" "$SCAN_REPORT.info" "$LINK_REPORT"
exit $RC
