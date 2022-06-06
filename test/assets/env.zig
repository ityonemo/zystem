//! simple program which takes the first argument, then seeks the
//! environment variable which matches this argument and then outputs
//! the key for that variable.

const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

pub fn main() !u8 {
    var std_out = std.io.getStdOut();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("env.zig requires one argument, which the environment variable to return\n", .{});
        return 255;
    }

    var env_var = args[1];

    for (std.os.environ) |ev| {
        var ev_slice = std.mem.sliceTo(ev, 0);
        if (ev_slice.len >= 4) {
            if (std.mem.eql(u8, ev_slice[0..env_var.len], env_var)) {
                _ = try std_out.write(ev_slice[4..]);
                return 0;
            }
        }
    } else {
        std.debug.print("env.zig did not find the environment variable {s}\n", .{env_var});
        return 255;
    }
}