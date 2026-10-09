package libtsnet_forwarder

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

// ForwardCallback defines the forwarding status callback interface
type ForwardCallback struct {
	OnForwardSuccess func(remoteAddr string, remotePort int, localPort int)
	OnForwardClosed  func(remoteAddr string, remotePort int, localPort int)
	OnForwardError   func(remoteAddr string, remotePort int, localPort int, err error)
}

// ConnectCallback defines the connection status callback interface
type ConnectCallback struct {
	OnConnectSuccess func(hostname string, magicDNS string, ipv4 string, ipv6 string)
	OnConnectError   func(hostname string, err error)
}

// ForwardInfo stores forwarding information
type ForwardInfo struct {
	RemoteAddr string
	RemotePort int
	LocalPort  int
	Listener   net.Listener
	Cancel     context.CancelFunc
}

// TSNetForwarder tsnet forwarder
type TSNetForwarder struct {
	server          *tsnet.Server
	authKey         string
	hostname        string
	stateDir        string
	forwards        map[string]*ForwardInfo
	callback        *ForwardCallback
	connectCallback *ConnectCallback
	mutex           sync.RWMutex
	isStarted       bool
}

var globalForwarder *TSNetForwarder
var initOnce sync.Once

// GetInstance gets the global singleton
func GetInstance() *TSNetForwarder {
	initOnce.Do(func() {
		globalForwarder = &TSNetForwarder{
			forwards: make(map[string]*ForwardInfo),
			stateDir: "/tmp/tsnet-forwarder", // default state directory
		}
	})
	return globalForwarder
}

// UpdateTsnetAuthKey sets the tsnet authentication key
func (f *TSNetForwarder) UpdateTsnetAuthKey(authKey string) error {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	f.authKey = authKey

	// If the server is already started, need to reinitialize
	if f.isStarted {
		f.stopServer()
		return f.startServer()
	}
	return nil
}

// TsnetUpdateHostname sets the tsnet client hostname
func (f *TSNetForwarder) TsnetUpdateHostname(hostname string) error {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	f.hostname = hostname

	// If the server is already started, need to reinitialize to use the new hostname
	if f.isStarted {
		f.stopServer()
		return f.startServer()
	}
	return nil
}

// TsnetUpdateStateDir sets the tsnet state directory
func (f *TSNetForwarder) TsnetUpdateStateDir(stateDir string) error {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	f.stateDir = stateDir

	// If the server is already started, need to reinitialize to use the new state directory
	if f.isStarted {
		f.stopServer()
		return f.startServer()
	}
	return nil
}

// getHostname gets the hostname to use, if not set, use the local hostname
func (f *TSNetForwarder) getHostname() string {
	if f.hostname != "" {
		return f.hostname
	}

	// Try to get the local hostname
	if hostname, err := os.Hostname(); err == nil && hostname != "" {
		return hostname
	}

	// If failed to get, use default value
	return "scrcpy-tsnet-forwarder"
}

// getStateDir gets the state directory to use
func (f *TSNetForwarder) getStateDir() string {
	if f.stateDir != "" {
		return f.stateDir
	}
	return "/tmp/tsnet-forwarder"
}

// startServer starts the tsnet server
func (f *TSNetForwarder) startServer() error {
	if f.isStarted {
		return nil
	}

	tsnetData := f.getStateDir()
	hostname := f.getHostname()

	// First try to reuse existing state if it exists
	stateExists := false
	if _, err := os.Stat(tsnetData); !os.IsNotExist(err) {
		stateExists = true
		log.Printf("Found existing state directory: %s, attempting to reuse", tsnetData)
	}

	f.server = &tsnet.Server{
		Dir:      tsnetData,
		Hostname: hostname,
		AuthKey:  f.authKey,
	}

	if err := f.server.Start(); err != nil {
		// If we have existing state and start failed, try cleaning up and retrying
		if stateExists {
			log.Printf("Failed to start with existing state, cleaning up and retrying: %v", err)
			f.server.Close()
			_ = os.RemoveAll(tsnetData)

			// Retry with clean state
			f.server = &tsnet.Server{
				Dir:      tsnetData,
				Hostname: hostname,
				AuthKey:  f.authKey,
			}

			if err := f.server.Start(); err != nil {
				return fmt.Errorf("failed to start tsnet server after cleanup: %v", err)
			}
		} else {
			return fmt.Errorf("failed to start tsnet server: %v", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	_, err := f.server.Up(ctx)
	if err != nil {
		// If Up failed and we haven't tried cleanup yet, try once more with clean state
		if stateExists {
			log.Printf("Failed to bring up with existing state, cleaning up and retrying: %v", err)
			f.server.Close()
			_ = os.RemoveAll(tsnetData)

			// Retry with clean state
			f.server = &tsnet.Server{
				Dir:      tsnetData,
				Hostname: hostname,
				AuthKey:  f.authKey,
			}

			if err := f.server.Start(); err != nil {
				return fmt.Errorf("failed to start tsnet server after cleanup: %v", err)
			}

			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			_, err := f.server.Up(ctx)
			if err != nil {
				f.server.Close()
				return fmt.Errorf("failed to bring up tsnet server after cleanup: %v", err)
			}
		} else {
			f.server.Close()
			return fmt.Errorf("failed to bring up tsnet server: %v", err)
		}
	}

	f.isStarted = true
	ip4, ip6 := f.server.TailscaleIPs()

	if stateExists {
		log.Printf("TSNet server reused existing state with hostname '%s', state dir '%s' and IPs: %v, %v", hostname, tsnetData, ip4, ip6)
	} else {
		log.Printf("TSNet server started with hostname '%s', state dir '%s' and IPs: %v, %v", hostname, tsnetData, ip4, ip6)
	}

	return nil
}

// stopServer stops the tsnet server
func (f *TSNetForwarder) stopServer() {
	if f.server != nil {
		f.server.Close()
		f.server = nil
	}
	f.isStarted = false
}

// TsnetStartForward starts port forwarding
// TsnetProbe 拨号探测 tailnet 上的目标是否可达（给 App 首页的「Tailscale 灯」用）。
//
// 为什么要真拨一次：一个 tailnet 节点在不在线，本端没有轻量查询接口；
// 真的 Dial 一次（走内置节点的 netstack，用 MagicDNS 名或 100.x 都行）成功/失败
// 才是诚实的判据。拨通即关，不留连接。
func (f *TSNetForwarder) TsnetProbe(remoteAddr string, remotePort int, timeoutMs int) error {
	f.mutex.RLock()
	srv := f.server
	f.mutex.RUnlock()
	if srv == nil {
		return fmt.Errorf("tsnet server not started")
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	conn, err := srv.Dial(ctx, "tcp", net.JoinHostPort(remoteAddr, fmt.Sprintf("%d", remotePort)))
	if err != nil {
		return err
	}
	conn.Close()
	return nil
}

// TsnetPeerPath 查一条 peer 当前**实际走的路径**（给气泡标「直连 / 中转」）：
//
//	"direct ip:port"     —— 打洞成功，走直连
//	"derp <region>"      —— 走 DERP 中继
//	"peer-relay ..."     —— 走 peer relay
//	""                   —— 查不到（没连/没这个节点）
//
// host 支持 MagicDNS 全名（可带尾点）、短名、HostName、或 100.x 地址。
func (f *TSNetForwarder) TsnetPeerPath(host string) string {
	f.mutex.RLock()
	srv := f.server
	f.mutex.RUnlock()
	if srv == nil {
		return ""
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil {
		return ""
	}

	h := strings.ToLower(strings.TrimSuffix(host, "."))
	for _, p := range st.Peer {
		dns := strings.ToLower(strings.TrimSuffix(p.DNSName, "."))
		match := false
		if dns != "" {
			if dns == h {
				match = true
			} else if i := strings.IndexByte(dns, '.'); i > 0 && dns[:i] == h {
				match = true
			}
		}
		if !match && p.HostName != "" && strings.EqualFold(p.HostName, h) {
			match = true
		}
		if !match {
			for _, ip := range p.TailscaleIPs {
				if ip.String() == h {
					match = true
					break
				}
			}
		}
		if !match {
			continue
		}

		if p.CurAddr != "" {
			return "direct " + p.CurAddr
		}
		if p.Relay != "" {
			return "derp " + p.Relay
		}
		if p.PeerRelay != "" {
			return "peer-relay " + p.PeerRelay
		}
		return "unknown"
	}
	return ""
}

func (f *TSNetForwarder) TsnetStartForward(remoteAddr string, remotePort int, localPort int) error {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	// Ensure the server is started
	if err := f.startServer(); err != nil {
		log.Printf("Failed to start server: %v", err)
		if f.callback != nil && f.callback.OnForwardError != nil {
			f.callback.OnForwardError(remoteAddr, remotePort, localPort, err)
		}
		return err
	}

	// Generate unique key
	key := fmt.Sprintf("%s:%d->%d", remoteAddr, remotePort, localPort)

	// Check if already exists
	if _, exists := f.forwards[key]; exists {
		log.Printf("Forward already exists: %s", key)
		return nil
	}

	// Create local listener
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", localPort))
	if err != nil {
		log.Printf("Failed to create listener on port %d: %v", localPort, err)
		if f.callback != nil && f.callback.OnForwardError != nil {
			f.callback.OnForwardError(remoteAddr, remotePort, localPort, err)
		}
		return err
	}

	// Create context for cancellation
	ctx, cancel := context.WithCancel(context.Background())

	// Store forwarding information
	forwardInfo := &ForwardInfo{
		RemoteAddr: remoteAddr,
		RemotePort: remotePort,
		LocalPort:  localPort,
		Listener:   listener,
		Cancel:     cancel,
	}
	f.forwards[key] = forwardInfo

	// Start forwarding goroutine
	go f.handleForward(ctx, forwardInfo)

	log.Printf("Started forward: %s", key)
	if f.callback != nil && f.callback.OnForwardSuccess != nil {
		f.callback.OnForwardSuccess(remoteAddr, remotePort, localPort)
	}

	return nil
}

// handleForward handles port forwarding
func (f *TSNetForwarder) handleForward(ctx context.Context, info *ForwardInfo) {
	defer func() {
		info.Listener.Close()
		f.mutex.Lock()
		key := fmt.Sprintf("%s:%d->%d", info.RemoteAddr, info.RemotePort, info.LocalPort)
		delete(f.forwards, key)
		f.mutex.Unlock()

		if f.callback != nil && f.callback.OnForwardClosed != nil {
			f.callback.OnForwardClosed(info.RemoteAddr, info.RemotePort, info.LocalPort)
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return
		default:
			// Accept local connection
			localConn, err := info.Listener.Accept()
			if err != nil {
				if f.callback != nil && f.callback.OnForwardError != nil {
					f.callback.OnForwardError(info.RemoteAddr, info.RemotePort, info.LocalPort, err)
				}
				return
			}

			// Handle connection
			go f.handleConnection(ctx, localConn, info)
		}
	}
}

// handleConnection handles a single connection
func (f *TSNetForwarder) handleConnection(ctx context.Context, localConn net.Conn, info *ForwardInfo) {
	defer localConn.Close()

	// Connect to remote address through tsnet
	remoteAddr := fmt.Sprintf("%s:%d", info.RemoteAddr, info.RemotePort)
	remoteConn, err := f.server.Dial(ctx, "tcp", remoteAddr)
	if err != nil {
		log.Printf("Failed to connect to remote %s: %v", remoteAddr, err)
		if f.callback != nil && f.callback.OnForwardError != nil {
			f.callback.OnForwardError(info.RemoteAddr, info.RemotePort, info.LocalPort, err)
		}
		return
	}
	defer remoteConn.Close()

	// Bidirectional data forwarding
	done := make(chan struct{}, 2)

	// Local to remote
	go func() {
		defer func() { done <- struct{}{} }()
		io.Copy(remoteConn, localConn)
	}()

	// Remote to local
	go func() {
		defer func() { done <- struct{}{} }()
		io.Copy(localConn, remoteConn)
	}()

	// Wait for either direction to complete or context cancellation
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// TsnetStopForward stops port forwarding
func (f *TSNetForwarder) TsnetStopForward(remoteAddr string, remotePort int, localPort int) int {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	// Find and stop matching forwards
	var toRemove []string
	for key, info := range f.forwards {
		if (remoteAddr == "" || info.RemoteAddr == remoteAddr) &&
			(remotePort == 0 || info.RemotePort == remotePort) &&
			(localPort == 0 || info.LocalPort == localPort) {
			toRemove = append(toRemove, key)
		}
	}

	for _, key := range toRemove {
		if info, exists := f.forwards[key]; exists {
			info.Cancel()
			log.Printf("Stopped forward: %s", key)
		}
	}

	return len(toRemove)
}

// TsnetStopAllForwards stops all port forwarding
func (f *TSNetForwarder) TsnetStopAllForwards() int {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	count := len(f.forwards)
	for key, info := range f.forwards {
		info.Cancel()
		log.Printf("Stopped forward: %s", key)
	}

	return count
}

// TsnetRegisterCallback registers callback functions
func (f *TSNetForwarder) TsnetRegisterCallback(callback *ForwardCallback) {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	f.callback = callback
}

// TsnetRegisterConnectCallback registers connection callback functions
func (f *TSNetForwarder) TsnetRegisterConnectCallback(callback *ConnectCallback) {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	f.connectCallback = callback
}

// TsnetConnect connects to Tailscale network and returns connection information via callback
func (f *TSNetForwarder) TsnetConnect() error {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	// Check if authKey is set
	if f.authKey == "" {
		err := fmt.Errorf("auth key is not set")
		if f.connectCallback != nil && f.connectCallback.OnConnectError != nil {
			f.connectCallback.OnConnectError(f.getHostname(), err)
		}
		return err
	}

	// Check if already started (reuse case)
	wasAlreadyStarted := f.isStarted

	// Start the server (this will connect to Tailscale)
	if err := f.startServer(); err != nil {
		if f.connectCallback != nil && f.connectCallback.OnConnectError != nil {
			f.connectCallback.OnConnectError(f.getHostname(), err)
		}
		return err
	}

	// Get connection information
	hostname := f.getHostname()
	ip4, ip6 := f.server.TailscaleIPs()

	// Generate MagicDNS information (actual format depends on tailnet configuration)
	magicDNS := f.getMagicDNS(hostname)

	var ipv4Str, ipv6Str string
	if ip4.IsValid() {
		ipv4Str = ip4.String()
	}
	if ip6.IsValid() {
		ipv6Str = ip6.String()
	}

	// Call success callback (always call regardless of new or reused connection)
	if f.connectCallback != nil && f.connectCallback.OnConnectSuccess != nil {
		f.connectCallback.OnConnectSuccess(hostname, magicDNS, ipv4Str, ipv6Str)
	}

	// Log success with appropriate message
	if wasAlreadyStarted {
		log.Printf("Reused existing Tailscale connection - Hostname: %s, MagicDNS: %s, IPv4: %s, IPv6: %s",
			hostname, magicDNS, ipv4Str, ipv6Str)
	} else {
		log.Printf("Successfully connected to Tailscale network - Hostname: %s, MagicDNS: %s, IPv4: %s, IPv6: %s",
			hostname, magicDNS, ipv4Str, ipv6Str)
	}

	return nil
}

// TsnetConnectAsync connects to Tailscale network asynchronously
func (f *TSNetForwarder) TsnetConnectAsync() {
	go func() {
		if err := f.TsnetConnect(); err != nil {
			log.Printf("Async connection failed: %v", err)
		}
	}()
}

// getMagicDNS generates the MagicDNS name for the given hostname
func (f *TSNetForwarder) getMagicDNS(hostname string) string {
	// The actual MagicDNS format depends on the tailnet configuration
	// For most tailnets, it follows the pattern: hostname.tailnet-name.ts.net
	// Since we can't easily get the tailnet name, we use a generic format
	// The actual MagicDNS can be different and should be obtained from Tailscale API
	return hostname + ".tail-scale.ts.net"
}

// GetForwards gets all current forwarding information
func (f *TSNetForwarder) GetForwards() map[string]*ForwardInfo {
	f.mutex.RLock()
	defer f.mutex.RUnlock()

	result := make(map[string]*ForwardInfo)
	for k, v := range f.forwards {
		result[k] = v
	}
	return result
}

// IsStarted checks if the server is already started
func (f *TSNetForwarder) IsStarted() bool {
	f.mutex.RLock()
	defer f.mutex.RUnlock()
	return f.isStarted
}

// GetTailscaleIPs gets Tailscale IP addresses
func (f *TSNetForwarder) GetTailscaleIPs() []string {
	f.mutex.RLock()
	defer f.mutex.RUnlock()

	if f.server == nil {
		return nil
	}

	ip4, ip6 := f.server.TailscaleIPs()
	var result []string
	if ip4.IsValid() {
		result = append(result, ip4.String())
	}
	if ip6.IsValid() {
		result = append(result, ip6.String())
	}
	return result
}

// GetHostname gets the currently used hostname
func (f *TSNetForwarder) GetHostname() string {
	f.mutex.RLock()
	defer f.mutex.RUnlock()

	return f.getHostname()
}

// GetStateDir gets the currently used state directory
func (f *TSNetForwarder) GetStateDir() string {
	f.mutex.RLock()
	defer f.mutex.RUnlock()

	return f.getStateDir()
}

// Cleanup cleans up resources
func (f *TSNetForwarder) Cleanup() int {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	count := len(f.forwards)

	// Stop all forwards
	for _, info := range f.forwards {
		info.Cancel()
	}
	f.forwards = make(map[string]*ForwardInfo)

	// Stop server
	f.stopServer()

	return count
}
