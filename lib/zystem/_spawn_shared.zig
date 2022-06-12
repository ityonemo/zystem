//! spawn_shared.zig
//!
//! currently the zig stdlib's ChildProcess struct has a spawn function which
//! does NOT take into account the possibility that you might want to share a
//! file descriptor between stdout and stderr.  This fixes that condition.

const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const os = std.os;
const mem = std.mem;
const linux = std.os.linux;

// convenience aliasing
const ChildProcess = std.ChildProcess;
const File = std.fs.File;
const SpawnError = std.ChildProcess.SpawnError;
const StdIo = std.ChildProcess.StdIo;
const assert = std.debug.assert;

// consider the following cases:

pub fn spawnShared(child: *ChildProcess) SpawnError!void {
    if (builtin.os.tag == .windows) {
        // currently zigler doesn't support windows; in future releases
        // activating this will be important.
        unreachable;
    } else {
        try spawnSharedPosix(child);
    }
}

fn spawnSharedPosix(child: *ChildProcess) SpawnError!void {
    const pipe_flags = if (io.is_async) os.O.NONBLOCK else 0;
    const stdin_pipe = if (child.stdin_behavior == StdIo.Pipe) try os.pipe2(pipe_flags) else undefined;
    errdefer if (child.stdin_behavior == StdIo.Pipe) {
        destroyPipe(stdin_pipe);
    };

    const shared_pipe = try os.pipe2(pipe_flags);
    errdefer destroyPipe(shared_pipe);

    const ignore_stdin = (child.stdin_behavior == StdIo.Ignore);
    const dev_null_fd = if (ignore_stdin)
        os.openZ("/dev/null", os.O.RDWR, 0) catch |err| switch (err) {
            error.PathAlreadyExists => unreachable,
            error.NoSpaceLeft => unreachable,
            error.FileTooBig => unreachable,
            error.DeviceBusy => unreachable,
            error.FileLocksNotSupported => unreachable,
            error.BadPathName => unreachable, // Windows-only
            error.WouldBlock => unreachable,
            else => |e| return e,
        }
    else
        undefined;
    defer {
        if (ignore_stdin) os.close(dev_null_fd);
    }

    var arena_allocator = std.heap.ArenaAllocator.init(child.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // The POSIX standard does not allow malloc() between fork() and execve(),
    // and `child.allocator` may be a libc allocator.
    // I have personally observed the child process deadlocking when it tries
    // to call malloc() due to a heap allocation between fork() and execve(),
    // in musl v1.1.24.
    // Additionally, we want to reduce the number of possible ways things
    // can fail between fork() and execve().
    // Therefore, we do all the allocation for the execve() before the fork().
    // This means we must do the null-termination of argv and env vars here.
    const argv_buf = try arena.allocSentinel(?[*:0]u8, child.argv.len, null);
    for (child.argv) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const envp = m: {
        if (child.env_map) |env_map| {
            const envp_buf = try createNullDelimitedEnvMap(arena, env_map);
            break :m envp_buf.ptr;
        } else if (builtin.link_libc) {
            break :m std.c.environ;
        } else if (builtin.output_mode == .Exe) {
            // Then we have Zig start code and this works.
            // TODO type-safety for null-termination of `os.environ`.
            break :m @ptrCast([*:null]?[*:0]u8, os.environ.ptr);
        } else {
            // TODO come up with a solution for this.
            @compileError("missing std lib enhancement: ChildProcess implementation has no way to collect the environment variables to forward to the child process");
        }
    };

    // This pipe is used to communicate errors between the time of fork
    // and execve from the child process to the parent process.
    const err_pipe = blk: {
        if (builtin.os.tag == .linux) {
            const fd = try os.eventfd(0, linux.EFD.CLOEXEC);
            // There's no distinction between the readable and the writeable
            // end with eventfd
            break :blk [2]os.fd_t{ fd, fd };
        } else {
            break :blk try os.pipe2(os.O.CLOEXEC);
        }
    };
    errdefer destroyPipe(err_pipe);

    const pid_result = try os.fork();
    if (pid_result == 0) {
        // we are the child
        setUpChildIo(child.stdin_behavior, stdin_pipe[0], os.STDIN_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);
        setUpChildIo(.Pipe, shared_pipe[1], os.STDOUT_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);
        setUpChildIo(.Pipe, shared_pipe[1], os.STDERR_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);

        if (child.stdin_behavior == .Pipe) {
            os.close(stdin_pipe[0]);
            os.close(stdin_pipe[1]);
        }

        os.close(shared_pipe[0]);
        os.close(shared_pipe[1]);

        if (child.cwd_dir) |cwd| {
            os.fchdir(cwd.fd) catch |err| forkChildErrReport(err_pipe[1], err);
        } else if (child.cwd) |cwd| {
            os.chdir(cwd) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        if (child.gid) |gid| {
            os.setregid(gid, gid) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        if (child.uid) |uid| {
            os.setreuid(uid, uid) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        const err = switch (child.expand_arg0) {
            .expand => os.execvpeZ_expandArg0(.expand, argv_buf.ptr[0].?, argv_buf.ptr, envp),
            .no_expand => os.execvpeZ_expandArg0(.no_expand, argv_buf.ptr[0].?, argv_buf.ptr, envp),
        };
        forkChildErrReport(err_pipe[1], err);
    }

    // we are the parent
    const pid = @intCast(i32, pid_result);
    if (child.stdin_behavior == StdIo.Pipe) {
        child.stdin = File{ .handle = stdin_pipe[1] };
    } else {
        child.stdin = null;
    }

    child.stdout = File{ .handle = shared_pipe[0] };
    child.stderr = null;

    child.pid = pid;
    child.err_pipe = err_pipe;
    child.term = null;

    if (child.stdin_behavior == StdIo.Pipe) {
        os.close(stdin_pipe[0]);
    }

    os.close(shared_pipe[1]);
}

fn destroyPipe(pipe: [2]os.fd_t) void {
    os.close(pipe[0]);
    if (pipe[0] != pipe[1]) os.close(pipe[1]);
}

fn setUpChildIo(stdio: StdIo, pipe_fd: i32, std_fileno: i32, dev_null_fd: i32) !void {
    switch (stdio) {
        .Pipe => try os.dup2(pipe_fd, std_fileno),
        .Close => os.close(std_fileno),
        .Inherit => {},
        .Ignore => try os.dup2(dev_null_fd, std_fileno),
    }
}

fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const std.BufMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
    {
        var it = env_map.iterator();
        var i: usize = 0;
        while (it.next()) |pair| : (i += 1) {
            const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
            mem.copy(u8, env_buf, pair.key_ptr.*);
            env_buf[pair.key_ptr.len] = '=';
            mem.copy(u8, env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
            envp_buf[i] = env_buf.ptr;
        }
        assert(i == envp_count);
    }
    return envp_buf;
}

fn forkChildErrReport(fd: i32, err: SpawnError) noreturn {
    writeIntFd(fd, @as(ErrInt, @errorToInt(err))) catch {};
    // If we're linking libc, some naughty applications may have registered atexit handlers
    // which we really do not want to run in the fork child. I caught LLVM doing this and
    // it caused a deadlock instead of doing an exit syscall. In the words of Avril Lavigne,
    // "Why'd you have to go and make things so complicated?"
    if (builtin.link_libc) {
        // The _exit(2) function does nothing but make the exit syscall, unlike exit(3)
        std.c._exit(1);
    }
    os.exit(1);
}

const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

fn writeIntFd(fd: i32, value: ErrInt) !void {
    const file = File{
        .handle = fd,
        .capable_io_mode = .blocking,
        .intended_io_mode = .blocking,
    };
    file.writer().writeIntNative(u64, @intCast(u64, value)) catch return error.SystemResources;
}