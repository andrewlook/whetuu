//! Shell indicator module. A small modifier letter follows the character when
//! enabled, distinguishing fish, zsh and bash without adding another segment
//! to the status line.

const std = @import("std");

const Env = @import("Env.zig");
const style = @import("style.zig");
const Span = style.Span;

/// The shell's initial as a superscript-style modifier letter. Bright black
/// keeps it secondary to the character's language or error color.
pub fn choose(shell: Env.Shell) Span {
    return .{
        .style = .{ .color = .bright_black },
        .text = switch (shell) {
            .fish => "ᶠ",
            .zsh => "ᶻ",
            .bash => "ᵇ",
        },
    };
}

test "each shell has a dim superscript suffix" {
    const fish = choose(.fish);
    try std.testing.expectEqualStrings("ᶠ", fish.text);
    try std.testing.expectEqualStrings("ᶻ", choose(.zsh).text);
    try std.testing.expectEqualStrings("ᵇ", choose(.bash).text);
    try std.testing.expectEqual(style.Color.bright_black, fish.style.color);
}
