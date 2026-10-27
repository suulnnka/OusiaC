//! Token 与词法分析器
//!
//! Token 是贯穿词法/预处理/解析三个阶段的公共数据结构。
//! 每个记录来源文件与行号,即使经过宏展开也能给出准确诊断。

const std = @import("std");

pub const CompileError = error{CompileError};

pub const TokenKind = enum { ident, punct, keyword, num, str, eof };

pub const SourceFile = struct {
    path: []const u8, // 打开时用的路径
    content: []const u8, // 去掉反斜杠续行后的内容
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8, // 原始拼写(指向 content 或宏替换生成的新串)
    file: *SourceFile,
    line: u32 = 0,
    line_start: usize = 0, // 行首在 content 中的偏移(诊断用)
    at_bol: bool = false, // 行首(preprocessor 判定指令用)
    has_space: bool = false, // 前面有空白(#字符串化保留间距用)
    num_val: ?i64 = null, // 字符字面量在词法阶段就转成数字
    str_data: []const u8 = &.{}, // 字符串字面量解码后的字节(不含结尾 NUL)
    next: ?*Token = null, // 词法阶段先串成链表,pp 结束后展平

    pub fn isPunct(t: *const Token, s: []const u8) bool {
        return t.kind == .punct and std.mem.eql(u8, t.text, s);
    }
    /// 名字匹配(标识符或关键字)
    pub fn isKw(t: *const Token, s: []const u8) bool {
        return (t.kind == .ident or t.kind == .keyword) and std.mem.eql(u8, t.text, s);
    }
};

/// 诊断:file:line: 消息 + 源码行 + 指示位置
pub fn errorAt(t: *const Token, comptime fmt: []const u8, args: anytype) CompileError {
    std.debug.print("{s}:{d}: error: ", .{ t.file.path, t.line });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
    printCaret(t);
    return error.CompileError;
}

/// 警告(不中断编译)
pub fn warnAt(t: *const Token, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}:{d}: warning: ", .{ t.file.path, t.line });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn printCaret(t: *const Token) void {
    if (t.line_start >= t.file.content.len) return;
    const content = t.file.content;
    var end = t.line_start;
    while (end < content.len and content[end] != '\n') end += 1;
    if (t.line_start == end) return;
    std.debug.print("  {s}\n", .{content[t.line_start..end]});
    // 指示列:token 起点若在本行内
    const tok_off = @intFromPtr(t.text.ptr) - @intFromPtr(content.ptr);
    if (tok_off >= t.line_start and tok_off <= end) {
        std.debug.print("  ", .{});
        var i = t.line_start;
        while (i < tok_off) : (i += 1) std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
    }
}

const keywords = [_][]const u8{
    "return", "if",      "else",   "for",   "while",   "int",     "char",
    "sizeof", "struct",  "union",  "typedef", "enum",  "static",  "goto",
    "do",     "break",   "continue", "switch", "case",  "default", "extern",
    "unsigned", "signed", "long",  "short", "void",    "const",   "volatile",
    "auto",   "register", "restrict", "inline", "__attribute__", "_Bool",
};

const punctuators = [_][]const u8{
    "<<=", ">>=", "...", "==", "!=", "<=", ">=", "->", "+=",
    "-=",  "*=",  "/=",  "++", "--", "%=", "&=", "|=", "^=",
    "&&",  "||",  "<<",  ">>", "##",
    "<", ">", "+", "-", "*", "/", "%", "&", "|", "^", "!", "?", ":",
    ";", ",", ".", "(", ")", "[", "]", "{", "}", "#", "=", "~",
};

pub const Lexer = struct {
    arena: std.mem.Allocator,
    file: *SourceFile,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    fn newToken(self: *Lexer, kind: TokenKind, start: usize, end: usize) *Token {
        const t = self.arena.create(Token) catch unreachable;
        t.* = .{
            .kind = kind,
            .text = self.src[start..end],
            .file = self.file,
            .line = self.line,
            .line_start = self.line_start,
        };
        return t;
    }

    fn mkEof(self: *Lexer) *Token {
        const t = self.newToken(.eof, self.pos, self.pos);
        t.at_bol = true;
        return t;
    }

    fn peekCh(self: *Lexer, off: usize) u8 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else 0;
    }

    pub const SpaceKind = enum { none, space, newline };

    /// 跳过空白与注释;越过换行时推进行号。
    fn skipSpace(self: *Lexer) SpaceKind {
        var kind: SpaceKind = .none;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.line_start = self.pos;
                kind = .newline;
            } else if (c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c) {
                self.pos += 1;
                if (kind == .none) kind = .space;
            } else if (c == '/' and self.peekCh(1) == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                if (kind == .none) kind = .space;
            } else if (c == '/' and self.peekCh(1) == '*') {
                const start_line = self.line;
                const start_pos = self.pos;
                self.pos += 2;
                while (true) {
                    if (self.pos + 1 >= self.src.len) {
                        var fake = self.newToken(.eof, start_pos, start_pos + 2);
                        fake.line = start_line;
                        _ = Lexer.reportUnclosed(fake) catch {};
                        return kind;
                    }
                    if (self.src[self.pos] == '\n') {
                        self.pos += 1;
                        self.line += 1;
                        self.line_start = self.pos;
                        kind = .newline;
                    } else if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    } else {
                        self.pos += 1;
                    }
                }
            } else break;
        }
        return kind;
    }

    fn reportUnclosed(t: *Token) CompileError {
        return errorAt(t, "unclosed block comment", .{});
    }

    fn isIdent1(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }
    fn isIdent2(c: u8) bool {
        return Lexer.isIdent1(c) or std.ascii.isDigit(c);
    }

    fn readIdent(self: *Lexer) *Token {
        const start = self.pos;
        while (self.pos < self.src.len and isIdent2(self.src[self.pos])) self.pos += 1;
        const text = self.src[start..self.pos];
        for (keywords) |kw| {
            if (std.mem.eql(u8, kw, text)) return self.newToken(.keyword, start, self.pos);
        }
        return self.newToken(.ident, start, self.pos);
    }

    fn isPpNumChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '.' or c == '_';
    }

    fn readNumber(self: *Lexer) *Token {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isPpNumChar(c)) {
                self.pos += 1;
            } else if ((c == '+' or c == '-') and self.pos > start and
                (self.src[self.pos - 1] == 'e' or self.src[self.pos - 1] == 'E' or
                    self.src[self.pos - 1] == 'p' or self.src[self.pos - 1] == 'P'))
            {
                self.pos += 1; // pp-number 里的指数符号(不支持浮点,仅为完整吞掉)
            } else break;
        }
        return self.newToken(.num, start, self.pos);
    }

    /// 解码转义序列;pos 指向反斜杠后的字符
    fn readEscape(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0'...'7' => blk: { // 八进制,最多 3 位
                var v: u32 = c - '0';
                var n: u32 = 0;
                while (n < 2 and self.pos < self.src.len and
                    self.src[self.pos] >= '0' and self.src[self.pos] <= '7')
                {
                    v = v * 8 + (self.src[self.pos] - '0');
                    self.pos += 1;
                    n += 1;
                }
                break :blk @truncate(v);
            },
            'x' => blk: {
                var v: u32 = 0;
                while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) {
                    v = v * 16 + (std.fmt.charToDigit(self.src[self.pos], 16) catch 0);
                    self.pos += 1;
                }
                break :blk @truncate(v);
            },
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'v' => 11,
            else => c, // \\ \' \" \? 及其他:字符本身
        };
    }

    fn readString(self: *Lexer) CompileError!*Token {
        // 相邻字符串字面量拼接;text 覆盖从第一个引号到最后一个引号的原文
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);
        const span_start = self.pos;
        var span_end: usize = self.pos;
        while (true) {
            std.debug.assert(self.src[self.pos] == '"');
            self.pos += 1;
            while (true) {
                if (self.pos >= self.src.len or self.src[self.pos] == '\n')
                    return errorAt(self.mkEof(), "unclosed string literal", .{});
                const c = self.src[self.pos];
                if (c == '"') {
                    self.pos += 1;
                    span_end = self.pos;
                    break;
                }
                if (c == '\\') {
                    self.pos += 1;
                    buf.append(self.arena, self.readEscape()) catch unreachable;
                } else {
                    buf.append(self.arena, c) catch unreachable;
                    self.pos += 1;
                }
            }
            // 跳过空白/注释看是否紧跟另一个字符串字面量
            const save_pos = self.pos;
            const save_line = self.line;
            const save_ls = self.line_start;
            _ = self.skipSpace();
            if (self.pos < self.src.len and self.src[self.pos] == '"') {
                continue;
            }
            self.pos = save_pos;
            self.line = save_line;
            self.line_start = save_ls;
            break;
        }
        const tok = self.newToken(.str, span_start, span_end);
        tok.str_data = self.arena.dupe(u8, buf.items) catch unreachable;
        return tok;
    }

    fn readChar(self: *Lexer) CompileError!*Token {
        const start = self.pos;
        self.pos += 1; // 跳过开头的 '
        var val: i64 = 0;
        while (true) {
            if (self.pos >= self.src.len or self.src[self.pos] == '\n')
                return errorAt(self.mkEof(), "unclosed char literal", .{});
            const c = self.src[self.pos];
            if (c == '\'') {
                self.pos += 1;
                break;
            }
            const b: u8 = if (c == '\\') blk: {
                self.pos += 1;
                break :blk self.readEscape();
            } else blk: {
                self.pos += 1;
                break :blk c;
            };
            val = (val << 8) | @as(i64, b); // 多字符字面量:实现定义,取按序拼接
        }
        const t = self.newToken(.num, start, self.pos);
        t.num_val = val;
        return t;
    }

    fn readPunct(self: *Lexer) *Token {
        const start = self.pos;
        for (punctuators) |p| {
            if (self.pos + p.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + p.len], p)) {
                self.pos += p.len;
                return self.newToken(.punct, start, self.pos);
            }
        }
        unreachable; // 调用方已保证
    }

    /// 词法分析整个文件,返回以 EOF 结尾的 token 链表
    pub fn tokenize(arena: std.mem.Allocator, file: *SourceFile) CompileError!*Token {
        var self = Lexer{
            .arena = arena,
            .file = file,
            .src = file.content,
        };
        var tail: ?*Token = null;
        var first: ?*Token = null;
        var at_bol = true;
        while (true) {
            const space_kind = self.skipSpace();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            var t: *Token = undefined;
            if (isIdent1(c)) {
                t = self.readIdent();
            } else if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peekCh(1)))) {
                t = self.readNumber();
            } else if (c == '"') {
                t = try self.readString();
            } else if (c == '\'') {
                t = try self.readChar();
            } else {
                var is_punct = false;
                for (punctuators) |p| {
                    if (self.pos + p.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + p.len], p)) {
                        is_punct = true;
                        break;
                    }
                }
                if (!is_punct) {
                    const bad = self.newToken(.eof, self.pos, self.pos + 1);
                    return errorAt(bad, "invalid character '{c}' (0x{x:0>2})", .{ c, c });
                }
                t = self.readPunct();
            }
            t.at_bol = at_bol or space_kind == .newline;
            t.has_space = space_kind != .none;
            at_bol = false;
            if (tail) |tl| tl.next = t else first = t;
            tail = t;
        }
        const eof = self.mkEof();
        eof.at_bol = true;
        if (tail) |tl| tl.next = eof else first = eof;
        return first orelse eof;
    }
};
