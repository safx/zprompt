// ANSI color codes wrapped in zsh %{..%} for correct prompt width calculation.

pub const reset = "%{\x1b[0m%}";
pub const green = "%{\x1b[32m%}";
pub const cyan = "%{\x1b[36m%}";
pub const yellow = "%{\x1b[33m%}";
pub const red = "%{\x1b[31m%}";
pub const purple = "%{\x1b[35m%}";
pub const white = "%{\x1b[97m%}";
pub const bright_green = "%{\x1b[92m%}";
pub const bold_yellow = "%{\x1b[1;33m%}";
pub const fg_666 = "%{\x1b[38;2;102;102;102m%}";
pub const fg_f60 = "%{\x1b[38;2;255;96;96m%}";

const std = @import("std");
const Writer = std.io.Writer;

pub fn styled(w: *Writer, color: []const u8, text: []const u8) !void {
    try w.writeAll(color);
    try w.writeAll(text);
    try w.writeAll(reset);
}
