# Makefile for libmobile
#
# 把两个 Go 库编成**一个** iOS 静态库，供 Scrcpy Remote 内嵌：
#   - frp 的 client（visitor 模式）—— 和手机的 frpc 打 XTCP 洞
#   - tailscale 的 tsnet —— 兜底路径
#
# ★★ 为什么必须是**一个**库（别拆回两个）：
#   Go 的 `-buildmode=c-archive` **每个库自带一整套 Go runtime**
#   （调度器/GC/TLS/信号处理）。两个这样的库链接进同一个 App，
#   重名符号会被去重 → 两套 Go 代码共用一套 runtime 状态 → 一调用就崩。
#   实测铁证：App 二进制里 `\xff Go buildinf:`（Go 运行时指纹）出现过 2 次。
#
# 产出：
#   build/iphoneos/arm64/libmobile-forwarder.a
#   build/include/libmobile-forwarder.h

.PHONY: all clean deps build-iphoneos-arm64 build-iphonesimulator-arm64 \
        build-ios-all build-ios-universal help

# 默认只编真机 arm64（TrollStore/Sideloadly 装机用不到模拟器切片）
all: deps build-iphoneos-arm64

# 拉依赖、生成 go.sum。
# ★ 注意：本仓库里 libtsnet 只有 go.sum 没有 go.mod，go build 会直接失败；
#   这里我们两个都提交，避免踩同一个坑。
deps:
	@echo "==> 拉取依赖..."
	go mod tidy

# iPhone 真机（ARM64）
build-iphoneos-arm64:
	@echo "==> 编译 iOS 真机 ARM64 静态库..."
	@mkdir -p build/iphoneos/arm64 build/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC="$(shell xcrun --sdk iphoneos --find clang)" \
	CGO_CFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -mios-version-min=13.0" \
	CGO_LDFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path)" \
	go build -tags ios -buildmode=c-archive \
		-o build/iphoneos/arm64/libmobile-forwarder.a ./cmd/c-binding
	@cp build/iphoneos/arm64/libmobile-forwarder.h build/include/
	@ls -lh build/iphoneos/arm64/libmobile-forwarder.a

# iOS 模拟器（Apple Silicon Mac）
build-iphonesimulator-arm64:
	@echo "==> 编译 iOS 模拟器 ARM64 静态库..."
	@mkdir -p build/iphonesimulator/arm64 build/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC="$(shell xcrun --sdk iphonesimulator --find clang)" \
	CGO_CFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -mios-simulator-version-min=13.0" \
	CGO_LDFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path)" \
	go build -tags ios -buildmode=c-archive \
		-o build/iphonesimulator/arm64/libmobile-forwarder.a ./cmd/c-binding
	@cp build/iphonesimulator/arm64/libmobile-forwarder.h build/include/

build-ios-all: build-iphoneos-arm64 build-iphonesimulator-arm64

clean:
	rm -rf build/

help:
	@echo "  all                          - 拉依赖 + 编译真机 arm64（默认）"
	@echo "  deps                         - go mod tidy"
	@echo "  build-iphoneos-arm64         - 真机 arm64 静态库"
	@echo "  build-iphonesimulator-arm64  - 模拟器 arm64 静态库"
	@echo "  build-ios-all                - 两个都编"
	@echo "  clean                        - 清理"
