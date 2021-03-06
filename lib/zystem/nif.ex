defmodule Zystem.Nif do
  use Zig, link_libc: true

  # SOME OF THIS CODE IS SHAMELESSLY STOLEN FROM THE ZIG STD LIBRARY.
  # THAT IS (C) some-time-in-the-past The Zig Authors
  # I WILL DO A BETTER ATTRIBUTION WHEN THIS THING IS MORE FLESHED OUT.

  ~Z"""
  const BEAM_FALSE = 0;
  const os = std.os;

  const sig = @cImport({
    @cInclude("signal.h");
  });

  const wait = @cImport({
    @cInclude("wait.h");
  });

  const struct_from_kwl = @import("_struct_from_kwl.zig").struct_from_kwl;
  const env_map_from_term = @import("_env_map_from_term.zig").env_map_from_term;
  const make_atom = @import("_make_atom.zig").make_atom;
  const isTag = @import("_enum_tricks.zig").isTag;
  const asSynonymousAdvanced = @import("_enum_tricks.zig").asSynonymousAdvanced;
  const spawnShared = @import("_spawn_shared.zig").spawnShared;

  const ZystemOpts = struct{
    cwd: ?[]const u8 = null,
    env: ?beam.term = null,
    stdin: std.ChildProcess.StdIo = .Ignore,
    stdout: std.ChildProcess.StdIo = .Pipe,
    stderr: StdErr = .Inherit
  };

  /// resource: ZystemRes definition
  const ZystemRes = struct {
    child: *std.ChildProcess,
    opts: ZystemOpts,
  };

  /// resource: ZystemRes cleanup
  fn zystem_info_cleanup(_: beam.env, zystem_res: *ZystemRes) void {
    const child = zystem_res.child;

    for (child.argv) |arg| {
      beam.allocator.free(arg);
    }

    if (child.env_map) | const_env_map | {
      // unfortunately const erasure here is necessary.
      var env_map = @intToPtr(*std.BufMap, @ptrToInt(const_env_map));
      env_map.deinit();
      beam.allocator.destroy(env_map);
    }

    beam.allocator.free(child.argv);
    child.deinit();
  }

  const StdErr = enum {
    Ignore, Pipe, Inherit, Close, stdout
  };

  const StdFd = enum { stdin, stdout, stderr };

  const ExitEnum = enum { end };

  fn stderr_behavior(option: StdErr) std.ChildProcess.StdIo {
    if (option == .stdout) return .Ignore;
    return asSynonymousAdvanced(std.ChildProcess.StdIo, option, .{.strictInclusion = false});
  }

  /// nif: build/3
  fn build(env: beam.env, cmd: []u8, beam_args: beam.term, opts: beam.term) !beam.term {
    // create the arguments list.  Simultaneously checks if it's a proper
    // list.  If it's improper or not a list, raises FCE.
    var length: c_uint = undefined;
    if (e.enif_get_list_length(env, beam_args, &length) == BEAM_FALSE) {
      return beam.raise_function_clause_error(env);
    }

    // ownership of the args list will pass to the ChildProcess struct.
    var args: [][]const u8 = try beam.allocator.alloc([] const u8, length + 1);
    errdefer beam.allocator.free(args);

    // populate the cmd as the first argument, then pull the rest
    // from the erlang list elements.  Raises FCE if it's not a slice.
    var rest_arg = beam_args;
    args[0] = try copy(cmd);
    errdefer beam.allocator.free(args[0]);

    for (args[1..]) | *arg, index | {
      var this_arg: beam.term = undefined;
      // this can't fail:
      _ = e.enif_get_list_cell(env, rest_arg, &this_arg, &rest_arg);
      var arg_slice = try beam.get_char_slice(env, this_arg);
      arg.* = copy(arg_slice) catch |err| {
        for (args[1..(index + 1)]) | arg_ | { beam.allocator.free(arg_); }
        return err;
      };
    }
    errdefer for(args[1..]) | arg | { beam.allocator.free(arg); };

    // NB this is going to change on Zig 0.10
    var child = try std.ChildProcess.init(args, beam.allocator);
    errdefer child.deinit();

    // get more options from the opts piece
    var child_opts = try struct_from_kwl(e, env, ZystemOpts, opts);

    // possibly create an env_map
    if (child_opts.env) |env_term| {
      child.env_map = try env_map_from_term(e, env, env_term);
    }

    child.stdin_behavior = child_opts.stdin;
    child.stdout_behavior = child_opts.stdout;
    child.stderr_behavior = stderr_behavior(child_opts.stderr);

    child.cwd = child_opts.cwd;

    var res = try __resource__.create(ZystemRes, env, .{.child = child, .opts = child_opts});
    __resource__.release(ZystemRes, env, res);

    return res;
  }

  // utility functions
  // note: copy relinquishes ownership of the slice.
  fn copy(slice: []u8) ![]u8 {
    var result = try beam.allocator.alloc(u8, slice.len);
    std.mem.copy(u8, result, slice);
    return result;
  }

  /// nif: exec/1 dirty_io
  fn exec(env: beam.env, zystem_res: beam.term) !void {
    const res = try __resource__.fetch(ZystemRes, env, zystem_res);
    var child = res.child;

    const self = try beam.self(env);

    if (res.opts.stderr == .stdout) {
      try spawnShared(child);
    } else {
      try child.spawn();
    }

    try collect_output(env, child, self);
    var result = try child.wait();

    // in the future, make the last bit anytype.
    try send_response(env, self, ExitEnum.end, beam.make_u8(env, result.Exited));
  }

  fn collect_output(
    env: beam.env,
    child: *const std.ChildProcess,
    self: beam.pid
  ) !void {
    var poll_buffer: [2]os.pollfd = undefined;
    var fds: [2]StdFd = undefined;

    var poll_count: usize = 0;

    // check stdout, it pipes if it's Pipe or inherit
    if ((child.stdout_behavior == .Pipe) or (child.stdout_behavior == .Inherit)) {
      poll_buffer[poll_count] = .{.fd = child.stdout.?.handle, .events = os.POLL.IN, .revents = undefined };
      fds[poll_count] = .stdout;
      poll_count += 1;
    }

    if (child.stderr_behavior == .Pipe) {
      poll_buffer[poll_count] = .{.fd = child.stderr.?.handle, .events = os.POLL.IN, .revents = undefined };
      fds[poll_count] = .stderr;
      poll_count += 1;
    }

    var poll = poll_buffer[0..poll_count];

    const err_mask = os.POLL.ERR | os.POLL.NVAL | os.POLL.HUP;

    // TODO: make the buffer size variable here.  OR CONSIDER USING A DIFFERENT BUFFERING STRATEGY.
    var buf: [512]u8 = undefined;
    var finished: usize = 0;

    while (finished < poll_count) {
        const events = try os.poll(poll, std.math.maxInt(i32));
        if (events == 0) continue;

        // Try reading whatever is available before checking the error
        // conditions.
        // It's still possible to read after a POLL.HUP is received, always
        // check if there's some data waiting to be read first.

        for (poll) |polled, index| {
          if (polled.revents & os.POLL.IN != 0) {
            // this file descriptor is ready to be read.
            const nread = try os.read(polled.fd, buf[0..]);

            if (nread == 0) {
              // exit the loop if we have exhausted all things
              if (finished == poll_count) { return; }
              // otherwise keep looping, but mark this as having read data.
              finished += 1;
              continue;
            } else {
              var binary = beam.make_slice(env, buf[0..nread]);
              try send_response(env, self, fds[index], binary);
            }
          } else {
            if (polled.revents & err_mask != 0) {
              finished += 1;
              break;
            }
          }
        }
    }
  }

  fn send_response(env: beam.env, self: beam.pid, atom: anytype, term: beam.term) !void {
    var tuple = [_]beam.term{try make_atom(env, atom), term};

    _ = beam.send(
      env,
      self,
      beam.make_tuple(
        env,
        tuple[0..]
      )
    );
  }

  """
end
