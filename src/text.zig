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
    size: std.meta.Vector(2, i32), // Size of glyph
    bearing: std.meta.Vector(2, i32), // Offset from baseline to left/top of glyph
    advance: i64, // Horizontal offset to advance to next glyph
    bmp_x: std.meta.Vector(2, u32), // Begin and end of the bmp in the texture atlas, x-axis
    bmp_y: std.meta.Vector(2, u32), // "", y-axis
};

pub var allocator: std.mem.Allocator = undefined;
var characters: std.AutoHashMap(u8, Character) = undefined;

var VAO: u32 = undefined;
var VBO: u32 = undefined;

var text_shader_id: u32 = undefined;
var texture_atlas_id: u32 = undefined;

var tex_width: u32 = 1;
var tex_height: u32 = 1;

pub var num_cols: usize = 0;
pub var num_rows: usize = 0;

var scale: f32 = 1.0;

fn loadFile(path: []const u8) anyerror![]u8 {
    const cwd = std.fs.cwd();
    const file: std.fs.File = try cwd.openFile(path, .{ .mode = std.fs.File.OpenMode.read_only });
    try return file.readToEndAlloc(std.testing.allocator, 2048);
}

/// Check whether the vertex/fragment shader or shader program properly compiled
/// Panic if an error occurred.
fn checkShaderCompile(shader_obj: u32, compile_type: ShaderCompileType) void {
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

fn compileShader(v_shader_src: []u8, f_shader_src: []u8) u32 {
    const vertex_id = c.glCreateShader(c.GL_VERTEX_SHADER);
    defer c.glDeleteShader(vertex_id);
    var lengths = [_]i32{@intCast(i32, v_shader_src.len)};
    c.glShaderSource(vertex_id, 1, @ptrCast([*c]const [*c]const u8, &v_shader_src), @ptrCast([*c]const c_int, &lengths));
    c.glCompileShader(vertex_id);
    checkShaderCompile(vertex_id, ShaderCompileType.Vertex);

    const fragment_id = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    defer c.glDeleteShader(fragment_id);
    lengths = [_]i32{@intCast(i32, f_shader_src.len)};
    c.glShaderSource(fragment_id, 1, @ptrCast([*c]const [*c]const u8, &f_shader_src), @ptrCast([*c]const c_int, &lengths));
    c.glCompileShader(fragment_id);
    checkShaderCompile(fragment_id, ShaderCompileType.Fragment);

    const shader_id = c.glCreateProgram();
    c.glAttachShader(shader_id, vertex_id);
    c.glAttachShader(shader_id, fragment_id);
    c.glLinkProgram(shader_id);
    checkShaderCompile(shader_id, ShaderCompileType.Program);

    return shader_id;
}

pub fn loadShadersFromFile(v_shader_path: []const u8, f_shader_path: []const u8) u32 {
    var v_shader = loadFile(v_shader_path) catch |err| std.debug.panic("{}\n", .{err});
    var f_shader = loadFile(f_shader_path) catch |err| std.debug.panic("{}\n", .{err});

    return compileShader(v_shader, f_shader);
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

    text_shader_id = loadShadersFromFile("shaders/text.vs", "shaders/text.fs");
    c.glUseProgram(text_shader_id);
    c.glUniformMatrix4fv(c.glGetUniformLocation(text_shader_id, "projection"), 1, c.GL_FALSE, @ptrCast([*c]const f32, &projection));

    var err = c.glGetError();
    if (err != 0) {
        std.debug.print("gl error: {}\n", .{err});
    }

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

    _ = c.FT_Set_Char_Size(face, 0, 12 << 6, 96, 96);

    // var num_glyphs: u32 = 128;
    var max_dim = (1 + (face.*.size.*.metrics.height >> 6)) * 12; // 12 = ceil(sqrt(128))
    std.debug.print("max_dim: {}\n", .{max_dim});
    std.debug.print("face.*.size.*.metrics.height: {}\n", .{face.*.size.*.metrics.height});

    while (tex_width < max_dim) {
        tex_width <<= 1;
    }
    tex_height = tex_width;
    std.debug.print("tex_height: {}\n", .{tex_height});

    // render glyphs to atlas
    var pixels = try allocator.alloc(u8, tex_width * tex_height);
    var zero_i: usize = 0;
    while (zero_i < tex_width * tex_height) {
        pixels[zero_i] = 0;
        zero_i += 1;
    }

    defer allocator.free(pixels);
    var pen_x: u32 = 0;
    var pen_y: u32 = 0;

    var ch: u8 = 0;
    while (ch < 128) {
        if (c.FT_Load_Char(face, ch, c.FT_LOAD_RENDER | c.FT_LOAD_FORCE_AUTOHINT | c.FT_LOAD_TARGET_LIGHT) != 0) {
            std.debug.panic("error loading char num {}\n", .{c});
        }
        var bmp = &face.*.glyph.*.bitmap;

        if (pen_x + bmp.*.width >= tex_width) {
            pen_x = 0;
            pen_y += ((@intCast(u32, face.*.size.*.metrics.height) >> 6) + 1);
        }

        var row: usize = 0;
        while (row < bmp.*.rows) {
            var col: usize = 0;
            while (col < bmp.*.width) {
                const x = pen_x + col;
                const y = pen_y + row;
                pixels[y * tex_width + x] = bmp.*.buffer[(@intCast(u32, row) * @intCast(u32, bmp.*.pitch)) + col];

                col += 1;
            }

            row += 1;
        }

        // this is stuff you'd need when rendering individual glyphs out of the atlas

        // info[i].x0 = pen_x;
        // info[i].y0 = pen_y;
        // info[i].x1 = pen_x + bmp.*.width;
        // info[i].y1 = pen_y + bmp.*.rows;

        try characters.put(ch, Character{
            .size = [_]i32{ @intCast(c_int, face.*.glyph.*.bitmap.width), @intCast(c_int, face.*.glyph.*.bitmap.rows) },
            .bearing = [_]i32{ face.*.glyph.*.bitmap_left, face.*.glyph.*.bitmap_top },
            .advance = face.*.glyph.*.advance.x,
            .bmp_x = [_]u32{ pen_x, pen_x + bmp.*.width },
            .bmp_y = [_]u32{ pen_y, pen_y + bmp.*.rows },
        });

        pen_x += bmp.*.width + 1;
        ch += 1;
    }

    var a_ch: Character = characters.get('a').?;
    const num_pixels_per_char = @intToFloat(f32, a_ch.advance >> 6) * scale;
    num_cols = @floatToInt(u32, 600 / num_pixels_per_char);
    num_rows = 18; // 400 / 20

    // std.debug.print("allocating {} bytes for png_data\n", .{tex_width * tex_height * 4});
    // var png_data = try allocator.alloc(u8, tex_width * tex_height * 4);
    // defer allocator.free(png_data);
    // var i: usize = 0;
    // while (i < (tex_width * tex_height)) {
    //     png_data[i * 4 + 0] |= pixels[i];
    //     png_data[i * 4 + 1] |= pixels[i];
    //     png_data[i * 4 + 2] |= pixels[i];
    //     png_data[i * 4 + 3] = 0xff;
    //     i += 1;
    // }
    // _ = c.stbi_write_png(
    //     "font_output.png",
    //     @intCast(c_int, tex_width),
    //     @intCast(c_int, tex_height),
    //     4,
    //     @ptrCast(*const anyopaque, png_data),
    //     @intCast(c_int, tex_width * 4),
    // );

    // _ = c.FT_Set_Pixel_Sizes(face, 0, 16);

    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glGenTextures(1, &texture_atlas_id);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_atlas_id);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RED,
        @intCast(c_int, tex_width),
        @intCast(c_int, tex_height),
        0,
        c.GL_RED,
        c.GL_UNSIGNED_BYTE,
        @ptrCast(*const anyopaque, pixels),
    );

    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    // -----------------------------------
    c.glGenVertexArrays(1, &VAO);
    c.glGenBuffers(1, &VBO);
    c.glBindVertexArray(VAO);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, VBO);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4 * 2048, null, c.GL_STATIC_DRAW); // c.GL_DYNAMIC_DRAW);
    c.glEnableVertexAttribArray(0);
    c.glVertexAttribPointer(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @intToPtr(*allowzero const anyopaque, 0));
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindVertexArray(0);
    err = c.glGetError();
    if (err != 0) {
        std.debug.print("gl error: {}\n", .{err});
    }
}

pub fn render(text: []const u8, begin_x: f32, begin_y: f32, color: zlm.Vec3) void {
    _ = text;
    _ = begin_x;
    _ = begin_y;
    _ = scale;

    c.glUseProgram(text_shader_id);
    c.glUniform3f(c.glGetUniformLocation(text_shader_id, "textColor"), color.x, color.y, color.z);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindVertexArray(VAO);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, VBO);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_atlas_id);

    // float vertices[] = {
    //     // first triangle
    //      0.5f,  0.5f, 0.0f,  // top right
    //      0.5f, -0.5f, 0.0f,  // bottom right
    //     -0.5f,  0.5f, 0.0f,  // top left
    //     // second triangle
    //      0.5f, -0.5f, 0.0f,  // bottom right
    //     -0.5f, -0.5f, 0.0f,  // bottom left
    //     -0.5f,  0.5f, 0.0f   // top left
    // };

    // const xpos = 10.0;
    // const ypos = -10.0;
    // const w = 600.0;
    // const h = 400.0;

    // const vertices = [6][4]f32{
    //     [4]f32{ 10.0, 10.0, 0.0, 0.0 }, // bottom left
    //     [4]f32{ -0.5, 0.5, 0.0, 1.0 }, // top left
    //     [4]f32{ 0.5, 0.5, 1.0, 1.0 }, // top right
    //     [4]f32{ -0.5, -0.5, 0.0, 0.0 }, // bottom left
    //     [4]f32{ 0.5, 0.5, 1.0, 1.0 }, // top right
    //     [4]f32{ 0.5, -0.5, 1.0, 0.0 }, // bottom right
    // };
    // const vertices = [6][4]f32{
    //     .{ xpos, ypos + h, 0.0, 0.0 },
    //     .{ xpos, ypos, 0.0, 1.0 },
    //     .{ xpos + w, ypos, 1.0, 1.0 },
    //     .{ xpos, ypos + h, 0.0, 0.0 },
    //     .{ xpos + w, ypos, 1.0, 1.0 },
    //     .{ xpos + w, ypos + h, 1.0, 0.0 },
    // };
    // float vertices[] = {
    //     // positions          // colors           // texture coords
    //      0.5f,  0.5f, 0.0f,   1.0f, 0.0f, 0.0f,   1.0f, 1.0f,   // top right
    //      0.5f, -0.5f, 0.0f,   0.0f, 1.0f, 0.0f,   1.0f, 0.0f,   // bottom right
    //     -0.5f, -0.5f, 0.0f,   0.0f, 0.0f, 1.0f,   0.0f, 0.0f,   // bottom left
    //     -0.5f,  0.5f, 0.0f,   1.0f, 1.0f, 0.0f,   0.0f, 1.0f    // top left
    // };

    // var ch: Character = characters.get('a').?;
    // const begin_tex_x: f32 = @intToFloat(f32, ch.bmp_x[0]) / @intToFloat(f32, tex_width);
    // const begin_tex_y: f32 = @intToFloat(f32, ch.bmp_y[0]) / @intToFloat(f32, tex_height);
    // const end_tex_x: f32 = @intToFloat(f32, ch.bmp_x[1]) / @intToFloat(f32, tex_width);
    // const end_tex_y: f32 = @intToFloat(f32, ch.bmp_y[1]) / @intToFloat(f32, tex_height);
    // const vertices = [6][4]f32{
    //     .{ xpos, ypos + h, begin_tex_x, begin_tex_y }, // bottom left
    //     .{ xpos, ypos, begin_tex_x, end_tex_y }, // top left
    //     .{ xpos + w, ypos, end_tex_x, end_tex_y }, // rop right
    //     .{ xpos, ypos + h, begin_tex_x, begin_tex_y }, // bottom left
    //     .{ xpos + w, ypos, end_tex_x, end_tex_y }, // top right
    //     .{ xpos + w, ypos + h, end_tex_x, begin_tex_y }, // bottom right
    // };

    // const elem_size: comptime_int = @sizeOf(f32) * 6 * 4;
    // c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, elem_size, @ptrCast(*const anyopaque, &vertices));

    var x = begin_x;
    var y = begin_y;
    var count: i32 = 0;
    var chars_current_row: usize = 0;
    for (text) |i| {
        if (i == 0) {
            continue;
        }
        if (i == '\n' or i == '\r') {
            chars_current_row = 0;
            x = begin_x;
            y -= 10.0;
            continue;
        }
        if (count >= 2048) {
            std.debug.panic("opengl buffer not big enough\n", .{});
        }

        var ch: Character = characters.get(i).?;

        const xpos = x + @intToFloat(f32, ch.bearing[0]) + scale;
        const ypos = y - @intToFloat(f32, (ch.size[1] - ch.bearing[1])) * scale;

        const w = @intToFloat(f32, ch.size[0]) * scale;
        const h = @intToFloat(f32, ch.size[1]) * scale;

        const begin_tex_x: f32 = @intToFloat(f32, ch.bmp_x[0]) / @intToFloat(f32, tex_width);
        const begin_tex_y: f32 = @intToFloat(f32, ch.bmp_y[0]) / @intToFloat(f32, tex_height);
        const end_tex_x: f32 = @intToFloat(f32, ch.bmp_x[1]) / @intToFloat(f32, tex_width);
        const end_tex_y: f32 = @intToFloat(f32, ch.bmp_y[1]) / @intToFloat(f32, tex_height);
        const vertices = [6][4]f32{
            .{ xpos, ypos + h, begin_tex_x, begin_tex_y }, // bottom left
            .{ xpos, ypos, begin_tex_x, end_tex_y }, // top left
            .{ xpos + w, ypos, end_tex_x, end_tex_y }, // rop right
            .{ xpos, ypos + h, begin_tex_x, begin_tex_y }, // bottom left
            .{ xpos + w, ypos, end_tex_x, end_tex_y }, // top right
            .{ xpos + w, ypos + h, end_tex_x, begin_tex_y }, // bottom right
        };

        // render glyph texture over quad

        // update content of VBO memory

        const buffer_element_size: comptime_int = @sizeOf(f32) * 6 * 4;
        c.glBufferSubData(
            c.GL_ARRAY_BUFFER,
            count * buffer_element_size,
            buffer_element_size,
            @ptrCast(*const anyopaque, &vertices),
        ); // be sure to use glBufferSubData and not glBufferData

        // now advance cursors for next glyph (note that advance is number of 1/64 pixels)
        x += @intToFloat(f32, ch.advance >> 6) * scale; // bitshift by 6 to get value in pixels (2^6 = 64 (divide amount of 1/64th pixels by 64 to get amount of pixels))
        count += 1;
        chars_current_row += 1;

        if (chars_current_row >= num_cols) {
            chars_current_row = 0;
            x = begin_x;
            y -= 20.0;
        }
        // std.debug.print("y: {} ", .{y});
        // std.debug.print("drew a char starting at {}", .{x});
    }
    // std.debug.print("\n", .{});
    // std.debug.print("drew {} characters\n", .{count});
    // render quad
    c.glDrawArrays(c.GL_TRIANGLES, 0, count * 6);

    var err = c.glGetError();
    if (err != 0) {
        std.debug.print("gl error: {}\n", .{err});
    }

    // std.debug.print("drew {} characters\n", .{count});

    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindVertexArray(0);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}
