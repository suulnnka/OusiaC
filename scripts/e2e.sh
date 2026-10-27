#!/usr/bin/env bash
# 端到端测试:zcc 编译示例 → 打进 ZOS initrd → QEMU 启动运行 → 校验输出
#
# 用法: ./scripts/e2e.sh          # 完整流程(构建 zcc + os + iso + qemu)
#       ./scripts/e2e.sh --fast   # 跳过 zcc/os 重建,只重打 iso + qemu
set -euo pipefail
cd "$(dirname "$0")/.."

OS_ROOT=${ZCC_OS_ROOT:-../os}
FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

# 1) 构建 zcc
if [[ $FAST == 0 ]]; then
    echo "== 构建 zcc =="
    zig build
fi

# 2) 确保 ZOS(内核 + libzos.a)已构建
if [[ $FAST == 0 ]]; then
    echo "== 构建 ZOS =="
    (cd "$OS_ROOT" && zig build)
fi

# 3) 用 zcc 编译示例与真实程序,装进 ZOS 的 /bin
echo "== zcc 编译 =="
mkdir -p "$OS_ROOT/zig-out/bin/user"
for f in examples/*.c; do
    name=$(basename "$f" .c)
    ./zig-out/bin/zcc "$f" -o "$OS_ROOT/zig-out/bin/user/z$name"
    echo "  z$name"
done
# 真实移植测试:ZOS 仓库里的 wc.c(zig cc 版叫 wc,zcc 版叫 wcz)
./zig-out/bin/zcc "$OS_ROOT/userland/wc.c" -o "$OS_ROOT/zig-out/bin/user/wcz"
echo "  wcz(来自 ../os/userland/wc.c)"
./zig-out/bin/zcc "$OS_ROOT/userland/cdemo.c" -o "$OS_ROOT/zig-out/bin/user/zcdemo"
echo "  zcdemo(来自 ../os/userland/cdemo.c,libc 全家桶)"

# 4) 打 ISO + 启动 QEMU 逐条运行
echo "== 打包 ISO 并启动 QEMU =="
cd "$OS_ROOT"
zig build iso >/dev/null

python3 scripts/test.py \
    "zhello" \
    "zarith" "zcontrol" "zptr" "zstruct" "zalloc" \
    "wcz /etc/motd" "wc /etc/motd" \
    "zcdemo" \
    "echo e2e-done"
