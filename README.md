# openvpn-easyrsa

```bash
bash openvpn-easyrsa.sh vpn.example.com laptop phone
```

That builds an easy-rsa PKI and writes `./openvpn-out` from the OpenVPN sample `server.conf` and `client.conf` (including gzipped copies under `/usr/share/doc/openvpn`):

```
openvpn-out/
  pki/
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

Each `.ovpn` comments out `ca`, `cert`, `key`, and `tls-auth`, then appends `<ca>`, `<cert>`, `<key>`, and `<tls-auth>`. The first argument is the address written on the client `remote` line. The sample server network, port, and protocol are left as they are.

Running it again deletes `./openvpn-out` first. The `.ovpn` files and `pki/private/ca.key` are private keys.

Needs `easy-rsa`, `openvpn`, and `openssl`:

```bash
sudo apt install openvpn easy-rsa
```
