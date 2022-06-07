const beam = @import("beam.zig");
const std = @import("std");

const EnumError = error{EnumNotFound};

/// converts an atom into a zig enum, using zig metaprogramming.  In the case that
/// the zig enum is lower-cased, it will only take a lower-cased erlang atom.
/// In the case that the zig enum is upper-cased ASCII, it can take either an
/// upper-cased erlang atom OR an Elixir alias (this is an upper-cased atom with
/// "Elixir." prepended to it).
pub fn enum_from_atom(comptime T: type, env: beam.env, enum_atom: beam.term) !T {
    const type_info = @typeInfo(T);

    // compile-time guard to make sure we aren't footgunning ourself with this
    // function.  You're not allowed to used this on anything that isn't an enum.
    if (type_info != .Enum) {
        @compileError("the seed type in enum_from_atom must be an enum");
    }

    var atom_slice = try beam.get_atom_slice(env, enum_atom);
    defer beam.allocator.free(atom_slice);

    // at compile-time, unroll a check for each of the possible Enum names
    inline for (type_info.Enum.fields) |field| {
        // if it's capitalized, it might be an elixir alias.  Check to see if
        // it matches the case where "Elixir." has been prependend to the Enum name.
        switch (field.name[0]) {
            'A'...'Z' => if (std.mem.eql(u8, atom_slice[0..7], "Elixir.") and std.mem.eql(u8, atom_slice[7..], field.name)) {
                return @intToEnum(T, field.value);
            },
            _ => {},
        }

        // fallback for Elixir alias failure, or general case -- just see if the atom matches enum name.
        if (std.mem.eql(u8, atom_slice, field.name)) {
            return @intToEnum(T, field.value);
        }
    }

    // none of the unrolled cases matched and we tried to send an atom which doesn't match any of our
    // enum names.
    return EnumError.EnumNotFound;
}
