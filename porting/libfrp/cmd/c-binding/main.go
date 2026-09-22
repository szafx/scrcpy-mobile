// c-binding —— 把 libfrp 暴露成几个 C 函数，供 iOS（Swift/ObjC）调用。
//
// 编译方式（见 ../Makefile）：
//   CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
//   CC="$(xcrun --sdk iphoneos --find clang)" \
//   go build -tags ios -buildmode=c-archive -o libfrp-forwarder.a ./cmd/c-binding
//
// 产出 .a + .h，塞进 Xcode 工程即可。
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"

import (
	"fmt"
	"unsafe"

	frp "me.wsen.scrcpy-frp/lib"
)

// 保存最后一次错误信息，供 frp_last_error() 取。
var lastError string

//export frp_start_visitor
func frp_start_visitor(
	cServerAddr *C.char,
	serverPort C.int,
	cToken *C.char,
	cStunServer *C.char,
	cBaseDir *C.char,
	localPort C.int,
	cProxyName *C.char,
	cSecretKey *C.char,
	keepTunnelOpen C.int,
) C.int {
	opt := frp.VisitorOptions{
		ServerAddr:     C.GoString(cServerAddr),
		ServerPort:     int(serverPort),
		Token:          C.GoString(cToken),
		StunServer:     C.GoString(cStunServer),
		BaseDir:        C.GoString(cBaseDir),
		LocalPort:      int(localPort),
		ProxyName:      C.GoString(cProxyName),
		SecretKey:      C.GoString(cSecretKey),
		KeepTunnelOpen: keepTunnelOpen != 0,
	}

	fmt.Printf("[libfrp] start visitor: server=%s:%d proxy=%s local=%d stun=%s\n",
		opt.ServerAddr, opt.ServerPort, opt.ProxyName, opt.LocalPort, opt.StunServer)

	if err := frp.StartVisitor(opt); err != nil {
		lastError = err.Error()
		fmt.Printf("[libfrp] ERROR %s\n", lastError)
		return 1
	}
	lastError = ""
	return 0
}

//export frp_stop_visitor
func frp_stop_visitor() {
	fmt.Printf("[libfrp] stop visitor\n")
	frp.StopVisitor()
}

//export frp_status
func frp_status() *C.char {
	return C.CString(frp.Status())
}

//export frp_last_error
func frp_last_error() *C.char {
	return C.CString(lastError)
}

//export frp_free
func frp_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
