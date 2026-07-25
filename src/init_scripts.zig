//! `whetuu init <shell>` — prints the shell integration script to stdout. The
//! scripts are embedded at compile time so the binary is self-contained.
//!
//! A shell reads the script by piping or substituting it, so stdout is a pipe
//! in every real use. Stdout being a terminal instead means the command was run
//! by hand, where several hundred lines of shell answer nothing. That case
//! prints the one line to add and where to add it, and says how to see the
//! script anyway.

const std = @import("std");

const Io = std.Io;
const Writer = std.Io.Writer;

const HistoryKey = @import("config.zig").HistoryKey;
const Shell = @import("Env.zig").Shell;
const style = @import("style.zig");

const bash_init = @embedFile("init.bash");
const fish_init = @embedFile("init.fish");
const zsh_init = @embedFile("init.zsh");
const history_binding_marker = "    # @whetuu-history-binding@\n";

/// How a shell loads the integration: the config file it goes in, and the line
/// that goes there.
const Setup = struct {
    file: []const u8,
    line: []const u8,
};

/// The embedded integration script for `shell`, before its configured history
/// binding replaces the marker.
fn embeddedScript(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => bash_init,
        .fish => fish_init,
        .zsh => zsh_init,
    };
}

/// Safe shell source for the two named bindings. No configuration bytes are
/// interpolated here.
fn historyBinding(shell: Shell, key: HistoryKey) []const u8 {
    return switch (shell) {
        .fish => switch (key) {
            .up => "    bind up __whetuu_history\n",
            .ctrl_up => "    bind ctrl-up __whetuu_history\n",
            .alt_up => "    bind alt-up __whetuu_history\n",
        },
        .bash => switch (key) {
            .up => "    # Both cursor sequences are common, depending on keypad mode.\n" ++
                "    bind '\"\\e[A\": \"\\C-x\\C-w\\C-x\\C-z\"'\n" ++
                "    bind '\"\\eOA\": \"\\C-x\\C-w\\C-x\\C-z\"'\n",
            .ctrl_up => "    bind '\"\\e[1;5A\": \"\\C-x\\C-w\\C-x\\C-z\"'\n",
            .alt_up => "    bind '\"\\e[1;3A\": \"\\C-x\\C-w\\C-x\\C-z\"'\n",
        },
        .zsh => switch (key) {
            .up => "    # Both cursor sequences are common, depending on keypad mode.\n" ++
                "    bindkey '^[[A' __whetuu_history\n" ++
                "    bindkey '^[OA' __whetuu_history\n",
            .ctrl_up => "    bindkey '^[[1;5A' __whetuu_history\n",
            .alt_up => "    bindkey '^[[1;3A' __whetuu_history\n",
        },
    };
}

fn writeScript(w: *Writer, shell: Shell, key: HistoryKey) Writer.Error!void {
    const source = embeddedScript(shell);
    const marker_at = std.mem.indexOf(u8, source, history_binding_marker) orelse unreachable;
    try w.writeAll(source[0..marker_at]);
    try w.writeAll(historyBinding(shell, key));
    try w.writeAll(source[marker_at + history_binding_marker.len ..]);
}

/// Where the integration line goes for `shell`, and what it says.
fn setup(shell: Shell) Setup {
    return switch (shell) {
        .bash => .{ .file = "~/.bashrc", .line = "eval \"$(whetuu init bash)\"" },
        .fish => .{ .file = "~/.config/fish/config.fish", .line = "whetuu init fish | source" },
        .zsh => .{ .file = "~/.zshrc", .line = "eval \"$(whetuu init zsh)\"" },
    };
}

/// Resolves a shell name, or `error.UnknownShell`. Pure, so the dispatch is
/// testable without touching stdout.
fn parse(shell_name: []const u8) error{UnknownShell}!Shell {
    return std.meta.stringToEnum(Shell, shell_name) orelse error.UnknownShell;
}

/// Writes the hint shown when stdout is a terminal.
fn writeHint(w: *Writer, shell: Shell, shell_name: []const u8) Writer.Error!void {
    const bold = style.sgr.bold;
    const dim = style.sgr.dim;
    const purple = style.sgr.fg_purple;
    const reset = style.sgr.reset;
    const s = setup(shell);

    try w.print(
        purple ++ style.icon.star ++ reset ++ " " ++
            dim ++ "add this line to" ++ reset ++ " {s}" ++ dim ++ ", then open a new shell" ++ reset ++ "\n" ++
            "\n" ++
            "  " ++ bold ++ "{s}" ++ reset ++ "\n" ++
            "\n" ++
            dim ++ "That runs the integration script at startup. To read it instead:" ++ reset ++ "\n" ++
            "  " ++ dim ++ "whetuu init {s} | less" ++ reset ++ "\n",
        .{ s.file, s.line, shell_name },
    );
}

/// Writes the integration script for `shell_name` to stdout, or the setup hint
/// when stdout is a terminal. Returns `error.UnknownShell` for an unrecognized
/// shell.
pub fn write(io: Io, shell_name: []const u8, history_key: HistoryKey) !void {
    const shell = try parse(shell_name);
    const stdout = Io.File.stdout();

    // A failed query means we cannot prove it is a terminal, so print the
    // script: a piped shell that silently got a hint instead would break.
    const interactive = stdout.isTty(io) catch false;

    var buf: [256]u8 = undefined;
    var fw = stdout.writer(io, &buf);
    if (interactive) {
        try writeHint(&fw.interface, shell, shell_name);
    } else {
        try writeScript(&fw.interface, shell, history_key);
    }

    try fw.interface.flush();
}

test "every supported shell resolves to its embedded script" {
    for ([_][]const u8{ "bash", "fish", "zsh" }) |name| {
        const source = embeddedScript(try parse(name));
        try std.testing.expect(std.mem.indexOf(u8, source, "whetuu") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, history_binding_marker) != null);
    }
}

test "unrecognized shell is rejected" {
    try std.testing.expectError(error.UnknownShell, parse("powershell"));
    try std.testing.expectError(error.UnknownShell, parse(""));
}

test "each shell's hint names its own config file and line" {
    var buf: [512]u8 = undefined;

    for ([_][]const u8{ "bash", "fish", "zsh" }) |name| {
        const shell = try parse(name);
        var w: Writer = .fixed(&buf);
        try writeHint(&w, shell, name);
        const out = w.buffered();

        const s = setup(shell);
        try std.testing.expect(std.mem.indexOf(u8, out, s.file) != null);
        try std.testing.expect(std.mem.indexOf(u8, out, s.line) != null);
        try std.testing.expect(std.mem.indexOf(u8, out, name) != null);
    }
}

test "the hint is short enough to read, unlike the script it replaces" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeHint(&w, .fish, "fish");

    const lines = std.mem.count(u8, w.buffered(), "\n");
    try std.testing.expect(lines <= 8);
    try std.testing.expect(std.mem.count(u8, embeddedScript(.fish), "\n") > lines * 3);
}

test "history binding selects Up, Ctrl-Up or Alt-Up for every shell" {
    const cases = [_]struct {
        shell: Shell,
        up: []const u8,
        ctrl_up: []const u8,
        alt_up: []const u8,
    }{
        .{ .shell = .fish, .up = "bind up", .ctrl_up = "bind ctrl-up", .alt_up = "bind alt-up" },
        .{ .shell = .bash, .up = "\\e[A", .ctrl_up = "\\e[1;5A", .alt_up = "\\e[1;3A" },
        .{ .shell = .zsh, .up = "^[[A", .ctrl_up = "^[[1;5A", .alt_up = "^[[1;3A" },
    };

    var buf: [8192]u8 = undefined;
    for (cases) |case| {
        var up_writer: Writer = .fixed(&buf);
        try writeScript(&up_writer, case.shell, .up);
        const up = up_writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, up, case.up) != null);
        try std.testing.expect(std.mem.indexOf(u8, up, case.ctrl_up) == null);
        try std.testing.expect(std.mem.indexOf(u8, up, case.alt_up) == null);
        try std.testing.expect(std.mem.indexOf(u8, up, history_binding_marker) == null);

        var ctrl_writer: Writer = .fixed(&buf);
        try writeScript(&ctrl_writer, case.shell, .ctrl_up);
        const ctrl_up = ctrl_writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, ctrl_up, case.ctrl_up) != null);
        try std.testing.expect(std.mem.indexOf(u8, ctrl_up, case.up) == null);
        try std.testing.expect(std.mem.indexOf(u8, ctrl_up, case.alt_up) == null);
        try std.testing.expect(std.mem.indexOf(u8, ctrl_up, history_binding_marker) == null);

        var alt_writer: Writer = .fixed(&buf);
        try writeScript(&alt_writer, case.shell, .alt_up);
        const alt_up = alt_writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, alt_up, case.alt_up) != null);
        try std.testing.expect(std.mem.indexOf(u8, alt_up, case.up) == null);
        try std.testing.expect(std.mem.indexOf(u8, alt_up, case.ctrl_up) == null);
        try std.testing.expect(std.mem.indexOf(u8, alt_up, history_binding_marker) == null);
    }
}
