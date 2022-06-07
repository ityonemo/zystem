//! simple program which prints stderr to stderr and stdout to stdout

const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

pub fn main() !void {
    var std_out = std.io.getStdOut();

    std.debug.print("stderr\n", .{});  // to stderr
    _ = try std_out.write("stdout\n"); // to stdout
}