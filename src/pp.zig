//! C 预处理器
//!
//! 支持:#include <>/""、对象宏/函数宏(# 与 ##)、#if/#ifdef/#ifndef/
//! #elif/#else/#endif、#undef、#error、#pragma(忽略)、
//! 内建宏 __FILE__/__LINE__/__DATE__/__TIME__/__COUNTER__。
//!
//! 宏递归防护:展开时携带"活跃宏名栈",栈中宏不再展开(等价 hide set 的
//! 常见情形,足够覆盖标准头文件的 include guard 与常规用法)。

const std = @import("std");
const tk = @import("token.zig");
const parse = @import("parse.zig");

const Token = tk.Token;
const SourceFile = tk.SourceFile;
const CompileError = tk.CompileError;
const errorAt = tk.errorAt;

const Macro = struct {
    name: []const u8,
    is_func: bool = false,
    params: []const []const u8 = &.{},
    va_args: bool = false,
    body: []const *Token = &.{},
    builtin: enum { none, file, line, counter, date, time } = .none,
};

const CondIncl = struct {
    tok: *Token,
    included: bool,
    in_else: bool = false,
};

pub const Pp = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    macros: std.StringHashMap(*Macro),
    include_dirs: []const []const u8,
    builtin_headers: *const std.StringHashMap([]const u8),
    include_depth: u32 = 0,
    cond_stack: std.ArrayList(CondIncl) = .empty,
    counter: u32 = 0,
    cur_file: *SourceFile,
    pub fn init(
        arena: std.mem.Allocator,
        io: std.Io,
        include_dirs: []const []const u8,
        builtin_headers: *const std.StringHashMap([]const u8),
        cur_file: *SourceFile,
    ) *Pp {
        const p = arena.create(Pp) catch unreachable;
        p.* = .{
            .arena = arena,
            .io = io,
            .macros = std.StringHashMap(*Macro).init(arena),
            .include_dirs = include_dirs,
            .builtin_headers = builtin_headers,
            .cur_file = cur_file,
        };
        p.predefine();
        return p;
    }

    fn predefine(self: *Pp) void {
        self.definePlain("__ZCC__", "1");
        self.definePlain("__STDC__", "1");
        self.definePlain("__STDC_HOSTED__", "1");
        self.definePlain("__STDC_VERSION__", "201112L");
        self.defineBuiltin("__FILE__", .file);
        self.defineBuiltin("__LINE__", .line);
        self.defineBuiltin("__COUNTER__", .counter);
        self.defineBuiltin("__DATE__", .date);
        self.defineBuiltin("__TIME__", .time);
    }

    pub fn definePlain(self: *Pp, name: []const u8, body_text: []const u8) void {
        const file = self.arena.create(SourceFile) catch unreachable;
        file.* = .{ .path = "<built-in>", .content = body_text };
        const body = chainToSlice(self.arena, tk.Lexer.tokenize(self.arena, file) catch {
            return;
        });
        const m = self.arena.create(Macro) catch unreachable;
        m.* = .{ .name = name, .body = body };
        self.macros.put(name, m) catch unreachable;
    }

    fn defineBuiltin(self: *Pp, name: []const u8, b: @FieldType(Macro, "builtin")) void {
        const m = self.arena.create(Macro) catch unreachable;
        m.* = .{ .name = name, .builtin = b };
        self.macros.put(name, m) catch unreachable;
    }

    // ---------------- 主流程 ----------------
    /// 处理整段 token 列表;active 为当前展开链上的宏名
    fn runList(self: *Pp, list: []const *Token, active: []const []const u8, out: *std.ArrayList(*Token)) CompileError!void {
        var i: usize = 0;
        while (i < list.len) {
            const t = list[i];
            // 指令(只在原始流中识别;宏体内不会出现)
            if (t.at_bol and t.isPunct("#") and i + 1 < list.len and !list[i + 1].at_bol) {
                i = try self.directive(list, i, out, active);
                continue;
            }
            if (t.kind == .ident) {
                if (self.macros.get(t.text)) |m| {
                    if (activeIndex(active, t.text) == null) {
                        // 函数宏:后面紧跟 '(' 才展开
                        if (m.is_func and i + 1 < list.len and list[i + 1].isPunct("(")) {
                            var args: std.ArrayList([]const *Token) = .empty;
                            const after = try self.readMacroArgs(list, i + 1, m, t, &args);
                            const body = try self.subst(m, t, args.items, active);
                            var sub_out: std.ArrayList(*Token) = .empty;
                            try self.runList(body, appendActive(self.arena, active, t.text), &sub_out);
                            if (sub_out.items.len > 0) sub_out.items[0].has_space = t.has_space;
                            out.appendSlice(self.arena, sub_out.items) catch unreachable;
                            i = after;
                            continue;
                        }
                        if (!m.is_func) {
                            try self.expandObjectMacro(m, t, active, out);
                            i += 1;
                            continue;
                        }
                    }
                }
            }
            out.append(self.arena, t) catch unreachable;
            i += 1;
        }
    }

    fn expandObjectMacro(self: *Pp, m: *Macro, t: *Token, active: []const []const u8, out: *std.ArrayList(*Token)) CompileError!void {
        switch (m.builtin) {
            .none => {},
            .file => {
                const nt = self.arena.create(Token) catch unreachable;
                nt.* = .{
                    .kind = .str,
                    .text = t.file.path,
                    .file = t.file,
                    .line = t.line,
                    .line_start = t.line_start,
                    .str_data = t.file.path,
                    .has_space = t.has_space,
                };
                out.append(self.arena, nt) catch unreachable;
                return;
            },
            .line => {
                const nt = self.arena.create(Token) catch unreachable;
                const text = std.fmt.allocPrint(self.arena, "{d}", .{t.line}) catch unreachable;
                nt.* = .{
                    .kind = .num,
                    .text = text,
                    .file = t.file,
                    .line = t.line,
                    .line_start = t.line_start,
                    .num_val = t.line,
                    .has_space = t.has_space,
                };
                out.append(self.arena, nt) catch unreachable;
                return;
            },
            .counter => {
                const nt = self.arena.create(Token) catch unreachable;
                const text = std.fmt.allocPrint(self.arena, "{d}", .{self.counter}) catch unreachable;
                nt.* = .{
                    .kind = .num,
                    .text = text,
                    .file = t.file,
                    .line = t.line,
                    .line_start = t.line_start,
                    .num_val = self.counter,
                    .has_space = t.has_space,
                };
                self.counter += 1;
                out.append(self.arena, nt) catch unreachable;
                return;
            },
            .date, .time => {
                const nt = self.arena.create(Token) catch unreachable;
                const lit = if (m.builtin == .date) "Oct 27 2026" else "00:00:00";
                nt.* = .{
                    .kind = .str,
                    .text = lit,
                    .file = t.file,
                    .line = t.line,
                    .line_start = t.line_start,
                    .str_data = lit,
                    .has_space = t.has_space,
                };
                out.append(self.arena, nt) catch unreachable;
                return;
            },
        }
        var sub_out: std.ArrayList(*Token) = .empty;
        try self.runList(dupTokens(self.arena, m.body), appendActive(self.arena, active, t.text), &sub_out);
        if (sub_out.items.len > 0) sub_out.items[0].has_space = t.has_space;
        out.appendSlice(self.arena, sub_out.items) catch unreachable;
    }

    // ---------------- 指令 ----------------
    /// 处理 list[from] 开始的指令行;返回处理完后的下一个下标
    fn directive(self: *Pp, list: []const *Token, from: usize, out: *std.ArrayList(*Token), active: []const []const u8) CompileError!usize {
        const hash = list[from];
        if (from + 1 >= list.len) return from + 1;
        const name_tok = list[from + 1];
        const name = name_tok.text;
        // 指令行 = 从 from+2 起,直到下一个 at_bol
        var end = from + 2;
        while (end < list.len and !list[end].at_bol) end += 1;
        const rest = list[from + 2 .. end];

        if (std.mem.eql(u8, name, "include")) {
            try self.doInclude(hash, rest, out, active);
            return end;
        }
        if (std.mem.eql(u8, name, "define")) {
            try self.doDefine(hash, rest);
            return end;
        }
        if (std.mem.eql(u8, name, "undef")) {
            if (rest.len > 0 and rest[0].kind == .ident) {
                _ = self.macros.remove(rest[0].text);
            }
            return end;
        }
        if (std.mem.eql(u8, name, "if")) {
            const v = try self.evalCondLine(hash, rest);
            self.cond_stack.append(self.arena, .{ .tok = hash, .included = v }) catch unreachable;
            if (!v) return self.skipToElseOrEndif(list, end);
            return end;
        }
        if (std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
            var v = false;
            if (rest.len > 0 and rest[0].kind == .ident) {
                v = self.macros.contains(rest[0].text);
            } else {
                return errorAt(hash, "macro name missing after #{s}", .{name});
            }
            if (std.mem.eql(u8, name, "ifndef")) v = !v;
            self.cond_stack.append(self.arena, .{ .tok = hash, .included = v }) catch unreachable;
            if (!v) return self.skipToElseOrEndif(list, end);
            return end;
        }
        if (std.mem.eql(u8, name, "elif")) {
            if (self.cond_stack.items.len == 0)
                return errorAt(hash, "stray #elif", .{});
            const top = &self.cond_stack.items[self.cond_stack.items.len - 1];
            if (top.included or top.in_else)
                return self.skipToEndif(list, end);
            const v = try self.evalCondLine(hash, rest);
            top.included = v;
            if (!v) return self.skipToElseOrEndif(list, end);
            return end;
        }
        if (std.mem.eql(u8, name, "else")) {
            if (self.cond_stack.items.len == 0)
                return errorAt(hash, "stray #else", .{});
            const top = &self.cond_stack.items[self.cond_stack.items.len - 1];
            top.in_else = true;
            if (top.included) return self.skipToEndif(list, end);
            top.included = true;
            return end;
        }
        if (std.mem.eql(u8, name, "endif")) {
            if (self.cond_stack.items.len == 0)
                return errorAt(hash, "stray #endif", .{});
            _ = self.cond_stack.pop();
            return end;
        }
        if (std.mem.eql(u8, name, "error")) {
            var msg: std.ArrayList(u8) = .empty;
            for (rest, 0..) |t, k| {
                if (k > 0 and t.has_space) msg.append(self.arena, ' ') catch unreachable;
                msg.appendSlice(self.arena, t.text) catch unreachable;
            }
            return errorAt(hash, "#error{s} {s}", .{ if (rest.len > 0) "" else ":", msg.items });
        }
        if (std.mem.eql(u8, name, "pragma") or std.mem.eql(u8, name, "line")) {
            return end; // 忽略
        }
        return errorAt(name_tok, "unknown preprocessor directive '#{s}'", .{name});
    }

    /// 跳过未满足的条件块,返回停在那条指令 '#' 的下标(由主循环重新处理)
    fn skipToElseOrEndif(self: *Pp, list: []const *Token, from: usize) usize {
        _ = self;
        var i = from;
        var depth: u32 = 0;
        while (i < list.len) : (i += 1) {
            const t = list[i];
            if (t.at_bol and t.isPunct("#") and i + 1 < list.len and !list[i + 1].at_bol) {
                const name = list[i + 1].text;
                if (std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
                    depth += 1;
                    continue;
                }
                if (std.mem.eql(u8, name, "endif")) {
                    if (depth == 0) return i;
                    depth -= 1;
                    continue;
                }
                if (depth == 0 and (std.mem.eql(u8, name, "else") or std.mem.eql(u8, name, "elif"))) {
                    return i;
                }
            }
        }
        return i;
    }

    fn skipToEndif(self: *Pp, list: []const *Token, from: usize) usize {
        _ = self;
        var i = from;
        var depth: u32 = 0;
        while (i < list.len) : (i += 1) {
            const t = list[i];
            if (t.at_bol and t.isPunct("#") and i + 1 < list.len and !list[i + 1].at_bol) {
                const name = list[i + 1].text;
                if (std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
                    depth += 1;
                    continue;
                }
                if (std.mem.eql(u8, name, "endif")) {
                    if (depth == 0) return i; // 停在 '#',主循环将 pop 掉
                    depth -= 1;
                    continue;
                }
            }
        }
        return i;
    }

    // ---------------- #include ----------------
    fn doInclude(self: *Pp, hash: *Token, rest: []const *Token, out: *std.ArrayList(*Token), active: []const []const u8) CompileError!void {
        _ = active;
        if (rest.len == 0)
            return errorAt(hash, "#include expects a filename", .{});
        var path: []const u8 = "";
        var is_angle = false;
        const first = rest[0];
        if (first.isPunct("<")) {
            is_angle = true;
            var buf: std.ArrayList(u8) = .empty;
            for (rest[1..]) |t| {
                if (t.isPunct(">")) break;
                buf.appendSlice(self.arena, t.text) catch unreachable;
            }
            path = buf.items;
        } else if (first.kind == .str) {
            path = first.str_data;
        } else {
            return errorAt(first, "#include expects \"FILE\" or <FILE>", .{});
        }
        if (path.len == 0)
            return errorAt(hash, "#include expects a filename", .{});
        if (self.include_depth >= 64)
            return errorAt(hash, "#include nested too deeply", .{});

        const content = self.findInclude(hash, path, is_angle) orelse
            return errorAt(hash, "'{s}' file not found", .{path});

        const file = self.arena.create(SourceFile) catch unreachable;
        file.* = .{ .path = content.path, .content = content.data };
        const toks = chainToSlice(self.arena, tk.Lexer.tokenize(self.arena, file) catch |e| return e);
        // 去掉 EOF,拼接处理
        var body = toks;
        if (body.len > 0 and body[body.len - 1].kind == .eof) body = body[0 .. body.len - 1];
        self.include_depth += 1;
        const save_file = self.cur_file;
        self.cur_file = file;
        try self.runList(body, &.{}, out);
        self.cur_file = save_file;
        self.include_depth -= 1;
    }

    const IncludeContent = struct { path: []const u8, data: []const u8 };

    fn findInclude(self: *Pp, hash: *Token, path: []const u8, is_angle: bool) ?IncludeContent {
        // 内建头文件(zcc 自带 stddef.h 等)
        if (!std.fs.path.isAbsolute(path)) {
            if (self.builtin_headers.get(path)) |c| {
                return .{ .path = path, .data = c };
            }
        }
        // "file":先找当前文件所在目录
        if (!is_angle) {
            const dir = std.fs.path.dirname(self.cur_file.path) orelse ".";
            const full = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, path }) catch return null;
            if (self.readMaybe(full)) |data| return .{ .path = full, .data = data };
        }
        for (self.include_dirs) |d| {
            const full = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ d, path }) catch return null;
            if (self.readMaybe(full)) |data| return .{ .path = full, .data = data };
        }
        _ = hash;
        return null;
    }

    fn readMaybe(self: *Pp, path: []const u8) ?[]const u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(8 << 20)) catch return null;
        return stripLineSplices(self.arena, data);
    }

    // ---------------- #define ----------------
    fn doDefine(self: *Pp, hash: *Token, rest: []const *Token) CompileError!void {
        if (rest.len == 0 or rest[0].kind != .ident)
            return errorAt(hash, "macro name missing after #define", .{});
        const name = rest[0].text;
        const m = self.arena.create(Macro) catch unreachable;
        m.* = .{ .name = name };

        var body_start: usize = 1;
        if (body_start < rest.len and rest[body_start].isPunct("(") and !rest[body_start].has_space) {
            m.is_func = true;
            // 参数表
            var params: std.ArrayList([]const u8) = .empty;
            var j = body_start + 1;
            var expect_param = true;
            while (j < rest.len and !rest[j].isPunct(")")) {
                const t = rest[j];
                if (t.isPunct(",")) {
                    expect_param = true;
                    j += 1;
                    continue;
                }
                if (t.isPunct("...")) {
                    m.va_args = true;
                    j += 1;
                    continue;
                }
                if (t.kind != .ident)
                    return errorAt(t, "expected an identifier in macro parameter list", .{});
                if (!expect_param)
                    return errorAt(t, "expected ',' in macro parameter list", .{});
                params.append(self.arena, t.text) catch unreachable;
                expect_param = false;
                j += 1;
            }
            if (j >= rest.len)
                return errorAt(hash, "missing ')' in macro parameter list", .{});
            m.params = params.items;
            body_start = j + 1;
        }
        // 替换列表
        const body = self.arena.dupe(*Token, rest[body_start..]) catch unreachable;
        // 拷贝的 token 断开 next 链
        for (body) |b| b.next = null;
        m.body = body;
        self.macros.put(name, m) catch unreachable;
    }

    // ---------------- 函数宏实参与替换 ----------------
    /// list[lparen] 是 '(';返回 ')' 之后的下标
    fn readMacroArgs(self: *Pp, list: []const *Token, lparen: usize, m: *Macro, name_tok: *Token, args: *std.ArrayList([]const *Token)) CompileError!usize {
        var cur: std.ArrayList(*Token) = .empty;
        var j = lparen + 1;
        var depth: u32 = 1;
        while (j < list.len) : (j += 1) {
            const t = list[j];
            if (t.isPunct("(")) depth += 1;
            if (t.isPunct(")")) {
                depth -= 1;
                if (depth == 0) break;
            }
            if (depth == 1 and t.isPunct(",") and (!m.va_args or args.items.len >= m.params.len)) {
                args.append(self.arena, cur.items) catch unreachable;
                cur = .empty;
                continue;
            }
            cur.append(self.arena, t) catch unreachable;
        }
        if (j >= list.len)
            return errorAt(name_tok, "unterminated function-like macro invocation '{s}'", .{m.name});
        args.append(self.arena, cur.items) catch unreachable;

        // __VA_ARGS__:把多余实参(含逗号)合成一个
        if (m.va_args) {
            if (args.items.len < m.params.len) {
                // 补空参
                while (args.items.len < m.params.len)
                    args.append(self.arena, &.{}) catch unreachable;
            }
        } else if (args.items.len == 1 and args.items[0].len == 0 and m.params.len == 0) {
            // foo() 对 #define foo() :零参
        } else if (args.items.len != m.params.len) {
            return errorAt(name_tok, "macro '{s}' expects {d} argument(s), got {d}", .{ m.name, m.params.len, args.items.len });
        }
        return j + 1;
    }

    fn isParam(m: *Macro, tok: *Token) ?usize {
        if (tok.kind != .ident) return null;
        for (m.params, 0..) |p, i| {
            if (std.mem.eql(u8, p, tok.text)) return i;
        }
        if (m.va_args and std.mem.eql(u8, "__VA_ARGS__", tok.text)) return m.params.len;
        return null;
    }

    /// 替换:处理 # 字符串化、## 拼接、参数代入(代入前先做宏展开)
    fn subst(self: *Pp, m: *Macro, name_tok: *Token, args: []const []const *Token, active: []const []const u8) CompileError![]const *Token {
        var out: std.ArrayList(*Token) = .empty;

        var i: usize = 0;
        while (i < m.body.len) : (i += 1) {
            const t = m.body[i];

            // # param → 字符串化(未展开实参)
            if (t.isPunct("#") and i + 1 < m.body.len) {
                if (isParam(m, m.body[i + 1])) |pi| {
                    const raw = if (pi < args.len) args[pi] else @as([]const *Token, &.{});
                    out.append(self.arena, self.stringize(t, raw)) catch unreachable;
                    i += 1;
                    continue;
                }
            }
            // tok ## next → 拼接
            if (t.isPunct("##") and i + 1 < m.body.len and out.items.len > 0) {
                const rhs = m.body[i + 1];
                var rhs_tokens: std.ArrayList(*Token) = .empty;
                if (isParam(m, rhs)) |pi| {
                    const raw = if (pi < args.len) args[pi] else @as([]const *Token, &.{});
                    rhs_tokens.appendSlice(self.arena, raw) catch unreachable;
                } else {
                    rhs_tokens.append(self.arena, rhs) catch unreachable;
                }
                if (rhs_tokens.items.len > 0) {
                    const lhs_tok = out.items[out.items.len - 1];
                    const pasted = try self.pasteTokens(lhs_tok, rhs_tokens.items[0]);
                    out.items[out.items.len - 1] = pasted;
                    // 参数剩余 token 原样接上
                    for (rhs_tokens.items[1..]) |rt| out.append(self.arena, rt) catch unreachable;
                }
                i += 1;
                continue;
            }
            // 参数代入(展开后的)
            if (isParam(m, t)) |pi| {
                const raw = if (pi < args.len) args[pi] else @as([]const *Token, &.{});
                // 后跟 ## 时代入原始 token(标准要求)
                const next_is_paste = i + 1 < m.body.len and m.body[i + 1].isPunct("##");
                if (next_is_paste) {
                    for (raw, 0..) |rt, k| {
                        const c = self.arena.create(Token) catch unreachable;
                        c.* = rt.*;
                        if (k == 0) c.has_space = t.has_space;
                        out.append(self.arena, c) catch unreachable;
                    }
                } else {
                    var expanded: std.ArrayList(*Token) = .empty;
                    try self.runList(raw, active, &expanded);
                    for (expanded.items, 0..) |et, k| {
                        if (k == 0) et.has_space = t.has_space;
                        out.append(self.arena, et) catch unreachable;
                    }
                }
                continue;
            }
            out.append(self.arena, self.copyToken(t)) catch unreachable;
        }
        _ = name_tok;
        return out.items;
    }

    fn copyToken(self: *Pp, t: *Token) *Token {
        const c = self.arena.create(Token) catch unreachable;
        c.* = t.*;
        c.next = null;
        return c;
    }

    /// # 实参 → 字符串字面量 token
    fn stringize(self: *Pp, hash: *Token, raw: []const *Token) *Token {
        var buf: std.ArrayList(u8) = .empty;
        for (raw, 0..) |t, k| {
            if (k > 0 and t.has_space) buf.append(self.arena, ' ') catch unreachable;
            buf.appendSlice(self.arena, t.text) catch unreachable;
        }
        const t = self.arena.create(Token) catch unreachable;
        t.* = .{
            .kind = .str,
            .text = buf.items,
            .file = hash.file,
            .line = hash.line,
            .line_start = hash.line_start,
            .str_data = buf.items,
        };
        return t;
    }

    /// ## 拼接两个 token,重新词法分析;必须是单一 token
    fn pasteTokens(self: *Pp, a: *Token, b: *Token) CompileError!*Token {
        const text = std.fmt.allocPrint(self.arena, "{s}{s}", .{ a.text, b.text }) catch unreachable;
        const file = self.arena.create(SourceFile) catch unreachable;
        file.* = .{ .path = a.file.path, .content = text };
        const chain = tk.Lexer.tokenize(self.arena, file) catch {
            return errorAt(a, "pasting '{s}' and '{s}' does not give a valid token", .{ a.text, b.text });
        };
        const slice = chainToSlice(self.arena, chain);
        if (slice.len != 2 or slice[1].kind != .eof)
            return errorAt(a, "pasting '{s}' and '{s}' does not give a single token", .{ a.text, b.text });
        const merged = slice[0];
        merged.line = a.line;
        merged.line_start = a.line_start;
        merged.has_space = a.has_space;
        return merged;
    }

    // ---------------- #if 表达式 ----------------
    fn evalCondLine(self: *Pp, hash: *Token, rest: []const *Token) CompileError!bool {
        // defined(X)/defined X → 0/1
        var line: std.ArrayList(*Token) = .empty;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const t = rest[i];
            if (t.kind == .ident and std.mem.eql(u8, t.text, "defined")) {
                var name: []const u8 = "";
                if (i + 1 < rest.len and rest[i + 1].isPunct("(")) {
                    if (i + 3 < rest.len and rest[i + 2].kind == .ident and rest[i + 3].isPunct(")")) {
                        name = rest[i + 2].text;
                        i += 3;
                    } else {
                        return errorAt(t, "macro name missing after 'defined('", .{});
                    }
                } else if (i + 1 < rest.len and rest[i + 1].kind == .ident) {
                    name = rest[i + 1].text;
                    i += 1;
                } else {
                    return errorAt(t, "macro name missing after 'defined'", .{});
                }
                const nt = self.arena.create(Token) catch unreachable;
                const lit = if (self.macros.contains(name)) "1" else "0";
                nt.* = .{
                    .kind = .num,
                    .text = lit,
                    .file = t.file,
                    .line = t.line,
                    .line_start = t.line_start,
                    .num_val = if (self.macros.contains(name)) 1 else 0,
                };
                line.append(self.arena, nt) catch unreachable;
                continue;
            }
            line.append(self.arena, t) catch unreachable;
        }

        // 宏展开(拷贝一份,避免共享 token 被后续修改)
        var expanded: std.ArrayList(*Token) = .empty;
        try self.runList(dupTokens(self.arena, line.items), &.{}, &expanded);

        // 剩余 ident(未定义宏)在 #if 中视为 0
        for (expanded.items) |t| {
            if (t.kind == .ident) {
                t.kind = .num;
                t.num_val = 0;
                t.text = "0";
            }
        }

        if (expanded.items.len == 0)
            return errorAt(hash, "#if with no expression", .{});
        const eof = self.arena.create(Token) catch unreachable;
        eof.* = .{
            .kind = .eof,
            .text = "",
            .file = hash.file,
            .line = hash.line,
            .line_start = hash.line_start,
            .at_bol = true,
        };
        expanded.append(self.arena, eof) catch unreachable;
        const v = try parse.constEvalTokens(self.arena, expanded.items);
        return v != 0;
    }

    // ---------------- 入口 ----------------
    pub fn run(self: *Pp, toks: []const *Token) CompileError![]const *Token {
        var out: std.ArrayList(*Token) = .empty;
        var list = toks;
        if (list.len > 0 and list[list.len - 1].kind == .eof) list = list[0 .. list.len - 1];
        try self.runList(list, &.{}, &out);
        if (self.cond_stack.items.len > 0) {
            const c = self.cond_stack.items[self.cond_stack.items.len - 1];
            return errorAt(c.tok, "unterminated #if", .{});
        }
        // 附加 EOF
        const eof = self.arena.create(Token) catch unreachable;
        eof.* = .{
            .kind = .eof,
            .text = "",
            .file = self.cur_file,
            .at_bol = true,
        };
        out.append(self.arena, eof) catch unreachable;
        return out.items;
    }
};

fn activeIndex(active: []const []const u8, name: []const u8) ?usize {
    for (active, 0..) |a, i| {
        if (std.mem.eql(u8, a, name)) return i;
    }
    return null;
}

fn appendActive(arena: std.mem.Allocator, active: []const []const u8, name: []const u8) []const []const u8 {
    const buf = arena.alloc([]const u8, active.len + 1) catch unreachable;
    @memcpy(buf[0..active.len], active);
    buf[active.len] = name;
    return buf;
}

/// 拷贝一组 token(宏体展开前避免共享)
fn dupTokens(arena: std.mem.Allocator, list: []const *Token) []const *Token {
    const buf = arena.alloc(*Token, list.len) catch unreachable;
    for (list, 0..) |t, i| {
        const c = arena.create(Token) catch unreachable;
        c.* = t.*;
        c.next = null;
        buf[i] = c;
    }
    return buf;
}

/// token 链表 → slice
pub fn chainToSlice(arena: std.mem.Allocator, head: *Token) []const *Token {
    var list: std.ArrayList(*Token) = .empty;
    var cur: ?*Token = head;
    while (cur) |c| : (cur = c.next) {
        list.append(arena, c) catch unreachable;
    }
    return list.items;
}

/// 去掉反斜杠续行
pub fn stripLineSplices(arena: std.mem.Allocator, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "\\\n") == null) return src;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (src[i] == '\\' and i + 2 < src.len and src[i + 1] == '\r' and src[i + 2] == '\n') {
            i += 3;
            continue;
        }
        out.append(arena, src[i]) catch unreachable;
        i += 1;
    }
    return out.items;
}
