const std = @import("std");
const assert = std.debug.assert;
const cmsg = @import("linux.zig").cmsg;

const log = std.log.scoped(.wayland);

const BoundedArray = @import("bounded_array.zig").BoundedArray;

pub const header_size: u32 = 8;
pub const string_max_len = 128;

pub const Fd = std.os.linux.fd_t;
pub const String = BoundedArray(u8, string_max_len);
pub const ObjectId = u32;
pub const Opcode = u16;
pub const Fixed = packed struct(u32) {
    decimal: u8,
    integer: u24,
};

pub const Arg = union(enum) {
    int: i32,
    uint: u32,
    object: ObjectId,
    new_id: ObjectId,
    string: ?[]const u8,
    array: []const u8,
    fd: Fd,
    fixed: Fixed,
};

pub const ObjectIdAllocator = struct {
    current_id: ObjectId,

    const init: ObjectIdAllocator = .{ .current_id = 2 };

    fn alloc(self: *ObjectIdAllocator) ObjectId {
        defer self.current_id += 1;
        return self.current_id;
    }
};

var id_allocator: ObjectIdAllocator = .init;

pub fn sendMessage(writer: *std.Io.Writer, object: ObjectId, opcode: Opcode, args: []const Arg) !void {
    var announced_size: u16 = header_size;
    for (args) |arg| {
        switch (arg) {
            .int, .uint, .object, .new_id, .fixed => announced_size += @sizeOf(u32),
            .string => |maybe_str| {
                if (maybe_str) |str| {
                    announced_size += std.mem.alignForward(u16, @intCast(@sizeOf(u32) + str.len + 1), 4);
                } else {
                    // NULL string
                    announced_size += @sizeOf(u32);
                }
            },
            .array => |arr| announced_size += std.mem.alignForward(u16, @intCast(@sizeOf(u32) + arr.len), 4),
            .fd => {},
        }
    }
    assert(std.mem.isAligned(announced_size, 4));

    try writer.writeInt(ObjectId, object, .native);
    try writer.writeInt(u16, opcode, .native);
    try writer.writeInt(u16, announced_size, .native);

    for (args) |arg| {
        switch (arg) {
            .int => |value| try writer.writeInt(i32, value, .native),
            .uint, .object, .new_id => |value| try writer.writeInt(u32, value, .native),
            .fixed => |value| try writer.writeInt(u32, @bitCast(value), .native),
            .string => |maybe_str| {
                if (maybe_str) |str| {
                    const len: u32 = @intCast(str.len + 1);
                    const padded_len = std.mem.alignForward(u32, len, 4);
                    const padding = padded_len - str.len;

                    try writer.writeInt(u32, len, .native);
                    try writer.writeAll(str);
                    try writer.splatByteAll(0, padding);
                } else {
                    // NULL string
                    try writer.writeInt(u32, 0, .native);
                }
            },
            .array => |arr| {
                const len: u32 = @intCast(arr.len);
                const padded_len = std.mem.alignForward(u32, len, 4);
                const padding = padded_len - arr.len;

                try writer.writeInt(u32, len, .native);
                try writer.writeAll(arr);
                try writer.splatByteAll(0, padding);
            },
            .fd => {},
        }
    }

    try writer.flush();
}

pub fn sendMessageFd(socket: Fd, object: ObjectId, opcode: Opcode, args: []const Arg) !void {
    var fd: ?Fd = null;
    for (args) |arg| {
        if (arg == .fd) {
            assert(fd == null); // only one fd can be sent
            fd = arg.fd;
        }
    }

    var buf: [512]u8 = undefined;
    var buf_writer = std.Io.Writer.fixed(&buf);

    try sendMessage(&buf_writer, object, opcode, args);

    const iov = [_]std.posix.iovec_const{
        .{
            .base = &buf,
            .len = buf_writer.buffered().len,
        },
    };

    const data_size = @sizeOf(Fd);
    var cmsg_buf: [cmsg.space(data_size)]u8 align(@alignOf(std.os.linux.cmsghdr)) = @splat(0);

    const msghdr: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    const cmessage: *std.os.linux.cmsghdr = @ptrCast(&cmsg_buf);
    cmessage.level = std.os.linux.SOL.SOCKET;
    cmessage.type = std.os.linux.SCM.RIGHTS;
    cmessage.len = cmsg.len(data_size);

    @memcpy(cmsg.data(cmessage), std.mem.asBytes(&fd));

    const sent = std.os.linux.sendmsg(socket, &msghdr, 0);
    if (sent == -1) return error.SendMsgFailed;
}

pub fn receiveMessageFd(socket: Fd, buf: []u8) !struct { []u8, Fd } {
    var iov = [_]std.posix.iovec{
        .{ .base = &buf, .len = buf.len },
    };

    const data_size = @sizeOf(Fd);
    var cmsg_buf: [cmsg.space(data_size)]u8 align(@alignOf(std.os.linux.cmsghdr)) = @splat(0);

    var msg: std.os.linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    const recv = std.os.linux.recvmsg(socket, &msg, 0);
    if (recv == -1) return error.RecvMsgFailed;

    if (msg.flags & std.os.linux.MSG.TRUNC != 0 or msg.flags & std.os.linux.MSG.CTRUNC != 0) {
        return error.BufferTooSmall;
    }

    var fd: Fd = -1;
    var cmessage: *const std.os.linux.cmsghdr = @ptrCast(&cmsg_buf);
    while (true) {
        if (cmessage.level == std.os.linux.SOL.SOCKET and cmessage.type == std.os.linux.SCM.RIGHTS) {
            @memcpy(std.mem.asBytes(&fd), cmsg.data(cmsg)[0..@sizeOf(Fd)]);
            break;
        }

        cmessage = cmsg.nextHeader(&msg, cmsg) orelse break;
    }

    return .{ msg.iov[0].base[0..msg.iov[0].len], fd };
}

pub fn readString(reader: *std.Io.Reader, comptime max_len: usize) !BoundedArray(u8, max_len) {
    const len = try reader.takeInt(u32, .native);
    if (len == 0) return .{};

    const padded_len = std.mem.alignForward(u32, len, 4);

    var buf: [max_len]u8 = undefined;
    var buf_writer = std.Io.Writer.fixed(&buf);
    assert(padded_len <= buf.len);

    try reader.streamExact(&buf_writer, len);
    assert(buf[len - 1] == 0);

    const discard = padded_len - len;
    const discarded = try reader.discard(.limited(discard));
    assert(discard == discarded);

    const str = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));

    var result: BoundedArray(u8, max_len) = .{};
    try result.appendSlice(str);

    return result;
}

pub fn readArray(reader: *std.Io.Reader, comptime max_len: usize) !BoundedArray(u8, max_len) {
    const len = try reader.takeInt(u32, .native);
    if (len == 0) return .{};

    const padded_len = std.mem.alignForward(u32, len, 4);

    var buf: [max_len]u8 = undefined;
    var buf_writer = std.Io.Writer.fixed(&buf);
    assert(padded_len <= buf.len);

    try reader.streamExact(&buf_writer, len);
    const discard = padded_len - len;
    const discarded = try reader.discard(.limited(discard));
    assert(discard == discarded);

    var result: BoundedArray(u8, max_len) = .{};
    try result.appendSlice(buf_writer.buffered());

    return result;
}

pub const wl = struct {
    pub const Display = struct {
        id: ObjectId,
        stream: std.Io.net.Stream,

        pub const Request = enum(u16) {
            sync = 0,
            get_registry = 1,
        };

        pub const Event = enum(u16) {
            err = 0,
            delete_id = 1,
        };

        pub const Error = enum(u32) {
            invalid_object = 0,
            invalid_method = 1,
            no_memory = 2,
            implementation = 3,
        };

        pub fn init(io: std.Io, env: *std.process.Environ.Map) !Display {
            const xdg_runtime_dir = env.get("XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirNotSet;
            const wayland_display = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
            var unix_address_path_buffer: [128]u8 = undefined;
            const unix_address_path = try std.fmt.bufPrint(
                &unix_address_path_buffer,
                "{s}/{s}",
                .{ xdg_runtime_dir, wayland_display },
            );

            const unix_address: std.Io.net.UnixAddress = .{ .path = unix_address_path };
            const stream = try unix_address.connect(io);

            return .{
                .id = 1,
                .stream = stream,
            };
        }

        pub fn deinit(self: *const Display, io: std.Io) void {
            self.stream.close(io);
        }

        pub fn sync(self: *const Display, writer: *std.Io.Writer) !Callback {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.sync), &.{.{ .new_id = new_id }});

            log.debug("-> wl_display@{d}.sync: wl_callback={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getRegistry(self: *const Display, writer: *std.Io.Writer) !Registry {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_registry), &.{.{ .new_id = new_id }});

            log.debug("-> wl_display@{d}.get_registry: wl_registry={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn onError(self: *const Display, reader: *std.Io.Reader) !struct { ObjectId, u32, String } {
            const target_object_id = try reader.takeInt(ObjectId, .native);
            const code = try reader.takeInt(u32, .native);
            const err = try readString(reader, string_max_len);

            log.err("<- wl_display@{d}.error: target_object_id={d} code={d} error={s}", .{
                self.id,
                target_object_id,
                code,
                err.slice(),
            });

            return .{ target_object_id, code, err };
        }

        pub fn onDeleteId(self: *const Display, reader: *std.Io.Reader) !ObjectId {
            const deleted_id = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_display@{d}.delete_id: id={d}", .{ self.id, deleted_id });

            return deleted_id;
        }
    };

    pub const GlobalObject = struct {
        name: u32,
        interface: String,
        version: u32,
    };

    pub const Registry = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            bind = 0,
        };

        pub const Event = enum(u16) {
            global = 0,
            global_remove = 1,
        };

        pub fn bind(
            self: Registry,
            comptime T: type,
            writer: *std.Io.Writer,
            global_object: *const GlobalObject,
        ) !T {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.bind), &.{
                .{ .uint = global_object.name },
                .{ .string = global_object.interface.slice() },
                .{ .uint = global_object.version },
                .{ .new_id = new_id },
            });

            log.debug("-> wl_display@{d}.bind: name={d} interface={s} version={d} id={d}", .{
                self.id,
                global_object.name,
                global_object.interface.slice(),
                global_object.version,
                new_id,
            });

            return .{ .id = new_id };
        }

        pub fn onGlobal(self: Registry, reader: *std.Io.Reader) !GlobalObject {
            const name = try reader.takeInt(u32, .native);
            const interface = try readString(reader, string_max_len);
            const version = try reader.takeInt(u32, .native);

            log.debug("<- wl_registry@{d}.global: name={d} interface={s} version={d}", .{
                self.id,
                name,
                interface.slice(),
                version,
            });

            return .{
                .name = name,
                .interface = interface,
                .version = version,
            };
        }

        pub fn onGlobalRemove(self: Registry, reader: *std.Io.Reader) !u32 {
            const name = try reader.takeInt(u32, .native);

            log.debug("<- wl_registry@{d}.global_remove: name={d}", .{ self.id, name });

            return name;
        }
    };

    pub const Callback = struct {
        id: ObjectId,

        pub const Event = enum(u16) {
            done = 0,
        };

        pub fn onDone(self: Callback, reader: *std.Io.Reader) !u32 {
            const data = try reader.takeInt(u32, .native);

            log.debug("<- wl_callback@{d}.done: callback_data={d}", .{ self.id, data });

            return data;
        }
    };

    pub const Compositor = struct {
        id: ObjectId,

        pub const interface = "wl_compositor";

        pub const Request = enum(u16) {
            create_surface = 0,
            create_region = 1,
            release = 2,
        };

        pub fn createSurface(self: Compositor, writer: *std.Io.Writer) !Surface {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.create_surface), &.{.{ .new_id = new_id }});

            log.debug("-> wl_compositor@{d}.create_surface: wl_surface={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn createRegion(self: Compositor, writer: *std.Io.Writer) !Region {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.create_region), &.{ .new_id = new_id });

            log.debug("-> wl_compositor@{d}.create_region: wl_region={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn release(self: Compositor, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_compositor@{d}.release", .{self.id});
        }
    };

    pub const ShmPool = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            create_buffer = 0,
            destroy = 1,
            resize = 2,
        };

        pub const Error = enum(u32) {
            invalid_format = 0,
            invalid_stride = 1,
        };

        pub fn createBuffer(
            self: ShmPool,
            writer: *std.Io.Writer,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: Shm.Format,
        ) !Buffer {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.create_buffer), &.{
                .{ .new_id = new_id },
                .{ .int = offset },
                .{ .int = width },
                .{ .int = height },
                .{ .int = stride },
                .{ .uint = @intFromEnum(format) },
            });

            log.debug(
                "-> wl_shm_pool@{d}.create_buffer: wl_buffer={d} offset={d} width={d} height={d} stride={d} format={t}",
                .{ self.id, new_id, offset, width, height, stride, format },
            );

            return .{ .id = new_id };
        }

        pub fn destroy(self: ShmPool, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_shm_pool@{d}.destroy", .{self.id});
        }

        pub fn resize(self: *ShmPool, writer: *std.Io.Writer, new_size: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.resize), &.{.{ .int = new_size }});

            log.debug("-> wl_shm_pool@{d}.resize: size={d}", .{ self.id, new_size });
        }
    };

    pub const Shm = struct {
        id: ObjectId,

        pub const interface = "wl_shm";

        pub const Request = enum(u16) {
            create_pool = 0,
            release = 1,
        };

        pub const Event = enum(u16) {
            format = 0,
        };

        pub const Error = enum(u32) {
            invalid_format = 0,
            invalid_stride = 1,
            invalid_fd = 2,
        };

        pub const Format = enum(u32) {
            argb8888 = 0,
            xrgb8888 = 1,
            c8 = 0x20203843,
            rgb332 = 0x38424752,
            bgr233 = 0x38524742,
            xrgb4444 = 0x32315258,
            xbgr4444 = 0x32314258,
            rgbx4444 = 0x32315852,
            bgrx4444 = 0x32315842,
            argb4444 = 0x32315241,
            abgr4444 = 0x32314241,
            rgba4444 = 0x32314152,
            bgra4444 = 0x32314142,
            xrgb1555 = 0x35315258,
            xbgr1555 = 0x35314258,
            rgbx5551 = 0x35315852,
            bgrx5551 = 0x35315842,
            argb1555 = 0x35315241,
            abgr1555 = 0x35314241,
            rgba5551 = 0x35314152,
            bgra5551 = 0x35314142,
            rgb565 = 0x36314752,
            bgr565 = 0x36314742,
            rgb888 = 0x34324752,
            bgr888 = 0x34324742,
            xbgr8888 = 0x34324258,
            rgbx8888 = 0x34325852,
            bgrx8888 = 0x34325842,
            abgr8888 = 0x34324241,
            rgba8888 = 0x34324152,
            bgra8888 = 0x34324142,
            xrgb2101010 = 0x30335258,
            xbgr2101010 = 0x30334258,
            rgbx1010102 = 0x30335852,
            bgrx1010102 = 0x30335842,
            argb2101010 = 0x30335241,
            abgr2101010 = 0x30334241,
            rgba1010102 = 0x30334152,
            bgra1010102 = 0x30334142,
            yuyv = 0x56595559,
            yvyu = 0x55595659,
            uyvy = 0x59565955,
            vyuy = 0x59555956,
            ayuv = 0x56555941,
            nv12 = 0x3231564e,
            nv21 = 0x3132564e,
            nv16 = 0x3631564e,
            nv61 = 0x3136564e,
            yuv410 = 0x39565559,
            yvu410 = 0x39555659,
            yuv411 = 0x31315559,
            yvu411 = 0x31315659,
            yuv420 = 0x32315559,
            yvu420 = 0x32315659,
            yuv422 = 0x36315559,
            yvu422 = 0x36315659,
            yuv444 = 0x34325559,
            yvu444 = 0x34325659,
            r8 = 0x20203852,
            r16 = 0x20363152,
            rg88 = 0x38384752,
            gr88 = 0x38385247,
            rg1616 = 0x32334752,
            gr1616 = 0x32335247,
            xrgb16161616f = 0x48345258,
            xbgr16161616f = 0x48344258,
            argb16161616f = 0x48345241,
            abgr16161616f = 0x48344241,
            xyuv8888 = 0x56555958,
            vuy888 = 0x34325556,
            vuy101010 = 0x30335556,
            y210 = 0x30313259,
            y212 = 0x32313259,
            y216 = 0x36313259,
            y410 = 0x30313459,
            y412 = 0x32313459,
            y416 = 0x36313459,
            xvyu2101010 = 0x30335658,
            xvyu12_16161616 = 0x36335658,
            xvyu16161616 = 0x38345658,
            y0l0 = 0x304c3059,
            x0l0 = 0x304c3058,
            y0l2 = 0x324c3059,
            x0l2 = 0x324c3058,
            yuv420_8bit = 0x38305559,
            yuv420_10bit = 0x30315559,
            xrgb8888_a8 = 0x38415258,
            xbgr8888_a8 = 0x38414258,
            rgbx8888_a8 = 0x38415852,
            bgrx8888_a8 = 0x38415842,
            rgb888_a8 = 0x38413852,
            bgr888_a8 = 0x38413842,
            rgb565_a8 = 0x38413552,
            bgr565_a8 = 0x38413542,
            nv24 = 0x3432564e,
            nv42 = 0x3234564e,
            p210 = 0x30313250,
            p010 = 0x30313050,
            p012 = 0x32313050,
            p016 = 0x36313050,
            axbxgxrx106106106106 = 0x30314241,
            nv15 = 0x3531564e,
            q410 = 0x30313451,
            q401 = 0x31303451,
            xrgb16161616 = 0x38345258,
            xbgr16161616 = 0x38344258,
            argb16161616 = 0x38345241,
            abgr16161616 = 0x38344241,
            c1 = 0x20203143,
            c2 = 0x20203243,
            c4 = 0x20203443,
            d1 = 0x20203144,
            d2 = 0x20203244,
            d4 = 0x20203444,
            d8 = 0x20203844,
            r1 = 0x20203152,
            r2 = 0x20203252,
            r4 = 0x20203452,
            r10 = 0x20303152,
            r12 = 0x20323152,
            avuy8888 = 0x59555641,
            xvuy8888 = 0x59555658,
            p030 = 0x30333050,
            rgb161616 = 0x38344752,
            bgr161616 = 0x38344742,
            r16f = 0x48202052,
            gr1616f = 0x48205247,
            bgr161616f = 0x48524742,
            r32f = 0x46202052,
            gr3232f = 0x46205247,
            bgr323232f = 0x46524742,
            abgr32323232f = 0x46384241,
            nv20 = 0x3032564e,
            nv30 = 0x3033564e,
            s010 = 0x30313053,
            s210 = 0x30313253,
            s410 = 0x30313453,
            s012 = 0x32313053,
            s212 = 0x32313253,
            s412 = 0x32313453,
            s016 = 0x36313053,
            s216 = 0x36313253,
            s416 = 0x36313453,
            xvuy2101010 = 0x30335958,
            p230 = 0x30333250,
            t430 = 0x30333454,
            y8 = 0x59455247,
            xyyy2101010 = 0x34415059,
        };

        pub fn createPool(self: Shm, socket: Fd, shm_fd: Fd, size: i32) !ShmPool {
            const new_id = id_allocator.alloc();

            try sendMessageFd(socket, self.id, @intFromEnum(Request.create_pool), &.{
                .{ .new_id = new_id },
                .{ .int = size },
                .{ .fd = shm_fd },
            });

            log.debug("-> wl_shm@{d}.create_pool: wl_shm_pool={d} fd={d}", .{ self.id, new_id, shm_fd });

            return .{ .id = new_id };
        }

        pub fn release(self: Shm, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_shm@{d}.release", .{self.id});
        }

        pub fn onFormat(self: Shm, reader: *std.Io.Reader) !Format {
            const format = try reader.takeEnum(Format, .native);

            log.debug("<- wl_shm@{d}.format: format={t}", .{ self.id, format });

            return format;
        }
    };

    pub const Buffer = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
        };

        pub const Event = enum(u16) {
            release = 0,
        };

        pub fn destroy(self: Buffer, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_buffer@{d}.destroy", .{self.id});
        }

        pub fn onRelease(self: Buffer) !void {
            log.debug("<- wl_buffer@{d}.release", .{self.id});
        }
    };

    pub const DataOffer = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            accept = 0,
            receive = 1,
            destroy = 2,
            finish = 3,
            set_actions = 4,
        };

        pub const Event = enum(u16) {
            offer = 0,
            source_actions = 1,
            action = 2,
        };

        pub const Error = enum(u32) {
            invalid_finish = 0,
            invalid_action_mask = 1,
            invalid_action = 2,
            invalid_offer = 3,
        };

        pub fn accept(self: DataOffer, writer: *std.Io.Writer, serial: u32, mime_type: ?[]const u8) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.accept), &.{
                .{ .uint = serial },
                .{ .string = mime_type },
            });

            log.debug("-> wl_data_offer@{d}.accept: serial={d} mime_type{?s}", .{ self.id, serial, mime_type });
        }

        pub fn receive(self: DataOffer, socket: Fd, mime_type: []const u8, fd: Fd) !void {
            try sendMessageFd(socket, self.id, @intFromEnum(Request.receive), &.{
                .{ .string = mime_type },
                .{ .fd = fd },
            });

            log.debug("-> wl_data_offer@{d}.receive: mime_type={s} fd={d}", .{ self.id, mime_type, fd });
        }

        pub fn destroy(self: DataOffer, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_data_offer@{d}.destroy", .{self.id});
        }

        pub fn finish(self: DataOffer, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.finish), &.{});

            log.debug("-> wl_data_offer@{d}.finish", .{self.id});
        }

        pub fn setActions(
            self: DataOffer,
            writer: *std.Io.Writer,
            dnd_actions: DataDeviceManager.DndAction,
            preferred_action: DataDeviceManager.DndAction,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_actions), &.{
                .{ .uint = @bitCast(dnd_actions) },
                .{ .uint = @bitCast(preferred_action) },
            });
        }

        pub fn onOffer(self: DataOffer, reader: *std.Io.Reader) !String {
            const mime_type = try readString(reader);

            log.debug("<- wl_data_offer@{d}.offer: mime_type={s}", .{ self.id, mime_type.slice() });

            return mime_type;
        }

        pub fn onSourceActions(self: DataOffer, reader: *std.Io.Reader) !DataDeviceManager.DndAction {
            const source_actions = try reader.takeStruct(DataDeviceManager.DndAction, .native);

            log.debug("<- wl_data_offer@{d}.source_actions: actions={any}", .{ self.id, source_actions });

            return source_actions;
        }

        pub fn onAction(self: DataOffer, reader: *std.Io.Reader) !DataDeviceManager.DndAction {
            const action = try reader.takeStruct(DataDeviceManager.DndAction, .native);

            log.debug("<- wl_data_offer@{d}.action: action={any}", .{ self.id, action });

            return action;
        }
    };

    pub const DataSource = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            offer = 0,
            destroy = 1,
            set_actions = 2,
        };

        pub const Event = enum(u16) {
            target = 0,
            send = 1,
            cancelled = 2,
            dnd_drop_performed = 3,
            dnd_finished = 4,
            action = 5,
        };

        pub const Error = enum(u32) {
            invalid_action_mask = 0,
            invalid_source = 1,
        };

        pub fn offer(self: DataSource, writer: *std.Io.Writer, mime_type: []const u8) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.offer), &.{ .string = mime_type });

            log.debug("-> wl_data_source@{d}.offer: mime_type={s}", .{ self.id, mime_type });
        }

        pub fn destroy(self: DataSource, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_data_source@{d}.destroy", .{self.id});
        }

        pub fn setActions(
            self: DataSource,
            writer: *std.Io.Writer,
            dnd_actions: DataDeviceManager.DndAction,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_actions), &.{
                .{ .uint = @bitCast(dnd_actions) },
            });

            log.debug("-> wl_data_source@{d}.set_actions: actions={any}", .{ self.id, dnd_actions });
        }

        pub fn onTarget(self: DataSource, reader: *std.Io.Reader) !?String {
            const mime_type = try readString(reader);

            log.debug("<- wl_data_source@{d}.target: mime_type={?s}", .{
                self.id,
                if (mime_type) |mt| mt.slice() else null,
            });

            return mime_type;
        }

        pub fn onSend(self: DataSource, socket: Fd) !struct { String, Fd } {
            var buf: [512]u8 = undefined;
            const mime_type, const fd = try receiveMessageFd(socket, &buf);

            log.debug("<- wl_data_source@{d}.send: mime_type={s} fd={d}", .{ self.id, mime_type, fd });

            var result: BoundedArray(u8, 128) = .{};
            try result.append(mime_type);

            return .{ result, fd };
        }

        pub fn onCancelled(self: DataSource) void {
            log.debug("<- wl_data_source@{d}.cancelled", .{self.id});
        }

        pub fn onDndDropPerformed(self: DataSource) void {
            log.debug("<- wl_data_source@{d}.dnd_drop_performed", .{self.id});
        }

        pub fn onDndFinished(self: DataSource) void {
            log.debug("<- wl_data_source@{d}.dnd_finished", .{self.id});
        }

        pub fn onDndAction(self: DataSource, reader: *std.Io.Reader) !DataDeviceManager.DndAction {
            const action = try reader.takeStruct(DataDeviceManager.DndAction, .native);

            log.debug("<- wl_data_source@{d}.dnd_action: action={any}", .{ self.id, action });

            return action;
        }
    };

    pub const DataDevice = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            start_drag = 0,
            set_selection = 1,
            release = 2,
        };

        pub const Event = enum(u16) {
            data_offer = 0,
            enter = 1,
            leave = 2,
            motion = 3,
            drop = 4,
            selection = 5,
        };

        pub const Error = enum(u32) {
            role = 0,
            used_source = 1,
        };

        pub fn startDrag(
            self: DataDevice,
            writer: *std.Io.Writer,
            source: ?DataSource,
            origin: Surface,
            icon: ?Surface,
            serial: u32,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.start_drag), &.{
                .{ .object = if (source) |src| src.id else 0 },
                .{ .object = origin },
                .{ .object = if (icon) |icn| icn.id else 0 },
                .{ .uint = serial },
            });

            log.debug("-> wl_data_device@{d}.start_drag: source={?any} origin={any} icon={?any} serial={d}", .{
                self.id,
                source,
                origin,
                icon,
                serial,
            });
        }

        pub fn setSelection(self: DataDevice, writer: *std.Io.Writer, source: ?DataSource, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_selection), &.{
                .{ .object = if (source) |src| src.id else 0 },
                .{ .uint = serial },
            });

            log.debug("-> wl_data_device@{d}.start_drag: source={?any} serial={d}", .{
                self.id,
                source,
                serial,
            });
        }

        pub fn release(self: DataDevice, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_data_device@{d}.release", .{self.id});
        }

        pub fn onDataOffer(self: DataDevice, reader: *std.Io.Reader) !DataOffer {
            const new_id = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_data_device@{d}.data_offer: data_offer={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn onEnter(self: DataDevice, reader: *std.Io.Reader) !struct { u32, Surface, Fixed, Fixed, ?DataOffer } {
            const serial = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);
            const x = try reader.takeStruct(Fixed, .native);
            const y = try reader.takeStruct(Fixed, .native);
            const id = try reader.takeInt(ObjectId, .native);
            const data_offer: ?DataOffer = if (id == 0) null else .{ .id = id };

            log.debug("<- wl_data_device@{d}.enter: serial={d} surface={d} x={any} y={any} data_offer={any}", .{
                self.id,
                serial,
                surface,
                x,
                y,
                data_offer,
            });

            return .{ serial, .{ .id = surface }, x, y, data_offer };
        }

        pub fn onLeave(self: DataDevice) void {
            log.debug("<- wl_data_device@{d}.leave", .{self.id});
        }

        pub fn onMotion(self: DataDevice, reader: *std.Io.Reader) !struct { u32, Fixed, Fixed } {
            const time = try reader.takeInt(u32, .native);
            const x = try reader.takeStruct(Fixed, .native);
            const y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_data_device@{d}.motion: time={d} x={any} y={any}", .{ self.id, time, x, y });

            return .{ time, x, y };
        }

        pub fn onDrop(self: DataDevice) void {
            log.debug("<- wl_data_device@{d}.drop", .{self.id});
        }

        pub fn onSelection(self: DataDevice, reader: *std.Io.Reader) !?DataOffer {
            const id = try reader.takeInt(ObjectId, .native);
            const data_offer: ?DataOffer = if (id == 0) null else .{ .id = id };

            log.debug("<- wl_data_device@{d}.selection: data_offer={?any}", .{ self.id, data_offer });

            return data_offer;
        }
    };

    pub const DataDeviceManager = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            create_data_source = 0,
            get_data_device = 1,
            release = 2,
        };

        pub const DndAction = packed struct(u32) {
            copy: bool = false,
            move: bool = false,
            ask: bool = false,
            _unused: u29 = 0,

            pub const none: DndAction = .{};
        };

        pub fn createDataSource(self: DataDeviceManager, writer: *std.Io.Writer, seat: Seat) !DataSource {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.create_data_source), &.{
                .{ .new_id = new_id },
                .{ .object = seat.id },
            });

            log.debug("-> wl_data_device_manager@{d}.create_data_source: data_source={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getDataDevice(self: DataDeviceManager, writer: *std.Io.Writer, seat: Seat) !DataDevice {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_data_device), &.{
                .{ .new_id = new_id },
                .{ .object = seat.id },
            });

            log.debug("-> wl_data_device_manager@{d}.get_data_device: data_device={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn release(self: DataDeviceManager, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_data_device_manager@{d}.release", .{self.id});
        }
    };

    pub const Surface = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            attach = 1,
            damage = 2,
            frame = 3,
            set_opaque_region = 4,
            set_input_region = 5,
            commit = 6,
            set_buffer_transform = 7,
            set_buffer_scale = 8,
            damage_buffer = 9,
            offset = 10,
            get_release = 11,
        };

        pub const Event = enum(u16) {
            enter = 0,
            leave = 1,
            preferred_buffer_scale = 2,
            preferred_buffer_transform = 3,
        };

        pub const Error = enum(u32) {
            invalid_scale = 0,
            invalid_transform = 1,
            invalid_size = 2,
            invalid_offset = 3,
            defunct_role_object = 4,
            no_buffer = 5,
        };

        pub fn destroy(self: Surface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_surface@{d}.destroy", .{self.id});
        }

        pub fn attach(self: Surface, writer: *std.Io.Writer, wl_buffer: Buffer, x: i32, y: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.attach), &.{
                .{ .object = wl_buffer.id },
                .{ .int = x },
                .{ .int = y },
            });

            log.debug("-> wl_surface@{d}.attach: wl_buffer={d}", .{ self.id, wl_buffer.id });
        }

        pub fn damage(self: Surface, writer: *std.Io.Writer, x: i32, y: i32, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.damage), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> wl_surface@{d}.damage: x={d} y={d} width={d} height={d}", .{ self.id, x, y, width, height });
        }

        pub fn frame(self: Surface, writer: *std.Io.Writer) !Callback {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.frame), &.{.{ .new_id = new_id }});

            log.debug("-> wl_surface@{d}.frame: wl_callback={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn setOpaqueRegion(self: Surface, writer: *std.Io.Writer, region: ?Region) !void {
            const id: ObjectId = if (region) |r| r.id else 0;

            try sendMessage(writer, self.id, @intFromEnum(Request.set_opaque_region), &.{
                .{ .object = id },
            });

            log.debug("-> wl_surface@{d}.set_opaque_region: region={any}", .{ self.id, region });
        }

        pub fn setInputRegion(self: Surface, writer: *std.Io.Writer, region: ?Region) !void {
            const id: ObjectId = if (region) |r| r.id else 0;

            try sendMessage(writer, self.id, @intFromEnum(Request.set_input_region), &.{
                .{ .object = id },
            });

            log.debug("-> wl_surface@{d}.set_input_region: region={any}", .{ self.id, region });
        }

        pub fn commit(self: Surface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.commit), &.{});

            log.debug("-> wl_surface@{d}.commit", .{self.id});
        }

        pub fn setBufferTransform(self: Surface, writer: *std.Io.Writer, transform: Output.Transform) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_buffer_transform), &.{
                .{ .uint = @intFromEnum(transform) },
            });

            log.debug("-> wl_surface@{d}.set_buffer_transform: transform={t}", .{ self.id, transform });
        }

        pub fn setBufferScale(self: Surface, writer: *std.Io.Writer, scale: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_buffer_scale), &.{
                .{ .int = scale },
            });

            log.debug("-> wl_surface@{d}.set_buffer_scale: scale={d}", .{ self.id, scale });
        }

        pub fn damageBuffer(self: Surface, writer: *std.Io.Writer, x: i32, y: i32, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.damage_buffer), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> wl_surface@{d}.damage_buffer: x={d} y={d} width={d} height={d}", .{
                self.id,
                x,
                y,
                width,
                height,
            });
        }

        pub fn offset(self: Surface, writer: *std.Io.Writer, x: i32, y: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.offset), &.{
                .{ .int = x },
                .{ .int = y },
            });

            log.debug("-> wl_surface@{d}.offset: x={d} y={d}", .{ self.id, x, y });
        }

        pub fn getRelease(self: Surface, writer: *std.Io.Writer) !Callback {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_release), &.{
                .{ .new_id = new_id },
            });

            log.debug("-> wl_surface@{d}.get_release: callback={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn onEnter(self: Surface, reader: *std.Io.Reader) !Output {
            const output = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_surface@{d}.enter: output={d}", .{ self.id, output });

            return .{ .id = output };
        }

        pub fn onLeave(self: Surface, reader: *std.Io.Reader) !Output {
            const output = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_surface@{d}.leave: output={d}", .{ self.id, output });

            return .{ .id = output };
        }

        pub fn onPreferredBufferScale(self: Surface, reader: *std.Io.Reader) !i32 {
            const factor = try reader.takeInt(i32, .native);

            log.debug("<- wl_surface@{d}.preferred_buffer_scale: factor={d}", .{ self.id, factor });

            return factor;
        }

        pub fn onPreferedBufferTransform(self: Surface, reader: *std.Io.Reader) !Output.Transform {
            const transform = try reader.takeEnum(Output.Transform, .native);

            log.debug("<- wl_surface@{d}.preferred_buffer_transform: transform={t}", .{ self.id, transform });

            return transform;
        }
    };

    pub const Seat = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            get_pointer = 0,
            get_keyboard = 1,
            get_touch = 2,
            release = 3,
        };

        pub const Event = enum(u16) {
            capabilities = 0,
            name = 1,
        };

        pub const Capability = packed struct(u32) {
            pointer: bool = false,
            keyboard: bool = false,
            touch: bool = false,
            _unused: u29 = 0,
        };

        pub const Error = enum(u32) {
            missing_capability = 0,
        };

        pub fn getPointer(self: Seat, writer: *std.Io.Writer) !Pointer {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_pointer), &.{
                .{ .new_id = new_id },
            });

            log.debug("-> wl_seat@{d}.get_pointer: pointer={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getKeyboard(self: Seat, writer: *std.Io.Writer) !Keyboard {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_keyboard), &.{
                .{ .new_id = new_id },
            });

            log.debug("-> wl_seat@{d}.get_keyboard: keyboard={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getTouch(self: Seat, writer: *std.Io.Writer) !Touch {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_touch), &.{
                .{ .new_id = new_id },
            });

            log.debug("-> wl_seat@{d}.get_touch: touch={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn release(self: Seat, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_seat@{d}.release", .{self.id});
        }

        pub fn onCapabilities(self: Seat, reader: *std.Io.Reader) !Capability {
            const capabilities = try reader.takeStruct(Capability, .native);

            log.debug("<- wl_seat@{d}.capabilities: capabilities={any}", .{ self.id, capabilities });

            return capabilities;
        }

        pub fn onName(self: Seat, reader: *std.Io.Reader) !String {
            const name = try readString(reader);

            log.debug("<- wl_seat@{d}.name: name={s}", .{ self.id, name.slice() });

            return name;
        }
    };

    pub const Pointer = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            set_cursor = 0,
            release = 1,
        };

        pub const Event = enum(u16) {
            enter = 0,
            leave = 1,
            motion = 2,
            button = 3,
            axis = 4,
            frame = 5,
            axis_source = 6,
            axis_top = 7,
            axis_discrete = 8,
            axis_value120 = 9,
            axis_relative_direction = 10,
            warp = 11,
        };

        pub const Error = enum(u32) {
            role = 0,
        };

        pub const ButtonState = enum(u32) {
            released = 0,
            pressed = 1,
        };

        pub const Axis = enum(u32) {
            vertical_scroll = 0,
            horizontal_scroll = 1,
        };

        pub const AxisSource = enum(u32) {
            wheel = 0,
            finger = 1,
            continuous = 2,
            wheel_tilt = 3,
        };

        pub const AxisRelativeDirection = enum(u32) {
            identical = 0,
            inverted = 1,
        };

        pub fn setCursor(
            self: Pointer,
            writer: *std.Io.Writer,
            serial: u32,
            surface: Surface,
            hotspot_x: i32,
            hotspot_y: i32,
        ) !void {
            try sendMessage(writer, surface, @intFromEnum(Request.set_cursor), &.{
                .{ .uint = serial },
                .{ .object = surface.id },
                .{ .int = hotspot_x },
                .{ .int = hotspot_y },
            });

            log.debug("-> wl_pointer@{d}.set_cursor: serial={d} surface={d} hotspot_x={d} hotspot_y={d}", .{
                self.id,
                serial,
                surface.id,
                hotspot_x,
                hotspot_y,
            });
        }

        pub fn release(self: Pointer) void {
            log.debug("-> wl_pointer@{d}.release", .{self.id});
        }

        pub fn onEnter(self: Pointer, reader: *std.Io.Reader) !struct { u32, Surface, Fixed, Fixed } {
            const serial = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);
            const surface_x = try reader.takeStruct(Fixed, .native);
            const surface_y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_pointer@{d}.enter: serial={d} surface={d} surface_x={any} surface_y={any}", .{
                self.id,
                serial,
                surface,
                surface_x,
                surface_y,
            });

            return .{ serial, .{ .id = surface }, surface_x, surface_y };
        }

        pub fn onLeave(self: Pointer, reader: *std.Io.Reader) !struct { u32, Surface } {
            const serial = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_pointer@{d}.leave: serial={d} surface={d}", .{ self.id, serial, surface });

            return .{ serial, .{ .id = surface } };
        }

        pub fn onMotion(self: Pointer, reader: *std.Io.Reader) !struct { u32, Fixed, Fixed } {
            const time = try reader.takeInt(u32, .native);
            const surface_x = try reader.takeStruct(Fixed, .native);
            const surface_y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_pointer@{d}.motion: time={d} surface_x={d} surface_y={d}", .{
                self.id,
                time,
                surface_x,
                surface_y,
            });

            return .{ time, surface_x, surface_y };
        }

        pub fn onButton(self: Pointer, reader: *std.Io.Reader) !struct { u32, u32, u32, ButtonState } {
            const serial = try reader.takeInt(u32, .native);
            const time = try reader.takeInt(u32, .native);
            const button = try reader.takeInt(u32, .native);
            const state = try reader.takeEnum(ButtonState, .native);

            log.debug("<- wl_pointer@{d}.button: serial={d} time={d} button={d} state={t}", .{
                self.id,
                serial,
                time,
                button,
                state,
            });

            return .{ serial, time, button, state };
        }

        pub fn onAxis(self: Pointer, reader: *std.Io.Reader) !struct { u32, Axis, Fixed } {
            const time = try reader.takeInt(u32, .native);
            const axis = try reader.takeEnum(Axis, .native);
            const value = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_pointer@{d}.axis: time={d} axis={t} value={any}", .{ self.id, time, axis, value });

            return .{ time, axis, value };
        }

        pub fn onFrame(self: Pointer) void {
            log.debug("<- wl_pointer@{d}.frame", .{self.id});
        }

        pub fn onAxisSource(self: Pointer, reader: *std.Io.Reader) !AxisSource {
            const axis_source = try reader.takeEnum(AxisSource, .native);

            log.debug("<- wl_pointer@{d}.axis_source: axis_source={t}", .{ self.id, axis_source });

            return axis_source;
        }

        pub fn onAxisStop(self: Pointer, reader: *std.Io.Reader) !struct { u32, Axis } {
            const time = try reader.takeInt(u32, .native);
            const axis = try reader.takeEnum(Axis, .native);

            log.debug("<- wl_pointer@{d}.", .{self.id});

            return .{ time, axis };
        }

        pub fn onAxisDiscrete(self: Pointer, reader: *std.Io.Reader) !struct { Axis, i32 } {
            const axis = try reader.takeEnum(Axis, .native);
            const discrete = try reader.takeInt(i32, .native);

            log.debug("<- wl_pointer@{d}.axis_discrete: axis={t} discrete={d}", .{
                self.id,
                axis,
                discrete,
            });

            return .{ axis, discrete };
        }

        pub fn onAxisValue120(self: Pointer, reader: *std.Io.Reader) !struct { Axis, i32 } {
            const axis = try reader.takeEnum(Axis, .native);
            const value120 = try reader.takeInt(i32, .native);

            log.debug("<- wl_pointer@{d}.axis_value120: axis={t} value120={d}", .{
                self.id,
                axis,
                value120,
            });

            return .{ axis, value120 };
        }

        pub fn onAxisRelativeDirection(
            self: Pointer,
            reader: *std.Io.Reader,
        ) !struct { Axis, AxisRelativeDirection } {
            const axis = try reader.takeEnum(Axis, .native);
            const direction = try reader.takeEnum(AxisRelativeDirection, .native);

            log.debug("<- wl_pointer@{d}.axis_relative_direction: axis={t} direction={d}", .{
                self.id,
                axis,
                direction,
            });

            return .{ axis, direction };
        }

        pub fn onWarp(self: Pointer, reader: *std.Io.Reader) !struct { Fixed, Fixed } {
            const surface_x = try reader.takeStruct(Fixed, .native);
            const surface_y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_pointer@{d}.warp: surface_x={any} surface_y={any}", .{
                self.id,
                surface_x,
                surface_y,
            });

            return .{ surface_x, surface_y };
        }
    };

    pub const Keyboard = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            release = 0,
        };

        pub const Event = enum(u16) {
            keymap = 0,
            enter = 1,
            leave = 2,
            key = 3,
            modifiers = 4,
            repeat_info = 5,
        };

        pub const KeymapFormat = enum(u32) {
            no_keymap = 0,
            xkb_v1 = 1,
        };

        pub const KeyState = enum(u32) {
            released = 0,
            pressed = 1,
            repeated = 2,
        };

        pub fn release(self: Keyboard, writer: *std.Io.Writer) void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_keyboard@{d}.release", .{self.id});
        }

        pub fn onKeymap(self: Keyboard, socket: Fd) !struct { KeymapFormat, Fd, u32 } {
            var buf: [512]u8 = undefined;
            const data, const fd = try receiveMessageFd(socket, &buf);

            var reader = std.Io.Reader.fixed(data);
            const format = try reader.takeEnum(KeymapFormat, .native);
            const size = try reader.takeInt(u32, .native);

            log.debug("<- wl_pointer@{d}.keymap: format={t} fd={d} size={d}", .{ self.id, format, fd, size });

            return .{ format, fd, size };
        }

        pub fn onEnter(
            self: Keyboard,
            reader: *std.Io.Reader,
        ) !struct { u32, Surface, BoundedArray(u32, 64) } {
            const serial = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);
            const array = try readArray(reader, @sizeOf(u32) * 64);
            const keys = std.mem.bytesAsSlice(u32, array.slice());

            log.debug("<- wl_pointer@{d}.enter: serial={d} surface={d} keys={any}", .{
                self.id,
                serial,
                surface.id,
                keys,
            });

            var result: BoundedArray(u32, 64) = .{};
            try result.appendSlice(keys);

            return .{ serial, .{ .id = surface }, result };
        }

        pub fn onLeave(self: Keyboard, reader: *std.Io.Reader) !struct { u32, Surface } {
            const serial = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);

            log.debug("<- wl_pointer@{d}.leave: serial={d} surface={d}", .{ self.id, serial, surface });

            return .{ serial, .{ .id = surface } };
        }

        pub fn onKey(self: Keyboard, reader: *std.Io.Reader) !struct { u32, u32, u32, KeyState } {
            const serial = try reader.takeInt(u32, .native);
            const time = try reader.takeInt(u32, .native);
            const key = try reader.takeInt(u32, .native);
            const state = try reader.takeEnum(KeyState, .native);

            log.debug("<- wl_pointer@{d}.key: serial={d} time={d} key={d} state={t}", .{
                self.id,
                serial,
                time,
                key,
                state,
            });

            return .{ serial, time, key, state };
        }

        pub fn onModifiers(self: Keyboard, reader: *std.Io.Reader) !struct { u32, u32, u32, u32, u32 } {
            const serial = try reader.takeInt(u32, .native);
            const mods_depressed = try reader.takeInt(u32, .native);
            const mods_latched = try reader.takeInt(u32, .native);
            const mods_locked = try reader.takeInt(u32, .native);
            const group = try reader.takeInt(u32, .native);

            log.debug("<- wl_pointer@{d}.modifiers: serial={d} mods_depressed={d} mods_latched={d} mods_locked={d} group={d}", .{
                self.id,
                serial,
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
            });

            return .{ serial, mods_depressed, mods_latched, mods_locked, group };
        }

        pub fn onRepeatInfo(self: Keyboard, reader: *std.Io.Reader) !struct { i32, i32 } {
            const rate = try reader.takeInt(i32, .native);
            const delay = try reader.takeInt(i32, .native);

            log.debug("<- wl_pointer@{d}.repeat_info: rate={d} delay={d}", .{ self.id, rate, delay });

            return .{ rate, delay };
        }
    };

    pub const Touch = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            release = 0,
        };

        pub const Event = enum(u16) {
            down = 0,
            up = 1,
            motion = 2,
            frame = 3,
            cancel = 4,
            shape = 5,
            orientation = 6,
        };

        pub fn release(self: Touch, writer: *std.Io.Writer) void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_touch@{d}.release", .{self.id});
        }

        pub fn onDown(self: Touch, reader: *std.Io.Reader) !struct { u32, u32, Surface, i32, Fixed, Fixed } {
            const serial = try reader.takeInt(u32, .native);
            const time = try reader.takeInt(u32, .native);
            const surface = try reader.takeInt(ObjectId, .native);
            const id = try reader.takeInt(i32, .native);
            const x = try reader.takeStruct(Fixed, .native);
            const y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_touch@{d}.down: serial={d} time={d} surface={d} id={d} x={any} y={any}", .{
                self.id,
                serial,
                time,
                surface,
                id,
                x,
                y,
            });

            return .{ serial, time, .{ .id = surface }, id, x, y };
        }

        pub fn onUp(self: Touch, reader: *std.Io.Reader) !struct { u32, u32, i32 } {
            const serial = try reader.takeInt(u32, .native);
            const time = try reader.takeInt(u32, .native);
            const id = try reader.takeInt(i32, .native);

            log.debug("<- wl_touch@{d}.up: serial={d} time={d} id={d}", .{ self.id, serial, time, id });

            return .{ serial, time, id };
        }

        pub fn onMotion(self: Touch, reader: *std.Io.Reader) !struct { u32, i32, Fixed, Fixed } {
            const time = try reader.takeInt(u32, .native);
            const id = try reader.takeInt(i32, .native);
            const x = try reader.takeStruct(Fixed, .native);
            const y = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_touch@{d}.motion: time={d} id={d} x={any} y={any}", .{ self.id, time, id, x, y });

            return .{ time, id, x, y };
        }

        pub fn onFrame(self: Touch) void {
            log.debug("<- wl_touch@{d}.frame", .{self.id});
        }

        pub fn onCancel(self: Touch) void {
            log.debug("<- wl_touch@{d}.cancel", .{self.id});
        }

        pub fn onShape(self: Touch, reader: *std.Io.Reader) !struct { i32, Fixed, Fixed } {
            const id = try reader.takeInt(i32, .native);
            const major = try reader.takeStruct(Fixed, .native);
            const minor = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_touch@{d}.shape: id={d} major={any} minor={d}", .{ self.id, id, major, minor });

            return .{ id, major, minor };
        }

        pub fn onOrientation(self: Touch, reader: *std.Io.Reader) !struct { i32, Fixed } {
            const id = try reader.takeInt(i32, .native);
            const orientation = try reader.takeStruct(Fixed, .native);

            log.debug("<- wl_touch@{d}.orientation: id={d} orientation={any}", .{ self.id, id, orientation });

            return .{ id, orientation };
        }
    };

    pub const Output = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            release = 0,
        };

        pub const Event = enum(u16) {
            geometry = 0,
            mode = 1,
            done = 2,
            scale = 3,
            name = 4,
            description = 5,
        };

        pub const Subpixel = enum(u32) {
            unknown = 0,
            none = 1,
            horizontal_rgb = 2,
            horizontal_bgr = 3,
            vertical_rgb = 4,
            vertical_bgr = 5,
        };

        pub const Transform = enum(u32) {
            normal = 0,
            @"90" = 1,
            @"180" = 2,
            @"270" = 3,
            flipped = 4,
            flipped_90 = 5,
            flipped_180 = 6,
            flipped_270 = 7,
        };

        pub const Mode = packed struct(u32) {
            current: bool = false,
            preferred: bool = false,
            _unused: u30 = 0,
        };

        pub fn release(self: Output, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.release), &.{});

            log.debug("-> wl_output@{d}.release", .{self.id});
        }

        pub fn onGeometry(
            self: Output,
            reader: *std.Io.Reader,
        ) !struct { i32, i32, i32, i32, Subpixel, String, String, Transform } {
            const x = try reader.takeInt(i32, .native);
            const y = try reader.takeInt(i32, .native);
            const physical_width = try reader.takeInt(i32, .native);
            const physical_height = try reader.takeInt(i32, .native);
            const subpixel = try reader.takeEnum(Subpixel, .native);
            const make = try readString(reader, string_max_len);
            const model = try readString(reader, string_max_len);
            const transform = try reader.takeEnum(Transform, .native);

            log.debug("<- wl_output@{d}.geometry: x={d} y={d} physical_width={d} physical_height={d} subpixel={t} make={s} model={s} transform={t}", .{
                self.id,
                x,
                y,
                physical_width,
                physical_height,
                subpixel,
                make.slice(),
                model.slice(),
                transform,
            });

            return .{ x, y, physical_width, physical_height, subpixel, make, model, transform };
        }

        pub fn onMode(self: Output, reader: *std.Io.Reader) !struct { Mode, i32, i32, i32 } {
            const flags = try reader.takeStruct(Mode, .native);
            const width = try reader.takeInt(i32, .native);
            const height = try reader.takeInt(i32, .native);
            const refresh = try reader.takeInt(i32, .native);

            log.debug("<- wl_output@{d}.mode: flags={any} width={d} height={d} refresh={d}", .{
                self.id,
                flags,
                width,
                height,
                refresh,
            });

            return .{ flags, width, height, refresh };
        }

        pub fn onDone(self: Output) void {
            log.debug("<- wl_output@{d}.done", .{self.id});
        }

        pub fn onScale(self: Output, reader: *std.Io.Reader) !i32 {
            const factor = try reader.takeInt(i32, .native);

            log.debug("<- wl_output@{d}.scale: factor={d}", .{ self.id, factor });

            return factor;
        }

        pub fn onName(self: Output, reader: *std.Io.Reader) !String {
            const name = try readString(reader, string_max_len);

            log.debug("<- wl_output@{d}.name: name={s}", .{ self.id, name.slice() });

            return name;
        }

        pub fn onDescription(self: Output, reader: *std.Io.Reader) !String {
            const description = try readString(reader, string_max_len);

            log.debug("<- wl_output@{d}.description: description={s}", .{ self.id, description.slice() });

            return description;
        }
    };

    pub const Region = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            add = 1,
            subtract = 2,
        };

        pub fn destroy(self: Region, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_region@{d}.destroy", .{self.id});
        }

        pub fn add(self: Region, writer: *std.Io.Writer, x: i32, y: i32, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.add), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> wl_region@{d}.add: x={d} y={d} width={d} height={d}", .{ self.id, x, y, width, height });
        }

        pub fn subtract(self: Region, writer: *std.Io.Writer, x: i32, y: i32, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.subtract), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> wl_region@{d}.subtract: x={d} y={d} width={d} height={d}", .{ self.id, x, y, width, height });
        }
    };

    pub const Subcompositor = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            get_subsurface = 1,
        };

        pub const Error = enum(u32) {
            bad_surface = 0,
            bad_parent = 1,
        };

        pub fn destroy(self: Subcompositor, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_subcompositor@{d}.destroy", .{self.id});
        }

        pub fn getSubsurface(
            self: Subcompositor,
            writer: *std.Io.Writer,
            surface: Surface,
            parent: Surface,
        ) !Subsurface {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_subsurface), &.{
                .{ .new_id = new_id },
                .{ .object = surface.id },
                .{ .object = parent.id },
            });

            log.debug("-> wl_subcompositor@{d}.get_subsurface: subsurface={d} surface={d} parent={d}", .{self.id});

            return .{ .id = new_id };
        }
    };

    pub const Subsurface = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            set_position = 1,
            place_above = 2,
            place_below = 3,
            set_sync = 4,
            set_desync = 5,
        };

        pub const Error = enum(u32) {
            bad_surface = 0,
        };

        pub fn destroy(self: Subsurface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_subsurface@{d}.destroy", .{self.id});
        }

        pub fn setPosition(self: Subsurface, writer: *std.Io.Writer, x: i32, y: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_position), &.{
                .{ .int = x },
                .{ .int = y },
            });

            log.debug("-> wl_subsurface@{d}.set_position: x={d} y={d}", .{ self.id, x, y });
        }

        pub fn placeAbove(self: Subsurface, writer: *std.Io.Writer, sibling: Surface) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.place_above), &.{
                .{ .object = sibling.id },
            });

            log.debug("-> wl_subsurface@{d}.place_above: sibling={d}", .{ self.id, sibling.id });
        }

        pub fn placeBelow(self: Subsurface, writer: *std.Io.Writer, sibling: Surface) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.place_below), &.{
                .{ .object = sibling.id },
            });

            log.debug("-> wl_subsurface@{d}.place_below: sibling={d}", .{ self.id, sibling.id });
        }

        pub fn setSync(self: Subsurface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_sync), &.{});

            log.debug("-> wl_subsurface@{d}.set_sync", .{self.id});
        }

        pub fn setDesync(self: Subsurface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_dssync), &.{});

            log.debug("-> wl_subsurface@{d}.set_desync", .{self.id});
        }
    };

    pub const Fixes = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            destroy_registry = 1,
            ack_global_remove = 2,
        };

        pub const Error = enum(u32) {
            invalid_ack_remove = 0,
        };

        pub fn destroy(self: Fixes, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> wl_fixes@{d}.destroy", .{self.id});
        }

        pub fn destroyRegistry(self: Fixes, writer: *std.Io.Writer, registry: Registry) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy_registry), &.{
                .{ .object = registry.id },
            });

            log.debug("-> wl_fixes@{d}.destroy_registry: registry={d}", .{ self.id, registry.id });
        }

        pub fn ackGlobalRemove(self: Fixes, writer: *std.Io.Writer, registry: Registry, name: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.ack_global_remove), &.{
                .{ .object = registry.id },
                .{ .uint = name },
            });

            log.debug("-> wl_fixes@{d}.ack_global_remove: registry={d} name={d}", .{ self.id, registry.id, name });
        }
    };

    pub const zxdg = struct {
        pub const DecorationManagerV1 = struct {
            id: ObjectId,

            pub const interface = "zxdg_decoration_manager_v1";

            pub const Request = enum(u16) {
                destroy = 0,
                get_toplevel_decoration = 1,
            };

            pub fn getToplevelDecoration(
                self: DecorationManagerV1,
                writer: *std.Io.Writer,
                toplevel: xdg.Toplevel,
            ) !ToplevelDecorationV1 {
                const new_id = id_allocator.alloc();

                try sendMessage(writer, self.id, @intFromEnum(Request.get_toplevel_decoration), &.{
                    .{ .new_id = new_id },
                    .{ .object = toplevel.id },
                });

                log.debug(
                    "-> zxdg_decoration_manager_v1@{d}.get_toplevel_decoration: toplevel_decoration={d} xdg_toplevel={d}",
                    .{ self.id, new_id, toplevel.id },
                );

                return .{ .id = new_id };
            }
        };

        pub const ToplevelDecorationV1 = struct {
            id: ObjectId,

            pub const Request = enum(u16) {
                destroy = 0,
                set_mode = 1,
                unset_mode = 2,
            };

            pub const Event = enum(u16) {
                configure = 0,
            };

            pub const Error = enum(u32) {
                unconfigured_buffer = 0,
                already_constructed = 1,
                orphaned = 2,
                invalid_mode = 3,
            };

            pub const Mode = enum(u32) {
                client_side = 1,
                server_side = 2,
            };

            pub fn setMode(self: ToplevelDecorationV1, writer: *std.Io.Writer, mode: Mode) !void {
                try sendMessage(writer, self.id, @intFromEnum(Request.set_mode), &.{.{ .uint = @intFromEnum(mode) }});

                log.debug("-> zxdg_toplevel_decoration@{d}.set_mode: mode={t}", .{ self.id, mode });
            }

            pub fn onConfigure(self: ToplevelDecorationV1, reader: *std.Io.Reader) !Mode {
                const mode = try reader.takeEnum(Mode, .native);

                log.debug("<- zxdg_toplevel_decoration@{d}.configure: mode={t}", .{ self.id, mode });

                return mode;
            }
        };
    };
};

pub const xdg = struct {
    pub const WmBase = struct {
        id: ObjectId,

        pub const interface = "xdg_wm_base";

        pub const Request = enum(u16) {
            destroy = 0,
            create_positioner = 1,
            get_xdg_surface = 2,
            pong = 3,
        };

        pub const Event = enum(u16) {
            ping = 0,
        };

        pub const Error = enum(u32) {
            role = 0,
            defunct_surfaces = 1,
            not_the_topmost_popup = 2,
            invalid_popup_parent = 3,
            invalid_surface_state = 4,
            invalid_positioner = 5,
            unresponsive = 6,
        };

        pub fn destroy(self: WmBase, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> xdg_wm_base@{d}.destroy", .{self.id});
        }

        pub fn createPositioner(self: WmBase, writer: *std.Io.Writer) !Positioner {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.create_positioner), &.{
                .{ .new_id = new_id },
            });

            log.debug("-> xdg_wm_base@{d}.create_positioner: positioner={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getXdgSurface(self: WmBase, writer: *std.Io.Writer, surface: wl.Surface) !Surface {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_xdg_surface), &.{
                .{ .new_id = new_id },
                .{ .object = surface.id },
            });

            log.debug("-> xdg_wm_base@{d}.get_xdg_surface: xdg_surface={d} wl_surface={d}", .{ self.id, new_id, surface.id });

            return .{ .id = new_id };
        }

        pub fn pong(self: WmBase, writer: *std.Io.Writer, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.pong), &.{.{ .uint = serial }});

            log.debug("-> xdg_wm_base@{d}.pong: serial={d}", .{ self.id, serial });
        }

        pub fn onPing(self: WmBase, reader: *std.Io.Reader) !u32 {
            const serial = try reader.takeInt(u32, .native);

            log.debug("<- xdg_wm_base@{d}.ping: serial={d}", .{ self.id, serial });

            return serial;
        }
    };

    pub const Positioner = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            set_size = 1,
            set_anchor_rect = 2,
            set_anchor = 3,
            set_gravity = 4,
            set_constraint_adjustment = 5,
            set_offset = 6,
            set_reactive = 7,
            set_parent_size = 8,
            set_parent_configure = 9,
        };

        pub const Error = enum(u32) {
            invalid_input = 0,
        };

        pub const Anchor = enum(u32) {
            none = 0,
            top = 1,
            bottom = 2,
            left = 3,
            right = 4,
            top_left = 5,
            bottom_left = 6,
            top_right = 7,
            bottom_right = 8,
        };

        pub const Gravity = enum(u32) {
            none = 0,
            top = 1,
            bottom = 2,
            left = 3,
            right = 4,
            top_left = 5,
            bottom_left = 6,
            top_right = 7,
            bottom_right = 8,
        };

        pub const ConstraintAdjustment = packed struct(u32) {
            slide_x: bool = false,
            slide_y: bool = false,
            flip_x: bool = false,
            flip_y: bool = false,
            resize_x: bool = false,
            resize_y: bool = false,
            _unused: u26 = 0,

            pub const none: ConstraintAdjustment = .{};
        };

        pub fn destroy(self: Positioner, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> xdg_positioner@{d}.destroy", .{self.id});
        }

        pub fn setSize(self: Positioner, writer: *std.Io.Writer, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_size), &.{
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> xdg_positioner@{d}.set_size: width={d} height={d}", .{ self.id, width, height });
        }

        pub fn setAnchorRect(
            self: Positioner,
            writer: *std.Io.Writer,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_anchor_rect), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> xdg_positioner@{d}.set_size: x={d} y={d} width={d} height={d}", .{
                self.id,
                x,
                y,
                width,
                height,
            });
        }

        pub fn setAnchor(self: Positioner, writer: *std.Io.Writer, anchor: Anchor) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_anchor), &.{
                .{ .uint = @intFromEnum(anchor) },
            });

            log.debug("-> xdg_positioner@{d}.set_anchor: anchor={t}", .{ self.id, anchor });
        }

        pub fn setGravity(self: Positioner, writer: *std.Io.Writer, gravity: Gravity) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_gravity), &.{
                .{ .uint = @intFromEnum(gravity) },
            });

            log.debug("-> xdg_positioner@{d}.set_gravity: gravity={t}", .{ self.id, gravity });
        }

        pub fn setConstraintAdjustment(
            self: Positioner,
            writer: *std.Io.Writer,
            constraint_adjustment: ConstraintAdjustment,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_constraint_adjustment), &.{
                .{ .uint = @bitCast(constraint_adjustment) },
            });

            log.debug("-> xdg_positioner@{d}.set_constraint_adjustment: constraint_adjustment={any}", .{
                self.id,
                constraint_adjustment.id,
            });
        }

        pub fn setOffset(self: Positioner, writer: *std.Io.Writer, x: i32, y: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_offset), &.{
                .{ .int = x },
                .{ .int = y },
            });

            log.debug("-> xdg_positioner@{d}.set_offset: x={d} y={d}", .{ self.id, x, y });
        }

        pub fn setReactive(self: Positioner, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_reactive), &.{});

            log.debug("-> xdg_positioner@{d}.set_reactive", .{self.id});
        }

        pub fn setParentSize(
            self: Positioner,
            writer: *std.Io.Writer,
            parent_width: i32,
            parent_height: i32,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_parent_size), &.{
                .{ .int = parent_width },
                .{ .int = parent_height },
            });

            log.debug("-> xdg_positioner@{d}.set_parent_size: parent_width={d} parent_height={d}", .{
                self.id,
                parent_width,
                parent_height,
            });
        }

        pub fn setParentConfigure(self: Positioner, writer: *std.Io.Writer, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_parent_configure), &.{
                .{ .uint = serial },
            });

            log.debug("-> xdg_positioner@{d}.set_parent_configure: serial={d}", .{ self.id, serial });
        }
    };

    pub const Surface = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            get_toplevel = 1,
            get_popup = 2,
            set_window_geometry = 3,
            ack_configure = 4,
        };

        pub const Event = enum(u16) {
            configure = 0,
        };

        pub const Error = enum(u32) {
            not_constructed = 1,
            already_constructed = 2,
            unconfigured_buffer = 3,
            invalid_serial = 4,
            invalid_size = 5,
            defunct_role_object = 6,
        };

        pub fn destroy(self: Surface, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> xdg_surface@{d}.destroy", .{self.id});
        }

        pub fn getToplevel(self: Surface, writer: *std.Io.Writer) !Toplevel {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_toplevel), &.{.{ .new_id = new_id }});

            log.debug("-> xdg_surface@{d}.get_toplevel: xdg_toplevel={d}", .{ self.id, new_id });

            return .{ .id = new_id };
        }

        pub fn getPopup(self: Surface, writer: *std.Io.Writer, parent: ?Surface, positioner: Positioner) !Popup {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_popup), &.{
                .{ .new_id = new_id },
                .{ .object = if (parent) |p| p.id else 0 },
                .{ .object = positioner.id },
            });

            log.debug("-> xdg_surface@{d}.get_popup: popup={d} parent={?any} positioner={d}", .{
                self.id,
                parent,
                positioner,
            });

            return .{ .id = new_id };
        }

        pub fn setWindowGeometry(
            self: Surface,
            writer: *std.Io.Writer,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_window_geometry), &.{
                .{ .int = x },
                .{ .int = y },
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> xdg_surface@{d}.set_window_geometry: x={d} y={d} width={d} height={d}", .{
                self.id,
                x,
                y,
                width,
                height,
            });
        }

        pub fn ackConfigure(self: Surface, writer: *std.Io.Writer, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.ack_configure), &.{.{ .uint = serial }});

            log.debug("-> xdg_surface@{d}.ack_configure: serial={d}", .{ self.id, serial });
        }

        pub fn onConfigure(self: Surface, reader: *std.Io.Reader) !u32 {
            const serial = try reader.takeInt(u32, .native);

            log.debug("<- xdg_surface@{d}.configure: serial={d}", .{ self.id, serial });

            return serial;
        }
    };

    pub const Toplevel = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            set_parent = 1,
            set_title = 2,
            set_app_id = 3,
            show_window_menu = 4,
            move = 5,
            resize = 6,
            set_max_size = 7,
            set_min_size = 8,
            set_maximized = 9,
            unset_maximized = 10,
            set_fullscreen = 11,
            unset_fullscreen = 12,
            set_minimized = 13,
        };

        pub const Event = enum(u16) {
            configure = 0,
            close = 1,
            configure_bounds = 2,
            wm_capabilities = 3,
        };

        pub const Error = enum(u32) {
            invalid_resize_edge = 0,
            invalid_parent = 1,
            invalid_size = 2,
        };

        pub const ResizeEdge = packed struct(u32) {
            top: bool = false,
            bottom: bool = false,
            left: bool = false,
            right: bool = false,

            pub const none: ResizeEdge = .{};
            pub const top_left: ResizeEdge = .{ .top = true, .left = true };
            pub const top_right: ResizeEdge = .{ .top = true, .right = true };
            pub const bottom_left: ResizeEdge = .{ .bottom = true, .left = true };
            pub const bottom_right: ResizeEdge = .{ .bottom = true, .right = true };
        };

        pub const State = enum(u32) {
            maximized = 1,
            fullscreen = 2,
            resizing = 3,
            activated = 4,
            tiled_left = 5,
            tiled_right = 6,
            tiled_top = 7,
            tiled_bottom = 8,
            suspended = 9,
            constrained_left = 10,
            constrained_right = 11,
            constrained_top = 12,
            constrained_bottom = 13,
        };

        pub const WmCapabilities = enum(u32) {
            window_menu = 1,
            maximize = 2,
            fullscreen = 3,
            minimize = 4,
        };

        pub fn destroy(self: Toplevel, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> xdg_toplevel@{d}.destroy", .{self.id});
        }

        pub fn setParent(self: Toplevel, writer: *std.Io.Writer, parent: ?Toplevel) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_parent), &.{
                .{ .object = if (parent) |p| p.id else 0 },
            });

            log.debug("-> xdg_toplevel@{d}.set_parent: parent={?any}", .{ self.id, parent });
        }

        pub fn setTitle(self: Toplevel, writer: *std.Io.Writer, title: []const u8) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_title), &.{
                .{ .string = title },
            });

            log.debug("-> xdg_toplevel@{d}.set_title: title={s}", .{ self.id, title });
        }

        pub fn setAppId(self: Toplevel, writer: *std.Io.Writer, app_id: []const u8) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_app_id), &.{
                .{ .string = app_id },
            });

            log.debug("-> xdg_toplevel@{d}.set_app_id: app_id={s}", .{ self.id, app_id });
        }

        pub fn showWindowMenu(
            self: Toplevel,
            writer: *std.Io.Writer,
            seat: wl.Seat,
            serial: u32,
            x: i32,
            y: i32,
        ) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.show_window_menu), &.{
                .{ .object = seat.id },
                .{ .uint = serial },
                .{ .int = x },
                .{ .int = y },
            });

            log.debug("-> xdg_toplevel@{d}.show_window_menu: seat={d} serial={d} x={d} y={d}", .{
                self.id,
                seat.id,
                serial,
                x,
                y,
            });
        }

        pub fn move(self: Toplevel, writer: *std.Io.Writer, seat: wl.Seat, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.move), &.{
                .{ .object = seat.id },
                .{ .uint = serial },
            });

            log.debug("-> xdg_toplevel@{d}.move: seat={d} serial={d}", .{ self.id, seat.id, serial });
        }

        pub fn resize(self: Toplevel, writer: *std.Io.Writer, seat: wl.Seat, serial: u32, edges: ResizeEdge) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.resize), &.{
                .{ .object = seat.id },
                .{ .uint = serial },
                .{ .uint = @bitCast(edges) },
            });

            log.debug("-> xdg_toplevel@{d}.resize: seat={d} serial={d} edges={any}", .{ self.id, seat.id, serial, edges });
        }

        pub fn setMaxSize(self: Toplevel, writer: *std.Io.Writer, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_max_size), &.{
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> xdg_toplevel@{d}.set_max_size: width={d} height={d}", .{ self.id, width, height });
        }

        pub fn setMinSize(self: Toplevel, writer: *std.Io.Writer, width: i32, height: i32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_min_size), &.{
                .{ .int = width },
                .{ .int = height },
            });

            log.debug("-> xdg_toplevel@{d}.set_min_size: width={d} height={d}", .{ self.id, width, height });
        }

        pub fn setMaximized(self: Toplevel, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_maximized), &.{});

            log.debug("-> xdg_toplevel@{d}.set_maximized", .{self.id});
        }

        pub fn setUnsetMaximized(self: Toplevel, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_unset_maximized), &.{});

            log.debug("-> xdg_toplevel@{d}.set_unset_maximized", .{self.id});
        }

        pub fn setFullscreen(self: Toplevel, writer: *std.Io.Writer, output: ?wl.Output) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_fullscreen), &.{
                .{ .object = if (output) |o| o.id else 0 },
            });

            log.debug("-> xdg_toplevel@{d}.set_fullscreen", .{self.id});
        }

        pub fn setUnsetFullscreen(self: Toplevel, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_unset_fullscreen), &.{});

            log.debug("-> xdg_toplevel@{d}.set_unset_fullscreen", .{self.id});
        }

        pub fn setMinimized(self: Toplevel, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_minimized), &.{});

            log.debug("-> xdg_toplevel@{d}.set_minimized", .{self.id});
        }

        pub fn onConfigure(self: Toplevel, reader: *std.Io.Reader) !struct { i32, i32, BoundedArray(State, 8) } {
            const width = try reader.takeInt(i32, .native);
            const height = try reader.takeInt(i32, .native);
            const data = try readArray(reader, 32);

            var states: BoundedArray(State, 8) = .{};
            try states.appendSlice(@alignCast(std.mem.bytesAsSlice(State, data.slice())));

            log.debug("<- xdg_toplevel@{d}.configure: width={d} height={d} states={any}", .{
                self.id,
                width,
                height,
                states.slice(),
            });

            return .{ width, height, states };
        }

        pub fn onClose(self: Toplevel) void {
            log.debug("<- xdg_toplevel@{d}.close", .{self.id});
        }

        pub fn onConfigureBounds(self: Toplevel, reader: *std.Io.Reader) !struct { i32, i32 } {
            const width = try reader.takeInt(i32, .native);
            const height = try reader.takeInt(i32, .native);

            log.debug("<- xdg_toplevel@{d}.configure_bounds: width={d} height={d}", .{ self.id, width, height });

            return .{ width, height };
        }

        pub fn onWmCapabilities(self: Toplevel, reader: *std.Io.Reader) !BoundedArray(WmCapabilities, 8) {
            const data = try readArray(reader, 32);

            var capabilities: BoundedArray(WmCapabilities, 8) = .{};
            try capabilities.appendSlice(@alignCast(std.mem.bytesAsSlice(WmCapabilities, data.slice())));

            log.debug("<- xdg_toplevel@{d}.wm_capabilities: capabilities={any}", .{ self.id, capabilities.slice() });

            return capabilities;
        }
    };

    pub const Popup = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            grab = 1,
            reposition = 2,
        };

        pub const Event = enum(u16) {
            configure = 0,
            popup_done = 1,
            repositioned = 2,
        };

        pub const Error = enum(u32) {
            invalid_grab = 0,
        };

        pub fn destroy(self: Popup, writer: *std.Io.Writer) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.destroy), &.{});

            log.debug("-> xdg_popup@{d}.destroy", .{self.id});
        }

        pub fn grab(self: Popup, writer: *std.Io.Writer, seat: wl.Seat, serial: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.grab), &.{
                .{ .object = seat.id },
                .{ .uint = serial },
            });

            log.debug("-> xdg_popup@{d}.grab: seat={d} serial={d}", .{ self.id, seat.id, serial });
        }

        pub fn reposition(self: Popup, writer: *std.Io.Writer, positioner: Positioner, token: u32) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.reposition), &.{
                .{ .object = positioner.id },
                .{ .uint = token },
            });

            log.debug("-> xdg_popup@{d}.reposition: positioner={d} token={d}", .{
                self.id,
                positioner.id,
                token,
            });
        }

        pub fn onConfigure(self: Popup, reader: *std.Io.Reader) !struct { i32, i32, i32, i32 } {
            const x = try reader.takeInt(i32, .native);
            const y = try reader.takeInt(i32, .native);
            const width = try reader.takeInt(i32, .native);
            const height = try reader.takeInt(i32, .native);

            log.debug("<- xdg_popup@{d}.configure: x={d} y={d} width={d} height={d}", .{
                self.id,
                x,
                y,
                width,
                height,
            });

            return .{ x, y, width, height };
        }

        pub fn onPopupDone(self: Popup) void {
            log.debug("<- xdg_popup@{d}.popup_done", .{self.id});
        }

        pub fn onRepositioned(self: Popup, reader: *std.Io.Reader) !u32 {
            const token = try reader.takeInt(u32, .native);

            log.debug("<- xdg_popup@{d}.repositioned: token={d}", .{ self.id, token });

            return token;
        }
    };
};

pub const zxdg = struct {
    pub const DecorationManagerV1 = struct {
        id: ObjectId,

        pub const interface = "zxdg_decoration_manager_v1";

        pub const Request = enum(u16) {
            destroy = 0,
            get_toplevel_decoration = 1,
        };

        pub fn getToplevelDecoration(
            self: DecorationManagerV1,
            writer: *std.Io.Writer,
            toplevel: xdg.Toplevel,
        ) !ToplevelDecorationV1 {
            const new_id = id_allocator.alloc();

            try sendMessage(writer, self.id, @intFromEnum(Request.get_toplevel_decoration), &.{
                .{ .new_id = new_id },
                .{ .object = toplevel.id },
            });

            log.debug(
                "-> zxdg_decoration_manager_v1@{d}.get_toplevel_decoration: toplevel_decoration={d} xdg_toplevel={d}",
                .{ self.id, new_id, toplevel.id },
            );

            return .{ .id = new_id };
        }
    };

    pub const ToplevelDecorationV1 = struct {
        id: ObjectId,

        pub const Request = enum(u16) {
            destroy = 0,
            set_mode = 1,
            unset_mode = 2,
        };

        pub const Event = enum(u16) {
            configure = 0,
        };

        pub const Error = enum(u32) {
            unconfigured_buffer = 0,
            already_constructed = 1,
            orphaned = 2,
            invalid_mode = 3,
        };

        pub const Mode = enum(u32) {
            client_side = 1,
            server_side = 2,
        };

        pub fn setMode(self: ToplevelDecorationV1, writer: *std.Io.Writer, mode: Mode) !void {
            try sendMessage(writer, self.id, @intFromEnum(Request.set_mode), &.{.{ .uint = @intFromEnum(mode) }});

            log.debug("-> zxdg_toplevel_decoration@{d}.set_mode: mode={t}", .{ self.id, mode });
        }

        pub fn onConfigure(self: ToplevelDecorationV1, reader: *std.Io.Reader) !Mode {
            const mode = try reader.takeEnum(Mode, .native);

            log.debug("<- zxdg_toplevel_decoration@{d}.configure: mode={t}", .{ self.id, mode });

            return mode;
        }
    };
};
