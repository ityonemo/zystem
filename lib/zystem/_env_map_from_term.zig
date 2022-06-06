const beam = @import("beam.zig");
const std = @import("std");

const EnvError = error { NotProplist };
const BufMap = std.BufMap;

// TODO: remove the weird comptime e thing on zigler 0.10.0
// note: ownership of the returned BufMap is passed on to the caller.
pub fn env_map_from_term(comptime e: type, env: beam.env, env_list: beam.term) !*BufMap {
    var env_map : *BufMap = try beam.allocator.create(BufMap);
    env_map.* = BufMap.init(beam.allocator);
    errdefer {
        env_map.deinit();
        beam.allocator.destroy(env_map);
    }

    var index:usize = 0;
    var rest_list = env_list;
    var head_term: beam.term = undefined;
    var continue_list = (1 == e.enif_get_list_cell(env, rest_list, &head_term, &rest_list));
    while (continue_list) {
        var tuple_length: c_int = undefined;
        var tuple_terms: [*c]const beam.term = undefined;

        index += 1;

        if (0 != e.enif_get_tuple(env, head_term, &tuple_length, &tuple_terms)) {
            if (tuple_length != 2) {
                return EnvError.NotProplist;
            }

            const key_term = tuple_terms[0];
            const val_term = tuple_terms[1];

            var key = try beam.get_char_slice(env, key_term);
            var val = try beam.get_char_slice(env, val_term);

            try env_map.put(key, val);
        }

        continue_list = (1 == e.enif_get_list_cell(env, rest_list, &head_term, &rest_list));
        if (0 == e.enif_is_list(env, rest_list)) {
            return EnvError.NotProplist;
        }
    }

    return env_map;
}