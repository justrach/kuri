const std = @import("std");

pub const KafkaConfig = struct {
    brokers: []const u8,
    topic: []const u8,
    compression: CompressionType,
    max_message_size: usize,
    buffer_memory: usize,
    session_id: ?[]const u8,
};

pub const CompressionType = enum {
    none,
    gzip,
    snappy,
    lz4,
    zstd,

    pub fn fromString(s: []const u8) CompressionType {
        const map = std.StaticStringMap(CompressionType).initComptime(.{
            .{ "none", .none },
            .{ "gzip", .gzip },
            .{ "snappy", .snappy },
            .{ "lz4", .lz4 },
            .{ "zstd", .zstd },
        });
        return map.get(s) orelse .none;
    }
};

pub fn loadConfig() KafkaConfig {
    return .{
        .brokers = std.posix.getenv("KAFKA_BROKERS") orelse "localhost:9092",
        .topic = std.posix.getenv("KAFKA_TOPIC") orelse "browdie_crawl",
        .compression = CompressionType.fromString(std.posix.getenv("KAFKA_COMPRESSION") orelse "gzip"),
        .max_message_size = 10 * 1024 * 1024, // 10MB
        .buffer_memory = 100 * 1024 * 1024, // 100MB
        .session_id = null,
    };
}

test "CompressionType fromString" {
    try std.testing.expectEqual(CompressionType.gzip, CompressionType.fromString("gzip"));
    try std.testing.expectEqual(CompressionType.zstd, CompressionType.fromString("zstd"));
    try std.testing.expectEqual(CompressionType.none, CompressionType.fromString("unknown"));
}
