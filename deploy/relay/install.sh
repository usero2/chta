#!/usr/bin/env bash
# Run on the Linux VPS, never on the development Windows host.
set -euo pipefail
umask 077

if [[ $# != 2 || $EUID != 0 ]]; then
  echo "Usage: sudo bash deploy/relay/install.sh /path/to/cht-relay /path/to/relay.json" >&2
  exit 1
fi
for command in systemctl systemd-creds systemd-analyze python3 openssl install getent useradd groupadd realpath awk mktemp; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -d /run/systemd/system ]] || { echo "A running systemd host is required" >&2; exit 1; }
version=$(systemd-creds --version | awk 'NR==1 {print $2}')
[[ $version =~ ^[0-9]+$ && $version -ge 250 ]] || { echo "systemd 250 or later is required" >&2; exit 1; }
binary=$(realpath "$1")
config=$(realpath "$2")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$binary" --config "$config" --check-config
python3 - "$config" <<'PY'
import ipaddress, json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    config = json.load(source)
if config.get("state_dir") != "/var/lib/cht-relay":
    sys.exit("The supplied systemd unit requires state_dir=/var/lib/cht-relay")
if config.get("port", 4001) < 1024:
    sys.exit("The unprivileged systemd service requires a port >=1024")
for address in config.get("public_addresses", []):
    parts = address.split("/")
    if parts[1] in ("ip4", "ip6") and not ipaddress.ip_address(parts[2]).is_global:
        sys.exit("Replace the example/private address with the VPS public IP")
PY

credential=/etc/credstore.encrypted/cht-relay-identity-password.cred
if [[ -e /var/lib/cht-relay/identity.enc.json && ! -f $credential ]]; then
  echo "Identity exists but its credential is missing. Restore the original credential; refusing to generate a replacement." >&2
  exit 1
fi
getent group cht-relay >/dev/null || groupadd --system cht-relay
getent passwd cht-relay >/dev/null || useradd --system --gid cht-relay --home-dir /var/lib/cht-relay --shell /usr/sbin/nologin cht-relay
install -d -m 0700 -o cht-relay -g cht-relay /var/lib/cht-relay
install -d -m 0750 -o root -g cht-relay /etc/cht-relay
install -d -m 0700 -o root -g root /etc/credstore.encrypted
if [[ ! -e $credential ]]; then
  # The generated secret travels through a pipe, not an argv/env value or plaintext disk file.
  systemd-creds setup
  temporary_credential=$(mktemp /etc/credstore.encrypted/cht-relay.XXXXXXXX)
  trap 'rm -f -- "${temporary_credential:-}" "${temporary_binary:-}"' EXIT
  openssl rand -base64 48 | systemd-creds encrypt --with-key=host --name=identity-password - - > "$temporary_credential"
  chmod 0600 "$temporary_credential"
  mv -- "$temporary_credential" "$credential"
fi
# Atomic executable replacement also works when upgrading a running service.
temporary_binary=$(mktemp /usr/local/bin/cht-relay.XXXXXXXX)
trap 'rm -f -- "${temporary_credential:-}" "${temporary_binary:-}"' EXIT
install -m 0755 -o root -g root "$binary" "$temporary_binary"
mv -- "$temporary_binary" /usr/local/bin/cht-relay
install -m 0640 -o root -g cht-relay "$config" /etc/cht-relay/relay.json
install -m 0644 -o root -g root "$script_dir/cht-relay.service" /etc/systemd/system/cht-relay.service
systemd-analyze verify /etc/systemd/system/cht-relay.service
systemctl daemon-reload
systemctl enable cht-relay.service
systemctl restart cht-relay.service
systemctl --no-pager --full status cht-relay.service
echo "Allow the configured TCP port in the VPS/provider firewall. Inspect public Peer ID with: journalctl -u cht-relay -n 30 --no-pager"
