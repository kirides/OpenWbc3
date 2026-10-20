# openwbc3 lobby server

Lists the internet games openwbc3 hosts publish, introduces players to hosts (UDP hole punching) and, when punching
fails, relays the game's datagrams. Design and wire format: `docs/lobby.md`. Plain Go, standard library only.

## Build and run

```sh
cd server/lobby
go test ./...
go build -o openwbc3-lobby .            # GOOS=linux GOARCH=amd64 go build ... for a Linux server
./openwbc3-lobby                         # reads lobby.ini next to the executable, if there is one
./openwbc3-lobby -config /etc/openwbc3-lobby.ini -webListen ""
```

Open UDP 24860 (both IPv4 and IPv6 if the server has them) in the firewall; the web page (`WebListen`, TCP 8080 by
default) is optional and read-only: `/` (HTML), `/api/games` (JSON), `/healthz`. Neither shows addresses.

Settings: see `lobby.ini` (every key is also a flag in lower camel case). The relay costs bandwidth: at most
`MaxRelays × RelayBytesPerSecond` (100 × 32 KB/s by default); `EnableRelay = 0` switches it off.

A systemd unit:

```ini
[Unit]
Description=openwbc3 lobby
After=network-online.target

[Service]
ExecStart=/opt/openwbc3-lobby/openwbc3-lobby -config /opt/openwbc3-lobby/lobby.ini
DynamicUser=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## The game side

Players and hosts point the game at the server with `[net] lobby=host[:port]` in `openwbc3.ini` (default port 24860).
Hosts publish from the multiplayer lobby screen; the join screen lists the published games.
