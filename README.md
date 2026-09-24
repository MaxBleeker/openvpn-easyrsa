# openvpn-easyrsa

Build an OpenVPN server and any number of clients with easy-rsa.

The script initializes a PKI, builds the CA, server certificate, and one certificate per client name, generates `dh.pem`, and writes configs from the OpenVPN sample files (`server.conf` and `client.conf`). On Debian and Ubuntu those files are usually under `/usr/share/doc/openvpn/examples/sample-config-files/`, sometimes gzipped. Other packages use `/usr/share/doc/openvpn/sample-config-files/` or `/usr/share/doc/openvpn/sample/sample-config-files/`.

Each client file comments out the sample `ca`, `cert`, `key`, and `tls-auth` lines and appends that material inline:

```
<ca>
... ca.crt ...
</ca>
<cert>
... client certificate ...
</cert>
<key>
... client key ...
</key>
<tls-auth>
... ta.key ...
</tls-auth>
key-direction 1
```

## Requirements

- bash
- easy-rsa
- openvpn
- openssl
- the OpenVPN sample config files

```bash
sudo apt install openvpn easy-rsa
```

## Usage

```bash
bash openvpn-easyrsa.sh \
  --remote vpn.example.com \
  --server 10.8.0.0 255.255.255.0 \
  --route 192.168.1.0 255.255.255.0 \
  --route 10.10.0.0 255.255.0.0 \
  laptop phone
```

`--server SUBNET MASK` sets the tunnel network (`server SUBNET MASK` in `server.conf`). Omit it to keep the sample file's server line.

`--route SUBNET MASK` appends `push "route SUBNET MASK"` so clients send that network through the tunnel. Repeat the flag for another network. The subnet and mask are written exactly as given.

```
openvpn-out/
  pki/                         easy-rsa PKI, including the CA private key
  server/
    server.conf
    ca.crt
    server.crt
    server.key
    dh.pem
    ta.key
  clients/
    laptop.ovpn
    phone.ovpn
```

Copy `server/` to the OpenVPN server, for example `/etc/openvpn/server/`. Copy each `.ovpn` to that client. The `.ovpn` files contain private keys.

`--force` replaces an output directory this script created. It will not delete any other directory.

Pass `--sample-dir` if the sample configs are not in a standard location.
