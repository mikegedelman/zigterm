const std = @import("std");
const zlm = @import("zlm");

const text = @import("text.zig");

const c = @cImport({
    @cInclude("term_setup.h");

    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");
});

var tty_buf: [2048]u8 = undefined;
pub var chars_buf: [25 * 80]u8 = undefined;
var tty_pos: usize = 0;
var pty_fd: i32 = 0;

var window: *c.GLFWwindow = undefined;

fn printBuffer(buf: []u8) void {
    for (buf) |ch| {
        if (ch == 0) {
            break;
        }
        std.debug.print("{x} ", .{ch});
    }
    std.debug.print("\n", .{});
}

fn buildCharBuf() void {
    // zero it
    var char_buf_i: usize = 0;
    while (char_buf_i < 25 * 80) {
        chars_buf[char_buf_i] = 0;
        char_buf_i += 1;
    }

    var rows_seen: usize = 0;
    var chars_this_col: usize = 0;
    var tmp_tty_pos: usize = tty_pos;
    while (tmp_tty_pos > 0 and rows_seen < text.num_rows and (tty_pos - tmp_tty_pos < 25 * 80)) {
        chars_this_col += 1;
        if (tty_buf[tmp_tty_pos] == 0xa or chars_this_col > text.num_cols) {
            rows_seen += 1;
            chars_this_col = 0;
        }
        tmp_tty_pos -= 1;
    }
    std.debug.print("rows_seen: {} ({})\n", .{ rows_seen, text.num_rows });
    std.debug.print("tmp_tty_pos: {}\n", .{tmp_tty_pos});

    while (tmp_tty_pos <= tty_pos) {
        chars_buf[tmp_tty_pos] = tty_buf[tmp_tty_pos];
        tmp_tty_pos += 1;
    }
}

fn readPty() usize {
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
        printBuffer(&buf);

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
        // buildCharBuf();
        // printBuffer(&chars_buf);
    }
    return bytes_read;
}

fn readPtyLoop() void {
    while (true) {
        _ = readPty();
        // std.debug.print("bytes read: {}", .{bytes});
    }
}

fn transformKey(code: i32, modifiers: i32) u8 {
    if (code == c.GLFW_KEY_LEFT_SHIFT or code == c.GLFW_KEY_RIGHT_SHIFT or code == c.GLFW_KEY_LEFT_CONTROL or code == c.GLFW_KEY_RIGHT_CONTROL) {
        return 0;
    }

    if (code == c.GLFW_KEY_ENTER) {
        return 0xa;
    }
    if (code == c.GLFW_KEY_BACKSPACE) {
        return 0x08;
    }

    const shift_pressed: bool = (modifiers & 1) == 1;
    var raw_code = @truncate(u8, @bitCast(u32, code));
    if ((raw_code >= 65) and (raw_code <= 90) and !shift_pressed) {
        raw_code += 32;
    }

    return raw_code;
}

fn keyCallback(_: ?*c.GLFWwindow, pressed_key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = scancode;

    if (action != c.GLFW_PRESS) {
        return;
    }

    std.debug.print("{x} ({x})", .{ pressed_key, mods });
    const key = transformKey(pressed_key, mods);
    if (key == 0) {
        std.debug.print("\n", .{});
        return;
    }

    std.debug.print("writing {x}\n", .{key});
    const buf = [1]u8{key};
    _ = std.os.write(pty_fd, &buf) catch |err| std.debug.panic("{}\n", .{err});
}

fn render() void {
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    text.render(&chars_buf, 10.0, 400.0 - 20.0, zlm.Vec3.new(1.0, 1.0, 1.0));

    var err: u32 = c.glGetError();
    while (err != 0) {
        std.debug.print("gl error: {}\n", .{err});
        err = c.glGetError();
    }
}

fn renderWorker() anyerror!void {
    c.glfwMakeContextCurrent(window);

    if (c.gladLoadGLLoader(@ptrCast(fn ([*c]const u8) callconv(.C) ?*anyopaque, c.glfwGetProcAddress)) != 1) {
        std.debug.panic("Unable to initialize GLAD.\n", .{});
    }

    try text.init();

    while (true) {
        buildCharBuf();
        render();
        c.glfwSwapBuffers(window);
        // std.debug.print("rendered {s}\n", .{chars_buf});
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    text.allocator = arena.allocator();

    tty_buf[0] = 0;
    pty_fd = c.tty_setup("/bin/dash");

    if (c.glfwInit() != 1) {
        std.debug.print("Failed to init GLFW", .{});
        return;
    }
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    // should be like #IFDEF apple
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);

    // glfw window creation
    // --------------------
    var new_window = c.glfwCreateWindow(640, 400, "zigterm", null, null);
    if (new_window == null) {
        std.debug.print("Failed to create GLFW window", .{});
        c.glfwTerminate();
        return;
    }
    window = new_window.?;

    _ = c.glfwSetKeyCallback(window, keyCallback);

    const read_thread = try std.Thread.spawn(.{}, readPtyLoop, .{});
    read_thread.detach();

    const render_thread = try std.Thread.spawn(.{}, renderWorker, .{});
    render_thread.detach();

    while (c.glfwWindowShouldClose(window) == 0) {
        // render();
        // c.glfwSwapBuffers(window);
        c.glfwWaitEvents();
    }

    c.glfwTerminate();
}
