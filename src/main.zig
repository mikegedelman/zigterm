const std = @import("std");
const zlm = @import("zlm");

const text = @import("text.zig");

const c = @cImport({
    @cInclude("term_setup.h");

    @cInclude("glad/glad.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
});

var tty_buf: [2048]u8 = undefined;
var tty_pos: usize = 0;
var pty_fd: i32 = 0;

fn print_buffer(buf: []u8) void {
    for (buf) |ch| {
        if (ch == 0) {
            break;
        }
        std.debug.print("{x} ", .{ch});
    }
    std.debug.print("\n", .{});
}

fn read_pty() usize {
    var buf: [4096:0]u8 = undefined;
    const bytes_read = std.os.read(pty_fd, &buf) catch |err| switch (err) {
        // if (err != error.WouldBlock) {
        //     std.debug.panic("{}\n", .{err});
        // }
        // return 0;
        error.WouldBlock => 0,
        else => {
            std.debug.panic("{}\n", .{err});
        },
    };
    buf[bytes_read] = 0;

    if (bytes_read > 0) {
        print_buffer(&buf);

        for (buf) |ch| {
            if (ch == 0) {
                break;
            }
            if (ch == 0x7) {
                std.debug.print("ding\n", .{});
                continue;
            }
            if (ch == 0x8) {
                tty_pos -= 1;
                continue;
            }

            tty_buf[tty_pos] = ch;
            tty_pos += 1;
        }
        print_buffer(&tty_buf);
    }
    return bytes_read;
}

// https://wiki.libsdl.org/SDL_Keycode
fn transform_key(code: i32, modifiers: u32) u8 {
    if (code == c.SDLK_LSHIFT or code == c.SDLK_RSHIFT or code == c.SDLK_LCTRL or code == c.SDLK_RCTRL) {
        return 0;
    }

    if (code == c.SDLK_RETURN) {
        return 0xa;
    }
    if (code == c.SDLK_BACKSPACE) {
        return 0x08;
    }

    const shift_pressed: bool = (modifiers & 1) == 1;
    var raw_code = @truncate(u8, @bitCast(u32, code));
    if ((raw_code >= 65) and (raw_code <= 90) and !shift_pressed) {
        raw_code += 32;
    }

    return raw_code;
}

// export fn event(e: ?*const sapp.Event) void {
//     const ev = e.?;

//     if (ev.type != .KEY_DOWN) {
//         return;
//     }

//     std.debug.print("{x} ({x})", .{ ev.key_code, ev.modifiers });
//     const key = transform_key(ev.key_code, ev.modifiers);
//     if (key == 0) {
//         std.debug.print("\n", .{});
//         return;
//     }

//     std.debug.print("writing {x}\n", .{key});
//     const buf = [1]u8{key};
//     _ = std.os.write(pty_fd, &buf) catch |err| std.debug.panic("{}\n", .{err});
// }

fn update(events: std.ArrayList(c.SDL_Event)) anyerror!void {
    _ = read_pty();

    for (events.items) |e| {
        if (e.type != c.SDL_KEYDOWN) {
            continue;
        }

        std.debug.print("{x} ({x})", .{ e.key.keysym.sym, e.key.keysym.mod });
        const key = transform_key(e.key.keysym.sym, e.key.keysym.mod);
        if (key == 0) {
            std.debug.print("\n", .{});
            return;
        }

        std.debug.print("writing {x}\n", .{key});
        const buf = [1]u8{key};
        _ = std.os.write(pty_fd, &buf) catch |err| std.debug.panic("{}\n", .{err});
    }
}

fn render() void {
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    text.render(&tty_buf, 10.0, 400.0 - 20.0, 0.8, zlm.Vec3.new(1.0, 1.0, 1.0));

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

    tty_buf[0] = 0;

    tty_buf[0] = 0;
    pty_fd = c.tty_setup("/bin/dash");

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
        const start = c.SDL_GetPerformanceCounter();

        var sdl_event: c.SDL_Event = undefined;
        var events = std.ArrayList(c.SDL_Event).init(std.testing.allocator);
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                else => {},
            }

            try events.append(sdl_event);
        }

        try update(events);
        const now1 = c.SDL_GetPerformanceCounter();
        const duration1 = ((now1 - start) * 1000) / c.SDL_GetPerformanceFrequency();
        std.debug.print("update took {} ms\n", .{duration1});
        render();
        c.SDL_GL_SwapWindow(window);
        const now2 = c.SDL_GetPerformanceCounter();
        const duration2 = ((now2 - start) * 1000) / c.SDL_GetPerformanceFrequency();
        std.debug.print("render took {} ms\n", .{duration2});
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
