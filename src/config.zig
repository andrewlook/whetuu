//! Optional module configuration read from `~/.config/whetuu/whetuu.toml`.
//! A missing file keeps every module enabled, so installing whetuu still needs
//! no setup. The accepted TOML schema is deliberately small: one `[modules]`
//! table whose known keys have boolean values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Upper bound for the configuration file. Six boolean settings should stay
/// tiny, and a bound keeps an accidental large file off the render path.
const read_limit: Io.Limit = .limited(64 * 1024);

/// Enable switches for each render module. These defaults preserve the status
/// line produced when no configuration file exists.
pub const Modules = struct {
    user_host: bool = true,
    directory: bool = true,
    git: bool = true,
    language: bool = true,
    cmd_duration: bool = true,
    character: bool = true,
};

const Module = enum(u3) {
    user_host,
    directory,
    git,
    language,
    cmd_duration,
    character,
};

/// Location of a parse error. Zero means the file could not be read before a
/// line was parsed.
pub const Diagnostic = struct {
    line: usize = 0,
};

pub const ParseError = error{
    ExpectedModulesTable,
    UnsupportedTable,
    DuplicateTable,
    ExpectedAssignment,
    ExpectedBoolean,
    UnknownModule,
    DuplicateModule,
};

/// Loads the module switches. A missing file or an unset HOME uses defaults;
/// malformed and unreadable files are errors so a typo cannot silently change
/// what the status line runs.
pub fn load(io: Io, arena: Allocator, home: []const u8, diagnostic: *Diagnostic) !Modules {
    const config_path = (try path(arena, home)) orelse return .{};
    const bytes = Dir.cwd().readFileAlloc(io, config_path, arena, read_limit) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(bytes, diagnostic);
}

/// Absolute path of the optional configuration file. Null when HOME is unset.
pub fn path(arena: Allocator, home: []const u8) Allocator.Error!?[]const u8 {
    if (home.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}/.config/whetuu/whetuu.toml", .{home});
}

/// Human-readable detail for a parse error.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ExpectedModulesTable => "settings must be under a [modules] table",
        error.UnsupportedTable => "only the [modules] table is supported",
        error.DuplicateTable => "the [modules] table appears more than once",
        error.ExpectedAssignment => "expected a module = true or false assignment",
        error.ExpectedBoolean => "module values must be true or false",
        error.UnknownModule => "unknown module name",
        error.DuplicateModule => "module is configured more than once",
        else => "configuration could not be read",
    };
}

/// Parses the supported TOML schema. Blank lines and comments are allowed,
/// including comments after a table or value.
fn parse(text: []const u8, diagnostic: *Diagnostic) ParseError!Modules {
    var modules: Modules = .{};
    var seen_modules: u8 = 0;
    var in_modules = false;
    var saw_table = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const before_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, before_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (!std.mem.eql(u8, line, "[modules]"))
                return invalid(diagnostic, line_number, error.UnsupportedTable);
            if (saw_table) return invalid(diagnostic, line_number, error.DuplicateTable);
            saw_table = true;
            in_modules = true;
            continue;
        }

        if (!in_modules) return invalid(diagnostic, line_number, error.ExpectedModulesTable);

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse
            return invalid(diagnostic, line_number, error.ExpectedAssignment);
        const name = std.mem.trim(u8, line[0..equals], " \t");
        const raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (name.len == 0 or raw_value.len == 0)
            return invalid(diagnostic, line_number, error.ExpectedAssignment);

        const enabled = if (std.mem.eql(u8, raw_value, "true"))
            true
        else if (std.mem.eql(u8, raw_value, "false"))
            false
        else
            return invalid(diagnostic, line_number, error.ExpectedBoolean);

        const module = std.meta.stringToEnum(Module, name) orelse
            return invalid(diagnostic, line_number, error.UnknownModule);
        const bit = @as(u8, 1) << @intFromEnum(module);
        if (seen_modules & bit != 0)
            return invalid(diagnostic, line_number, error.DuplicateModule);
        seen_modules |= bit;

        switch (module) {
            .user_host => modules.user_host = enabled,
            .directory => modules.directory = enabled,
            .git => modules.git = enabled,
            .language => modules.language = enabled,
            .cmd_duration => modules.cmd_duration = enabled,
            .character => modules.character = enabled,
        }
    }

    return modules;
}

fn invalid(diagnostic: *Diagnostic, line: usize, err: ParseError) ParseError {
    diagnostic.* = .{ .line = line };
    return err;
}

test "path is under the user's config directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "/home/davy/.config/whetuu/whetuu.toml",
        (try path(arena.allocator(), "/home/davy")).?,
    );
    try std.testing.expect((try path(arena.allocator(), "")) == null);
}

test "missing settings default every module to enabled" {
    var diagnostic: Diagnostic = .{};
    const got = try parse("# no overrides\n", &diagnostic);
    try std.testing.expect(got.user_host);
    try std.testing.expect(got.directory);
    try std.testing.expect(got.git);
    try std.testing.expect(got.language);
    try std.testing.expect(got.cmd_duration);
    try std.testing.expect(got.character);
}

test "an unset home loads defaults without looking for a file" {
    var diagnostic: Diagnostic = .{};
    const got = try load(std.testing.io, std.testing.allocator, "", &diagnostic);
    try std.testing.expect(got.user_host);
    try std.testing.expect(got.directory);
    try std.testing.expect(got.git);
    try std.testing.expect(got.language);
    try std.testing.expect(got.cmd_duration);
    try std.testing.expect(got.character);
}

test "modules can be disabled independently" {
    var diagnostic: Diagnostic = .{};
    const got = try parse(
        \\[modules]
        \\user_host = false
        \\directory = true # inline comments are TOML
        \\git = false
        \\language = false
        \\cmd_duration = false
        \\character = true
    , &diagnostic);

    try std.testing.expect(!got.user_host);
    try std.testing.expect(got.directory);
    try std.testing.expect(!got.git);
    try std.testing.expect(!got.language);
    try std.testing.expect(!got.cmd_duration);
    try std.testing.expect(got.character);
}

test "invalid values and module names report their line" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.ExpectedBoolean, parse("[modules]\ngit = yes\n", &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(error.UnknownModule, parse("[modules]\ngti = false\n", &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
}

test "duplicate module settings are rejected" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.DuplicateModule,
        parse("[modules]\ngit = false\ngit = true\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
}
