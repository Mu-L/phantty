//! Bounded, cancellable ICMP probe through the operating system's ping tool.
const std = @import("std");
const builtin = @import("builtin");
const process_runner = @import("../process_runner.zig");

pub const Sample = struct { milliseconds: f32, less_than: bool = false };
pub const Result = union(enum) { value: Sample, no_reply, unavailable, cancelled };
pub const TIMEOUT_MS: u64 = 2000;

pub fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 255 or host[0] == '-') return false;
    for (host) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, ".-_:%", ch) == null) return false;
    }
    return true;
}

/// Windows uses `time=12ms` / `时间<1ms`; POSIX uses `time=0.123 ms`.
/// Read a reply's numeric measurement, never the elapsed subprocess duration
/// (which includes startup/DNS) or a summary's min/avg/max values.
pub fn parseReply(output: []const u8) ?Sample {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, output, offset, "ms")) |end| {
        offset = end + 2;
        var number_end = end;
        while (number_end > 0 and output[number_end - 1] == ' ') number_end -= 1;
        var start = number_end;
        while (start > 0 and (std.ascii.isDigit(output[start - 1]) or output[start - 1] == '.')) start -= 1;
        if (start == number_end or start == 0) continue;
        var operator = start;
        while (operator > 0 and output[operator - 1] == ' ') operator -= 1;
        if (operator == 0 or (output[operator - 1] != '=' and output[operator - 1] != '<')) continue;
        const line_start = if (std.mem.lastIndexOfScalar(u8, output[0..start], '\n')) |newline| newline + 1 else 0;
        if (std.mem.indexOfScalar(u8, output[line_start..operator], ':') == null) continue;
        const ms = std.fmt.parseFloat(f32, output[start..number_end]) catch continue;
        if (!std.math.isFinite(ms) or ms < 0 or ms > TIMEOUT_MS) continue;
        return .{ .milliseconds = ms, .less_than = output[operator - 1] == '<' };
    }
    return null;
}

pub fn probe(allocator: std.mem.Allocator, host: []const u8, cancel: *const process_runner.CancelToken) Result {
    if (!validHost(host)) return .unavailable;
    if (cancel.isCancelled()) return .cancelled;
    var env = std.process.getEnvMap(allocator) catch return .unavailable;
    defer env.deinit();
    env.put("LC_ALL", "C") catch return .unavailable;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "ping.exe", "-n", "1", host },
        .macos => &.{ if (std.mem.indexOfScalar(u8, host, ':') != null) "/sbin/ping6" else "/sbin/ping", "-n", "-c", "1", host },
        .linux => &.{ "ping", "-n", "-c", "1", host },
        else => return .unavailable,
    };
    var result = process_runner.runCapture(allocator, argv, .{
        .timeout_ms = TIMEOUT_MS,
        .cancel = cancel,
        .max_stdout_bytes = 4096,
        .max_stderr_bytes = 1024,
        .env_map = &env,
    }) catch return .unavailable;
    defer result.deinit(allocator);
    if (result.cancelled) return .cancelled;
    if (result.timed_out) return .no_reply;
    switch (result.termination) {
        .exited => |code| if (code != 0) return .no_reply,
        .killed => return .no_reply,
    }
    return if (parseReply(result.stdout)) |sample| .{ .value = sample } else .no_reply;
}

test "ping parses Windows English/Chinese and POSIX replies without inventing zero" {
    try std.testing.expectEqual(Sample{ .milliseconds = 12 }, parseReply("Reply: bytes=32 time=12ms TTL=64").?);
    try std.testing.expectEqual(Sample{ .milliseconds = 1, .less_than = true }, parseReply("来自 127.0.0.1 的回复: 字节=32 时间<1ms TTL=128").?);
    try std.testing.expectEqual(Sample{ .milliseconds = 0.125 }, parseReply("64 bytes: icmp_seq=1 ttl=64 time=0.125 ms").?);
    try std.testing.expectEqual(@as(?Sample, null), parseReply("Request timed out. 100% packet loss"));
    try std.testing.expectEqual(@as(?Sample, null), parseReply("rtt min/avg/max/mdev = 1/2/3/4 ms"));
    try std.testing.expectEqual(@as(?Sample, null), parseReply("Minimum = 0ms, Maximum = 0ms, Average = 0ms"));
}

test "ping rejects option injection and malformed measurements" {
    for ([_][]const u8{ "", "-t", "host name", "host;cmd", "host\ncmd", "host/other" }) |host| try std.testing.expect(!validHost(host));
    for ([_][]const u8{ "example.org", "127.0.0.1", "::1", "fe80::1%en0" }) |host| try std.testing.expect(validHost(host));
    try std.testing.expectEqual(@as(?Sample, null), parseReply("Reply: time=-1ms"));
    try std.testing.expectEqual(@as(?Sample, null), parseReply("Reply: time=999999ms"));
    try std.testing.expectEqual(@as(?Sample, null), parseReply("Reply: time=1.2.3ms"));
    try std.testing.expectEqual(Sample{ .milliseconds = 0.25 }, parseReply("64 bytes from ::1: icmp_seq=0 time=0.250 ms\nrtt min/avg/max/mdev = 0.250/0.250/0.250/0.000 ms").?);
}
