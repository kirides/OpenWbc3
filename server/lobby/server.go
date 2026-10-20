package main

import (
	"cmp"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"log"
	"net"
	"net/netip"
	"slices"
	"sync"
	"time"
)

const (
	cookieBucket     = 60 * time.Second
	summaryInterval  = 10 * time.Minute
	refuseLogEvery   = time.Minute
	introducePerSec  = 5 // introductions a host gets at most per second (bursts of twice that)
	maxLimiterTables = 1 << 16
)

// endpoint is a host's address in one family, from the latest REGISTER over that family.
type endpoint struct {
	addr     netip.AddrPort // invalid: none
	lastSeen time.Time
}

type game struct {
	id      uint32
	key     hostKey    // the host's secret: its identity across both families
	owner   netip.Addr // limit key of the address that created it (MaxGamesPerAddress)
	v4, v6  endpoint
	info    gameInfo
	lan     []netip.AddrPort
	created time.Time
	intro   bucket // introductions sent to this host
}

func (g *game) endpoint(v6 bool) *endpoint {
	if v6 {
		return &g.v6
	}
	return &g.v4
}

// address of the host for a peer in the given family: that family's endpoint, else the other one (the relay can
// bridge an IPv4-only host and an IPv6-only player).
func (g *game) address(v6 bool) netip.AddrPort {
	if a := g.endpoint(v6).addr; a.IsValid() {
		return a
	}
	return g.endpoint(!v6).addr
}

type bucket struct {
	tokens float64
	last   time.Time
}

// take refills at `rate` per second up to `burst` and takes `n`; false when there are not enough tokens.
func (b *bucket) take(now time.Time, rate, burst, n float64) bool {
	if b.last.IsZero() {
		b.tokens, b.last = burst, now
	}
	b.tokens = min(burst, b.tokens+now.Sub(b.last).Seconds()*rate)
	b.last = now
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

type Server struct {
	cfg    Config
	conn4  *net.UDPConn // either may be nil: that family isn't served
	conn6  *net.UDPConn
	secret [32]byte
	now    func() time.Time

	mu        sync.Mutex
	games     map[hostKey]*game
	byID      map[uint32]*game
	byAddr    map[netip.AddrPort]*game // by either of its addresses
	perOwner  map[netip.Addr]int
	limits    map[netip.Addr]*bucket
	overflow  bucket // shared by addresses that find the limiter table full
	relays    relayTable
	requests  uint64
	dropped   uint64
	refusedAt time.Time
}

// NewServer serves the given sockets (nil ones are skipped), each for the family of its local address.
func NewServer(cfg Config, conns ...*net.UDPConn) *Server {
	s := &Server{
		cfg:      cfg,
		now:      time.Now,
		games:    map[hostKey]*game{},
		byID:     map[uint32]*game{},
		byAddr:   map[netip.AddrPort]*game{},
		perOwner: map[netip.Addr]int{},
		limits:   map[netip.Addr]*bucket{},
		relays:   newRelayTable(),
	}
	for _, c := range conns {
		if c == nil {
			continue
		}
		if c.LocalAddr().(*net.UDPAddr).AddrPort().Addr().Unmap().Is4() {
			s.conn4 = c
		} else {
			s.conn6 = c
		}
	}
	if _, err := rand.Read(s.secret[:]); err != nil {
		panic(err)
	}
	return s
}

func is6(a netip.AddrPort) bool { return !a.Addr().Is4() }

func familyName(v6 bool) string {
	if v6 {
		return "IPv6"
	}
	return "IPv4"
}

// limitKey groups addresses for the rate limit and MaxGamesPerAddress: an IPv4 address, or an IPv6 /64 network
// (one subscriber usually has a whole /64, or more).
func limitKey(a netip.Addr) netip.Addr {
	if a.Is4() {
		return a
	}
	p, _ := a.Prefix(64)
	return p.Addr()
}

// where names an address in the log only with LogSensitiveData=1.
func (s *Server) where(a netip.AddrPort) string {
	if !s.cfg.LogSensitiveData {
		return ""
	}
	return " (" + a.String() + ")"
}

// Serve handles datagrams until ctx ends; the caller closes the connections to stop the read loops.
func (s *Server) Serve(ctx context.Context) error {
	go s.housekeeping(ctx)
	var wg sync.WaitGroup
	for _, c := range []*net.UDPConn{s.conn4, s.conn6} {
		if c == nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 2048)
			for {
				n, from, err := c.ReadFromUDPAddrPort(buf)
				if err != nil {
					if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
						return
					}
					// ICMP errors from earlier sends surface here on some systems; they don't concern the socket.
					continue
				}
				s.handle(buf[:n], from)
			}
		}()
	}
	wg.Wait()
	return nil
}

func (s *Server) housekeeping(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	summary := s.now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		now := s.now()
		s.expire(now)
		if now.Sub(summary) >= summaryInterval {
			summary = now
			s.mu.Lock()
			log.Printf("summary: %d games, %d relay sessions, %d requests, %d dropped by the rate limit, %d relayed bytes"+
				" (last %v)", len(s.games), len(s.relays.byID), s.requests, s.dropped, s.relays.bytes, summaryInterval)
			s.requests, s.dropped, s.relays.bytes = 0, 0, 0
			s.mu.Unlock()
		}
	}
}

// send answers over the socket of the destination's family.
func (s *Server) send(to netip.AddrPort, b []byte) {
	c := s.conn4
	if is6(to) {
		c = s.conn6
	}
	if c != nil && len(b) <= maxDatagram+dataHeaderSize {
		_, _ = c.WriteToUDPAddrPort(b, to)
	}
}

// cookie proves that a requester receives at its source address: only then do replies get larger than requests,
// so spoofed requests can't turn this server into an amplifier.
func (s *Server) cookie(from netip.AddrPort, bucket int64) cookie {
	var msg [addrSize + 8]byte
	putAddr(msg[:], from)
	binary.LittleEndian.PutUint64(msg[addrSize:], uint64(bucket))
	mac := hmac.New(sha256.New, s.secret[:])
	mac.Write(msg[:])
	var c cookie
	copy(c[:], mac.Sum(nil))
	return c
}

func (s *Server) currentCookie(from netip.AddrPort, now time.Time) cookie {
	return s.cookie(from, now.Unix()/int64(cookieBucket/time.Second))
}

// validCookie accepts the current and the previous bucket, so a cookie lives 60 to 120 s.
func (s *Server) validCookie(from netip.AddrPort, c cookie, now time.Time) bool {
	b := now.Unix() / int64(cookieBucket/time.Second)
	cur, prev := s.cookie(from, b), s.cookie(from, b-1)
	return hmac.Equal(c[:], cur[:]) || hmac.Equal(c[:], prev[:])
}

// checkCookie answers CHALLENGE when the request has no valid cookie (and the caller drops the request).
func (s *Server) checkCookie(p prefix, from netip.AddrPort, now time.Time) bool {
	if s.validCookie(from, p.Cookie, now) {
		return true
	}
	s.send(from, encodeChallenge(p.Nonce, s.currentCookie(from, now)))
	return false
}

// allow is a token bucket per limit key: RequestsPerSecond, bursts of twice that. When the table is full, unknown
// addresses share one bucket, so a flood of spoofed sources cannot grow memory (and gets throttled as one).
func (s *Server) allow(ip netip.Addr, now time.Time) bool {
	key := limitKey(ip)
	rate := s.cfg.RequestsPerSecond
	b := s.limits[key]
	if b == nil {
		if len(s.limits) >= maxLimiterTables {
			return s.overflow.take(now, rate, 2*rate, 1)
		}
		b = &bucket{}
		s.limits[key] = b
	}
	return b.take(now, rate, 2*rate, 1)
}

func (s *Server) handle(b []byte, from netip.AddrPort) {
	from = netip.AddrPortFrom(from.Addr().Unmap().WithZone(""), from.Port())
	kind := messageType(b)
	if kind == 0 || !from.IsValid() {
		return
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if kind == typeData {
		// relay traffic has its own limits per session (relay.go), not the request rate limit
		s.onData(b, from, now)
		return
	}
	if !s.allow(from.Addr(), now) {
		s.dropped++
		return
	}
	s.requests++
	switch kind {
	case typeRegister:
		s.onRegister(b, from, now)
	case typeUnregister:
		s.onUnregister(b, from, now)
	case typeList:
		s.onList(b, from, now)
	case typeJoin:
		s.onJoin(b, from, now)
	case typeRelay:
		s.onRelay(b, from, now)
	}
}

func (s *Server) onRegister(b []byte, from netip.AddrPort, now time.Time) {
	m, err := decodeRegister(b)
	if err != nil || !s.checkCookie(m.prefix, from, now) {
		return
	}
	v6 := is6(from)

	// Another game at this very address is gone: its host ended and a new one uses the socket now.
	if old := s.byAddr[from]; old != nil && old.key != m.Key {
		s.dropFamily(old, v6, "replaced by a new game at its address")
	}

	g := s.games[m.Key]
	if g == nil {
		owner := limitKey(from.Addr())
		if len(s.games) >= s.cfg.MaxGames || s.perOwner[owner] >= s.cfg.MaxGamesPerAddress {
			// The host repeats REGISTER every few seconds: log refusals sparingly.
			if now.Sub(s.refusedAt) >= refuseLogEvery {
				s.refusedAt = now
				log.Printf("game '%s' refused: %d games (MaxGames %d, MaxGamesPerAddress %d)%s",
					m.Info.Name, len(s.games), s.cfg.MaxGames, s.cfg.MaxGamesPerAddress, s.where(from))
			}
			return
		}
		g = &game{id: s.newID(), key: m.Key, owner: owner, created: now}
		s.games[m.Key] = g
		s.byID[g.id] = g
		s.perOwner[owner]++
		log.Printf("game %08x '%s' created over %s: %d/%d players, version %d, flags %x%s",
			g.id, m.Info.Name, familyName(v6), m.Info.Players, m.Info.MaxPlayers, m.Info.GameVersion, m.Info.Flags,
			s.where(from))
	} else if g.info.Players != m.Info.Players || g.info.Flags != m.Info.Flags {
		log.Printf("game %08x '%s': %d/%d players, flags %x", g.id, m.Info.Name, m.Info.Players, m.Info.MaxPlayers,
			m.Info.Flags)
	}

	e := g.endpoint(v6)
	if e.addr != from {
		if e.addr.IsValid() {
			delete(s.byAddr, e.addr) // NAT rebinding, or a new address
		} else if g.created != now {
			log.Printf("game %08x '%s' now reachable over %s%s", g.id, m.Info.Name, familyName(v6), s.where(from))
		}
		e.addr = from
		s.byAddr[from] = g
	}
	e.lastSeen = now
	g.info = m.Info
	g.lan = m.Lan
	s.send(from, encodeRegistered(m.Nonce, g.id, s.cfg.RefreshMs, from))
}

func (s *Server) onUnregister(b []byte, from netip.AddrPort, now time.Time) {
	m, err := decodeUnregister(b)
	// No reply either way: the host sends it once while it shuts down, and the game expires anyway.
	if err != nil || !s.validCookie(from, m.Cookie, now) {
		return
	}
	if g := s.games[m.Key]; g != nil {
		log.Printf("game %08x '%s' unregistered", g.id, g.info.Name)
		s.remove(g)
	}
}

func (s *Server) onList(b []byte, from netip.AddrPort, now time.Time) {
	m, err := decodeList(b)
	if err != nil || !s.checkCookie(m.prefix, from, now) {
		return
	}
	var listed []*game
	for _, g := range s.sorted() {
		if g.info.Flags&flagPrivate == 0 && (m.GameVersion == 0 || g.info.GameVersion == m.GameVersion) {
			listed = append(listed, g)
		}
	}
	pageCount := max(1, (len(listed)+gamesPerPage-1)/gamesPerPage)
	var entries []gameEntry
	if start := int(m.Page) * gamesPerPage; start < len(listed) {
		for _, g := range listed[start:min(start+gamesPerPage, len(listed))] {
			entries = append(entries, gameEntry{ID: g.id, Info: g.info,
				AgeSeconds: uint32(now.Sub(g.created) / time.Second)})
		}
	}
	s.send(from, encodeGames(m.Nonce, m.Page, uint16(min(pageCount, 0xFFFF)), entries))
}

func (s *Server) onJoin(b []byte, from netip.AddrPort, now time.Time) {
	m, err := decodeJoin(b)
	if err != nil || !s.checkCookie(m.prefix, from, now) {
		return
	}
	g := s.byID[m.GameID]
	if g == nil {
		s.send(from, joinedMsg{Nonce: m.Nonce, GameID: m.GameID, Status: statusNoGame}.encode())
		return
	}
	if g.info.Flags&flagStarted != 0 || (g.info.MaxPlayers > 0 && g.info.Players >= g.info.MaxPlayers) {
		s.send(from, joinedMsg{Nonce: m.Nonce, GameID: g.id, Status: statusNotJoinable, Flags: g.info.Flags}.encode())
		return
	}
	// The host punches towards the player's addresses while the player starts its handshake towards all of the
	// host's. The player repeats JOIN while it connects; the host is introduced a few times a second at most.
	if host := g.address(is6(from)); host.IsValid() && g.intro.take(now, introducePerSec, 2*introducePerSec, 1) {
		s.send(host, introduceMsg{GameID: g.id, Player: from, Lan: m.Lan}.encode())
	}
	s.send(from, joinedMsg{Nonce: m.Nonce, GameID: g.id, Status: statusOK, Flags: g.info.Flags,
		Host4: g.v4.addr, Host6: g.v6.addr, Lan: g.lan}.encode())
	log.Printf("join of game %08x '%s' over %s%s", g.id, g.info.Name, familyName(is6(from)), s.where(from))
}

func (s *Server) newID() uint32 {
	var b [4]byte
	for {
		_, _ = rand.Read(b[:])
		if id := binary.LittleEndian.Uint32(b[:]); id != 0 && s.byID[id] == nil {
			return id
		}
	}
}

// dropFamily forgets a game's address in one family, and the game if it has no address left.
func (s *Server) dropFamily(g *game, v6 bool, why string) {
	e := g.endpoint(v6)
	if !e.addr.IsValid() {
		return
	}
	delete(s.byAddr, e.addr)
	*e = endpoint{}
	if !g.v4.addr.IsValid() && !g.v6.addr.IsValid() {
		log.Printf("game %08x '%s' %s", g.id, g.info.Name, why)
		s.remove(g)
		return
	}
	log.Printf("game %08x '%s' no longer reachable over %s (%s)", g.id, g.info.Name, familyName(v6), why)
}

func (s *Server) remove(g *game) {
	for _, e := range []endpoint{g.v4, g.v6} {
		if e.addr.IsValid() && s.byAddr[e.addr] == g {
			delete(s.byAddr, e.addr)
		}
	}
	delete(s.games, g.key)
	delete(s.byID, g.id)
	if s.perOwner[g.owner]--; s.perOwner[g.owner] <= 0 {
		delete(s.perOwner, g.owner)
	}
	s.relays.dropGame(g)
}

func (s *Server) expire(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	why := "expired (no REGISTER for " + s.cfg.GameTimeout.String() + ")"
	for _, g := range s.games {
		for _, v6 := range []bool{false, true} {
			if e := g.endpoint(v6); e.addr.IsValid() && now.Sub(e.lastSeen) > s.cfg.GameTimeout {
				s.dropFamily(g, v6, why)
			}
		}
	}
	for key, b := range s.limits {
		if now.Sub(b.last) > time.Minute {
			delete(s.limits, key)
		}
	}
	s.relays.expire(now, s.cfg.RelayIdleTimeout)
}

// sorted lists the games oldest first, so pages stay stable while games come and go at the end.
func (s *Server) sorted() []*game {
	games := make([]*game, 0, len(s.games))
	for _, g := range s.games {
		games = append(games, g)
	}
	slices.SortFunc(games, func(a, b *game) int {
		if c := a.created.Compare(b.created); c != 0 {
			return c
		}
		return cmp.Compare(a.id, b.id)
	})
	return games
}

// GameView is what the web UI and /api/games show: no addresses, no private games.
type GameView struct {
	ID         uint32 `json:"id"`
	Name       string `json:"name"`
	Map        string `json:"map"`
	Players    int    `json:"players"`
	MaxPlayers int    `json:"maxPlayers"`
	Version    int    `json:"version"`
	Password   bool   `json:"password"`
	Started    bool   `json:"started"`
	IPv4       bool   `json:"ipv4"`
	IPv6       bool   `json:"ipv6"`
	AgeSeconds int64  `json:"ageSeconds"`
}

func (s *Server) Snapshot() []GameView {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	views := []GameView{}
	for _, g := range s.sorted() {
		if g.info.Flags&flagPrivate != 0 {
			continue
		}
		views = append(views, GameView{
			ID:         g.id,
			Name:       g.info.Name,
			Map:        g.info.Map,
			Players:    int(g.info.Players),
			MaxPlayers: int(g.info.MaxPlayers),
			Version:    int(g.info.GameVersion),
			Password:   g.info.Flags&flagPassword != 0,
			Started:    g.info.Flags&flagStarted != 0,
			IPv4:       g.v4.addr.IsValid(),
			IPv6:       g.v6.addr.IsValid(),
			AgeSeconds: int64(now.Sub(g.created).Seconds()),
		})
	}
	return views
}
