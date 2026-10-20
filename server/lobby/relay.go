package main

// The relay: when hole punching fails, a player asks for a session (RELAY), the host is told (RELAYOFFER) and both
// wrap their game datagrams in DATA(session, payload) frames to this server, which forwards each frame to the other
// endpoint unchanged. A session forwards only between the player that asked for it and the host's registered
// addresses, and is capped in bandwidth, packets and idle time; the whole relay can be switched off (EnableRelay).

import (
	"crypto/rand"
	"encoding/binary"
	"log"
	"net/netip"
	"time"
)

type relaySession struct {
	id       uint64
	game     *game
	player   netip.AddrPort
	owner    netip.Addr // limit key of the player (MaxRelaysPerAddress)
	lastSeen time.Time
	bytes    bucket // RelayBytesPerSecond, both directions together
	packets  bucket // relayPacketsPerSecond
}

// relayPacketsPerSecond caps the frames of one session (lockstep sends tens of small packets a second).
const relayPacketsPerSecond = 400

type relayTable struct {
	byID     map[uint64]*relaySession
	perOwner map[netip.Addr]int
	bytes    uint64 // relayed since the last summary
}

func newRelayTable() relayTable {
	return relayTable{byID: map[uint64]*relaySession{}, perOwner: map[netip.Addr]int{}}
}

func (t *relayTable) newID() uint64 {
	var b [8]byte
	for {
		_, _ = rand.Read(b[:])
		if id := binary.LittleEndian.Uint64(b[:]); id != 0 && t.byID[id] == nil {
			return id
		}
	}
}

func (t *relayTable) remove(r *relaySession) {
	delete(t.byID, r.id)
	if t.perOwner[r.owner]--; t.perOwner[r.owner] <= 0 {
		delete(t.perOwner, r.owner)
	}
}

func (t *relayTable) dropGame(g *game) {
	for _, r := range t.byID {
		if r.game == g {
			t.remove(r)
		}
	}
}

func (t *relayTable) expire(now time.Time, idle time.Duration) {
	for _, r := range t.byID {
		if now.Sub(r.lastSeen) > idle {
			log.Printf("relay %016x of game %08x idle, closed", r.id, r.game.id)
			t.remove(r)
		}
	}
}

func (s *Server) onRelay(b []byte, from netip.AddrPort, now time.Time) {
	m, err := decodeRelay(b)
	if err != nil || !s.checkCookie(m.prefix, from, now) {
		return
	}
	g := s.byID[m.GameID]
	if g == nil {
		s.send(from, encodeRelayed(m.Nonce, statusNoGame, 0))
		return
	}
	host := g.address(is6(from))
	t := &s.relays
	owner := limitKey(from.Addr())
	if !s.cfg.EnableRelay || g.info.Flags&flagRelay == 0 || !host.IsValid() {
		s.send(from, encodeRelayed(m.Nonce, statusNoRelay, 0))
		return
	}
	// A repeated request (the reply was lost) gets the same session.
	for _, r := range t.byID {
		if r.game == g && r.player == from {
			r.lastSeen = now
			s.send(host, encodeRelayOffer(g.id, r.id))
			s.send(from, encodeRelayed(m.Nonce, statusOK, r.id))
			return
		}
	}
	if len(t.byID) >= s.cfg.MaxRelays || t.perOwner[owner] >= s.cfg.MaxRelaysPerAddress {
		s.send(from, encodeRelayed(m.Nonce, statusNoRelay, 0))
		return
	}
	r := &relaySession{id: t.newID(), game: g, player: from, owner: owner, lastSeen: now}
	t.byID[r.id] = r
	t.perOwner[owner]++
	log.Printf("relay %016x for game %08x '%s' opened (%s player, %s host)%s", r.id, g.id, g.info.Name,
		familyName(is6(from)), familyName(is6(host)), s.where(from))
	s.send(host, encodeRelayOffer(g.id, r.id))
	s.send(from, encodeRelayed(m.Nonce, statusOK, r.id))
}

// onData forwards a frame between the two ends of its session. Frames from anywhere else are dropped silently.
func (s *Server) onData(b []byte, from netip.AddrPort, now time.Time) {
	id, ok := dataSession(b)
	if !ok {
		return
	}
	r := s.relays.byID[id]
	if r == nil {
		return
	}
	var to netip.AddrPort
	switch from {
	case r.player:
		to = r.game.address(is6(from))
	case r.game.v4.addr, r.game.v6.addr:
		to = r.player
	default:
		return
	}
	if !to.IsValid() {
		return
	}
	rate := float64(s.cfg.RelayBytesPerSecond)
	if !r.packets.take(now, relayPacketsPerSecond, 2*relayPacketsPerSecond, 1) || !r.bytes.take(now, rate, 2*rate, float64(len(b))) {
		return
	}
	r.lastSeen = now
	s.relays.bytes += uint64(len(b))
	s.send(to, b)
}
