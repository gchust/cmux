//! End-to-end integration tests for the Zig daemon's Phase 1 push protocol.
//!
//! Each test stands up a real `serve_unix`-shaped listener on a temp Unix
//! socket path, connects one or more real clients, and drives line-delimited
//! JSON-RPC over the socket. No production code is modified — the test
//! server composes `session_service.Service` + `outbound_queue.OutboundQueue`
//! + `server_core.dispatch` in the same shape as production's
//! `serve_unix.handleClient`.

const std = @import("std");

const cmuxd = @import("cmuxd_src");
const pty_pump = cmuxd.pty_pump;
const session_service = cmuxd.session_service;
const server_core = cmuxd.server_core;

const test_util = @import("test_util.zig");

const Fixture = struct {
    alloc: std.mem.Allocator,
    service: session_service.Service,
    server: *test_util.Server,
    socket_path: []u8,

    fn init(alloc: std.mem.Allocator, label: []const u8) !*Fixture {
        const self = try alloc.create(Fixture);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.socket_path = try test_util.uniqueSocketPath(alloc, label);
        errdefer alloc.free(self.socket_path);

        self.service = session_service.Service.init(alloc);
        errdefer self.service.deinit();
        self.service.on_workspace_changed = &server_core.notifyWorkspaceSubscribers;

        self.server = try test_util.Server.start(alloc, &self.service, self.socket_path);
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.service.deinit();
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);
    }
};

fn deadlineIn(ms: i64) i64 {
    return std.time.milliTimestamp() + ms;
}

// ---------------------------------------------------------------------------
// Test 1: single-socket interleave
// ---------------------------------------------------------------------------

test "integration: single-socket interleave (workspace.changed + write resp + terminal.output)" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "interleave");
    defer fx.deinit();

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    const hello_id = client.allocId();
    try client.sendRequest(hello_id, "hello", .{});
    {
        var resp = try client.awaitResponse(hello_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    // Real PTY session. `cat` echoes what we write, so terminal.output will
    // carry our own bytes back.
    var opened = try fx.service.openTerminal("s-interleave", "cat", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);

    const ws_id_owned = try fx.service.workspace_reg.create("integration-ws", null);
    _ = ws_id_owned;

    const sub_id = client.allocId();
    try client.sendRequest(sub_id, "workspace.subscribe", .{});
    {
        var resp = try client.awaitResponse(sub_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    const tsub_id = client.allocId();
    try client.sendRequest(tsub_id, "terminal.subscribe", .{
        .session_id = "s-interleave",
        .offset = @as(u64, 0),
    });
    {
        var resp = try client.awaitResponse(tsub_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    const write_bytes = "hello-from-client\n";
    const write_b64 = try test_util.base64Encode(alloc, write_bytes);
    defer alloc.free(write_b64);

    const write_id = client.allocId();
    try client.sendRequest(write_id, "terminal.write", .{
        .session_id = "s-interleave",
        .data = write_b64,
    });

    // Grab the workspace id freshly (create() returned it borrowed by us).
    const ws_id: []const u8 = blk: {
        const order = fx.service.workspace_reg.order.items;
        try std.testing.expect(order.len > 0);
        break :blk order[0];
    };
    const pin_id = client.allocId();
    try client.sendRequest(pin_id, "workspace.pin", .{
        .workspace_id = ws_id,
        .pinned = true,
    });

    var got_write_ok = false;
    var got_pin_ok = false;
    var got_terminal_output = false;
    var got_workspace_changed = false;

    const deadline = deadlineIn(4000);
    while (std.time.milliTimestamp() < deadline) {
        if (got_write_ok and got_pin_ok and got_terminal_output and got_workspace_changed) break;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        if (parsed.value.object.get("id")) |id_val| {
            if (test_util.idEquals(id_val, write_id)) got_write_ok = true;
            if (test_util.idEquals(id_val, pin_id)) got_pin_ok = true;
            continue;
        }
        if (parsed.value.object.get("event")) |ev| {
            if (ev != .string) continue;
            if (std.mem.eql(u8, ev.string, "terminal.output")) {
                got_terminal_output = true;
            } else if (std.mem.eql(u8, ev.string, "workspace.changed")) {
                got_workspace_changed = true;
            }
        }
    }

    try std.testing.expect(got_write_ok);
    try std.testing.expect(got_pin_ok);
    try std.testing.expect(got_terminal_output);
    try std.testing.expect(got_workspace_changed);

    try fx.service.closeSession("s-interleave");
}
