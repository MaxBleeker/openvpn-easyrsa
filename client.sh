#!/bin/bash
# client.sh NAME REMOTE PORT
# Copy the sample client.conf, set remote, comment the cert lines, append the PKI.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: client.sh NAME REMOTE PORT" >&2
  exit 1
fi

name=$1
remote=$2
port=$3
pki=${PKI:-$PWD/pki}
sample=${SAMPLE:-/usr/share/doc/openvpn/examples/sample-config-files/client.conf}
out="${name}.ovpn"

if [[ -f "$sample" ]]; then
  cp "$sample" "$out"
elif [[ -f "$sample.gz" ]]; then
  gzip -dc "$sample.gz" > "$out"
else
  echo "sample client.conf not found: $sample" >&2
  exit 1
fi

sed -i \
  -e "s/^remote my-server-1 .*/remote ${remote} ${port}/" \
  -e "s/^ca /;ca /" \
  -e "s/^cert /;cert /" \
  -e "s/^key /;key /" \
  "$out"

{
  echo
  echo "<ca>"
  cat "$pki/ca.crt"
  echo "</ca>"
  echo "<cert>"
  cat "$pki/issued/${name}.crt"
  echo "</cert>"
  echo "<key>"
  cat "$pki/private/${name}.key"
  echo "</key>"
} >> "$out"

echo "Wrote $out"
