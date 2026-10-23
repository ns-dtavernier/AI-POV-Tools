# DLP On-Demand (DLPoD) — Zero-Touch Provisioning Reference

This is the reference for the `bootstrap.json` file the DLPoD appliance reads at first boot. The Terraform templates in [`../`](../README.md) build this file for you from `terraform.tfvars`; you only need this document to understand what they generate, to troubleshoot, or to provision DLPoD on a platform the templates do not cover.

---

## What is ZTP?

Zero-Touch Provisioning lets you preconfigure a DLPoD appliance so it comes up ready to use — network, DNS, proxy, certificates, system settings, and persona — without any interactive login. You supply a JSON configuration file (`bootstrap.json`) through your cloud platform's cloud-init **user-data** channel. At first boot the appliance:

1. cloud-init **caches** the user-data (it never executes it — all cloud-init execution modules are stripped from the appliance image).
2. The `nsbootstrap` service reads, strictly validates, and applies the configuration.
3. Pod installation (`nssetupdlpaas`) runs **after** base config is applied — the appliance never starts pod installation against an unconfigured network.
4. At the console login, the setup wizard shows live progress and a "do not power off" warning until initialization completes.

---

## Supported platforms

| Platform | How to deliver `bootstrap.json` |
|----------|----------------------------------|
| **AWS EC2** | Instance **User data** (raw JSON) |
| **Microsoft Azure / Hyper-V** | **User data** (read from IMDS). **Custom data is not supported.** |
| **Google Cloud** | Instance metadata `user-data` (raw JSON) |
| **OpenStack / KVM** | OpenStack user-data or a config-drive |
| **VMware / ESXi / vSphere (OVF)** | `guestinfo.userdata` guest property — the appliance auto-unwraps double-encoded JSON |
| **Generic seed ISO** | NoCloud seed containing `user-data` |

**VMware/ESXi note:** VMware sometimes double-encodes `guestinfo.userdata` (wraps the JSON object as a JSON string). The appliance detects and unwraps this automatically — provide your JSON object as user-data without worrying about the encoding.

---

## bootstrap.json schema

`bootstrap.json` is a single JSON **object**. Any unknown top-level key causes the entire file to be rejected (fail-closed). Every section is optional — an absent or empty section is simply not applied.

### Top-level keys

| Key | Type | Purpose |
|-----|------|---------|
| `persona` | string | Appliance role: `dlp-on-demand` or `dspm` |
| `dns` | object | DNS servers |
| `interface` | object | IPv4 network configuration (static or DHCP) |
| `management-plane` | object | Upstream proxy configuration |
| `system` | object | Hostname, license key, banner, timezone, SSH settings |
| `dlpaas` | object | Supply your own TLS server certificate (mutually exclusive with `request`) |
| `request` | object | Generate a self-signed cert or CSR on the appliance (mutually exclusive with `dlpaas`) |

---

### `persona`

String. One of `dlp-on-demand` or `dspm`.

- `dlp-on-demand` — standard DLP On-Demand persona.
- `dspm` — Data Security Posture Management; the appliance updates its platform mode accordingly.

> The appliance does **not** change the hostname based on persona — cloud-init owns the hostname on cloud instances. Set the hostname explicitly via `system.hostname` if required.

---

### `dns`

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `primary` | string (IP) | Yes | Primary DNS server |
| `secondary` | string (IP) | No | Applied only if non-empty |

---

### `interface.v4`

Configure **either** static **or** DHCP — they are mutually exclusive. Static is all-or-nothing: `ip`, `gw`, and `netmask` are all required together.

| Field | Type | Notes |
|-------|------|-------|
| `static.enable` | bool | Truthy values: `true`, `"true"`, `"1"`, `"yes"`, non-zero int |
| `static.ip` | string (IP) | Required when static enabled |
| `static.gw` | string (IP) | Required when static enabled |
| `static.netmask` | string | Dotted (`255.255.255.0`) or prefix length (`24`). Non-contiguous masks are rejected. |
| `dhcp.enable` | bool | Mutually exclusive with static |

---

### `management-plane.upstream-proxy-server`

Pairing rules: `hostname` + `port` are all-or-nothing; `username` + `password` are all-or-nothing; credentials require a host+port. A `trusted-ca` may be supplied on its own.

| Field | Type | Notes |
|-------|------|-------|
| `hostname` | string | Proxy host |
| `port` | int | 1–65535 |
| `username` | string | Optional; requires `password` |
| `password` | string | **Secret** — redacted from the persisted record, never logged |
| `trusted-ca` | PEM string | Must be a non-expired CA certificate with `basicConstraints CA:TRUE` |

---

### `system`

| Field | Type | Notes |
|-------|------|-------|
| `hostname` | string | Appliance hostname |
| `licensekey` | string | **Secret** — redacted from the persisted record, never logged |
| `login-banner` | string (multi-line) | Pre-login banner text |
| `timezone` | string (IANA) | e.g. `America/Los_Angeles`. An invalid name silently falls back to UTC. |
| `metrics.debug` | bool | Enable/disable debug metrics. Omit to leave unchanged. |
| `ssh-allowlist` | list of CIDR strings | e.g. `["10.20.0.0/16"]`. Empty list applies nothing. |
| `ssh-public-keys` | list of `{key, user}` | `key` (PEM/OpenSSH public key, required), `user` (optional). Entries without `key` are skipped. |

---

### `dlpaas` — supply your own server certificate

> `dlpaas` and `request` are **mutually exclusive**. Include one, not both.

All three fields are **mandatory together** — a partial set is skipped (not half-applied). All values are PEM strings.

| Field | Type | Notes |
|-------|------|-------|
| `server-cert` | PEM | Server certificate. Must be non-expired and parseable. |
| `server-key` | PEM | Private key. **Secret** — redacted from the persisted record, never logged. |
| `server-intermediate-ca-chain` | PEM | Intermediate CA chain. Each cert must be non-expired. |

---

### `request` — generate a certificate on the appliance

> `dlpaas` and `request` are **mutually exclusive**. Include one, not both.

Two sub-sections: `self-signed` (generates a self-signed cert) and `certificate-request` (generates a CSR; the CSR still needs external signing). **Both sub-sections are required together** — you cannot supply only one.

All eight DN fields are mandatory in each sub-section.

| Field | Type | Notes |
|-------|------|-------|
| `days` | int | Validity in days |
| `country` | string | 2-letter country code |
| `state` | string | State/province (spaces OK) |
| `city` | string | City (spaces OK, e.g. `Santa Clara`) |
| `organization` | string | Organization name (spaces OK) |
| `organization-unit` | string | Org unit |
| `common-name` | string | Certificate CN |
| `email-address` | string | Contact email. **See Known Issues** — a hyphen in the local-part is currently rejected. |

---

## Validation and fail-closed behavior

The entire config is validated before anything is applied. The first failing check stops the run — the config is **never partially applied**.

| Check | What is rejected | Example error |
|-------|-----------------|---------------|
| Is object | Non-object payload | `Bootstrap file must be a JSON object` |
| Top-level keys | Any unrecognized key | `bootstrap.json has unknown top-level keys: ...` |
| Persona | Invalid persona name | `Invalid persona '...' in bootstrap file (valid: dlp-on-demand, dspm)` |
| Interface | static + dhcp both set; partial static; bad IP/gw/netmask | `interface v4: static and dhcp are mutually exclusive ...` |
| Server certs | Partial cert set; expired or unparseable cert | `dlpaas server certificate config is incomplete: ...` |
| Request certs | Partial DN field set | `request certificate config is incomplete: ...` |
| Upstream proxy | Bad pairing; port out of range; non-CA or expired `trusted-ca` | `upstream-proxy-server: port ... is out of range (1-65535)` |

Certificate content checks use OpenSSL (`x509 -checkend`) — if validation cannot be run, the config is rejected rather than applied.

---

## Security model

- **cloud-init is a data carrier only.** All executing cloud-init modules are stripped from the appliance image; user-data is treated purely as configuration data.
- **Allowlist only.** Only the recognized top-level keys are honored; anything else rejects the whole file.
- **Secrets are redacted.** `system.licensekey`, `management-plane.upstream-proxy-server.password`, and `dlpaas.server-key` are blanked in the persisted record (`bootstrap.json.done`) and are never written to logs.
- **Least privilege.** The staged config copy is readable only by the appliance service account (mode `0640`). The main bootstrap process runs unprivileged as `nsadmin`.
- **Run-once.** After a successful apply, the appliance writes a redacted record file and will not re-apply on later boots. To deliberately re-run ZTP, remove that record file and reboot (see Known Issues for the SSH key duplication caveat).
- **IMDSv2 required** on AWS instances — blocks SSRF reads of metadata/user-data.

---

## Worked examples

### Minimal — DHCP + DNS + persona

```json
{
  "persona": "dlp-on-demand",
  "dns": { "primary": "8.8.8.8" },
  "interface": { "v4": { "dhcp": { "enable": true } } }
}
```

### Full example — static IP, proxy, custom cert, SSH

```json
{
  "persona": "dlp-on-demand",
  "dns": { "primary": "8.8.8.8", "secondary": "8.8.4.4" },
  "interface": {
    "v4": {
      "static": {
        "enable": true,
        "ip": "10.20.30.40",
        "gw": "10.20.30.1",
        "netmask": "255.255.255.0"
      },
      "dhcp": { "enable": false }
    }
  },
  "management-plane": {
    "upstream-proxy-server": {
      "hostname": "proxy.corp.example.com",
      "port": "8080",
      "username": "dlpod_proxy",
      "password": "REPLACE_WITH_PROXY_PASSWORD",
      "trusted-ca": "-----BEGIN CERTIFICATE-----\n<PROXY CA PEM>\n-----END CERTIFICATE-----\n"
    }
  },
  "system": {
    "hostname": "dlpod-appliance-01",
    "licensekey": "REPLACE_WITH_LICENSE_KEY",
    "login-banner": "Authorized access only. This system is monitored.\n",
    "timezone": "America/Los_Angeles",
    "metrics": { "debug": true },
    "ssh-allowlist": ["10.20.0.0/16", "192.168.100.0/24"],
    "ssh-public-keys": [
      { "key": "ssh-ed25519 AAAA... admin@example", "user": "nsadmin" }
    ]
  },
  "dlpaas": {
    "server-cert": "-----BEGIN CERTIFICATE-----\n<SERVER CERT PEM>\n-----END CERTIFICATE-----\n",
    "server-key": "-----BEGIN PRIVATE KEY-----\n<SERVER KEY PEM>\n-----END PRIVATE KEY-----\n",
    "server-intermediate-ca-chain": "-----BEGIN CERTIFICATE-----\n<INTERMEDIATE CA PEM>\n-----END CERTIFICATE-----\n"
  }
}
```

### Certificate alternative — generate on the appliance

Use `request` **instead of** `dlpaas`. Both sub-sections (`self-signed` and `certificate-request`) are required together.

```json
{
  "request": {
    "self-signed": {
      "days": "825",
      "country": "US",
      "state": "California",
      "city": "Santa Clara",
      "organization": "Netskope",
      "organization-unit": "DLP",
      "common-name": "appliance.dlpod.example",
      "email-address": "dlpodadmin@example.com"
    },
    "certificate-request": {
      "days": "825",
      "country": "US",
      "state": "California",
      "city": "Santa Clara",
      "organization": "Netskope",
      "organization-unit": "DLP",
      "common-name": "appliance.dlpod.example",
      "email-address": "dlpodadmin@example.com"
    }
  }
}
```

---

## Delivering user-data per platform

### AWS EC2

```bash
aws ec2 run-instances --image-id ami-xxxx --instance-type ... \
  --user-data file://bootstrap.json
```

### Microsoft Azure (User data — Custom data is NOT supported)

```bash
az vm create -g MyRG -n dlpod01 --image <image> \
  --user-data bootstrap.json
```

### Google Cloud

```bash
gcloud compute instances create dlpod01 --image <image> \
  --metadata-from-file user-data=bootstrap.json
```

### OpenStack / KVM

```bash
openstack server create --image <image> --flavor <flavor> \
  --user-data bootstrap.json dlpod01
```

### VMware / ESXi (govc, `guestinfo.userdata`)

```bash
# Provide the JSON object as guestinfo.userdata (optionally base64-encoded).
govc vm.change -vm dlpod01 \
  -e guestinfo.userdata="$(cat bootstrap.json)" \
  -e guestinfo.userdata.encoding="base64"
```

---

## Verifying bootstrap

At the console login, the setup wizard shows live bootstrap and pod-install progress. Success is reached when base config is applied and the persona is written; the appliance then proceeds to pod install.

To check from the appliance:

```bash
# Progress and status
cat /opt/ns/states/nsbootstrap/progress.json

# Redacted record of what was applied (secrets blanked)
cat /opt/ns/states/nsbootstrap/bootstrap.json.done

# Service log
journalctl -u nsbootstrap.service
```

**Re-running ZTP:** After a successful apply the appliance will not re-apply on later boots. To deliberately re-run zero-touch config, remove the record file and reboot:

```bash
rm /opt/ns/states/nsbootstrap/bootstrap.json.done
reboot
```

> **Note:** SSH public keys are not idempotent on re-run — if you re-run ZTP with the same keys in `ssh-public-keys`, duplicate keys will be appended. Remove duplicates afterward via the appliance CLI if needed.

---

## Known issues and workarounds

| Issue | Impact | Workaround |
|-------|--------|------------|
| **Hyphen in `email-address` rejected** | An email with a hyphen in the local-part (e.g. `dlpod-admin@example.com`) is rejected when generating a `request` certificate, failing the bootstrap. | Use an email address **without a hyphen** in the local-part (e.g. `dlpodadmin@example.com`). Dots and `+` are accepted; hyphens in the domain part are fine. |
| **SSH public keys duplicated on re-run** | If you deliberately re-run ZTP by removing the record file, `ssh-public-keys` entries are appended again, creating duplicates. | Avoid re-running with the same keys, or remove duplicate keys afterward via the appliance CLI. |
| **Invalid timezone falls back to UTC silently** | A `timezone` that is not a valid IANA name is not rejected; the appliance uses UTC and logs a warning. | Use an exact IANA timezone name (e.g. `America/Los_Angeles`, `Asia/Kolkata`). |

---

## FAQ

**Does ZTP affect manual OVA/ISO installs?** No. With no user-data, ZTP is a clean no-op and the normal interactive setup wizard runs.

**Can I supply my own certificate instead of generating one?** Yes — use the `dlpaas` section (all three fields) to supply your own, or the `request` section to generate one on the appliance. These two methods are mutually exclusive: use one, not both. If you use `request`, you must include both `self-signed` and `certificate-request`.

**Are my secrets stored in plaintext?** The license key, proxy password, and server private key are redacted from the persisted record (`bootstrap.json.done`) and are never written to logs.

**Is it safe to reboot during initialization?** No — wait until the wizard reports completion. A persistent on-screen warning enforces this.

**What happens if bootstrap fails?** The wizard shows the failing command, the error message, the log path, and support guidance, then drops to `nsshell` for manual recovery.

---

## Terraform templates

The AWS templates in this repository (`../existing-vpc/`, `../new-vpc-private/`, and the combined `../../ai-services-all/new-vpc-public/`) assemble `bootstrap.json` from Terraform variables and deliver it as EC2 user-data. See [`../README.md`](../README.md) to choose one.
