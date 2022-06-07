const beam = @import("beam.zig");
const std = @import("std");

const EnumError = error {
    EnumNotFound
};

pub fn enum_from_atom(comptime T: type, env: beam.env, enum_atom: beam.term) !T {
    const type_info = @typeInfo(T);

    if (type_info != .Enum) {
        @compileError("the seed type in enum_from_atom must be an enum");
    }

    var enum_slice = try beam.get_atom_slice(env, enum_atom);
    defer beam.allocator.free(enum_slice);

    inline for (type_info.Enum.fields) | field | {
        switch (field.name[0]) {
            'A'...'Z' =>
                // do the thing where it could be an elixir alias
                if (std.mem.eql(u8, enum_slice[0..7], "Elixir.") and std.mem.eql(u8, enum_slice[7..], field.name)) {
                    return @intToEnum(T, field.value);
                },
            _ => {}
        }
        if (std.mem.eql(u8, enum_slice, field.name)) {
            return @intToEnum(T, field.value);
        }
    }

    return EnumError.EnumNotFound;
}