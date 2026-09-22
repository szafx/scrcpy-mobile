# Makefile for libfrp
#
# 把 frp 的 client（visitor 模式）编译成 iOS 静态库，供 Scrcpy Remote 内嵌。
# 用法和 porting/libtsnet 一致，目标是产出：
#   build/iphoneos/arm64/libfrp-forwarder.a
#   build/include/libfrp-forwarder.h

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
		-o build/iphoneos/arm64/libfrp-forwarder.a ./cmd/c-binding
	@cp build/iphoneos/arm64/libfrp-forwarder.h build/include/
	@ls -lh build/iphoneos/arm64/libfrp-forwarder.a

# iOS 模拟器（Apple Silicon Mac）
build-iphonesimulator-arm64:
	@echo "==> 编译 iOS 模拟器 ARM64 静态库..."
	@mkdir -p build/iphonesimulator/arm64 build/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC="$(shell xcrun --sdk iphonesimulator --find clang)" \
	CGO_CFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -mios-simulator-version-min=13.0" \
	CGO_LDFLAGS="-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path)" \
	go build -tags ios -buildmode=c-archive \
		-o build/iphonesimulator/arm64/libfrp-forwarder.a ./cmd/c-binding
	@cp build/iphonesimulator/arm64/libfrp-forwarder.h build/include/

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
