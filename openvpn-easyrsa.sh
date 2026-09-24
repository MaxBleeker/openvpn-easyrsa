#!/usr/bin/env bash
# Usage: openvpn-easyrsa.sh REMOTE CLIENT [CLIENT...]
set -euo pipefail
umask 077

die() {
  echo "openvpn-easyrsa: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: openvpn-easyrsa.sh REMOTE CLIENT [CLIENT...]

Builds an easy-rsa PKI and writes ./openvpn-out from the OpenVPN sample
server.conf and client.conf:

  server/server.conf, ca.crt, server.crt, server.key, dh.pem, ta.key
  clients/CLIENT.ovpn

Each .ovpn comments out ca, cert, key, and tls-auth, then appends that
material inline. REMOTE is the address in each client file. Running this
again deletes ./openvpn-out first.
EOF
  exit 0
fi

[[ $# -ge 2 ]] || die "usage: openvpn-easyrsa.sh REMOTE CLIENT [CLIENT...]"

remote=$1
shift
[[ "$remote" != *" "* && "$remote" != *$'\t'* && "$remote" != -* ]] || die "bad remote: $remote"

names=$'\n'
for client in "$@"; do
  [[ "$client" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "bad client name: $client"
  [[ "$client" == server ]] && die "client name cannot be server"
  case "$names" in
    *$'\n'"$client"$'\n'*) die "duplicate client: $client" ;;
  esac
  names+="$client"$'\n'
done
clients=("$@")

sample_ok() {
  local d=$1
  [[ -d "$d" ]] || return 1
  { [[ -f "$d/server.conf" ]] || [[ -f "$d/server.conf.gz" ]]; } || return 1
  [[ -f "$d/client.conf" ]] || [[ -f "$d/client.conf.gz" ]]
}

copy_sample() {
  local dir=$1 name=$2 dest=$3
  if [[ -f "$dir/$name" ]]; then
    cp "$dir/$name" "$dest"
  elif [[ -f "$dir/$name.gz" ]]; then
    gzip -dc "$dir/$name.gz" >"$dest"
  else
    die "could not find $name in $dir"
  fi
}

find_samples() {
  local d line found
  shopt -s nullglob
  local candidates=(
    /usr/share/doc/openvpn/examples/sample-config-files
    /usr/share/doc/openvpn/sample-config-files
    /usr/share/doc/openvpn/sample/sample-config-files
    /usr/share/doc/packages/openvpn/sample-config-files
    /usr/share/doc/packages/openvpn/examples/sample-config-files
    /usr/share/openvpn/examples/sample-config-files
    /usr/share/doc/openvpn*/examples/sample-config-files
    /usr/share/doc/openvpn*/sample-config-files
    /usr/share/doc/openvpn*/sample/sample-config-files
  )
  shopt -u nullglob
  for d in "${candidates[@]}"; do
    if sample_ok "$d"; then
      printf '%s\n' "$d"
      return
    fi
  done
  found="$(find /usr/share/doc/openvpn /usr/share/doc/packages/openvpn /usr/share/openvpn \
    -type d -name sample-config-files 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if sample_ok "$line"; then
      printf '%s\n' "$line"
      return
    fi
  done <<<"$found"
  die "could not find sample-config-files/server.conf under /usr/share/doc/openvpn"
}

find_easyrsa() {
  local bin dir
  bin="$(command -v easyrsa || true)"
  if [[ -z "$bin" ]]; then
    for bin in /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/3/easyrsa; do
      [[ -x "$bin" ]] && break
      bin=""
    done
  fi
  [[ -n "$bin" ]] || die "easyrsa not found"
  if command -v realpath >/dev/null 2>&1; then
    dir="$(dirname "$(realpath "$bin")")"
  else
    dir="$(cd "$(dirname "$bin")" && pwd)"
  fi
  if [[ -f "$dir/openssl-easyrsa.cnf" ]]; then
    export EASYRSA="$dir"
  elif [[ -f /usr/share/easy-rsa/openssl-easyrsa.cnf ]]; then
    export EASYRSA=/usr/share/easy-rsa
  elif [[ -f /usr/share/easy-rsa/3/openssl-easyrsa.cnf ]]; then
    export EASYRSA=/usr/share/easy-rsa/3
  fi
  EASYRSA_BIN=$bin
}

# Put key value on the first matching directive, uncommenting it if needed.
set_opt() {
  local file=$1 key=$2 value=$3 tmp
  tmp="$(mktemp)"
  if awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      commented = 0
      if (s ~ /^[;#]/) {
        commented = 1
        sub(/^[;#][[:space:]]*/, "", s)
      }
      token = s
      sub(/[[:space:]].*$/, "", token)
      if (!commented && token == key) {
        if (!found) print key " " value
        found = 1
        next
      }
      print
    }
    END { exit found ? 0 : 1 }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
    return
  fi
  if awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      if (s ~ /^[;#]/) {
        sub(/^[;#][[:space:]]*/, "", s)
        token = s
        sub(/[[:space:]].*$/, "", token)
        if (!found && token == key) {
          print key " " value
          found = 1
          next
        }
      }
      print
    }
    END { exit found ? 0 : 1 }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
    return
  fi
  printf '%s %s\n' "$key" "$value" >>"$file"
  rm -f "$tmp"
}

comment_client_certs() {
  local file=$1 tmp
  tmp="$(mktemp)"
  awk '
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      if (s ~ /^[;#]/) { print; next }
      token = s
      sub(/[[:space:]].*$/, "", token)
      if (token == "ca" || token == "cert" || token == "key" || token == "pkcs12" ||
          token == "tls-auth" || token == "tls-crypt" || token == "tls-crypt-v2") {
        print ";" $0
        next
      }
      print
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

inline_pem() {
  local tag=$1 src=$2
  printf '<%s>\n' "$tag"
  cat "$src"
  [[ -n "$(tail -c 1 "$src")" ]] && printf '\n'
  printf '</%s>\n' "$tag"
}

set_remote() {
  local file=$1 tmp
  tmp="$(mktemp)"
  awk -v host="$remote" '
    BEGIN { found = 0 }
    {
      if (!found && $0 ~ /^[[:space:]]*remote[[:space:]]/) {
        port = ($3 == "" ? "1194" : $3)
        print "remote " host " " port
        found = 1
        next
      }
      print
    }
    END { exit found ? 0 : 1 }
  ' "$file" >"$tmp" || die "client sample has no remote line"
  mv "$tmp" "$file"
}

gen_ta() {
  local dest=$1
  rm -f "$dest"
  if openvpn --genkey tls-auth "$dest" >/dev/null 2>&1 && [[ -s "$dest" ]]; then
    return
  fi
  rm -f "$dest"
  if openvpn --genkey --secret "$dest" >/dev/null 2>&1 && [[ -s "$dest" ]]; then
    return
  fi
  rm -f "$dest"
  openvpn --genkey secret "$dest"
  [[ -s "$dest" ]] || die "openvpn did not write ta.key"
}

command -v openvpn >/dev/null || die "openvpn not found"
command -v gzip >/dev/null || die "gzip not found"
find_easyrsa
samples="$(find_samples)"

out="$PWD/openvpn-out"
rm -rf "$out"
mkdir -p "$out/server" "$out/clients"
pki="$out/pki"

export EASYRSA_PKI="$pki" EASYRSA_BATCH=1 EASYRSA_DN=cn_only
cd "$out"
echo "Initializing PKI"
"$EASYRSA_BIN" --batch init-pki
echo "Building CA"
EASYRSA_REQ_CN=OpenVPN-CA "$EASYRSA_BIN" --batch build-ca nopass
unset EASYRSA_REQ_CN
echo "Building server certificate"
"$EASYRSA_BIN" --batch build-server-full server nopass
for client in "${clients[@]}"; do
  echo "Building client certificate ($client)"
  "$EASYRSA_BIN" --batch build-client-full "$client" nopass
done
echo "Generating dh.pem"
"$EASYRSA_BIN" --batch gen-dh

[[ -f "$pki/ca.crt" && -f "$pki/issued/server.crt" && -f "$pki/private/server.key" && -f "$pki/dh.pem" ]] || die "easy-rsa did not produce the server files"
cp "$pki/ca.crt" "$out/server/ca.crt"
cp "$pki/issued/server.crt" "$out/server/server.crt"
cp "$pki/private/server.key" "$out/server/server.key"
cp "$pki/dh.pem" "$out/server/dh.pem"
gen_ta "$out/server/ta.key"

copy_sample "$samples" server.conf "$out/server/server.conf"
set_opt "$out/server/server.conf" dh dh.pem
set_opt "$out/server/server.conf" tls-auth "ta.key 0"

for client in "${clients[@]}"; do
  [[ -f "$pki/issued/$client.crt" && -f "$pki/private/$client.key" ]] || die "missing certificate for $client"
  ovpn="$out/clients/$client.ovpn"
  copy_sample "$samples" client.conf "$ovpn"
  set_remote "$ovpn"
  comment_client_certs "$ovpn"
  {
    printf '\n'
    inline_pem ca "$pki/ca.crt"
    inline_pem cert "$pki/issued/$client.crt"
    inline_pem key "$pki/private/$client.key"
    inline_pem tls-auth "$out/server/ta.key"
    printf 'key-direction 1\n'
  } >>"$ovpn"
  echo "Wrote $ovpn"
done

echo "Wrote $out/server/server.conf"
echo "Wrote $out/server/dh.pem"
