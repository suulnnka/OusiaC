//! 链接器:ELF64 REL 目标文件(.o)+ 静态归档(.a)→ 静态 ET_EXEC ELF
//!
//! 为 ZOS 而生:基址 0x400000、入口 _start、节序 .text→.rodata→.data→.bss
//! (等价 ../os/userland/user.ld 的布局),丢弃 .eh_frame/.note*/调试节。
//!
//! 支持:GNU ar 归档(长名 + 符号索引,lazy 抽取)、强/弱/COMMON 符号、
//! STT_SECTION 局部符号、R_X86_64_{64,PC32,PLT32,32,32S} 重定位。

const std = @import("std");

pub const LinkError = error{LinkError};

const BASE = 0x400000;
const PAGE = 0x1000;

const R_X86_64_64 = 1;
const R_X86_64_PC32 = 2;
const R_X86_64_PLT32 = 4;
const R_X86_64_32 = 10;
const R_X86_64_32S = 11;

const SHN_UNDEF = 0;
const SHN_COMMON = 0xFFF2;
const SHN_ABS = 0xFFF1;

const STB_LOCAL = 0;
const STB_GLOBAL = 1;
const STB_WEAK = 2;
const STT_SECTION = 3;

const InSec = struct {
    name: []const u8,
    sh_type: u32,
    flags: u64,
    data: []const u8, // NOBITS 为空
    size: u64,
    alignment: u64,
    // 输出定位(布局后填充)
    out_sec: u8 = 255, // 255 = 丢弃
    out_off: u64 = 0,
};

const InSym = struct {
    name: []const u8,
    bind: u8,
    shndx: u16,
    value: u64,
    size: u64,
};

const Rela = struct {
    sec: u16, // 目标节索引
    offset: u64,
    type: u32,
    sym: u32, // 对象内符号表索引
    addend: i64,
};

const InputObj = struct {
    path: []const u8,
    secs: []InSec,
    syms: []InSym,
    rela: []Rela,
    used: bool = true,
};

const SymState = struct {
    obj: usize, // 定义所在对象
    sec: u16, // 对象内节索引(SHN_COMMON/SHN_ABS 同义)
    value: u64,
    size: u64,
    weak: bool,
    common: bool,
    resolved_va: u64 = 0, // 布局后填充
};

pub const Linker = struct {
    arena: std.mem.Allocator,
    objs: std.ArrayList(InputObj),
    globals: std.StringHashMap(SymState),
    commons: std.ArrayList([]const u8),
    archives: std.ArrayList(Archive),
    errors: std.ArrayList([]const u8),
    out_base: [NOUT]u64 = .{ 0, 0, 0, 0 },
    out_size: [NOUT]u64 = .{ 0, 0, 0, 0 },
    out_align: [NOUT]u64 = .{ 16, 16, 16, 16 },
    out_file_off: [NOUT]u64 = .{ 0, 0, 0, 0 },
    entry_va: u64 = 0,

    const Archive = struct {
        path: []const u8,
        members: []ArchiveMember,
        index: std.StringHashMap(usize), // 符号名 → member 下标
        loaded: []bool,
    };
    const ArchiveMember = struct {
        name: []const u8,
        data: []const u8,
        hdr_off: usize, // 成员头在文件中的偏移(索引匹配用)
    };

    fn fail(self: *Linker, comptime fmt: []const u8, args: anytype) LinkError {
        _ = self;
        std.debug.print("old: error: ", .{});
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        return error.LinkError;
    }

    // ---------------- ELF .o 读取 ----------------
    fn readObject(self: *Linker, path: []const u8, data: []const u8) LinkError!void {
        if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF"))
            return self.fail("{s}: not an ELF object", .{path});
        if (data[4] != 2 or data[5] != 1)
            return self.fail("{s}: only ELF64 little-endian supported", .{path});
        const e_type = rdU16(data, 16);
        if (e_type != 1)
            return self.fail("{s}: not a relocatable object (e_type={d})", .{ path, e_type });
        const e_machine = rdU16(data, 18);
        if (e_machine != 0x3E)
            return self.fail("{s}: not x86-64", .{path});
        const shoff = rdU64(data, 40);
        const shentsize = rdU16(data, 58);
        const shnum = rdU16(data, 60);
        const shstrndx = rdU16(data, 62);
        if (shoff == 0 or shnum == 0)
            return self.fail("{s}: no sections", .{path});

        const Shdr = struct {
            name: u32,
            typ: u32,
            flags: u64,
            offset: u64,
            size: u64,
            link: u32,
            info: u32,
            alignment: u64,
            entsize: u64,
        };
        const shdrs = self.arena.alloc(Shdr, shnum) catch unreachable;
        for (0..shnum) |i| {
            const b = data[shoff + i * shentsize ..];
            shdrs[i] = .{
                .name = rdU32(b, 0),
                .typ = rdU32(b, 4),
                .flags = rdU64(b, 8),
                .offset = rdU64(b, 24),
                .size = rdU64(b, 32),
                .link = rdU32(b, 40),
                .info = rdU32(b, 44),
                .alignment = rdU64(b, 48),
                .entsize = rdU64(b, 56),
            };
        }
        if (shstrndx >= shnum)
            return self.fail("{s}: bad shstrndx", .{path});
        const shstr = secData(data, shdrs[shstrndx]);
        const secName = struct {
            fn f(strtab: []const u8, off: u32) []const u8 {
                if (off >= strtab.len) return "";
                const end = std.mem.indexOfScalar(u8, strtab[off..], 0) orelse (strtab.len - off);
                return strtab[off .. off + end];
            }
        }.f;

        var obj = InputObj{
            .path = path,
            .secs = &.{},
            .syms = &.{},
            .rela = &.{},
        };
        var secs = self.arena.alloc(InSec, shnum) catch unreachable;
        var symtab_idx: ?usize = null;
        var symtab_link: u32 = 0;
        for (shdrs, 0..) |sh, i| {
            secs[i] = .{
                .name = secName(shstr, sh.name),
                .sh_type = sh.typ,
                .flags = sh.flags,
                .data = if (sh.typ == 8) &.{} else data[sh.offset .. sh.offset + sh.size],
                .size = sh.size,
                .alignment = if (sh.alignment == 0) 1 else sh.alignment,
            };
            if (sh.typ == 2) {
                symtab_idx = i;
                symtab_link = sh.link;
            }
        }

        var rela_list: std.ArrayList(Rela) = .empty;
        for (shdrs, 0..) |sh, i| {
            if (sh.typ != 4) continue; // SHT_RELA
            const target: u16 = @intCast(sh.info);
            const n = if (sh.entsize == 0) 0 else sh.size / sh.entsize;
            for (0..n) |k| {
                const b = data[sh.offset + k * sh.entsize ..];
                rela_list.append(self.arena, .{
                    .sec = target,
                    .offset = rdU64(b, 0),
                    .type = @intCast(rdU64(b, 8) & 0xFFFFFFFF),
                    .sym = @intCast(rdU64(b, 8) >> 32),
                    .addend = @bitCast(rdU64(b, 16)),
                }) catch unreachable;
            }
            _ = i;
        }

        if (symtab_idx) |si| {
            const sh = shdrs[si];
            const strtab = secData(data, shdrs[sh.link]);
            const n = sh.size / 24;
            var syms = self.arena.alloc(InSym, n) catch unreachable;
            for (0..n) |k| {
                const b = data[sh.offset + k * 24 ..];
                const name_off = rdU32(b, 0);
                syms[k] = .{
                    .name = if (name_off == 0) "" else secName(strtab, name_off),
                    .bind = b[4] >> 4,
                    .shndx = rdU16(b, 6),
                    .value = rdU64(b, 8),
                    .size = rdU64(b, 16),
                };
            }
            obj.syms = syms;
        } else {
            return self.fail("{s}: no symbol table", .{path});
        }
        obj.secs = secs;
        obj.rela = rela_list.items;
        self.objs.append(self.arena, obj) catch unreachable;
    }

    // ---------------- 归档读取 ----------------
    fn readArchive(self: *Linker, path: []const u8, data: []const u8) LinkError!void {
        if (data.len < 8 or !std.mem.eql(u8, data[0..8], "!<arch>\n"))
            return self.fail("{s}: not an ar archive", .{path});
        const Member = struct { name: []const u8, hdr_off: usize, size: usize };
        var members: std.ArrayList(Member) = .empty;
        var longnames: []const u8 = "";
        var off: usize = 8;
        while (off + 60 <= data.len) {
            const hdr = data[off .. off + 60];
            const raw_name = std.mem.trim(u8, hdr[0..16], " ");
            const size = std.fmt.parseInt(usize, std.mem.trim(u8, hdr[48..58], " "), 10) catch
                return self.fail("{s}: bad archive member size", .{path});
            const body_off = off + 60;
            if (std.mem.eql(u8, raw_name, "//")) {
                longnames = data[body_off .. body_off + size];
            } else {
                members.append(self.arena, .{ .name = raw_name, .hdr_off = off, .size = size }) catch unreachable;
            }
            off = body_off + size + (size & 1);
        }

        var ar = Archive{
            .path = path,
            .members = &.{},
            .index = std.StringHashMap(usize).init(self.arena),
            .loaded = &.{},
        };
        var mlist: std.ArrayList(ArchiveMember) = .empty;
        for (members.items) |m| {
            var real = m.name;
            if (m.name.len > 0 and m.name[0] == '/') {
                if (std.mem.eql(u8, m.name, "/") or std.mem.eql(u8, m.name, "/SYM64/")) continue;
                const idx = std.fmt.parseInt(usize, m.name[1..], 10) catch
                    return self.fail("{s}: bad long name ref '{s}'", .{ path, m.name });
                if (idx < longnames.len) {
                    const end = std.mem.indexOfScalar(u8, longnames[idx..], '\n') orelse (longnames.len - idx);
                    real = std.mem.trim(u8, longnames[idx .. idx + end], "/\r");
                }
            }
            mlist.append(self.arena, .{
                .name = real,
                .data = data[m.hdr_off + 60 .. m.hdr_off + 60 + m.size],
                .hdr_off = m.hdr_off,
            }) catch unreachable;
        }
        ar.members = mlist.items;
        ar.loaded = self.arena.alloc(bool, ar.members.len) catch unreachable;
        @memset(ar.loaded, false);

        // 符号索引(容错:失败则全成员可抽取)
        var symtab_member: ?[]const u8 = null;
        var sym64 = false;
        for (members.items) |m| {
            if (std.mem.eql(u8, m.name, "/")) {
                symtab_member = data[m.hdr_off + 60 .. m.hdr_off + 60 + m.size];
            } else if (std.mem.eql(u8, m.name, "/SYM64/")) {
                symtab_member = data[m.hdr_off + 60 .. m.hdr_off + 60 + m.size];
                sym64 = true;
            }
        }
        if (symtab_member) |st| {
            self.buildArchiveIndex(&ar, st, sym64) catch {
                // 索引损坏:为每个成员登记全部全局符号(全量索引)
                self.indexAllMembers(&ar) catch {};
            };
        } else {
            self.indexAllMembers(&ar) catch {};
        }
        self.archives.append(self.arena, ar) catch unreachable;
        _ = &ar;
    }

    fn buildArchiveIndex(self: *Linker, ar: *Archive, st: []const u8, sym64: bool) !void {
        if (st.len < 4) return error.Bad;
        var pos: usize = 0;
        var count: usize = 0;
        if (sym64) {
            if (st.len < 8) return error.Bad;
            count = std.mem.readInt(u64, st[0..8], .big);
            pos = 8;
        } else {
            count = std.mem.readInt(u32, st[0..4], .big);
            pos = 4;
        }
        if (count > 1 << 20) return error.Bad;
        const off_size: usize = if (sym64) 8 else 4;
        if (pos + count * off_size > st.len) return error.Bad;
        var offsets = self.arena.alloc(usize, count) catch return error.Bad;
        for (0..count) |i| {
            offsets[i] = if (sym64)
                std.mem.readInt(u64, st[pos + i * 8 ..][0..8], .big)
            else
                std.mem.readInt(u32, st[pos + i * 4 ..][0..4], .big);
        }
        var names_off = pos + count * off_size;
        // 名字 → 成员下标(按成员头偏移匹配)
        for (0..count) |i| {
            const nend = std.mem.indexOfScalar(u8, st[names_off..], 0) orelse (st.len - names_off);
            const name = st[names_off .. names_off + nend];
            names_off += nend + 1;
            if (name.len == 0) continue;
            var mi: ?usize = null;
            for (ar.members, 0..) |m, k| {
                if (m.hdr_off == offsets[i]) {
                    mi = k;
                    break;
                }
            }
            if (mi) |k| {
                if (!ar.index.contains(name))
                    ar.index.put(name, k) catch {};
            }
        }
        _ = &pos;
    }

    fn indexAllMembers(self: *Linker, ar: *Archive) !void {
        for (ar.members, 0..) |m, k| {
            if (m.data.len < 64 or !std.mem.eql(u8, m.data[0..4], "\x7fELF")) continue;
            const names = try extractGlobalNames(self.arena, m.data);
            for (names) |name| {
                if (!ar.index.contains(name))
                    ar.index.put(name, k) catch {};
            }
        }
    }

    // ---------------- 符号解析 ----------------
    fn defineSymbol(self: *Linker, obj_idx: usize, sym: InSym) LinkError!void {
        if (sym.name.len == 0) return;
        const weak = sym.bind == STB_WEAK;
        const common = sym.shndx == SHN_COMMON;
        if (sym.shndx == SHN_UNDEF and !common) return; // 引用,不是定义

        if (self.globals.get(sym.name)) |existing| {
            if (existing.common and !common) {
                // COMMON 被真定义覆盖
                self.globals.put(sym.name, .{
                    .obj = obj_idx,
                    .sec = sym.shndx,
                    .value = sym.value,
                    .size = sym.size,
                    .weak = weak,
                    .common = false,
                }) catch unreachable;
                return;
            }
            if (existing.weak and !weak and !existing.common) {
                self.globals.put(sym.name, .{
                    .obj = obj_idx,
                    .sec = sym.shndx,
                    .value = sym.value,
                    .size = sym.size,
                    .weak = false,
                    .common = false,
                }) catch unreachable;
                return;
            }
            if (!existing.weak and !existing.common and !weak and !common) {
                return self.fail("duplicate symbol '{s}' ({s} and {s})", .{
                    sym.name, self.objs.items[existing.obj].path, self.objs.items[obj_idx].path,
                });
            }
            return; // 弱重复/被覆盖:保留现有
        }
        self.globals.put(sym.name, .{
            .obj = obj_idx,
            .sec = sym.shndx,
            .value = sym.value,
            .size = sym.size,
            .weak = weak,
            .common = common,
        }) catch unreachable;
        if (common) self.commons.append(self.arena, sym.name) catch unreachable;
    }

    fn collectGlobals(self: *Linker) LinkError!void {
        for (self.objs.items, 0..) |obj, i| {
            for (obj.syms) |sym| {
                if (sym.bind == STB_LOCAL) continue;
                try self.defineSymbol(i, sym);
            }
        }
    }

    fn undefinedSymbols(self: *Linker) std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.objs.items) |obj| {
            for (obj.syms) |sym| {
                if (sym.bind == STB_LOCAL or sym.name.len == 0) continue;
                if (sym.shndx != SHN_UNDEF) continue;
                if (!self.globals.contains(sym.name))
                    out.append(self.arena, sym.name) catch unreachable;
            }
        }
        return out;
    }

    /// 归档 lazy 抽取直到不动点(含 entry 符号)
    fn pullArchives(self: *Linker, entry: []const u8) LinkError!void {
        var changed = true;
        var want: std.ArrayList([]const u8) = .empty;
        if (!self.globals.contains(entry)) want.append(self.arena, entry) catch unreachable;
        while (changed) {
            changed = false;
            var undefs = self.undefinedSymbols();
            for (want.items) |w| undefs.append(self.arena, w) catch unreachable;
            want = .empty;
            for (undefs.items) |name| {
                for (self.archives.items) |*ar| {
                    const k = ar.index.get(name) orelse continue;
                    if (ar.loaded[k]) continue;
                    ar.loaded[k] = true;
                    try self.readObject(ar.path, ar.members[k].data);
                    // 新对象的全局符号入表
                    const obj_idx = self.objs.items.len - 1;
                    for (self.objs.items[obj_idx].syms) |sym| {
                        if (sym.bind == STB_LOCAL) continue;
                        try self.defineSymbol(obj_idx, sym);
                    }
                    changed = true;
                }
            }
        }
        if (!self.globals.contains(entry))
            return self.fail("entry symbol '{s}' not found", .{entry});
    }

    // ---------------- 布局与输出 ----------------
    const OUT_TEXT = 0;
    const OUT_RODATA = 1;
    const OUT_DATA = 2;
    const OUT_BSS = 3;
    const NOUT = 4;

    fn mapSection(name: []const u8) ?u8 {
        if (std.mem.eql(u8, name, ".text") or std.mem.startsWith(u8, name, ".text."))
            return OUT_TEXT;
        if (std.mem.eql(u8, name, ".rodata") or std.mem.startsWith(u8, name, ".rodata."))
            return OUT_RODATA;
        if (std.mem.eql(u8, name, ".data") or std.mem.startsWith(u8, name, ".data."))
            return OUT_DATA;
        if (std.mem.eql(u8, name, ".bss") or std.mem.startsWith(u8, name, ".bss."))
            return OUT_BSS;
        return null; // .eh_frame/.note*/调试节等:丢弃
    }

    fn outAddrOf(self: *Linker, obj_idx: usize, sec_idx: u16) ?u64 {
        const sec = self.objs.items[obj_idx].secs[sec_idx];
        if (sec.out_sec == 255) return null;
        return self.out_base[sec.out_sec] + sec.out_off;
    }

    pub fn link(
        arena: std.mem.Allocator,
        objs: []const struct { path: []const u8, data: []const u8 },
        archives: []const struct { path: []const u8, data: []const u8 },
        entry: []const u8,
        out_path: []const u8,
        io: std.Io,
    ) LinkError!void {
        var self = Linker{
            .arena = arena,
            .objs = .empty,
            .globals = std.StringHashMap(SymState).init(arena),
            .commons = .empty,
            .archives = .empty,
            .errors = .empty,
        };

        for (objs) |o| try self.readObject(o.path, o.data);
        try self.collectGlobals();
        for (archives) |a| try self.readArchive(a.path, a.data);
        try self.pullArchives(entry);

        // ---- 分配节到输出区 ----
        var cursor: [NOUT]u64 = .{ 0, 0, 0, 0 };
        for (self.objs.items, 0..) |*obj, oi| {
            for (obj.secs, 0..) |*sec, si| {
                if (sec.sh_type != 1 and sec.sh_type != 8) {
                    sec.out_sec = 255; // SYMTAB/RELA/STRTAB 等非 ALLOC
                    continue;
                }
                if ((sec.flags & 0x2) == 0) { // SHF_ALLOC
                    sec.out_sec = 255;
                    continue;
                }
                const mapped = mapSection(sec.name) orelse {
                    sec.out_sec = 255;
                    continue;
                };
                const al = @max(sec.alignment, 1);
                cursor[mapped] = (cursor[mapped] + al - 1) / al * al;
                sec.out_sec = mapped;
                sec.out_off = cursor[mapped];
                cursor[mapped] += sec.size;
                if (al > self.out_align[mapped]) self.out_align[mapped] = al;
                _ = oi;
                _ = si;
            }
        }
        // COMMON → bss 尾部
        for (self.commons.items) |name| {
            const st = self.globals.getPtr(name).?;
            const al: u64 = if (st.value == 0) 4 else st.value; // st_value 存对齐
            const size = st.size;
            cursor[OUT_BSS] = (cursor[OUT_BSS] + al - 1) / al * al;
            st.value = cursor[OUT_BSS];
            st.sec = 0xFFFF; // 标记:已分配到输出 bss(resolved_va 直接算)
            st.common = false;
            cursor[OUT_BSS] += size;
            st.resolved_va = 0; // 布局后统一填
        }
        self.out_size = cursor;

        // ---- 文件布局 ----
        // [ehdr 64][phdr 2×56][.text][.rodata][pad 到页][.data]……
        // 关键:每个输出区的起始 VA 都要按该区最大对齐数对齐(lib 的
        // memset 用 movaps,常量池要求 16 字节对齐)。
        const alignUp = struct {
            fn f(v: u64, a: u64) u64 {
                const al = @max(a, 1);
                return (v + al - 1) / al * al;
            }
        }.f;
        const headers_len: u64 = 64 + 2 * 56;
        var file_cursor: u64 = alignUp(headers_len, self.out_align[OUT_TEXT]);
        self.out_file_off[OUT_TEXT] = file_cursor;
        self.out_base[OUT_TEXT] = BASE + file_cursor;
        file_cursor += self.out_size[OUT_TEXT];

        file_cursor = alignUp(file_cursor, self.out_align[OUT_RODATA]);
        self.out_file_off[OUT_RODATA] = file_cursor;
        self.out_base[OUT_RODATA] = BASE + file_cursor;
        file_cursor += self.out_size[OUT_RODATA];
        const rx_filesz = file_cursor;

        file_cursor = (file_cursor + PAGE - 1) / PAGE * PAGE;
        file_cursor = alignUp(file_cursor, self.out_align[OUT_DATA]);
        self.out_file_off[OUT_DATA] = file_cursor;
        self.out_base[OUT_DATA] = BASE + file_cursor;
        file_cursor += self.out_size[OUT_DATA];
        const rw_filesz = self.out_size[OUT_DATA];
        const rw_memsz = alignUp(self.out_size[OUT_DATA], self.out_align[OUT_BSS]) + self.out_size[OUT_BSS];
        // bss 紧跟 data(对齐到 bss 区最大对齐数;无文件内容,只在内存)
        self.out_base[OUT_BSS] = alignUp(self.out_base[OUT_DATA] + self.out_size[OUT_DATA], self.out_align[OUT_BSS]);

        // ---- 符号终址 ----
        var it = self.globals.iterator();
        while (it.next()) |e| {
            const st = e.value_ptr;
            if (st.sec == 0xFFFF) {
                st.resolved_va = self.out_base[OUT_BSS] + st.value;
                continue;
            }
            if (st.sec == SHN_ABS) {
                st.resolved_va = st.value;
                continue;
            }
            if (st.sec == SHN_UNDEF) {
                st.resolved_va = 0; // 弱未定义 → 0
                continue;
            }
            const addr = self.outAddrOf(st.obj, st.sec) orelse {
                return self.fail("symbol '{s}' defined in a discarded section", .{e.key_ptr.*});
            };
            st.resolved_va = addr + st.value;
        }
        if (self.globals.get(entry)) |e| self.entry_va = e.resolved_va;

        // ---- 输出镜像 ----
        var image = arena.alloc(u8, @intCast(file_cursor)) catch unreachable;
        @memset(image, 0);

        for (self.objs.items) |obj| {
            for (obj.secs) |sec| {
                if (sec.out_sec == 255 or sec.sh_type != 1) continue;
                const dst = image[@intCast(self.out_file_off[sec.out_sec] + sec.out_off)..];
                @memcpy(dst[0..sec.data.len], sec.data);
            }
        }

        // ---- 应用重定位 ----
        for (self.objs.items, 0..) |obj, oi| {
            for (obj.rela) |r| {
                const target_sec = obj.secs[r.sec];
                if (target_sec.out_sec == 255) continue; // 丢弃节的重定位一并丢弃
                if (r.sym >= obj.syms.len)
                    return self.fail("{s}: relocation symbol index out of range", .{obj.path});
                const sym = obj.syms[r.sym];
                var s_va: u64 = undefined;
                if (sym.bind == STB_LOCAL) {
                    if (sym.shndx == SHN_UNDEF) {
                        return self.fail("{s}: relocation against undefined local symbol", .{obj.path});
                    }
                    if (sym.shndx == SHN_ABS) {
                        s_va = sym.value;
                    } else {
                        s_va = self.outAddrOf(oi, sym.shndx) orelse
                            return self.fail("{s}: relocation against symbol in discarded section", .{obj.path});
                        s_va += sym.value;
                    }
                } else {
                    const gs = self.globals.get(sym.name) orelse {
                        return self.fail("{s}: undefined symbol '{s}' (referenced from {s})", .{ "input", sym.name, obj.path });
                    };
                    s_va = gs.resolved_va;
                }
                const p_va = self.outAddrOf(oi, r.sec).? + r.offset;
                const patch_off: usize = @intCast(self.out_file_off[target_sec.out_sec] + target_sec.out_off + r.offset);
                switch (r.type) {
                    R_X86_64_64 => {
                        const v = s_va +% @as(u64, @bitCast(r.addend));
                        std.mem.writeInt(u64, image[patch_off..][0..8], v, .little);
                    },
                    R_X86_64_PC32, R_X86_64_PLT32 => {
                        const v: i64 = @as(i64, @intCast(s_va)) + r.addend - @as(i64, @intCast(p_va));
                        if (v < std.math.minInt(i32) or v > std.math.maxInt(i32))
                            return self.fail("PC-relative overflow (sym '{s}')", .{sym.name});
                        std.mem.writeInt(i32, image[patch_off..][0..4], @intCast(v), .little);
                    },
                    R_X86_64_32 => {
                        const v = s_va +% @as(u64, @bitCast(r.addend));
                        if (v > std.math.maxInt(u32))
                            return self.fail("R_X86_64_32 overflow: 0x{x} (sym '{s}')", .{ v, sym.name });
                        std.mem.writeInt(u32, image[patch_off..][0..4], @intCast(v), .little);
                    },
                    R_X86_64_32S => {
                        const v: i64 = @as(i64, @intCast(s_va)) + r.addend;
                        if (v < std.math.minInt(i32) or v > std.math.maxInt(i32))
                            return self.fail("R_X86_64_32S overflow (sym '{s}')", .{sym.name});
                        std.mem.writeInt(i32, image[patch_off..][0..4], @intCast(v), .little);
                    },
                    else => return self.fail("unsupported relocation type {d} (sym '{s}')", .{ r.type, sym.name }),
                }
            }
        }

        // ---- ELF 头 + 段表 ----
        const hdr = image[0..64];
        hdr[0] = 0x7F;
        @memcpy(hdr[1..4], "ELF");
        hdr[4] = 2;
        hdr[5] = 1;
        hdr[6] = 1;
        std.mem.writeInt(u16, hdr[16..18], 2, .little); // ET_EXEC
        std.mem.writeInt(u16, hdr[18..20], 0x3E, .little);
        std.mem.writeInt(u32, hdr[20..24], 1, .little);
        std.mem.writeInt(u64, hdr[24..32], self.entry_va, .little);
        std.mem.writeInt(u64, hdr[32..40], 64, .little); // e_phoff
        std.mem.writeInt(u64, hdr[40..48], 0, .little); // e_shoff(可选,后填)
        std.mem.writeInt(u32, hdr[48..52], 0, .little);
        std.mem.writeInt(u16, hdr[52..54], 64, .little);
        std.mem.writeInt(u16, hdr[54..56], 56, .little);
        std.mem.writeInt(u16, hdr[56..58], 2, .little); // phnum

        const putPhdr = struct {
            fn f(b: []u8, typ: u32, flags: u32, off: u64, vaddr: u64, filesz: u64, memsz: u64, palign: u64) void {
                std.mem.writeInt(u32, b[0..4], typ, .little);
                std.mem.writeInt(u32, b[4..8], flags, .little);
                std.mem.writeInt(u64, b[8..16], off, .little);
                std.mem.writeInt(u64, b[16..24], vaddr, .little);
                std.mem.writeInt(u64, b[24..32], vaddr, .little); // paddr
                std.mem.writeInt(u64, b[32..40], filesz, .little);
                std.mem.writeInt(u64, b[40..48], memsz, .little);
                std.mem.writeInt(u64, b[48..56], palign, .little);
            }
        }.f;
        // RX 段:含头 + .text + .rodata
        putPhdr(image[64..120], 1, 0x5, 0, BASE, rx_filesz, rx_filesz, PAGE);
        // RW 段:.data + .bss
        putPhdr(image[120..176], 1, 0x6, self.out_file_off[OUT_DATA], self.out_base[OUT_DATA], rw_filesz, rw_memsz, PAGE);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = image }) catch |e| {
            return self.fail("cannot write '{s}': {s}", .{ out_path, @errorName(e) });
        };
    }
};

fn rdU16(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .little);
}
fn rdU32(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .little);
}
fn rdU64(d: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, d[off..][0..8], .little);
}

fn secData(data: []const u8, sh: anytype) []const u8 {
    return data[sh.offset .. sh.offset + sh.size];
}

/// 抽取一个 ELF .o 里全部已定义的全局/弱符号名
fn extractGlobalNames(arena: std.mem.Allocator, data: []const u8) ![][]const u8 {
    const shoff: usize = @intCast(rdU64(data, 40));
    const shentsize: usize = rdU16(data, 58);
    const shnum: usize = rdU16(data, 60);
    var out: std.ArrayList([]const u8) = .empty;
    for (0..shnum) |i| {
        const s = data[shoff + i * shentsize ..];
        if (rdU32(s, 4) != 2) continue; // SHT_SYMTAB
        const tab_off: usize = @intCast(rdU64(s, 24));
        const tab_size: usize = @intCast(rdU64(s, 32));
        const link_idx: usize = rdU32(s, 40);
        if (link_idx >= shnum) return error.Bad;
        const ls = data[shoff + link_idx * shentsize ..];
        const strtab = data[@intCast(rdU64(ls, 24)) .. @intCast(rdU64(ls, 24) + rdU64(ls, 32))];
        const cnt = tab_size / 24;
        for (0..cnt) |j| {
            const e = data[tab_off + j * 24 ..];
            const bind = e[4] >> 4;
            const shndx = rdU16(e, 6);
            if (bind == STB_LOCAL or shndx == SHN_UNDEF) continue;
            const noff = rdU32(e, 0);
            if (noff == 0 or noff >= strtab.len) continue;
            const nend = std.mem.indexOfScalar(u8, strtab[noff..], 0) orelse (strtab.len - noff);
            if (nend == 0) continue;
            try out.append(arena, strtab[noff .. noff + nend]);
        }
        break;
    }
    return out.items;
}
