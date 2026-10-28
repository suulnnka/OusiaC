//! occ —— OusiaC 编译器(Zig 编写)
//!
//! 流水线:C 源码 → 词法 → 预处理 → 解析(AST) → x86-64 汇编,
//! 再用 `zig cc` 汇编并链接到 OusiaOS 的 libousia.a(crt0 + libc),
//! 产出可在 ../os 中运行的用户程序(静态 ELF,基址 0x400000)。
//!
//! 用法:
//!   occ [-S|-c|-E] [-o out] [-I dir]... [-D name[=val]]... [--os-root DIR] input.c
//!
//! 默认(无 -S/-c/-E):编译 + 汇编 + 链接,一步得到 OusiaOS 可执行文件。

const std = @import("std");
const oas = @import("asm.zig");
const old = @import("link.zig");
const tk = @import("token.zig");
const ty = @import("type.zig");
const parse = @import("parse.zig");
const gen = @import("gen.zig");
const pp = @import("pp.zig");

// 内建头文件(编译器自带,优先于系统 include 路径)
const builtin_headers_src = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "stddef.h", .src = @embedFile("include/stddef.h") },
    .{ .name = "stdarg.h", .src = @embedFile("include/stdarg.h") },
    .{ .name = "stdbool.h", .src = @embedFile("include/stdbool.h") },
    .{ .name = "stdint.h", .src = @embedFile("include/stdint.h") },
    .{ .name = "limits.h", .src = @embedFile("include/limits.h") },
};

const Options = struct {
    input: []const u8 = "",
    output: []const u8 = "",
    mode: enum { auto, asm_only, obj_only, preprocess, assemble } = .auto,
    include_dirs: std.ArrayList([]const u8) = .empty,
    defines: std.ArrayList([]const u8) = .empty,
    os_root: []const u8 = "../os",
    os_root_explicit: bool = false,
    verbose: bool = false,
    keep_asm: bool = false,
    use_zig_cc: bool = false,
};

const usage =
    \\occ - OusiaC 编译器(Zig 编写,目标:OusiaOS x86-64 用户程序)
    \\
    \\用法: occ [选项] input.c
    \\
    \\  -o <file>       输出文件(默认 a.out / input.s / input.o)
    \\  -S              只生成汇编(.s)
    \\  --oas           汇编模式:输入 .s,输出 .o(自研汇编器)
    \\  -c              只汇编到目标文件(.o)
    \\  -E              只预处理,输出到 stdout
    \\  -I <dir>        头文件搜索路径(可多次)
    \\  -D <n>[=v]      预定义宏(可多次)
    \\  --os-root DIR   OusiaOS 仓库位置(默认 ../os,需先 zig build 出 libousia.a)
    \\  --keep-s        链接后保留 .s 汇编文件
    \\  --use-zig-cc    回退:汇编/链接改用 zig cc(默认用自研 oas + old)
    \\  -v              打印底层命令
    \\  -h, --help      本帮助
    \\
;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("occ: error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = init.minimal.args.vector;
    var opts = Options{};
    var args_buf: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |a| try args_buf.append(arena, std.mem.span(a));
    try parseCli(arena, args_buf.items, &opts);
    if (opts.input.len == 0) {
        std.debug.print("{s}", .{usage});
        std.process.exit(0);
    }
    // 环境变量仅在未显式指定 --os-root 时生效
    if (!opts.os_root_explicit) {
        if (init.environ_map.get("OUSIAC_OS_ROOT")) |root| opts.os_root = root;
    }

    // ---- 汇编模式:.s → .o(自研汇编器)----
    if (opts.mode == .assemble) {
        const src_text = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(64 << 20)) catch |e| {
            fatal("cannot read '{s}': {s}", .{ opts.input, @errorName(e) });
        };
        const obj = oas.Assembler.assemble(arena, src_text, opts.input) catch {
            std.process.exit(1);
        };
        const out = if (opts.output.len > 0) opts.output else (replaceExt(arena, opts.input, ".o") orelse fatal("bad input name", .{}));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = obj });
        if (opts.verbose) std.debug.print("occ: assembled {s} -> {s} ({d} bytes)\n", .{ opts.input, out, obj.len });
        return;
    }

    // ---- 读入源文件 ----
    const content_raw = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(8 << 20)) catch |e| {
        fatal("cannot read '{s}': {s}", .{ opts.input, @errorName(e) });
    };
    const content = pp.stripLineSplices(arena, content_raw);
    const file = arena.create(tk.SourceFile) catch unreachable;
    file.* = .{ .path = opts.input, .content = content };

    // ---- include 搜索路径:-I 目录 + OusiaOS 的 userland/include ----
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.appendSlice(arena, opts.include_dirs.items);
    const os_include = try std.fmt.allocPrint(arena, "{s}/userland/include", .{opts.os_root});
    try dirs.append(arena, os_include);

    // ---- 内建头文件表 ----
    var builtins = std.StringHashMap([]const u8).init(arena);
    for (builtin_headers_src) |h| {
        try builtins.put(h.name, h.src);
    }

    // ---- 词法 + 预处理 ----
    const chain = tk.Lexer.tokenize(arena, file) catch {
        std.process.exit(1);
    };
    const toks = pp.chainToSlice(arena, chain);

    const pp_ctx = pp.Pp.init(arena, io, dirs.items, &builtins, file);
    // -D 定义的宏
    for (opts.defines.items) |d| {
        if (std.mem.indexOfScalar(u8, d, '=')) |eq| {
            pp_ctx.definePlain(d[0..eq], d[eq + 1 ..]);
        } else {
            pp_ctx.definePlain(d, "1");
        }
    }
    const pp_toks = pp_ctx.run(toks) catch {
        std.process.exit(1);
    };

    if (opts.mode == .preprocess) {
        var buf: [4096]u8 = undefined;
        var fw = std.Io.File.stdout().writer(io, &buf);
        for (pp_toks) |t| {
            if (t.kind == .eof) break;
            if (t.has_space) try fw.interface.writeAll(" ");
            if (t.at_bol) try fw.interface.writeAll("\n");
            try fw.interface.writeAll(t.text);
        }
        try fw.interface.writeAll("\n");
        try fw.flush();
        return;
    }

    // ---- 解析 ----
    const globals = parse.parse(arena, pp_toks) catch {
        std.process.exit(1);
    };

    // ---- 代码生成 ----
    const asm_text = gen.Gen.run(arena, globals.items) catch {
        std.process.exit(1);
    };

    // ---- 输出 .s ----
    var s_path: []const u8 = undefined;
    var default_out: std.ArrayList(u8) = .empty;
    switch (opts.mode) {
        .asm_only => {
            if (opts.output.len > 0) {
                s_path = opts.output;
            } else {
                s_path = replaceExt(arena, opts.input, ".s") orelse fatal("bad input name", .{});
            }
        },
        else => {
            if (opts.output.len > 0) {
                s_path = try std.fmt.allocPrint(arena, "{s}.s", .{opts.output});
            } else {
                s_path = replaceExt(arena, opts.input, ".s") orelse fatal("bad input name", .{});
            }
        },
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = s_path, .data = asm_text });
    if (opts.verbose) std.debug.print("occ: wrote {s}\n", .{s_path});
    if (opts.mode == .asm_only) return;

    // ---- 汇编 + 链接(zig cc + OusiaOS 的 libousia.a)----
    const libousia = try std.fmt.allocPrint(arena, "{s}/zig-out/lib/libousia.a", .{opts.os_root});
    const user_ld = try std.fmt.allocPrint(arena, "{s}/userland/user.ld", .{opts.os_root});

    // libousia.a 存在性检查
    _ = std.Io.Dir.cwd().statFile(io, libousia, .{}) catch {
        fatal("找不到 {s}\n  请先在 OusiaOS 仓库目录执行: zig build\n  (或用 --os-root 指定 OusiaOS 位置)", .{libousia});
    };

    if (opts.mode == .obj_only) {
        const obj_out = if (opts.output.len > 0) opts.output else (replaceExt(arena, opts.input, ".o") orelse fatal("bad input name", .{}));
        if (!opts.use_zig_cc) {
            const obj_data = oas.Assembler.assemble(arena, asm_text, s_path) catch {
                std.process.exit(1);
            };
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = obj_out, .data = obj_data });
        } else {
            const cc_argv = [_][]const u8{
                "zig", "cc", "-target", "x86_64-freestanding", "-c", "-o", obj_out, s_path,
            };
            try runChild(gpa, io, &cc_argv, opts.verbose);
        }
        if (!opts.keep_asm) deleteFile(io, s_path);
        return;
    }

    const out_path = if (opts.output.len > 0) opts.output else blk: {
        default_out.appendSlice(arena, "a.out") catch unreachable;
        break :blk default_out.items;
    };

    // ---- 自研汇编 + 链接(默认路径)----
    if (!opts.use_zig_cc) {
        const obj_data = oas.Assembler.assemble(arena, asm_text, s_path) catch {
            std.process.exit(1);
        };
        if (opts.mode == .obj_only) {
            // 不会到这里(-c 在前面已处理并 return)——保险
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = obj_data });
            return;
        }
        const lib_data = std.Io.Dir.cwd().readFileAlloc(io, libousia, arena, .limited(64 << 20)) catch {
            fatal("cannot read {s}", .{libousia});
        };
        old.Linker.link(
            arena,
            &.{.{ .path = s_path, .data = obj_data }},
            &.{.{ .path = libousia, .data = lib_data }},
            "_start",
            out_path,
            io,
        ) catch {
            std.process.exit(1);
        };
        if (!opts.keep_asm) deleteFile(io, s_path);
        if (opts.verbose) std.debug.print("occ: {s} -> {s} (oas + old)\n", .{ opts.input, out_path });
        return;
    }

    // ---- zig cc 回退路径 ----
    const cc_argv = [_][]const u8{
        "zig",                    "cc",
        "-target",                "x86_64-freestanding",
        "-nostdlib",              "-no-pie",
        "-static",                "-fno-stack-protector",
        try std.fmt.allocPrint(arena, "-Wl,--script={s}", .{user_ld}),
        "-Wl,-e,_start",          "-Wl,--build-id=none",
        "-o",                     out_path,
        s_path,                   libousia,
    };
    try runChild(gpa, io, &cc_argv, opts.verbose);
    if (!opts.keep_asm) deleteFile(io, s_path);
    if (opts.verbose) std.debug.print("occ: {s} -> {s}\n", .{ opts.input, out_path });
}

fn parseCli(arena: std.mem.Allocator, args: []const []const u8, opts: *Options) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) fatal("-o requires an argument", .{});
            opts.output = args[i];
        } else if (std.mem.eql(u8, a, "-S")) {
            opts.mode = .asm_only;
        } else if (std.mem.eql(u8, a, "--oas")) {
            opts.mode = .assemble;
        } else if (std.mem.eql(u8, a, "-c")) {
            opts.mode = .obj_only;
        } else if (std.mem.eql(u8, a, "-E")) {
            opts.mode = .preprocess;
        } else if (std.mem.eql(u8, a, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--keep-s")) {
            opts.keep_asm = true;
        } else if (std.mem.eql(u8, a, "--use-zig-cc")) {
            opts.use_zig_cc = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--os-root")) {
            i += 1;
            if (i >= args.len) fatal("--os-root requires an argument", .{});
            opts.os_root = args[i];
            opts.os_root_explicit = true;
        } else if (std.mem.startsWith(u8, a, "--os-root=")) {
            opts.os_root = a["--os-root=".len..];
            opts.os_root_explicit = true;
        } else if (std.mem.eql(u8, a, "-I")) {
            i += 1;
            if (i >= args.len) fatal("-I requires an argument", .{});
            try opts.include_dirs.append(arena, args[i]);
        } else if (std.mem.startsWith(u8, a, "-I")) {
            try opts.include_dirs.append(arena, a[2..]);
        } else if (std.mem.eql(u8, a, "-D")) {
            i += 1;
            if (i >= args.len) fatal("-D requires an argument", .{});
            try opts.defines.append(arena, args[i]);
        } else if (std.mem.startsWith(u8, a, "-D")) {
            try opts.defines.append(arena, a[2..]);
        } else if (std.mem.startsWith(u8, a, "-")) {
            fatal("unknown option '{s}'", .{a});
        } else {
            if (opts.input.len > 0) fatal("multiple input files not supported ('{s}' and '{s}')", .{ opts.input, a });
            opts.input = a;
        }
    }
}

fn replaceExt(arena: std.mem.Allocator, path: []const u8, new_ext: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    if (stem.len == 0) return null;
    const dir = std.fs.path.dirname(path) orelse "";
    if (dir.len == 0) return std.fmt.allocPrint(arena, "{s}{s}", .{ stem, new_ext }) catch null;
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, stem, new_ext }) catch null;
}

fn runChild(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, verbose: bool) !void {
    if (verbose) {
        std.debug.print("occ: run:", .{});
        for (argv) |a| std.debug.print(" {s}", .{a});
        std.debug.print("\n", .{});
    }
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stderr_limit = .limited(1 << 20),
        .stdout_limit = .limited(1 << 20),
    }) catch |e| {
        if (e == error.FileNotFound) fatal("无法启动 '{s}'(不在 PATH 里?)", .{argv[0]});
        return e;
    };
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        else => fatal("child process '{s}' terminated abnormally", .{argv[0]}),
    }
}

fn deleteFile(io: std.Io, path: []const u8) void {
    if (std.Io.Dir.cwd().deleteFile(io, path)) |_| {} else |_| {}
}
