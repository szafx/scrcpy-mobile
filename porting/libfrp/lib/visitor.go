// Package libfrp —— 把 frp 的 client（visitor 模式）包成一个可以嵌进 iOS App 的库。
//
// 用途：iPhone 侧作为 XTCP 的 visitor，和被控手机上跑的 frpc（XTCP proxy）打洞，
//       打通后走 P2P 直连，打不通自动降级成经 frps 中转。
//
// 设计参考同仓库的 porting/libtsnet（Go + cgo → iOS 静态库）。
//
// 与 libtsnet 的关键区别：
//   - libtsnet 建立的是一个「虚拟网络」，本 App 走它 dial
//   - libfrp  只做「端口转发」：本机监听 localPort，收到的连接经 XTCP 隧道送到对端，
//     所以 App 侧只需要连 127.0.0.1:localPort，跟现在的 adb 用法完全一致
package lib

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	"github.com/fatedier/frp/pkg/config/source"
	"github.com/fatedier/frp/pkg/policy/security"
	"github.com/fatedier/frp/pkg/util/log"
)

// VisitorOptions 描述一条 XTCP 隧道。
type VisitorOptions struct {
	// ServerAddr 是 frps 地址（如 home.szafx.icu）
	ServerAddr string
	// ServerPort 是 frps 端口（默认 7000）
	ServerPort int
	// Token 是 frps 的 auth token
	Token string
	// StunServer 是打洞用的 STUN 服务器。
	// ★★ 国内必须填，默认那个 stun.easyvoip.com 连不上，打洞会死在第一步。
	//    实测可用：stun.miwifi.com:3478
	StunServer string

	// BaseDir 放配置和状态文件（App 沙盒目录）
	BaseDir string

	// LocalPort 本机监听的端口（App 连 127.0.0.1:LocalPort 即可）
	LocalPort int
	// ProxyName 对应被控端 frpc 里 [[proxies]] 的 name
	ProxyName string
	// SecretKey 对应被控端 frpc 里那个 proxy 的 secretKey
	SecretKey string
	// KeepTunnelOpen 是否一直保持打洞（true 时即使没连接也维持 P2P）
	KeepTunnelOpen bool

	// LogLevel 默认 info
	LogLevel string
}

// Visitor 是一条正在运行的 visitor。
type Visitor struct {
	mu      sync.Mutex
	svc     *client.Service
	cancel  context.CancelFunc
	running bool
	lastErr string
}

var (
	globalMu sync.Mutex
	global   *Visitor
)

// genConfigTOML 用最朴素的方式拼 TOML —— 字段都是我们自己控制的，
// 值里不可能出现需要转义的特殊字符（地址/端口/名字都是受限字符集）。
func (o *VisitorOptions) genConfigTOML() string {
	logLevel := o.LogLevel
	if logLevel == "" {
		logLevel = "info"
	}
	stun := o.StunServer
	if stun == "" {
		stun = "stun.miwifi.com:3478"
	}
	return fmt.Sprintf(`serverAddr = %q
serverPort = %d
natHoleStunServer = %q
loginFailExit = false

auth.method = "token"
auth.token = %q

transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

log.to = %q
log.level = %q

[[visitors]]
name = %q
type = "xtcp"
serverName = %q
secretKey = %q
bindAddr = "127.0.0.1"
bindPort = %d
keepTunnelOpen = %v
`,
		o.ServerAddr, o.ServerPort, stun,
		o.Token,
		filepath.Join(o.BaseDir, "frpc_visitor.log"), logLevel,
		"visitor-"+o.ProxyName, o.ProxyName, o.SecretKey,
		o.LocalPort, o.KeepTunnelOpen)
}

// StartVisitor 启动一条 XTCP visitor 隧道。
// 返回后 App 就可以连 127.0.0.1:LocalPort 了（隧道在后台异步建立）。
func StartVisitor(opt VisitorOptions) error {
	globalMu.Lock()
	defer globalMu.Unlock()

	// 同一时刻只跑一条
	if global != nil && global.IsRunning() {
		global.Stop()
	}

	if opt.BaseDir == "" {
		return fmt.Errorf("BaseDir 不能为空")
	}
	if err := os.MkdirAll(opt.BaseDir, 0o700); err != nil {
		return fmt.Errorf("建目录失败: %w", err)
	}

	cfgPath := filepath.Join(opt.BaseDir, "frpc_visitor.toml")
	if err := os.WriteFile(cfgPath, []byte(opt.genConfigTOML()), 0o600); err != nil {
		return fmt.Errorf("写配置失败: %w", err)
	}

	log.InitLogger(filepath.Join(opt.BaseDir, "frpc_visitor.log"), opt.LogLevel, 3, true)

	result, err := config.LoadClientConfigResult(cfgPath, false)
	if err != nil {
		return fmt.Errorf("解析配置失败: %w", err)
	}

	configSource := source.NewConfigSource()
	if err := configSource.ReplaceAll(result.Proxies, result.Visitors); err != nil {
		return fmt.Errorf("装载 visitor 配置失败: %w", err)
	}
	aggregator := source.NewAggregator(configSource)

	unsafeFeatures := security.NewUnsafeFeatures(nil)
	svc, err := client.NewService(client.ServiceOptions{
		Common:                 result.Common,
		ConfigSourceAggregator: aggregator,
		UnsafeFeatures:         unsafeFeatures,
		ConfigFilePath:         cfgPath,
	})
	if err != nil {
		return fmt.Errorf("创建 frpc 服务失败: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	v := &Visitor{svc: svc, cancel: cancel, running: true}
	global = v

	go func() {
		err := svc.Run(ctx)
		v.mu.Lock()
		v.running = false
		if err != nil {
			v.lastErr = err.Error()
		}
		v.mu.Unlock()
	}()

	return nil
}

// StopVisitor 停掉当前隧道。
func StopVisitor() {
	globalMu.Lock()
	defer globalMu.Unlock()
	if global != nil {
		global.Stop()
		global = nil
	}
}

// IsRunning 隧道是否还在跑。
func (v *Visitor) IsRunning() bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.running
}

// Stop 停止这条隧道（给 ctx 一个取消机会，再关服务）。
func (v *Visitor) Stop() {
	v.mu.Lock()
	if !v.running {
		v.mu.Unlock()
		return
	}
	v.running = false
	v.mu.Unlock()

	if v.cancel != nil {
		v.cancel()
	}
	if v.svc != nil {
		go func() {
			time.Sleep(200 * time.Millisecond)
			v.svc.Close()
		}()
	}
}

// Status 返回一句人类可读的状态，给 App 打日志用。
func Status() string {
	globalMu.Lock()
	v := global
	globalMu.Unlock()
	if v == nil {
		return "not started"
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.running {
		return "running"
	}
	if v.lastErr != "" {
		return "stopped: " + v.lastErr
	}
	return "stopped"
}
