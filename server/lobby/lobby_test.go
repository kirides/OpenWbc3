package main

import (
	"bytes"
	"context"
	"io"
	"log"
	"net"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func init() { log.SetOutput(io.Discard) }

var (
	lanHost   = netip.MustParseAddrPort("192.168.1.10:24850")
	lanPlayer = netip.MustParseAddrPort("10.0.0.7:51000")
)

func TestRoundTrips(t *testing.T) {
	info := gameInfo{Flags: flagPassword | flagRelay, GameVersion: 3, Players: 2, MaxPlayers: 6,
		Content: [8]byte{1, 2, 3, 4, 5, 6, 7, 8}, Name: "Bridges at dawn", Map: "Bridges"}
	reg := registerMsg{prefix: prefix{Nonce: 7, Cookie: cookie{1, 2, 3}}, Key: hostKey{9}, Info: info,
		Lan: []netip.AddrPort{lanHost}}
	got, err := decodeRegister(reg.encode())
	if err != nil || got.Nonce != 7 || got.Cookie != reg.Cookie || got.Key != reg.Key || got.Info != info ||
		len(got.Lan) != 1 || got.Lan[0] != lanHost {
		t.Fatalf("register round trip: %v %+v", err, got)
	}

	host4 := netip.MustParseAddrPort("203.0.113.5:40000")
	host6 := netip.MustParseAddrPort("[2001:db8::5]:24850")
	var a [addrSize]byte
	putAddr(a[:], host4)
	if string(a[:16]) != "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xcb\x00\x71\x05" || le.Uint16(a[16:]) != 40000 {
		t.Fatalf("IPv4 address: % x", a)
	}
	if getAddr(a[:]) != host4 || getAddr(make([]byte, addrSize)).IsValid() {
		t.Fatal("address round trip")
	}

	// A full page of entries with the longest names fits a datagram.
	long := strings.Repeat("x", 100)
	var entries []gameEntry
	for i := range gamesPerPage {
		entries = append(entries, gameEntry{ID: uint32(i + 1), Info: gameInfo{Name: long, Map: long}, AgeSeconds: 61})
	}
	g := encodeGames(5, 1, 3, entries)
	if len(g) > maxDatagram {
		t.Fatalf("a full page is %d bytes", len(g))
	}
	nonce, page, pageCount, back, err := decodeGames(g)
	if err != nil || nonce != 5 || page != 1 || pageCount != 3 || len(back) != gamesPerPage ||
		len(back[0].Info.Name) != maxString || back[7].AgeSeconds != 61 {
		t.Fatalf("games round trip: %v %+v", err, back)
	}

	j := joinedMsg{Nonce: 3, GameID: 4, Status: statusOK, Flags: flagRelay, Host4: host4, Host6: host6,
		Lan: []netip.AddrPort{lanHost}}
	if back, err := decodeJoined(j.encode()); err != nil || back.Host4 != host4 || back.Host6 != host6 ||
		len(back.Lan) != 1 || back.Flags != flagRelay {
		t.Fatalf("joined round trip: %v %+v", err, back)
	}
	in := introduceMsg{GameID: 4, Player: host6, Lan: []netip.AddrPort{lanPlayer}}
	if back, err := decodeIntroduce(in.encode()); err != nil || back.Player != host6 || back.Lan[0] != lanPlayer {
		t.Fatalf("introduce round trip: %v %+v", err, back)
	}

	// Truncated and oversized fields are errors, not panics.
	b := reg.encode()
	for n := headerSize; n < len(b); n++ {
		if _, err := decodeRegister(b[:n]); err == nil {
			t.Fatalf("register cut at %d bytes decoded", n)
		}
	}
	bad := joinMsg{GameID: 1}.encode()
	bad[len(bad)-1] = maxLanAddrs + 1
	if _, err := decodeJoin(bad); err == nil {
		t.Fatal("too many LAN addresses accepted")
	}
}

func TestSanitize(t *testing.T) {
	if s := sanitize("Ancaria\x1b[2J\nnight\xff"); s != "Ancaria?[2J?night?" {
		t.Fatalf("sanitize: %q", s)
	}
	if s := clip(strings.Repeat("ä", 40)); len(s) > maxString || !strings.HasPrefix(strings.Repeat("ä", 40), s) {
		t.Fatalf("clip split a character: %q", s)
	}
}

func TestCookieBuckets(t *testing.T) {
	s := NewServer(defaultConfig())
	t0 := time.Unix(1_000_000_040, 0) // 20 s into a bucket (1_000_000_020 is a multiple of 60)
	for _, from := range []netip.AddrPort{netip.MustParseAddrPort("203.0.113.5:1000"),
		netip.MustParseAddrPort("[2001:db8::5]:1000")} {
		c := s.currentCookie(from, t0)
		for _, tc := range []struct {
			after time.Duration
			valid bool
		}{{0, true}, {39 * time.Second, true}, {41 * time.Second, true}, {99 * time.Second, true}, {101 * time.Second, false}} {
			if got := s.validCookie(from, c, t0.Add(tc.after)); got != tc.valid {
				t.Errorf("%v after %v: valid %v, want %v", from, tc.after, got, tc.valid)
			}
		}
		if s.validCookie(netip.AddrPortFrom(from.Addr(), 1001), c, t0) {
			t.Errorf("%v: cookie valid for another port", from)
		}
	}
}

func TestLimitKey(t *testing.T) {
	a, b := netip.MustParseAddr("2001:db8:1:2::1"), netip.MustParseAddr("2001:db8:1:2:ffff:ffff:ffff:ffff")
	if limitKey(a) != limitKey(b) || limitKey(a) == limitKey(netip.MustParseAddr("2001:db8:1:3::1")) {
		t.Fatal("IPv6 addresses are limited per /64")
	}
	if v4 := netip.MustParseAddr("203.0.113.5"); limitKey(v4) != v4 {
		t.Fatal("IPv4 addresses are limited per address")
	}
}

func TestLimiterTableIsBounded(t *testing.T) {
	cfg := defaultConfig()
	cfg.RequestsPerSecond = 1
	s := NewServer(cfg)
	now := time.Unix(1_000_000_000, 0)
	var a [4]byte
	for i := range maxLimiterTables + 1000 {
		a[0], a[1], a[2], a[3] = 10, byte(i>>16), byte(i>>8), byte(i)
		s.allow(netip.AddrFrom4(a), now)
	}
	if len(s.limits) != maxLimiterTables {
		t.Fatalf("limiter table grew to %d", len(s.limits))
	}
	// The addresses beyond the table share one bucket: two of them are throttled together.
	x, y := netip.MustParseAddr("11.0.0.1"), netip.MustParseAddr("11.0.0.2")
	s.overflow = bucket{}
	if !s.allow(x, now) || !s.allow(y, now) || s.allow(x, now) {
		t.Fatal("overflow bucket")
	}
}

// fakeClock lets a test move time forward for expiry and cookies.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *fakeClock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type peer struct {
	t      *testing.T
	conn   *net.UDPConn
	to     *net.UDPAddr
	cookie cookie
}

// newPeer binds a loopback socket in the family of the server address it talks to.
func newPeer(t *testing.T, server *net.UDPAddr) *peer {
	network, ip := "udp4", net.IPv4(127, 0, 0, 1)
	if server.IP.To4() == nil {
		network, ip = "udp6", net.IPv6loopback
	}
	conn, err := net.ListenUDP(network, &net.UDPAddr{IP: ip})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return &peer{t: t, conn: conn, to: server}
}

func (p *peer) addr() netip.AddrPort {
	a := p.conn.LocalAddr().(*net.UDPAddr).AddrPort()
	return netip.AddrPortFrom(a.Addr().Unmap(), a.Port())
}

func (p *peer) send(b []byte) {
	p.t.Helper()
	if _, err := p.conn.WriteToUDP(b, p.to); err != nil {
		p.t.Fatal(err)
	}
}

func (p *peer) read() []byte {
	p.t.Helper()
	b := p.tryRead(2 * time.Second)
	if b == nil {
		p.t.Fatal("no reply")
	}
	return b
}

func (p *peer) tryRead(timeout time.Duration) []byte {
	buf := make([]byte, 2048)
	_ = p.conn.SetReadDeadline(time.Now().Add(timeout))
	n, err := p.conn.Read(buf)
	if err != nil {
		return nil
	}
	return buf[:n]
}

// request sends a request; without a cookie yet it first checks that the CHALLENGE reply is not larger than the
// request (no amplification), keeps the cookie and sends again. Returns the reply.
func (p *peer) request(build func(prefix) []byte) []byte {
	p.t.Helper()
	nonce := uint32(len(p.cookie)) + 77
	if p.cookie == (cookie{}) {
		req := build(prefix{Nonce: nonce})
		p.send(req)
		c := p.read()
		if messageType(c) != typeChallenge || len(c) > len(req) || le.Uint32(c[8:]) != nonce {
			p.t.Fatalf("want CHALLENGE no larger than %d bytes, got % x", len(req), c)
		}
		copy(p.cookie[:], c[12:])
	}
	p.send(build(prefix{Nonce: nonce, Cookie: p.cookie}))
	return p.read()
}

func (p *peer) register(m registerMsg) (gameID uint32, observed netip.AddrPort) {
	p.t.Helper()
	r := p.request(func(px prefix) []byte { m.prefix = px; return m.encode() })
	if messageType(r) != typeRegistered {
		p.t.Fatalf("want REGISTERED, got % x", r)
	}
	return le.Uint32(r[12:]), getAddr(r[20:38])
}

func (p *peer) list(page, version uint16) []gameEntry {
	p.t.Helper()
	_, _, _, entries, err := decodeGames(p.request(func(px prefix) []byte {
		return listMsg{prefix: px, Page: page, GameVersion: version}.encode()
	}))
	if err != nil {
		p.t.Fatal(err)
	}
	return entries
}

func (p *peer) join(id uint32, lan ...netip.AddrPort) joinedMsg {
	p.t.Helper()
	j, err := decodeJoined(p.request(func(px prefix) []byte { return joinMsg{prefix: px, GameID: id, Lan: lan}.encode() }))
	if err != nil {
		p.t.Fatal(err)
	}
	return j
}

type testServer struct {
	s     *Server
	clock *fakeClock
	addr4 *net.UDPAddr
	addr6 *net.UDPAddr // nil without IPv6 loopback
}

// startServer serves 127.0.0.1 and, where it can be bound, ::1.
func startServer(t *testing.T, cfg Config) testServer {
	conn4, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	conn6, _ := net.ListenUDP("udp6", &net.UDPAddr{IP: net.IPv6loopback})
	ts := testServer{s: NewServer(cfg, conn4, conn6), clock: &fakeClock{t: time.Unix(1_000_000_000, 0)},
		addr4: conn4.LocalAddr().(*net.UDPAddr)}
	if conn6 != nil {
		ts.addr6 = conn6.LocalAddr().(*net.UDPAddr)
	}
	ts.s.now = ts.clock.now
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = ts.s.Serve(ctx); close(done) }()
	t.Cleanup(func() {
		cancel()
		conn4.Close()
		if conn6 != nil {
			conn6.Close()
		}
		<-done
	})
	return ts
}

func checkWeb(t *testing.T, s *Server, want, notWant string) {
	t.Helper()
	for _, path := range []string{"/api/games", "/"} {
		rec := httptest.NewRecorder()
		newWebHandler(s, "Test").ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		body := rec.Body.String()
		if !strings.Contains(body, want) || strings.Contains(body, "127.0.0.1") || strings.Contains(body, "::1") ||
			strings.Contains(body, "192.168.") || (notWant != "" && strings.Contains(body, notWant)) {
			t.Fatalf("%s: %s", path, body)
		}
	}
}

func testGame(name string, flags uint16) registerMsg {
	return registerMsg{Key: hostKey{byte(len(name)), 1, 2, 3}, Lan: []netip.AddrPort{lanHost},
		Info: gameInfo{Flags: flags, GameVersion: 3, Players: 1, MaxPlayers: 4, Name: name, Map: "Bridges"}}
}

func TestEndToEnd(t *testing.T) {
	cfg := defaultConfig()
	ts := startServer(t, cfg)
	host, player, other := newPeer(t, ts.addr4), newPeer(t, ts.addr4), newPeer(t, ts.addr4)

	id, observed := host.register(testGame("Ancaria", flagRelay))
	if id == 0 || observed != host.addr() {
		t.Fatalf("REGISTERED: %08x %v", id, observed)
	}
	other.register(testGame("Hidden one", flagPrivate))

	// LIST: the public game only, without any address; a version filter drops it.
	entries := player.list(0, 0)
	if len(entries) != 1 || entries[0].ID != id || entries[0].Info.Name != "Ancaria" || entries[0].Info.Map != "Bridges" {
		t.Fatalf("GAMES: %+v", entries)
	}
	if e := player.list(0, 4); len(e) != 0 {
		t.Fatalf("version filter: %+v", e)
	}

	// JOIN: the player gets the host's public and LAN addresses, the host gets the player's.
	j := player.join(id, lanPlayer)
	if j.Status != statusOK || j.Host4 != host.addr() || j.Host6.IsValid() || len(j.Lan) != 1 || j.Lan[0] != lanHost {
		t.Fatalf("JOINED: %+v", j)
	}
	in, err := decodeIntroduce(host.read())
	if err != nil || in.GameID != id || in.Player != player.addr() || len(in.Lan) != 1 || in.Lan[0] != lanPlayer {
		t.Fatalf("INTRODUCE: %v %+v", err, in)
	}
	if j := player.join(id + 1); j.Status != statusNoGame || j.Host4.IsValid() {
		t.Fatalf("JOINED for an unknown game: %+v", j)
	}

	checkWeb(t, ts.s, "Ancaria", "Hidden one")

	// A started game is listed but not joinable.
	m := testGame("Ancaria", flagRelay|flagStarted)
	host.register(m)
	if j := player.join(id); j.Status != statusNotJoinable || j.Host4.IsValid() {
		t.Fatalf("JOINED for a started game: %+v", j)
	}

	// UNREGISTER needs the host's key, not just a cookie.
	other.send(unregisterMsg{prefix: prefix{Cookie: other.cookie}, Key: hostKey{1}}.encode())
	host.send(unregisterMsg{prefix: prefix{Cookie: host.cookie}, Key: m.Key}.encode())
	time.Sleep(100 * time.Millisecond)
	if e := player.list(0, 0); len(e) != 0 {
		t.Fatalf("game not unregistered: %+v", e)
	}

	// Expiry: no REGISTER for longer than GameTimeout.
	id, _ = host.register(testGame("Again", 0))
	ts.clock.add(cfg.GameTimeout + time.Second)
	ts.s.expire(ts.clock.now())
	player.cookie = cookie{} // the old one has expired as well
	if e := player.list(0, 0); len(e) != 0 {
		t.Fatalf("game didn't expire: %+v", e)
	}
}

func TestIntroductionsAreLimited(t *testing.T) {
	ts := startServer(t, defaultConfig())
	host, player := newPeer(t, ts.addr4), newPeer(t, ts.addr4)
	id, _ := host.register(testGame("Busy", 0))
	for range 30 {
		player.join(id)
	}
	n := 0
	for host.tryRead(200*time.Millisecond) != nil {
		n++
	}
	if n == 0 || n > 2*introducePerSec {
		t.Fatalf("%d introductions for 30 joins", n)
	}
}

func TestRelay(t *testing.T) {
	ts := startServer(t, defaultConfig())
	host, player, stranger := newPeer(t, ts.addr4), newPeer(t, ts.addr4), newPeer(t, ts.addr4)
	id, _ := host.register(testGame("Relayed", flagRelay))

	r := player.request(func(px prefix) []byte { return relayMsg{prefix: px, GameID: id}.encode() })
	if messageType(r) != typeRelayed || r[12] != statusOK {
		t.Fatalf("RELAYED: % x", r)
	}
	session := le.Uint64(r[13:])
	offer := host.read()
	if messageType(offer) != typeRelayOffer || le.Uint32(offer[8:]) != id || le.Uint64(offer[12:]) != session {
		t.Fatalf("RELAYOFFER: % x", offer)
	}

	// Both directions, unchanged.
	player.send(encodeData(session, []byte("WS hello")))
	if b := host.read(); !bytes.Equal(b, encodeData(session, []byte("WS hello"))) {
		t.Fatalf("to host: % x", b)
	}
	host.send(encodeData(session, []byte("WS welcome")))
	if b := player.read(); !bytes.Equal(b, encodeData(session, []byte("WS welcome"))) {
		t.Fatalf("to player: % x", b)
	}
	// A third party that knows nothing gets nowhere; even with the session id it is not one of the two ends.
	stranger.send(encodeData(session, []byte("injected")))
	if b := host.tryRead(200 * time.Millisecond); b != nil {
		t.Fatalf("stranger reached the host: % x", b)
	}

	// The session closes when the game goes away.
	ts.clock.add(defaultConfig().GameTimeout + time.Second)
	ts.s.expire(ts.clock.now())
	if ts.s.relayCount() != 0 {
		t.Fatal("relay session survived its game")
	}
}

func TestRelayRefused(t *testing.T) {
	cfg := defaultConfig()
	ts := startServer(t, cfg)
	host, player := newPeer(t, ts.addr4), newPeer(t, ts.addr4)
	id, _ := host.register(testGame("No relay", 0)) // the host does not accept a relay
	r := player.request(func(px prefix) []byte { return relayMsg{prefix: px, GameID: id}.encode() })
	if messageType(r) != typeRelayed || r[12] != statusNoRelay {
		t.Fatalf("RELAYED: % x", r)
	}

	cfg.EnableRelay = false
	ts2 := startServer(t, cfg)
	host2, player2 := newPeer(t, ts2.addr4), newPeer(t, ts2.addr4)
	id2, _ := host2.register(testGame("Relay off", flagRelay))
	if r := player2.request(func(px prefix) []byte { return relayMsg{prefix: px, GameID: id2}.encode() }); r[12] != statusNoRelay {
		t.Fatalf("relay switched off: % x", r)
	}
}

func TestRelayBandwidth(t *testing.T) {
	cfg := defaultConfig()
	cfg.RelayBytesPerSecond = 1000
	ts := startServer(t, cfg)
	host, player := newPeer(t, ts.addr4), newPeer(t, ts.addr4)
	id, _ := host.register(testGame("Slow", flagRelay))
	r := player.request(func(px prefix) []byte { return relayMsg{prefix: px, GameID: id}.encode() })
	session := le.Uint64(r[13:])
	host.read() // the offer
	payload := make([]byte, 500)
	for range 10 {
		player.send(encodeData(session, payload))
	}
	n := 0
	for host.tryRead(200*time.Millisecond) != nil {
		n++
	}
	if n == 0 || n > 4 { // a burst of 2000 bytes: three 516-byte frames
		t.Fatalf("%d frames of 516 bytes passed a 1000 B/s relay", n)
	}
}

func TestDualStack(t *testing.T) {
	ts := startServer(t, defaultConfig())
	if ts.addr6 == nil {
		t.Skip("no IPv6 loopback")
	}
	host4, host6, player6 := newPeer(t, ts.addr4), newPeer(t, ts.addr6), newPeer(t, ts.addr6)
	m := testGame("Dual", flagRelay)
	id, _ := host4.register(m)
	if id6, _ := host6.register(m); id6 != id {
		t.Fatalf("same key, two games: %08x %08x", id, id6)
	}
	j := player6.join(id)
	if j.Host4 != host4.addr() || j.Host6 != host6.addr() {
		t.Fatalf("JOINED: %+v", j)
	}
	if in, _ := decodeIntroduce(host6.read()); in.Player != player6.addr() {
		t.Fatalf("INTRODUCE over IPv6: %+v", in)
	}
}

func TestConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lobby.ini")
	ini := "; comment\n[Lobby]\nListen = :3000\nEnableRelay = 0\nRelayBytesPerSecond = 2048\nTitle = My games\n"
	if err := os.WriteFile(path, []byte(ini), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig([]string{"-config", path, "-maxRelays", "7"})
	if err != nil || cfg.Listen != ":3000" || cfg.EnableRelay || cfg.RelayBytesPerSecond != 2048 || cfg.MaxRelays != 7 ||
		cfg.Title != "My games" {
		t.Fatalf("%v %+v", err, cfg)
	}
	if _, err := loadConfig([]string{"-refreshMs", "30000"}); err == nil {
		t.Fatal("RefreshMs longer than GameTimeout accepted")
	}
	if _, err := loadConfig([]string{"-config", path, "-maxGames", "0"}); err == nil {
		t.Fatal("MaxGames 0 accepted")
	}
}
