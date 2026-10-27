//! C 类型系统
//!
//! Type 是不可变语义的普通结构体,所有实例都从 arena 分配。
//! 单例 + copy 工厂模仿 chibicc 的做法,简单直接。

const std = @import("std");

pub const Kind = enum {
    void_,
    char,
    short,
    int,
    long, // long/long long/ptrdiff_t/ssize_t,8 字节
    ptr,
    array,
    func,
    struct_,
    union_,
    enum_, // 枚举类型本身按 int 处理,保留 kind 用于诊断
};

pub const Member = struct {
    ty: *Type,
    name: []const u8,
    offset: u32 = 0,
    idx: u32 = 0,
};

pub const Param = struct {
    ty: *Type,
    name: []const u8 = "",
};

pub const Type = struct {
    kind: Kind,
    size: u32,
    alignment: u32,
    is_unsigned: bool = false,
    is_complete: bool = true, // 不完整数组/前置声明的结构体为 false
    /// ptr 指向的类型 / array 元素类型 / func 返回类型
    base: ?*Type = null,
    /// 数组长度(元素数)
    len: i64 = 0,
    /// struct/union 成员
    members: []const Member = &.{},
    /// func 参数
    params: []const Param = &.{},
    is_variadic: bool = false,
    /// struct/union/enum 标签名(诊断用)
    tag: []const u8 = "",

    pub fn isInteger(t: *const Type) bool {
        return switch (t.kind) {
            .char, .short, .int, .long, .enum_ => true,
            else => false,
        };
    }
    pub fn isPtr(t: *const Type) bool {
        return t.kind == .ptr;
    }
    pub fn isPtrOrArray(t: *const Type) bool {
        return t.kind == .ptr or t.kind == .array;
    }
    pub fn isAggregate(t: *const Type) bool {
        return t.kind == .array or t.kind == .struct_ or t.kind == .union_;
    }
    pub fn isFunc(t: *const Type) bool {
        return t.kind == .func;
    }
    /// 取"数组/函数退化为指针后"的元素/函数类型
    pub fn decayBase(t: *const Type) ?*Type {
        return if (t.kind == .array or t.kind == .func) t.base else null;
    }
};

// ---- 单例(所有基本类型的模板) ----
pub var ty_void = Type{ .kind = .void_, .size = 1, .alignment = 1 };
pub var ty_char = Type{ .kind = .char, .size = 1, .alignment = 1 };
pub var ty_short = Type{ .kind = .short, .size = 2, .alignment = 2 };
pub var ty_int = Type{ .kind = .int, .size = 4, .alignment = 4 };
pub var ty_long = Type{ .kind = .long, .size = 8, .alignment = 8 };
pub var ty_uchar = Type{ .kind = .char, .size = 1, .alignment = 1, .is_unsigned = true };
pub var ty_ushort = Type{ .kind = .short, .size = 2, .alignment = 2, .is_unsigned = true };
pub var ty_uint = Type{ .kind = .int, .size = 4, .alignment = 4, .is_unsigned = true };
pub var ty_ulong = Type{ .kind = .long, .size = 8, .alignment = 8, .is_unsigned = true };

/// arena 分配的副本
pub fn copy(arena: std.mem.Allocator, t: Type) *Type {
    const p = arena.create(Type) catch unreachable;
    p.* = t;
    return p;
}

pub fn ptrTo(arena: std.mem.Allocator, base: *Type) *Type {
    return copy(arena, .{
        .kind = .ptr,
        .size = 8,
        .alignment = 8,
        .base = base,
        .is_unsigned = true, // 指针按无符号参与通常算术转换(与 chibicc 一致)
    });
}

pub fn arrayOf(arena: std.mem.Allocator, base: *Type, len: i64) *Type {
    return copy(arena, .{
        .kind = .array,
        .size = @intCast(@as(i64, base.size) * len),
        .alignment = base.alignment,
        .base = base,
        .len = len,
        .is_complete = len >= 0,
    });
}

/// 不完整数组 `int a[]`
pub fn arrayOfIncomplete(arena: std.mem.Allocator, base: *Type) *Type {
    return copy(arena, .{
        .kind = .array,
        .size = 0,
        .alignment = base.alignment,
        .base = base,
        .len = -1,
        .is_complete = false,
    });
}

pub fn funcOf(arena: std.mem.Allocator, ret: *Type, params: []const Param, variadic: bool) *Type {
    return copy(arena, .{
        .kind = .func,
        .size = 1,
        .alignment = 1,
        .base = ret,
        .params = params,
        .is_variadic = variadic,
    });
}

/// struct/union 成员偏移布局(union:全部为 0,size 取最大)
pub fn layoutStruct(arena: std.mem.Allocator, t: *Type, members: []Member, is_union: bool) *Type {
    var offset: u32 = 0;
    var max_alignment: u32 = 1;
    var max_size: u32 = 0;
    for (members, 0..) |*m, i| {
        m.idx = @intCast(i);
        m.offset = offset;
        if (is_union) {
            m.offset = 0;
            offset = @max(offset, m.ty.size);
            max_size = @max(max_size, m.ty.size);
        } else {
            const a = m.ty.alignment;
            offset = (offset + a - 1) / a * a; // 对齐
            m.offset = offset;
            offset += m.ty.size;
        }
        max_alignment = @max(max_alignment, m.ty.alignment);
    }
    var size = if (is_union) max_size else offset;
    size = (size + max_alignment - 1) / max_alignment * max_alignment; // 整体对齐
    if (size == 0) size = max_alignment; // 空结构体给最小尺寸
    t.members = arena.dupe(Member, members) catch unreachable;
    t.size = size;
    t.alignment = max_alignment;
    return t;
}

pub fn alignTo(n: u32, a: u32) u32 {
    return (n + a - 1) / a * a;
}

/// 通常算术转换的结果类型
pub fn getCommonType(arena: std.mem.Allocator, a: *Type, b: *Type) *Type {
    if (a.kind == .ptr) return a;
    if (b.kind == .ptr) return b;
    if (a.kind == .array) return ptrTo(arena, a.base.?);
    if (b.kind == .array) return ptrTo(arena, b.base.?);
    if (a.kind == .func) return ptrTo(arena, a);
    if (b.kind == .func) return ptrTo(arena, b);
    if (a.size == 8 or b.size == 8) {
        if (a.is_unsigned or b.is_unsigned) return &ty_ulong;
        return &ty_long;
    }
    if (a.is_unsigned or b.is_unsigned) return &ty_uint;
    return &ty_int;
}

/// 整数提升:小于 int 的整数类型 → int
pub fn promote(arena: std.mem.Allocator, t: *Type) *Type {
    if (t.isInteger() and t.size < 4) return &ty_int;
    if (t.kind == .enum_) return &ty_int;
    if (t.kind == .array) return ptrTo(arena, t.base.?);
    if (t.kind == .func) return ptrTo(arena, t);
    return t;
}
