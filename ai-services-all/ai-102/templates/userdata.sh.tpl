#!/bin/bash -xe
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# ================================================================
# Guardrails GPU instance bootstrap. Works on either:
#   - a pre-built Guardrails AMI (NVIDIA driver, NVIDIA Container Toolkit,
#     Docker and the LLM image already present, possibly out of date), or
#   - a stock Ubuntu 22.04 AMI (everything is installed from scratch).
#
# Every component is checked first, then installed if missing or upgraded
# if present. Versions are snapshotted before any upgrade so Phase 2 can
# tell what changed and restart Docker / the Guardrails container only
# when it needs to.
#
# PHASE 1 (this script): OS packages, NVIDIA driver check/install/upgrade.
#   Reboots only if the driver or kernel changed; otherwise starts
#   Phase 2 immediately.
# PHASE 2 (guardrails-setup.service): NVIDIA Container Toolkit, Docker,
#   LLM image, container (re)start, readiness signal.
#
# Terraform templatefile has resolved these variables at plan time:
#   ${aws_region}  ${guardrails_llm_image_s3_bucket}  ${guardrails_llm_image_s3_key}
# Bash dollar-brace variables inside heredocs are written as $${VAR} in
# this template so templatefile leaves them intact.
# ================================================================

STATE_DIR=/var/lib/guardrails-setup
mkdir -p "$STATE_DIR"

# ------------------------------------------------------------------
# Shared helpers, sourced by Phase 1 and Phase 2.
# ------------------------------------------------------------------
cat > /opt/guardrails-lib.sh <<'LIBMARKER'
# UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) to prefix log messages.
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Installed version of a dpkg package, empty if not installed.
pkg_ver() {
  dpkg-query -W -f='$${Status} $${Version}\n' "$1" 2>/dev/null \
    | awk '$1=="install" && $3=="installed" {print $4}'
}

# Name of the installed apt-managed NVIDIA driver package, empty if none.
driver_pkg() {
  dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/ {print $2; exit}'
}

# Docker version, whichever of Docker CE or Ubuntu's docker.io is installed.
docker_ver() {
  local v
  v=$(pkg_ver docker-ce)
  [ -n "$v" ] || v=$(pkg_ver docker.io)
  echo "$v"
}

# Publish a status to the SSM parameter that the Terraform readiness gate
# (null_resource.guardrails_ready) polls; "healthy" signals readiness.
# Usage: aws_ssm_put_parameter_guardrails_ready <value>
aws_ssm_put_parameter_guardrails_ready() {
  aws ssm put-parameter \
    --name "/${guardrails_name}/guardrails-ready" \
    --value "$1" \
    --type String \
    --overwrite \
    --region ${aws_region}
}
LIBMARKER
. /opt/guardrails-lib.sh

# Ubuntu 22.04 cloud images run apt-daily-upgrade at first boot. The
# -o DPkg::Lock::Timeout=300 flag tells apt-get to wait up to 5 minutes for
# the dpkg lock to be released rather than failing immediately.
# NOTE: do NOT call 'cloud-init status --wait' here — the userdata script is
# itself a cloud-init module, so that call deadlocks indefinitely.
APT="apt-get -o DPkg::Lock::Timeout=300"
export DEBIAN_FRONTEND=noninteractive

$APT update -y
$APT install -y curl jq ubuntu-drivers-common
# Only install the distro awscli if no aws CLI is present (an AMI may ship v2).
command -v aws >/dev/null 2>&1 || $APT install -y awscli

# Clear any stale readiness signal from a previous deployment so the
# Terraform readiness gate does not complete prematurely on re-deploy.
#aws ssm delete-parameter \
#  --name "/${guardrails_name}/guardrails-ready" \
#  --region ${aws_region} 2>/dev/null || true

# Reset the readiness signal to indicate that Phase 1 is running and to prevent
# Terraform from completing prematurely on re-deploy.
aws_ssm_put_parameter_guardrails_ready "Guardrails just starting"

# ---- Snapshot component versions BEFORE upgrading anything ----
DRIVER_PKG=$(driver_pkg)
{
  echo "BEFORE_DRIVER_VER='$(pkg_ver "$DRIVER_PKG")'"
  echo "BEFORE_TOOLKIT_VER='$(pkg_ver nvidia-container-toolkit)'"
  echo "BEFORE_DOCKER_VER='$(docker_ver)'"
} > "$STATE_DIR/before.env"
cat "$STATE_DIR/before.env"
. "$STATE_DIR/before.env"

aws_ssm_put_parameter_guardrails_ready "Guardrails updating OS"

# ---- OS package upgrade ----
$APT upgrade -y

aws_ssm_put_parameter_guardrails_ready "Guardrails installing/updating NVIDIA drivers"

# ---- NVIDIA driver: install if missing, upgrade if present ----
REBOOT_NEEDED=0
if [ -z "$DRIVER_PKG" ]; then
  if nvidia-smi >/dev/null 2>&1; then
    echo "$(ts) NVIDIA driver works but is not apt-managed; leaving it as is."
  else
    echo "$(ts) No NVIDIA driver found; installing the recommended driver."
    ubuntu-drivers install
    REBOOT_NEEDED=1
  fi
else
  echo "$(ts) NVIDIA driver package $DRIVER_PKG found; upgrading within its branch."
  # 'apt-get upgrade' holds back packages that need new dependencies (for
  # example a matching kernel module package), so upgrade the driver explicitly.
  $APT install -y --only-upgrade "$DRIVER_PKG"
  if [ "$(pkg_ver "$DRIVER_PKG")" != "$BEFORE_DRIVER_VER" ]; then
    echo "$(ts) NVIDIA driver changed; reboot required to load the new kernel module."
    REBOOT_NEEDED=1
  fi
  # A driver/library mismatch means the old module is still loaded.
  if ! nvidia-smi >/dev/null 2>&1; then
    echo "$(ts) nvidia-smi is not working; reboot required."
    REBOOT_NEEDED=1
  fi
fi

# A kernel upgrade also needs a reboot (and the NVIDIA module must match it).
if [ -f /var/run/reboot-required ]; then
  echo "$(ts) System flagged reboot-required."
  aws_ssm_put_parameter_guardrails_ready "Guardrails reboot required"
  REBOOT_NEEDED=1
fi

# ------------------------------------------------------------------
# Write Phase 2 script. The <<'PHASE2MARKER' quoted-delimiter prevents
# the shell from expanding variables when Phase 1 runs, so the script
# is written verbatim. Terraform templatefile has already substituted
# ${aws_region}, ${guardrails_llm_image_s3_bucket}, and ${guardrails_llm_image_s3_key} above.
# ------------------------------------------------------------------
cat > /opt/guardrails-phase2.sh <<'PHASE2MARKER'
#!/bin/bash -xe
exec >> /var/log/guardrails-phase2.log 2>&1

STATE_DIR=/var/lib/guardrails-setup
. /opt/guardrails-lib.sh
. "$STATE_DIR/before.env"

APT="apt-get -o DPkg::Lock::Timeout=300"
export DEBIAN_FRONTEND=noninteractive

aws_ssm_put_parameter_guardrails_ready "Guardrails phase2 starting"

# Fetch instance ID via IMDSv2 for error logging
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

# Log errors prominently to the system journal
trap 'echo "ERROR: Guardrails Phase 2 setup failed on $${INSTANCE_ID}. \
  Check /var/log/guardrails-phase2.log for details." \
  | systemd-cat -t guardrails-setup -p err' ERR

# Components whose version changed during this run. A non-empty list means
# the Guardrails container must be restarted to pick the changes up.
CHANGED=""

aws_ssm_put_parameter_guardrails_ready "Guardrails verifying NVIDIA driver loaded"

# ---- NVIDIA driver: verify it is loaded ----
# Allow up to 2 minutes for the kernel module after a reboot.
for i in $(seq 1 12); do
  nvidia-smi && break
  sleep 10
done
nvidia-smi

AFTER_DRIVER_VER=$(pkg_ver "$(driver_pkg)")
if [ "$AFTER_DRIVER_VER" != "$BEFORE_DRIVER_VER" ]; then
  CHANGED="$CHANGED driver"
fi

aws_ssm_put_parameter_guardrails_ready "Guardrails installing system tools"

$APT update -y
$APT install -y apt-transport-https ca-certificates gnupg lsb-release jq curl

aws_ssm_put_parameter_guardrails_ready "Guardrails installing/updating NVIDIA Container Toolkit"

# ---- NVIDIA Container Toolkit: install if missing, upgrade if present ----
if ! grep -rqs 'nvidia.github.io/libnvidia-container' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  ARCH=$(dpkg --print-architecture)
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
https://nvidia.github.io/libnvidia-container/stable/deb/$${ARCH} /" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  $APT update -y
fi
# 'install' installs the package if absent and upgrades it if present.
$APT install -y nvidia-container-toolkit
if [ "$(pkg_ver nvidia-container-toolkit)" != "$BEFORE_TOOLKIT_VER" ]; then
  CHANGED="$CHANGED nvidia-container-toolkit"
fi

aws_ssm_put_parameter_guardrails_ready "Guardrails installing/updating Docker"

# ---- Docker: install if missing, upgrade if present ----
# If the AMI uses Ubuntu's docker.io, upgrade that rather than swapping it
# for Docker CE.
if [ -n "$(pkg_ver docker.io)" ] && [ -z "$(pkg_ver docker-ce)" ]; then
  DOCKER_PKGS="docker.io"
else
  if ! grep -rqs 'download.docker.com' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    $APT update -y
  fi
  DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
fi
$APT install -y $${DOCKER_PKGS}
if [ "$(docker_ver)" != "$BEFORE_DOCKER_VER" ]; then
  CHANGED="$CHANGED docker"
fi

aws_ssm_put_parameter_guardrails_ready "Guardrails configuring Docker to use NVIDIA runtime"

# ---- Configure Docker to use the NVIDIA runtime ----
# nvidia-ctk is idempotent; restart the daemon only if the config changed or
# Docker itself was installed/upgraded.
DAEMON_JSON_BEFORE=$(md5sum /etc/docker/daemon.json 2>/dev/null || true)
nvidia-ctk runtime configure --runtime=docker
DAEMON_JSON_AFTER=$(md5sum /etc/docker/daemon.json 2>/dev/null || true)

aws_ssm_put_parameter_guardrails_ready "Guardrails starting and verifying Docker"

systemctl enable docker
if [ "$DAEMON_JSON_BEFORE" != "$DAEMON_JSON_AFTER" ]; then
  CHANGED="$CHANGED docker-runtime-config"
  systemctl restart docker
elif echo "$CHANGED" | grep -q docker; then
  systemctl restart docker
else
  systemctl start docker
fi

# ---- Verify GPU access in Docker ----
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi

# ---- Guardrails LLM image: use the local copy, else load it from S3 ----
# The pre-built AMI is expected to ship the image. Match on 'aisecurity' so
# both aisecurity-llm and aisecurityllm repository names are found.
LOCAL_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -i 'aisecurity' | grep -v '<none>' | head -1 || true)

if [ -n "$LOCAL_IMAGE" ]; then
  echo "$(ts) Guardrails LLM image already present: $${LOCAL_IMAGE}"
  aws_ssm_put_parameter_guardrails_ready "Guardrails LLM image found; skipping download from S3."

else
  echo "$(ts) Guardrails LLM image not found locally; downloading from S3."
  aws_ssm_put_parameter_guardrails_ready "Guardrails LLM image not found locally; downloading from S3."
  if [ -z "${guardrails_llm_image_s3_bucket}" ]; then
    echo "$(ts) ERROR: no local Guardrails LLM image and guardrails_llm_image_s3_bucket is not set."
    aws_ssm_put_parameter_guardrails_ready "ERROR: no local Guardrails LLM image and guardrails_llm_image_s3_bucket is not set."
    false
  fi
  # aws_region, guardrails_llm_image_s3_bucket, guardrails_llm_image_s3_key were substituted by Terraform templatefile.
  aws s3 cp s3://${guardrails_llm_image_s3_bucket}/${guardrails_llm_image_s3_key} /tmp/aisecurity-llm.tgz \
    --region ${aws_region}

  # Extract the image tag from the manifest, then load the image
  aws_ssm_put_parameter_guardrails_ready "Guardrails loading LLM image"
  LOCAL_IMAGE=$(tar -xOf /tmp/aisecurity-llm.tgz manifest.json 2>/dev/null \
    | jq -r '.[0].RepoTags[0]')
  docker load -i /tmp/aisecurity-llm.tgz
  rm /tmp/aisecurity-llm.tgz
  CHANGED="$CHANGED llm-image"
fi

# ---- Guardrails container: create, start, or restart as needed ----
# Reuse any existing container built from the image (the AMI may ship one);
# otherwise create it.
CONTAINER_ID=$(docker ps -aq --filter "ancestor=$${LOCAL_IMAGE}" | head -1)

if [ -z "$CONTAINER_ID" ]; then
  echo "$(ts) No Guardrails container exists; creating one."
  aws_ssm_put_parameter_guardrails_ready "Guardrails creating LLM container"
  docker run -d \
    --name guardrails \
    --gpus all \
    --shm-size=1g \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e TORCH_COMPILE_DISABLE=1 \
    -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:128 \
    -e TOKENIZERS_PARALLELISM=false \
    --restart=unless-stopped \
    -p 8080:8080 \
    "$${LOCAL_IMAGE}"
else
  docker update --restart=unless-stopped "$CONTAINER_ID"
  if [ -n "$CHANGED" ]; then
    echo "$(ts) Components changed ($${CHANGED# }); restarting container $${CONTAINER_ID}."
    aws_ssm_put_parameter_guardrails_ready "Guardrails restarting LLM container"
    docker restart "$CONTAINER_ID"
  else
    echo "$(ts) Nothing changed; ensuring container $${CONTAINER_ID} is running."
    aws_ssm_put_parameter_guardrails_ready "Guardrails container restart not needed; running"
    docker start "$CONTAINER_ID"
  fi
fi

# ---- Wait up to 10 minutes for the service to become healthy ----
# Returns 0 as soon as /ping reports Healthy, 1 if the timeout expires.
aws_ssm_put_parameter_guardrails_ready "Guardrails waiting for container to be healthy (up to 10 minutes)"
wait_healthy() {
  local attempts=0
  until curl -sf http://localhost:8080/ping | grep -q Healthy; do
    attempts=$(( attempts + 1 ))
    [ "$attempts" -ge 60 ] && return 1
    sleep 10
  done
}

if ! wait_healthy; then
  # Restart the container once and give it another 10 minutes. The container
  # is looked up again because the create branch above does not set CONTAINER_ID.
  CONTAINER_ID=$(docker ps -aq --filter "ancestor=$${LOCAL_IMAGE}" | head -1)
  echo "$(ts) WARNING: Guardrails not healthy after 10 minutes; restarting container $${CONTAINER_ID} once."
  aws_ssm_put_parameter_guardrails_ready "WARNING: Guardrails container not healthy after 10 minutes; restarting"
  docker restart "$CONTAINER_ID" || echo "$(ts) WARNING: docker restart failed."
  wait_healthy || true
fi

# ---- Log final health status and signal readiness ----
if curl -sf http://localhost:8080/ping | grep -q Healthy; then
  echo "$(ts) SUCCESS: Guardrails service is healthy and ready on port 8080."
  aws_ssm_put_parameter_guardrails_ready "healthy"
else
  echo "$(ts) WARNING: Guardrails service did not become healthy within 10 minutes:" \
    "not healthy after initial 5 minutes; restarted container; not healthy 5" \
    "minutes after restart. Container may still be starting." \
    "Re-check with: curl http://localhost:8080/ping"
  aws_ssm_put_parameter_guardrails_ready "ERROR: Guardrail container did not become healthy within 20 minutes"
fi
PHASE2MARKER

chmod +x /opt/guardrails-phase2.sh

# Remove any stale /etc/guardrails-setup-complete file so the systemd service runs Phase 2.
rm -rf /etc/guardrails-setup-complete

# ------------------------------------------------------------------
# Systemd oneshot service — runs Phase 2 once, either after the reboot
# below or immediately if no reboot is needed.
# ConditionPathExists=!/etc/guardrails-setup-complete prevents it from
# re-running if the instance is stopped and restarted later.
# ------------------------------------------------------------------
cat > /etc/systemd/system/guardrails-setup.service <<'SVCMARKER'
[Unit]
Description=Netskope Guardrails GPU Setup (Phase 2)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/opt/guardrails-phase2.sh
ConditionPathExists=!/etc/guardrails-setup-complete

[Service]
Type=oneshot
ExecStart=/opt/guardrails-phase2.sh
ExecStartPost=/usr/bin/touch /etc/guardrails-setup-complete
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCMARKER

systemctl daemon-reload
systemctl enable guardrails-setup.service

if [ "$REBOOT_NEEDED" = "1" ]; then
  # Reboot to load the new NVIDIA kernel module / kernel; the enabled
  # service runs Phase 2 on the next boot.
  reboot
else
  # Driver and kernel are current and loaded; no reboot needed.
  systemctl start --no-block guardrails-setup.service
fi
