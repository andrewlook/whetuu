//! Optional configuration read from `~/.config/whetuu/whetuu.toml`. A missing
//! file preserves the original status line and Up binding. The accepted TOML
//! schema is deliberately small: boolean module switches, a history launcher
//! key (named or an arbitrary Ctrl+letter), and a history scope key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Upper bound for the configuration file. Its handful of settings should stay
/// tiny, and a bound keeps an accidental large file off the render path.
const read_limit: Io.Limit = .limited(64 * 1024);

/// The picker launcher binding. `ctrl_letter` accepts any Ctrl+letter other
/// than the ones the picker's own key handling already claims (see
/// `parseCtrlLetter`). Arbitrary escape sequences are deliberately absent so
/// configuration text never becomes generated shell code — every variant here
/// maps to a fixed, known-safe binding per shell.
pub const HistoryKey = union(enum) {
    up,
    ctrl_up,
    alt_up,
    ctrl_letter: u8,
};

/// The control character that switches the picker's directory and all-history
/// scopes. It is parsed from a named `ctrl-a` through `ctrl-z` value, never a
/// raw byte from the configuration file.
pub const ScopeKey = struct {
    code: u8 = 0x07, // Ctrl+G
};

/// Enable switches for each render module. These defaults preserve the status
/// line produced when no configuration file exists.
pub const Modules = struct {
    user_host: bool = true,
    directory: bool = true,
    git: bool = true,
    language: bool = true,
    cmd_duration: bool = true,
    character: bool = true,
    shell: bool = false,
};

/// Every setting resolved from the file, with defaults for omitted tables and
/// keys.
pub const Settings = struct {
    modules: Modules = .{},
    history_key: HistoryKey = .up,
    history_scope_key: ScopeKey = .{},
};

const Module = enum(u3) {
    user_host,
    directory,
    git,
    language,
    cmd_duration,
    character,
    shell,
};

const Table = enum {
    modules,
    history,
};

/// Location of a parse error. Zero means the file could not be read before a
/// line was parsed.
pub const Diagnostic = struct {
    line: usize = 0,
};

pub const ParseError = error{
    ExpectedTable,
    UnsupportedTable,
    DuplicateTable,
    ExpectedAssignment,
    ExpectedBoolean,
    ExpectedString,
    UnknownModule,
    DuplicateModule,
    UnknownHistorySetting,
    DuplicateHistorySetting,
    UnknownHistoryKey,
    UnknownScopeKey,
    HistoryKeyMatchesScopeKey,
};

/// Loads all settings. A missing file or an unset HOME uses defaults;
/// malformed and unreadable files are errors so a typo cannot silently change
/// the status line or shell integration.
pub fn load(io: Io, arena: Allocator, home: []const u8, diagnostic: *Diagnostic) !Settings {
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
        error.ExpectedTable => "settings must be under a [modules] or [history] table",
        error.UnsupportedTable => "only the [modules] and [history] tables are supported",
        error.DuplicateTable => "a configuration table appears more than once",
        error.ExpectedAssignment => "expected a name = value assignment",
        error.ExpectedBoolean => "module values must be true or false",
        error.ExpectedString => "history keys must be quoted strings",
        error.UnknownModule => "unknown module name",
        error.DuplicateModule => "module is configured more than once",
        error.UnknownHistorySetting => "unknown history setting",
        error.DuplicateHistorySetting => "history setting is configured more than once",
        error.UnknownHistoryKey => "history key must be \"up\", \"ctrl-up\", \"alt-up\", or \"ctrl-\" plus an unused letter",
        error.UnknownScopeKey => "history scope key must be Ctrl plus an unused letter",
        error.HistoryKeyMatchesScopeKey => "history key and scope key cannot use the same letter",
        else => "configuration could not be read",
    };
}

/// Parses the supported TOML schema. Blank lines and comments are allowed,
/// including comments after a table or value.
fn parse(text: []const u8, diagnostic: *Diagnostic) ParseError!Settings {
    var settings: Settings = .{};
    var seen_modules: u8 = 0;
    var seen_history: SeenHistory = .{};
    var saw_modules = false;
    var saw_history = false;
    var table: ?Table = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const before_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, before_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            table = if (std.mem.eql(u8, line, "[modules]"))
                .modules
            else if (std.mem.eql(u8, line, "[history]"))
                .history
            else
                return invalid(diagnostic, line_number, error.UnsupportedTable);

            const already_seen = switch (table.?) {
                .modules => &saw_modules,
                .history => &saw_history,
            };
            if (already_seen.*) return invalid(diagnostic, line_number, error.DuplicateTable);
            already_seen.* = true;
            continue;
        }

        const active_table = table orelse
            return invalid(diagnostic, line_number, error.ExpectedTable);

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse
            return invalid(diagnostic, line_number, error.ExpectedAssignment);
        const name = std.mem.trim(u8, line[0..equals], " \t");
        const raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (name.len == 0 or raw_value.len == 0)
            return invalid(diagnostic, line_number, error.ExpectedAssignment);

        switch (active_table) {
            .modules => try parseModule(
                &settings.modules,
                &seen_modules,
                name,
                raw_value,
                diagnostic,
                line_number,
            ),
            .history => try parseHistory(
                &settings,
                &seen_history,
                name,
                raw_value,
                diagnostic,
                line_number,
            ),
        }
    }

    if (std.meta.activeTag(settings.history_key) == .ctrl_letter and
        settings.history_key.ctrl_letter == settings.history_scope_key.code)
    {
        return invalid(
            diagnostic,
            @max(seen_history.key_line, seen_history.scope_key_line),
            error.HistoryKeyMatchesScopeKey,
        );
    }

    return settings;
}

fn parseModule(
    modules: *Modules,
    seen_modules: *u8,
    name: []const u8,
    raw_value: []const u8,
    diagnostic: *Diagnostic,
    line_number: usize,
) ParseError!void {
    const enabled = if (std.mem.eql(u8, raw_value, "true"))
        true
    else if (std.mem.eql(u8, raw_value, "false"))
        false
    else
        return invalid(diagnostic, line_number, error.ExpectedBoolean);

    const module = std.meta.stringToEnum(Module, name) orelse
        return invalid(diagnostic, line_number, error.UnknownModule);
    const bit = @as(u8, 1) << @intFromEnum(module);
    if (seen_modules.* & bit != 0)
        return invalid(diagnostic, line_number, error.DuplicateModule);
    seen_modules.* |= bit;

    switch (module) {
        .user_host => modules.user_host = enabled,
        .directory => modules.directory = enabled,
        .git => modules.git = enabled,
        .language => modules.language = enabled,
        .cmd_duration => modules.cmd_duration = enabled,
        .character => modules.character = enabled,
        .shell => modules.shell = enabled,
    }
}

const SeenHistory = struct {
    key: bool = false,
    scope_key: bool = false,
    key_line: usize = 0,
    scope_key_line: usize = 0,
};

fn parseHistory(
    settings: *Settings,
    seen: *SeenHistory,
    name: []const u8,
    raw_value: []const u8,
    diagnostic: *Diagnostic,
    line_number: usize,
) ParseError!void {
    const value = stringValue(raw_value) orelse
        return invalid(diagnostic, line_number, error.ExpectedString);

    if (std.mem.eql(u8, name, "key")) {
        if (seen.key) return invalid(diagnostic, line_number, error.DuplicateHistorySetting);
        seen.key = true;
        seen.key_line = line_number;
        settings.history_key = if (std.mem.eql(u8, value, "up"))
            .up
        else if (std.mem.eql(u8, value, "ctrl-up"))
            .ctrl_up
        else if (std.mem.eql(u8, value, "alt-up"))
            .alt_up
        else if (parseCtrlLetter(value)) |code|
            .{ .ctrl_letter = code }
        else
            return invalid(diagnostic, line_number, error.UnknownHistoryKey);
        return;
    }

    if (std.mem.eql(u8, name, "scope_key")) {
        if (seen.scope_key) return invalid(diagnostic, line_number, error.DuplicateHistorySetting);
        seen.scope_key = true;
        seen.scope_key_line = line_number;
        const code = parseCtrlLetter(value) orelse
            return invalid(diagnostic, line_number, error.UnknownScopeKey);
        settings.history_scope_key = .{ .code = code };
        return;
    }

    return invalid(diagnostic, line_number, error.UnknownHistorySetting);
}

/// Parses Ctrl plus a letter, excluding controls already assigned to editing,
/// confirmation, or cancellation inside the picker. Shared by the history
/// launcher key and the scope key, which draw from the same letter pool.
fn parseCtrlLetter(value: []const u8) ?u8 {
    if (value.len != 6 or !std.mem.eql(u8, value[0..5], "ctrl-")) return null;
    const letter = value[5];
    if (letter < 'a' or letter > 'z') return null;
    if (std.mem.indexOfScalar(u8, "cdhijm", letter) != null) return null;
    return letter - 'a' + 1;
}

fn stringValue(raw: []const u8) ?[]const u8 {
    if (raw.len < 2) return null;
    const quote = raw[0];
    if ((quote != '"' and quote != '\'') or raw[raw.len - 1] != quote) return null;
    return raw[1 .. raw.len - 1];
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

test "missing settings preserve the status line and Up binding" {
    var diagnostic: Diagnostic = .{};
    const got = try parse("# no overrides\n", &diagnostic);
    try std.testing.expect(got.modules.user_host);
    try std.testing.expect(got.modules.directory);
    try std.testing.expect(got.modules.git);
    try std.testing.expect(got.modules.language);
    try std.testing.expect(got.modules.cmd_duration);
    try std.testing.expect(got.modules.character);
    try std.testing.expect(!got.modules.shell);
    try std.testing.expectEqual(HistoryKey.up, got.history_key);
    try std.testing.expectEqual(@as(u8, 0x07), got.history_scope_key.code);
}

test "an unset home loads defaults without looking for a file" {
    var diagnostic: Diagnostic = .{};
    const got = try load(std.testing.io, std.testing.allocator, "", &diagnostic);
    try std.testing.expect(got.modules.user_host);
    try std.testing.expect(got.modules.directory);
    try std.testing.expect(got.modules.git);
    try std.testing.expect(got.modules.language);
    try std.testing.expect(got.modules.cmd_duration);
    try std.testing.expect(got.modules.character);
    try std.testing.expect(!got.modules.shell);
    try std.testing.expectEqual(HistoryKey.up, got.history_key);
    try std.testing.expectEqual(@as(u8, 0x07), got.history_scope_key.code);
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
        \\shell = true
    , &diagnostic);

    try std.testing.expect(!got.modules.user_host);
    try std.testing.expect(got.modules.directory);
    try std.testing.expect(!got.modules.git);
    try std.testing.expect(!got.modules.language);
    try std.testing.expect(!got.modules.cmd_duration);
    try std.testing.expect(got.modules.character);
    try std.testing.expect(got.modules.shell);
}

test "history keys accept launcher and scope bindings" {
    var diagnostic: Diagnostic = .{};
    const ctrl_up = try parse(
        \\[history]
        \\key = "ctrl-up"
        \\scope_key = "ctrl-t"
        \\[modules]
        \\git = false
    , &diagnostic);
    try std.testing.expectEqual(HistoryKey.ctrl_up, ctrl_up.history_key);
    try std.testing.expectEqual(@as(u8, 0x14), ctrl_up.history_scope_key.code);
    try std.testing.expect(!ctrl_up.modules.git);

    const up = try parse("[history]\nkey = 'up'\n", &diagnostic);
    try std.testing.expectEqual(HistoryKey.up, up.history_key);

    const alt_up = try parse("[history]\nkey = \"alt-up\"\n", &diagnostic);
    try std.testing.expectEqual(HistoryKey.alt_up, alt_up.history_key);
}

test "history key accepts an arbitrary unreserved ctrl-letter" {
    var diagnostic: Diagnostic = .{};
    const got = try parse("[history]\nkey = \"ctrl-r\"\n", &diagnostic);
    try std.testing.expectEqual(HistoryKey{ .ctrl_letter = 0x12 }, got.history_key);
}

test "history key rejects letters reserved by the picker's own key handling" {
    var diagnostic: Diagnostic = .{};
    for ("cdhijm") |letter| {
        diagnostic = .{};
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "[history]\nkey = \"ctrl-{c}\"\n", .{letter}) catch unreachable;
        try std.testing.expectError(error.UnknownHistoryKey, parse(text, &diagnostic));
        try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    }
}

test "history key and scope key cannot share a letter" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.HistoryKeyMatchesScopeKey,
        parse("[history]\nkey = \"ctrl-r\"\nscope_key = \"ctrl-r\"\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);

    // The default scope key (Ctrl-G) collides just as much as an explicit one.
    diagnostic = .{};
    try std.testing.expectError(
        error.HistoryKeyMatchesScopeKey,
        parse("[history]\nkey = \"ctrl-g\"\n", &diagnostic),
    );
}

test "invalid values and module names report their line" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.ExpectedBoolean, parse("[modules]\ngit = yes\n", &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(
        error.UnknownScopeKey,
        parse("[history]\nscope_key = \"ctrl-c\"\n", &diagnostic),
    );
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

test "invalid history settings report their line" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.ExpectedString,
        parse("[history]\nkey = ctrl-up\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(
        error.UnknownHistoryKey,
        parse("[history]\nkey = \"cmd-up\"\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(
        error.UnknownHistorySetting,
        parse("[history]\nshortcut = \"ctrl-up\"\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
}

test "history key and tables cannot be repeated" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.DuplicateHistorySetting,
        parse("[history]\nkey = \"up\"\nkey = \"alt-up\"\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(
        error.DuplicateHistorySetting,
        parse("[history]\nscope_key = \"ctrl-g\"\nscope_key = \"ctrl-t\"\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);

    diagnostic = .{};
    try std.testing.expectError(
        error.DuplicateTable,
        parse("[history]\nkey = \"up\"\n[history]\n", &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
}
