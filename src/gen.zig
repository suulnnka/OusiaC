//! x86-64 代码生成(System V ABI,AT&T 语法)
//!
//! 约定:
//!   - genExpr 的结果留在 %rax(表达式值;聚合类型/数组/函数为其地址)
//!   - 二元运算:rhs 求值后压栈,lhs 在 %rax,pop 到 %rdi,运算落回 %rax
//!   - 函数体内 push/pop 保持配平,调用点 %rsp 恒为 16 字节对齐

const std = @import("std");
const tk = @import("token.zig");
const ty = @import("type.zig");
const parse = @import("parse.zig");

const Obj = parse.Obj;
const Node = parse.Node;
const Type = ty.Type;
const errorAt = tk.errorAt;
const CompileError = tk.CompileError;

pub const Gen = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    counter: u32 = 0,
    cur_ret_label: []const u8 = "",
    cur_fn: ?*Obj = null,

    fn p(self: *Gen, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.arena, fmt, args) catch unreachable;
        self.out.appendSlice(self.arena, s) catch unreachable;
    }
    fn label(self: *Gen, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch unreachable;
    }
    fn newId(self: *Gen) u32 {
        self.counter += 1;
        return self.counter;
    }

    /// 入口:全局对象列表 → 汇编文本
    pub fn run(arena: std.mem.Allocator, globals: []const *Obj) CompileError![]const u8 {
        var self = Gen{ .arena = arena };
        for (globals) |o| {
            if (o.is_function and o.is_definition) {
                try self.genFunction(o);
            }
        }
        try self.genData(globals);
        return self.out.items;
    }

    // ---------------- 函数 ----------------
    fn genFunction(self: *Gen, fn_obj: *Obj) CompileError!void {
        const ret_label = self.label(".L.return.{d}", .{self.newId()});
        self.cur_ret_label = ret_label;
        self.cur_fn = fn_obj;

        self.p("\n    .text\n", .{});
        if (!fn_obj.is_static) self.p("    .globl {s}\n", .{fn_obj.name});
        self.p("{s}:\n", .{fn_obj.name});
        self.p("    push %rbp\n", .{});
        self.p("    mov %rsp, %rbp\n", .{});
        if (fn_obj.stack_size > 0)
            self.p("    sub ${d}, %rsp\n", .{fn_obj.stack_size});

        // 前 6 个参数从寄存器存入栈槽(locals 前段即参数,槽统一 8 字节)
        const nparams = fn_obj.params.len;
        const arg_regs = [_][]const u8{ "%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9" };
        for (0..@min(nparams, 6)) |i| {
            if (i >= fn_obj.locals.items.len) break;
            const v = fn_obj.locals.items[i];
            if (v.pass_by_stack) continue;
            self.p("    mov {s}, {d}(%rbp)\n", .{ arg_regs[i], v.offset });
        }

        if (fn_obj.body) |body| try self.genStmt(body);

        // main 隐式 return 0(C99)
        if (std.mem.eql(u8, fn_obj.name, "main"))
            self.p("    mov $0, %eax\n", .{});
        self.p("{s}:\n", .{ret_label});
        self.p("    mov %rbp, %rsp\n", .{});
        self.p("    pop %rbp\n", .{});
        self.p("    ret\n", .{});
    }

    // ---------------- 语句 ----------------
    fn genStmt(self: *Gen, node: *Node) CompileError!void {
        switch (node.kind) {
            .block => {
                for (node.body) |s| try self.genStmt(s);
            },
            .expr_stmt => try self.genExpr(node.lhs.?),
            .return_ => {
                if (node.lhs) |e| try self.genExpr(e);
                self.p("    jmp {s}\n", .{self.cur_ret_label});
            },
            .if_ => {
                const id = self.newId();
                try self.genExpr(node.cond.?);
                self.p("    cmp $0, %rax\n    je .L.else.{d}\n", .{id});
                try self.genStmt(node.then.?);
                self.p("    jmp .L.end.{d}\n", .{id});
                self.p(".L.else.{d}:\n", .{id});
                if (node.els) |e| try self.genStmt(e);
                self.p(".L.end.{d}:\n", .{id});
            },
            .for_ => {
                const id = self.newId();
                if (node.init) |i| try self.genStmt(i);
                self.p(".L.begin.{d}:\n", .{id});
                if (node.cond) |c| {
                    try self.genExpr(c);
                    self.p("    cmp $0, %rax\n    je {s}\n", .{node.brk_label});
                }
                try self.genStmt(node.then.?);
                self.p("{s}:\n", .{node.cont_label});
                if (node.inc) |i| try self.genExpr(i);
                self.p("    jmp .L.begin.{d}\n", .{id});
                self.p("{s}:\n", .{node.brk_label});
            },
            .do_ => {
                const id = self.newId();
                self.p(".L.begin.{d}:\n", .{id});
                try self.genStmt(node.then.?);
                self.p("{s}:\n", .{node.cont_label});
                try self.genExpr(node.cond.?);
                self.p("    cmp $0, %rax\n    jne .L.begin.{d}\n", .{id});
                self.p("{s}:\n", .{node.brk_label});
            },
            .switch_ => {
                try self.genExpr(node.cond.?);
                const cond_ty = node.cond.?.ty.?;
                var c = node.case_next;
                while (c) |case_node| {
                    const cid = self.newId();
                    case_node.unique_label = self.label(".L.case.{d}", .{cid});
                    if (cond_ty.size == 4) {
                        self.p("    cmp ${d}, %eax\n", .{@as(i32, @truncate(case_node.val))});
                    } else if (case_node.val >= std.math.minInt(i32) and case_node.val <= std.math.maxInt(i32)) {
                        self.p("    cmp ${d}, %rax\n", .{case_node.val});
                    } else {
                        self.p("    movabsq ${d}, %rdi\n    cmp %rdi, %rax\n", .{case_node.val});
                    }
                    self.p("    je {s}\n", .{case_node.unique_label});
                    c = case_node.case_next;
                }
                if (node.default_case) |d| {
                    const did = self.newId();
                    d.unique_label = self.label(".L.case.{d}", .{did});
                    self.p("    jmp {s}\n", .{d.unique_label});
                } else {
                    self.p("    jmp {s}\n", .{node.brk_label});
                }
                try self.genStmt(node.then.?);
                self.p("{s}:\n", .{node.brk_label});
            },
            .case_ => {
                self.p("{s}:\n", .{node.unique_label});
                try self.genStmt(node.then.?);
            },
            .label_ => {
                self.p("{s}:\n", .{node.unique_label});
                try self.genStmt(node.then.?);
            },
            .goto_ => {
                self.p("    jmp {s}\n", .{node.unique_label});
            },
            else => try self.genExpr(node),
        }
    }

    // ---------------- 地址 ----------------
    fn genAddr(self: *Gen, node: *Node) CompileError!void {
        switch (node.kind) {
            .var_ => {
                const v = node.var_.?;
                if (v.is_local) {
                    self.p("    lea {d}(%rbp), %rax\n", .{v.offset});
                } else {
                    self.p("    lea {s}(%rip), %rax\n", .{v.sym()});
                }
            },
            .deref => try self.genExpr(node.lhs.?),
            .member => {
                try self.genAddr(node.lhs.?);
                if (node.member.?.offset != 0)
                    self.p("    add ${d}, %rax\n", .{node.member.?.offset});
            },
            .comma => {
                try self.genExpr(node.lhs.?);
                try self.genAddr(node.rhs.?);
            },
            else => return errorAt(node.tok, "not an lvalue (cannot take address)", .{}),
        }
    }

    /// 从 %rax 处按类型加载到 %rax
    fn load(self: *Gen, t: *Type) void {
        if (t.kind == .array or t.kind == .struct_ or t.kind == .union_ or t.kind == .func) return;
        switch (t.size) {
            1 => if (t.is_unsigned) self.p("    movzbl (%rax), %eax\n", .{}) else self.p("    movsbl (%rax), %eax\n", .{}),
            2 => if (t.is_unsigned) self.p("    movzwl (%rax), %eax\n", .{}) else self.p("    movswl (%rax), %eax\n", .{}),
            4 => self.p("    mov (%rax), %eax\n", .{}),
            8 => self.p("    mov (%rax), %rax\n", .{}),
            else => {},
        }
    }

    /// %rax 的值存到 %rdi 所指内存
    fn store(self: *Gen, t: *Type) void {
        switch (t.size) {
            1 => self.p("    mov %al, (%rdi)\n", .{}),
            2 => self.p("    mov %ax, (%rdi)\n", .{}),
            4 => self.p("    mov %eax, (%rdi)\n", .{}),
            8 => self.p("    mov %rax, (%rdi)\n", .{}),
            else => {},
        }
    }

    /// 类型大小对应的指令后缀(q/l)
    fn suf(t: *Type) []const u8 {
        return if (t.size == 8) "q" else "l";
    }
    /// 按类型大小选寄存器名
    fn rax(t: *Type) []const u8 {
        return if (t.size == 8) "%rax" else "%eax";
    }
    fn rdi(t: *Type) []const u8 {
        return if (t.size == 8) "%rdi" else "%edi";
    }

    // ---------------- 表达式 ----------------
    fn genExpr(self: *Gen, node: *Node) CompileError!void {
        switch (node.kind) {
            .num => {
                if (node.val >= std.math.minInt(i32) and node.val <= std.math.maxInt(i32)) {
                    self.p("    mov ${d}, %rax\n", .{node.val});
                } else {
                    self.p("    movabsq ${d}, %rax\n", .{node.val});
                }
            },
            .var_ => {
                const v = node.var_.?;
                if (v.is_enum_const) {
                    // 枚举常量:直接取值,无存储
                    if (v.enum_val >= std.math.minInt(i32) and v.enum_val <= std.math.maxInt(i32)) {
                        self.p("    mov ${d}, %rax\n", .{v.enum_val});
                    } else {
                        self.p("    movabsq ${d}, %rax\n", .{v.enum_val});
                    }
                    return;
                }
                try self.genAddr(node);
                self.load(node.ty.?);
            },
            .member => {
                try self.genAddr(node);
                self.load(node.ty.?);
            },
            .deref => {
                try self.genExpr(node.lhs.?);
                self.load(node.ty.?);
            },
            .addr => try self.genAddr(node.lhs.?),
            .assign => {
                const t = node.lhs.?.ty.?;
                try self.genAddr(node.lhs.?);
                self.p("    push %rax\n", .{});
                try self.genExpr(node.rhs.?);
                if (t.isAggregate()) {
                    // 结构体赋值:rdi=lhs 地址,rax=rhs 地址,rep movsb 拷贝
                    self.p("    mov %rax, %rsi\n", .{});
                    self.p("    pop %rdi\n", .{});
                    self.p("    mov ${d}, %rcx\n", .{t.size});
                    self.p("    cld\n    rep movsb\n", .{});
                } else {
                    self.p("    pop %rdi\n", .{});
                    self.store(t);
                }
            },
            .memzero => {
                const v = node.var_.?;
                if (v.is_local) {
                    self.p("    lea {d}(%rbp), %rdi\n", .{v.offset});
                } else {
                    self.p("    lea {s}(%rip), %rdi\n", .{v.sym()});
                }
                self.p("    mov ${d}, %rcx\n    xor %eax, %eax\n    cld\n    rep stosb\n", .{v.ty.size});
            },
            .cast => {
                try self.genExpr(node.lhs.?);
                self.genCast(node.lhs.?.ty.?, node.cast_ty.?);
            },
            .comma => {
                try self.genExpr(node.lhs.?);
                try self.genExpr(node.rhs.?);
            },
            .cond => {
                const id = self.newId();
                try self.genExpr(node.cond.?);
                self.p("    cmp $0, %rax\n    je .L.else.{d}\n", .{id});
                try self.genExpr(node.then.?);
                self.p("    jmp .L.end.{d}\n", .{id});
                self.p(".L.else.{d}:\n", .{id});
                try self.genExpr(node.els.?);
                self.p(".L.end.{d}:\n", .{id});
            },
            .not => {
                try self.genExpr(node.lhs.?);
                self.p("    cmp $0, %rax\n    sete %al\n    movzbl %al, %eax\n", .{});
            },
            .bitnot => {
                try self.genExpr(node.lhs.?);
                self.p("    not{s} %rax\n", .{suf(node.ty.?)});
            },
            .neg => {
                try self.genExpr(node.lhs.?);
                self.p("    neg{s} %rax\n", .{suf(node.ty.?)});
            },
            .logand => {
                const id = self.newId();
                try self.genExpr(node.lhs.?);
                self.p("    cmp $0, %rax\n    je .L.false.{d}\n", .{id});
                try self.genExpr(node.rhs.?);
                self.p("    cmp $0, %rax\n    je .L.false.{d}\n", .{id});
                self.p("    mov $1, %eax\n    jmp .L.end.{d}\n", .{id});
                self.p(".L.false.{d}:\n    xor %eax, %eax\n", .{id});
                self.p(".L.end.{d}:\n", .{id});
            },
            .logor => {
                const id = self.newId();
                try self.genExpr(node.lhs.?);
                self.p("    cmp $0, %rax\n    jne .L.true.{d}\n", .{id});
                try self.genExpr(node.rhs.?);
                self.p("    cmp $0, %rax\n    jne .L.true.{d}\n", .{id});
                self.p("    xor %eax, %eax\n    jmp .L.end.{d}\n", .{id});
                self.p(".L.true.{d}:\n    mov $1, %eax\n", .{id});
                self.p(".L.end.{d}:\n", .{id});
            },
            .funcall => try self.genFuncall(node),
            .shl, .shr, .add, .sub, .mul, .div_, .mod, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le => {
                try self.genExpr(node.rhs.?);
                self.p("    push %rax\n", .{});
                try self.genExpr(node.lhs.?);
                self.p("    pop %rdi\n", .{});
                try self.genBinary(node);
            },
            else => return errorAt(node.tok, "internal: cannot generate expression of kind '{s}'", .{@tagName(node.kind)}),
        }
    }

    fn genCast(self: *Gen, from: *Type, to: *Type) void {
        if (to.kind == .void_) return;
        // 聚合/函数:值本身就是地址(退化语义),无需转换
        if (from.isAggregate() or from.kind == .func) return;
        if (to.size == from.size) return;
        if (to.size == 8) {
            switch (from.size) {
                1 => if (from.is_unsigned) {
                    self.p("    movzbq %al, %rax\n", .{});
                } else {
                    self.p("    movsbq %al, %rax\n", .{});
                },
                2 => if (from.is_unsigned) {
                    self.p("    movzwq %ax, %rax\n", .{});
                } else {
                    self.p("    movswq %ax, %rax\n", .{});
                },
                4 => if (from.is_unsigned) {
                    self.p("    mov %eax, %eax\n", .{});
                } else {
                    self.p("    movslq %eax, %rax\n", .{});
                },
                else => {},
            }
            return;
        }
        switch (to.size) {
            1 => self.p("    movzbl %al, %eax\n", .{}),
            2 => self.p("    movzwl %ax, %eax\n", .{}),
            4 => self.p("    mov %eax, %eax\n", .{}),
            else => {},
        }
    }

    /// 左右操作数分别在 %rax(lhs) 与 %rdi(rhs)
    fn genBinary(self: *Gen, node: *Node) CompileError!void {
        const t = node.ty.?;
        const s = suf(t);
        switch (node.kind) {
            .add => self.p("    add{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .sub => self.p("    sub{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .mul => self.p("    imul{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .div_, .mod => {
                if (t.is_unsigned) {
                    self.p("    xor %edx, %edx\n    div{s} {s}\n", .{ s, rdi(t) });
                } else {
                    if (t.size == 8) {
                        self.p("    cqto\n    idivq %rdi\n", .{});
                    } else {
                        self.p("    cltd\n    idivl %edi\n", .{});
                    }
                }
                if (node.kind == .mod)
                    self.p("    mov %edx, %eax\n", .{});
            },
            .bitand => self.p("    and{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .bitor => self.p("    or{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .bitxor => self.p("    xor{s} {s}, {s}\n", .{ s, rdi(t), rax(t) }),
            .shl => {
                const ls = suf(node.lhs.?.ty.?);
                self.p("    mov %rdi, %rcx\n    sal{s} %cl, {s}\n", .{ ls, rax(node.lhs.?.ty.?) });
            },
            .shr => {
                const lt = node.lhs.?.ty.?;
                const ls = suf(lt);
                if (lt.is_unsigned) {
                    self.p("    mov %rdi, %rcx\n    shr{s} %cl, {s}\n", .{ ls, rax(lt) });
                } else {
                    self.p("    mov %rdi, %rcx\n    sar{s} %cl, {s}\n", .{ ls, rax(lt) });
                }
            },
            .eq => self.p("    cmp{s} {s}, {s}\n    sete %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) }),
            .ne => self.p("    cmp{s} {s}, {s}\n    setne %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) }),
            .lt => if (node.lhs.?.ty.?.is_unsigned)
                self.p("    cmp{s} {s}, {s}\n    setb %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) })
            else
                self.p("    cmp{s} {s}, {s}\n    setl %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) }),
            .le => if (node.lhs.?.ty.?.is_unsigned)
                self.p("    cmp{s} {s}, {s}\n    setbe %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) })
            else
                self.p("    cmp{s} {s}, {s}\n    setle %al\n    movzbl %al, %eax\n", .{ s, rdi(t), rax(t) }),
            else => return errorAt(node.tok, "internal: bad binary node", .{}),
        }
    }

    fn genFuncall(self: *Gen, node: *Node) CompileError!void {
        const args = node.body;
        const nargs = args.len;
        const nreg: usize = @min(nargs, 6);
        const nstack: usize = nargs - nreg;
        const pad: usize = nstack & 1;

        // 先压栈传参(从最后一个到第 7 个,保证第 7 个在最上面;pad 在最深处)
        if (pad > 0) self.p("    sub $8, %rsp\n", .{});
        var i: usize = nargs;
        while (i > nreg) {
            i -= 1;
            try self.genExpr(args[i]);
            self.p("    push %rax\n", .{});
        }
        // 寄存器传参:从左到右求值压栈
        for (args[0..nreg]) |a| {
            try self.genExpr(a);
            self.p("    push %rax\n", .{});
        }
        // 逆序弹入参数寄存器:第 nreg-1 个在栈顶
        const arg_regs = [_][]const u8{ "%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9" };
        var k: usize = nreg;
        while (k > 0) {
            k -= 1;
            self.p("    pop {s}\n", .{arg_regs[k]});
        }
        if (node.func_ty.?.is_variadic)
            self.p("    mov $0, %eax\n", .{});

        if (node.call_direct.len > 0) {
            self.p("    call {s}\n", .{node.call_direct});
        } else {
            try self.genExpr(node.lhs.?);
            self.p("    call *%rax\n", .{});
        }
        if (nstack + pad > 0)
            self.p("    add ${d}, %rsp\n", .{8 * (nstack + pad)});
    }

    // ---------------- 数据 ----------------
    fn genData(self: *Gen, globals: []const *Obj) CompileError!void {
        for (globals) |o| {
            if (o.is_function or o.is_typedef or o.is_enum_const) continue;
            if (!o.is_definition) continue; // extern 声明
            if (o.is_str_lit) continue; // 稍后统一 .rodata

            if (o.init_data) |data| {
                self.p("\n    .data\n", .{});
                if (!o.is_static) self.p("    .globl {s}\n", .{o.name});
                self.p("    .balign {d}\n", .{o.ty.alignment});
                self.p("{s}:\n", .{o.sym()});
                try self.emitDataBytes(data, o.rel.items);
            } else {
                self.p("\n    .bss\n", .{});
                if (!o.is_static) self.p("    .globl {s}\n", .{o.name});
                self.p("    .balign {d}\n", .{o.ty.alignment});
                self.p("{s}:\n", .{o.sym()});
                self.p("    .zero {d}\n", .{o.ty.size});
            }
        }

        // 字符串字面量 → .rodata
        for (globals) |o| {
            if (!o.is_str_lit) continue;
            self.p("\n    .section .rodata\n", .{});
            self.p("    .balign {d}\n", .{o.ty.alignment});
            self.p("{s}:\n", .{o.sym()});
            const data = o.init_data orelse continue;
            try self.emitBytes(data);
            if (data.len == 0 or o.ty.size > data.len) {
                // 字符串对象自带结尾 NUL(init_data 已含);补齐剩余空间
                const rest = o.ty.size - data.len;
                if (rest > 0) {
                    self.p("    .zero {d}\n", .{rest});
                }
            }
        }
    }

    /// 带重定位的数据区发射:重定位处用 .quad label+addend
    fn emitDataBytes(self: *Gen, data: []const u8, rels: []const parse.Reloc) CompileError!void {
        if (rels.len == 0) {
            try self.emitBytes(data);
            return;
        }
        var sorted: [64]parse.Reloc = undefined;
        var rlist: []parse.Reloc = undefined;
        if (rels.len <= 64) {
            @memcpy(sorted[0..rels.len], rels);
            std.mem.sort(parse.Reloc, sorted[0..rels.len], {}, relocLess);
            rlist = sorted[0..rels.len];
        } else {
            rlist = self.arena.dupe(parse.Reloc, rels) catch unreachable;
            std.mem.sort(parse.Reloc, rlist, {}, relocLess);
        }

        var off: usize = 0;
        for (rlist) |r| {
            if (r.offset > off) try self.emitBytes(data[off..r.offset]);
            if (r.addend != 0) {
                self.p("    .quad {s}{d}\n", .{ r.label, r.addend });
            } else {
                self.p("    .quad {s}\n", .{r.label});
            }
            off = r.offset + 8;
        }
        if (off < data.len) try self.emitBytes(data[off..]);
    }

    fn relocLess(_: void, a: parse.Reloc, b: parse.Reloc) bool {
        return a.offset < b.offset;
    }

    /// 逐字节发射(.byte 列表)
    fn emitBytes(self: *Gen, data: []const u8) CompileError!void {
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(i + 16, data.len);
            self.p("    .byte ", .{});
            for (data[i..end], 0..) |b, j| {
                if (j > 0) self.p(",", .{});
                self.p("{d}", .{b});
            }
            self.p("\n", .{});
            i = end;
        }
    }
};
