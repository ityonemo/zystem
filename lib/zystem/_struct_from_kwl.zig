const beam = @import("beam.zig");
const std = @import("std");

const KeywordError = error{NotKeyword};

fn remove_optional(comptime T: type) type {
    // strip optional
    const type_info = @typeInfo(T);
    if (type_info == .Optional) {
        return type_info.Optional.child;
    } else {
        return T;
    }
}

fn remove_const(comptime T: type) type {
    var type_info = @typeInfo(T);
    switch (type_info) {
        .Pointer => {
            type_info.Pointer.is_const = false;
            return @Type(type_info);
        },
        else => return T,
    }
}

// TODO: remove the weird comptime e thing on zigler 0.10.0
pub fn struct_from_kwl(comptime e: type, env: beam.env, comptime T: type, opts: beam.term) !T {
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        @compileError("the seed structure in struct_from_kwl must be a struct");
    }
    if (type_info.Struct.is_tuple) {
        @compileError("the seed structure in struct.from_kwl must not be a tuple");
    }

    var result: T = undefined;

    inline for (type_info.Struct.fields) |field| {
        if (field.default_value != null) {
            @field(result, field.name) = field.default_value.?;
        }
    }

    var this_list = opts;
    var head_term: beam.term = undefined;
    var continue_list = (1 == e.enif_get_list_cell(env, this_list, &head_term, &this_list));
    while (continue_list) {
        var tuple_length: c_int = undefined;
        var tuple_terms: [*c]const beam.term = undefined;

        if (0 != e.enif_get_tuple(env, head_term, &tuple_length, &tuple_terms)) {
            if (tuple_length != 2) {
                return KeywordError.NotKeyword;
            }

            const key_term = tuple_terms[0];
            const val_term = tuple_terms[1];

            var key = try beam.get_atom_slice(env, key_term);
            defer beam.allocator.free(key);

            // does it match any field?
            inline for (type_info.Struct.fields) |field| {
                // TODO: make this honor nil if it's optional.
                const __ft = remove_optional(field.field_type);
                const field_type = remove_const(__ft);

                if (std.mem.eql(u8, field.name, key)) {
                    @field(result, field.name) =
                        switch (field_type) {
                        beam.term => val_term,
                        []u8 => try beam.get_char_slice(env, val_term),
                        else => try beam.get(field_type, env, val_term),
                    };
                }
            }
        }

        continue_list = (1 == e.enif_get_list_cell(env, this_list, &head_term, &this_list));
        if (0 == e.enif_is_list(env, this_list)) {
            return KeywordError.NotKeyword;
        }
    }

    return result;
}
