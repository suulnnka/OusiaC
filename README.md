# OusiaC —— 用 Zig 写的 C 编译器(目标:../os 的 OusiaOS)

`OusiaC`(原名 `zcc`)是一个约 6400 行 Zig 的**自包含教学级 C 工具链**:编译器(词法→预处理→
解析→x86-64 代码生成)+ **汇编器 `oas`** + **链接器 `old`**,产出可以直接放进
`../os` 的 initrd、在 QEMU 里运行的用户程序(静态 ELF,基址 0x400000)。
运行时链接 OusiaOS 自己的 `libousia.a`(crt0 + libc);`zig cc` 仅作为可选回退
(`--use-zig-cc`)。

```
foo.c ──词法→ token ──预处理→ token ──解析→ AST ──代码生成→ foo.s
                                                       │
        ┌──────────────────────────────────────────────┘
        ▼
   oas(自研汇编器):foo.s → foo.o(ELF64 REL + 重定位)
        ▼
   old(自研链接器):foo.o + libousia.a(GNU ar,lazy 抽取)
        → foo(静态 ET_EXEC @0x400000,入口 _start,两个 PT_LOAD)
```

### 链接的是谁的 libc?

**OusiaOS 自己的 libc,不是 Zig 的,也不是宿主机 glibc。**

- 产物链接的 `libousia.a` 由 `../os` 的 `zig build` 产出,源码在
  `../os/userland/lib/`(libc.zig + clib.c),底层走 OusiaOS 内核的 `int 0x80`
  系统调用——这正是程序能跑进 OusiaOS 的原因。
- `zig cc` 只充当汇编器+链接器;`-nostdlib -target x86_64-freestanding`
  保证 Zig 自带的 musl/crt 不会链进任何东西。
- Linux 的 glibc 无法用于 OusiaOS 目标:OusiaOS 内核只实现了一个 POSIX 子集,
  没有 TLS/动态链接/futex,glibc 二进制在里面起不来。

## 快速开始

```bash
cd ../os && zig build        # 1) 先构建 OusiaOS(产出 libousia.a)
cd ../ccompiler && zig build # 2) 构建 OusiaC

./zig-out/bin/OusiaC examples/hello.c -o ohello   # 3) 编译一个 C 程序
./scripts/e2e.sh                               # 4) 端到端:打 ISO + QEMU 全量验证
```

e2e 会把 OusiaC 编译的程序装进 OusiaOS 的 `/bin`,启动 QEMU 逐个运行并检查输出,
包括用 OusiaC 编译 OusiaOS 仓库里的真实程序 `wc.c`、`cdemo.c`(与 zig cc 版逐字节对比)。

## 用法

```
OusiaC [选项] input.c
  -o <file>       输出(默认 a.out)
  -S / -c / -E    只到汇编 / 目标文件 / 预处理
  -I <dir>        头文件搜索路径(自动追加 <os-root>/userland/include)
  -D <n>[=v]      预定义宏
  --os-root DIR   OusiaOS 仓库位置(默认 ../os,或环境变量 OUSIAC_OS_ROOT)
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
  OusiaC 二进制里(@embedFile),其余(<stdio.h> 等)用 OusiaOS 的 userland/include。

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
| `src/asm.zig` | **汇编器 oas**:AT&T 子集 → ELF64 REL(.o),含重定位 | ~700 |
| `src/link.zig` | **链接器 old**:.o + libousia.a → 静态 ET_EXEC | ~700 |
| `src/main.zig` | 驱动:CLI → 流水线 → oas → old(zig cc 仅回退) | ~330 |

几个值得一提的实现点:

- **类型推导**:Node 构造时自底向上 `addType`(chibicc 风格);`>`/`>=` 在此处
  翻转成 `<`/`<=`,代码生成少两个分支。
- **指针算术**在解析层完成缩放(`newAdd`/`newSub`),代码生成器只见到纯整数。
- **调用约定**:实参全部求值压栈再逆序弹入 rdi/rsi/rdx/rcx/r8/r9;
  第 7 个起留在栈上,奇数个时垫 8 字节保证 call 时 %rsp 16 字节对齐;
  可变参数调用前 `mov $0, %eax`(无向量寄存器)。
- **int 语义**:所有算术在 int(32 位)或 long(64 位)档进行,加载/存储按
  实际宽度符号或零扩展;全局初始化器支持"符号 ± 常量"的地址重定位。

### 汇编器 oas(src/asm.zig)

只编码 OusiaC 生成器输出的指令子集(约 60 种操作数模式),因此可以做到很小:
寄存器/内存操作数解析(REX 自动生成、r8-r15、disp8/disp32、`sym(%rip)`)、
跳转一律 rel32 并在节末 patch 局部标签、其余符号引用发
R_X86_64_{PC32,PLT32,64} 重定位;输出带 .symtab/.rela 的标准 ELF64 REL,
可用 `objdump -d` 直接检查。

### 链接器 old(src/link.zig)

- **输入**:若干 .o + GNU ar 归档(解析 `/` 符号索引与 `//` 长名表,按需
  lazy 抽取成员,索引损坏则退化为全量索引)。
- **符号**:强/弱/COMMON 解析,STT_SECTION 局部符号,重复强定义报错;
  入口符号 `_start` 强制从归档拉入。
- **布局**:复刻 `user.ld` 的节序(.text → .rodata → .data → .bss,基址
  0x400000),丢弃 .eh_frame/调试节;**每个输出区起始按区内最大对齐数对齐**
  (lib 的 memset 用 movaps,常量池需要 16 字节对齐——这是实际踩过的坑)。
- **重定位**:R_X86_64_{64, PC32, PLT32, 32, 32S},全部带溢出检查。
- **输出**:ET_EXEC、入口 _start、两个 PT_LOAD(RX 含头+text+rodata,
  RW 含 data+bss,bss 用 memsz>filesz),p_offset ≡ p_vaddr (mod 0x1000),
  与 OusiaOS 内核加载器(kernel/elf.zig)的约定完全匹配。

## 测试

`examples/` 里 6 个程序覆盖算术溢出/unsigned、控制流、指针/函数指针/qsort、
结构体/联合/枚举/设计器、malloc/字符串/文件 IO,每行输出都有预期值;
`./scripts/e2e.sh` 在 QEMU 里全量校验,并额外编译 OusiaOS 仓库的真实程序:

- `wc.c`(Unix 字数统计)→ `wco`:与 zig cc 版 `wc` 输出**逐字节一致**
- `cdemo.c`(libc 全家桶自检)→ `ocdemo`:`cdemo: PASS`

```
$ ./scripts/e2e.sh
...
/ $ oarith
1: 12
2: -10
...
/ $ wco /etc/motd
      4     29    202 /etc/motd
/ $ wc /etc/motd
      4     29    202 /etc/motd
/ $ ocdemo
...
cdemo: PASS
```
