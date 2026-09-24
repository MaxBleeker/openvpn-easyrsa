#!/bin/bash
# server.sh PORT LOCAL NET MASK
# Copy the sample server.conf and set port, local address, and server network.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: server.sh PORT LOCAL NET MASK" >&2
  exit 1
fi

port=$1
local_ip=$2
net=$3
mask=$4
pki=${PKI:-$PWD/pki}
sample=${SAMPLE:-/usr/share/doc/openvpn/examples/sample-config-files/server.conf}

if [[ -f "$sample" ]]; then
  cp "$sample" server.conf
elif [[ -f "$sample.gz" ]]; then
  gzip -dc "$sample.gz" > server.conf
else
  echo "sample server.conf not found: $sample" >&2
  exit 1
fi

sed -i \
  -e "s/^port .*/port ${port}/" \
  -e "s/^;local .*/local ${local_ip}/" \
  -e "s/^server .*/server ${net} ${mask}/" \
  server.conf

cp "$pki/ca.crt" ca.crt
cp "$pki/issued/server.crt" server.crt
cp "$pki/private/server.key" server.key

echo "Wrote server.conf, ca.crt, server.crt, server.key"
