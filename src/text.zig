const std = @import("std");
const zlm = @import("zlm");

const c = @cImport({
    @cInclude("glad/glad.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const ShaderCompileType = enum {
    Vertex,
    Fragment,
    Program,
};

const Character = struct {
    texture_id: u32, // ID handle of the glyph texture
    size: std.meta.Vector(2, i32), // Size of glyph
    bearing: std.meta.Vector(2, i32), // Offset from baseline to left/top of glyph
    advance: i64, // Horizontal offset to advance to next glyph
};

pub var allocator: std.mem.Allocator = undefined;
var characters: std.AutoHashMap(u8, Character) = undefined;
var VAO: u32 = undefined;
var VBO: u32 = undefined;
var text_shader_id: u32 = undefined;

fn load_file(path: []const u8) anyerror![]u8 {
    const cwd = std.fs.cwd();
    const file: std.fs.File = try cwd.openFile(path, .{ .mode = std.fs.File.OpenMode.read_only });
    try return file.readToEndAlloc(std.testing.allocator, 2048);
}

fn check_shader_compile(shader_obj: u32, compile_type: ShaderCompileType) void {
    var success: i32 = undefined;
    var info_log: [1024]u8 = undefined;

    if (compile_type == ShaderCompileType.Program) {
        c.glGetProgramiv(shader_obj, c.GL_LINK_STATUS, @ptrCast([*c]c_int, &success));
        if (success != 1) {
            c.glGetShaderInfoLog(shader_obj, 1024, null, @ptrCast([*c]u8, &info_log));
            std.debug.print("success: {}\n{s}\n", .{ success, info_log });
            std.debug.panic("Shader link error: {s}\n", .{compile_type});
        }
    } else {
        c.glGetShaderiv(shader_obj, c.GL_COMPILE_STATUS, @ptrCast([*c]c_int, &success));
        if (success != 1) {
            c.glGetShaderInfoLog(shader_obj, 1024, null, @ptrCast([*c]u8, &info_log));
            std.debug.print("success: {}\n{s}\n", .{ success, info_log });
            std.debug.panic("Shader compile error: {s}\n", .{compile_type});
        }
    }
}

fn compile_shader(v_shader_src: []u8, f_shader_src: []u8) u32 {
    const vertex_id = c.glCreateShader(c.GL_VERTEX_SHADER);
    defer c.glDeleteShader(vertex_id);
    var lengths = [_]i32{@intCast(i32, v_shader_src.len)};
    c.glShaderSource(vertex_id, 1, @ptrCast([*c]const [*c]const u8, &v_shader_src), @ptrCast([*c]const c_int, &lengths));
    c.glCompileShader(vertex_id);
    check_shader_compile(vertex_id, ShaderCompileType.Vertex);

    const fragment_id = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    defer c.glDeleteShader(fragment_id);
    lengths = [_]i32{@intCast(i32, f_shader_src.len)};
    c.glShaderSource(fragment_id, 1, @ptrCast([*c]const [*c]const u8, &f_shader_src), @ptrCast([*c]const c_int, &lengths));
    c.glCompileShader(fragment_id);
    check_shader_compile(fragment_id, ShaderCompileType.Fragment);

    const shader_id = c.glCreateProgram();
    c.glAttachShader(shader_id, vertex_id);
    c.glAttachShader(shader_id, fragment_id);
    c.glLinkProgram(shader_id);
    check_shader_compile(shader_id, ShaderCompileType.Program);

    return shader_id;
}

pub fn load_shaders_from_file(v_shader_path: []const u8, f_shader_path: []const u8) u32 {
    var v_shader = load_file(v_shader_path) catch |err| std.debug.panic("{}\n", .{err});
    var f_shader = load_file(f_shader_path) catch |err| std.debug.panic("{}\n", .{err});

    return compile_shader(v_shader, f_shader);
}

pub fn init() anyerror!void {
    characters = std.AutoHashMap(u8, Character).init(
        allocator,
    );

    c.glEnable(c.GL_CULL_FACE);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    var projection = zlm.Mat4.createOrthogonal(0.0, 640.0, 0.0, 400.0, -1.0, 1.0);
    // std.debug.print("{}\n", .{projection.fields[0][0]});

    text_shader_id = load_shaders_from_file("shaders/text.vs", "shaders/text.fs");
    c.glUseProgram(text_shader_id);
    c.glUniformMatrix4fv(c.glGetUniformLocation(text_shader_id, "projection"), 1, c.GL_FALSE, @ptrCast([*c]const f32, &projection));

    var err = c.glGetError();
    std.debug.print("gl error: {}\n", .{err});

    var ft: c.FT_Library = undefined;
    // All functions return a value different than 0 whenever an error occurred
    if (c.FT_Init_FreeType(&ft) != 0) {
        std.debug.print("error initializing freetype\n", .{});
    }
    defer _ = c.FT_Done_FreeType(ft);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft, "resources/inconsolata.ttf", 0, &face) != 0) {
        std.debug.print("error loading font", .{});
    }
    defer _ = c.FT_Done_Face(face);

    _ = c.FT_Set_Pixel_Sizes(face, 0, 24);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);

    var ch: u8 = 0;
    while (ch < 128) {
        var texture: u32 = undefined;

        if (c.FT_Load_Char(face, ch, c.FT_LOAD_RENDER) != 0) {
            std.debug.panic("error loading char num {}\n", .{c});
        }

        c.glGenTextures(1, &texture);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RED,
            @intCast(c_int, face.*.glyph.*.bitmap.width),
            @intCast(c_int, face.*.glyph.*.bitmap.rows),
            0,
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            face.*.glyph.*.bitmap.buffer,
        );

        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

        try characters.put(ch, Character{
            .texture_id = texture,
            .size = [_]i32{ @intCast(c_int, face.*.glyph.*.bitmap.width), @intCast(c_int, face.*.glyph.*.bitmap.rows) },
            .bearing = [_]i32{ face.*.glyph.*.bitmap_left, face.*.glyph.*.bitmap_top },
            .advance = face.*.glyph.*.advance.x,
        });

        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        ch += 1;
    }

    // -----------------------------------
    c.glGenVertexArrays(1, &VAO);
    c.glGenBuffers(1, &VBO);
    c.glBindVertexArray(VAO);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, VBO);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, c.GL_DYNAMIC_DRAW);
    c.glEnableVertexAttribArray(0);
    c.glVertexAttribPointer(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @intToPtr(*allowzero const anyopaque, 0));
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindVertexArray(0);
}

pub fn render(text: []const u8, begin_x: f32, y: f32, scale: f32, color: zlm.Vec3) void {
    c.glUseProgram(text_shader_id);
    c.glUniform3f(c.glGetUniformLocation(text_shader_id, "textColor"), color.x, color.y, color.z);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindVertexArray(VAO);

    var x = begin_x;
    for (text) |i| {
        var ch: Character = characters.get(i).?;

        const xpos = x + @intToFloat(f32, ch.bearing[0]) + scale;
        const ypos = y - @intToFloat(f32, (ch.size[1] - ch.bearing[1])) * scale;

        const w = @intToFloat(f32, ch.size[0]) * scale;
        const h = @intToFloat(f32, ch.size[1]) * scale;

        const vertices = [6][4]f32{
            [4]f32{ xpos, ypos + h, 0.0, 0.0 },
            [4]f32{ xpos, ypos, 0.0, 1.0 },
            [4]f32{ xpos + w, ypos, 1.0, 1.0 },
            [4]f32{ xpos, ypos + h, 0.0, 0.0 },
            [4]f32{ xpos + w, ypos, 1.0, 1.0 },
            [4]f32{ xpos + w, ypos + h, 1.0, 0.0 },
        };

        // render glyph texture over quad
        c.glBindTexture(c.GL_TEXTURE_2D, ch.texture_id);
        // update content of VBO memory
        c.glBindBuffer(c.GL_ARRAY_BUFFER, VBO);
        c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @sizeOf(f32) * 6 * 4, @ptrCast(*const anyopaque, &vertices)); // be sure to use glBufferSubData and not glBufferData

        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        // render quad
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        // now advance cursors for next glyph (note that advance is number of 1/64 pixels)
        x += @intToFloat(f32, ch.advance >> 6) * scale; // bitshift by 6 to get value in pixels (2^6 = 64 (divide amount of 1/64th pixels by 64 to get amount of pixels))
    }

    c.glBindVertexArray(0);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}
