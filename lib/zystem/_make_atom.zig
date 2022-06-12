const beam = @import("beam.zig");
const std = @import("std");

const UnionError = enum{ UnionIsNotAnEnum };

pub fn make_atom(env: beam.env, enum_value: anytype) !beam.term {
    const T = @TypeOf(enum_value);
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
        return make_atom_from_union(env, enum_value);
    }

    return beam.make_atom(env, @tagName(enum_value));
}

fn make_atom_from_union(env: beam.env, union_value: anytype) !beam.term {
    comptime var has_enums: bool = false;
    const T = @TypeOf(union_value);
    const type_info = @typeInfo(T);

    inline for (type_info.Union.fields) |field| {
        // attempt to interpret the atom as the field type; if it fails, then keep going
        // through the inline for loop.

        if (field.field_type == .Enum) {
            has_enums = true;
            var tag_name = @tagName(union_value);

            // see if the union tag matches the expected tag.  Is there a comptime way to do this better?
            if (std.mem.eql(u8, tag_name, field.name)) {
                return beam.make_atom(env, tag_name);
            }
        }
    }

    if (!has_enums) {
        @compileError("the seed type in enum_for_atom is a union that does not have any enums, got " ++ @typeName(T));
    }

    return UnionError.UnionIsNotAnEnum;
}