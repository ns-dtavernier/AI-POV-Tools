#!/bin/bash
# LibreChat first-boot setup: Docker, TLS material from Secrets Manager, and a
# compose stack of nginx (TLS on 443), LibreChat and MongoDB under /opt/librechat.
# Logs: /var/log/cloud-init-output.log
set -u
export DEBIAN_FRONTEND=noninteractive

snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# Docker from Docker's apt repository
apt-get -o Acquire::Retries=5 update -y
apt-get -o Acquire::Retries=5 install -y ca-certificates curl gnupg jq openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 5 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get -o Acquire::Retries=5 update -y
apt-get -o Acquire::Retries=5 install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

snap install aws-cli --classic

# TLS certificate and key (signed by the lab root CA). The IAM role policy can take
# a few seconds to propagate, so the download is retried.
install -d -m 755 /opt/librechat/tls /opt/librechat/config
TMPFILE=$(mktemp)
for i in $(seq 1 30); do
  if /snap/bin/aws secretsmanager get-secret-value \
      --region ${region} \
      --secret-id "${tls_secret_name}" \
      --query SecretString --output text > "$TMPFILE"; then
    jq -r .cert "$TMPFILE" > /opt/librechat/tls/server.crt
    jq -r .key "$TMPFILE" > /opt/librechat/tls/server.key
    break
  fi
  sleep 10
done
rm -f "$TMPFILE"
chmod 644 /opt/librechat/tls/server.crt
chmod 600 /opt/librechat/tls/server.key

cd /opt/librechat

# LibreChat settings. The secrets are generated here, once, so they are never in
# Terraform state or user data.
if [ ! -f .env ]; then
  umask 077
  cat > .env <<ENV
HOST=0.0.0.0
PORT=3080
MONGO_URI=mongodb://mongodb:27017/LibreChat
DOMAIN_CLIENT=https://${domain}
DOMAIN_SERVER=https://${domain}
TRUST_PROXY=1
NO_INDEX=true
SEARCH=false
ALLOW_REGISTRATION=true
ALLOW_EMAIL_LOGIN=true
ALLOW_SOCIAL_LOGIN=false
ALLOW_SOCIAL_REGISTRATION=false
CONFIG_PATH=/librechat-config/librechat.yaml
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
ENV
fi

cat > nginx.conf <<'NGINX'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 443 ssl;
  http2 on;
  server_name _;

  ssl_certificate     /etc/nginx/tls/server.crt;
  ssl_certificate_key /etc/nginx/tls/server.key;
  ssl_protocols       TLSv1.2 TLSv1.3;

  client_max_body_size 50m;

  location / {
    proxy_pass http://librechat:3080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    # Streamed chat responses: do not buffer, allow long-lived connections
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
}
NGINX

cat > docker-compose.yml <<'COMPOSE'
services:
  nginx:
    image: ${nginx_image}
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./tls:/etc/nginx/tls:ro
    depends_on:
      - librechat

  librechat:
    image: ${librechat_image}
    restart: unless-stopped
    env_file: .env
    expose:
      - "3080"
    volumes:
      - ./config:/librechat-config:ro
      - librechat_images:/app/client/public/images
      - librechat_uploads:/app/uploads
      - librechat_logs:/app/logs
    depends_on:
      - mongodb

  mongodb:
    image: ${mongo_image}
    restart: unless-stopped
    command: mongod --noauth
    volumes:
      - mongo_data:/data/db

volumes:
  librechat_images:
  librechat_uploads:
  librechat_logs:
  mongo_data:
COMPOSE

# Image pulls can fail while the Elastic IP is being attached; retry.
for i in $(seq 1 10); do
  docker compose up -d && break
  sleep 15
done
