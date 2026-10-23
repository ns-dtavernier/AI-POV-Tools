#!/bin/bash -xe
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# ================================================================
# PHASE 1: system update, NVIDIA driver install, reboot.
# Phase 2 continues via guardrails-setup.service after reboot.
#
# Terraform templatefile has resolved these variables at plan time:
#   ${aws_region}  ${image_s3_bucket}  ${image_s3_key}
# Bash dollar-brace variables inside the Phase 2 heredoc are written
# as $${VAR} in this template so templatefile leaves them intact.
# ================================================================

# Ubuntu 22.04 cloud images run apt-daily-upgrade at first boot. The
# -o DPkg::Lock::Timeout=300 flag tells apt-get to wait up to 5 minutes for
# the dpkg lock to be released rather than failing immediately.
# NOTE: do NOT call 'cloud-init status --wait' here — the userdata script is
# itself a cloud-init module, so that call deadlocks indefinitely.
apt-get -o DPkg::Lock::Timeout=300 update -y
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y awscli curl ubuntu-drivers-common
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 upgrade -y

# Clear any stale readiness signal from a previous deployment so the
# Terraform readiness gate does not complete prematurely on re-deploy.
aws ssm delete-parameter \
  --name "/${guardrails_prefix}/guardrails-ready" \
  --region ${aws_region} 2>/dev/null || true

# Install the recommended NVIDIA GPU driver (selects correct version automatically)
ubuntu-drivers install

# ------------------------------------------------------------------
# Write Phase 2 script. The <<'PHASE2MARKER' quoted-delimiter prevents
# the shell from expanding variables when Phase 1 runs, so the script
# is written verbatim. Terraform templatefile has already substituted
# ${aws_region}, ${image_s3_bucket}, and ${image_s3_key} above.
# ------------------------------------------------------------------
cat > /opt/guardrails-phase2.sh <<'PHASE2MARKER'
#!/bin/bash -xe
exec >> /var/log/guardrails-phase2.log 2>&1

# Fetch instance ID via IMDSv2 for error logging
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

# Log errors prominently to the system journal
trap 'echo "ERROR: Guardrails Phase 2 setup failed on $${INSTANCE_ID}. \
  Check /var/log/guardrails-phase2.log for details." \
  | systemd-cat -t guardrails-setup -p err' ERR

# ---- Verify GPU driver is loaded ----
nvidia-smi

# ---- NVIDIA Container Toolkit ----
ARCH=$(dpkg --print-architecture)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
https://nvidia.github.io/libnvidia-container/stable/deb/$${ARCH} /" \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit

# ---- Docker CE ----
apt-get install -y apt-transport-https ca-certificates gnupg lsb-release jq
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# ---- Configure Docker to use the NVIDIA runtime ----
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# ---- Verify GPU access in Docker ----
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi

# ---- Download Guardrails LLM image from S3 ----
# aws_region, image_s3_bucket, image_s3_key were substituted by Terraform templatefile.
aws s3 cp s3://${image_s3_bucket}/${image_s3_key} /tmp/aisecurity-llm.tgz \
  --region ${aws_region}

# Extract the image tag from the manifest, then load the image
LOCAL_IMAGE=$(tar -xOf /tmp/aisecurity-llm.tgz manifest.json 2>/dev/null \
  | jq -r '.[0].RepoTags[0]')
docker load -i /tmp/aisecurity-llm.tgz
rm /tmp/aisecurity-llm.tgz

# ---- Start the Guardrails container ----
docker run -d \
  --gpus all \
  --shm-size=1g \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e TORCH_COMPILE_DISABLE=1 \
  -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:128 \
  -e TOKENIZERS_PARALLELISM=false \
  --restart=unless-stopped \
  -p 8080:8080 \
  "$${LOCAL_IMAGE}"

# ---- Wait up to 5 minutes for the service to become healthy ----
ATTEMPTS=0
until curl -sf http://localhost:8080/ping | grep -q Healthy; do
  ATTEMPTS=$(( $${ATTEMPTS} + 1 ))
  [ "$${ATTEMPTS}" -ge 30 ] && break
  sleep 10
done

# ---- Log final health status and signal readiness ----
if curl -sf http://localhost:8080/ping | grep -q Healthy; then
  echo "SUCCESS: Guardrails service is healthy and ready on port 8080."
  aws ssm put-parameter \
    --name "/${guardrails_prefix}/guardrails-ready" \
    --value "healthy" \
    --type String \
    --overwrite \
    --region ${aws_region}
else
  echo "WARNING: Guardrails service did not become healthy within 5-minute timeout." \
    "Container may still be starting. Re-check with: curl http://localhost:8080/ping"
fi
PHASE2MARKER

chmod +x /opt/guardrails-phase2.sh

# ------------------------------------------------------------------
# Systemd oneshot service — runs Phase 2 once after the reboot below.
# ConditionPathExists=!/etc/guardrails-setup-complete prevents it from
# re-running if the instance is stopped and restarted later.
# ------------------------------------------------------------------
cat > /etc/systemd/system/guardrails-setup.service <<'SVCMARKER'
[Unit]
Description=Netskope Guardrails GPU Setup (Phase 2, post-driver reboot)
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

# Reboot to activate the NVIDIA kernel module loaded by ubuntu-drivers
reboot
