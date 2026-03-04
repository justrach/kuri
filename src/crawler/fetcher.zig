const std = @import("std");
const validator = @import("validator.zig");

pub const FetchError = error{
    ValidationFailed,
    RateLimited,
    FetchFailed,
    ContentTooLarge,
};

pub const FetchOpts = struct {
    max_retries: u8 = 3,
    max_content_length: usize = 20 * 1024 * 1024, // 20MB
    timeout_ms: u32 = 30_000,
};

pub const FetchResult = struct {
    html: []const u8,
    status_code: u16,
    content_type: []const u8,
};

/// Token bucket rate limiter using atomics (lock-free).
pub const RateLimiter = struct {
    tokens: std.atomic.Value(u32),
    max_tokens: u32,
    last_refill: std.atomic.Value(i64),
    refill_interval_ns: i64,

    pub fn init(max_tokens: u32, refill_interval_ms: u32) RateLimiter {
        return .{
            .tokens = std.atomic.Value(u32).init(max_tokens),
            .max_tokens = max_tokens,
            .last_refill = std.atomic.Value(i64).init(@intCast(std.time.nanoTimestamp())),
            .refill_interval_ns = @as(i64, refill_interval_ms) * std.time.ns_per_ms,
        };
    }

    pub fn tryAcquire(self: *RateLimiter) bool {
        // Try to refill first
        self.maybeRefill();

        // Try to take a token
        while (true) {
            const current = self.tokens.load(.acquire);
            if (current == 0) return false;
            if (self.tokens.cmpxchgWeak(current, current - 1, .release, .monotonic) == null) {
                return true;
            }
        }
    }

    fn maybeRefill(self: *RateLimiter) void {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const last = self.last_refill.load(.acquire);
        if (now - last >= self.refill_interval_ns) {
            if (self.last_refill.cmpxchgWeak(last, now, .release, .monotonic) == null) {
                self.tokens.store(self.max_tokens, .release);
            }
        }
    }
};

test "RateLimiter acquires and exhausts tokens" {
    var limiter = RateLimiter.init(3, 1000);

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire()); // exhausted
}
