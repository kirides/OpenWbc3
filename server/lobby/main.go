// Lobby server for openwbc3's internet games: hosts publish their games here, players list them and get introduced
// to the host (UDP hole punching), and when punching fails the server can relay the game's datagrams.
// Protocol and design: docs/lobby.md. Derived from the Sacred-Bild matchmaker (same author), MIT like openwbc3.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Config struct {
	Listen              string
	WebListen           string
	LogSensitiveData    bool
	GameTimeout         time.Duration
	RefreshMs           uint32
	MaxGames            int
	MaxGamesPerAddress  int
	RequestsPerSecond   float64
	EnableRelay         bool
	MaxRelays           int
	MaxRelaysPerAddress int
	RelayBytesPerSecond int
	RelayIdleTimeout    time.Duration
	Title               string
	ExitAfter           time.Duration // tests: stop after this long (0: never)
}

func defaultConfig() Config {
	return Config{
		Listen:              ":24860",
		WebListen:           ":8080",
		GameTimeout:         20 * time.Second,
		RefreshMs:           5000,
		MaxGames:            1000,
		MaxGamesPerAddress:  4,
		RequestsPerSecond:   20,
		EnableRelay:         true,
		MaxRelays:           100,
		MaxRelaysPerAddress: 2,
		RelayBytesPerSecond: 32 << 10,
		RelayIdleTimeout:    30 * time.Second,
		Title:               "openwbc3 games",
	}
}

// configKeys are the ini keys; each is also a flag in lower camel case (-listen, -webListen, ...).
var configKeys = []string{"Listen", "WebListen", "LogSensitiveData", "GameTimeout", "RefreshMs", "MaxGames",
	"MaxGamesPerAddress", "RequestsPerSecond", "EnableRelay", "MaxRelays", "MaxRelaysPerAddress",
	"RelayBytesPerSecond", "RelayIdleTimeout", "Title", "ExitAfter"}

func flagName(key string) string { return strings.ToLower(key[:1]) + key[1:] }

func parseBool(key, value string) (bool, error) {
	switch strings.ToLower(value) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off", "":
		return false, nil
	}
	return false, fmt.Errorf("%s: want 0 or 1, got %q", key, value)
}

func (c *Config) set(key, value string) error {
	value = strings.TrimSpace(value)
	positive := func() (int, error) {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 {
			return 0, fmt.Errorf("%s: want a number >= 1, got %q", key, value)
		}
		return n, nil
	}
	var err error
	var n int
	switch strings.ToLower(key) {
	case "listen":
		c.Listen = value
	case "weblisten":
		c.WebListen = value
	case "logsensitivedata":
		c.LogSensitiveData, err = parseBool(key, value)
	case "gametimeout":
		n, err = positive()
		c.GameTimeout = time.Duration(n) * time.Second
	case "refreshms":
		n, err = positive()
		c.RefreshMs = uint32(n)
	case "maxgames":
		c.MaxGames, err = positive()
	case "maxgamesperaddress":
		c.MaxGamesPerAddress, err = positive()
	case "requestspersecond":
		f, perr := strconv.ParseFloat(value, 64)
		if perr != nil || f <= 0 {
			return fmt.Errorf("%s: want a number > 0, got %q", key, value)
		}
		c.RequestsPerSecond = f
	case "enablerelay":
		c.EnableRelay, err = parseBool(key, value)
	case "maxrelays":
		c.MaxRelays, err = positive()
	case "maxrelaysperaddress":
		c.MaxRelaysPerAddress, err = positive()
	case "relaybytespersecond":
		c.RelayBytesPerSecond, err = positive()
	case "relayidletimeout":
		n, err = positive()
		c.RelayIdleTimeout = time.Duration(n) * time.Second
	case "title":
		c.Title = value
	case "exitafter":
		n, err = positive()
		c.ExitAfter = time.Duration(n) * time.Second
	default:
		return fmt.Errorf("unknown key %q", key)
	}
	return err
}

// loadIni reads Key=Value lines; ';' and '#' start comments, [Section] lines are ignored.
func loadIni(path string, c *Config) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || text[0] == ';' || text[0] == '#' || text[0] == '[' {
			continue
		}
		key, value, ok := strings.Cut(text, "=")
		if !ok {
			return fmt.Errorf("%s:%d: expected Key=Value", path, line)
		}
		if err := c.set(strings.TrimSpace(key), value); err != nil {
			return fmt.Errorf("%s:%d: %w", path, line, err)
		}
	}
	return scanner.Err()
}

func loadConfig(args []string) (Config, error) {
	cfg := defaultConfig()
	fs := flag.NewFlagSet("lobby", flag.ContinueOnError)
	configPath := fs.String("config", "", "config file (default: lobby.ini next to the executable, if there is one)")
	values := map[string]*string{}
	for _, key := range configKeys {
		values[key] = fs.String(flagName(key), "", "overrides "+key+" from the config file")
	}
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}

	path := *configPath
	if path == "" {
		if exe, err := os.Executable(); err == nil {
			path = filepath.Join(filepath.Dir(exe), "lobby.ini")
			if _, err := os.Stat(path); err != nil {
				path = ""
			}
		}
	}
	if path != "" {
		if err := loadIni(path, &cfg); err != nil {
			return cfg, err
		}
		log.Printf("config: %s", path)
	}

	var err error
	fs.Visit(func(f *flag.Flag) {
		for _, key := range configKeys {
			if f.Name == flagName(key) && err == nil {
				err = cfg.set(key, *values[key])
			}
		}
	})
	if err == nil && time.Duration(cfg.RefreshMs)*time.Millisecond >= cfg.GameTimeout {
		err = fmt.Errorf("RefreshMs (%d) must be shorter than GameTimeout (%v)", cfg.RefreshMs, cfg.GameTimeout)
	}
	return cfg, err
}

func run() error {
	cfg, err := loadConfig(os.Args[1:])
	if err != nil {
		return err
	}
	log.Printf("Listen=%s WebListen=%s LogSensitiveData=%v GameTimeout=%v RefreshMs=%d MaxGames=%d "+
		"MaxGamesPerAddress=%d RequestsPerSecond=%g EnableRelay=%v MaxRelays=%d MaxRelaysPerAddress=%d "+
		"RelayBytesPerSecond=%d RelayIdleTimeout=%v Title=%q", cfg.Listen, cfg.WebListen, cfg.LogSensitiveData,
		cfg.GameTimeout, cfg.RefreshMs, cfg.MaxGames, cfg.MaxGamesPerAddress, cfg.RequestsPerSecond, cfg.EnableRelay,
		cfg.MaxRelays, cfg.MaxRelaysPerAddress, cfg.RelayBytesPerSecond, cfg.RelayIdleTimeout, cfg.Title)

	conns, err := listenUDP(cfg.Listen)
	if err != nil {
		return err
	}
	closeAll := func() {
		for _, c := range conns {
			c.Close()
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if cfg.ExitAfter > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, cfg.ExitAfter)
		defer cancel()
	}
	server := NewServer(cfg, conns...)

	var web *http.Server
	if cfg.WebListen != "" {
		web = newWebServer(cfg.WebListen, newWebHandler(server, cfg.Title))
		listener, err := net.Listen("tcp", cfg.WebListen)
		if err != nil {
			closeAll()
			return fmt.Errorf("WebListen: %w", err)
		}
		log.Printf("web UI on http://%s/", listener.Addr())
		go func() {
			if err := web.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Printf("web: %v", err)
			}
		}()
	}

	go func() {
		<-ctx.Done()
		log.Printf("shutting down")
		closeAll() // ends Serve's read loops
	}()
	err = server.Serve(ctx)
	if web != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = web.Shutdown(shutdownCtx)
	}
	return err
}

// listenUDP opens the lobby's sockets. Without a host (":24860") there is one per family, IPv4 and IPv6 (the IPv6
// one only where the system has IPv6); separate sockets don't depend on dual-stack sockets, which some systems turn
// off. With an address, just that one.
func listenUDP(listen string) ([]*net.UDPConn, error) {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return nil, fmt.Errorf("Listen: %w", err)
	}
	if host != "" {
		addr, err := net.ResolveUDPAddr("udp", listen)
		if err != nil {
			return nil, fmt.Errorf("Listen: %w", err)
		}
		network := "udp6"
		if addr.IP.To4() != nil {
			network = "udp4"
		}
		conn, err := net.ListenUDP(network, addr)
		if err != nil {
			return nil, err
		}
		log.Printf("lobby on UDP %s", conn.LocalAddr())
		return []*net.UDPConn{conn}, nil
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 0 || portNumber > 0xFFFF {
		return nil, fmt.Errorf("Listen: bad port %q", port)
	}
	conn4, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: portNumber})
	if err != nil {
		return nil, err
	}
	conns := []*net.UDPConn{conn4}
	log.Printf("lobby on UDP %s (IPv4)", conn4.LocalAddr())
	if conn6, err := net.ListenUDP("udp6", &net.UDPAddr{IP: net.IPv6unspecified, Port: portNumber}); err != nil {
		log.Printf("no IPv6: %v", err)
	} else {
		conns = append(conns, conn6)
		log.Printf("lobby on UDP %s (IPv6)", conn6.LocalAddr())
	}
	return conns, nil
}

func main() {
	if err := run(); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			os.Exit(0)
		}
		log.Fatal(err)
	}
}
