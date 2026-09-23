package libtsnet_forwarder

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// OAuthConfig holds the OAuth client configuration
type OAuthConfig struct {
	ClientID     string
	ClientSecret string
	TokenURL     string
}

// OAuthToken represents an OAuth access token response
type OAuthToken struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
	Scope       string `json:"scope"`
}

// AuthKeyRequest represents the request body for creating an auth key
type AuthKeyRequest struct {
	Capabilities  AuthKeyCapabilities `json:"capabilities"`
	ExpirySeconds int                 `json:"expirySeconds,omitempty"`
	Description   string              `json:"description,omitempty"`
}

// AuthKeyCapabilities defines the capabilities for an auth key
type AuthKeyCapabilities struct {
	Devices DeviceCapabilities `json:"devices"`
}

// DeviceCapabilities defines device-related capabilities
type DeviceCapabilities struct {
	Create DeviceCreateCapabilities `json:"create"`
}

// DeviceCreateCapabilities defines the create capabilities for devices
type DeviceCreateCapabilities struct {
	Reusable      bool     `json:"reusable"`
	Ephemeral     bool     `json:"ephemeral"`
	Preauthorized bool     `json:"preauthorized"`
	Tags          []string `json:"tags"`
}

// AuthKeyResponse represents the response from creating an auth key
type AuthKeyResponse struct {
	ID           string              `json:"id"`
	Key          string              `json:"key"`
	Created      string              `json:"created"`
	Expires      string              `json:"expires"`
	Revoked      string              `json:"revoked,omitempty"`
	Capabilities AuthKeyCapabilities `json:"capabilities"`
	Description  string              `json:"description,omitempty"`
}

// OAuthClient handles OAuth operations for Tailscale
type OAuthClient struct {
	config      *OAuthConfig
	token       *OAuthToken
	tokenExpiry time.Time
	mutex       sync.RWMutex
	httpClient  *http.Client
}

// OAuthCallback defines callback functions for OAuth operations
type OAuthCallback struct {
	OnTokenSuccess   func(token *OAuthToken)
	OnTokenError     func(err error)
	OnAuthKeySuccess func(authKey string, expiresAt string)
	OnAuthKeyError   func(err error)
}

var (
	globalOAuthClient   *OAuthClient
	oauthInitOnce       sync.Once
	globalOAuthCallback *OAuthCallback
)

// GetOAuthInstance returns the global OAuth client singleton
func GetOAuthInstance() *OAuthClient {
	oauthInitOnce.Do(func() {
		globalOAuthClient = &OAuthClient{
			config: &OAuthConfig{
				TokenURL: "https://api.tailscale.com/api/v2/oauth/token",
			},
			httpClient: &http.Client{
				Timeout: 30 * time.Second,
			},
		}
	})
	return globalOAuthClient
}

// SetOAuthCredentials sets the OAuth client credentials
func (c *OAuthClient) SetOAuthCredentials(clientID, clientSecret string) {
	c.mutex.Lock()
	defer c.mutex.Unlock()

	c.config.ClientID = clientID
	c.config.ClientSecret = clientSecret
	// Clear existing token when credentials change
	c.token = nil
	c.tokenExpiry = time.Time{}

	log.Printf("[OAuth] Credentials set - ClientID: %s...", truncateString(clientID, 10))
}

// RegisterOAuthCallback registers callback functions for OAuth operations
func (c *OAuthClient) RegisterOAuthCallback(callback *OAuthCallback) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	globalOAuthCallback = callback
}

// GetAccessToken retrieves a valid access token, refreshing if necessary
func (c *OAuthClient) GetAccessToken(ctx context.Context) (*OAuthToken, error) {
	c.mutex.Lock()
	defer c.mutex.Unlock()

	// Check if we have a valid token
	if c.token != nil && time.Now().Before(c.tokenExpiry.Add(-5*time.Minute)) {
		return c.token, nil
	}

	// Request new token
	token, err := c.requestToken(ctx)
	if err != nil {
		if globalOAuthCallback != nil && globalOAuthCallback.OnTokenError != nil {
			globalOAuthCallback.OnTokenError(err)
		}
		return nil, err
	}

	c.token = token
	c.tokenExpiry = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second)

	if globalOAuthCallback != nil && globalOAuthCallback.OnTokenSuccess != nil {
		globalOAuthCallback.OnTokenSuccess(token)
	}

	return token, nil
}

// requestToken makes the actual token request to Tailscale OAuth endpoint
func (c *OAuthClient) requestToken(ctx context.Context) (*OAuthToken, error) {
	if c.config.ClientID == "" || c.config.ClientSecret == "" {
		return nil, fmt.Errorf("OAuth credentials not set")
	}

	data := url.Values{}
	data.Set("client_id", c.config.ClientID)
	data.Set("client_secret", c.config.ClientSecret)

	req, err := http.NewRequestWithContext(ctx, "POST", c.config.TokenURL, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, fmt.Errorf("failed to create token request: %w", err)
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to request token: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read token response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("token request failed with status %d: %s", resp.StatusCode, string(body))
	}

	var token OAuthToken
	if err := json.Unmarshal(body, &token); err != nil {
		return nil, fmt.Errorf("failed to parse token response: %w", err)
	}

	log.Printf("[OAuth] Token obtained successfully - Type: %s, ExpiresIn: %d, Scope: %s",
		token.TokenType, token.ExpiresIn, token.Scope)

	return &token, nil
}

// CreateAuthKey creates a new auth key using the OAuth token
func (c *OAuthClient) CreateAuthKey(ctx context.Context, tags []string, reusable, ephemeral, preauthorized bool, expirySeconds int, description string) (*AuthKeyResponse, error) {
	// Get access token first
	token, err := c.GetAccessToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get access token: %w", err)
	}

	// Prepare auth key request
	authKeyReq := AuthKeyRequest{
		Capabilities: AuthKeyCapabilities{
			Devices: DeviceCapabilities{
				Create: DeviceCreateCapabilities{
					Reusable:      reusable,
					Ephemeral:     ephemeral,
					Preauthorized: preauthorized,
					Tags:          tags,
				},
			},
		},
		Description: description,
	}

	if expirySeconds > 0 {
		authKeyReq.ExpirySeconds = expirySeconds
	}

	reqBody, err := json.Marshal(authKeyReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal auth key request: %w", err)
	}

	log.Printf("[OAuth] Creating auth key with tags: %v, reusable: %v, ephemeral: %v, preauthorized: %v",
		tags, reusable, ephemeral, preauthorized)

	// Create auth key via API
	apiURL := "https://api.tailscale.com/api/v2/tailnet/-/keys"
	req, err := http.NewRequestWithContext(ctx, "POST", apiURL, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create auth key request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", token.AccessToken))

	resp, err := c.httpClient.Do(req)
	if err != nil {
		if globalOAuthCallback != nil && globalOAuthCallback.OnAuthKeyError != nil {
			globalOAuthCallback.OnAuthKeyError(err)
		}
		return nil, fmt.Errorf("failed to create auth key: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read auth key response: %w", err)
	}

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		err := fmt.Errorf("auth key creation failed with status %d: %s", resp.StatusCode, string(body))
		if globalOAuthCallback != nil && globalOAuthCallback.OnAuthKeyError != nil {
			globalOAuthCallback.OnAuthKeyError(err)
		}
		return nil, err
	}

	var authKeyResp AuthKeyResponse
	if err := json.Unmarshal(body, &authKeyResp); err != nil {
		return nil, fmt.Errorf("failed to parse auth key response: %w", err)
	}

	log.Printf("[OAuth] Auth key created successfully - ID: %s, Expires: %s", authKeyResp.ID, authKeyResp.Expires)

	if globalOAuthCallback != nil && globalOAuthCallback.OnAuthKeySuccess != nil {
		globalOAuthCallback.OnAuthKeySuccess(authKeyResp.Key, authKeyResp.Expires)
	}

	return &authKeyResp, nil
}

// CreateAuthKeyAsync creates an auth key asynchronously
func (c *OAuthClient) CreateAuthKeyAsync(tags []string, reusable, ephemeral, preauthorized bool, expirySeconds int, description string) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		_, err := c.CreateAuthKey(ctx, tags, reusable, ephemeral, preauthorized, expirySeconds, description)
		if err != nil {
			log.Printf("[OAuth] Async auth key creation failed: %v", err)
		}
	}()
}

// ValidateCredentials validates the OAuth credentials by attempting to get a token
func (c *OAuthClient) ValidateCredentials(ctx context.Context) error {
	c.mutex.Lock()
	// Clear existing token to force a new request
	c.token = nil
	c.tokenExpiry = time.Time{}
	c.mutex.Unlock()

	_, err := c.GetAccessToken(ctx)
	return err
}

// GetCurrentToken returns the current cached token info (for display purposes)
func (c *OAuthClient) GetCurrentToken() (*OAuthToken, time.Time) {
	c.mutex.RLock()
	defer c.mutex.RUnlock()
	return c.token, c.tokenExpiry
}

// IsCredentialsSet checks if OAuth credentials are configured
func (c *OAuthClient) IsCredentialsSet() bool {
	c.mutex.RLock()
	defer c.mutex.RUnlock()
	return c.config.ClientID != "" && c.config.ClientSecret != ""
}

// GetClientID returns the configured client ID (for display)
func (c *OAuthClient) GetClientID() string {
	c.mutex.RLock()
	defer c.mutex.RUnlock()
	return c.config.ClientID
}

// ClearCredentials clears OAuth credentials and token
func (c *OAuthClient) ClearCredentials() {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.config.ClientID = ""
	c.config.ClientSecret = ""
	c.token = nil
	c.tokenExpiry = time.Time{}
	log.Printf("[OAuth] Credentials cleared")
}

// Helper function to truncate string for logging
func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
