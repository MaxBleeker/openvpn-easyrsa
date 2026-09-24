#!/usr/bin/env bash
# Build an OpenVPN PKI with easy-rsa and write server.conf plus inline client .ovpn files.
# Subnet and mask arguments are copied into the config as given.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: openvpn-easyrsa.sh [options] CLIENT [CLIENT...]

Initialize an easy-rsa PKI, build a server certificate and one certificate per
client, generate dh.pem, and write OpenVPN configs from the sample files in
sample-config-files (server.conf and client.conf, gzipped copies included).

Client files are NAME.ovpn. The sample ca, cert, key, and tls-auth lines are
commented out, and the PEM material is appended inline.

Options:
  --remote HOST           Address clients connect to (required)
  --port PORT             UDP/TCP port (default: 1194)
  --proto udp|tcp         Tunnel protocol (default: udp)
  --server SUBNET MASK    Tunnel network for the "server" directive.
                          Omit to keep the sample file's server line.
                          SUBNET and MASK are written unchanged.
  --route SUBNET MASK     Push this network so clients route it through the
                          tunnel. Repeat for more than one network.
                          SUBNET and MASK are written unchanged.
  --out DIR               Output directory (default: ./openvpn-out)
  --sample-dir DIR        Directory that contains server.conf and client.conf
  --ca-cn NAME            CA common name (default: OpenVPN-CA)
  --server-cn NAME        Server certificate name (default: server)
  --easyrsa PATH          easyrsa program to run
  --force                 Replace an output directory this script created
  -h, --help              Show this help

Example:
  openvpn-easyrsa.sh \
    --remote vpn.example.com \
    --server 10.8.0.0 255.255.255.0 \
    --route 192.168.1.0 255.255.255.0 \
    --route 10.10.0.0 255.255.0.0 \
    laptop phone
EOF
}

die() {
  echo "openvpn-easyrsa: $*" >&2
  exit 1
}

is_ipv4() {
  local o
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    ((10#$o <= 255)) || return 1
  done
}

require_ipv4() {
  is_ipv4 "$1" || die "$2 must be an IPv4 address, got: $1"
}

sample_ok() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  { [[ -f "$d/server.conf" ]] || [[ -f "$d/server.conf.gz" ]]; } || return 1
  [[ -f "$d/client.conf" ]] || [[ -f "$d/client.conf.gz" ]]
}

copy_sample() {
  local dir="$1" name="$2" dest="$3"
  if [[ -f "$dir/$name" ]]; then
    cp "$dir/$name" "$dest"
  elif [[ -f "$dir/$name.gz" ]]; then
    gzip -dc "$dir/$name.gz" >"$dest"
  else
    die "could not find $name or $name.gz in $dir"
  fi
}

find_sample_dir() {
  local d
  if [[ -n "$SAMPLE_DIR" ]]; then
    sample_ok "$SAMPLE_DIR" || die "sample directory $SAMPLE_DIR needs server.conf and client.conf (.gz is ok)"
    printf '%s\n' "$SAMPLE_DIR"
    return
  fi
  if [[ -n "${OPENVPN_SAMPLE_DIR:-}" ]]; then
    sample_ok "$OPENVPN_SAMPLE_DIR" || die "OPENVPN_SAMPLE_DIR is missing server.conf or client.conf"
    printf '%s\n' "$OPENVPN_SAMPLE_DIR"
    return
  fi

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

  local found
  found="$(find /usr/share/doc/openvpn /usr/share/doc/packages/openvpn /usr/share/openvpn \
    -type d -name sample-config-files 2>/dev/null | head -n 20 || true)"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if sample_ok "$line"; then
      printf '%s\n' "$line"
      return
    fi
  done <<<"$found"

  die "could not find OpenVPN sample configs (sample-config-files/server.conf). Pass --sample-dir."
}

find_easyrsa() {
  local bin="" dir cand
  if [[ -n "$EASYRSA_BIN" ]]; then
    [[ -x "$EASYRSA_BIN" ]] || die "easyrsa is not executable: $EASYRSA_BIN"
  else
    bin="$(command -v easyrsa || true)"
    if [[ -z "$bin" ]]; then
      for cand in /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/3/easyrsa; do
        if [[ -x "$cand" ]]; then
          bin="$cand"
          break
        fi
      done
    fi
    [[ -n "$bin" ]] || die "easyrsa not found. Install the easy-rsa package."
    EASYRSA_BIN="$bin"
  fi

  if command -v realpath >/dev/null 2>&1; then
    dir="$(dirname "$(realpath "$EASYRSA_BIN")")"
  else
    dir="$(cd "$(dirname "$EASYRSA_BIN")" && pwd)"
  fi
  if [[ -f "$dir/openssl-easyrsa.cnf" ]]; then
    export EASYRSA="$dir"
  elif [[ -f /usr/share/easy-rsa/openssl-easyrsa.cnf ]]; then
    export EASYRSA=/usr/share/easy-rsa
  elif [[ -f /usr/share/easy-rsa/3/openssl-easyrsa.cnf ]]; then
    export EASYRSA=/usr/share/easy-rsa/3
  fi
}

# Replace the first active directive, or the first commented one, or append it.
# Later active copies of the same directive are commented out.
set_directive() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    {
      line = $0
      s = line
      sub(/^[[:space:]]+/, "", s)
      commented = 0
      if (s ~ /^[;#]/) {
        commented = 1
        sub(/^[;#][[:space:]]*/, "", s)
      }
      token = s
      sub(/[[:space:]].*$/, "", token)
      if (!commented && token == key) {
        if (!found) {
          print key " " value
          found = 1
        } else {
          print ";" line
        }
        next
      }
      print line
    }
    END { exit found ? 0 : 1 }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
    return 0
  fi

  if awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    {
      line = $0
      s = line
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
      print line
    }
    END { exit found ? 0 : 1 }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
    return 0
  fi

  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >>"$file"
  fi
  printf '%s %s\n' "$key" "$value" >>"$file"
  rm -f "$tmp"
}

comment_active() {
  local file="$1" key="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" '
    {
      line = $0
      s = line
      sub(/^[[:space:]]+/, "", s)
      if (s ~ /^[;#]/) { print line; next }
      token = s
      sub(/[[:space:]].*$/, "", token)
      if (token == key) { print ";" line; next }
      print line
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

comment_client_material() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk '
    {
      line = $0
      s = line
      sub(/^[[:space:]]+/, "", s)
      if (s ~ /^[;#]/) { print line; next }
      token = s
      sub(/[[:space:]].*$/, "", token)
      if (token == "ca" || token == "cert" || token == "key" || token == "pkcs12" ||
          token == "tls-auth" || token == "tls-crypt" || token == "tls-crypt-v2") {
        print ";" line
        next
      }
      print line
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

inline_pem() {
  local tag="$1" src="$2"
  printf '<%s>\n' "$tag"
  cat "$src"
  if [[ -n "$(tail -c 1 "$src")" ]]; then
    printf '\n'
  fi
  printf '</%s>\n' "$tag"
}

run_easyrsa() {
  local cn="${EASYRSA_REQ_CN-}"
  (
    cd "$OUT"
    export EASYRSA_PKI="$PKI"
    export EASYRSA_BATCH=1
    export EASYRSA_DN=cn_only
    if [[ -n "$cn" ]]; then
      export EASYRSA_REQ_CN="$cn"
    else
      unset EASYRSA_REQ_CN
    fi
    "$EASYRSA_BIN" --batch "$@"
  )
}

gen_ta() {
  local dest="$1"
  rm -f "$dest"
  if openvpn --genkey tls-auth "$dest" >/dev/null 2>&1 && [[ -s "$dest" ]]; then
    return
  fi
  rm -f "$dest"
  if openvpn --genkey --secret "$dest" >/dev/null 2>&1 && [[ -s "$dest" ]]; then
    return
  fi
  rm -f "$dest"
  if ! openvpn --genkey secret "$dest"; then
    die "could not generate $dest"
  fi
  [[ -s "$dest" ]] || die "openvpn did not write $dest"
}

validate_name() {
  local name="$1" what="$2"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "$what must be letters, digits, dot, underscore, or hyphen: $name"
}

resolve_out() {
  local parent base
  parent="$(dirname "$OUT")"
  base="$(basename "$OUT")"
  [[ -d "$parent" ]] || die "output parent does not exist: $parent"
  parent="$(cd "$parent" && pwd)"
  OUT="$parent/$base"
  case "$OUT" in
    / | /usr | /usr/* | /etc | /etc/* | /bin | /bin/* | /sbin | /sbin/* | /System | /System/* | "$HOME")
      die "refusing output directory $OUT"
      ;;
  esac
}

prepare_out() {
  local marker
  resolve_out
  marker="$OUT/.generated-by-openvpn-easyrsa"
  if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || die "$OUT exists and is not a directory"
    if [[ "$FORCE" -ne 1 ]]; then
      die "$OUT already exists (use --force to replace a directory this script created)"
    fi
    [[ -f "$marker" ]] || die "$OUT exists and was not created by this script"
    rm -rf "$OUT"
  fi
  mkdir -p "$OUT/server" "$OUT/clients"
  printf '%s\n' "openvpn-easyrsa" >"$marker"
}

need_value() {
  [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || die "$1 needs a value"
}

REMOTE=""
PORT="1194"
PROTO="udp"
SERVER_SUBNET=""
SERVER_MASK=""
OUT="./openvpn-out"
SAMPLE_DIR=""
CA_CN="OpenVPN-CA"
SERVER_CN="server"
EASYRSA_BIN=""
FORCE=0
ROUTES=()
CLIENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -r | --remote)
      need_value "$@"
      REMOTE="$2"
      shift 2
      ;;
    -p | --port)
      need_value "$@"
      PORT="$2"
      shift 2
      ;;
    -t | --proto)
      need_value "$@"
      PROTO="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    --server)
      [[ $# -ge 3 ]] || die "--server needs a subnet and a mask"
      SERVER_SUBNET="$2"
      SERVER_MASK="$3"
      shift 3
      ;;
    --route)
      [[ $# -ge 3 ]] || die "--route needs a subnet and a mask"
      ROUTES+=("$2 $3")
      shift 3
      ;;
    -o | --out)
      need_value "$@"
      OUT="$2"
      shift 2
      ;;
    -s | --sample-dir)
      need_value "$@"
      SAMPLE_DIR="$2"
      shift 2
      ;;
    --ca-cn)
      need_value "$@"
      CA_CN="$2"
      shift 2
      ;;
    --server-cn)
      need_value "$@"
      SERVER_CN="$2"
      shift 2
      ;;
    --easyrsa)
      need_value "$@"
      EASYRSA_BIN="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --)
      shift
      CLIENTS+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      CLIENTS+=("$1")
      shift
      ;;
  esac
done

[[ -n "$REMOTE" ]] || die "--remote is required"
[[ "$REMOTE" =~ ^[^[:space:]]+$ ]] || die "--remote must not contain whitespace"
[[ "$PORT" =~ ^[0-9]+$ && 10#$PORT -ge 1 && 10#$PORT -le 65535 ]] || die "port must be 1-65535"
[[ "$PROTO" == "udp" || "$PROTO" == "tcp" ]] || die "proto must be udp or tcp"
[[ -n "$CA_CN" ]] || die "CA common name is empty"
validate_name "$SERVER_CN" "server certificate name"
[[ ${#CLIENTS[@]} -gt 0 ]] || die "give at least one client name"

if [[ -n "$SERVER_SUBNET" || -n "$SERVER_MASK" ]]; then
  [[ -n "$SERVER_SUBNET" && -n "$SERVER_MASK" ]] || die "--server needs a subnet and a mask"
  require_ipv4 "$SERVER_SUBNET" "--server subnet"
  require_ipv4 "$SERVER_MASK" "--server mask"
fi

deduped=()
seen_routes=$'\n'
for route in "${ROUTES[@]+"${ROUTES[@]}"}"; do
  subnet="${route%% *}"
  mask="${route#* }"
  [[ "$subnet" != "$route" && -n "$mask" ]] || die "--route needs a subnet and a mask"
  require_ipv4 "$subnet" "--route subnet"
  require_ipv4 "$mask" "--route mask"
  case "$seen_routes" in
    *$'\n'"$subnet $mask"$'\n'*) continue ;;
  esac
  seen_routes+="$subnet $mask"$'\n'
  deduped+=("$subnet $mask")
done
ROUTES=("${deduped[@]+"${deduped[@]}"}")

seen_clients=$'\n'
for client in "${CLIENTS[@]}"; do
  validate_name "$client" "client name"
  [[ "$client" == "$SERVER_CN" ]] && die "client name $client collides with the server certificate name"
  case "$seen_clients" in
    *$'\n'"$client"$'\n'*) die "duplicate client: $client" ;;
  esac
  seen_clients+="$client"$'\n'
done

command -v openssl >/dev/null || die "openssl not found"
command -v openvpn >/dev/null || die "openvpn not found"
command -v gzip >/dev/null || die "gzip not found"
find_easyrsa
SAMPLE_DIR="$(find_sample_dir)"
prepare_out
PKI="$OUT/pki"
SERVER_DIR="$OUT/server"

echo "Initializing PKI in $PKI"
run_easyrsa init-pki
echo "Building CA ($CA_CN)"
EASYRSA_REQ_CN="$CA_CN" run_easyrsa build-ca nopass
echo "Building server certificate ($SERVER_CN)"
run_easyrsa build-server-full "$SERVER_CN" nopass
for client in "${CLIENTS[@]}"; do
  echo "Building client certificate ($client)"
  run_easyrsa build-client-full "$client" nopass
done
echo "Generating dh.pem"
run_easyrsa gen-dh

[[ -f "$PKI/ca.crt" ]] || die "CA certificate was not created"
[[ -f "$PKI/issued/$SERVER_CN.crt" && -f "$PKI/private/$SERVER_CN.key" ]] || die "server certificate was not created"
[[ -f "$PKI/dh.pem" ]] || die "dh.pem was not created"
for client in "${CLIENTS[@]}"; do
  [[ -f "$PKI/issued/$client.crt" && -f "$PKI/private/$client.key" ]] || die "client certificate was not created: $client"
done
cp "$PKI/ca.crt" "$SERVER_DIR/ca.crt"
cp "$PKI/issued/$SERVER_CN.crt" "$SERVER_DIR/server.crt"
cp "$PKI/private/$SERVER_CN.key" "$SERVER_DIR/server.key"
cp "$PKI/dh.pem" "$SERVER_DIR/dh.pem"
gen_ta "$SERVER_DIR/ta.key"

server_conf="$SERVER_DIR/server.conf"
copy_sample "$SAMPLE_DIR" server.conf "$server_conf"
set_directive "$server_conf" port "$PORT"
set_directive "$server_conf" proto "$PROTO"
set_directive "$server_conf" ca "ca.crt"
set_directive "$server_conf" cert "server.crt"
set_directive "$server_conf" key "server.key"
set_directive "$server_conf" dh "dh.pem"
if [[ -n "$SERVER_SUBNET" ]]; then
  set_directive "$server_conf" server "$SERVER_SUBNET $SERVER_MASK"
fi
comment_active "$server_conf" tls-crypt
comment_active "$server_conf" tls-crypt-v2
set_directive "$server_conf" tls-auth "ta.key 0"
if [[ "$PROTO" == "tcp" ]]; then
  comment_active "$server_conf" explicit-exit-notify
fi
if [[ ${#ROUTES[@]} -gt 0 ]]; then
  {
    printf '\n'
    printf '%s\n' "# Pushed so clients route these networks through the tunnel."
    for route in "${ROUTES[@]}"; do
      printf 'push "route %s"\n' "$route"
    done
  } >>"$server_conf"
fi

for client in "${CLIENTS[@]}"; do
  ovpn="$OUT/clients/$client.ovpn"
  copy_sample "$SAMPLE_DIR" client.conf "$ovpn"
  set_directive "$ovpn" remote "$REMOTE $PORT"
  set_directive "$ovpn" proto "$PROTO"
  comment_client_material "$ovpn"
  {
    printf '\n'
    inline_pem ca "$PKI/ca.crt"
    inline_pem cert "$PKI/issued/$client.crt"
    inline_pem key "$PKI/private/$client.key"
    inline_pem tls-auth "$SERVER_DIR/ta.key"
    # Inline tls-auth has no direction argument. 1 is the client side.
    printf 'key-direction 1\n'
  } >>"$ovpn"
done

echo "Wrote $OUT"
echo "  server:  $SERVER_DIR/server.conf"
echo "  dh:      $SERVER_DIR/dh.pem"
echo "  clients:"
for client in "${CLIENTS[@]}"; do
  echo "    $OUT/clients/$client.ovpn"
done
if [[ ${#ROUTES[@]} -gt 0 ]]; then
  echo "  routes pushed through the tunnel:"
  for route in "${ROUTES[@]}"; do
    echo "    $route"
  done
fi
echo "Private keys are in this directory. Keep the CA key and the .ovpn files private."
