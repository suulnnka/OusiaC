//! 解析器:声明/类型/语句/表达式 → AST
//!
//! 结构上参考 chibicc:Obj 统一表示变量/函数/typedef/枚举常量,
//! Node 构造完后立即自底向上推导类型(ty 为 null 表示尚未推导或纯语句)。

const std = @import("std");
const tk = @import("token.zig");
const ty = @import("type.zig");

const Token = tk.Token;
const Type = ty.Type;
const Member = ty.Member;
const Param = ty.Param;
const errorAt = tk.errorAt;
const CompileError = tk.CompileError;

pub const Reloc = struct {
    offset: u32,
    label: []const u8,
    addend: i64,
};

pub const Obj = struct {
    name: []const u8,
    ty: *Type,
    tok: *Token,
    is_local: bool = false,

    /// 帧内偏移:<0 为 rbp 相对局部/寄存器参数;>0 为栈传参(rbp+16+8k)
    offset: i32 = 0,
    pass_by_stack: bool = false,

    is_function: bool = false,
    is_definition: bool = false,
    is_static: bool = false,
    is_tentative: bool = false,
    params: []const Param = &.{},
    body: ?*Node = null,
    locals: std.ArrayList(*Obj) = .empty,
    stack_size: u32 = 0,

    init_data: ?[]u8 = null, // 全局初始化镜像
    rel: std.ArrayList(Reloc) = .empty,
    is_str_lit: bool = false,

    is_typedef: bool = false,
    is_enum_const: bool = false,
    enum_val: i64 = 0,

    asm_name: []const u8 = "", // 汇编符号名;为空时用 name
    pub fn sym(o: *const Obj) []const u8 {
        return if (o.asm_name.len > 0) o.asm_name else o.name;
    }
};

pub const NodeKind = enum {
    add, sub, mul, div_, mod, bitand, bitor, bitxor, shl, shr,
    eq, ne, lt, le, gt, ge,
    logand, logor, not,
    assign, cond, comma,
    bitnot, neg,
    var_, member, addr, deref,
    cast, num,
    funcall,
    memzero,
    // 语句
    return_, if_, for_, do_, switch_, case_,
    block, expr_stmt,
    label_, goto_,
};

pub const Node = struct {
    kind: NodeKind,
    ty: ?*Type = null,
    tok: *Token,
    lhs: ?*Node = null,
    rhs: ?*Node = null,
    cond: ?*Node = null,
    then: ?*Node = null,
    els: ?*Node = null,
    init: ?*Node = null,
    inc: ?*Node = null,
    body: []const *Node = &.{}, // block 语句列表 / funcall 实参
    var_: ?*Obj = null,
    member: ?*const Member = null,
    val: i64 = 0,
    cast_ty: ?*Type = null, // cast 目标类型(constEval/gen 用)
    call_direct: []const u8 = "", // 直接调用符号名;空则经寄存器间接调用
    func_ty: ?*Type = null,
    label: []const u8 = "",
    unique_label: []const u8 = "",
    brk_label: []const u8 = "",
    cont_label: []const u8 = "",
    case_next: ?*Node = null,
    default_case: ?*Node = null,
    is_default: bool = false,
};

const Scope = struct {
    parent: ?*Scope = null,
    vars: std.StringHashMap(*Obj),
    tags: std.StringHashMap(*Type),

    fn create(arena: std.mem.Allocator, parent: ?*Scope) *Scope {
        const s = arena.create(Scope) catch unreachable;
        s.* = .{
            .parent = parent,
            .vars = std.StringHashMap(*Obj).init(arena),
            .tags = std.StringHashMap(*Type).init(arena),
        };
        return s;
    }
};

const VarAttr = struct {
    is_typedef: bool = false,
    is_static: bool = false,
    is_extern: bool = false,
    is_inline: bool = false,
};

const Decl = struct {
    ty: *Type,
    name: []const u8 = "",
    name_tok: ?*Token = null,
};

/// 初始化器树
const Initializer = struct {
    ty: *Type,
    tok: ?*Token = null,
    expr: ?*Node = null, // 标量叶子
    children: []Initializer = &.{},
    is_flexible: bool = false, // 不完整数组,长度由初始化内容决定
};

/// 设计器链:描述左值路径(var → [idx] → .member → ...)
const Desig = struct {
    next: ?*const Desig,
    idx: i64 = 0,
    member: ?*const Member = null,
    obj: *Obj,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    toks: []const *Token,
    pos: usize = 0,
    globals: *std.ArrayList(*Obj),
    scope: *Scope = undefined,
    cur_fn: ?*Obj = null,
    labels: std.StringHashMap(*Node) = undefined,
    gotos: std.ArrayList(*Node) = .empty,
    brk_label: []const u8 = "",
    cont_label: []const u8 = "",
    cur_switch: ?*Node = null,
    uniq: u32 = 0,

    // ---------------- token 游标 ----------------
    fn cur(self: *Parser) *Token {
        return self.toks[self.pos];
    }
    fn peekAt(self: *Parser, n: usize) *Token {
        const i = @min(self.pos + n, self.toks.len - 1);
        return self.toks[i];
    }
    fn next(self: *Parser) void {
        if (self.pos + 1 < self.toks.len) self.pos += 1;
    }
    fn consume(self: *Parser, s: []const u8) bool {
        if (self.cur().isPunct(s)) {
            self.next();
            return true;
        }
        return false;
    }
    fn expect(self: *Parser, s: []const u8) CompileError!void {
        if (!self.cur().isPunct(s))
            return errorAt(self.cur(), "expected '{s}' but found '{s}'", .{ s, self.cur().text });
        self.next();
    }
    fn nextIdent(self: *Parser) CompileError![]const u8 {
        if (self.cur().kind != .ident)
            return errorAt(self.cur(), "expected an identifier but found '{s}'", .{self.cur().text});
        const name = self.cur().text;
        self.next();
        return name;
    }
    fn newUniqueId(self: *Parser) u32 {
        self.uniq += 1;
        return self.uniq;
    }
    fn uniqueLabel(self: *Parser, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch unreachable;
    }

    // ---------------- 作用域 ----------------
    fn enterScope(self: *Parser) void {
        self.scope = Scope.create(self.arena, self.scope);
    }
    fn leaveScope(self: *Parser) void {
        self.scope = self.scope.parent.?;
    }
    fn findVar(self: *Parser, name: []const u8) ?*Obj {
        var s: ?*Scope = self.scope;
        while (s) |sc| : (s = sc.parent) {
            if (sc.vars.get(name)) |o| return o;
        }
        return null;
    }
    fn findTag(self: *Parser, name: []const u8) ?*Type {
        var s: ?*Scope = self.scope;
        while (s) |sc| : (s = sc.parent) {
            if (sc.tags.get(name)) |t| return t;
        }
        return null;
    }

    // ---------------- 类型推导 ----------------
    fn ensureTyped(self: *Parser, node: *Node) void {
        if (node.ty != null) return;
        if (node.lhs) |n| self.ensureTyped(n);
        if (node.rhs) |n| self.ensureTyped(n);
        if (node.cond) |n| self.ensureTyped(n);
        if (node.then) |n| self.ensureTyped(n);
        if (node.els) |n| self.ensureTyped(n);
        if (node.init) |n| self.ensureTyped(n);
        if (node.inc) |n| self.ensureTyped(n);
        self.addTypeInternal(node);
    }

    fn usualConv(self: *Parser, lp: **Node, rp: **Node) void {
        const common = ty.getCommonType(self.arena, lp.*.ty.?, rp.*.ty.?);
        if (common.kind == .ptr) {
            // 指针参与比较等:把整型一边转成指针
            if (lp.*.ty.?.kind != .ptr) lp.* = self.newCast(lp.*, common);
            if (rp.*.ty.?.kind != .ptr) rp.* = self.newCast(rp.*, common);
            return;
        }
        lp.* = self.newCast(lp.*, common);
        rp.* = self.newCast(rp.*, common);
    }

    fn addTypeInternal(self: *Parser, node: *Node) void {
        switch (node.kind) {
            .add, .sub, .mul, .div_, .mod, .bitand, .bitor, .bitxor => {
                self.usualConv(&node.lhs.?, &node.rhs.?);
                node.ty = ty.getCommonType(self.arena, node.lhs.?.ty.?, node.rhs.?.ty.?);
            },
            .neg, .bitnot => {
                node.lhs.? = self.newCast(node.lhs.?, ty.promote(self.arena, node.lhs.?.ty.?));
                node.ty = node.lhs.?.ty;
            },
            .shl, .shr => {
                node.lhs.? = self.newCast(node.lhs.?, ty.promote(self.arena, node.lhs.?.ty.?));
                node.ty = node.lhs.?.ty;
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                // a > b 转成 b < a,a >= b 转成 b <= a,gen 少两个分支
                if (node.kind == .gt or node.kind == .ge) {
                    const tmp = node.lhs.?;
                    node.lhs = node.rhs.?;
                    node.rhs = tmp;
                    node.kind = if (node.kind == .gt) .lt else .le;
                }
                self.usualConv(&node.lhs.?, &node.rhs.?);
                node.ty = &ty.ty_int;
            },
            .logand, .logor, .not => node.ty = &ty.ty_int,
            .assign => node.ty = node.lhs.?.ty,
            .cond => {
                const t = self.condCommonType(node.then.?.ty.?, node.els.?.ty.?);
                node.then.? = self.newCast(node.then.?, t);
                node.els.? = self.newCast(node.els.?, t);
                node.ty = t;
            },
            .comma => node.ty = node.rhs.?.ty,
            .var_ => node.ty = node.var_.?.ty,
            .member => node.ty = node.member.?.ty,
            .addr => {
                if (node.lhs.?.ty.?.kind == .array or node.lhs.?.ty.?.kind == .func)
                    node.ty = ty.ptrTo(self.arena, node.lhs.?.ty.?.base.?)
                else
                    node.ty = ty.ptrTo(self.arena, node.lhs.?.ty.?);
            },
            .deref => node.ty = node.lhs.?.ty.?.base,
            .cast => node.ty = node.cast_ty,
            .num, .funcall, .memzero => {},
            else => {}, // 语句节点
        }
    }

    fn condCommonType(self: *Parser, a: *Type, b: *Type) *Type {
        if (a.kind == .void_ or b.kind == .void_) return &ty.ty_void;
        if (a.isAggregate() or b.isAggregate()) {
            if (a.kind == b.kind and a.size == b.size) return a;
            return a; // 结构体条件表达式不支持,姑且取 a
        }
        return ty.getCommonType(self.arena, a, b);
    }

    // ---------------- Node 构造 ----------------
    fn newNode(self: *Parser, kind: NodeKind, tok: *Token) *Node {
        const n = self.arena.create(Node) catch unreachable;
        n.* = .{ .kind = kind, .tok = tok };
        return n;
    }

    fn newNum(self: *Parser, val: i64, tok: *Token) *Node {
        const n = self.newNode(.num, tok);
        n.val = val;
        n.ty = if (val >= std.math.minInt(i32) and val <= std.math.maxInt(i32)) &ty.ty_int else &ty.ty_long;
        return n;
    }

    fn newBinaryTyped(self: *Parser, kind: NodeKind, lhs: *Node, rhs: *Node, tok: *Token) *Node {
        const n = self.newNode(kind, tok);
        n.lhs = lhs;
        n.rhs = rhs;
        self.ensureTyped(lhs);
        self.ensureTyped(rhs);
        self.addTypeInternal(n);
        return n;
    }

    fn newUnaryTyped(self: *Parser, kind: NodeKind, lhs: *Node, tok: *Token) *Node {
        const n = self.newNode(kind, tok);
        n.lhs = lhs;
        self.ensureTyped(lhs);
        self.addTypeInternal(n);
        return n;
    }

    fn newCast(self: *Parser, e: *Node, t: *Type) *Node {
        if (e.ty != null and e.ty.? == t) return e;
        self.ensureTyped(e);
        const n = self.newNode(.cast, e.tok);
        n.lhs = e;
        n.cast_ty = t;
        n.ty = t;
        return n;
    }

    fn newAdd(self: *Parser, lhs: *Node, rhs: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(lhs);
        self.ensureTyped(rhs);
        const lt = lhs.ty.?;
        const rt = rhs.ty.?;
        if ((lt.kind == .ptr or lt.kind == .array) and lt.base != null and rt.isInteger()) {
            const scale = self.newNum(lt.base.?.size, tok);
            const scaled = self.newBinaryTyped(.mul, self.newCast(rhs, &ty.ty_long), scale, tok);
            return self.newBinaryTyped(.add, lhs, scaled, tok);
        }
        if (lt.isInteger() and (rt.kind == .ptr or rt.kind == .array) and rt.base != null) {
            const scale = self.newNum(rt.base.?.size, tok);
            const scaled = self.newBinaryTyped(.mul, self.newCast(lhs, &ty.ty_long), scale, tok);
            return self.newBinaryTyped(.add, rhs, scaled, tok);
        }
        if (lt.isInteger() and rt.isInteger())
            return self.newBinaryTyped(.add, lhs, rhs, tok);
        return errorAt(tok, "invalid operands to '+' ('{s}' and '{s}')", .{ @tagName(lt.kind), @tagName(rt.kind) });
    }

    fn newSub(self: *Parser, lhs: *Node, rhs: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(lhs);
        self.ensureTyped(rhs);
        const lt = lhs.ty.?;
        const rt = rhs.ty.?;
        if ((lt.kind == .ptr or lt.kind == .array) and lt.base != null and rt.isInteger()) {
            const scale = self.newNum(lt.base.?.size, tok);
            const scaled = self.newBinaryTyped(.mul, self.newCast(rhs, &ty.ty_long), scale, tok);
            return self.newBinaryTyped(.sub, lhs, scaled, tok);
        }
        if (lt.base != null and rt.base != null and (lt.kind == .ptr or lt.kind == .array) and (rt.kind == .ptr or rt.kind == .array)) {
            const diff = self.newBinaryTyped(.sub, lhs, rhs, tok);
            const scale = self.newNum(lt.base.?.size, tok);
            return self.newBinaryTyped(.div_, diff, scale, tok);
        }
        if (lt.isInteger() and rt.isInteger())
            return self.newBinaryTyped(.sub, lhs, rhs, tok);
        return errorAt(tok, "invalid operands to '-'", .{});
    }

    fn newDeref(self: *Parser, e: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(e);
        const t = e.ty.?;
        if (t.kind == .ptr and t.base != null) return self.newUnaryTyped(.deref, e, tok);
        if (t.kind == .array) return errorAt(tok, "cannot dereference an array value", .{});
        return errorAt(tok, "invalid pointer dereference", .{});
    }

    // ---------------- 常量表达式求值 ----------------
    pub fn constEval(node: *Node) ?i64 {
        switch (node.kind) {
            .num => return node.val,
            .var_ => {
                if (node.var_.?.is_enum_const) return node.var_.?.enum_val;
                return null;
            },
            .add => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                return a +% b;
            },
            .sub => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                return a -% b;
            },
            .mul => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                return a *% b;
            },
            .div_, .mod => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                if (b == 0) return null;
                if (node.lhs.?.ty.?.is_unsigned) {
                    const ua: u64 = @bitCast(a);
                    const ub: u64 = @bitCast(b);
                    return if (node.kind == .div_) @bitCast(ua / ub) else @bitCast(ua % ub);
                }
                return if (node.kind == .div_) @divTrunc(a, b) else @rem(a, b);
            },
            .bitand => return (constEval(node.lhs.?) orelse return null) & (constEval(node.rhs.?) orelse return null),
            .bitor => return (constEval(node.lhs.?) orelse return null) | (constEval(node.rhs.?) orelse return null),
            .bitxor => return (constEval(node.lhs.?) orelse return null) ^ (constEval(node.rhs.?) orelse return null),
            .shl => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                return a << @truncate(@as(u64, @bitCast(b)));
            },
            .shr => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                const sh: u6 = @truncate(@as(u64, @bitCast(b)));
                if (node.lhs.?.ty.?.is_unsigned)
                    return @bitCast(@as(u64, @bitCast(a)) >> sh);
                return a >> sh;
            },
            .eq => return @intFromBool((constEval(node.lhs.?) orelse return null) == (constEval(node.rhs.?) orelse return null)),
            .ne => return @intFromBool((constEval(node.lhs.?) orelse return null) != (constEval(node.rhs.?) orelse return null)),
            .lt => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                const u = node.lhs.?.ty.?.is_unsigned;
                return @intFromBool(if (u) @as(u64, @bitCast(a)) < @as(u64, @bitCast(b)) else a < b);
            },
            .le => {
                const a = constEval(node.lhs.?) orelse return null;
                const b = constEval(node.rhs.?) orelse return null;
                const u = node.lhs.?.ty.?.is_unsigned;
                return @intFromBool(if (u) @as(u64, @bitCast(a)) <= @as(u64, @bitCast(b)) else a <= b);
            },
            .logand => {
                const a = constEval(node.lhs.?) orelse return null;
                if (a == 0) return 0;
                return @intFromBool((constEval(node.rhs.?) orelse return null) != 0);
            },
            .logor => {
                const a = constEval(node.lhs.?) orelse return null;
                if (a != 0) return 1;
                return @intFromBool((constEval(node.rhs.?) orelse return null) != 0);
            },
            .not => return @intFromBool((constEval(node.lhs.?) orelse return null) == 0),
            .neg => return -%(constEval(node.lhs.?) orelse return null),
            .bitnot => return ~(constEval(node.lhs.?) orelse return null),
            .cond => {
                const c = constEval(node.cond.?) orelse return null;
                return if (c != 0) (constEval(node.then.?) orelse return null) else (constEval(node.els.?) orelse return null);
            },
            .comma => return constEval(node.rhs.?),
            .cast => {
                const v = constEval(node.lhs.?) orelse return null;
                return castConst(v, node.cast_ty.?);
            },
            else => return null,
        }
    }

    fn castConst(v: i64, to: *Type) i64 {
        if (to.kind == .ptr or to.size == 8) return v;
        return switch (to.size) {
            1 => if (to.is_unsigned)
                @as(i64, @as(u8, @truncate(@as(u64, @bitCast(v)))))
            else
                @as(i64, @as(i8, @truncate(v))),
            2 => if (to.is_unsigned)
                @as(i64, @as(u16, @truncate(@as(u64, @bitCast(v)))))
            else
                @as(i64, @as(i16, @truncate(v))),
            4 => if (to.is_unsigned)
                @as(i64, @as(u32, @truncate(@as(u64, @bitCast(v)))))
            else
                @as(i64, @as(i32, @truncate(v))),
            else => v,
        };
    }

    fn constExpr(self: *Parser, tok: *Token) CompileError!i64 {
        const node = try self.parseCondExpr();
        if (constEval(node)) |v| return v;
        return errorAt(tok, "not a compile-time constant expression", .{});
    }

    // ---------------- 顶层 ----------------
    pub fn parseTranslationUnit(self: *Parser) CompileError!void {
        while (self.cur().kind != .eof) {
            if (self.consume(";")) continue;
            try self.parseExternal();
        }
    }

    fn parseExternal(self: *Parser) CompileError!void {
        var attr = VarAttr{};
        const base = try self.declspec(&attr);
        if (self.cur().isPunct(";")) {
            self.next();
            return; // 仅类型声明:enum {...}; / struct S {...};
        }

        if (attr.is_typedef) {
            while (true) {
                if (self.consume(";")) break;
                const d = try self.declarator(base, false);
                if (d.name.len == 0)
                    return errorAt(self.cur(), "typedef declarator must have a name", .{});
                const o = self.arena.create(Obj) catch unreachable;
                o.* = .{ .name = d.name, .ty = d.ty, .tok = d.name_tok.?, .is_typedef = true };
                self.scope.vars.put(d.name, o) catch unreachable;
                if (self.consume(",")) continue;
                try self.expect(";");
                break;
            }
            return;
        }

        // 函数定义或全局变量
        const first = try self.declarator(base, false);
        if (first.ty.kind == .func) {
            try self.parseFunction(first, &attr);
            return;
        }
        try self.parseGlobalVar(first, &attr);
        while (self.consume(",")) {
            const d = try self.declarator(base, false);
            try self.parseGlobalVar(d, &attr);
        }
        self.skipAttributes();
        try self.expect(";");
    }

    fn parseFunction(self: *Parser, d: Decl, attr: *VarAttr) CompileError!void {
        const name_tok = d.name_tok orelse self.cur();
        const name = d.name;
        const fn_ty = d.ty;

        var fn_obj: *Obj = undefined;
        if (self.findVar(name)) |o| {
            if (o.is_typedef) return errorAt(name_tok, "unexpected typedef here", .{});
            fn_obj = o;
            fn_obj.ty = fn_ty;
        } else {
            fn_obj = self.newGlobalObj(name, fn_ty, name_tok);
        }
        fn_obj.is_function = true;
        fn_obj.params = fn_ty.params;
        if (attr.is_static) fn_obj.is_static = true;
        self.scope.vars.put(name, fn_obj) catch unreachable;

        self.skipAttributes();

        if (!self.cur().isPunct("{")) {
            // 原型
            _ = self.consume(";");
            return;
        }

        // 函数定义
        for (fn_ty.params) |p| {
            if (p.ty.isAggregate())
                return errorAt(name_tok, "passing struct/union by value is not supported (parameter '{s}')", .{p.name});
        }
        if (fn_ty.base.?.isAggregate())
            return errorAt(name_tok, "returning struct/union by value is not supported", .{});
        if (fn_ty.is_variadic)
            return errorAt(name_tok, "defining variadic functions is not supported", .{});
        if (fn_ty.base.?.kind == .array)
            return errorAt(name_tok, "function cannot return an array", .{});

        fn_obj.is_definition = true;
        self.cur_fn = fn_obj;
        self.labels = std.StringHashMap(*Node).init(self.arena);
        self.gotos = .empty;
        self.enterScope();
        for (fn_ty.params, 0..) |p, i| {
            const po = self.arena.create(Obj) catch unreachable;
            po.* = .{ .name = p.name, .ty = p.ty, .tok = name_tok, .is_local = true };
            if (i >= 6) {
                po.pass_by_stack = true;
                po.offset = @intCast(16 + 8 * (i - 6));
            }
            fn_obj.locals.append(self.arena, po) catch unreachable;
            if (p.name.len > 0) self.scope.vars.put(p.name, po) catch unreachable;
        }
        fn_obj.body = try self.parseCompoundStmt();
        self.leaveScope();
        try self.resolveGotos();
        self.assignLocalOffsets(fn_obj);
        self.cur_fn = null;
    }

    fn parseGlobalVar(self: *Parser, d: Decl, attr: *VarAttr) CompileError!void {
        const name = d.name;
        const name_tok = d.name_tok orelse self.cur();
        if (name.len == 0) return errorAt(name_tok, "variable name expected in file scope", .{});
        if (d.ty.kind == .func and !self.cur().isPunct("=")) {
            // 函数原型(无函数体)
            var o: *Obj = undefined;
            if (self.findVar(name)) |ex| {
                o = ex;
            } else {
                o = self.newGlobalObj(name, d.ty, name_tok);
            }
            o.is_function = true;
            o.ty = d.ty;
            o.params = d.ty.params;
            if (attr.is_static) o.is_static = true;
            self.scope.vars.put(name, o) catch unreachable;
            return;
        }

        var o: *Obj = undefined;
        if (self.findVar(name)) |ex| {
            if (ex.is_typedef) return errorAt(name_tok, "unexpected typedef", .{});
            o = ex;
        } else {
            o = self.newGlobalObj(name, d.ty, name_tok);
        }
        o.ty = d.ty;
        if (attr.is_static) o.is_static = true;

        if (self.consume("=")) {
            o.is_definition = true;
            o.is_tentative = false;
            try self.parseGlobalInitializer(o);
        } else if (attr.is_extern) {
            o.is_definition = false;
        } else {
            o.is_definition = true;
            o.is_tentative = true;
        }
        self.scope.vars.put(name, o) catch unreachable;
    }

    fn newGlobalObj(self: *Parser, name: []const u8, t: *Type, tok: *Token) *Obj {
        const o = self.arena.create(Obj) catch unreachable;
        o.* = .{ .name = name, .ty = t, .tok = tok };
        self.globals.append(self.arena, o) catch unreachable;
        return o;
    }

    fn newStaticLocal(self: *Parser, name: []const u8, t: *Type, tok: *Token) *Obj {
        const o = self.newGlobalObj(name, t, tok);
        o.is_static = true;
        o.asm_name = self.uniqueLabel(".L.st.{s}.{d}", .{ name, self.newUniqueId() });
        return o;
    }

    /// 字符串字面量 → 匿名全局对象(.rodata)
    fn newStringObj(self: *Parser, tok: *Token) *Obj {
        const t = ty.arrayOf(self.arena, &ty.ty_char, @intCast(tok.str_data.len + 1));
        const o = self.newGlobalObj("", t, tok);
        o.is_str_lit = true;
        o.asm_name = self.uniqueLabel(".L.str.{d}", .{self.newUniqueId()});
        const data = self.arena.alloc(u8, t.size) catch unreachable;
        @memset(data, 0);
        @memcpy(data[0..tok.str_data.len], tok.str_data);
        o.init_data = data;
        return o;
    }

    fn resolveGotos(self: *Parser) CompileError!void {
        for (self.gotos.items) |g| {
            if (self.labels.get(g.label)) |l| {
                g.unique_label = l.unique_label;
            } else {
                return errorAt(g.tok, "use of undeclared label '{s}'", .{g.label});
            }
        }
    }

    fn assignLocalOffsets(self: *Parser, func: *Obj) void {
        _ = self;
        var offset: i32 = 0;
        for (func.locals.items, 0..) |v, i| {
            if (v.pass_by_stack) continue; // 栈传参偏移在参数创建时已定
            // 寄存器参数的栈槽统一 8 字节(整寄存器直接落栈)
            const is_param = i < func.params.len;
            const slot: u32 = if (is_param) 8 else v.ty.size;
            const alignment: u32 = if (is_param) 8 else v.ty.alignment;
            offset += @intCast(slot);
            offset = @intCast(ty.alignTo(@as(u32, @intCast(offset)), alignment));
            v.offset = -offset;
        }
        func.stack_size = ty.alignTo(@as(u32, @intCast(offset)), 16);
    }

    // ---------------- 声明说明符 ----------------
    fn isTypenameStart(self: *Parser, tok: *Token) bool {
        if (tok.kind == .keyword) {
            const kws = [_][]const u8{
                "void",     "char",    "short",      "int",     "long",
                "struct",   "union",   "enum",       "signed",  "unsigned",
                "static",   "extern",  "const",      "volatile", "auto",
                "register", "restrict", "inline",    "__attribute__", "_Bool",
            };
            for (kws) |k| {
                if (std.mem.eql(u8, k, tok.text)) return true;
            }
            return false;
        }
        if (tok.kind == .ident) {
            if (self.findVar(tok.text)) |o| return o.is_typedef;
        }
        return false;
    }

    fn skipAttributes(self: *Parser) void {
        while (self.isKwTok("__attribute__")) {
            self.next();
            if (!self.consume("(")) break;
            var depth: u32 = 1;
            while (depth > 0 and self.cur().kind != .eof) {
                if (self.cur().isPunct("(")) depth += 1;
                if (self.cur().isPunct(")")) depth -= 1;
                self.next();
            }
        }
    }

    fn isKwTok(self: *Parser, s: []const u8) bool {
        return self.cur().isKw(s);
    }

    fn declspec(self: *Parser, attr: ?*VarAttr) CompileError!*Type {
        var dummy_attr = VarAttr{};
        const a = attr orelse &dummy_attr;
        var base: ?*Type = null;
        var counter: i32 = 0; // void=1 char=2 short=3 int=4 long=8
        var is_unsigned = false;
        var saw_type = false;

        while (self.cur().kind != .eof) {
            if (self.cur().kind == .keyword) {
                const t = self.cur().text;
                if (eqAny(t, &.{ "typedef", "static", "extern", "inline" })) {
                    if (eq(t, "typedef")) a.is_typedef = true;
                    if (eq(t, "static")) a.is_static = true;
                    if (eq(t, "extern")) a.is_extern = true;
                    if (eq(t, "inline")) a.is_inline = true;
                    self.next();
                    continue;
                }
                if (eqAny(t, &.{ "const", "volatile", "auto", "register", "restrict" })) {
                    self.next();
                    continue;
                }
                if (eq(t, "__attribute__")) {
                    self.skipAttributes();
                    continue;
                }
                if (eq(t, "void") and counter == 0) {
                    self.next();
                    counter += 1;
                    saw_type = true;
                    continue;
                }
                if (eq(t, "char") and counter == 0) {
                    self.next();
                    counter += 2;
                    saw_type = true;
                    continue;
                }
                if (eq(t, "short") and (counter == 0 or counter == 4)) {
                    self.next();
                    counter += 3;
                    saw_type = true;
                    continue;
                }
                if (eq(t, "int") and (counter == 0 or counter == 3 or counter == 8 or counter == 16)) {
                    self.next();
                    counter += 4;
                    saw_type = true;
                    continue;
                }
                if (eq(t, "long") and (counter == 0 or counter == 8 or counter == 4)) {
                    self.next();
                    counter += 8;
                    saw_type = true;
                    continue;
                }
                if (eq(t, "signed") or eq(t, "unsigned")) {
                    is_unsigned = eq(t, "unsigned");
                    self.next();
                    continue;
                }
                if (eq(t, "struct") or eq(t, "union")) {
                    if (saw_type) break;
                    base = try self.structUnionDecl();
                    saw_type = true;
                    continue;
                }
                if (eq(t, "enum")) {
                    if (saw_type) break;
                    base = try self.enumDecl();
                    saw_type = true;
                    continue;
                }
                if (eq(t, "_Bool")) {
                    self.next();
                    if (counter == 0) counter = 4; // _Bool 按 int 处理
                    saw_type = true;
                    continue;
                }
                break; // 其他关键字(如 return/for)不属于声明说明符
            }
            // typedef 名
            if (self.cur().kind == .ident and !saw_type) {
                if (self.findVar(self.cur().text)) |o| {
                    if (o.is_typedef) {
                        self.next();
                        base = o.ty;
                        saw_type = true;
                        continue;
                    }
                }
            }
            break;
        }

        var t: *Type = undefined;
        if (base) |b| {
            t = b;
        } else if (counter == 0 and is_unsigned) {
            t = &ty.ty_int; // 裸 unsigned = unsigned int
        } else switch (counter) {
            1 => t = &ty.ty_void,
            2 => t = &ty.ty_char,
            3, 7 => t = &ty.ty_short, // short / short int
            4 => t = &ty.ty_int,
            8, 12 => t = &ty.ty_long, // long / long int
            16, 20 => t = &ty.ty_long, // long long [int]
            else => return errorAt(self.cur(), "type name expected (counter={d})", .{counter}),
        }

        if (is_unsigned) {
            t = ty.copy(self.arena, t.*);
            t.is_unsigned = true;
        }
        return t;
    }

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
    fn eqAny(a: []const u8, list: []const []const u8) bool {
        for (list) |b| {
            if (eq(a, b)) return true;
        }
        return false;
    }

    fn structUnionDecl(self: *Parser) CompileError!*Type {
        const is_union = self.cur().isKw("union");
        self.next();
        var tag: []const u8 = "";
        if (self.cur().kind == .ident) {
            tag = self.cur().text;
            self.next();
        }

        if (!self.cur().isPunct("{")) {
            if (tag.len > 0) {
                if (self.findTag(tag)) |t| return t;
            }
            const t = ty.copy(self.arena, .{
                .kind = if (is_union) .union_ else .struct_,
                .size = 0,
                .alignment = 1,
                .is_complete = false,
                .tag = tag,
            });
            if (tag.len > 0) self.pushTag(tag, t);
            return t;
        }

        var members: std.ArrayList(Member) = .empty;
        self.next(); // '{'
        while (!self.consume("}")) {
            if (self.consume(";")) continue;
            var mattr = VarAttr{};
            const mbase = try self.declspec(&mattr);
            self.skipAttributes();
            if (self.consume(";")) continue; // 匿名 struct/union 定义体
            while (true) {
                const d = try self.declarator(mbase, false);
                var mty = d.ty;
                if (mty.kind == .array and !mty.is_complete) {
                    // flexible array member:按 0 大小处理
                    mty = ty.copy(self.arena, mty.*);
                    mty.size = 0;
                }
                if (d.name.len > 0) {
                    members.append(self.arena, .{ .ty = mty, .name = d.name }) catch unreachable;
                }
                if (!self.consume(",")) break;
            }
            self.skipAttributes();
            try self.expect(";");
        }
        self.skipAttributes();

        const t = ty.copy(self.arena, .{
            .kind = if (is_union) .union_ else .struct_,
            .size = 0,
            .alignment = 1,
            .tag = tag,
        });
        _ = ty.layoutStruct(self.arena, t, members.items, is_union);
        if (tag.len > 0) self.pushTag(tag, t);
        return t;
    }

    fn enumDecl(self: *Parser) CompileError!*Type {
        self.next(); // 'enum'
        if (self.cur().kind == .ident) {
            const tag = self.cur().text;
            self.next();
            if (!self.cur().isPunct("{")) {
                _ = tag;
                return &ty.ty_int; // enum Tag 引用
            }
        }
        if (!self.consume("{")) return &ty.ty_int;
        var val: i64 = 0;
        while (!self.consume("}")) {
            const name = try self.nextIdent();
            if (self.consume("=")) {
                val = try self.constExpr(self.cur());
            }
            const o = self.arena.create(Obj) catch unreachable;
            o.* = .{
                .name = name,
                .ty = &ty.ty_int,
                .tok = self.cur(),
                .is_enum_const = true,
                .enum_val = val,
            };
            self.scope.vars.put(name, o) catch unreachable;
            val += 1;
            _ = self.consume(",");
        }
        return &ty.ty_int;
    }

    fn pushTag(self: *Parser, name: []const u8, t: *Type) void {
        self.scope.tags.put(name, t) catch unreachable;
    }

    // ---------------- 声明符 ----------------
    fn typeSuffix(self: *Parser, base: *Type) CompileError!*Type {
        if (self.cur().isPunct("(")) {
            self.next();
            var params: std.ArrayList(Param) = .empty;
            var variadic = false;
            if (self.cur().isPunct(")")) {
                self.next();
                return ty.funcOf(self.arena, base, &.{}, true); // K&R 空参表,按可变参处理
            }
            if (self.cur().isKw("void") and self.peekAt(1).isPunct(")")) {
                self.next();
                self.next();
                return ty.funcOf(self.arena, base, &.{}, false);
            }
            while (!self.cur().isPunct(")")) {
                if (self.consume("...")) {
                    variadic = true;
                    break;
                }
                var dattr = VarAttr{};
                var pty = try self.declspec(&dattr);
                var pname: []const u8 = "";
                if (!self.cur().isPunct(",") and !self.cur().isPunct(")")) {
                    const d = try self.declarator(pty, false); // 带名参数(无名参数自然跳过)
                    pty = d.ty;
                    pname = d.name;
                    if (pty.kind == .array) pty = ty.ptrTo(self.arena, pty.base.?);
                    if (pty.kind == .func) pty = ty.ptrTo(self.arena, pty);
                }
                params.append(self.arena, .{ .ty = pty, .name = pname }) catch unreachable;
                _ = self.consume(",");
            }
            try self.expect(")");
            return ty.funcOf(self.arena, base, params.items, variadic);
        }
        if (self.cur().isPunct("[")) {
            self.next();
            var len: i64 = -1;
            if (!self.cur().isPunct("]")) {
                len = try self.constExpr(self.cur());
            }
            try self.expect("]");
            const elem = try self.typeSuffix(base);
            if (len < 0) return ty.arrayOfIncomplete(self.arena, elem);
            return ty.arrayOf(self.arena, elem, len);
        }
        return base;
    }

    /// 声明符:返回类型与名字。abstract=true 时不消费普通标识符名字。
    fn declarator(self: *Parser, base: *Type, abstract: bool) CompileError!Decl {
        var t = base;
        while (true) {
            if (self.cur().isPunct("*")) {
                t = ty.ptrTo(self.arena, t);
                self.next();
            } else if (self.cur().isKw("const") or self.cur().isKw("volatile") or self.cur().isKw("restrict")) {
                self.next();
            } else break;
        }

        var name: []const u8 = "";
        var name_tok: ?*Token = null;
        if (self.cur().kind == .ident and !abstract) {
            name = self.cur().text;
            name_tok = self.cur();
            self.next();
        }

        // 名字后(或无名字时)的 '(' 是分组声明符还是函数参数列表?
        if (self.cur().isPunct("(") and name.len == 0 and self.startsDeclaratorGroup()) {
            // 分组声明符:先越过组,解析组外后缀,再回到组内重新解析
            const group_start = self.pos + 1;
            var depth: u32 = 0;
            var i = self.pos;
            while (i < self.toks.len) : (i += 1) {
                if (self.toks[i].isPunct("(")) depth += 1;
                if (self.toks[i].isPunct(")")) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            self.pos = i + 1; // 组外
            const suffixed = try self.typeSuffix(t);
            const after_suffix = self.pos; // 组外后缀(函数参数/数组维度)之后
            self.pos = group_start; // 回到组内重新解析
            const inner = try self.declarator(suffixed, abstract);
            self.pos = after_suffix;
            return inner;
        }

        const t2 = try self.typeSuffix(t);
        return .{ .ty = t2, .name = name, .name_tok = name_tok };
    }

    /// cur=='(' 且尚未消费名字时,判断是否为声明符分组(而非函数参数表)
    fn startsDeclaratorGroup(self: *Parser) bool {
        const nxt = self.peekAt(1);
        if (nxt.isPunct("*") or nxt.isPunct("[") or nxt.isPunct("(")) return true;
        if (nxt.isPunct(")")) return false; // "()" 空参数表
        if (nxt.kind == .keyword) return false; // (int ...) 参数表
        if (nxt.kind == .ident) {
            // (name) 且组内无其他 → 分组声明符;否则按参数表
            return self.peekAt(2).isPunct(")");
        }
        return false;
    }

    // ---------------- 语句 ----------------
    fn parseCompoundStmt(self: *Parser) CompileError!*Node {
        const blk = self.newNode(.block, self.cur());
        var stmts: std.ArrayList(*Node) = .empty;
        try self.expect("{");
        self.enterScope();
        while (!self.consume("}")) {
            if (self.cur().kind == .eof)
                return errorAt(self.cur(), "unexpected end of file in block", .{});
            if (self.isTypenameStart(self.cur())) {
                try self.parseDeclaration(&stmts);
            } else if (self.consume(";")) {
                continue;
            } else {
                stmts.append(self.arena, try self.parseStmt()) catch unreachable;
            }
        }
        self.leaveScope();
        blk.body = stmts.items;
        return blk;
    }

    fn parseStmt(self: *Parser) CompileError!*Node {
        const tok = self.cur();
        if (tok.isPunct("{")) return self.parseCompoundStmt();
        if (self.consume(";")) {
            const n = self.newNode(.block, tok);
            return n;
        }
        if (tok.isKw("return")) {
            self.next();
            const n = self.newNode(.return_, tok);
            if (!self.consume(";")) {
                n.lhs = try self.parseExpr();
                try self.expect(";");
            }
            return n;
        }
        if (tok.isKw("if")) {
            self.next();
            const n = self.newNode(.if_, tok);
            try self.expect("(");
            n.cond = try self.parseExpr();
            try self.expect(")");
            n.then = try self.parseStmt();
            if (self.cur().isKw("else")) {
                self.next();
                n.els = try self.parseStmt();
            }
            return n;
        }
        if (tok.isKw("switch")) {
            self.next();
            const n = self.newNode(.switch_, tok);
            try self.expect("(");
            n.cond = try self.parseExpr();
            try self.expect(")");
            const prev_switch = self.cur_switch;
            const prev_brk = self.brk_label;
            self.cur_switch = n;
            n.brk_label = self.uniqueLabel(".L.brk.{d}", .{self.newUniqueId()});
            self.brk_label = n.brk_label;
            n.then = try self.parseStmt();
            self.cur_switch = prev_switch;
            self.brk_label = prev_brk;
            return n;
        }
        if (tok.isKw("case")) {
            self.next();
            if (self.cur_switch == null)
                return errorAt(tok, "stray 'case'", .{});
            const n = self.newNode(.case_, tok);
            n.val = try self.constExpr(self.cur());
            if (!self.consume(":"))
                return errorAt(self.cur(), "expected ':' after case label", .{});
            n.then = try self.parseStmt();
            const sw = self.cur_switch.?;
            n.case_next = sw.case_next;
            sw.case_next = n;
            return n;
        }
        if (tok.isKw("default")) {
            self.next();
            if (self.cur_switch == null)
                return errorAt(tok, "stray 'default'", .{});
            try self.expect(":");
            const n = self.newNode(.case_, tok);
            n.is_default = true;
            n.then = try self.parseStmt();
            self.cur_switch.?.default_case = n;
            return n;
        }
        if (tok.isKw("for")) {
            self.next();
            const n = self.newNode(.for_, tok);
            try self.expect("(");
            self.enterScope();
            var pre: std.ArrayList(*Node) = .empty;
            // init
            if (self.cur().isPunct(";")) {
                self.next();
            } else if (self.isTypenameStart(self.cur())) {
                try self.parseDeclaration(&pre);
            } else {
                pre.append(self.arena, try self.parseExprStmt()) catch unreachable;
            }
            // cond
            if (!self.cur().isPunct(";")) {
                n.cond = try self.parseExpr();
            }
            try self.expect(";");
            // inc
            if (!self.cur().isPunct(")")) {
                n.inc = try self.parseExpr();
            }
            try self.expect(")");
            const prev_brk = self.brk_label;
            const prev_cont = self.cont_label;
            n.brk_label = self.uniqueLabel(".L.brk.{d}", .{self.newUniqueId()});
            n.cont_label = self.uniqueLabel(".L.cont.{d}", .{self.newUniqueId()});
            self.brk_label = n.brk_label;
            self.cont_label = n.cont_label;
            const body = try self.parseStmt();
            self.brk_label = prev_brk;
            self.cont_label = prev_cont;
            if (pre.items.len > 0) {
                const init_blk = self.newNode(.block, tok);
                init_blk.body = pre.items;
                n.init = init_blk;
            }
            n.then = body;
            self.leaveScope();
            return n;
        }
        if (tok.isKw("while")) {
            self.next();
            const n = self.newNode(.for_, tok); // while 用 for 结构表示(init/inc 为空)
            try self.expect("(");
            n.cond = try self.parseExpr();
            try self.expect(")");
            const prev_brk = self.brk_label;
            const prev_cont = self.cont_label;
            n.brk_label = self.uniqueLabel(".L.brk.{d}", .{self.newUniqueId()});
            n.cont_label = self.uniqueLabel(".L.cont.{d}", .{self.newUniqueId()});
            self.brk_label = n.brk_label;
            self.cont_label = n.cont_label;
            n.then = try self.parseStmt();
            self.brk_label = prev_brk;
            self.cont_label = prev_cont;
            return n;
        }
        if (tok.isKw("do")) {
            self.next();
            const n = self.newNode(.do_, tok);
            const prev_brk = self.brk_label;
            const prev_cont = self.cont_label;
            n.brk_label = self.uniqueLabel(".L.brk.{d}", .{self.newUniqueId()});
            n.cont_label = self.uniqueLabel(".L.cont.{d}", .{self.newUniqueId()});
            self.brk_label = n.brk_label;
            self.cont_label = n.cont_label;
            n.then = try self.parseStmt();
            self.brk_label = prev_brk;
            self.cont_label = prev_cont;
            if (!self.cur().isKw("while"))
                return errorAt(self.cur(), "expected 'while' after do-body", .{});
            self.next();
            try self.expect("(");
            n.cond = try self.parseExpr();
            try self.expect(")");
            try self.expect(";");
            return n;
        }
        if (tok.isKw("break")) {
            self.next();
            try self.expect(";");
            if (self.brk_label.len == 0)
                return errorAt(tok, "stray 'break'", .{});
            const n = self.newNode(.goto_, tok);
            n.unique_label = self.brk_label;
            return n;
        }
        if (tok.isKw("continue")) {
            self.next();
            try self.expect(";");
            if (self.cont_label.len == 0)
                return errorAt(tok, "stray 'continue'", .{});
            const n = self.newNode(.goto_, tok);
            n.unique_label = self.cont_label;
            return n;
        }
        if (tok.isKw("goto")) {
            self.next();
            const n = self.newNode(.goto_, tok);
            n.label = try self.nextIdent();
            self.gotos.append(self.arena, n) catch unreachable;
            try self.expect(";");
            return n;
        }
        // 标签:ident ':'
        if (tok.kind == .ident and self.peekAt(1).isPunct(":")) {
            const n = self.newNode(.label_, tok);
            n.label = tok.text;
            n.unique_label = self.uniqueLabel(".L.user.{s}.{d}", .{ tok.text, self.newUniqueId() });
            if (self.labels.contains(n.label))
                return errorAt(tok, "duplicate label '{s}'", .{n.label});
            self.labels.put(n.label, n) catch unreachable;
            self.next();
            self.next();
            n.then = try self.parseStmt();
            return n;
        }
        return self.parseExprStmt();
    }

    fn parseExprStmt(self: *Parser) CompileError!*Node {
        if (self.consume(";")) {
            return self.newNode(.block, self.cur());
        }
        const n = self.newNode(.expr_stmt, self.cur());
        n.lhs = try self.parseExpr();
        try self.expect(";");
        return n;
    }

    /// 块内声明:产生 0..n 条初始化语句追加到 out
    fn parseDeclaration(self: *Parser, out: *std.ArrayList(*Node)) CompileError!void {
        var attr = VarAttr{};
        const base = try self.declspec(&attr);
        if (self.consume(";")) return;
        while (true) {
            const d = try self.declarator(base, false);
            if (d.name.len == 0)
                return errorAt(self.cur(), "variable name expected in declaration", .{});
            try self.parseLocalVar(d, &attr, out);
            if (self.consume(",")) continue;
            try self.expect(";");
            break;
        }
    }

    fn parseLocalVar(self: *Parser, d: Decl, attr: *VarAttr, out: *std.ArrayList(*Node)) CompileError!void {
        const name_tok = d.name_tok.?;
        if (d.ty.kind == .func) {
            // 局部函数原型:登记到作用域即可
            const o = self.arena.create(Obj) catch unreachable;
            o.* = .{ .name = d.name, .ty = d.ty, .tok = name_tok, .is_function = true };
            self.scope.vars.put(d.name, o) catch unreachable;
            return;
        }
        if (d.ty.kind == .void_)
            return errorAt(name_tok, "variable '{s}' declared void", .{d.name});
        if (d.ty.kind == .array and !d.ty.is_complete and !self.cur().isPunct("="))
            return errorAt(name_tok, "array size missing in declaration of '{s}'", .{d.name});

        var t = d.ty;
        var init: ?*Initializer = null;
        if (self.consume("=")) {
            init = try self.parseInitializerFor(&t, true);
        }

        const obj = if (attr.is_static)
            self.newStaticLocal(d.name, t, name_tok)
        else
            self.newLocalObj(d.name, t, name_tok);

        if (init) |ini| {
            if (attr.is_static) {
                try self.writeGlobalInit(obj, ini);
            } else {
                try self.genLocalInit(obj, ini, out);
            }
        } else if (attr.is_static) {
            obj.is_definition = true;
            obj.is_tentative = true;
        }
        self.scope.vars.put(d.name, obj) catch unreachable;
    }

    fn newLocalObj(self: *Parser, name: []const u8, t: *Type, tok: *Token) *Obj {
        const o = self.arena.create(Obj) catch unreachable;
        o.* = .{ .name = name, .ty = t, .tok = tok, .is_local = true };
        if (self.cur_fn) |f| f.locals.append(self.arena, o) catch unreachable;
        return o;
    }

    // ---------------- 表达式 ----------------
    pub fn parseExpr(self: *Parser) CompileError!*Node {
        var node = try self.parseAssign();
        while (true) {
            const t = self.cur();
            if (!self.consume(",")) break;
            node = self.newBinaryTyped(.comma, node, try self.parseAssign(), t);
        }
        return node;
    }

    fn parseAssign(self: *Parser) CompileError!*Node {
        const node = try self.parseCondExpr();

        const ops = [_]struct { s: []const u8, k: NodeKind }{
            .{ .s = "+=", .k = .add }, .{ .s = "-=", .k = .sub },
            .{ .s = "*=", .k = .mul }, .{ .s = "/=", .k = .div_ },
            .{ .s = "%=", .k = .mod }, .{ .s = "&=", .k = .bitand },
            .{ .s = "|=", .k = .bitor }, .{ .s = "^=", .k = .bitxor },
            .{ .s = "<<=", .k = .shl }, .{ .s = ">>=", .k = .shr },
        };
        if (self.cur().isPunct("=")) {
            const t = self.cur();
            self.next();
            const rhs = try self.parseAssign();
            return self.buildAssign(node, rhs, t);
        }
        for (ops) |op| {
            if (self.cur().isPunct(op.s)) {
                const t = self.cur();
                self.next();
                const rhs = try self.parseAssign();
                return self.buildOpAssign(node, op.k, rhs, t);
            }
        }
        return node;
    }

    fn checkLValue(self: *Parser, node: *Node) CompileError!void {
        switch (node.kind) {
            .var_, .deref, .member => {},
            else => return errorAt(node.tok, "expression is not assignable(lvalue required)", .{}),
        }
        _ = self;
    }

    fn buildAssign(self: *Parser, lhs: *Node, rhs: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(lhs);
        self.ensureTyped(rhs);
        try self.checkLValue(lhs);
        if (lhs.ty.?.kind == .array)
            return errorAt(tok, "cannot assign to an array", .{});
        // 右值转换为左值类型
        const converted = self.convertAssign(rhs, lhs.ty.?);
        const n = self.newNode(.assign, tok);
        n.lhs = lhs;
        n.rhs = converted;
        self.addTypeInternal(n);
        return n;
    }

    fn convertAssign(self: *Parser, rhs: *Node, t: *Type) *Node {
        if (t.isAggregate() or rhs.ty.?.isAggregate()) {
            if (rhs.ty.?.kind == t.kind and rhs.ty.?.size == t.size) return rhs;
            return rhs; // 结构体赋值兼容性宽松处理
        }
        if (t.kind == .ptr) {
            if (rhs.ty.?.kind == .ptr) return rhs;
            return self.newCast(rhs, t);
        }
        if (rhs.ty.?.kind == .ptr) return self.newCast(rhs, t);
        if (rhs.ty.? == t) return rhs;
        return self.newCast(rhs, t);
    }

    fn buildOpAssign(self: *Parser, lhs: *Node, op: NodeKind, rhs: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(lhs);
        try self.checkLValue(lhs);
        // tmp = &lhs; *tmp = *tmp op rhs
        const ptr_ty = ty.ptrTo(self.arena, lhs.ty.?);
        const tmp = self.newLocalObj("", ptr_ty, tok);
        const tmp_var = self.newNode(.var_, tok);
        tmp_var.var_ = tmp;
        tmp_var.ty = ptr_ty;

        const assign_ptr = self.newNode(.assign, tok);
        assign_ptr.lhs = tmp_var;
        assign_ptr.rhs = self.newUnaryTyped(.addr, lhs, tok);
        self.addTypeInternal(assign_ptr);

        const deref1 = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
        const op_result = switch (op) {
            .add => try self.newAdd(self.cloneNode(deref1, tok), rhs, tok),
            .sub => try self.newSub(self.cloneNode(deref1, tok), rhs, tok),
            else => blk: {
                const l2 = self.newCast(self.cloneNode(deref1, tok), ty.promote(self.arena, lhs.ty.?));
                const r2 = self.newCast(rhs, ty.promote(self.arena, rhs.ty.?));
                break :blk self.newBinaryTyped(op, l2, r2, tok);
            },
        };
        const deref2 = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
        const assign_val = self.newNode(.assign, tok);
        assign_val.lhs = deref2;
        assign_val.rhs = self.convertAssign(op_result, lhs.ty.?);
        self.addTypeInternal(assign_val);

        const n = self.newNode(.comma, tok);
        n.lhs = assign_ptr;
        n.rhs = assign_val;
        n.ty = assign_val.ty;
        return n;
    }

    /// 复制一个浅拷贝节点(clone 用于同一变量在多处出现)
    fn cloneNode(self: *Parser, n: *Node, tok: *Token) *Node {
        const c = self.arena.create(Node) catch unreachable;
        c.* = n.*;
        c.tok = tok;
        return c;
    }
    fn cloneVarNode(self: *Parser, n: *Node, tok: *Token) *Node {
        return self.cloneNode(n, tok);
    }

    fn parseCondExpr(self: *Parser) CompileError!*Node {
        const cond = try self.parseBinary(0);
        if (!self.consume("?")) return cond;
        const q = self.toks[self.pos - 1];
        const n = self.newNode(.cond, q);
        n.cond = cond;
        n.then = try self.parseExpr();
        try self.expect(":");
        n.els = try self.parseAssign();
        self.ensureTyped(n.then.?);
        self.ensureTyped(n.els.?);
        self.addTypeInternal(n);
        return n;
    }

    pub const PrecEntry = struct { prec: u8, kind: NodeKind };

    /// 二元运算优先级爬山
    fn binaryPrec(op: []const u8) ?PrecEntry {
        const T = PrecEntry;
        const table = [_]struct { s: []const u8, v: T }{
            .{ .s = "||", .v = .{ .prec = 1, .kind = .logor } },
            .{ .s = "&&", .v = .{ .prec = 2, .kind = .logand } },
            .{ .s = "|", .v = .{ .prec = 3, .kind = .bitor } },
            .{ .s = "^", .v = .{ .prec = 4, .kind = .bitxor } },
            .{ .s = "&", .v = .{ .prec = 5, .kind = .bitand } },
            .{ .s = "==", .v = .{ .prec = 6, .kind = .eq } },
            .{ .s = "!=", .v = .{ .prec = 6, .kind = .ne } },
            .{ .s = "<", .v = .{ .prec = 7, .kind = .lt } },
            .{ .s = "<=", .v = .{ .prec = 7, .kind = .le } },
            .{ .s = ">", .v = .{ .prec = 7, .kind = .gt } },
            .{ .s = ">=", .v = .{ .prec = 7, .kind = .ge } },
            .{ .s = "<<", .v = .{ .prec = 8, .kind = .shl } },
            .{ .s = ">>", .v = .{ .prec = 8, .kind = .shr } },
            .{ .s = "+", .v = .{ .prec = 9, .kind = .add } },
            .{ .s = "-", .v = .{ .prec = 9, .kind = .sub } },
            .{ .s = "*", .v = .{ .prec = 10, .kind = .mul } },
            .{ .s = "/", .v = .{ .prec = 10, .kind = .div_ } },
            .{ .s = "%", .v = .{ .prec = 10, .kind = .mod } },
        };
        for (table) |e| {
            if (std.mem.eql(u8, e.s, op)) return e.v;
        }
        return null;
    }

    fn parseBinary(self: *Parser, min_prec: u8) CompileError!*Node {
        var node = try self.parseCastExpr();
        while (true) {
            const t = self.cur();
            if (t.kind != .punct) break;
            const p = binaryPrec(t.text) orelse break;
            if (p.prec < min_prec + 1) break;
            self.next();
            const rhs = try self.parseBinary(p.prec);
            node = try self.makeBinaryNode(p.kind, node, rhs, t);
        }
        return node;
    }

    fn makeBinaryNode(self: *Parser, kind: NodeKind, lhs: *Node, rhs: *Node, tok: *Token) CompileError!*Node {
        return switch (kind) {
            .add => try self.newAdd(lhs, rhs, tok),
            .sub => try self.newSub(lhs, rhs, tok),
            else => self.newBinaryTyped(kind, lhs, rhs, tok),
        };
    }

    fn parseCastExpr(self: *Parser) CompileError!*Node {
        if (self.cur().isPunct("(") and self.isTypenameStart(self.peekAt(1))) {
            const lp = self.cur();
            self.next();
            var attr = VarAttr{};
            const base = try self.declspec(&attr);
            const t = (try self.declarator(base, true)).ty;
            try self.expect(")");
            if (self.consume(";")) {
                return errorAt(lp, "expected expression after cast", .{});
            }
            const inner = try self.parseCastExpr();
            self.ensureTyped(inner);
            if (t.isAggregate())
                return errorAt(lp, "cannot cast to struct/union type", .{});
            return self.newCast(inner, t);
        }
        return self.parseUnary();
    }

    fn parseUnary(self: *Parser) CompileError!*Node {
        const t = self.cur();
        if (self.consume("+")) {
            const n = try self.parseCastExpr();
            self.ensureTyped(n);
            if (n.ty.?.isInteger()) return self.newCast(n, ty.promote(self.arena, n.ty.?));
            return n;
        }
        if (self.consume("-")) {
            const n = try self.parseCastExpr();
            self.ensureTyped(n);
            const zero = self.newNum(0, t);
            return self.newBinaryTyped(.sub, zero, n, t);
        }
        if (self.consume("!")) {
            const n = try self.parseCastExpr();
            return self.newUnaryTyped(.not, n, t);
        }
        if (self.consume("~")) {
            const n = try self.parseCastExpr();
            return self.newUnaryTyped(.bitnot, n, t);
        }
        if (self.consume("*")) {
            const n = try self.parseCastExpr();
            return self.newDeref(n, t);
        }
        if (self.consume("&")) {
            const n = try self.parseCastExpr();
            self.ensureTyped(n);
            return self.newUnaryTyped(.addr, n, t);
        }
        if (self.consume("++")) return self.parseIncDec(true, false, t);
        if (self.consume("--")) return self.parseIncDec(false, false, t);
        if (t.isKw("sizeof")) {
            self.next();
            if (self.cur().isPunct("(") and self.isTypenameStart(self.peekAt(1))) {
                self.next();
                var attr = VarAttr{};
                const base = try self.declspec(&attr);
                const size_ty = (try self.declarator(base, true)).ty;
                try self.expect(")");
                if (size_ty.kind == .func or (size_ty.kind == .array and !size_ty.is_complete)) {
                    return errorAt(t, "sizeof applied to an incomplete type", .{});
                }
                const n = self.newNode(.num, t);
                n.val = size_ty.size;
                n.ty = &ty.ty_ulong;
                return n;
            }
            const n = try self.parseUnary();
            self.ensureTyped(n);
            if (n.ty.?.kind == .func) {
                return errorAt(t, "invalid application of 'sizeof' to a function type", .{});
            }
            const num = self.newNode(.num, t);
            num.val = n.ty.?.size;
            num.ty = &ty.ty_ulong;
            return num;
        }
        return self.parsePostfix();
    }

    /// ++x / x++:tmp 地址指针 + tmp2 旧值(后缀)两段式
    fn parseIncDec(self: *Parser, is_inc: bool, is_post: bool, tok: *Token) CompileError!*Node {
        const operand = try self.parseUnary();
        return self.buildIncDec(operand, is_inc, is_post, tok);
    }

    fn buildIncDec(self: *Parser, operand: *Node, is_inc: bool, is_post: bool, tok: *Token) CompileError!*Node {
        self.ensureTyped(operand);
        try self.checkLValue(operand);
        if (operand.ty.?.isAggregate())
            return errorAt(tok, "cannot increment/decrement a value of aggregate type", .{});

        const ptr_ty = ty.ptrTo(self.arena, operand.ty.?);
        const tmp = self.newLocalObj("", ptr_ty, tok);
        const tmp_var = self.newNode(.var_, tok);
        tmp_var.var_ = tmp;
        tmp_var.ty = ptr_ty;

        // s0: tmp = &operand
        const s0 = self.newNode(.assign, tok);
        s0.lhs = self.cloneVarNode(tmp_var, tok);
        s0.rhs = self.newUnaryTyped(.addr, operand, tok);
        self.addTypeInternal(s0);

        const one = self.newNum(1, tok);
        const cur_val = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
        const new_val = if (is_inc)
            try self.newAdd(self.cloneNode(cur_val, tok), one, tok)
        else
            try self.newSub(self.cloneNode(cur_val, tok), one, tok);

        // s2: *tmp = *tmp ± 1
        const s2 = self.newNode(.assign, tok);
        s2.lhs = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
        s2.rhs = self.convertAssign(new_val, operand.ty.?);
        self.addTypeInternal(s2);

        if (!is_post) {
            // 前缀:(s0, s2, *tmp) —— 值为新值
            const after = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
            var seq: *Node = self.newBinaryTyped(.comma, s0, s2, tok);
            seq = self.newBinaryTyped(.comma, seq, after, tok);
            return seq;
        }

        // 后缀:(s0, s1:tmp2=*tmp(旧值), s2, tmp2)
        const tmp2 = self.newLocalObj("", operand.ty.?, tok);
        const tv2 = self.newNode(.var_, tok);
        tv2.var_ = tmp2;
        tv2.ty = operand.ty.?;

        const s1 = self.newNode(.assign, tok);
        s1.lhs = self.cloneVarNode(tv2, tok);
        s1.rhs = try self.newDeref(self.cloneVarNode(tmp_var, tok), tok);
        self.addTypeInternal(s1);

        var seq: *Node = self.newBinaryTyped(.comma, s1, s2, tok);
        seq = self.newBinaryTyped(.comma, s0, seq, tok);
        seq = self.newBinaryTyped(.comma, seq, self.cloneVarNode(tv2, tok), tok);
        return seq;
    }

    fn parsePostfix(self: *Parser) CompileError!*Node {
        var node = try self.parsePrimary();
        while (true) {
            const t = self.cur();
            if (self.consume("(")) {
                node = try self.parseFuncall(node, t);
                continue;
            }
            if (self.consume("[")) {
                const idx = try self.parseExpr();
                try self.expect("]");
                const sum = try self.newAdd(node, idx, t);
                node = try self.newDeref(sum, t);
                continue;
            }
            if (self.consume(".")) {
                node = try self.parseMember(node);
                continue;
            }
            if (self.consume("->")) {
                const derefd = try self.newDeref(node, t);
                node = try self.parseMember(derefd);
                continue;
            }
            if (self.consume("++")) {
                node = try self.parsePostfixIncDec(node, true, t);
                continue;
            }
            if (self.consume("--")) {
                node = try self.parsePostfixIncDec(node, false, t);
                continue;
            }
            break;
        }
        return node;
    }

    fn parsePostfixIncDec(self: *Parser, operand: *Node, is_inc: bool, tok: *Token) CompileError!*Node {
        return self.buildIncDec(operand, is_inc, true, tok);
    }

    fn parseMember(self: *Parser, target: *Node) CompileError!*Node {
        self.ensureTyped(target);
        const t = target.ty.?;
        if (t.kind != .struct_ and t.kind != .union_)
            return errorAt(target.tok, "request for member in non-struct/union value", .{});
        if (!t.is_complete)
            return errorAt(target.tok, "member access into incomplete type", .{});
        const name = try self.nextIdent();
        for (t.members) |*m| {
            if (std.mem.eql(u8, m.name, name)) {
                const n = self.newNode(.member, target.tok);
                n.lhs = target;
                n.member = m;
                self.addTypeInternal(n);
                return n;
            }
        }
        return errorAt(self.cur(), "no member named '{s}' in '{s}'", .{ name, if (t.tag.len > 0) t.tag else "<anonymous>" });
    }

    fn parseFuncall(self: *Parser, callee: *Node, tok: *Token) CompileError!*Node {
        self.ensureTyped(callee);
        var callee_v = callee;
        var ct = callee.ty.?;
        if (ct.kind == .ptr and ct.base != null and ct.base.?.kind == .func) {
            callee_v = try self.newDeref(callee_v, tok);
            ct = callee_v.ty.?;
        }
        if (ct.kind != .func)
            return errorAt(tok, "called object is not a function or function pointer", .{});
        if (ct.base.?.isAggregate())
            return errorAt(tok, "calling function that returns struct by value is not supported", .{});

        var args: std.ArrayList(*Node) = .empty;
        while (!self.cur().isPunct(")")) {
            var a = try self.parseAssign();
            self.ensureTyped(a);
            if (a.ty.?.kind == .array) {
                // 数组实参退化为指针
                a = self.newCast(a, ty.ptrTo(self.arena, a.ty.?.base.?));
            } else if (a.ty.?.isAggregate()) {
                return errorAt(a.tok, "passing struct/union by value is not supported", .{});
            }
            args.append(self.arena, a) catch unreachable;
            if (!self.consume(",")) break;
        }
        try self.expect(")");

        const n = self.newNode(.funcall, tok);
        n.lhs = callee_v;
        n.func_ty = ct;
        n.ty = ct.base;

        const params = ct.params;
        if (!ct.is_variadic) {
            if (args.items.len != params.len)
                return errorAt(tok, "function expects {d} argument(s), got {d}", .{ params.len, args.items.len });
        } else if (params.len > 0 and args.items.len < params.len) {
            return errorAt(tok, "function expects at least {d} argument(s), got {d}", .{ params.len, args.items.len });
        }
        // 参数转换
        for (args.items, 0..) |a, i| {
            if (i < params.len) {
                args.items[i] = self.convertAssign(a, params[i].ty);
            } else {
                // 可变参数:小整型提升到 int
                const at = a.ty.?;
                if (at.isInteger() and at.size < 4)
                    args.items[i] = self.newCast(a, &ty.ty_int);
            }
        }
        n.body = args.items;

        // 直接调用符号?
        if (callee_v.kind == .var_ and !callee_v.var_.?.is_local and callee_v.var_.?.is_function) {
            n.call_direct = callee_v.var_.?.sym();
        }
        return n;
    }

    fn parsePrimary(self: *Parser) CompileError!*Node {
        const t = self.cur();
        if (t.isPunct("(")) {
            self.next();
            if (self.cur().isPunct("{"))
                return errorAt(t, "statement expressions are not supported", .{});
            const n = try self.parseExpr();
            try self.expect(")");
            return n;
        }
        if (t.kind == .ident) {
            const name = t.text;
            if (self.findVar(name)) |o| {
                if (o.is_typedef)
                    return errorAt(t, "unexpected type name '{s}' in expression", .{name});
                const n = self.newNode(.var_, t);
                n.var_ = o;
                n.ty = o.ty;
                self.next();
                return n;
            }
            return errorAt(t, "undefined variable '{s}'", .{name});
        }
        if (t.kind == .str) {
            const obj = self.newStringObj(t);
            const n = self.newNode(.var_, t);
            n.var_ = obj;
            n.ty = obj.ty;
            self.next();
            return n;
        }
        if (t.kind == .num) {
            const n = self.parseNumLiteral(t);
            self.next();
            return n;
        }
        if (t.isKw("sizeof")) {
            return self.parseUnary(); // 由 unary 处理
        }
        return errorAt(t, "expected an expression but found '{s}'", .{t.text});
    }

    fn parseNumLiteral(self: *Parser, t: *Token) *Node {
        const n = self.newNode(.num, t);
        if (t.num_val) |v| {
            n.val = v;
            n.ty = &ty.ty_int; // 字符字面量类型是 int
            return n;
        }
        const text = t.text;
        var s = text;
        var base: u8 = 10;
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            base = 16;
            s = s[2..];
        } else if (s.len >= 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B')) {
            base = 2;
            s = s[2..];
        } else if (s.len >= 2 and s[0] == '0') {
            base = 8;
            s = s[1..];
        }
        // 后缀 u/U/l/L(任意顺序)
        var is_u = false;
        var is_l = false;
        while (s.len > 0 and (s[s.len - 1] == 'u' or s[s.len - 1] == 'U' or
            s[s.len - 1] == 'l' or s[s.len - 1] == 'L'))
        {
            switch (s[s.len - 1]) {
                'u', 'U' => is_u = true,
                'l', 'L' => is_l = true,
                else => {},
            }
            s = s[0 .. s.len - 1];
        }
        if (s.len == 0)
            _ = errorAt(t, "invalid number literal '{s}'", .{text}) catch {};

        const uv = std.fmt.parseUnsigned(u64, s, base) catch blk: {
            _ = errorAt(t, "invalid number literal '{s}'", .{text}) catch {};
            break :blk 0;
        };
        n.val = @bitCast(uv);
        if (is_u) {
            n.ty = if (is_l) &ty.ty_ulong else if (uv > std.math.maxInt(u32)) &ty.ty_ulong else &ty.ty_uint;
        } else if (is_l) {
            n.ty = &ty.ty_long;
        } else {
            // 十进制:放得进 int 用 int;十六进制/八进制放得进 uint 也行(简化:超 int 即 long)
            if (uv <= std.math.maxInt(i32)) {
                n.ty = &ty.ty_int;
            } else if (uv <= std.math.maxInt(i64)) {
                n.ty = &ty.ty_long;
            } else {
                n.ty = &ty.ty_ulong;
            }
        }
        return n;
    }

    // ---------------- 初始化器 ----------------
    /// 解析初始化器(已越过 '=')
    fn parseInitializerFor(self: *Parser, t: **Type, infer_len: bool) CompileError!*Initializer {
        if (infer_len and t.*.kind == .array and !t.*.is_complete) {
            // 由初始化内容推断长度:字符串或花括号列表
            if (self.cur().kind == .str) {
                const lit = self.cur();
                const bytes = lit.str_data.len + 1;
                t.* = ty.arrayOf(self.arena, t.*.base.?, @intCast(bytes));
                const init = self.arena.create(Initializer) catch unreachable;
                init.* = .{ .ty = t.*, .tok = lit };
                init.expr = blk: {
                    const obj = self.newStringObj(lit);
                    const nv = self.newNode(.var_, lit);
                    nv.var_ = obj;
                    nv.ty = obj.ty;
                    break :blk nv;
                };
                self.next();
                return init;
            }
            // 花括号列表:按元素类型解析,数元素个数
            const init = try self.parseInitializerListLen(t.*.base.?);
            const count: i64 = @intCast(init.children.len);
            t.* = ty.arrayOf(self.arena, t.*.base.?, count);
            init.ty = t.*;
            return init;
        }
        return self.parseInitializer(t.*);
    }

    fn parseInitializer(self: *Parser, t: *Type) CompileError!*Initializer {
        const init = self.arena.create(Initializer) catch unreachable;
        init.* = .{ .ty = t };

        if (t.kind == .array) {
            if (self.cur().kind == .str) {
                const lit = self.cur();
                const data = lit.str_data;
                if (data.len + 1 > @as(usize, @intCast(t.size)))
                    return errorAt(lit, "string literal too long for array (need {d}, have {d})", .{ t.size, data.len + 1 });
                const so = self.newStringObj(lit);
                init.expr = blk: {
                    const nv = self.newNode(.var_, lit);
                    nv.var_ = so;
                    nv.ty = so.ty;
                    break :blk nv;
                };
                self.next();
                return init;
            }
            return self.parseInitializerList(t);
        }
        if (t.kind == .struct_ or t.kind == .union_) {
            return self.parseInitializerList(t);
        }
        // 标量
        init.expr = try self.parseAssign();
        self.ensureTyped(init.expr.?);
        if (init.expr.?.ty.?.kind == .array) {
            // 数组退化为指针:char *s = "str"; int *p = arr;
            init.expr = self.newCast(init.expr.?, ty.ptrTo(self.arena, init.expr.?.ty.?.base.?));
        } else if (init.expr.?.ty.?.isAggregate()) {
            return errorAt(init.expr.?.tok, "cannot initialize scalar from aggregate", .{});
        }
        return init;
    }

    /// 数组/结构体的 { ... } 列表
    fn parseInitializerList(self: *Parser, t: *Type) CompileError!*Initializer {
        const init = self.arena.create(Initializer) catch unreachable;
        init.* = .{ .ty = t };

        var children: std.ArrayList(Initializer) = .empty;
        if (!self.consume("{")) {
            // 无花括号:单元素(字符串在外层处理)或标量
            if (t.kind == .array) {
                children.append(self.arena, (try self.parseInitializer(t.base.?)).*) catch unreachable;
            } else if (t.kind == .struct_) {
                for (t.members) |m| {
                    children.append(self.arena, (try self.parseInitializer(m.ty)).*) catch unreachable;
                }
            }
            init.children = children.items;
            return init;
        }

        if (t.kind == .array) {
            const elem = t.base.?;
            var idx: usize = 0;
            while (!self.cur().isPunct("}")) {
                if (self.cur().isPunct("[")) {
                    // [n] = 设计器
                    self.next();
                    const n = try self.constExpr(self.cur());
                    try self.expect("]");
                    try self.expect("=");
                    idx = @intCast(@max(n, 0));
                    while (children.items.len < idx + 1) {
                        children.append(self.arena, .{ .ty = elem }) catch unreachable;
                    }
                    children.items[idx] = (try self.parseInitializer(elem)).*;
                    idx += 1;
                } else {
                    while (children.items.len < idx + 1) {
                        children.append(self.arena, .{ .ty = elem }) catch unreachable;
                    }
                    children.items[idx] = (try self.parseInitializer(elem)).*;
                    idx += 1;
                }
                if (!self.consume(",")) break;
            }
            try self.expect("}");
            init.children = children.items;
            return init;
        }

        if (t.kind == .struct_) {
            var mi: usize = 0;
            while (!self.cur().isPunct("}")) {
                if (self.cur().isPunct(".")) {
                    self.next();
                    const name = try self.nextIdent();
                    try self.expect("=");
                    var found = false;
                    for (t.members, 0..) |m, k| {
                        if (std.mem.eql(u8, m.name, name)) {
                            while (children.items.len < k + 1)
                                children.append(self.arena, .{ .ty = m.ty }) catch unreachable;
                            children.items[k] = (try self.parseInitializer(m.ty)).*;
                            mi = k + 1;
                            found = true;
                            break;
                        }
                    }
                    if (!found)
                        return errorAt(self.cur(), "no member named '{s}'", .{name});
                } else {
                    if (mi >= t.members.len) {
                        // 多余的初始化项,忽略
                        _ = try self.parseAssign();
                    } else {
                        while (children.items.len < mi + 1)
                            children.append(self.arena, .{ .ty = t.members[mi].ty }) catch unreachable;
                        children.items[mi] = (try self.parseInitializer(t.members[mi].ty)).*;
                        mi += 1;
                    }
                }
                if (!self.consume(",")) break;
            }
            try self.expect("}");
            init.children = children.items;
            return init;
        }

        // union:初始化第一个成员
        if (t.kind == .union_) {
            if (t.members.len > 0 and !self.cur().isPunct("}")) {
                if (self.consume(".")) {
                    const name = try self.nextIdent();
                    try self.expect("=");
                    for (t.members) |m| {
                        if (std.mem.eql(u8, m.name, name)) {
                            children.append(self.arena, (try self.parseInitializer(m.ty)).*) catch unreachable;
                            break;
                        }
                    }
                } else {
                    children.append(self.arena, (try self.parseInitializer(t.members[0].ty)).*) catch unreachable;
                }
            }
            try self.expect("}");
            init.children = children.items;
            return init;
        }
        return errorAt(self.cur(), "unexpected initializer list", .{});
    }

    /// 推断数组长度用的列表解析(按元素类型逐个解析,统计个数)
    fn parseInitializerListLen(self: *Parser, elem: *Type) CompileError!*Initializer {
        const init = self.arena.create(Initializer) catch unreachable;
        init.* = .{ .ty = elem };
        var children: std.ArrayList(Initializer) = .empty;
        if (!self.consume("{")) {
            children.append(self.arena, (try self.parseInitializer(elem)).*) catch unreachable;
            init.children = children.items;
            return init;
        }
        while (!self.cur().isPunct("}")) {
            children.append(self.arena, (try self.parseInitializer(elem)).*) catch unreachable;
            if (!self.consume(",")) break;
        }
        try self.expect("}");
        init.children = children.items;
        return init;
    }

    /// 全局变量的初始化(已越过 '=')
    fn parseGlobalInitializer(self: *Parser, obj: *Obj) CompileError!void {
        var t = obj.ty;
        const init = try self.parseInitializerFor(&t, true);
        obj.ty = t;
        try self.writeGlobalInit(obj, init);
    }

    fn writeGlobalInit(self: *Parser, obj: *Obj, init: *Initializer) CompileError!void {
        const t = obj.ty;
        if (t.kind == .array and init.expr != null and init.expr.?.var_ != null and
            init.expr.?.var_.?.is_str_lit)
        {
            // 数组直接用字符串字面量内容(补零到数组大小)
            const so = init.expr.?.var_.?;
            const data = self.arena.alloc(u8, t.size) catch unreachable;
            @memset(data, 0);
            const n = @min(so.init_data.?.len, data.len);
            @memcpy(data[0..n], so.init_data.?[0..n]);
            obj.init_data = data;
            return;
        }
        const buf = self.arena.alloc(u8, t.size) catch unreachable;
        @memset(buf, 0);
        try self.writeInitImage(buf, &obj.rel, init, t, 0);
        obj.init_data = buf;
    }

    fn writeInitImage(self: *Parser, buf: []u8, rels: *std.ArrayList(Reloc), init: *Initializer, t: *Type, base_off: usize) CompileError!void {
        if (t.kind == .array) {
            if (init.expr != null) {
                // 字符串字面量初始化数组
                const so = init.expr.?.var_.?;
                const data = so.init_data.?;
                const n = @min(data.len, buf.len - base_off);
                @memcpy(buf[base_off .. base_off + n], data[0..n]);
                return;
            }
            const elem = t.base.?;
            for (init.children, 0..) |*ci, i| {
                const off = base_off + @as(usize, @intCast(elem.size)) * i;
                if (off + elem.size > buf.len) break;
                try self.writeInitImage(buf, rels, ci, elem, off);
            }
            return;
        }
        if (t.kind == .struct_) {
            for (init.children, 0..) |*ci, i| {
                if (i >= t.members.len) break;
                const m = t.members[i];
                const off = base_off + m.offset;
                try self.writeInitImage(buf, rels, ci, m.ty, off);
            }
            return;
        }
        if (t.kind == .union_) {
            if (t.members.len > 0 and init.children.len > 0) {
                // 第一个被初始化的成员
                for (init.children, 0..) |*ci, i| {
                    if (ci.expr != null or ci.children.len > 0) {
                        if (i < t.members.len)
                            try self.writeInitImage(buf, rels, ci, t.members[i].ty, base_off);
                        break;
                    }
                }
            }
            return;
        }
        // 标量:整数或地址
        const e = init.expr orelse return;
        self.ensureTyped(e);
        if (self.evalGlobalAddr(e)) |addr| {
            if (t.size != 8)
                return errorAt(e.tok, "invalid address initializer", .{});
            std.mem.writeInt(u64, buf[base_off..][0..8], @bitCast(addr.addend), .little);
            rels.append(self.arena, .{ .offset = @intCast(base_off), .label = addr.label, .addend = addr.addend }) catch unreachable;
            return;
        }
        const v = constEval(e) orelse
            return errorAt(e.tok, "initializer element is not a compile-time constant", .{});
        switch (t.size) {
            1 => buf[base_off] = @truncate(@as(u64, @bitCast(v))),
            2 => std.mem.writeInt(u16, buf[base_off..][0..2], @truncate(@as(u64, @bitCast(v))), .little),
            4 => std.mem.writeInt(u32, buf[base_off..][0..4], @truncate(@as(u64, @bitCast(v))), .little),
            8 => std.mem.writeInt(u64, buf[base_off..][0..8], @bitCast(v), .little),
            else => {},
        }
    }

    const AddrVal = struct { label: []const u8, addend: i64 };

    /// 求值"地址类"常量表达式:全局对象 ± 偏移
    fn evalGlobalAddr(self: *Parser, node: *Node) ?AddrVal {
        self.ensureTyped(node);
        switch (node.kind) {
            .var_ => {
                const o = node.var_.?;
                if (o.is_local or o.is_typedef or o.is_enum_const) return null;
                if (o.is_function) return .{ .label = o.sym(), .addend = 0 };
                if (o.ty.kind == .array or o.ty.isAggregate()) return .{ .label = o.sym(), .addend = 0 };
                return null;
            },
            .addr => {
                const target = node.lhs.?;
                return self.lvalueAddr(target);
            },
            .deref => {
                // *(ptr 常量) 的地址即该常量
                const sub = self.evalGlobalAddr(node.lhs.?) orelse return null;
                return sub;
            },
            .cast => {
                if (node.cast_ty.?.kind == .ptr) return self.evalGlobalAddr(node.lhs.?);
                return null;
            },
            .add, .sub => {
                const l = node.lhs.?;
                const r = node.rhs.?;
                if (self.evalGlobalAddr(l)) |a| {
                    if (constEval(r)) |v| {
                        const scale: i64 = if (node.kind == .add or node.kind == .sub)
                            (if (l.ty.?.kind == .ptr) @intCast(l.ty.?.base.?.size) else 1)
                        else
                            1;
                        const delta = v * scale;
                        return .{ .label = a.label, .addend = if (node.kind == .add) a.addend + delta else a.addend - delta };
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// 左值的地址(全局对象 + 成员/下标偏移)
    fn lvalueAddr(self: *Parser, node: *Node) ?AddrVal {
        switch (node.kind) {
            .var_ => {
                const o = node.var_.?;
                if (o.is_local or o.is_typedef or o.is_enum_const) return null;
                return .{ .label = o.sym(), .addend = 0 };
            },
            .member => {
                const base = self.lvalueAddr(node.lhs.?) orelse return null;
                return .{ .label = base.label, .addend = base.addend + node.member.?.offset };
            },
            .deref => {
                const p = node.lhs.?;
                if (self.evalGlobalAddr(p)) |a| return a;
                // &arr[i] 形式:deref(add(arr, i))
                if (p.kind == .add or p.kind == .sub) {
                    const l = p.lhs.?;
                    const r = p.rhs.?;
                    if (constEval(r)) |v| {
                        if (self.evalGlobalAddr(l)) |a| {
                            const scale: i64 = if (l.ty.?.kind == .ptr) @intCast(l.ty.?.base.?.size) else if (l.ty.?.kind == .array) @intCast(l.ty.?.base.?.size) else 1;
                            const delta = v * scale;
                            return .{ .label = a.label, .addend = if (p.kind == .add) a.addend + delta else a.addend - delta };
                        }
                    }
                }
                return null;
            },
            .cast => return self.lvalueAddr(node.lhs.?),
            else => return null,
        }
    }

    /// 局部变量初始化 → 生成赋值语句序列(聚合先整块清零)
    fn genLocalInit(self: *Parser, obj: *Obj, init: *Initializer, out: *std.ArrayList(*Node)) CompileError!void {
        const t = obj.ty;
        const desg = Desig{ .next = null, .obj = obj };
        if (t.isAggregate()) {
            const mz = self.newNode(.memzero, obj.tok);
            mz.var_ = obj;
            mz.ty = t;
            out.append(self.arena, mz) catch unreachable;
            try self.genInitAssignments(obj, init, t, &desg, out);
            return;
        }
        if (init.expr) |e| {
            self.genOneAssign(obj, e, t, &desg, out);
        }
    }

    fn genInitAssignments(self: *Parser, obj: *Obj, init: *Initializer, t: *Type, desg: *const Desig, out: *std.ArrayList(*Node)) CompileError!void {
        if (t.kind == .array) {
            if (init.expr != null) {
                // 字符串字面量初始化字符数组:逐元素赋值
                const so = init.expr.?.var_.?;
                const data = so.init_data.?;
                for (data, 0..) |b, i| {
                    if (@as(usize, @intCast(t.base.?.size)) * i >= @as(usize, @intCast(t.size))) break;
                    const d2 = Desig{ .next = desg, .obj = obj, .idx = @intCast(i) };
                    const lit = self.newNum(b, init.expr.?.tok);
                    self.genOneAssign(obj, lit, t.base.?, &d2, out);
                }
                return;
            }
            const elem = t.base.?;
            for (init.children, 0..) |*ci, i| {
                const d2 = Desig{ .next = desg, .obj = obj, .idx = @intCast(i) };
                if (elem.isAggregate()) {
                    try self.genInitAssignments(obj, ci, elem, &d2, out);
                } else if (ci.expr != null) {
                    self.genOneAssign(obj, ci.expr.?, elem, &d2, out);
                }
            }
            return;
        }
        if (t.kind == .struct_ or t.kind == .union_) {
            for (init.children, 0..) |*ci, i| {
                if (i >= t.members.len) break;
                const m = &t.members[i];
                const d2 = Desig{ .next = desg, .obj = obj, .member = m };
                if (m.ty.isAggregate()) {
                    try self.genInitAssignments(obj, ci, m.ty, &d2, out);
                } else if (ci.expr != null) {
                    self.genOneAssign(obj, ci.expr.?, m.ty, &d2, out);
                }
            }
            return;
        }
        if (init.expr) |e| self.genOneAssign(obj, e, t, desg, out);
    }

    /// 生成一条 "obj.<path> = expr" 赋值语句
    fn genOneAssign(self: *Parser, obj: *Obj, e: *Node, t: *Type, desg: *const Desig, out: *std.ArrayList(*Node)) void {
        const tok = e.tok;
        const lhs = self.desgLvalue(desg, obj, tok);
        const rhs = self.convertAssign(e, t);
        const a = self.newNode(.assign, tok);
        a.lhs = lhs;
        a.rhs = rhs;
        self.addTypeInternal(a);
        const st = self.newNode(.expr_stmt, tok);
        st.lhs = a;
        out.append(self.arena, st) catch unreachable;
    }

    /// 沿设计器链构建左值(var → 下标/成员 → ...)
    fn desgLvalue(self: *Parser, desg: *const Desig, root: *Obj, tok: *Token) *Node {
        if (desg.next) |nx| {
            const base = self.desgLvalue(nx, root, tok);
            if (desg.member) |m| {
                const n = self.newNode(.member, tok);
                n.lhs = base;
                n.member = m;
                self.addTypeInternal(n);
                return n;
            }
            const idx = self.newNum(desg.idx, tok);
            // 数组基址 + 下标必须走 newAdd(按元素大小缩放)
            const sum = self.newAdd(base, idx, tok) catch unreachable;
            const d = self.newNode(.deref, tok);
            d.lhs = sum;
            self.addTypeInternal(d);
            return d;
        }
        const n = self.newNode(.var_, tok);
        n.var_ = root;
        n.ty = root.ty;
        return n;
    }
};

/// 入口:预处理后的 token 序列 → 全局对象列表(函数与变量)
pub fn parse(arena: std.mem.Allocator, toks: []const *Token) CompileError!*std.ArrayList(*Obj) {
    const globals = arena.create(std.ArrayList(*Obj)) catch unreachable;
    globals.* = .empty;

    const p = arena.create(Parser) catch unreachable;
    p.* = .{
        .arena = arena,
        .toks = toks,
        .globals = globals,
        .scope = Scope.create(arena, null),
    };

    // 预注册内建类型名:__builtin_va_list(仅在原型中出现,按 char* 处理)
    {
        const o = arena.create(Obj) catch unreachable;
        o.* = .{
            .name = "__builtin_va_list",
            .ty = ty.ptrTo(arena, &ty.ty_char),
            .tok = toks[toks.len - 1],
            .is_typedef = true,
        };
        p.scope.vars.put("__builtin_va_list", o) catch unreachable;
    }

    try p.parseTranslationUnit();
    return globals;
}

/// 供预处理 #if 使用:对一段 token 求常量表达式的值
pub fn constEvalTokens(arena: std.mem.Allocator, toks: []const *Token) CompileError!i64 {
    const globals = arena.create(std.ArrayList(*Obj)) catch unreachable;
    globals.* = .empty;
    const p = arena.create(Parser) catch unreachable;
    p.* = .{
        .arena = arena,
        .toks = toks,
        .globals = globals,
        .scope = Scope.create(arena, null),
    };
    const node = try p.parseCondExpr();
    if (p.cur().kind != .eof)
        return errorAt(p.cur(), "unexpected token in #if expression: '{s}'", .{p.cur().text});
    if (Parser.constEval(node)) |v| return v;
    return errorAt(toks[0], "#if expression is not a compile-time constant", .{});
}
