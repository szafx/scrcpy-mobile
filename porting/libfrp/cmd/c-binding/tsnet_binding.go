// tsnet_binding.go —— 从 porting/libtsnet 合并过来的 c-binding。
//
// ★ 为什么会有这个文件（别删、别拆回去）：
//   libtsnet 和 libfrp 原本是两个独立的 Go c-archive，**各自带一整套 Go runtime**。
//   链接进同一个 App 后重名符号被去重、两套 Go 代码共用一套 runtime 状态，
//   一旦调用第二个库就崩。所以必须合并成**一个** c-archive —— 一个进程一个 Go runtime。
//
// 本文件与 main.go 同属 package main，一起编出 libmobile-forwarder.a。

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"log"
	"strings"
	"time"

	forwarder "me.wsen.scrcpy-frp/libtsnet"
)

var tsnetForwarder *forwarder.TSNetForwarder

// Global variables to store connection info for C callbacks
var (
	lastHostname  string
	lastMagicDNS  string
	lastIPv4      string
	lastIPv6      string
	tsnetLastError     string
	connectStatus int // 0: none, 1: success, -1: error

	// Test variables to track IP changes
	firstConnectionIPs  []string
	secondConnectionIPs []string

	// OAuth variables
	oauthClient        *forwarder.OAuthClient
	oauthLastAuthKey   string
	oauthLastExpiresAt string
	oauthLastError     string
	oauthStatus        int // 0: none, 1: success, -1: error
)

func init() {
	tsnetForwarder = forwarder.GetInstance()
	oauthClient = forwarder.GetOAuthInstance()

	// Register OAuth callback
	oauthCallback := &forwarder.OAuthCallback{
		OnTokenSuccess: func(token *forwarder.OAuthToken) {
			log.Printf("OAuth Token Success: type=%s, expires_in=%d", token.TokenType, token.ExpiresIn)
		},
		OnTokenError: func(err error) {
			log.Printf("OAuth Token Error: %v", err)
			oauthLastError = err.Error()
			oauthStatus = -1
		},
		OnAuthKeySuccess: func(authKey, expiresAt string) {
			log.Printf("OAuth Auth Key Success: key=%s..., expires=%s", truncateForLog(authKey, 20), expiresAt)
			oauthLastAuthKey = authKey
			oauthLastExpiresAt = expiresAt
			oauthStatus = 1
		},
		OnAuthKeyError: func(err error) {
			log.Printf("OAuth Auth Key Error: %v", err)
			oauthLastError = err.Error()
			oauthStatus = -1
		},
	}
	oauthClient.RegisterOAuthCallback(oauthCallback)

	// Register connect callback
	connectCallback := &forwarder.ConnectCallback{
		OnConnectSuccess: func(hostname, magicDNS, ipv4, ipv6 string) {
			log.Printf("Connect Success: hostname=%s, magicDNS=%s, ipv4=%s, ipv6=%s", hostname, magicDNS, ipv4, ipv6)
			lastHostname = hostname
			lastMagicDNS = magicDNS
			lastIPv4 = ipv4
			lastIPv6 = ipv6
			connectStatus = 1
		},
		OnConnectError: func(hostname string, err error) {
			log.Printf("Connect Error: hostname=%s, error=%v", hostname, err)
			lastHostname = hostname
			tsnetLastError = err.Error()
			connectStatus = -1
		},
	}
	tsnetForwarder.TsnetRegisterConnectCallback(connectCallback)
}

// update_tsnet_auth_key sets the tsnet authentication key
//
//export update_tsnet_auth_key
func update_tsnet_auth_key(authKey *C.char) C.int {
	key := C.GoString(authKey)
	if err := tsnetForwarder.UpdateTsnetAuthKey(key); err != nil {
		return -1
	}
	return 0
}

// tsnet_update_hostname sets the tsnet client hostname
//
//export tsnet_update_hostname
func tsnet_update_hostname(hostname *C.char) C.int {
	host := C.GoString(hostname)
	if err := tsnetForwarder.TsnetUpdateHostname(host); err != nil {
		return -1
	}
	return 0
}

// tsnet_update_state_dir sets the tsnet state directory
//
//export tsnet_update_state_dir
func tsnet_update_state_dir(stateDir *C.char) C.int {
	dir := C.GoString(stateDir)
	if err := tsnetForwarder.TsnetUpdateStateDir(dir); err != nil {
		return -1
	}
	return 0
}

// tsnet_connect connects to Tailscale network
//
//export tsnet_connect
func tsnet_connect() C.int {
	connectStatus = 0
	if err := tsnetForwarder.TsnetConnect(); err != nil {
		return -1
	}
	return 0
}

// tsnet_connect_async connects to Tailscale network asynchronously
//
//export tsnet_connect_async
func tsnet_connect_async() {
	connectStatus = 0
	tsnetForwarder.TsnetConnectAsync()
}

// tsnet_get_connect_status gets the connection status
//
//export tsnet_get_connect_status
func tsnet_get_connect_status() C.int {
	return C.int(connectStatus)
}

// tsnet_get_last_hostname gets the last connected hostname
//
//export tsnet_get_last_hostname
func tsnet_get_last_hostname() *C.char {
	return C.CString(lastHostname)
}

// tsnet_get_last_magic_dns gets the last connected MagicDNS
//
//export tsnet_get_last_magic_dns
func tsnet_get_last_magic_dns() *C.char {
	return C.CString(lastMagicDNS)
}

// tsnet_get_last_ipv4 gets the last connected IPv4
//
//export tsnet_get_last_ipv4
func tsnet_get_last_ipv4() *C.char {
	return C.CString(lastIPv4)
}

// tsnet_get_last_ipv6 gets the last connected IPv6
//
//export tsnet_get_last_ipv6
func tsnet_get_last_ipv6() *C.char {
	return C.CString(lastIPv6)
}

// tsnet_get_last_error gets the last connection error
//
//export tsnet_get_last_error
func tsnet_get_last_error() *C.char {
	return C.CString(tsnetLastError)
}

// tsnet_start_forward starts port forwarding
//
//export tsnet_start_forward
func tsnet_start_forward(remoteAddr *C.char, remotePort C.int, localPort C.int) C.int {
	addr := C.GoString(remoteAddr)
	rPort := int(remotePort)
	lPort := int(localPort)

	if err := tsnetForwarder.TsnetStartForward(addr, rPort, lPort); err != nil {
		return -1
	}
	return 0
}

// tsnet_stop_forward stops port forwarding
//
//export tsnet_stop_forward
func tsnet_stop_forward(remoteAddr *C.char, remotePort C.int, localPort C.int) C.int {
	addr := C.GoString(remoteAddr)
	rPort := int(remotePort)
	lPort := int(localPort)

	count := tsnetForwarder.TsnetStopForward(addr, rPort, lPort)
	return C.int(count)
}

// tsnet_stop_all_forwards stops all port forwarding
//
//export tsnet_stop_all_forwards
func tsnet_stop_all_forwards() C.int {
	count := tsnetForwarder.TsnetStopAllForwards()
	return C.int(count)
}

// tsnet_cleanup cleans up resources
//
//export tsnet_cleanup
func tsnet_cleanup() C.int {
	count := tsnetForwarder.Cleanup()
	return C.int(count)
}

// tsnet_is_started checks if the server is already started
//
//export tsnet_is_started
func tsnet_is_started() C.int {
	if tsnetForwarder.IsStarted() {
		return 1
	}
	return 0
}

// tsnet_get_tailscale_ips gets Tailscale IP addresses (returns the first IP)
//
//export tsnet_get_tailscale_ips
func tsnet_get_tailscale_ips() *C.char {
	ips := tsnetForwarder.GetTailscaleIPs()
	if len(ips) > 0 {
		return C.CString(ips[0])
	}
	return C.CString("")
}

// tsnet_get_hostname gets the currently used hostname
//
//export tsnet_get_hostname
func tsnet_get_hostname() *C.char {
	hostname := tsnetForwarder.GetHostname()
	return C.CString(hostname)
}

// tsnet_get_state_dir gets the currently used state directory
//
//export tsnet_get_state_dir
func tsnet_get_state_dir() *C.char {
	stateDir := tsnetForwarder.GetStateDir()
	return C.CString(stateDir)
}

// tsnet_test_ip_reuse_consistency tests if IP addresses remain consistent when reusing state
//
//export tsnet_test_ip_reuse_consistency
func tsnet_test_ip_reuse_consistency(authKey *C.char, hostname *C.char, stateDir *C.char) C.int {
	log.Printf("=== Starting IP Reuse Consistency Test ===")

	// Setup configuration
	key := C.GoString(authKey)
	host := C.GoString(hostname)
	dir := C.GoString(stateDir)

	if err := tsnetForwarder.UpdateTsnetAuthKey(key); err != nil {
		log.Printf("Failed to set auth key: %v", err)
		return -1
	}

	if err := tsnetForwarder.TsnetUpdateHostname(host); err != nil {
		log.Printf("Failed to set hostname: %v", err)
		return -1
	}

	if err := tsnetForwarder.TsnetUpdateStateDir(dir); err != nil {
		log.Printf("Failed to set state dir: %v", err)
		return -1
	}

	// First connection
	log.Printf("--- First Connection ---")
	connectStatus = 0
	if err := tsnetForwarder.TsnetConnect(); err != nil {
		log.Printf("First connection failed: %v", err)
		return -1
	}

	// Wait for connection to complete
	for i := 0; i < 30; i++ {
		if connectStatus != 0 {
			break
		}
		time.Sleep(1 * time.Second)
	}

	if connectStatus != 1 {
		log.Printf("First connection did not succeed within timeout")
		return -1
	}

	// Record first connection IPs
	firstConnectionIPs = tsnetForwarder.GetTailscaleIPs()
	log.Printf("First connection IPs: %v", firstConnectionIPs)

	// Cleanup (this should preserve state directory)
	log.Printf("--- Cleaning up for reconnection test ---")
	cleanupCount := tsnetForwarder.Cleanup()
	log.Printf("Cleanup stopped %d forwards", cleanupCount)

	// Wait a moment before reconnecting
	time.Sleep(2 * time.Second)

	// Second connection (should reuse state)
	log.Printf("--- Second Connection (State Reuse Test) ---")
	connectStatus = 0
	if err := tsnetForwarder.TsnetConnect(); err != nil {
		log.Printf("Second connection failed: %v", err)
		return -1
	}

	// Wait for second connection to complete
	for i := 0; i < 30; i++ {
		if connectStatus != 0 {
			break
		}
		time.Sleep(1 * time.Second)
	}

	if connectStatus != 1 {
		log.Printf("Second connection did not succeed within timeout")
		return -1
	}

	// Record second connection IPs
	secondConnectionIPs = tsnetForwarder.GetTailscaleIPs()
	log.Printf("Second connection IPs: %v", secondConnectionIPs)

	// Compare IPs
	log.Printf("--- IP Comparison Results ---")
	if len(firstConnectionIPs) != len(secondConnectionIPs) {
		log.Printf("❌ DIFFERENT: IP count changed from %d to %d", len(firstConnectionIPs), len(secondConnectionIPs))
		return -1
	}

	identical := true
	for i, ip1 := range firstConnectionIPs {
		if i < len(secondConnectionIPs) {
			ip2 := secondConnectionIPs[i]
			if ip1 == ip2 {
				log.Printf("✅ SAME: IP[%d] = %s", i, ip1)
			} else {
				log.Printf("❌ DIFFERENT: IP[%d] changed from %s to %s", i, ip1, ip2)
				identical = false
			}
		}
	}

	if identical {
		log.Printf("🎉 SUCCESS: All IP addresses remained consistent after state reuse!")
		return 1
	} else {
		log.Printf("⚠️  WARNING: IP addresses changed after reconnection")
		return 0
	}
}

// tsnet_get_first_connection_ips gets the first connection IP addresses for comparison
//
//export tsnet_get_first_connection_ips
func tsnet_get_first_connection_ips() *C.char {
	if len(firstConnectionIPs) > 0 {
		return C.CString(firstConnectionIPs[0])
	}
	return C.CString("")
}

// tsnet_get_second_connection_ips gets the second connection IP addresses for comparison
//
//export tsnet_get_second_connection_ips
func tsnet_get_second_connection_ips() *C.char {
	if len(secondConnectionIPs) > 0 {
		return C.CString(secondConnectionIPs[0])
	}
	return C.CString("")
}

// Helper function to truncate string for logging
func truncateForLog(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen]
}

// ============== OAuth C Bindings ==============

// oauth_set_credentials sets the OAuth client credentials
//
//export oauth_set_credentials
func oauth_set_credentials(clientID *C.char, clientSecret *C.char) C.int {
	id := C.GoString(clientID)
	secret := C.GoString(clientSecret)

	if id == "" || secret == "" {
		return -1
	}

	oauthClient.SetOAuthCredentials(id, secret)
	return 0
}

// oauth_validate_credentials validates the OAuth credentials by attempting to get a token
//
//export oauth_validate_credentials
func oauth_validate_credentials() C.int {
	oauthStatus = 0
	oauthLastError = ""

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		err := oauthClient.ValidateCredentials(ctx)
		if err != nil {
			oauthLastError = err.Error()
			oauthStatus = -1
		} else {
			oauthStatus = 1
		}
	}()

	return 0
}

// oauth_create_auth_key creates an auth key using OAuth
// tags should be a comma-separated string like "tag:server,tag:client"
//
//export oauth_create_auth_key
func oauth_create_auth_key(tags *C.char, reusable C.int, ephemeral C.int, preauthorized C.int, expirySeconds C.int, description *C.char) C.int {
	oauthStatus = 0
	oauthLastError = ""
	oauthLastAuthKey = ""
	oauthLastExpiresAt = ""

	tagsStr := C.GoString(tags)
	descStr := C.GoString(description)

	// Parse comma-separated tags
	var tagList []string
	if tagsStr != "" {
		for _, tag := range strings.Split(tagsStr, ",") {
			tag = strings.TrimSpace(tag)
			if tag != "" {
				tagList = append(tagList, tag)
			}
		}
	}

	if len(tagList) == 0 {
		oauthLastError = "at least one tag is required for OAuth auth key creation"
		oauthStatus = -1
		return -1
	}

	oauthClient.CreateAuthKeyAsync(
		tagList,
		reusable != 0,
		ephemeral != 0,
		preauthorized != 0,
		int(expirySeconds),
		descStr,
	)

	return 0
}

// oauth_get_status gets the OAuth operation status
// Returns: 0 = in progress, 1 = success, -1 = error
//
//export oauth_get_status
func oauth_get_status() C.int {
	return C.int(oauthStatus)
}

// oauth_get_last_auth_key gets the last generated auth key
//
//export oauth_get_last_auth_key
func oauth_get_last_auth_key() *C.char {
	return C.CString(oauthLastAuthKey)
}

// oauth_get_last_expires_at gets the expiration time of the last generated auth key
//
//export oauth_get_last_expires_at
func oauth_get_last_expires_at() *C.char {
	return C.CString(oauthLastExpiresAt)
}

// oauth_get_last_error gets the last OAuth error message
//
//export oauth_get_last_error
func oauth_get_last_error() *C.char {
	return C.CString(oauthLastError)
}

// oauth_is_credentials_set checks if OAuth credentials are configured
//
//export oauth_is_credentials_set
func oauth_is_credentials_set() C.int {
	if oauthClient.IsCredentialsSet() {
		return 1
	}
	return 0
}

// oauth_get_client_id gets the configured OAuth client ID (for display)
//
//export oauth_get_client_id
func oauth_get_client_id() *C.char {
	return C.CString(oauthClient.GetClientID())
}

// oauth_clear_credentials clears OAuth credentials
//
//export oauth_clear_credentials
func oauth_clear_credentials() {
	oauthClient.ClearCredentials()
	oauthLastAuthKey = ""
	oauthLastExpiresAt = ""
	oauthLastError = ""
	oauthStatus = 0
}

// oauth_reset_status resets the OAuth status to allow new operations
//
//export oauth_reset_status
func oauth_reset_status() {
	oauthStatus = 0
	oauthLastError = ""
}

// main function is required

