package main

// Wire format of the lobby protocol (docs/lobby.md): an 8-byte header ("OWL", type, u32 version), little-endian
// integers, addresses as 18 bytes (16-byte IPv6, IPv4 as ::ffff:a.b.c.d, then the port; all zero = none), strings as
// a u8 length and UTF-8 bytes, address lists as a u8 count and addresses.

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	protocolVersion = 1
	maxDatagram     = 1200
	headerSize      = 8
	cookieSize      = 16
	keySize         = 16
	contentSize     = 8
	addrSize        = 18
	prefixSize      = headerSize + 4 + cookieSize // header, nonce, cookie
	maxString       = 48
	maxLanAddrs     = 4
	gamesPerPage    = 8

	flagPassword = 1 << 0
	flagPrivate  = 1 << 1
	flagStarted  = 1 << 2
	flagRelay    = 1 << 3

	statusOK          = 0
	statusNoGame      = 1
	statusNotJoinable = 2
	statusNoRelay     = 3
)

// Message types: the 4th byte after "OWL".
const (
	typeChallenge  = 'C'
	typeRegister   = 'R'
	typeRegistered = 'A'
	typeUnregister = 'U'
	typeList       = 'L'
	typeGames      = 'G'
	typeJoin       = 'J'
	typeJoined     = 'O'
	typeIntroduce  = 'I'
	typeRelay      = 'Y'
	typeRelayed    = 'Z'
	typeRelayOffer = 'V'
	typeData       = 'D'
)

var le = binary.LittleEndian

type cookie [cookieSize]byte
type hostKey [keySize]byte

var errShort = errors.New("short message")

// messageType returns the type of a lobby datagram of this protocol version, or 0.
func messageType(b []byte) byte {
	if len(b) < headerSize || string(b[:3]) != "OWL" || le.Uint32(b[4:]) != protocolVersion {
		return 0
	}
	return b[3]
}

// writer appends fields to a message.
type writer struct{ b []byte }

func newMessage(kind byte) *writer {
	w := &writer{b: make([]byte, headerSize, 256)}
	copy(w.b, "OWL")
	w.b[3] = kind
	le.PutUint32(w.b[4:], protocolVersion)
	return w
}

func (w *writer) u8(v uint8)     { w.b = append(w.b, v) }
func (w *writer) u16(v uint16)   { w.b = le.AppendUint16(w.b, v) }
func (w *writer) u32(v uint32)   { w.b = le.AppendUint32(w.b, v) }
func (w *writer) u64(v uint64)   { w.b = le.AppendUint64(w.b, v) }
func (w *writer) bytes(v []byte) { w.b = append(w.b, v...) }
func (w *writer) str(s string)   { s = clip(s); w.u8(uint8(len(s))); w.b = append(w.b, s...) }
func (w *writer) addr(a netip.AddrPort) {
	var b [addrSize]byte
	putAddr(b[:], a)
	w.b = append(w.b, b[:]...)
}
func (w *writer) addrs(list []netip.AddrPort) {
	n := min(len(list), maxLanAddrs)
	w.u8(uint8(n))
	for _, a := range list[:n] {
		w.addr(a)
	}
}

// reader reads fields; after the first error every read returns zero values and err stays set.
type reader struct {
	b   []byte
	off int
	err error
}

func newReader(b []byte, off int) *reader { return &reader{b: b, off: off} }

func (r *reader) take(n int) []byte {
	if r.err != nil || r.off+n > len(r.b) {
		r.err = errShort
		return nil
	}
	v := r.b[r.off : r.off+n]
	r.off += n
	return v
}
func (r *reader) u8() uint8 {
	if v := r.take(1); v != nil {
		return v[0]
	}
	return 0
}
func (r *reader) u16() uint16 {
	if v := r.take(2); v != nil {
		return le.Uint16(v)
	}
	return 0
}
func (r *reader) u32() uint32 {
	if v := r.take(4); v != nil {
		return le.Uint32(v)
	}
	return 0
}
func (r *reader) u64() uint64 {
	if v := r.take(8); v != nil {
		return le.Uint64(v)
	}
	return 0
}
func (r *reader) str() string {
	n := int(r.u8())
	if n > maxString {
		r.err = errors.New("string too long")
		return ""
	}
	return sanitize(string(r.take(n)))
}
func (r *reader) addr() netip.AddrPort {
	if v := r.take(addrSize); v != nil {
		return getAddr(v)
	}
	return netip.AddrPort{}
}
func (r *reader) addrs() []netip.AddrPort {
	n := int(r.u8())
	if n > maxLanAddrs {
		r.err = errors.New("too many addresses")
		return nil
	}
	var list []netip.AddrPort
	for range n {
		if a := r.addr(); a.IsValid() {
			list = append(list, a)
		}
	}
	return list
}

// putAddr writes an 18-byte address; an invalid one (no address) stays all zero.
func putAddr(b []byte, a netip.AddrPort) {
	if !a.IsValid() {
		return
	}
	ip := a.Addr().As16()
	copy(b, ip[:])
	le.PutUint16(b[16:], a.Port())
}

func getAddr(b []byte) netip.AddrPort {
	ip := [16]byte(b[:16])
	port := le.Uint16(b[16:])
	if ip == [16]byte{} && port == 0 {
		return netip.AddrPort{}
	}
	return netip.AddrPortFrom(netip.AddrFrom16(ip).Unmap(), port)
}

// sanitize keeps free text (game and map names) printable: invalid UTF-8 and control characters (line breaks,
// terminal escapes) become '?', so they cannot garble logs or the web page.
func sanitize(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "?")
	}
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == utf8.RuneError {
			return '?'
		}
		return r
	}, s))
}

// clip cuts a string to maxString bytes without splitting a UTF-8 sequence.
func clip(s string) string {
	if len(s) <= maxString {
		return s
	}
	s = s[:maxString]
	for len(s) > 0 && !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

// --- requests (host / player -> lobby) ---

// prefix is the start every request shares: nonce and cookie.
type prefix struct {
	Nonce  uint32
	Cookie cookie
}

func readPrefix(b []byte) (prefix, *reader) {
	r := newReader(b, headerSize)
	var p prefix
	p.Nonce = r.u32()
	copy(p.Cookie[:], r.take(cookieSize))
	return p, r
}

func newRequest(kind byte, p prefix) *writer {
	w := newMessage(kind)
	w.u32(p.Nonce)
	w.bytes(p.Cookie[:])
	return w
}

// gameInfo is what a host publishes about its game.
type gameInfo struct {
	Flags       uint16
	GameVersion uint16
	Players     uint8
	MaxPlayers  uint8
	Content     [contentSize]byte
	Name        string
	Map         string
}

type registerMsg struct {
	prefix
	Key  hostKey
	Info gameInfo
	Lan  []netip.AddrPort
}

func (m registerMsg) encode() []byte {
	w := newRequest(typeRegister, m.prefix)
	w.bytes(m.Key[:])
	w.u16(m.Info.Flags)
	w.u16(m.Info.GameVersion)
	w.u8(m.Info.Players)
	w.u8(m.Info.MaxPlayers)
	w.bytes(m.Info.Content[:])
	w.str(m.Info.Name)
	w.str(m.Info.Map)
	w.addrs(m.Lan)
	return w.b
}

func decodeRegister(b []byte) (m registerMsg, err error) {
	var r *reader
	m.prefix, r = readPrefix(b)
	copy(m.Key[:], r.take(keySize))
	m.Info.Flags = r.u16()
	m.Info.GameVersion = r.u16()
	m.Info.Players = r.u8()
	m.Info.MaxPlayers = r.u8()
	copy(m.Info.Content[:], r.take(contentSize))
	m.Info.Name = r.str()
	m.Info.Map = r.str()
	m.Lan = r.addrs()
	if m.Info.MaxPlayers > 0 && m.Info.Players > m.Info.MaxPlayers {
		m.Info.Players = m.Info.MaxPlayers
	}
	return m, r.err
}

type unregisterMsg struct {
	prefix
	Key hostKey
}

func (m unregisterMsg) encode() []byte {
	w := newRequest(typeUnregister, m.prefix)
	w.bytes(m.Key[:])
	return w.b
}

func decodeUnregister(b []byte) (m unregisterMsg, err error) {
	var r *reader
	m.prefix, r = readPrefix(b)
	copy(m.Key[:], r.take(keySize))
	return m, r.err
}

type listMsg struct {
	prefix
	Page        uint16
	GameVersion uint16
}

func (m listMsg) encode() []byte {
	w := newRequest(typeList, m.prefix)
	w.u16(m.Page)
	w.u16(m.GameVersion)
	return w.b
}

func decodeList(b []byte) (m listMsg, err error) {
	var r *reader
	m.prefix, r = readPrefix(b)
	m.Page = r.u16()
	m.GameVersion = r.u16()
	return m, r.err
}

type joinMsg struct {
	prefix
	GameID uint32
	Lan    []netip.AddrPort
}

func (m joinMsg) encode() []byte {
	w := newRequest(typeJoin, m.prefix)
	w.u32(m.GameID)
	w.addrs(m.Lan)
	return w.b
}

func decodeJoin(b []byte) (m joinMsg, err error) {
	var r *reader
	m.prefix, r = readPrefix(b)
	m.GameID = r.u32()
	m.Lan = r.addrs()
	return m, r.err
}

type relayMsg struct {
	prefix
	GameID uint32
}

func (m relayMsg) encode() []byte {
	w := newRequest(typeRelay, m.prefix)
	w.u32(m.GameID)
	return w.b
}

func decodeRelay(b []byte) (m relayMsg, err error) {
	var r *reader
	m.prefix, r = readPrefix(b)
	m.GameID = r.u32()
	return m, r.err
}

// --- replies (lobby -> host / player) ---

func encodeChallenge(nonce uint32, c cookie) []byte {
	w := newMessage(typeChallenge)
	w.u32(nonce)
	w.bytes(c[:])
	return w.b
}

func encodeRegistered(nonce, gameID, refreshMs uint32, observed netip.AddrPort) []byte {
	w := newMessage(typeRegistered)
	w.u32(nonce)
	w.u32(gameID)
	w.u32(refreshMs)
	w.addr(observed)
	return w.b
}

type gameEntry struct {
	ID         uint32
	Info       gameInfo
	AgeSeconds uint32
}

func encodeGames(nonce uint32, page, pageCount uint16, entries []gameEntry) []byte {
	w := newMessage(typeGames)
	w.u32(nonce)
	w.u16(page)
	w.u16(pageCount)
	w.u8(uint8(len(entries)))
	for _, e := range entries {
		w.u32(e.ID)
		w.u16(e.Info.Flags)
		w.u16(e.Info.GameVersion)
		w.u8(e.Info.Players)
		w.u8(e.Info.MaxPlayers)
		w.bytes(e.Info.Content[:])
		w.str(e.Info.Name)
		w.str(e.Info.Map)
		w.u32(e.AgeSeconds)
	}
	return w.b
}

func decodeGames(b []byte) (nonce uint32, page, pageCount uint16, entries []gameEntry, err error) {
	r := newReader(b, headerSize)
	nonce = r.u32()
	page = r.u16()
	pageCount = r.u16()
	n := int(r.u8())
	for range n {
		var e gameEntry
		e.ID = r.u32()
		e.Info.Flags = r.u16()
		e.Info.GameVersion = r.u16()
		e.Info.Players = r.u8()
		e.Info.MaxPlayers = r.u8()
		copy(e.Info.Content[:], r.take(contentSize))
		e.Info.Name = r.str()
		e.Info.Map = r.str()
		e.AgeSeconds = r.u32()
		entries = append(entries, e)
	}
	return nonce, page, pageCount, entries, r.err
}

type joinedMsg struct {
	Nonce        uint32
	GameID       uint32
	Status       uint8
	Flags        uint16
	Host4, Host6 netip.AddrPort
	Lan          []netip.AddrPort
}

func (m joinedMsg) encode() []byte {
	w := newMessage(typeJoined)
	w.u32(m.Nonce)
	w.u32(m.GameID)
	w.u8(m.Status)
	w.u16(m.Flags)
	w.addr(m.Host4)
	w.addr(m.Host6)
	w.addrs(m.Lan)
	return w.b
}

func decodeJoined(b []byte) (m joinedMsg, err error) {
	r := newReader(b, headerSize)
	m.Nonce = r.u32()
	m.GameID = r.u32()
	m.Status = r.u8()
	m.Flags = r.u16()
	m.Host4 = r.addr()
	m.Host6 = r.addr()
	m.Lan = r.addrs()
	return m, r.err
}

type introduceMsg struct {
	GameID uint32
	Player netip.AddrPort
	Lan    []netip.AddrPort
}

func (m introduceMsg) encode() []byte {
	w := newMessage(typeIntroduce)
	w.u32(m.GameID)
	w.addr(m.Player)
	w.addrs(m.Lan)
	return w.b
}

func decodeIntroduce(b []byte) (m introduceMsg, err error) {
	r := newReader(b, headerSize)
	m.GameID = r.u32()
	m.Player = r.addr()
	m.Lan = r.addrs()
	return m, r.err
}

func encodeRelayed(nonce uint32, status uint8, session uint64) []byte {
	w := newMessage(typeRelayed)
	w.u32(nonce)
	w.u8(status)
	w.u64(session)
	return w.b
}

func encodeRelayOffer(gameID uint32, session uint64) []byte {
	w := newMessage(typeRelayOffer)
	w.u32(gameID)
	w.u64(session)
	return w.b
}

const dataHeaderSize = headerSize + 8

func encodeData(session uint64, payload []byte) []byte {
	w := newMessage(typeData)
	w.u64(session)
	w.bytes(payload)
	return w.b
}

// dataSession returns the session of a DATA frame (the payload follows at dataHeaderSize).
func dataSession(b []byte) (uint64, bool) {
	if len(b) < dataHeaderSize {
		return 0, false
	}
	return le.Uint64(b[headerSize:]), true
}
