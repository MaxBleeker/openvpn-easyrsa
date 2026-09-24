# openvpn-easyrsa

Three short scripts. Run them from an empty directory on the OpenVPN machine.

```bash
sudo apt install openvpn easy-rsa
bash pki.sh laptop phone
bash server.sh 1194 10.0.0.5 10.8.0.0 255.255.255.0
bash client.sh laptop 203.0.113.10 1194
bash client.sh phone 203.0.113.10 1194
```

`pki.sh` takes one or two client names. It inits easy-rsa and builds the CA, the `server` certificate, and those clients in `./pki`.

`server.sh PORT LOCAL NET MASK` copies the sample `server.conf` and writes:

- `port`
- `local` (the listen address)
- `server NET MASK`

It also copies `ca.crt`, `server.crt`, and `server.key` next to `server.conf`.

`client.sh NAME REMOTE PORT` copies the sample `client.conf` to `NAME.ovpn`, sets `remote`, comments out `ca`, `cert`, and `key`, and appends the built files:

```
<ca>
... pki/ca.crt ...
</ca>
<cert>
... pki/issued/NAME.crt ...
</cert>
<key>
... pki/private/NAME.key ...
</key>
```

The same edits by hand, after `cp` of the sample files:

```bash
sample=/usr/share/doc/openvpn/examples/sample-config-files

cp "$sample/server.conf" server.conf
sed -i "s/^port .*/port 1194/" server.conf
sed -i "s/^;local .*/local 10.0.0.5/" server.conf
sed -i "s/^server .*/server 10.8.0.0 255.255.255.0/" server.conf

cp "$sample/client.conf" laptop.ovpn
sed -i "s/^remote my-server-1 .*/remote 203.0.113.10 1194/" laptop.ovpn
sed -i -e "s/^ca /;ca /" -e "s/^cert /;cert /" -e "s/^key /;key /" laptop.ovpn
{
  echo "<ca>";   cat pki/ca.crt;              echo "</ca>"
  echo "<cert>"; cat pki/issued/laptop.crt;   echo "</cert>"
  echo "<key>";  cat pki/private/laptop.key;  echo "</key>"
} >> laptop.ovpn
```

`^server ` does not match `;server-bridge`. `^remote my-server-1 ` does not match the commented second remote. `^ca `, `^cert `, and `^key ` do not match `remote-cert-tls`.

## WireGuard

WireGuard does not use the easy-rsa PKI. `wg.sh` makes its own keys.

```bash
sudo apt install wireguard
bash wg.sh 51820 203.0.113.10 10.9.0.1/24 10.9.0.0/24 laptop 10.9.0.2/32 phone 10.9.0.3/32
```

Arguments are the listen port, the address clients connect to, the server tunnel address, the network clients should route through the tunnel, then one or two `NAME ADDRESS` pairs. Give each client a `/32`. This writes `wg/wg0.conf` and `wg/NAME.conf`.

```bash
sudo cp wg/wg0.conf /etc/wireguard/wg0.conf
sudo wg-quick up wg0
```

## Both on one machine

Run the OpenVPN scripts and `wg.sh` from the same directory. They write different files. Use a different UDP port and a different tunnel network so the two do not claim the same traffic.

```bash
bash pki.sh laptop phone
bash server.sh 1194 10.0.0.5 10.8.0.0 255.255.255.0
bash client.sh laptop 203.0.113.10 1194
bash client.sh phone 203.0.113.10 1194

bash wg.sh 51820 203.0.113.10 10.9.0.1/24 10.9.0.0/24 laptop 10.9.0.2/32 phone 10.9.0.3/32
```

`203.0.113.10` is the same public address in both. OpenVPN uses port `1194` and `10.8.0.0/24`. WireGuard uses port `51820` and `10.9.0.0/24`. Give a client `laptop.ovpn` or `wg/laptop.conf`, or both if that machine should be able to bring up either tunnel.
