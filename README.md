# zcc —— 用 Zig 写的 C 编译器(目标:../os 的 ZOS)

`zcc` 是一个约 4600 行 Zig 的教学级 C 编译器:读入 C 源码,生成 x86-64 汇编,
再借助 `zig cc` 汇编、链接到 ZOS 的 `libzos.a`(crt0 + libc),产出可以直接放进
`../os` 的 initrd、在 QEMU 里运行的用户程序(静态 ELF,基址 0x400000)。

```
foo.c ──词法──> token ──预处理──> token ──解析──> AST ──代码生成──> foo.s
                                                                  │
        ┌─────────────────────────────────────────────────────────┘
        ▼
   zig cc -target x86_64-freestanding -nostdlib -Wl,--script=../os/userland/user.ld
          foo.s ../os/zig-out/lib/libzos.a  ──>  foo(ZOS 可执行文件)
```

**为什么不自己写 ELF/链接器?** "转成可执行文件"最省事的路是复用现成工具链:
`zig cc` 当汇编器 + 链接器,ZOS 仓库里的 `libzos.a` 当运行时(`_start`、printf、
malloc 全都在),`user.ld` 决定加载基址。编译器本体只需要把 C 正确翻译成汇编。

### 链接的是谁的 libc?

**ZOS 自己的 libc,不是 Zig 的,也不是宿主机 glibc。**

- 产物链接的 `libzos.a` 由 `../os` 的 `zig build` 产出,源码在
  `../os/userland/lib/`(libc.zig + clib.c),底层走 ZOS 内核的 `int 0x80`
  系统调用——这正是程序能跑进 ZOS 的原因。
- `zig cc` 只充当汇编器+链接器;`-nostdlib -target x86_64-freestanding`
  保证 Zig 自带的 musl/crt 不会链进任何东西。
- Linux 的 glibc 无法用于 ZOS 目标:ZOS 内核只实现了一个 POSIX 子集,
  没有 TLS/动态链接/futex,glibc 二进制在里面起不来。

## 快速开始

```bash
cd ../os && zig build        # 1) 先构建 ZOS(产出 libzos.a)
cd ../ccompiler && zig build # 2) 构建 zcc

./zig-out/bin/zcc examples/hello.c -o zhello   # 3) 编译一个 C 程序
./scripts/e2e.sh                               # 4) 端到端:打 ISO + QEMU 全量验证
```

e2e 会把 zcc 编译的程序装进 ZOS 的 `/bin`,启动 QEMU 逐个运行并检查输出,
包括用 zcc 编译 ZOS 仓库里的真实程序 `wc.c`、`cdemo.c`(与 zig cc 版逐字节对比)。

## 用法

```
zcc [选项] input.c
  -o <file>       输出(默认 a.out)
  -S / -c / -E    只到汇编 / 目标文件 / 预处理
  -I <dir>        头文件搜索路径(自动追加 <os-root>/userland/include)
  -D <n>[=v]      预定义宏
  --os-root DIR   ZOS 仓库位置(默认 ../os,或环境变量 ZCC_OS_ROOT)
  --keep-s        链接后保留 .s(看看生成的汇编,教学用)
  -v              打印底层命令
```

## 支持的 C 子集

- **类型**:void/char/short/int/long(±unsigned)、指针、多维数组、
  结构体/联合/枚举、typedef、函数指针;const/volatile 接受并忽略。
- **语句**:if/else、while、do-while、for(含 C99 声明式 init)、
  switch/case/default(fallthrough)、break/continue、goto/标签、嵌套作用域。
- **表达式**:完整运算符集与优先级、三元、逗号、赋值族(`+=` 等)、
  前后缀 `++/--`(经临时变量脱糖,避免重复求值副作用)、
  指针算术(含 ptr-ptr 差)、sizeof、强制转换、整数常量折叠。
- **初始化器**:标量、数组(字符串字面量、长度推断、`[n]=` 设计器)、
  结构体(嵌套、`.field=` 设计器)、全局/静态局部(常量镜像 + 重定位)。
- **预处理器**:#include <>/""、对象/函数宏(#、##、__VA_ARGS__)、
  #if/#ifdef/#elif/#else/#endif(#if 走真正的常量求值器)、
  #undef/#error/#pragma(忽略)、__FILE__/__LINE__/__COUNTER__ 等。
- **内建头文件**:stddef.h/stdarg.h/stdbool.h/stdint.h/limits.h 直接嵌在
  zcc 二进制里(@embedFile),其余(<stdio.h> 等)用 ZOS 的 userland/include。

### 已知边界(教学取舍)

- 不支持 float/double、位域、struct 按值传参/返回(用指针,示例 struct.c 有写法)、
  定义可变参数函数(调用 printf 这类没问题)、K&R 旧式定义、inline asm。
- 单翻译单元(无 .h 多文件链接);优化为零(栈机式直译,正确性优先)。

## 源码导读(建议顺序)

| 文件 | 内容 | 行数 |
|---|---|---|
| `src/token.zig` | Token/词法分析、file:line 诊断 | 369 |
| `src/type.zig` | 类型系统(尺寸/对齐/通常算术转换) | 194 |
| `src/parse.zig` | 声明/声明符(分组小舞蹈)/语句/表达式/初始化器/常量求值 | 2431 |
| `src/gen.zig` | x86-64 SysV 代码生成(栈机式:结果恒在 %rax) | 564 |
| `src/pp.zig` | 预处理器(宏、条件编译、include) | 754 |
| `src/main.zig` | 驱动:CLI → 流水线 → 调 zig cc 链接 | 292 |

几个值得一提的实现点:

- **类型推导**:Node 构造时自底向上 `addType`(chibicc 风格);`>`/`>=` 在此处
  翻转成 `<`/`<=`,代码生成少两个分支。
- **指针算术**在解析层完成缩放(`newAdd`/`newSub`),代码生成器只见到纯整数。
- **调用约定**:实参全部求值压栈再逆序弹入 rdi/rsi/rdx/rcx/r8/r9;
  第 7 个起留在栈上,奇数个时垫 8 字节保证 call 时 %rsp 16 字节对齐;
  可变参数调用前 `mov $0, %eax`(无向量寄存器)。
- **int 语义**:所有算术在 int(32 位)或 long(64 位)档进行,加载/存储按
  实际宽度符号或零扩展;全局初始化器支持"符号 ± 常量"的地址重定位。

## 测试

`examples/` 里 6 个程序覆盖算术溢出/unsigned、控制流、指针/函数指针/qsort、
结构体/联合/枚举/设计器、malloc/字符串/文件 IO,每行输出都有预期值;
`./scripts/e2e.sh` 在 QEMU 里全量校验,并额外编译 ZOS 仓库的真实程序:

- `wc.c`(Unix 字数统计)→ `wcz`:与 zig cc 版 `wc` 输出**逐字节一致**
- `cdemo.c`(libc 全家桶自检)→ `zcdemo`:`cdemo: PASS`

```
$ ./scripts/e2e.sh
...
/ $ zarith
1: 12
2: -10
...
/ $ wcz /etc/motd
      4     29    202 /etc/motd
/ $ wc /etc/motd
      4     29    202 /etc/motd
/ $ zcdemo
...
cdemo: PASS
```
