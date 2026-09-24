#!/bin/bash
# pki.sh CLIENT [CLIENT2]
# Init easy-rsa and build the server cert plus one or two client certs.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: pki.sh CLIENT [CLIENT2]" >&2
  exit 1
fi

if [[ -x /usr/share/easy-rsa/easyrsa ]]; then
  easyrsa=/usr/share/easy-rsa/easyrsa
elif command -v easyrsa >/dev/null; then
  easyrsa=$(command -v easyrsa)
else
  echo "easyrsa not found" >&2
  exit 1
fi

export EASYRSA="${EASYRSA:-/usr/share/easy-rsa}"
export EASYRSA_PKI="${EASYRSA_PKI:-$PWD/pki}"
export EASYRSA_BATCH=1
export EASYRSA_DN=cn_only

"$easyrsa" init-pki
EASYRSA_REQ_CN=OpenVPN-CA "$easyrsa" build-ca nopass
"$easyrsa" build-server-full server nopass
for name in "$@"; do
  "$easyrsa" build-client-full "$name" nopass
done

echo "PKI is in $EASYRSA_PKI"
echo "  ca.crt"
echo "  issued/server.crt  private/server.key"
for name in "$@"; do
  echo "  issued/$name.crt  private/$name.key"
done
