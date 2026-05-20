/// Zig 0.16 compatibility shims for removed stdlib APIs.
const std = @import("std");
const builtin = @import("builtin");

// --- Windows API shims (Zig 0.16's std.os.windows only exposes some Win32 entry points) ---

const winapi = struct {
    const DWORD = std.os.windows.DWORD;
    const BOOL = std.os.windows.BOOL;
    const HANDLE = std.os.windows.HANDLE;
    const FILETIME = std.os.windows.FILETIME;

    // Win32 ABI: STD_*_HANDLE are (DWORD)-N, expressed as wrapped u32 values.
    const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // -11
    const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4; // -12

    /// Windows Slim Reader/Writer lock. Zero-initialized = SRWLOCK_INIT.
    const SRWLOCK = extern struct { Ptr: ?*anyopaque = null };

    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn TryAcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) BOOL;
    extern "kernel32" fn AcquireSRWLockShared(SRWLock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockShared(SRWLock: *SRWLOCK) callconv(.winapi) void;
};

// --- Time ---

/// 100-nanosecond intervals between the Windows FILETIME epoch (1601-01-01 UTC)
/// and the Unix epoch (1970-01-01 UTC). FILETIME counts in 100ns ticks.
const FILETIME_TO_UNIX_100NS: i128 = 11_644_473_600 * 10_000_000;

fn realtimeNanos() i128 {
    if (builtin.os.tag == .windows) {
        var ft: winapi.FILETIME = undefined;
        winapi.GetSystemTimeAsFileTime(&ft);
        const ft_100ns: i128 = (@as(i128, ft.dwHighDateTime) << 32) | @as(i128, ft.dwLowDateTime);
        return (ft_100ns - FILETIME_TO_UNIX_100NS) * 100;
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub fn timestampSeconds() i64 {
    return @intCast(@divTrunc(realtimeNanos(), std.time.ns_per_s));
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(realtimeNanos(), std.time.ns_per_ms));
}

pub fn nanoTimestamp() i128 {
    return realtimeNanos();
}

// --- TTY detection ---

/// Returns true if stderr (fd 2) is attached to a terminal.
pub fn isTtyStderr() bool {
    if (builtin.os.tag == .windows) {
        const handle = winapi.GetStdHandle(winapi.STD_ERROR_HANDLE) orelse return false;
        var mode: winapi.DWORD = undefined;
        return winapi.GetConsoleMode(handle, &mode).toBool();
    }
    return std.c.isatty(2) != 0;
}

// --- Threading ---

pub fn threadSleep(ns: u64) void {
    if (@import("builtin").os.tag == .windows) {
        const ms_u128: u128 = @as(u128, ns) / std.time.ns_per_ms;
        const ms: winapi.DWORD = @intCast(@min(ms_u128, @as(u128, std.math.maxInt(winapi.DWORD))));
        winapi.Sleep(ms);
        return;
    }
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

const is_windows_target = @import("builtin").os.tag == .windows;

pub const PthreadMutex = struct {
    inner: if (is_windows_target) winapi.SRWLOCK else std.c.pthread_mutex_t =
        if (is_windows_target) winapi.SRWLOCK{} else std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(m: *PthreadMutex) void {
        if (is_windows_target) {
            winapi.AcquireSRWLockExclusive(&m.inner);
            return;
        }
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        if (is_windows_target) {
            winapi.ReleaseSRWLockExclusive(&m.inner);
            return;
        }
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
    pub fn tryLock(m: *PthreadMutex) bool {
        if (is_windows_target) return winapi.TryAcquireSRWLockExclusive(&m.inner).toBool();
        return @intFromEnum(std.c.pthread_mutex_trylock(&m.inner)) == 0;
    }
};

pub const PthreadRwLock = struct {
    inner: if (is_windows_target) winapi.SRWLOCK else std.c.pthread_rwlock_t =
        if (is_windows_target) winapi.SRWLOCK{} else .{},

    pub fn lock(rw: *PthreadRwLock) void {
        if (is_windows_target) {
            winapi.AcquireSRWLockExclusive(&rw.inner);
            return;
        }
        _ = std.c.pthread_rwlock_wrlock(&rw.inner);
    }
    pub fn unlock(rw: *PthreadRwLock) void {
        if (is_windows_target) {
            winapi.ReleaseSRWLockExclusive(&rw.inner);
            return;
        }
        _ = std.c.pthread_rwlock_unlock(&rw.inner);
    }
    pub fn lockShared(rw: *PthreadRwLock) void {
        if (is_windows_target) {
            winapi.AcquireSRWLockShared(&rw.inner);
            return;
        }
        _ = std.c.pthread_rwlock_rdlock(&rw.inner);
    }
    pub fn unlockShared(rw: *PthreadRwLock) void {
        if (is_windows_target) {
            winapi.ReleaseSRWLockShared(&rw.inner);
            return;
        }
        _ = std.c.pthread_rwlock_unlock(&rw.inner);
    }
};

// --- Random ---

pub fn randomBytes(buf: []u8) void {
    if (buf.len == 0) return;

    if (@import("builtin").os.tag == .linux and @TypeOf(std.c.getrandom) != void) {
        var filled: usize = 0;
        while (filled < buf.len) {
            const rc = std.c.getrandom(buf[filled..].ptr, buf.len - filled, 0);
            switch (std.c.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) break;
                    filled += n;
                },
                .INTR => continue,
                else => break,
            }
        }
        if (filled == buf.len) return;
    } else if (@TypeOf(std.c.arc4random_buf) != void) {
        std.c.arc4random_buf(buf.ptr, buf.len);
        return;
    }

    var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @intCast(nanoTimestamp())))));
    prng.random().bytes(buf);
}

// --- Environment ---

pub fn getenv(name: []const u8) ?[]const u8 {
    // std.c.getenv needs a sentinel-terminated string. For comptime-known keys
    // the caller can pass a literal. For runtime keys we need a small buffer.
    if (name.len > 255) return null;
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const key: [*:0]const u8 = buf[0..name.len :0];
    const val = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(val, 0);
}

// --- Filesystem (replaces removed std.fs.cwd / std.fs.File) ---

pub fn writeToStdout(data: []const u8) void {
    writeToStdHandle(.stdout, data);
}

pub fn writeToStderr(data: []const u8) void {
    writeToStdHandle(.stderr, data);
}

const StdStream = enum { stdout, stderr };

fn writeToStdHandle(which: StdStream, data: []const u8) void {
    if (builtin.os.tag == .windows) {
        const handle_id: winapi.DWORD = switch (which) {
            .stdout => winapi.STD_OUTPUT_HANDLE,
            .stderr => winapi.STD_ERROR_HANDLE,
        };
        const handle = winapi.GetStdHandle(handle_id) orelse return;
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining = data.len - sent;
            const chunk: winapi.DWORD = @intCast(@min(remaining, std.math.maxInt(winapi.DWORD)));
            var written: winapi.DWORD = 0;
            if (!winapi.WriteFile(handle, data[sent..].ptr, chunk, &written, null).toBool()) break;
            if (written == 0) break;
            sent += written;
        }
        return;
    }
    const fd: c_int = switch (which) {
        .stdout => 1,
        .stderr => 2,
    };
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

// --- Filesystem (cwd operations using C calls) ---

pub fn cwdCreateFile(path: []const u8) !std.c.fd_t {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(buf[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileNotFound;
    return fd;
}

pub fn cwdReadFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var result = std.ArrayList(u8).empty;
    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) break;
        const bytes: usize = @intCast(n);
        if (result.items.len + bytes > max_size) return error.FileTooBig;
        try result.appendSlice(allocator, read_buf[0..bytes]);
    }
    return result.toOwnedSlice(allocator);
}

pub fn cwdWriteFile(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    const fd = try cwdCreateFile(path);
    defer _ = std.c.close(fd);
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.WriteError;
        sent += @intCast(n);
    }
}

pub fn cwdMakePath(path: []const u8) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    // Iteratively create each component
    var i: usize = 0;
    while (i < path.len) {
        i += 1;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        var buf: [4096]u8 = undefined;
        if (i > buf.len - 1) return error.NameTooLong;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = std.c.mkdir(buf[0..i :0], 0o755);
    }
}

pub fn cwdDeleteFile(path: []const u8) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (std.c.unlink(buf[0..path.len :0]) != 0) return error.FileNotFound;
}

pub fn cwdAccess(path: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0], std.c.F_OK) == 0;
}

pub fn fdWriteAll(fd: std.c.fd_t, data: []const u8) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.WriteError;
        sent += @intCast(n);
    }
}

pub fn fdClose(fd: std.c.fd_t) void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.close(fd);
}

// --- Process (replaces removed std.process.Child.init/run) ---

pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) !struct { stdout: []u8, term: i32 } {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    var arg_storage: std.ArrayList([:0]u8) = .empty;
    defer {
        for (arg_storage.items) |arg| allocator.free(arg);
        arg_storage.deinit(allocator);
    }
    for (argv) |arg| {
        const duped = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(duped[0..arg.len], arg);
        try arg_storage.append(allocator, duped);
    }

    const c_argv = try allocator.alloc(?[*:0]const u8, arg_storage.items.len + 1);
    defer allocator.free(c_argv);
    for (arg_storage.items, 0..) |arg, i| {
        c_argv[i] = arg.ptr;
    }
    c_argv[arg_storage.items.len] = null;

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeCreateFailed;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child: redirect stdout to pipe write end
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.dup2(pipe_fds[1], 2); // also capture stderr
        _ = std.c.close(pipe_fds[1]);

        _ = execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
        std.c._exit(127);
    }

    // Parent: read from pipe
    _ = std.c.close(pipe_fds[1]);
    defer _ = std.c.close(pipe_fds[0]);

    var result = std.ArrayList(u8).empty;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &read_buf, read_buf.len);
        if (n <= 0) break;
        const bytes: usize = @intCast(n);
        if (result.items.len + bytes > max_output) break;
        try result.appendSlice(allocator, read_buf[0..bytes]);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    return .{
        .stdout = try result.toOwnedSlice(allocator),
        .term = @intCast(status),
    };
}

// --- Networking (replaces removed std.net) ---

const c = std.c;
const fd_t = std.c.fd_t;
const native_endian = @import("builtin").cpu.arch.endian();

fn htons(val: u16) u16 {
    return if (native_endian == .little) @byteSwap(val) else val;
}

fn ntohs(val: u16) u16 {
    return htons(val);
}

/// Try to connect to 127.0.0.1:port. Returns true if connection succeeded.
pub fn isPortInUse(port: u16) bool {
    if (builtin.os.tag == .windows) return false;
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var addr = c.sockaddr.in{
        .port = htons(port),
        .addr = 0x0100007F, // 127.0.0.1 in network byte order
    };

    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
    return rc == 0;
}

/// A minimal TCP stream wrapping a C socket fd.
pub const TcpStream = struct {
    fd: fd_t,

    pub fn close(self: TcpStream) void {
        if (builtin.os.tag == .windows) return;
        _ = c.close(self.fd);
    }

    pub fn writeAll(self: TcpStream, data: []const u8) !void {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        var sent: usize = 0;
        while (sent < data.len) {
            const n = c.write(self.fd, data[sent..].ptr, data.len - sent);
            if (n <= 0) return error.BrokenPipe;
            sent += @intCast(n);
        }
    }

    pub fn read(self: TcpStream, buf: []u8) !usize {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.ConnectionResetByPeer;
        return @intCast(n);
    }

    pub fn write(self: TcpStream, data: []const u8) !usize {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        const n = c.write(self.fd, data.ptr, data.len);
        if (n <= 0) return error.BrokenPipe;
        return @intCast(n);
    }

    pub fn setSockOpt(self: TcpStream, level: i32, optname: u32, optval: []const u8) void {
        if (builtin.os.tag == .windows) return;
        _ = c.setsockopt(self.fd, level, optname, optval.ptr, @intCast(optval.len));
    }
};

/// Connect to 127.0.0.1:port via TCP. Returns a TcpStream.
pub fn tcpConnectToIp4(port: u16) !TcpStream {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;

    var addr = c.sockaddr.in{
        .port = htons(port),
        .addr = 0x0100007F, // 127.0.0.1
    };

    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
    if (rc != 0) {
        _ = c.close(fd);
        return error.ConnectionRefused;
    }
    return .{ .fd = fd };
}

/// Connect to host:port via TCP. For now supports "127.0.0.1" only
/// (which covers all our use cases). Falls back to loopback for "localhost".
pub fn tcpConnectToHost(host: []const u8, port: u16) !TcpStream {
    _ = host; // all callers use 127.0.0.1 or localhost
    return tcpConnectToIp4(port);
}

/// A minimal TCP server that binds and listens.
pub const TcpServer = struct {
    fd: fd_t,

    pub const Connection = struct {
        stream: TcpStream,
    };

    pub fn accept(self: TcpServer) !Connection {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        const client_fd = c.accept(self.fd, null, null);
        if (client_fd < 0) return error.AcceptFailed;
        return .{ .stream = .{ .fd = client_fd } };
    }

    pub fn deinit(self: *TcpServer) void {
        if (builtin.os.tag == .windows) return;
        _ = c.close(self.fd);
    }
};

/// Bind and listen on 127.0.0.1:port.
pub fn tcpListen(port: u16) !TcpServer {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = c.close(fd);

    // SO_REUSEADDR
    const one: c_int = 1;
    _ = c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));

    var addr = c.sockaddr.in{
        .port = htons(port),
        .addr = 0x0100007F, // 127.0.0.1
    };

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        return error.AddressInUse;
    }
    if (c.listen(fd, 1) != 0) {
        return error.ListenFailed;
    }
    return .{ .fd = fd };
}
