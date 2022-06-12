const beam = @import("beam.zig");
const std = @import("std");

const EnumError = error{EnumNotFound};

/// converts an atom into a zig enum, using zig metaprogramming.  In the case that
/// the zig enum is lower-cased, it will only take a lower-cased erlang atom.
/// In the case that the zig enum is upper-cased ASCII, it can take either an
/// upper-cased erlang atom OR an Elixir alias (this is an upper-cased atom with
/// "Elixir." prepended to it).
///
/// warning: if two unions share a name (possibly with different integer assignments)
/// then (for now) this function won't be able to correctly assign the enumeration
/// AND the type, it will pick the first choice in the union.
pub fn enum_from_atom(comptime T: type, env: beam.env, enum_atom: beam.term) !T {
    const type_info = @typeInfo(T);

    // compile-time guard to make sure we aren't footgunning ourself with this
    // function.  You're not allowed to used this on anything that isn't an enum, or
    // possibly, a union of Enums.
    if ((type_info != .Enum) and (type_info != .Union)) {
        @compileError("the seed type in enum_from_atom must be an enum or a union with an enum, got "
          ++ @typeName(T)
          ++ " which is "
          ++ @tagName(type_info));
    }

    if (type_info == .Union) {
        return union_with_enum_from_atom(T, env, enum_atom);
    }

    var atom_slice = try beam.get_atom_slice(env, enum_atom);
    defer beam.allocator.free(atom_slice);

    const maybe_elixir = atom_slice.len >= 7;

    // at compile-time, unroll a check for each of the possible Enum names
    inline for (type_info.Enum.fields) |field| {
        // if it's capitalized, it might be an elixir alias.  Check to see if
        // it matches the case where "Elixir." has been prependend to the Enum name.
        switch (field.name[0]) {
            'A'...'Z' => if (maybe_elixir and std.mem.eql(u8, atom_slice[0..7], "Elixir.") and std.mem.eql(u8, atom_slice[7..], field.name)) {
                return @intToEnum(T, field.value);
            },
            else => {},
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

fn union_with_enum_from_atom(comptime T: type, env: beam.env, enum_atom: beam.term) !T {
    comptime var has_enums: bool = false;
    const type_info = @typeInfo(T);

    inline for (type_info.Union.fields) |field| {
        // attempt to interpret the atom as the field type; if it fails, then keep going
        // through the inline for loop.
        if (field.field_type == .Enum) {
            has_enums = true;
            return enum_from_atom(field.field_type, env, enum_atom) catch |err| switch (err)
            {
                .EnumNotFound => continue,
                else => err,
            };
        }
    }

    if (!has_enums) {
        @compileError("the seed type in enum_for_atom is a union that does not have any enums, got" ++ @typeName(T));
    }

    // none of the unrolled union fields matched, so we have to give up.
    return EnumError.EnumNotFound;
}