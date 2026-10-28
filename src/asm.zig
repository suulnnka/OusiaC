//! 汇编器:OusiaC 生成的 AT&T 汇编(.s)→ ELF64 可重定位目标文件(.o)
//!
//! 只支持 OusiaC 代码生成器输出的指令子集,不追求通用:
//!   - 寄存器:64/32/16/8 位(r8-r15 自动加 REX)
//!   - 内存操作数:disp(%rbp) / (%rax|%rdi|%rsi) / sym(%rip)
//!   - 跳转一律 rel32:同节局部标签直接 patch,其余发 PLT32 重定位
//!   - 伪指令:.text/.data/.bss/.section .rodata/.globl/.balign/.byte/.zero/.quad

const std = @import("std");

pub const AsmError = error{AsmError};

const R_X86_64_PC32 = 2;
const R_X86_64_PLT32 = 4;
const R_X86_64_64 = 1;

const Reg = struct { num: u8, size: u8 }; // num 0-15

fn lookupReg(name: []const u8) ?Reg {
    const map = [_]struct { n: []const u8, num: u8, size: u8 }{
        .{ .n = "%rax", .num = 0, .size = 8 },  .{ .n = "%rcx", .num = 1, .size = 8 },
        .{ .n = "%rdx", .num = 2, .size = 8 },  .{ .n = "%rbx", .num = 3, .size = 8 },
        .{ .n = "%rsp", .num = 4, .size = 8 },  .{ .n = "%rbp", .num = 5, .size = 8 },
        .{ .n = "%rsi", .num = 6, .size = 8 },  .{ .n = "%rdi", .num = 7, .size = 8 },
        .{ .n = "%r8", .num = 8, .size = 8 },   .{ .n = "%r9", .num = 9, .size = 8 },
        .{ .n = "%r10", .num = 10, .size = 8 }, .{ .n = "%r11", .num = 11, .size = 8 },
        .{ .n = "%r12", .num = 12, .size = 8 }, .{ .n = "%r13", .num = 13, .size = 8 },
        .{ .n = "%r14", .num = 14, .size = 8 }, .{ .n = "%r15", .num = 15, .size = 8 },
        .{ .n = "%eax", .num = 0, .size = 4 },  .{ .n = "%ecx", .num = 1, .size = 4 },
        .{ .n = "%edx", .num = 2, .size = 4 },  .{ .n = "%ebx", .num = 3, .size = 4 },
        .{ .n = "%esp", .num = 4, .size = 4 },  .{ .n = "%ebp", .num = 5, .size = 4 },
        .{ .n = "%esi", .num = 6, .size = 4 },  .{ .n = "%edi", .num = 7, .size = 4 },
        .{ .n = "%r8d", .num = 8, .size = 4 },  .{ .n = "%r9d", .num = 9, .size = 4 },
        .{ .n = "%ax", .num = 0, .size = 2 },   .{ .n = "%cx", .num = 1, .size = 2 },
        .{ .n = "%dx", .num = 2, .size = 2 },   .{ .n = "%si", .num = 6, .size = 2 },
        .{ .n = "%di", .num = 7, .size = 2 },   .{ .n = "%al", .num = 0, .size = 1 },
        .{ .n = "%cl", .num = 1, .size = 1 },   .{ .n = "%dl", .num = 2, .size = 1 },
        .{ .n = "%bl", .num = 3, .size = 1 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.n, name)) return .{ .num = m.num, .size = m.size };
    }
    return null;
}

const MemOperand = struct {
    base: ?u8 = null,
    disp: i64 = 0,
    rip_sym: ?[]const u8 = null,
};

const Operand = union(enum) {
    reg: Reg,
    mem: MemOperand,
    imm: i64,
    sym: []const u8,
};

const RelocOut = struct {
    offset: u64,
    type: u32,
    sym: []const u8,
    addend: i64,
};

const SymDef = struct {
    name: []const u8,
    sec: u8,
    offset: u64,
    global: bool = false,
};

const Fixup = struct {
    offset: u64,
    target: []const u8,
    line: u32,
};

const SEC_TEXT = 0;
const SEC_RODATA = 1;
const SEC_DATA = 2;
const SEC_BSS = 3;
const NSECS = 4;

pub const Assembler = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    secs: [NSECS]std.ArrayList(u8),
    sec_align: [NSECS]u32 = .{ 1, 1, 1, 1 },
    bss_size: u64 = 0,
    relocs: [NSECS]std.ArrayList(RelocOut),
    syms: std.ArrayList(SymDef),
    global_names: std.ArrayList([]const u8),
    fixups: std.ArrayList(Fixup),
    cur: u8 = SEC_TEXT,
    err_line: u32 = 0,

    fn fail(self: *Assembler, line: u32, comptime fmt: []const u8, args: anytype) AsmError {
        std.debug.print("{s}:{d}: oas error: ", .{ self.path, line });
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        return error.AsmError;
    }

    fn secOff(self: *Assembler, sec: u8) u64 {
        if (sec == SEC_BSS) return self.bss_size;
        return self.secs[sec].items.len;
    }

    fn emit(self: *Assembler, b: u8) void {
        self.secs[self.cur].append(self.arena, b) catch unreachable;
    }
    fn emit2(self: *Assembler, a: u8, b: u8) void {
        self.emit(a);
        self.emit(b);
    }
    fn emit3(self: *Assembler, a: u8, b: u8, c: u8) void {
        self.emit(a);
        self.emit(b);
        self.emit(c);
    }
    fn emitI32(self: *Assembler, v: i32) void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, v, .little);
        for (buf) |b| self.emit(b);
    }
    fn emitI64(self: *Assembler, v: i64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v, .little);
        for (buf) |b| self.emit(b);
    }

    /// REX 前缀:r = ModRM.reg 扩展,b = ModRM.r/m(基址)扩展
    fn rex(self: *Assembler, w: bool, r: u8, b: u8, force: bool) void {
        var v: u8 = 0x40;
        var need = force;
        if (w) {
            v |= 8;
            need = true;
        }
        if (r >= 8) {
            v |= 4;
            need = true;
        }
        if (b >= 8) {
            v |= 1;
            need = true;
        }
        if (need) self.emit(v);
    }

    /// ModRM + SIB/disp(内存)或 mod11(寄存器)。REX 由调用方先行输出。
    fn modrm(self: *Assembler, reg: u8, m: *const Operand) AsmError!void {
        switch (m.*) {
            .reg => |r| self.emit(0xC0 | ((reg & 7) << 3) | (r.num & 7)),
            .mem => |mem| {
                if (mem.rip_sym) |sym| {
                    self.emit(0x05 | ((reg & 7) << 3));
                    const off = self.secOff(self.cur);
                    self.emitI32(0);
                    self.relocs[self.cur].append(self.arena, .{
                        .offset = off,
                        .type = R_X86_64_PC32,
                        .sym = sym,
                        .addend = -4,
                    }) catch unreachable;
                    return;
                }
                const base = mem.base orelse return self.fail(self.err_line, "memory operand needs a base or (%rip)", .{});
                if (mem.disp == 0 and base != 4 and base != 5) {
                    self.emit(((reg & 7) << 3) | (base & 7));
                } else if (mem.disp >= -128 and mem.disp <= 127) {
                    self.emit(0x40 | ((reg & 7) << 3) | (base & 7));
                    self.emit(@bitCast(@as(i8, @intCast(mem.disp))));
                } else {
                    self.emit(0x80 | ((reg & 7) << 3) | (base & 7));
                    self.emitI32(@intCast(mem.disp));
                }
            },
            else => return self.fail(self.err_line, "expected register or memory operand", .{}),
        }
    }

    /// 内存操作数里 REX.B 对应的基址编号(rip 相对时为 0)
    fn memBase(m: *const Operand) u8 {
        return switch (m.*) {
            .mem => |mem| if (mem.rip_sym != null) 0 else (mem.base orelse 0),
            else => 0,
        };
    }

    // ---- 操作数解析 ----
    fn parseOperand(self: *Assembler, text: []const u8, line: u32) AsmError!Operand {
        var t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return self.fail(line, "empty operand", .{});
        if (t[0] == '*') t = std.mem.trim(u8, t[1..], " \t"); // AT&T 间接前缀(call *%rax)
        if (t.len == 0) return self.fail(line, "empty operand", .{});
        if (t[0] == '$') {
            const v = std.fmt.parseInt(i64, t[1..], 0) catch
                return self.fail(line, "bad immediate '{s}'", .{t});
            return .{ .imm = v };
        }
        if (t[0] == '%') {
            if (lookupReg(t)) |r| return .{ .reg = r };
            return self.fail(line, "unknown register '{s}'", .{t});
        }
        if (t[t.len - 1] == ')') {
            const open = std.mem.lastIndexOfScalar(u8, t, '(') orelse
                return self.fail(line, "bad memory operand '{s}'", .{t});
            const inside = t[open + 1 .. t.len - 1];
            const outside = std.mem.trim(u8, t[0..open], " \t");
            var mem = MemOperand{};
            if (std.mem.eql(u8, inside, "%rip")) {
                mem.rip_sym = outside;
            } else if (lookupReg(inside)) |b| {
                mem.base = b.num;
                if (outside.len > 0) {
                    mem.disp = std.fmt.parseInt(i64, outside, 0) catch
                        return self.fail(line, "bad displacement '{s}'", .{outside});
                }
            } else {
                return self.fail(line, "bad base register '{s}'", .{inside});
            }
            return .{ .mem = mem };
        }
        return .{ .sym = t };
    }

    fn splitOperands(self: *Assembler, rest: []const u8, line: u32, out: *[4]Operand) AsmError!usize {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |part| {
            if (n >= 4) return self.fail(line, "too many operands", .{});
            out[n] = try self.parseOperand(part, line);
            n += 1;
        }
        return n;
    }

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    // ---- 指令编码 ----
    fn encode(self: *Assembler, mnem: []const u8, ops: []const Operand, line: u32) AsmError!void {
        self.err_line = line;

        // 无操作数
        if (eq(mnem, "ret")) return self.emit(0xC3);
        if (eq(mnem, "cld")) return self.emit(0xFC);
        if (eq(mnem, "cqto")) return self.emit2(0x48, 0x99);
        if (eq(mnem, "cltd")) return self.emit(0x99);
        if (eq(mnem, "movsb")) return self.emit2(0xF3, 0xA4); // rep movsb
        if (eq(mnem, "stosb")) return self.emit2(0xF3, 0xAA); // rep stosb

        // push/pop
        if (eq(mnem, "push") or eq(mnem, "pop")) {
            if (ops.len != 1 or ops[0] != .reg)
                return self.fail(line, "{s}: one register operand expected", .{mnem});
            const r = ops[0].reg;
            if (r.size != 8) return self.fail(line, "{s}: 64-bit register expected", .{mnem});
            if (r.num >= 8) self.emit(0x41);
            self.emit(if (eq(mnem, "push")) 0x50 + (r.num & 7) else 0x58 + (r.num & 7));
            return;
        }

        // 跳转
        if (mnem[0] == 'j' and (eq(mnem, "jmp") or eq(mnem, "je") or eq(mnem, "jne") or
            eq(mnem, "jl") or eq(mnem, "jle") or eq(mnem, "jg") or eq(mnem, "jge") or
            eq(mnem, "jb") or eq(mnem, "jbe") or eq(mnem, "ja") or eq(mnem, "jae")))
        {
            if (ops.len != 1 or ops[0] != .sym)
                return self.fail(line, "{s}: label operand expected", .{mnem});
            if (eq(mnem, "jmp")) {
                self.emit(0xE9);
            } else {
                const cc: u8 = if (eq(mnem, "je")) 0x84 else if (eq(mnem, "jne")) 0x85 else if (eq(mnem, "jl")) 0x8C else if (eq(mnem, "jle")) 0x8E else if (eq(mnem, "jg")) 0x8F else if (eq(mnem, "jge")) 0x8D else if (eq(mnem, "jb")) 0x82 else if (eq(mnem, "jbe")) 0x86 else if (eq(mnem, "ja")) 0x87 else 0x83;
                self.emit2(0x0F, cc);
            }
            const off = self.secOff(SEC_TEXT);
            self.emitI32(0);
            self.fixups.append(self.arena, .{ .offset = off, .target = ops[0].sym, .line = line }) catch unreachable;
            return;
        }

        // call
        if (eq(mnem, "call")) {
            if (ops.len != 1) return self.fail(line, "call: one operand expected", .{});
            switch (ops[0]) {
                .sym => |s| {
                    self.emit(0xE8);
                    const off = self.secOff(SEC_TEXT);
                    self.emitI32(0);
                    self.relocs[SEC_TEXT].append(self.arena, .{
                        .offset = off, .type = R_X86_64_PLT32, .sym = s, .addend = -4,
                    }) catch unreachable;
                },
                .reg => |r| {
                    if (r.size != 8) return self.fail(line, "call*: 64-bit register expected", .{});
                    self.rex(false, 0, r.num, false);
                    self.emit2(0xFF, 0xD0 | (r.num & 7));
                },
                else => return self.fail(line, "call: bad operand", .{}),
            }
            return;
        }

        // mov / movabsq
        if (eq(mnem, "mov") or eq(mnem, "movabsq")) {
            if (ops.len != 2) return self.fail(line, "mov: two operands expected", .{});
            const src = &ops[0];
            const dst = &ops[1];
            if (eq(mnem, "movabsq")) {
                if (src.* != .imm or dst.* != .reg or dst.reg.size != 8)
                    return self.fail(line, "movabsq: $imm, %r64 expected", .{});
                self.rex(true, 0, dst.reg.num, true);
                self.emit(0xB8 + (dst.reg.num & 7));
                self.emitI64(src.imm);
                return;
            }
            if (src.* == .imm) {
                if (dst.* != .reg) return self.fail(line, "mov $imm: register destination expected", .{});
                const r = dst.reg;
                if (r.size == 8) {
                    self.rex(true, 0, r.num, false);
                    self.emit2(0xC7, 0xC0 | (r.num & 7));
                    self.emitI32(@intCast(src.imm));
                } else if (r.size == 4) {
                    self.rex(false, 0, r.num, false);
                    self.emit(0xB8 + (r.num & 7));
                    self.emitI32(@intCast(src.imm));
                } else return self.fail(line, "mov $imm: unsupported size", .{});
                return;
            }
            if (src.* == .reg) {
                const r = src.reg;
                const w = r.size == 8;
                const op: u8 = if (r.size == 1) 0x88 else 0x89;
                if (dst.* == .reg) {
                    if (dst.reg.size != r.size) return self.fail(line, "mov: operand size mismatch", .{});
                    self.rex(w, r.num, dst.reg.num, false);
                    self.emit(op);
                    try self.modrm(r.num, dst);
                    return;
                }
                if (dst.* == .mem) {
                    self.rex(w, r.num, memBase(dst), false);
                    self.emit(op);
                    try self.modrm(r.num, dst);
                    return;
                }
                return self.fail(line, "mov: bad destination", .{});
            }
            if (src.* == .mem) {
                if (dst.* != .reg) return self.fail(line, "mov mem: register destination expected", .{});
                const r = dst.reg;
                const w = r.size == 8;
                const op: u8 = if (r.size == 1) 0x8A else 0x8B;
                self.rex(w, r.num, memBase(src), false);
                self.emit(op);
                try self.modrm(r.num, src);
                return;
            }
            return self.fail(line, "mov: bad operands", .{});
        }

        // movsx / movzx 家族
        if (eq(mnem, "movsbl") or eq(mnem, "movzbl") or eq(mnem, "movswl") or
            eq(mnem, "movzwl") or eq(mnem, "movsbq") or eq(mnem, "movswq") or
            eq(mnem, "movzbq") or eq(mnem, "movzwq"))
        {
            if (ops.len != 2 or ops[1] != .reg)
                return self.fail(line, "{s}: register destination expected", .{mnem});
            const q = mnem[mnem.len - 1] == 'q';
            const op2: u8 = if (mnem[3] == 's') (if (mnem[4] == 'b') @as(u8, 0xBE) else 0xBF) else (if (mnem[4] == 'b') @as(u8, 0xB6) else 0xB7);
            const r = ops[1].reg;
            self.rex(q, r.num, memBase(&ops[0]), q);
            self.emit2(0x0F, op2);
            try self.modrm(r.num, &ops[0]);
            return;
        }
        if (eq(mnem, "movslq")) {
            if (ops.len != 2 or ops[0] != .reg or ops[1] != .reg)
                return self.fail(line, "movslq: register operands expected", .{});
            const s = ops[0].reg;
            const d = ops[1].reg;
            if (s.size != 4 or d.size != 8) return self.fail(line, "movslq: r32 -> r64 expected", .{});
            self.rex(true, d.num, s.num, true);
            self.emit(0x63);
            self.emit(0xC0 | ((d.num & 7) << 3) | (s.num & 7));
            return;
        }

        // lea
        if (eq(mnem, "lea")) {
            if (ops.len != 2 or ops[1] != .reg or ops[1].reg.size != 8)
                return self.fail(line, "lea: mem, %r64 expected", .{});
            const r = ops[1].reg;
            self.rex(true, r.num, memBase(&ops[0]), false);
            self.emit(0x8D);
            try self.modrm(r.num, &ops[0]);
            return;
        }

        // 二元运算组:add/or/and/sub/xor/cmp(可带 q/l 后缀)
        {
            const G = struct { op: []const u8, opq: []const u8, opl: []const u8, rm_r: u8, ext: u8 };
            const g1 = [_]G{
                .{ .op = "add", .opq = "addq", .opl = "addl", .rm_r = 0x01, .ext = 0 },
                .{ .op = "or", .opq = "orq", .opl = "orl", .rm_r = 0x09, .ext = 1 },
                .{ .op = "and", .opq = "andq", .opl = "andl", .rm_r = 0x21, .ext = 4 },
                .{ .op = "sub", .opq = "subq", .opl = "subl", .rm_r = 0x29, .ext = 5 },
                .{ .op = "xor", .opq = "xorq", .opl = "xorl", .rm_r = 0x31, .ext = 6 },
                .{ .op = "cmp", .opq = "cmpq", .opl = "cmpl", .rm_r = 0x39, .ext = 7 },
            };
            for (g1) |g| {
                var size: u8 = 0;
                if (eq(mnem, g.opq)) size = 8;
                if (eq(mnem, g.opl)) size = 4;
                if (size == 0 and !eq(mnem, g.op)) continue;
                if (ops.len != 2) return self.fail(line, "{s}: two operands expected", .{g.op});
                if (size == 0) {
                    if (ops[1] == .reg) size = ops[1].reg.size else if (ops[0] == .reg) size = ops[0].reg.size else return self.fail(line, "{s}: cannot infer operand size", .{g.op});
                }
                const w = size == 8;
                if (ops[0] == .imm) {
                    if (ops[1] != .reg) return self.fail(line, "{s} $imm: register destination expected", .{g.op});
                    const r = ops[1].reg;
                    if (r.size != size) return self.fail(line, "{s}: operand size mismatch", .{g.op});
                    self.rex(w, 0, r.num, false);
                    self.emit(0x81);
                    self.emit(0xC0 | (g.ext << 3) | (r.num & 7));
                    self.emitI32(@intCast(ops[0].imm));
                    return;
                }
                if (ops[0] != .reg) return self.fail(line, "{s}: register source expected", .{g.op});
                const r = ops[0].reg;
                if (r.size != size) return self.fail(line, "{s}: operand size mismatch", .{g.op});
                if (ops[1] == .reg) {
                    if (ops[1].reg.size != size) return self.fail(line, "{s}: operand size mismatch", .{g.op});
                    self.rex(w, r.num, ops[1].reg.num, false);
                    self.emit(g.rm_r);
                    self.emit(0xC0 | ((r.num & 7) << 3) | (ops[1].reg.num & 7));
                    return;
                }
                if (ops[1] == .mem) {
                    self.rex(w, r.num, memBase(&ops[1]), false);
                    self.emit(g.rm_r);
                    try self.modrm(r.num, &ops[1]);
                    return;
                }
                return self.fail(line, "{s}: bad destination", .{g.op});
            }
        }

        // imul
        if (eq(mnem, "imul") or eq(mnem, "imulq") or eq(mnem, "imull")) {
            if (ops.len != 2 or ops[0] != .reg or ops[1] != .reg)
                return self.fail(line, "imul: two register operands expected", .{});
            const s = ops[0].reg;
            const d = ops[1].reg;
            const size: u8 = if (eq(mnem, "imulq")) 8 else if (eq(mnem, "imull")) 4 else s.size;
            const w = size == 8;
            self.rex(w, d.num, s.num, false);
            self.emit2(0x0F, 0xAF);
            self.emit(0xC0 | ((d.num & 7) << 3) | (s.num & 7));
            return;
        }

        // F7 组:idiv/div/not/neg(q/l 后缀)
        {
            const F = struct { op: []const u8, opq: []const u8, opl: []const u8, ext: u8 };
            const f7 = [_]F{
                .{ .op = "idiv", .opq = "idivq", .opl = "idivl", .ext = 7 },
                .{ .op = "div", .opq = "divq", .opl = "divl", .ext = 6 },
                .{ .op = "not", .opq = "notq", .opl = "notl", .ext = 2 },
                .{ .op = "neg", .opq = "negq", .opl = "negl", .ext = 3 },
            };
            for (f7) |g| {
                var size: u8 = 0;
                if (eq(mnem, g.opq)) size = 8;
                if (eq(mnem, g.opl)) size = 4;
                if (size == 0 and !eq(mnem, g.op)) continue;
                if (ops.len != 1 or ops[0] != .reg)
                    return self.fail(line, "{s}: one register operand expected", .{mnem});
                const r = ops[0].reg;
                if (size == 0) size = r.size;
                const w = size == 8;
                self.rex(w, g.ext, r.num, false);
                self.emit(0xF7);
                self.emit(0xC0 | (g.ext << 3) | (r.num & 7));
                return;
            }
        }

        // 移位:sal/shl/sar/shr %cl, r(q/l 后缀)
        {
            const H = struct { op: []const u8, opq: []const u8, opl: []const u8, ext: u8 };
            const sh = [_]H{
                .{ .op = "sal", .opq = "salq", .opl = "sall", .ext = 4 },
                .{ .op = "shl", .opq = "shlq", .opl = "shll", .ext = 4 },
                .{ .op = "sar", .opq = "sarq", .opl = "sarl", .ext = 7 },
                .{ .op = "shr", .opq = "shrq", .opl = "shrl", .ext = 5 },
            };
            for (sh) |g| {
                var size: u8 = 0;
                if (eq(mnem, g.opq)) size = 8;
                if (eq(mnem, g.opl)) size = 4;
                if (size == 0 and !eq(mnem, g.op)) continue;
                if (ops.len != 2 or ops[0] != .reg or ops[0].reg.size != 1 or ops[1] != .reg)
                    return self.fail(line, "{s}: '%cl, reg' expected", .{mnem});
                const r = ops[1].reg;
                if (size == 0) size = r.size;
                const w = size == 8;
                self.rex(w, g.ext, r.num, false);
                self.emit(0xD3);
                self.emit(0xC0 | (g.ext << 3) | (r.num & 7));
                return;
            }
        }

        // setcc %r8
        if (mnem.len >= 4 and std.mem.startsWith(u8, mnem, "set")) {
            if (ops.len != 1 or ops[0] != .reg or ops[0].reg.size != 1)
                return self.fail(line, "{s}: byte register operand expected", .{mnem});
            const cc: u8 = if (eq(mnem, "sete")) 0x94 else if (eq(mnem, "setne")) 0x95 else if (eq(mnem, "setl")) 0x9C else if (eq(mnem, "setle")) 0x9E else if (eq(mnem, "setg")) 0x9F else if (eq(mnem, "setge")) 0x9D else if (eq(mnem, "setb")) 0x92 else if (eq(mnem, "setbe")) 0x96 else if (eq(mnem, "seta")) 0x97 else 0x93;
            const r = ops[0].reg;
            self.rex(false, 0, r.num, false);
            self.emit2(0x0F, cc);
            self.emit(0xC0 | (r.num & 7));
            return;
        }

        return self.fail(line, "unsupported instruction '{s}'", .{mnem});
    }

    // ---- 顶层:逐行 ----
    pub fn assemble(arena: std.mem.Allocator, src: []const u8, path: []const u8) AsmError![]u8 {
        var self = Assembler{
            .arena = arena,
            .path = path,
            .secs = .{ .empty, .empty, .empty, .empty },
            .relocs = .{ .empty, .empty, .empty, .empty },
            .syms = .empty,
            .global_names = .empty,
            .fixups = .empty,
        };

        var line: u32 = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| : (line += 1) {
            var text = raw;
            if (std.mem.indexOfScalar(u8, text, '#')) |c| text = text[0..c];
            var rest = std.mem.trim(u8, text, " \t\r");
            if (rest.len == 0) continue;

            // 标签(一行可能多个)
            while (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
                const name = std.mem.trim(u8, rest[0..colon], " \t");
                if (name.len == 0 or lookupReg(name) != null) break;
                self.syms.append(arena, .{
                    .name = name,
                    .sec = self.cur,
                    .offset = self.secOff(self.cur),
                }) catch unreachable;
                rest = std.mem.trim(u8, rest[colon + 1 ..], " \t");
            }
            if (rest.len == 0) continue;

            // 伪指令
            if (rest[0] == '.') {
                var parts = std.mem.splitScalar(u8, rest, ' ');
                const dir = parts.first();
                const arg = std.mem.trim(u8, parts.rest(), " \t");
                if (eq(dir, ".text")) {
                    self.cur = SEC_TEXT;
                } else if (eq(dir, ".data")) {
                    self.cur = SEC_DATA;
                } else if (eq(dir, ".bss")) {
                    self.cur = SEC_BSS;
                } else if (eq(dir, ".section")) {
                    if (eq(arg, ".rodata")) {
                        self.cur = SEC_RODATA;
                    } else {
                        return self.fail(line, "unsupported section '{s}'", .{arg});
                    }
                } else if (eq(dir, ".globl")) {
                    self.global_names.append(arena, arg) catch unreachable;
                } else if (eq(dir, ".balign")) {
                    const n = std.fmt.parseInt(u32, arg, 0) catch
                        return self.fail(line, "bad .balign '{s}'", .{arg});
                    self.sec_align[self.cur] = @max(self.sec_align[self.cur], n);
                    if (self.cur == SEC_BSS) {
                        self.bss_size = (self.bss_size + n - 1) / n * n;
                    } else {
                        while (self.secs[self.cur].items.len % n != 0) self.emit(0);
                    }
                } else if (eq(dir, ".zero")) {
                    const n = std.fmt.parseInt(u64, arg, 0) catch
                        return self.fail(line, "bad .zero '{s}'", .{arg});
                    if (self.cur == SEC_BSS) {
                        self.bss_size += n;
                    } else {
                        for (0..n) |_| self.emit(0);
                    }
                } else if (eq(dir, ".byte")) {
                    var bv = std.mem.splitScalar(u8, arg, ',');
                    while (bv.next()) |b| {
                        const v = std.fmt.parseInt(u8, std.mem.trim(u8, b, " \t"), 0) catch
                            return self.fail(line, "bad .byte value", .{});
                        self.emit(v);
                    }
                } else if (eq(dir, ".quad")) {
                    try self.assembleQuad(arg, line);
                } else {
                    return self.fail(line, "unsupported directive '{s}'", .{dir});
                }
                continue;
            }

            // 指令
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const mnem = rest[0..sp];
            const ops_text = std.mem.trim(u8, rest[sp..], " \t");
            var ops: [4]Operand = undefined;
            const n = if (ops_text.len == 0) 0 else try self.splitOperands(ops_text, line, &ops);
            if (eq(mnem, "rep") and n == 1) {
                // rep movsb / rep stosb
                if (ops[0] == .sym) {
                    try self.encode(ops[0].sym, &.{}, line);
                    continue;
                }
                return self.fail(line, "rep: expected movsb/stosb", .{});
            }
            try self.encode(mnem, ops[0..n], line);
        }

        // patch 同节跳转
        for (self.fixups.items) |fx| {
            var found = false;
            for (self.syms.items) |s| {
                if (s.sec == SEC_TEXT and eq(s.name, fx.target)) {
                    const rel: i64 = @as(i64, @intCast(s.offset)) - @as(i64, @intCast(fx.offset)) - 4;
                    std.mem.writeInt(i32, self.secs[SEC_TEXT].items[fx.offset..][0..4], @intCast(rel), .little);
                    found = true;
                    break;
                }
            }
            if (!found) return self.fail(fx.line, "undefined local label '{s}'", .{fx.target});
        }

        // 标记全局符号
        for (self.global_names.items) |g| {
            var found = false;
            for (self.syms.items) |*s| {
                if (eq(s.name, g)) {
                    s.global = true;
                    found = true;
                }
            }
            if (!found) return self.fail(0, ".globl on undefined symbol '{s}'", .{g});
        }

        return self.writeElf(arena);
    }

    fn assembleQuad(self: *Assembler, arg: []const u8, line: u32) AsmError!void {
        if (arg.len > 0 and (std.ascii.isDigit(arg[0]) or arg[0] == '-')) {
            const v = std.fmt.parseInt(i64, arg, 0) catch
                return self.fail(line, "bad .quad value '{s}'", .{arg});
            self.emitI64(v);
            return;
        }
        var sym = arg;
        var addend: i64 = 0;
        if (std.mem.lastIndexOfScalar(u8, arg, '+')) |plus| {
            sym = std.mem.trim(u8, arg[0..plus], " \t");
            addend = std.fmt.parseInt(i64, std.mem.trim(u8, arg[plus + 1 ..], " \t"), 0) catch
                return self.fail(line, "bad .quad addend", .{});
        } else if (std.mem.lastIndexOfScalar(u8, arg, '-')) |minus| {
            sym = std.mem.trim(u8, arg[0..minus], " \t");
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, arg[minus + 1 ..], " \t"), 0) catch
                return self.fail(line, "bad .quad addend", .{});
            addend = -v;
        }
        const off = self.secOff(self.cur);
        self.emitI64(0);
        self.relocs[self.cur].append(self.arena, .{
            .offset = off, .type = R_X86_64_64, .sym = sym, .addend = addend,
        }) catch unreachable;
    }

    // ---- ELF64 REL 输出 ----
    fn writeElf(self: *Assembler, arena: std.mem.Allocator) AsmError![]u8 {
        var strtab: std.ArrayList(u8) = .empty;
        strtab.append(arena, 0) catch unreachable;
        var shstrtab: std.ArrayList(u8) = .empty;
        shstrtab.append(arena, 0) catch unreachable;

        const putStr = struct {
            fn f(list: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) u32 {
                const off: u32 = @intCast(list.items.len);
                list.appendSlice(a, s) catch unreachable;
                list.append(a, 0) catch unreachable;
                return off;
            }
        }.f;

        // 节名一次性预置
        const n_text = putStr(&shstrtab, arena, ".text");
        const n_rodata = putStr(&shstrtab, arena, ".rodata");
        const n_data = putStr(&shstrtab, arena, ".data");
        const n_bss = putStr(&shstrtab, arena, ".bss");
        const n_symtab = putStr(&shstrtab, arena, ".symtab");
        const n_strtab = putStr(&shstrtab, arena, ".strtab");
        const n_rela: [4]u32 = .{
            putStr(&shstrtab, arena, ".rela.text"),
            putStr(&shstrtab, arena, ".rela.rodata"),
            putStr(&shstrtab, arena, ".rela.data"),
            0,
        };
        const n_shstrtab = putStr(&shstrtab, arena, ".shstrtab");

        // 收集引用的外部符号
        var ext: std.ArrayList([]const u8) = .empty;
        for (self.relocs) |rl| {
            for (rl.items) |r| {
                var defined = false;
                for (self.syms.items) |s| {
                    if (eq(s.name, r.sym)) {
                        defined = true;
                        break;
                    }
                }
                if (!defined) {
                    var seen = false;
                    for (ext.items) |e| {
                        if (eq(e, r.sym)) seen = true;
                    }
                    if (!seen) ext.append(arena, r.sym) catch unreachable;
                }
            }
        }

        // 符号表:NULL + 局部 + 全局(定义)+ 外部引用
        const SymEntry = struct {
            name_off: u32,
            info: u8,
            shndx: u16,
            value: u64,
        };
        var symtab: std.ArrayList(SymEntry) = .empty;
        symtab.append(arena, .{ .name_off = 0, .info = 0, .shndx = 0, .value = 0 }) catch unreachable;

        var nlocals: u32 = 1;
        for (self.syms.items) |s| {
            if (s.global) continue;
            symtab.append(arena, .{
                .name_off = putStr(&strtab, arena, s.name),
                .info = 0,
                .shndx = s.sec + 1,
                .value = s.offset,
            }) catch unreachable;
            nlocals += 1;
        }
        const global_base: u32 = @intCast(symtab.items.len);
        for (self.syms.items, 0..) |s, i| {
            if (!s.global) continue;
            _ = i;
            symtab.append(arena, .{
                .name_off = putStr(&strtab, arena, s.name),
                .info = 0x10,
                .shndx = s.sec + 1,
                .value = s.offset,
            }) catch unreachable;
        }
        for (ext.items) |e| {
            symtab.append(arena, .{
                .name_off = putStr(&strtab, arena, e),
                .info = 0x10,
                .shndx = 0,
                .value = 0,
            }) catch unreachable;
        }

        // 名字 → 符号表索引(顺序必须与上面发射一致)
        const symIndex = struct {
            fn f(syms: []const SymDef, exts: []const []const u8, name: []const u8) ?u32 {
                var idx: u32 = 1;
                for (syms) |s| {
                    if (!s.global) {
                        if (eq(s.name, name)) return idx;
                        idx += 1;
                    }
                }
                for (syms) |s| {
                    if (s.global) {
                        if (eq(s.name, name)) return idx;
                        idx += 1;
                    }
                }
                for (exts, 0..) |e, i| {
                    if (eq(e, name)) return @intCast(idx + i);
                }
                return null;
            }
        }.f;

        // rela 列表
        const RelaE = struct { off: u64, info: u64, addend: i64 };
        var rela: [NSECS]std.ArrayList(RelaE) = .{ .empty, .empty, .empty, .empty };
        for (self.relocs, 0..) |rl, si| {
            for (rl.items) |r| {
                const idx = symIndex(self.syms.items, ext.items, r.sym) orelse
                    return self.fail(0, "internal: '{s}' not in symtab", .{r.sym});
                rela[si].append(arena, .{
                    .off = r.offset,
                    .info = (@as(u64, idx) << 32) | r.type,
                    .addend = r.addend,
                }) catch unreachable;
            }
        }

        // ---- 文件布局 ----
        var out: std.ArrayList(u8) = .empty;
        out.appendNTimes(arena, 0, 64) catch unreachable; // ELF 头占位

        var sec_off: [NSECS]u64 = .{ 0, 0, 0, 0 };
        for (0..NSECS) |i| {
            if (i == SEC_BSS or self.secs[i].items.len == 0) continue;
            while (out.items.len % 8 != 0) out.append(arena, 0) catch unreachable;
            sec_off[i] = out.items.len;
            out.appendSlice(arena, self.secs[i].items) catch unreachable;
        }

        var rela_off: [NSECS]u64 = .{ 0, 0, 0, 0 };
        for (0..NSECS) |i| {
            if (rela[i].items.len == 0) continue;
            while (out.items.len % 8 != 0) out.append(arena, 0) catch unreachable;
            rela_off[i] = out.items.len;
            for (rela[i].items) |r| {
                var buf: [24]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], r.off, .little);
                std.mem.writeInt(u64, buf[8..16], r.info, .little);
                std.mem.writeInt(i64, buf[16..24], r.addend, .little);
                out.appendSlice(arena, &buf) catch unreachable;
            }
        }

        while (out.items.len % 8 != 0) out.append(arena, 0) catch unreachable;
        const symtab_off = out.items.len;
        for (symtab.items) |s| {
            var buf: [24]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], s.name_off, .little);
            buf[4] = s.info;
            buf[5] = 0;
            std.mem.writeInt(u16, buf[6..8], s.shndx, .little);
            std.mem.writeInt(u64, buf[8..16], s.value, .little);
            std.mem.writeInt(u64, buf[16..24], 0, .little);
            out.appendSlice(arena, &buf) catch unreachable;
        }
        const symtab_size = symtab.items.len * 24;
        const strtab_off = out.items.len;
        out.appendSlice(arena, strtab.items) catch unreachable;

        const shstrtab_off = out.items.len;
        out.appendSlice(arena, shstrtab.items) catch unreachable;

        while (out.items.len % 8 != 0) out.append(arena, 0) catch unreachable;
        const shoff = out.items.len;

        const putShdr = struct {
            fn f(o: *std.ArrayList(u8), a: std.mem.Allocator, name: u32, typ: u32, flags: u64, off: u64, size: u64, link: u32, info: u32, align_: u64, entsize: u64) void {
                var b: [64]u8 = undefined;
                std.mem.writeInt(u32, b[0..4], name, .little);
                std.mem.writeInt(u32, b[4..8], typ, .little);
                std.mem.writeInt(u64, b[8..16], flags, .little);
                std.mem.writeInt(u64, b[16..24], 0, .little);
                std.mem.writeInt(u64, b[24..32], off, .little);
                std.mem.writeInt(u64, b[32..40], size, .little);
                std.mem.writeInt(u32, b[40..44], link, .little);
                std.mem.writeInt(u32, b[44..48], info, .little);
                std.mem.writeInt(u64, b[48..56], align_, .little);
                std.mem.writeInt(u64, b[56..64], entsize, .little);
                o.appendSlice(a, &b) catch unreachable;
            }
        }.f;

        var nrela: usize = 0;
        for (0..NSECS) |i| {
            if (rela[i].items.len > 0) nrela += 1;
        }
        const total_shdrs: u16 = @intCast(7 + nrela + 1); // NULL+4+symtab+strtab+rela*+shstrtab

        // [0] NULL
        putShdr(&out, arena, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        // [1..4]
        const sec_flags = [_]u64{ 0x006, 0x002, 0x003, 0x083 };
        const names4 = [_]u32{ n_text, n_rodata, n_data, n_bss };
        for (0..NSECS) |i| {
            const size = if (i == SEC_BSS) self.bss_size else self.secs[i].items.len;
            const typ: u32 = if (i == SEC_BSS) 8 else 1;
            putShdr(&out, arena, names4[i], typ, sec_flags[i], sec_off[i], size, 0, 0, self.sec_align[i], 0);
        }
        // [5] .symtab [6] .strtab
        putShdr(&out, arena, n_symtab, 2, 0, symtab_off, symtab_size, 6, nlocals, 8, 24);
        putShdr(&out, arena, n_strtab, 3, 0, strtab_off, strtab.items.len, 0, 0, 1, 0);
        // [7..] rela
        for (0..NSECS) |i| {
            if (rela[i].items.len == 0) continue;
            putShdr(&out, arena, n_rela[i], 4, 0, rela_off[i], rela[i].items.len * 24, 5, @intCast(i + 1), 8, 24);
        }
        // 最后 .shstrtab
        putShdr(&out, arena, n_shstrtab, 3, 0, shstrtab_off, shstrtab.items.len, 0, 0, 1, 0);
        _ = global_base;

        // ELF 头(偏移严格按 ELF64 定义)
        const hdr = out.items[0..64];
        hdr[0] = 0x7F;
        @memcpy(hdr[1..4], "ELF");
        hdr[4] = 2; // ELFCLASS64
        hdr[5] = 1; // 小端
        hdr[6] = 1; // EV_CURRENT
        std.mem.writeInt(u16, hdr[16..18], 1, .little); // e_type = ET_REL
        std.mem.writeInt(u16, hdr[18..20], 0x3E, .little); // e_machine = x86-64
        std.mem.writeInt(u32, hdr[20..24], 1, .little); // e_version
        std.mem.writeInt(u64, hdr[24..32], 0, .little); // e_entry
        std.mem.writeInt(u64, hdr[32..40], 0, .little); // e_phoff
        std.mem.writeInt(u64, hdr[40..48], shoff, .little); // e_shoff
        std.mem.writeInt(u32, hdr[48..52], 0, .little); // e_flags
        std.mem.writeInt(u16, hdr[52..54], 64, .little); // e_ehsize
        std.mem.writeInt(u16, hdr[54..56], 0, .little); // e_phentsize
        std.mem.writeInt(u16, hdr[56..58], 0, .little); // e_phnum
        std.mem.writeInt(u16, hdr[58..60], 64, .little); // e_shentsize
        std.mem.writeInt(u16, hdr[60..62], total_shdrs, .little); // e_shnum
        std.mem.writeInt(u16, hdr[62..64], @intCast(total_shdrs - 1), .little); // e_shstrndx

        return out.items;
    }
};
