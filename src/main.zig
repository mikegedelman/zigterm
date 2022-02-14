const std = @import("std");
const zlm = @import("zlm");

const text = @import("text.zig");

const c = @cImport({
    @cInclude("util.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/select.h");
    @cInclude("fcntl.h");

    @cInclude("glad/glad.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
});

var term_buf: [2048]u8 = undefined;
var term_buf_pos: usize = 0;

fn load_file() anyerror!std.ArrayList(i32) {
    const cwd = std.fs.cwd();

    const file: std.fs.File = try cwd.openFile("input.txt", .{ .mode = std.fs.File.OpenMode.read_only });
    defer file.close();

    var buffer: [500]u8 = undefined;
    var list = std.ArrayList(i32).init(std.testing.allocator);
    const reader = file.reader();
    while (true) {
        const result = try reader.readUntilDelimiterOrEof(buffer[0..], '\n');
        if (result == null) {
            break;
        }

        try list.append(try std.fmt.parseInt(i32, result.?, 10));
    }

    for (list.items) |input| {
        std.debug.print("{}\n", .{input});
    }

    // const t = @typeInfo(@TypeOf(list));
    // std.debug.print("{s}\n", .{t});

    return list;
}

fn update(master_fd: i32, events: std.ArrayList(c.SDL_Event)) anyerror!void {
    var fds: c.fd_set = undefined;
    c.FD_ZERO(&fds);
    c.FD_SET(&fds, master_fd);
    if (c.select(master_fd + 1, &fds, 0, 0) == 1) {
        const bytes_read = try std.os.read(master_fd, term_buf[term_buf_pos..]);
        term_buf_pos += bytes_read;
    }

    // var write_buf: [256]u8 = undefined;
    // var write_buf_pos: usize = 0;
    // std.debug.print("len: {}\n", .{events.len});
    for (events.items) |event| {
        std.debug.print("{}\n", .{event.key.keysym.sym});
        // write_buf[write_buf_pos] = @truncate(u8, @bitCast(u32, event.key.keysym.sym));
        // write_buf_pos += 1;
    }

    // _ = c.write(master_fd, &write_buf, write_buf_pos);
}

fn render() void {
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    text.render(&term_buf, 10.0, 10.0, 1.0, zlm.Vec3.new(1.0, 1.0, 1.0));

    var err: u32 = c.glGetError();
    while (err != 0) {
        std.debug.print("gl error: {}\n", .{err});
        err = c.glGetError();
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    text.allocator = arena.allocator();

    term_buf[0] = 0;

    var amaster: i32 = undefined;
    // var aslave: i32 = undefined;
    var fname: [256]u8 = undefined;
    // var termios: c.termios = undefined;
    // var winsize: c.winsize = undefined;
    // c.openpty(&amaster, &aslave, &fname, &termios, &winsize);
    const pid = c.forkpty(&amaster, &fname, null, null);
    // std.debug.print("pid: {}\namaster: {}\nfname: {s}\n", .{ pid, amaster, fname });

    if (pid == 0) {
        _ = c.close(amaster);
        _ = c.setsid();

        const slave_fd = c.open(@ptrCast([*c]const u8, &fname), c.O_RDWR | c.O_NOCTTY);

        // error: TODO: support C ABI for more targets. https://github.com/ziglang/zig/issues/1481
        // _ = c.ioctl(slave_fd, c.TIOCSCTTY, null);

        _ = c.dup2(slave_fd, 0);
        _ = c.dup2(slave_fd, 1);
        _ = c.dup2(slave_fd, 2);

        _ = c.execl("/bin/dash", "/bin/dash");

        return;
        // std.debug.print("there\n", .{});
    } else {
        std.debug.print("here\n", .{});
        const slave_fd = c.open(@ptrCast([*c]const u8, &fname), c.O_RDWR | c.O_NOCTTY);
        std.debug.print("slave_fd: {}\nslave_pid: {}\n", .{ slave_fd, pid });
    }

    // var buf: [2048]u8 = undefined;
    // var bytes_read = try std.os.read(amaster, &buf);
    // std.debug.print("bytes read: {}\n", .{bytes_read});
    // var i: u32 = 0;
    // while (i < bytes_read) {
    //     std.debug.print("{x} ", .{buf[i]});
    //     i += 1;
    // }
    // std.debug.print("bytes_read: {}\n{s}\n", .{ bytes_read, buf[0..bytes_read] });
    // std.debug.print("bytes read: {}\n\n{s}\n", .{ bytes_read, buf });

    // _ = try std.os.write(amaster, &.{0xd});
    // bytes_read = try std.os.read(amaster, &buf);
    // std.debug.print("bytes_read 2: {}\n{s}\n", .{ bytes_read, buf[0..bytes_read] });
    // var i: u32 = 0;
    // while (i < bytes_read) {
    //     std.debug.print("{x} ", .{buf[i]});
    //     i += 1;
    // }
    // bytes_read = try std.os.read(amaster, &buf);
    // std.debug.print("bytes_read 3: {}\n{s}\n", .{ bytes_read, buf[0..bytes_read] });
    // bytes_read = try std.os.read(amaster, &buf);

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);

    var window = c.SDL_CreateWindow("zigterm", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 640, 400, c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_OPENGL);
    if (window == null) {
        std.debug.panic("Error creating SDL window.\n", .{});
    }
    defer c.SDL_DestroyWindow(window);

    var gl_context = c.SDL_GL_CreateContext(window);
    if (gl_context == null) {
        std.debug.panic("Error creating SDL context.\n", .{});
    }
    defer c.SDL_GL_DeleteContext(gl_context);

    // const list = try load_file();
    // defer list.deinit();

    if (c.gladLoadGLLoader(c.SDL_GL_GetProcAddress) != 1) {
        std.debug.panic("Unable to initialize GLAD.\n", .{});
    }

    try text.init();

    mainloop: while (true) {
        var sdl_event: c.SDL_Event = undefined;
        var events = std.ArrayList(c.SDL_Event).init(std.testing.allocator);
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                else => {},
            }

            try events.append(sdl_event);
        }

        try update(amaster, events);
        render();

        c.SDL_GL_SwapWindow(window);
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
