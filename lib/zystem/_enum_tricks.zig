const std = @import("std");
const expect = std.testing.expect;

/// Given an enum or tagged union, returns true if the comptime-supplied
/// string matches the name of the tag value.  This match process should
/// be, at runtime, O(1) in the number of tags available to the enum or
/// union, and it should also be O(1) in the length of the comptime tag
/// names.
pub fn isTag(enum_or_union: anytype, comptime tag_name: []const u8) bool {
    const T = @TypeOf(enum_or_union);
    const type_info = @typeInfo(T);
    const type_name = @typeName(T);

    // select the Enum type out of the type (in the case of the struct, extract it)
    const E = if (.Enum == type_info) T else if (.Union == type_info) (if (type_info.Union.tag_type) |TT| TT else {
        @compileError("attempted to use isTag on the untagged union " ++ type_name);
    }) else {
        @compileError("attempted to use isTag on a value of type (" ++ type_name ++ ") that isn't an enum or a union.");
    };

    comptime var unmatched: bool = true;
    inline for (@typeInfo(E).Enum.fields) |field| {
        // note that the next if statement is comptime, and is pruned if
        // the field name doesn't match the supplied value.  *At most* one
        // code block in this list of if statements should exist in
        // generated code.
        if (std.mem.eql(u8, field.name, tag_name)) {
            unmatched = false;

            // NB: for unions, this uses the "tagged union coerces to enum"
            // feature.
            return @enumToInt(enum_or_union) == field.value;
        }
    }

    if (unmatched) {
        @compileError("attempted to use isTag with the type " ++ type_name ++ " which doesn't have the tag " ++ tag_name);
    }

    unreachable;
}

test "isTag works with Enums" {
    const EnumType = enum { a, b };
    var a_type: EnumType = .a;
    var b_type: EnumType = .b;

    try expect(isTag(a_type, "a"));
    try expect(!isTag(a_type, "b"));
    try expect(isTag(b_type, "b"));
    try expect(!isTag(b_type, "a"));
}

test "isTag works with Tagged Unions" {
    const TaggedUnionEnum = enum { int, flt };

    const TaggedUnionType = union(TaggedUnionEnum) {
        int: i64,
        flt: f64,
    };

    var int = TaggedUnionType{ .int = 1234 };
    var flt = TaggedUnionType{ .flt = 12.34 };

    try expect(isTag(int, "int"));
    try expect(!isTag(int, "flt"));
    try expect(isTag(flt, "flt"));
    try expect(!isTag(flt, "int"));
}

// note: strictValues is ignored if strictInclusion is not set.
const AsSynonymousOptions = struct{
    strictInclusion: bool = true,
    strictValues: bool = false
};

pub fn asSynonymous(comptime T: type, source_enum: anytype) T {
    return asSynonymousAdvanced(T, source_enum, .{});
}

pub fn asSynonymousAdvanced(comptime T: type, source_enum: anytype, comptime options: AsSynonymousOptions) T {
    // assert that T is an enum, and source_enum is an enum.
    const dst_type_info = @typeInfo(T);
    const S = @TypeOf(source_enum);
    const src_type_info = @typeInfo(S);

    if (dst_type_info != .Enum) { @compileError("the destination type for asSynonymousAdvanced " ++ @typeName(T) ++ "is not an enum type."); }
    if (src_type_info != .Enum) { @compileError("the source type for asSynonymousAdvarced" ++ @typeName(S) ++ "is not an enum type"); }

    // run checks to make sure that the comptime options are honored
    inline for (src_type_info.Enum.fields) |src_field| {
        if (matchingEnumValue(dst_type_info, src_field.name)) |dst_value| {
            // run a check to make sure that the values match.
            if (options.strictValues and (dst_value != src_field.value)) {
                if (options.strictInclusion) {
                    @compileError("the tag " ++ src_field.name ++ "does not have the same value between destination and source");
                } else {
                    // "trust me, I will never supply an enum with a mismatched value."
                    unreachable;
                }
            }

            // TODO: decide what actual int size to use here:
            if (@enumToInt(source_enum) == src_field.value) {
                return @intToEnum(T, dst_value);
            }

        } else if (options.strictInclusion) {
            @compileError("the destination type " ++ @typeName(T) ++ " does not have the tag " ++ src_field.name ++ " which is in " ++ @typeName(S));
        } else {
            // "trust me, I will never supply an enum with a mismatched name"
            unreachable;
        }
    }
    unreachable;
}

fn matchingEnumValue(comptime target: std.builtin.TypeInfo, comptime name: []const u8) ?comptime_int {
    inline for (target.Enum.fields) | field | {
        const tag_matches = comptime std.mem.eql(u8, field.name, name);
        if (tag_matches) {
            return field.value;
        }
    }
    return null;
}

test "asSynonymous with default settings works" {
    const BigEnum = enum{ a, b, c};
    const SmallEnum = enum { a, b };

    const small: SmallEnum = .a;
    const big: BigEnum = asSynonymous(BigEnum, small);

    try expect(big == .a);
}