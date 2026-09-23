#ifndef TSNET_FORWARDER_H
#define TSNET_FORWARDER_H

#ifdef __cplusplus
extern "C" {
#endif

// Callback function type definitions
typedef void (*forward_success_callback)(char* remote_addr, int remote_port, int local_port);
typedef void (*forward_closed_callback)(char* remote_addr, int remote_port, int local_port);
typedef void (*forward_error_callback)(char* remote_addr, int remote_port, int local_port, char* error_msg);

// API function declarations
extern int update_tsnet_auth_key(char* auth_key);
extern int tsnet_start_forward(char* remote_addr, int remote_port, int local_port);
extern int tsnet_stop_forward(char* remote_addr, int remote_port, int local_port);
extern int tsnet_stop_all_forwards(void);
extern void tsnet_register_callbacks(
    forward_success_callback on_success,
    forward_closed_callback on_closed,
    forward_error_callback on_error
);
extern int tsnet_cleanup(void);
extern int tsnet_is_started(void);
extern char* tsnet_get_tailscale_ips(void);

// Connection management functions
extern int tsnet_update_hostname(char* hostname);
extern int tsnet_update_state_dir(char* state_dir);
extern int tsnet_connect(void);
extern void tsnet_connect_async(void);
extern int tsnet_get_connect_status(void);
extern char* tsnet_get_last_hostname(void);
extern char* tsnet_get_last_magic_dns(void);
extern char* tsnet_get_last_ipv4(void);
extern char* tsnet_get_last_ipv6(void);
extern char* tsnet_get_last_error(void);
extern char* tsnet_get_hostname(void);
extern char* tsnet_get_state_dir(void);

// ============== OAuth API ==============
// OAuth credentials management
extern int oauth_set_credentials(char* client_id, char* client_secret);
extern int oauth_validate_credentials(void);
extern int oauth_is_credentials_set(void);
extern char* oauth_get_client_id(void);
extern void oauth_clear_credentials(void);

// OAuth auth key generation
// tags: comma-separated string like "tag:server,tag:client"
// reusable: 1 for reusable key, 0 for one-time use
// ephemeral: 1 for ephemeral nodes, 0 for persistent
// preauthorized: 1 to skip device approval, 0 to require approval
// expiry_seconds: key expiry in seconds, 0 for default (90 days max)
// description: optional description for the key
extern int oauth_create_auth_key(char* tags, int reusable, int ephemeral, int preauthorized, int expiry_seconds, char* description);

// OAuth status and results
extern int oauth_get_status(void);          // 0: in progress, 1: success, -1: error
extern char* oauth_get_last_auth_key(void); // returns the generated auth key
extern char* oauth_get_last_expires_at(void); // returns the expiration time
extern char* oauth_get_last_error(void);    // returns the last error message
extern void oauth_reset_status(void);       // reset status for new operation

#ifdef __cplusplus
}
#endif

#endif // TSNET_FORWARDER_H 