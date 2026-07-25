//! Shell indicator module. A small modifier letter follows the character when
//! enabled, distinguishing fish, zsh and bash without adding another segment
//! to the status line.

const std = @import("std");

const Env = @import("Env.zig");
const style = @import("style.zig");
const Span = style.Span;
const Style = style.Style;

/// The shell's initial as a superscript-style modifier letter. It shares the
/// character's resolved color while staying unbolded and visually secondary.
pub fn choose(shell: Env.Shell, character_style: Style) Span {
    return .{
        .style = .{ .color = character_style.color, .rgb = character_style.rgb },
        .text = switch (shell) {
            .fish => "ᶠ",
            .zsh => "ᶻ",
            .bash => "ᵇ",
        },
    };
}

test "each shell has an unbolded superscript suffix in the character color" {
    const character_style: Style = .{ .bold = true, .rgb = style.purple };
    const fish = choose(.fish, character_style);
    try std.testing.expectEqualStrings("ᶠ", fish.text);
    try std.testing.expectEqualStrings("ᶻ", choose(.zsh, character_style).text);
    try std.testing.expectEqualStrings("ᵇ", choose(.bash, character_style).text);
    try std.testing.expectEqual(style.purple, fish.style.rgb.?);
    try std.testing.expect(!fish.style.bold);

    const failed_style: Style = .{ .bold = true, .color = .red };
    const failed = choose(.fish, failed_style);
    try std.testing.expectEqual(style.Color.red, failed.style.color);
    try std.testing.expect(!failed.style.bold);
}
