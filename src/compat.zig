/// Zig 0.16 compatibility shims for removed stdlib APIs.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// --- Windows kernel32 extern bindings ---
// Zig 0.16's std.os.windows.kernel32 is nearly empty (does not export
// GetStdHandle / WriteFile / GetFileType / QueryPerformanceCounter).
// Declare the bindings we need directly so the file type-checks on Windows.
// These are only referenced from inside `if (comptime is_windows)` branches
// so they don't affect POSIX builds.

const win = if (is_windows) struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;

    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
    const FILE_TYPE_CHAR: DWORD = 0x0002;

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
} else struct {};

// --- Time ---
//
// Use the impl-struct pattern (Zig idiom for "compile only one branch"):
// `if (cond) struct {...} else struct {...}` — Zig instantiates only the
// branch selected by the comptime-known `cond`, so the un-chosen struct's
// body is never type-checked. That matters because `std.c.clock_gettime` on
// Windows is an extern decl whose own parameter chain (timespec → void) FAILS
// type-check, so even a dead `if (comptime is_windows) ... else { std.c.clock_gettime(...) }`
// branch breaks the Windows build. Splitting into a struct sidesteps it.

const time_impl = if (is_windows) struct {
    pub fn timestampSeconds() i64 {
        return @intCast(@divTrunc(@This().milliTimestamp(), 1000));
    }
    pub fn milliTimestamp() i64 {
        return @intCast(@divTrunc(@This().nanoTimestamp(), std.time.ns_per_ms));
    }
    pub fn nanoTimestamp() i128 {
        var counter: i64 = 0;
        var freq: i64 = 0;
        _ = win.QueryPerformanceCounter(&counter);
        _ = win.QueryPerformanceFrequency(&freq);
        if (freq == 0) return 0;
        return @divTrunc(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
    }
} else struct {
    pub fn timestampSeconds() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return ts.sec;
    }
    pub fn milliTimestamp() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
    pub fn nanoTimestamp() i128 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    }
};

pub fn timestampSeconds() i64 { return time_impl.timestampSeconds(); }
pub fn milliTimestamp() i64 { return time_impl.milliTimestamp(); }
pub fn nanoTimestamp() i128 { return time_impl.nanoTimestamp(); }

// --- Threading ---

const thread_impl = if (is_windows) struct {
    pub fn threadSleep(ns: u64) void {
        // Sleep takes milliseconds; round up to keep "at least this long".
        const ms = (ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        win.Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
    }
} else struct {
    pub fn threadSleep(ns: u64) void {
        const ts = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&ts, null);
    }
};

pub fn threadSleep(ns: u64) void { thread_impl.threadSleep(ns); }

// On Windows the pthread_* types resolve to `void` (no libc pthreads in Zig's
// std.c), and Zig 0.16 removed std.Thread.Mutex in favor of the io-parameterized
// std.Io.Mutex. The compat mutex API is io-free (lock()/unlock()), so on Windows
// we back it with a minimal atomic spin-mutex — correct mutual exclusion for the
// broker's short critical sections, needing no io handle. POSIX keeps the exact
// pthread ABI. Same impl-struct pattern as time_impl.
pub const PthreadMutex = if (is_windows) struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(m: *PthreadMutex) void {
        while (m.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlock(m: *PthreadMutex) void {
        m.locked.store(false, .release);
    }
    pub fn tryLock(m: *PthreadMutex) bool {
        return !m.locked.swap(true, .acquire);
    }
} else struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
    pub fn tryLock(m: *PthreadMutex) bool {
        return @intFromEnum(std.c.pthread_mutex_trylock(&m.inner)) == 0;
    }
};

pub const PthreadRwLock = if (is_windows) struct {
    // Windows fallback: an exclusive atomic spin-lock for both read and write.
    // Serializing readers is correct (just less concurrent) and avoids needing
    // an io handle, which the io-free compat API cannot supply.
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn acquire(rw: *PthreadRwLock) void {
        while (rw.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn lock(rw: *PthreadRwLock) void {
        rw.acquire();
    }
    pub fn unlock(rw: *PthreadRwLock) void {
        rw.locked.store(false, .release);
    }
    pub fn lockShared(rw: *PthreadRwLock) void {
        rw.acquire();
    }
    pub fn unlockShared(rw: *PthreadRwLock) void {
        rw.locked.store(false, .release);
    }
} else struct {
    inner: std.c.pthread_rwlock_t = .{},

    pub fn lock(rw: *PthreadRwLock) void {
        _ = std.c.pthread_rwlock_wrlock(&rw.inner);
    }
    pub fn unlock(rw: *PthreadRwLock) void {
        _ = std.c.pthread_rwlock_unlock(&rw.inner);
    }
    pub fn lockShared(rw: *PthreadRwLock) void {
        _ = std.c.pthread_rwlock_rdlock(&rw.inner);
    }
    pub fn unlockShared(rw: *PthreadRwLock) void {
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
pub fn stderrIsTty() bool {
    if (comptime is_windows) {
        const handle = win.GetStdHandle(win.STD_ERROR_HANDLE);
        return win.GetFileType(handle) == win.FILE_TYPE_CHAR;
    }
    return std.c.isatty(2) != 0;
}

pub fn writeToStdout(data: []const u8) void {
    if (comptime is_windows) {
        const handle = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        var written: u32 = 0;
        _ = win.WriteFile(handle, data.ptr, @intCast(data.len), &written, null);
        return;
    }
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(1, data[sent..].ptr, data.len - sent);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

pub fn writeToStderr(data: []const u8) void {
    if (comptime is_windows) {
        const handle = win.GetStdHandle(win.STD_ERROR_HANDLE);
        var written: u32 = 0;
        _ = win.WriteFile(handle, data.ptr, @intCast(data.len), &written, null);
        return;
    }
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(2, data[sent..].ptr, data.len - sent);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

// --- Filesystem (cwd operations via std.Io.Dir, Zig 0.16 portable API) ---
// Wave 6 (Windows port): replaced the prior std.c.open/read/write/close
// trio with Zig 0.16's std.Io.Dir.cwd() API. Reason: Zig 0.16's
// lib/std/c.zig defines `extern "c" fn open(path, oflag: O, ...)` with a
// variadic `...` that violates the x86_64-windows ABI (`parameter of
// type 'void' not allowed in calling convention 'x86_64_win'`). Any
// reference to std.c.open transitively poisoned compat.cwd*File for
// Windows targets. std.Io.Dir.cwd() dispatches per-platform: kernel32
// on Windows, posix syscalls on darwin/linux; no libc extern dependency.
//
// API surface preserved for callers: cwdReadFile / cwdWriteFile still
// take the same args + return types. cwdCreateFile is removed (no
// external callers per zigrep; was an internal helper for the old
// fd-based cwdWriteFile that's now in-lined into Io.Dir.writeFile).
//
// API source: deepwiki ziglang/zig confirmed std.fs.cwd() moved to
// std.Io.Dir.cwd() in Zig 0.16, threadCtx via .init_single_threaded.

pub fn cwdReadFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_size));
}

pub fn cwdWriteFile(path: []const u8, data: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn cwdMakePath(path: []const u8) !void {
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
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (std.c.unlink(buf[0..path.len :0]) != 0) return error.FileNotFound;
}

pub fn cwdAccess(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0], std.c.F_OK) == 0;
}

pub fn fdWriteAll(fd: std.c.fd_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.WriteError;
        sent += @intCast(n);
    }
}

pub fn fdClose(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

// --- Process (replaces removed std.process.Child.init/run) ---

pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) !struct { stdout: []u8, term: i32 } {
    if (comptime is_windows) {
        @panic("kuri Windows port: runCommand not implemented yet — Wave-2 will ship via CreateProcessW + pipe redirection");
    }
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
/// Try to connect to 127.0.0.1:port. Returns true if connection succeeded.
pub fn isPortInUse(port: u16) bool {
    if (comptime is_windows) {
        return false;  // TODO Wave-2: WSAStartup + WSASocket + connect
    }
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
// Winsock (ws2_32) bindings for the Windows TCP path. ws2_32 is linked for the
// relevant binaries in build.zig. A SOCKET (usize) is stashed in the fd_t field
// (a HANDLE/pointer on Windows) via int↔ptr casts so TcpStream is shape-stable.
const wsock = if (is_windows) struct {
    pub const SOCKET = usize;
    pub const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
    pub const AF_INET: c_int = 2;
    pub const SOCK_STREAM: c_int = 1;
    pub const WSADATA = extern struct { _opaque: [512]u8 };
    pub const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16,
        addr: u32,
        zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    pub extern "ws2_32" fn WSAStartup(v: u16, d: *WSADATA) callconv(.winapi) c_int;
    pub extern "ws2_32" fn socket(af: c_int, t: c_int, p: c_int) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    pub fn sockOf(fd: fd_t) SOCKET {
        return @intFromPtr(fd);
    }
    pub fn fdOf(s: SOCKET) fd_t {
        return @ptrFromInt(s);
    }
} else struct {};

pub const TcpStream = struct {
    fd: fd_t,

    pub fn close(self: TcpStream) void {
        if (comptime is_windows) {
            _ = wsock.closesocket(wsock.sockOf(self.fd));
            return;
        }
        _ = c.close(self.fd);
    }

    pub fn writeAll(self: TcpStream, data: []const u8) !void {
        if (comptime is_windows) {
            const s = wsock.sockOf(self.fd);
            var sent: usize = 0;
            while (sent < data.len) {
                const n = wsock.send(s, data.ptr + sent, @intCast(data.len - sent), 0);
                if (n <= 0) return error.BrokenPipe;
                sent += @intCast(n);
            }
            return;
        }
        var sent: usize = 0;
        while (sent < data.len) {
            const n = c.write(self.fd, data[sent..].ptr, data.len - sent);
            if (n <= 0) return error.BrokenPipe;
            sent += @intCast(n);
        }
    }

    pub fn read(self: TcpStream, buf: []u8) !usize {
        if (comptime is_windows) {
            const n = wsock.recv(wsock.sockOf(self.fd), buf.ptr, @intCast(buf.len), 0);
            if (n < 0) return error.ConnectionResetByPeer;
            return @intCast(n);
        }
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.ConnectionResetByPeer;
        return @intCast(n);
    }

    pub fn write(self: TcpStream, data: []const u8) !usize {
        if (comptime is_windows) {
            const n = wsock.send(wsock.sockOf(self.fd), data.ptr, @intCast(data.len), 0);
            if (n <= 0) return error.BrokenPipe;
            return @intCast(n);
        }
        const n = c.write(self.fd, data.ptr, data.len);
        if (n <= 0) return error.BrokenPipe;
        return @intCast(n);
    }

    pub fn setSockOpt(self: TcpStream, level: i32, optname: u32, optval: []const u8) void {
        if (comptime is_windows) return; // optional tuning; safe to skip on Windows
        _ = c.setsockopt(self.fd, level, optname, optval.ptr, @intCast(optval.len));
    }
};

/// Connect to 127.0.0.1:port via TCP. Returns a TcpStream.
pub fn tcpConnectToIp4(port: u16) !TcpStream {
    if (comptime is_windows) {
        var wsadata: wsock.WSADATA = undefined;
        if (wsock.WSAStartup(0x0202, &wsadata) != 0) return error.SocketCreateFailed;
        const s = wsock.socket(wsock.AF_INET, wsock.SOCK_STREAM, 0);
        if (s == wsock.INVALID_SOCKET) return error.SocketCreateFailed;
        var addr = wsock.sockaddr_in{
            .port = htons(port),
            .addr = 0x0100007F, // 127.0.0.1
        };
        if (wsock.connect(s, @ptrCast(&addr), @sizeOf(wsock.sockaddr_in)) != 0) {
            _ = wsock.closesocket(s);
            return error.ConnectionRefused;
        }
        return .{ .fd = wsock.fdOf(s) };
    }
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
        if (comptime is_windows) return error.NotImplementedOnWindows;
        const client_fd = c.accept(self.fd, null, null);
        if (client_fd < 0) return error.AcceptFailed;
        return .{ .stream = .{ .fd = client_fd } };
    }

    pub fn deinit(self: *TcpServer) void {
        if (comptime is_windows) return;
        _ = c.close(self.fd);
    }
};

/// Bind and listen on 127.0.0.1:port.
pub fn tcpListen(port: u16) !TcpServer {
    if (comptime is_windows) return error.NotImplementedOnWindows;
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
