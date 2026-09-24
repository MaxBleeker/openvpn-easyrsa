#!/bin/bash
# wg.sh PORT ENDPOINT SERVER_ADDR ROUTED CLIENT CLIENT_ADDR [CLIENT2 CLIENT_ADDR2]
# Write a WireGuard server config and one or two client configs.
set -euo pipefail
umask 077

if [[ $# -ne 6 && $# -ne 8 ]]; then
  echo "usage: wg.sh PORT ENDPOINT SERVER_ADDR ROUTED CLIENT CLIENT_ADDR [CLIENT2 CLIENT_ADDR2]" >&2
  exit 1
fi

command -v wg >/dev/null || { echo "wg not found (apt install wireguard)" >&2; exit 1; }

port=$1
endpoint=$2
server_addr=$3
routed=$4
shift 4

rm -rf wg
mkdir wg

wg genkey | tee wg/server.key | wg pubkey > wg/server.pub

{
  echo "[Interface]"
  echo "Address = ${server_addr}"
  echo "ListenPort = ${port}"
  echo "PrivateKey = $(cat wg/server.key)"
  echo
} > wg/wg0.conf

while [[ $# -gt 0 ]]; do
  name=$1
  addr=$2
  shift 2
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "bad client name: $name" >&2; exit 1; }

  wg genkey | tee "wg/${name}.key" | wg pubkey > "wg/${name}.pub"
  {
    echo "[Peer]"
    echo "PublicKey = $(cat "wg/${name}.pub")"
    echo "AllowedIPs = ${addr}"
    echo
  } >> wg/wg0.conf

  {
    echo "[Interface]"
    echo "Address = ${addr}"
    echo "PrivateKey = $(cat "wg/${name}.key")"
    echo
    echo "[Peer]"
    echo "PublicKey = $(cat wg/server.pub)"
    echo "Endpoint = ${endpoint}:${port}"
    echo "AllowedIPs = ${routed}"
  } > "wg/${name}.conf"
  echo "Wrote wg/${name}.conf"
done

echo "Wrote wg/wg0.conf"
