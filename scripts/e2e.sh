#!/usr/bin/env bash
# 端到端测试:OusiaC 编译示例 → 打进 ZOS initrd → QEMU 启动运行 → 校验输出
#
# 用法: ./scripts/e2e.sh          # 完整流程(构建 OusiaC + os + iso + qemu)
#       ./scripts/e2e.sh --fast   # 跳过 OusiaC/os 重建,只重打 iso + qemu
set -euo pipefail
cd "$(dirname "$0")/.."

OS_ROOT=${OUSIAC_OS_ROOT:-../os}
FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

# 1) 构建 OusiaC
if [[ $FAST == 0 ]]; then
    echo "== 构建 OusiaC =="
    zig build
fi

# 2) 确保 ZOS(内核 + libzos.a)已构建
if [[ $FAST == 0 ]]; then
    echo "== 构建 ZOS =="
    (cd "$OS_ROOT" && zig build)
fi

# 3) 用 OusiaC 编译示例与真实程序,装进 ZOS 的 /bin
echo "== OusiaC 编译 =="
mkdir -p "$OS_ROOT/zig-out/bin/user"
for f in examples/*.c; do
    name=$(basename "$f" .c)
    ./zig-out/bin/OusiaC "$f" -o "$OS_ROOT/zig-out/bin/user/o$name"
    echo "  o$name"
done
# 真实移植测试:ZOS 仓库里的 wc.c(zig cc 版叫 wc,OusiaC 版叫 wco)
./zig-out/bin/OusiaC "$OS_ROOT/userland/wc.c" -o "$OS_ROOT/zig-out/bin/user/wco"
echo "  wco(来自 ../os/userland/wc.c)"
./zig-out/bin/OusiaC "$OS_ROOT/userland/cdemo.c" -o "$OS_ROOT/zig-out/bin/user/ocdemo"
echo "  ocdemo(来自 ../os/userland/cdemo.c,libc 全家桶)"

# 4) 打 ISO + 启动 QEMU 逐条运行
echo "== 打包 ISO 并启动 QEMU =="
cd "$OS_ROOT"
zig build iso >/dev/null

python3 scripts/test.py \
    "ohello" \
    "oarith" "ocontrol" "optr" "ostruct" "oalloc" \
    "wco /etc/motd" "wc /etc/motd" \
    "ocdemo" \
    "echo e2e-done"
