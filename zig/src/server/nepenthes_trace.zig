//! Host-only NEPENTHES JSONL connector. Disabled mode is a branch-only no-op.
const std = @import("std");
const platform = @import("sys");
const request_log = @import("request_log.zig");
const Allocator = std.mem.Allocator;
const c = platform.c;

const queue_capacity = 256;
const record_capacity = 1024;

const Record = struct {
    bytes: [record_capacity]u8 = undefined,
    len: usize = 0,
};

const Queue = struct {
    slots: [queue_capacity]Record = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    /// Called with the sink mutex held. A full queue rejects immediately.
    fn push(q: *Queue, record: Record) bool {
        if (q.count == queue_capacity) return false;
        q.slots[q.tail] = record;
        q.tail = (q.tail + 1) % queue_capacity;
        q.count += 1;
        return true;
    }

    /// Called with the sink mutex held.
    fn pop(q: *Queue) ?Record {
        if (q.count == 0) return null;
        const record = q.slots[q.head];
        q.head = (q.head + 1) % queue_capacity;
        q.count -= 1;
        return record;
    }
};

pub const Request = struct {
    id: u64 = 0,
    started_ns: u64 = 0,
};

pub const Sink = struct {
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    fd: c.fd_t = -1,
    run_id: []const u8 = "",
    enabled: bool = false,
    closing: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: Queue = .{},
    thread: ?std.Thread = null,
    next_request_id: std.atomic.Value(u64) = .init(1),
    next_event_id: std.atomic.Value(u64) = .init(1),
    events_drained: std.atomic.Value(u64) = .init(0),
    dropped_events: std.atomic.Value(u64) = .init(0),
    write_errors: std.atomic.Value(u64) = .init(0),

    pub fn open(gpa: Allocator, io: std.Io, path: ?[]const u8, run_id: ?[]const u8) !Sink {
        if (path == null and run_id == null) return .{ .gpa = gpa, .io = io };
        if (path == null or run_id == null) return error.IncompleteTraceConfiguration;
        if (path.?.len == 0 or !validRunId(run_id.?)) return error.InvalidTraceConfiguration;

        const path_z = try gpa.dupeSentinel(u8, path.?, 0);
        defer gpa.free(path_z);
        const fd = c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.TraceOpenFailed;
        errdefer _ = c.close(fd);
        if (!request_log.private(fd)) return error.TraceFileNotPrivate;

        return .{
            .gpa = gpa,
            .io = io,
            .fd = fd,
            .run_id = try gpa.dupe(u8, run_id.?),
            .enabled = true,
        };
    }

    /// Start only after the Sink has reached its stable address inside Server.
    pub fn start(s: *Sink) !void {
        if (!s.enabled or s.thread != null) return;
        s.thread = std.Thread.spawn(.{}, writerMain, .{s}) catch return error.TraceWriterStartFailed;
    }

    pub fn beginRequest(s: *Sink) Request {
        if (!s.enabled) return .{};
        const id = s.next_request_id.fetchAdd(1, .monotonic);
        const started = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        s.emit("request_start", id, 0, 0, 0, started);
        return .{ .id = id, .started_ns = started };
    }

    pub fn endRequest(s: *Sink, request: Request, status: u16, broken: bool) void {
        if (!s.enabled or request.id == 0) return;
        const ended = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        const duration = ended -| request.started_ns;
        if (broken) {
            s.emit("request_cancel", request.id, status, 1, duration, ended);
        } else if (status >= 400) {
            s.emit("request_error", request.id, status, 0, duration, ended);
        }
        s.emit("request_end", request.id, status, @intFromBool(broken), duration, ended);
    }

    /// Marks the HTTP dispatch boundary without claiming detached work has completed.
    pub fn dispatchEnd(s: *Sink, request: Request, status: u16, broken: bool) void {
        if (!s.enabled or request.id == 0) return;
        const ended = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        s.emit("dispatch_end", request.id, status, @intFromBool(broken), ended -| request.started_ns, ended);
    }

    /// Completes a logical request only when its explicitly owned background work actually ends.
    pub fn endBackgroundRequest(s: *Sink, request: Request, cancelled: bool, failed: bool) void {
        if (!s.enabled or request.id == 0) return;
        const ended = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        const duration = ended -| request.started_ns;
        if (cancelled) {
            s.emit("request_cancel", request.id, 0, 1, duration, ended);
        } else if (failed) {
            s.emit("request_error", request.id, 0, 1, duration, ended);
        }
        s.emit("request_end", request.id, 0, @intFromBool(cancelled or failed), duration, ended);
    }

    /// A detached job inherits only the request ID explicitly copied from its owning HTTP request.
    pub fn backgroundStart(s: *Sink, request_id: u64) u64 {
        if (!s.enabled or request_id == 0) return 0;
        const started = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        s.emit("background_start", request_id, 0, 0, 0, started);
        return started;
    }

    pub fn backgroundEnd(s: *Sink, request_id: u64, started_ns: u64, cancelled: bool, failed: bool) void {
        if (!s.enabled or request_id == 0 or started_ns == 0) return;
        const ended = @as(u64, @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds()));
        s.emit("background_end", request_id, @intFromBool(cancelled), @intFromBool(failed), ended -| started_ns, ended);
    }

    fn emit(s: *Sink, kind: []const u8, request_id: u64, value0: u64, value1: u64, duration_ns: u64, monotonic_ns: u64) void {
        if (!s.enabled) return;
        const event_id = s.next_event_id.fetchAdd(1, .monotonic);
        const unix_ns = @as(u64, @intCast(std.Io.Clock.real.now(s.io).toNanoseconds()));
        const label = if (std.mem.startsWith(u8, kind, "background_")) "responses.background" else "http.request";
        var record: Record = .{};
        const line = std.fmt.bufPrint(&record.bytes,
            "{{\"schema_version\":\"1.0\",\"run_id\":\"{s}\",\"event_id\":\"tf-{d}\",\"source\":\"tensorfold\",\"timestamp_unix_ns\":{d},\"monotonic_ns\":{d},\"request_id\":{d},\"event_kind\":\"{s}\",\"label\":\"{s}\",\"value0\":{d},\"value1\":{d},\"duration_ns\":{d},\"flags\":0,\"clock_domain\":\"steady_clock\"}}\n",
            .{ s.run_id, event_id, unix_ns, monotonic_ns, request_id, kind, label, value0, value1, duration_ns },
        ) catch {
            _ = s.dropped_events.fetchAdd(1, .monotonic);
            return;
        };
        record.len = line.len;
        if (!s.mutex.tryLock()) {
            _ = s.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        if (s.closing or !s.queue.push(record)) {
            s.mutex.unlock(s.io);
            _ = s.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        s.mutex.unlock(s.io);
        s.condition.signal(s.io);
    }

    fn writerMain(s: *Sink) void {
        while (true) {
            s.mutex.lockUncancelable(s.io);
            while (s.queue.count == 0 and !s.closing) s.condition.waitUncancelable(s.io, &s.mutex);
            if (s.queue.count == 0 and s.closing) {
                s.mutex.unlock(s.io);
                break;
            }
            const record = s.queue.pop().?;
            s.mutex.unlock(s.io);
            if (writeAll(s.fd, record.bytes[0..record.len])) {
                _ = s.events_drained.fetchAdd(1, .monotonic);
            } else {
                _ = s.write_errors.fetchAdd(1, .monotonic);
            }
        }
        s.writeSummary();
    }

    fn writeSummary(s: *Sink) void {
        var bytes: [record_capacity]u8 = undefined;
        const event_id = s.next_event_id.fetchAdd(1, .monotonic);
        const unix_ns = @as(u64, @intCast(std.Io.Clock.real.now(s.io).toNanoseconds()));
        const line = std.fmt.bufPrint(&bytes,
            "{{\"schema_version\":\"1.0\",\"run_id\":\"{s}\",\"event_id\":\"tf-summary-{d}\",\"source\":\"tensorfold\",\"timestamp_unix_ns\":{d},\"event_kind\":\"sink_summary\",\"events_drained\":{d},\"dropped_events\":{d},\"write_errors\":{d}}}\n",
            .{ s.run_id, event_id, unix_ns, s.events_drained.load(.monotonic), s.dropped_events.load(.monotonic), s.write_errors.load(.monotonic) },
        ) catch return;
        if (!writeAll(s.fd, line)) _ = s.write_errors.fetchAdd(1, .monotonic);
    }

    pub fn close(s: *Sink) void {
        if (!s.enabled) return;
        s.mutex.lockUncancelable(s.io);
        s.closing = true;
        s.mutex.unlock(s.io);
        s.condition.broadcast(s.io);
        if (s.thread) |thread| thread.join();
        _ = c.close(s.fd);
        s.gpa.free(s.run_id);
        s.run_id = "";
        s.fd = -1;
        s.enabled = false;
        s.thread = null;
    }
};

fn validRunId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    return true;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written <= 0) return false;
        offset += @intCast(written);
    }
    return true;
}

test "NEPENTHES sink is disabled without path and run identity" {
    var sink = try Sink.open(std.testing.allocator, std.testing.io, null, null);
    defer sink.close();
    try std.testing.expect(!sink.enabled);
    try std.testing.expectEqual(@as(u64, 0), sink.beginRequest().id);
}

test "NEPENTHES sink requires a complete safe run identity" {
    try std.testing.expectError(error.IncompleteTraceConfiguration, Sink.open(std.testing.allocator, std.testing.io, "trace.jsonl", null));
    try std.testing.expectError(error.IncompleteTraceConfiguration, Sink.open(std.testing.allocator, std.testing.io, null, "run-1"));
    try std.testing.expectError(error.InvalidTraceConfiguration, Sink.open(std.testing.allocator, std.testing.io, "trace.jsonl", "../private"));
}

test "NEPENTHES refuses an existing trace path instead of mixing runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);
    const fd = c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    _ = c.close(fd);
    try std.testing.expectError(error.TraceOpenFailed, Sink.open(std.testing.allocator, std.testing.io, path, "run-host-2"));
}

test "NEPENTHES queue is bounded and rejects overflow" {
    var q: Queue = .{};
    var record: Record = .{};
    for (0..queue_capacity) |_| try std.testing.expect(q.push(record));
    try std.testing.expect(!q.push(record));
    try std.testing.expectEqual(queue_capacity, q.count);
    _ = q.pop();
    try std.testing.expect(q.push(record));
}

test "NEPENTHES writer reports failed file writes" {
    try std.testing.expect(!writeAll(-1, "record\n"));
}

test "NEPENTHES producer contention increments dropped accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var sink = try Sink.open(std.testing.allocator, std.testing.io, path, "run-drop-1");
    try sink.start();
    defer sink.close();
    sink.mutex.lockUncancelable(sink.io);
    sink.emit("request_start", 1, 0, 0, 0, 1);
    sink.mutex.unlock(sink.io);
    sink.close();
    try std.testing.expectEqual(@as(u64, 1), sink.dropped_events.load(.monotonic));
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"dropped_events\":1") != null);
}

test "NEPENTHES writer counts failed event and summary writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var sink = try Sink.open(std.testing.allocator, std.testing.io, path, "run-write-error-1");
    try sink.start();
    defer sink.close();
    const fd = sink.fd;
    sink.fd = -1;
    const request = sink.beginRequest();
    sink.endRequest(request, 200, false);
    sink.close();
    _ = c.close(fd);
    try std.testing.expect(sink.write_errors.load(.monotonic) >= 3);
}

fn concurrentRequests(sink: *Sink, count: usize) void {
    for (0..count) |_| {
        const request = sink.beginRequest();
        sink.endRequest(request, 200, false);
    }
}

test "NEPENTHES concurrent producers allocate distinct request identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var sink = try Sink.open(std.testing.allocator, std.testing.io, path, "run-concurrent-1");
    try sink.start();
    defer sink.close();
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, concurrentRequests, .{ &sink, 16 });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u64, 65), sink.next_request_id.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 129), sink.next_event_id.load(.monotonic));
    sink.close();
}

test "NEPENTHES sink writes request lifecycle and final summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var sink = try Sink.open(std.testing.allocator, std.testing.io, path, "run-host-1");
    try sink.start();
    defer sink.close();
    const request = sink.beginRequest();
    const second = sink.beginRequest();
    try std.testing.expect(request.id != 0 and second.id != 0 and request.id != second.id);
    sink.dispatchEnd(request, 200, false);
    const background_started = sink.backgroundStart(request.id);
    sink.backgroundEnd(request.id, background_started, false, false);
    sink.endBackgroundRequest(request, false, false);
    sink.endRequest(second, 500, false);
    const cancelled = sink.beginRequest();
    sink.dispatchEnd(cancelled, 200, false);
    const cancelled_started = sink.backgroundStart(cancelled.id);
    sink.backgroundEnd(cancelled.id, cancelled_started, true, false);
    sink.endBackgroundRequest(cancelled, true, false);
    sink.close();
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"request_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"request_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"request_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"request_cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"dispatch_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"background_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"background_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"dispatch_end\"") != null);
    const background_end = std.mem.indexOf(u8, content, "\"event_kind\":\"background_end\"").?;
    const request_end = std.mem.indexOf(u8, content, "\"event_kind\":\"request_end\"").?;
    try std.testing.expect(background_end < request_end);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"label\":\"responses.background\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"prompt\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"completion\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"Authorization\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_kind\":\"sink_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"events_drained\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"dropped_events\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"write_errors\":") != null);
    const last = std.mem.lastIndexOfScalar(u8, content, '\n').?;
    const before = std.mem.lastIndexOfScalar(u8, content[0..last], '\n') orelse 0;
    try std.testing.expect(std.mem.indexOf(u8, content[before..last], "\"event_kind\":\"sink_summary\"") != null);
}
