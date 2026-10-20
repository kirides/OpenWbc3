# Online lobby (internet play)

openwbc3's network game is a star: the host relays everything over its own UDP layer (`src/game/udp.lua`, lockstep in
`lockstep.lua`). On a LAN, players find hosts by broadcast (`net.lua`). Over the internet they need a rendezvous: the
**lobby server** (`server/lobby/`, a small Go program) lists the games that hosts publish and introduces a player to a
host so both sides open their NATs towards each other (UDP hole punching). When punching fails (two strict NATs), the
lobby can **relay** the game's datagrams (opt-in on the server, capped).

None of this exists in the original game (it used DirectPlay and GameSpy); it is openwbc3's own design, derived from the
matchmaker of the Sacred-Bild project (same author, reused under MIT).

## How a game gets from host to player

1. The host opens its game (`mphost`) with "publish online" on. It sends `REGISTER` from its game socket every
   `refreshMs` (5 s) to the lobby: name, map, players, game version, content hash, flags (password, private, started),
   and its LAN addresses. The lobby sees the host's public address (the NAT mapping of the game socket) and answers
   `REGISTERED` with a game id.
2. A player's join screen lists the public games (`LIST`, paged). Entries carry no addresses. Private games are not
   listed; their id is the join code the host's lobby shows.
3. Joining: the player creates its game socket, then sends `JOIN(gameId, its LAN addresses)` from it. The lobby sends
   `INTRODUCE(player's public address, its LAN addresses)` to the host and `JOINED(host's public addresses, host's LAN
   addresses)` to the player.
4. The host sends punch datagrams to every player candidate; the player starts the normal `udp.lua` handshake towards
   every host candidate at once. The first candidate that answers wins; the session's token makes the rest irrelevant.
   The player repeats `JOIN` every second while it connects (a lost introduction is retried).
5. No answer after a few seconds: the player asks for a relay (`RELAY`). The lobby allocates a session, tells the host
   (`RELAYOFFER`), and both wrap their game datagrams in `DATA(session, payload)` frames to the lobby, which forwards
   them. `udp.lua` sees the relayed peer as an address `relay:<session>`; nothing above it changes.

The password is checked by the host (in its `join` message handling), never by the lobby.

## Wire format

UDP, one socket per address family on the server (default port 24860). Little-endian integers. Every datagram starts
with an 8-byte header: `"OWL"`, a type byte, a `u32` protocol version (1); others are ignored. At most 1200 bytes.

- `addr` = 18 bytes: 16-byte IPv6 address (IPv4 as `::ffff:a.b.c.d`) and a `u16` port; all zero = none.
- `addrs` = `u8` count (at most 4) and that many `addr`.
- `str` = `u8` length and that many bytes of UTF-8 (names at most 48 bytes; the server replaces control characters).
- Requests to the lobby share a prefix after the header: `u32 nonce` (8), `cookie[16]` (12); the body starts at 28.
  Without a valid cookie the lobby only answers `CHALLENGE`, which is not larger than the request (no amplification).

| type | direction | body |
|---|---|---|
| `C` CHALLENGE | lobby → any | `u32 nonce`, `cookie[16]` |
| `R` REGISTER | host → lobby | prefix, `hostKey[16]`, `u16 flags`, `u16 gameVersion`, `u8 players`, `u8 maxPlayers`, `content[8]`, `str name`, `str map`, `addrs lan` |
| `A` REGISTERED | lobby → host | `u32 nonce`, `u32 gameId`, `u32 refreshMs`, `addr observed` |
| `U` UNREGISTER | host → lobby | prefix, `hostKey[16]` (no reply) |
| `L` LIST | player → lobby | prefix, `u16 page`, `u16 gameVersion` (0: every version) |
| `G` GAMES | lobby → player | `u32 nonce`, `u16 page`, `u16 pageCount`, `u8 count`, entries: `u32 id`, `u16 flags`, `u16 gameVersion`, `u8 players`, `u8 maxPlayers`, `content[8]`, `str name`, `str map`, `u32 ageSeconds` |
| `J` JOIN | player → lobby | prefix, `u32 gameId`, `addrs lan` |
| `O` JOINED | lobby → player | `u32 nonce`, `u32 gameId`, `u8 status`, `u16 flags`, `addr host4`, `addr host6`, `addrs lan` |
| `I` INTRODUCE | lobby → host | `u32 gameId`, `addr player`, `addrs lan` |
| `Y` RELAY | player → lobby | prefix, `u32 gameId` |
| `Z` RELAYED | lobby → player | `u32 nonce`, `u8 status`, `u64 session` |
| `V` RELAYOFFER | lobby → host | `u32 gameId`, `u64 session` |
| `D` DATA | host / player ↔ lobby | `u64 session`, payload (the game's own datagram) |

Flags: bit 0 password, bit 1 private (not listed), bit 2 started (in battle; not joinable), bit 3 host accepts a relay.
Status: 0 ok, 1 no such game, 2 game not joinable (started / full), 3 relay unavailable (disabled, full or not allowed
by the host).

## Security

- Stateless cookies (`HMAC-SHA256(secret, address ‖ 60 s bucket)`), as in Sacred-Bild: every request type needs one.
- Rate limit per IPv4 address or IPv6 /64 (token bucket); the limiter table has a size cap, so a spoofed-source flood
  cannot grow it without bound.
- `hostKey` is a random 128-bit secret: only its owner can refresh, move or remove its game.
- Listings never contain addresses. A host's public and LAN addresses go only to a player that joins it; the player's
  only to that host.
- At most a few introductions per game and second (a host is not made to punch at a flood of addresses).
- Relay sessions are identified by a random 64-bit id, forward only between the two endpoints they were created for,
  and are capped in bandwidth, count (in total and per address) and idle time. The relay can be switched off.
- On the game side: network messages are decoded with a data-only parser (`serialize.lua`), fragments and lockstep
  turns are bounded (`udp.lua`, `lockstep.lua`).

## Running a lobby server

See `server/lobby/README.md`. The game finds it through `[net] lobby=host[:port]` in `openwbc3.ini`.
