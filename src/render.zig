//! Async render orchestrator. Spawns the enabled filesystem modules
//! concurrently via `Io.async`, then awaits them in display order so the
//! output is deterministic even though the work overlaps. Pure enabled
//! modules run inline. The character is rendered after the segment line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const Env = @import("Env.zig");
const Modules = @import("config.zig").Modules;
const Span = @import("style.zig").Span;
const character = @import("module_character.zig");
const cmd_duration = @import("module_cmd_duration.zig");
const directory = @import("module_directory.zig");
const git = @import("module_git.zig");
const language = @import("module_language.zig");
const shell_indicator = @import("module_shell.zig");
const style = @import("style.zig");
const user_host = @import("module_user_host.zig");

/// Written between adjacent visible segments: a light grey dot, padded so it
/// breathes between the colored segments on either side.
const separator: Span = .{ .style = .{ .color = .bright_black }, .text = " · " };

/// Renders the status line to `w`. Enabled I/O modules are spawned before any
/// is awaited, so their work overlaps; awaiting in display order keeps layout
/// stable. When enabled, the language module runs detection exactly once. Its
/// result also tints the character.
pub fn render(io: Io, arena: Allocator, env: *const Env, modules: Modules, w: *Writer) Writer.Error!void {
    var git_future: ?Io.Future(?[]const Span) = if (modules.git)
        io.async(git.run, .{ io, arena, env })
    else
        null;
    var language_future: ?Io.Future(language.Result) = if (modules.language)
        io.async(language.run, .{ io, arena, env })
    else
        null;

    // Only git and language touch the filesystem, so only they are worth a
    // task. The rest are pure and run inline while those two overlap —
    // spawning them costs far more than the work they do.
    var wrote_any = false;
    if (modules.user_host)
        try writeSegment(w, env.shell, user_host.run(arena, env), &wrote_any);
    if (modules.directory)
        try writeSegment(w, env.shell, directory.run(io, arena, env), &wrote_any);
    if (git_future) |*future|
        try writeSegment(w, env.shell, future.await(io), &wrote_any);

    const lang_result = if (language_future) |*future| future.await(io) else language.Result{};
    if (modules.language)
        try writeSegment(w, env.shell, lang_result.spans, &wrote_any);
    if (modules.cmd_duration)
        try writeSegment(w, env.shell, cmd_duration.run(io, arena, env), &wrote_any);

    // A non-empty byte must follow the newline because command substitution in
    // bash and zsh strips trailing newlines. Keep the trailing space even when
    // the character is disabled so the segment line remains above the cursor.
    if (wrote_any) try w.writeByte('\n');
    if (modules.character) {
        const ch = character.choose(lang_result.lang, env.exit_status);
        try style.write(w, env.shell, ch.style, ch.text);
        if (modules.shell) {
            const shell = shell_indicator.choose(env.shell, ch.style);
            try style.write(w, env.shell, shell.style, shell.text);
        }
    }
    try w.writeByte(' ');
}

/// Writes one segment's spans, preceded by the separator when a previous
/// segment is already on the line. Null or empty spans write nothing.
fn writeSegment(w: *Writer, shell: Env.Shell, spans_opt: ?[]const Span, wrote_any: *bool) Writer.Error!void {
    const spans = spans_opt orelse return;
    if (spans.len == 0) return;

    if (wrote_any.*) try style.write(w, shell, separator.style, separator.text);
    for (spans) |span| try style.write(w, shell, span.style, span.text);
    wrote_any.* = true;
}

test "render emits the directory, a newline, then the trailing character" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // cwd "/" carries no git repo or language markers, so only the directory
    // segment and the character are deterministic across machines.
    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/nonexistent-home",
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, .{}, &w);

    const out = w.buffered();
    const newline = std.mem.indexOfScalar(u8, out, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, out[0..newline], "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[newline..], style.icon.star) != null);
    try std.testing.expect(std.mem.endsWith(u8, out, " "));
}

test "shell indicator does not render without the character" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/nonexistent-home",
        .width = 80,
        .duration_ms = 5_000,
        .exit_status = 0,
    };
    const modules: Modules = .{
        .user_host = false,
        .directory = false,
        .git = false,
        .language = false,
        .cmd_duration = false,
        .character = false,
        .shell = true,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, modules, &w);
    try std.testing.expectEqualStrings(" ", w.buffered());
}

test "character can be disabled without joining the cursor to the segment line" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/nonexistent-home",
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };
    const modules: Modules = .{
        .user_host = false,
        .git = false,
        .language = false,
        .cmd_duration = false,
        .character = false,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, modules, &w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') != null);
    try std.testing.expect(std.mem.indexOf(u8, out, style.icon.star) == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n "));
}

test "shell indicator follows the character when enabled" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/nonexistent-home",
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };
    const modules: Modules = .{
        .user_host = false,
        .directory = false,
        .git = false,
        .language = false,
        .cmd_duration = false,
        .shell = true,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, modules, &w);
    const out = w.buffered();
    const character_at = std.mem.indexOf(u8, out, style.icon.star).?;
    const shell_at = std.mem.indexOf(u8, out, "ᶠ").?;
    try std.testing.expect(character_at < shell_at);
    try std.testing.expect(std.mem.endsWith(u8, out, " "));
}
