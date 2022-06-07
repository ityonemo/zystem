defmodule Zystem.Nif do
  use Zig, link_libc: true

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

  fn setup() void {
    var sa: sig.sigaction = undefined;
    var sa_ptr = @ptrCast([*]u8, &sa);
    for (sa_ptr[0..@sizeOf(sig.sigaction)]) | *byte | { byte.* = 0; }

    sig.sigfillset(&sa.sa_mask);
    sa.sa_handler = null;
    sa.sa_flags = 0;
    sig.sigaction(sig.SIGCHLD, &sa, null);
  }

  /// resource: child_process_t definition
  const child_process_t = *std.ChildProcess;

  /// resource: child_process_t cleanup
  fn ChildProcess_cleanup(_: beam.env, child: *child_process_t) void {
    for (child.*.argv) |arg| {
      beam.allocator.free(arg);
    }

    if (child.*.env_map) | const_env_map | {
      // unfortunately const erasure here is necessary.
      var env_map = @intToPtr(*std.BufMap, @ptrToInt(const_env_map));
      env_map.deinit();
      beam.allocator.destroy(env_map);
    }

    beam.allocator.free(child.*.argv);
    child.*.deinit();
  }

  const ChildOpts = struct{
    cwd: ?[]const u8 = null,
    env: ?beam.term = null,
    stdin: std.ChildProcess.StdIo = .Ignore,
    stdout: std.ChildProcess.StdIo = .Pipe,
    stderr: std.ChildProcess.StdIo = .Inherit
  };

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

    // create the child process and then
    // NB this is going to change on Zig 0.10
    var child: child_process_t = try std.ChildProcess.init(args, beam.allocator);
    errdefer child.deinit();

    // get more options from the opts piece
    var child_opts = try struct_from_kwl(e, env, ChildOpts, opts);

    // possibly create an env_map
    if (child_opts.env) |env_term| {
      child.env_map = try env_map_from_term(e, env, env_term);
    }

    child.stdin_behavior = child_opts.stdin;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = child_opts.stderr; // child_opts.stderr;

    child.cwd = child_opts.cwd;

    var res = try __resource__.create(child_process_t, env, child);
    __resource__.release(child_process_t, env, res);

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
  fn exec(env: beam.env, child_term: beam.term) !void {
    var child = try __resource__.fetch(child_process_t, env, child_term);
    const self = try beam.self(env);

    try child.spawn();

    try collect_output(env, child, self);
    var result = try child.wait();

    // in the future, make the last bit anytype.
    send_response(env, self, "end", beam.make_u8(env, result.Exited));
  }

  fn collect_output(
    env: beam.env,
    child: *const std.ChildProcess,
    self: beam.pid
  ) !void {

    // TODO: incorporate stdout stuff too.
    var poll = [1]os.pollfd{.{.fd = child.stdout.?.handle, .events = os.POLL.IN, .revents = undefined }};

    const err_mask = os.POLL.ERR | os.POLL.NVAL | os.POLL.HUP;

    // TODO: make the buffer size variable here.  CONSIDER USING A DIFFERENT BUFFERING STRATEGY.
    var buf: [512]u8 = undefined;

    while (true) {
        const events = try os.poll(&poll, std.math.maxInt(i32));
        if (events == 0) continue;

        // Try reading whatever is available before checking the error
        // conditions.
        // It's still possible to read after a POLL.HUP is received, always
        // check if there's some data waiting to be read first.
        if (poll[0].revents & os.POLL.IN != 0) {
            // stdout is ready.
            const nread = try os.read(poll[0].fd, buf[0..]);

            // Exit the loop if we have everything, otherwise send to the parent process
            if (nread == 0) {
              break;
            } else {
              var binary = beam.make_slice(env, buf[0..nread]);
              send_response(env, self, "stdout", binary);
            }
        } else {
            if (poll[0].revents & err_mask != 0) { break; }
        }
    }
  }

  fn send_response(env: beam.env, self: beam.pid, atom: []const u8, term: beam.term) void {
    var tuple = [_]beam.term{beam.make_atom(env, atom), term};
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
