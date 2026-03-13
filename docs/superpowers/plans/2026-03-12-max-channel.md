# Max Messenger Channel Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full-featured Max messenger (platform-api.max.ru) channel support to NullClaw with polling + webhook modes, streaming, attachments, inline keyboards, typing indicators, and deep links.

**Architecture:** Single `MaxChannel` struct with internal mode switching (polling vs webhook). Three new files: `max_api.zig` (HTTP client), `max_ingress.zig` (update parsing), `max.zig` (channel struct + VTable). Eight existing files modified for registration. All HTTP through `http_util.curlPost/curlGet`. Streaming via message editing (`PUT /messages`).

**Tech Stack:** Zig 0.15.2, curl subprocesses for HTTP, `std.json` for parsing, `platform-api.max.ru` REST API.

**Spec:** `docs/superpowers/specs/2026-03-12-max-channel-design.md`

---

## Chunk 1: Build System + Config + Catalog Registration

### Task 1: Add `enable_channel_max` build flag

**Files:**
- Modify: `build.zig:69-89` (ChannelSelection), `build.zig:90-110` (enableAll), `build.zig:119-183` (parseChannelsOption), `build.zig:384-406` (local vars), `build.zig:442-464` (addOption), `build.zig:355` (help text)

- [ ] **Step 1: Add field to ChannelSelection struct**

In `build.zig`, after line 88 (`enable_channel_web: bool = false,`), add:

```zig
    enable_channel_max: bool = false,
```

- [ ] **Step 2: Add to enableAll()**

After line 109 (`self.enable_channel_web = true;`), add:

```zig
        self.enable_channel_max = true;
```

- [ ] **Step 3: Add parser token**

Before the `else` branch on line 181, add:

```zig
        } else if (std.mem.eql(u8, token, "max")) {
            selection.enable_channel_max = true;
```

- [ ] **Step 4: Add local variable extraction**

After line 405 (`const enable_channel_web = channels.enable_channel_web;`), add:

```zig
    const enable_channel_max = channels.enable_channel_max;
```

- [ ] **Step 5: Add build option**

After line 463 (`build_options.addOption(bool, "enable_channel_web", enable_channel_web);`), add:

```zig
    build_options.addOption(bool, "enable_channel_max", enable_channel_max);
```

- [ ] **Step 6: Update help text**

On line 355, append `|max` to the channels help string before the closing `(default: all)"`.

- [ ] **Step 7: Verify build compiles**

Run: `zig build -Dchannels=none 2>&1 | head -5`
Expected: clean build (no errors)

Run: `zig build -Dchannels=max 2>&1 | head -5`
Expected: may error since max.zig doesn't exist yet, but the flag is recognized (no "unknown channel" error)

- [ ] **Step 8: Commit**

```bash
git add build.zig
git commit -m "build: add enable_channel_max build flag"
```

---

### Task 2: Add MaxConfig to config_types.zig

**Files:**
- Modify: `src/config_types.zig:254-304` (near TelegramConfig), `src/config_types.zig:706-726` (ChannelsConfig), `src/config_types.zig:791-793` (after webPrimary)

- [ ] **Step 1: Add MaxListenerMode enum**

After the `TelegramCommandsMenuMode` enum (line 274), add:

```zig
pub const MaxListenerMode = enum {
    polling,
    webhook,
};
```

- [ ] **Step 2: Add MaxInteractiveConfig**

After `MaxListenerMode`:

```zig
pub const MaxInteractiveConfig = struct {
    enabled: bool = false,
    ttl_secs: u64 = 900,
    owner_only: bool = true,
};
```

- [ ] **Step 3: Add MaxConfig**

After `MaxInteractiveConfig`:

```zig
pub const MaxConfig = struct {
    account_id: []const u8 = "default",
    bot_token: []const u8,
    allow_from: []const []const u8 = &.{},
    group_allow_from: []const []const u8 = &.{},
    group_policy: []const u8 = "allowlist",
    proxy: ?[]const u8 = null,
    mode: MaxListenerMode = .polling,
    webhook_url: ?[]const u8 = null,
    webhook_secret: ?[]const u8 = null,
    interactive: MaxInteractiveConfig = .{},
    require_mention: bool = false,
    streaming: bool = true,
};
```

- [ ] **Step 4: Add `max` field to ChannelsConfig**

In `ChannelsConfig` (line 706), after `web: []const WebConfig = &.{},` (line 725), add:

```zig
    max: []const MaxConfig = &.{},
```

- [ ] **Step 5: Add maxPrimary() helper**

After `webPrimary()` (line 793), add:

```zig
    pub fn maxPrimary(self: *const ChannelsConfig) ?MaxConfig {
        return primaryAccount(MaxConfig, self.max);
    }
```

- [ ] **Step 6: Verify build**

Run: `zig build -Dchannels=none 2>&1 | head -5`
Expected: clean build

- [ ] **Step 7: Commit**

```bash
git add src/config_types.zig
git commit -m "config: add MaxConfig, MaxInteractiveConfig, MaxListenerMode"
```

---

### Task 3: Register Max in channel catalog

**Files:**
- Modify: `src/channel_catalog.zig:5-26` (ChannelId), `src/channel_catalog.zig:44-65` (known_channels), `src/channel_catalog.zig:67-90` (isBuildEnabled), `src/channel_catalog.zig:92-114` (isBuildEnabledByKey), `src/channel_catalog.zig:116-139` (configuredCount)

- [ ] **Step 1: Add `.max` to ChannelId enum**

After `.web,` (line 25), add:

```zig
    max,
```

- [ ] **Step 2: Add entry to known_channels**

After the `.web` entry (line 64), add:

```zig
    .{ .id = .max, .key = "max", .label = "Max", .configured_message = "Max configured", .listener_mode = .polling },
```

Note: `listener_mode = .polling` for default mode. Webhook mode is handled at runtime level, not catalog level.

- [ ] **Step 3: Add to isBuildEnabled switch**

After `.web => build_options.enable_channel_web,` (line 88), add:

```zig
        .max => build_options.enable_channel_max,
```

- [ ] **Step 4: Add to isBuildEnabledByKey**

After the `.web` line (line 112), add:

```zig
    if (comptime std.mem.eql(u8, key, "max")) return build_options.enable_channel_max;
```

- [ ] **Step 5: Add to configuredCount switch**

After `.web => cfg.channels.web.len,` (line 137), add:

```zig
        .max => cfg.channels.max.len,
```

- [ ] **Step 6: Verify build**

Run: `zig build -Dchannels=none 2>&1 | head -5`
Expected: clean build

- [ ] **Step 7: Commit**

```bash
git add src/channel_catalog.zig
git commit -m "catalog: register Max channel in ChannelId and known_channels"
```

---

## Chunk 2: max_api.zig — HTTP Client

### Task 4: Create max_api.zig with core API methods

**Files:**
- Create: `src/channels/max_api.zig`

- [ ] **Step 1: Write tests for URL building and response parsing**

Create `src/channels/max_api.zig` with test-first approach:

```zig
const std = @import("std");
const root = @import("root.zig");

const log = std.log.scoped(.max_api);

pub const BASE_URL = "https://platform-api.max.ru";
pub const MAX_MESSAGE_LEN: usize = 4000;

pub const BotInfo = struct {
    user_id: ?[]u8 = null,
    name: ?[]u8 = null,
    username: ?[]u8 = null,

    pub fn deinit(self: *const BotInfo, allocator: std.mem.Allocator) void {
        if (self.user_id) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.username) |v| allocator.free(v);
    }
};

pub const SentMessageMeta = struct {
    mid: ?[]u8 = null,

    pub fn deinit(self: *const SentMessageMeta, allocator: std.mem.Allocator) void {
        if (self.mid) |v| allocator.free(v);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    proxy: ?[]const u8,

    /// Build a full API URL: BASE_URL ++ path ++ query string.
    pub fn buildUrl(buf: []u8, path: []const u8, query: ?[]const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(BASE_URL);
        try w.writeAll(path);
        if (query) |q| {
            try w.writeByte('?');
            try w.writeAll(q);
        }
        return fbs.getWritten();
    }

    /// Build Authorization header value.
    pub fn authHeader(self: Client, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        try fbs.writer().writeAll(self.bot_token);
        return fbs.getWritten();
    }

    // ── GET /me ─────────────────────────────────────────────────────

    pub fn getMe(self: Client, allocator: std.mem.Allocator) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"user_id\":\"123\",\"name\":\"TestBot\",\"username\":\"testbot\"}");

        var url_buf: [512]u8 = undefined;
        const url = try buildUrl(&url_buf, "/me", null);
        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlGetWithHeaders(allocator, url, &.{
            .{ "Authorization", auth },
        }, self.proxy);
    }

    pub fn getMeOk(self: Client) bool {
        const resp = self.getMe(self.allocator) catch return false;
        defer self.allocator.free(resp);
        return std.mem.indexOf(u8, resp, "\"user_id\"") != null;
    }

    pub fn fetchBotInfo(self: Client, allocator: std.mem.Allocator) ?BotInfo {
        const resp = self.getMe(allocator) catch return null;
        defer allocator.free(resp);
        return parseBotInfo(allocator, resp);
    }

    pub fn parseBotInfo(allocator: std.mem.Allocator, json_resp: []const u8) ?BotInfo {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        var info = BotInfo{};
        if (obj.get("user_id")) |v| {
            if (v == .string) info.user_id = allocator.dupe(u8, v.string) catch return null;
            if (v == .integer) info.user_id = std.fmt.allocPrint(allocator, "{d}", .{v.integer}) catch return null;
        }
        if (obj.get("name")) |v| {
            if (v == .string) info.name = allocator.dupe(u8, v.string) catch return null;
        }
        if (obj.get("username")) |v| {
            if (v == .string) info.username = allocator.dupe(u8, v.string) catch return null;
        }
        return info;
    }

    // ── POST /messages ──────────────────────────────────────────────

    /// Send a text message to a chat. Returns the raw JSON response.
    pub fn sendMessage(self: Client, allocator: std.mem.Allocator, chat_id: []const u8, body_json: []const u8) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"message\":{\"body\":{\"mid\":\"test-mid-1\"}}}");

        var url_buf: [512]u8 = undefined;
        var query_buf: [256]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("chat_id={s}", .{chat_id});
        const url = try buildUrl(&url_buf, "/messages", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlPostWithHeaders(allocator, url, body_json, &.{
            .{ "Authorization", auth },
            .{ "Content-Type", "application/json" },
        }, self.proxy);
    }

    /// Parse the mid from a sendMessage response.
    pub fn parseSentMessageMid(allocator: std.mem.Allocator, json_resp: []const u8) ?SentMessageMeta {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const message = parsed.value.object.get("message") orelse return null;
        if (message != .object) return null;
        const body = message.object.get("body") orelse return null;
        if (body != .object) return null;
        const mid = body.object.get("mid") orelse return null;
        if (mid != .string) return null;

        return .{
            .mid = allocator.dupe(u8, mid.string) catch return null,
        };
    }

    // ── PUT /messages ───────────────────────────────────────────────

    /// Edit an existing message.
    pub fn editMessage(self: Client, allocator: std.mem.Allocator, message_id: []const u8, body_json: []const u8) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"success\":true}");

        var url_buf: [512]u8 = undefined;
        var query_buf: [256]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("message_id={s}", .{message_id});
        const url = try buildUrl(&url_buf, "/messages", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlPutWithHeaders(allocator, url, body_json, &.{
            .{ "Authorization", auth },
            .{ "Content-Type", "application/json" },
        }, self.proxy);
    }

    // ── DELETE /messages ────────────────────────────────────────────

    pub fn deleteMessage(self: Client, allocator: std.mem.Allocator, message_id: []const u8) !void {
        const builtin = @import("builtin");
        if (builtin.is_test) return;

        var url_buf: [512]u8 = undefined;
        var query_buf: [256]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("message_id={s}", .{message_id});
        const url = try buildUrl(&url_buf, "/messages", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        const resp = try root.http_util.curlDeleteWithHeaders(allocator, url, &.{
            .{ "Authorization", auth },
        }, self.proxy);
        allocator.free(resp);
    }

    // ── POST /answers ───────────────────────────────────────────────

    pub fn answerCallback(self: Client, allocator: std.mem.Allocator, callback_id: []const u8, notification: ?[]const u8) !void {
        const builtin = @import("builtin");
        if (builtin.is_test) return;

        var url_buf: [512]u8 = undefined;
        var query_buf: [256]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("callback_id={s}", .{callback_id});
        const url = try buildUrl(&url_buf, "/answers", qfbs.getWritten());

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        if (notification) |text| {
            try body.appendSlice(allocator, "{\"notification\":");
            try root.appendJsonStringW(body.writer(allocator), text);
            try body.appendSlice(allocator, "}");
        } else {
            try body.appendSlice(allocator, "{}");
        }

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        const resp = try root.http_util.curlPostWithHeaders(allocator, url, body.items, &.{
            .{ "Authorization", auth },
            .{ "Content-Type", "application/json" },
        }, self.proxy);
        allocator.free(resp);
    }

    // ── GET /updates ────────────────────────────────────────────────

    pub fn getUpdates(self: Client, allocator: std.mem.Allocator, marker: ?[]const u8, timeout: u32) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"updates\":[],\"marker\":\"test-marker\"}");

        var url_buf: [1024]u8 = undefined;
        var query_buf: [512]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        const qw = qfbs.writer();
        try qw.print("timeout={d}&types=message_created,message_callback,bot_started,bot_stopped", .{timeout});
        if (marker) |m| {
            try qw.print("&marker={s}", .{m});
        }
        const url = try buildUrl(&url_buf, "/updates", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlGetWithHeaders(allocator, url, &.{
            .{ "Authorization", auth },
        }, self.proxy);
    }

    // ── POST /subscriptions (webhook setup) ─────────────────────────

    pub fn subscribe(self: Client, allocator: std.mem.Allocator, webhook_url: []const u8, secret: ?[]const u8) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"success\":true}");

        var url_buf: [512]u8 = undefined;
        const url = try buildUrl(&url_buf, "/subscriptions", null);

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"url\":");
        try root.appendJsonStringW(body.writer(allocator), webhook_url);
        try body.appendSlice(allocator, ",\"update_types\":[\"message_created\",\"message_callback\",\"bot_started\",\"bot_stopped\"]");
        if (secret) |s| {
            try body.appendSlice(allocator, ",\"secret\":");
            try root.appendJsonStringW(body.writer(allocator), s);
        }
        try body.appendSlice(allocator, "}");

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlPostWithHeaders(allocator, url, body.items, &.{
            .{ "Authorization", auth },
            .{ "Content-Type", "application/json" },
        }, self.proxy);
    }

    // ── DELETE /subscriptions ────────────────────────────────────────

    pub fn unsubscribe(self: Client, allocator: std.mem.Allocator, webhook_url: []const u8) !void {
        const builtin = @import("builtin");
        if (builtin.is_test) return;

        var url_buf: [1024]u8 = undefined;
        var query_buf: [512]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("url={s}", .{webhook_url});
        const url = try buildUrl(&url_buf, "/subscriptions", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        const resp = try root.http_util.curlDeleteWithHeaders(allocator, url, &.{
            .{ "Authorization", auth },
        }, self.proxy);
        allocator.free(resp);
    }

    // ── POST /chats/{chatId}/actions ────────────────────────────────

    pub fn sendTypingAction(self: Client, allocator: std.mem.Allocator, chat_id: []const u8) !void {
        const builtin = @import("builtin");
        if (builtin.is_test) return;

        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        try fbs.writer().print("{s}/chats/{s}/actions", .{ BASE_URL, chat_id });
        const url = fbs.getWritten();

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        const resp = try root.http_util.curlPostWithHeaders(allocator, url, "{\"action\":\"typing_on\"}", &.{
            .{ "Authorization", auth },
            .{ "Content-Type", "application/json" },
        }, self.proxy);
        allocator.free(resp);
    }

    // ── POST /uploads ───────────────────────────────────────────────

    pub fn uploadFile(self: Client, allocator: std.mem.Allocator, file_type: []const u8, file_path: []const u8) ![]u8 {
        const builtin = @import("builtin");
        if (builtin.is_test) return allocator.dupe(u8, "{\"token\":\"test-upload-token\"}");

        var url_buf: [512]u8 = undefined;
        var query_buf: [256]u8 = undefined;
        var qfbs = std.io.fixedBufferStream(&query_buf);
        try qfbs.writer().print("type={s}", .{file_type});
        const url = try buildUrl(&url_buf, "/uploads", qfbs.getWritten());

        var hdr_buf: [256]u8 = undefined;
        const auth = try self.authHeader(&hdr_buf);
        return root.http_util.curlPostFormWithHeaders(allocator, url, file_path, &.{
            .{ "Authorization", auth },
        }, self.proxy);
    }

    /// Parse upload token from response.
    pub fn parseUploadToken(allocator: std.mem.Allocator, json_resp: []const u8) ?[]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const token = parsed.value.object.get("token") orelse return null;
        if (token != .string) return null;
        return allocator.dupe(u8, token.string) catch null;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// JSON body builders
// ════════════════════════════════════════════════════════════════════════════

/// Build a NewMessageBody JSON for a text message.
pub fn buildTextMessageBody(allocator: std.mem.Allocator, text: []const u8, format: ?[]const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"text\":");
    try root.appendJsonStringW(body.writer(allocator), text);
    if (format) |fmt| {
        try body.appendSlice(allocator, ",\"format\":");
        try root.appendJsonStringW(body.writer(allocator), fmt);
    }
    try body.appendSlice(allocator, "}");
    return body.toOwnedSlice(allocator);
}

/// Build a NewMessageBody JSON with inline keyboard attachment.
pub fn buildTextWithKeyboardBody(
    allocator: std.mem.Allocator,
    text: []const u8,
    keyboard_json: []const u8,
    format: ?[]const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"text\":");
    try root.appendJsonStringW(body.writer(allocator), text);
    if (format) |fmt| {
        try body.appendSlice(allocator, ",\"format\":");
        try root.appendJsonStringW(body.writer(allocator), fmt);
    }
    try body.appendSlice(allocator, ",\"attachments\":[{\"type\":\"inline_keyboard\",\"payload\":");
    try body.appendSlice(allocator, keyboard_json);
    try body.appendSlice(allocator, "}]}");
    return body.toOwnedSlice(allocator);
}

/// Build inline keyboard JSON from choices.
pub fn buildInlineKeyboardJson(allocator: std.mem.Allocator, choices: []const root.Channel.OutboundChoice) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    // One button per row: [[btn1],[btn2],...]
    try body.appendSlice(allocator, "{\"buttons\":[");
    for (choices, 0..) |choice, i| {
        if (i > 0) try body.appendSlice(allocator, ",");
        try body.appendSlice(allocator, "[{\"type\":\"callback\",\"text\":");
        try root.appendJsonStringW(body.writer(allocator), choice.label);
        try body.appendSlice(allocator, ",\"payload\":");
        try root.appendJsonStringW(body.writer(allocator), choice.id);
        try body.appendSlice(allocator, ",\"intent\":\"default\"}]");
    }
    try body.appendSlice(allocator, "]}");
    return body.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "buildUrl constructs correct API URL" {
    var buf: [256]u8 = undefined;
    const url = try Client.buildUrl(&buf, "/me", null);
    try std.testing.expectEqualStrings("https://platform-api.max.ru/me", url);
}

test "buildUrl with query params" {
    var buf: [256]u8 = undefined;
    const url = try Client.buildUrl(&buf, "/messages", "chat_id=123");
    try std.testing.expectEqualStrings("https://platform-api.max.ru/messages?chat_id=123", url);
}

test "parseBotInfo extracts fields" {
    const allocator = std.testing.allocator;
    const json = "{\"user_id\":\"456\",\"name\":\"MyBot\",\"username\":\"mybot\"}";
    const info = Client.parseBotInfo(allocator, json) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("456", info.user_id.?);
    try std.testing.expectEqualStrings("MyBot", info.name.?);
    try std.testing.expectEqualStrings("mybot", info.username.?);
}

test "parseBotInfo handles integer user_id" {
    const allocator = std.testing.allocator;
    const json = "{\"user_id\":789,\"name\":\"Bot\"}";
    const info = Client.parseBotInfo(allocator, json) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("789", info.user_id.?);
}

test "parseBotInfo returns null on invalid json" {
    const allocator = std.testing.allocator;
    try std.testing.expect(Client.parseBotInfo(allocator, "not json") == null);
}

test "parseSentMessageMid extracts mid" {
    const allocator = std.testing.allocator;
    const json = "{\"message\":{\"body\":{\"mid\":\"abc-123\"}}}";
    const meta = Client.parseSentMessageMid(allocator, json) orelse return error.TestUnexpectedResult;
    defer meta.deinit(allocator);
    try std.testing.expectEqualStrings("abc-123", meta.mid.?);
}

test "parseSentMessageMid returns null on missing mid" {
    const allocator = std.testing.allocator;
    try std.testing.expect(Client.parseSentMessageMid(allocator, "{\"message\":{}}") == null);
}

test "parseUploadToken extracts token" {
    const allocator = std.testing.allocator;
    const json = "{\"token\":\"upload-tok-42\"}";
    const token = Client.parseUploadToken(allocator, json) orelse return error.TestUnexpectedResult;
    defer allocator.free(token);
    try std.testing.expectEqualStrings("upload-tok-42", token);
}

test "buildTextMessageBody produces valid JSON" {
    const allocator = std.testing.allocator;
    const body = try buildTextMessageBody(allocator, "Hello", "markdown");
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"format\":\"markdown\"") != null);
}

test "buildTextMessageBody without format" {
    const allocator = std.testing.allocator;
    const body = try buildTextMessageBody(allocator, "Hi", null);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"format\"") == null);
}

test "buildInlineKeyboardJson produces callback buttons" {
    const allocator = std.testing.allocator;
    const choices = [_]root.Channel.OutboundChoice{
        .{ .id = "opt1", .label = "Option 1", .submit_text = "chose 1" },
        .{ .id = "opt2", .label = "Option 2", .submit_text = "chose 2" },
    };
    const json = try buildInlineKeyboardJson(allocator, &choices);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"callback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload\":\"opt1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Option 2\"") != null);
}

test "getMe returns mock in test" {
    const allocator = std.testing.allocator;
    const client = Client{ .allocator = allocator, .bot_token = "test-token", .proxy = null };
    const resp = try client.getMe(allocator);
    defer allocator.free(resp);
    try std.testing.expect(resp.len > 0);
}

test "sendMessage returns mock in test" {
    const allocator = std.testing.allocator;
    const client = Client{ .allocator = allocator, .bot_token = "test-token", .proxy = null };
    const resp = try client.sendMessage(allocator, "chat-1", "{\"text\":\"hi\"}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "test-mid-1") != null);
}
```

- [ ] **Step 2: Run tests**

Run: `zig test src/channels/max_api.zig 2>&1 | tail -5`
Expected: All tests pass

Note: This will likely fail because `root.http_util.curlGetWithHeaders`, `curlPostWithHeaders`, `curlPutWithHeaders`, `curlDeleteWithHeaders`, `curlPostFormWithHeaders` may not exist with that exact signature. Check `src/http_util.zig` for the actual function names and adjust accordingly. The `builtin.is_test` guards ensure no real HTTP calls are made in tests, so the actual HTTP functions only need to compile, not run.

- [ ] **Step 3: Adjust HTTP utility calls to match actual http_util API**

Read `src/http_util.zig` and adjust all `curlGetWithHeaders`, `curlPostWithHeaders`, etc. calls to use the actual function signatures. The existing channels use patterns like:
- `root.http_util.curlPost(allocator, url, body, timeout)`
- `root.http_util.curlPostWithProxy(allocator, url, body, timeout, proxy)`
- `root.http_util.curlGet(allocator, url, timeout)`

The Authorization header needs to be passed via curl `-H` flag. Check how Telegram passes headers (it doesn't — it uses URL-embedded token). For Max, we need to add header support. Check if `curlPostWithHeaders` already exists or if we need a different approach (e.g., building the curl command manually or adding a helper).

- [ ] **Step 4: Re-run tests and verify all pass**

Run: `zig test src/channels/max_api.zig 2>&1 | tail -5`
Expected: All tests pass with 0 leaks

- [ ] **Step 5: Commit**

```bash
git add src/channels/max_api.zig
git commit -m "feat(max): add max_api.zig HTTP client with tests"
```

---

## Chunk 3: max_ingress.zig — Update Parsing

### Task 5: Create max_ingress.zig with update parsing

**Files:**
- Create: `src/channels/max_ingress.zig`

- [ ] **Step 1: Write ingress parser with tests**

Create `src/channels/max_ingress.zig`:

```zig
const std = @import("std");
const root = @import("root.zig");

const log = std.log.scoped(.max_ingress);

// ════════════════════════════════════════════════════════════════════════════
// Update types
// ════════════════════════════════════════════════════════════════════════════

pub const UpdateType = enum {
    message_created,
    message_callback,
    message_edited,
    message_removed,
    bot_started,
    bot_stopped,
    bot_added,
    bot_removed,
    user_added,
    user_removed,
    chat_title_changed,
    unknown,

    pub fn fromString(s: []const u8) UpdateType {
        if (std.mem.eql(u8, s, "message_created")) return .message_created;
        if (std.mem.eql(u8, s, "message_callback")) return .message_callback;
        if (std.mem.eql(u8, s, "message_edited")) return .message_edited;
        if (std.mem.eql(u8, s, "message_removed")) return .message_removed;
        if (std.mem.eql(u8, s, "bot_started")) return .bot_started;
        if (std.mem.eql(u8, s, "bot_stopped")) return .bot_stopped;
        if (std.mem.eql(u8, s, "bot_added")) return .bot_added;
        if (std.mem.eql(u8, s, "bot_removed")) return .bot_removed;
        if (std.mem.eql(u8, s, "user_added")) return .user_added;
        if (std.mem.eql(u8, s, "user_removed")) return .user_removed;
        if (std.mem.eql(u8, s, "chat_title_changed")) return .chat_title_changed;
        return .unknown;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Parsed update structures
// ════════════════════════════════════════════════════════════════════════════

pub const SenderInfo = struct {
    user_id: []u8,
    name: ?[]u8 = null,
    username: ?[]u8 = null,

    pub fn deinit(self: *const SenderInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        if (self.name) |n| allocator.free(n);
        if (self.username) |u| allocator.free(u);
    }

    /// Preferred display identity: username if available, else user_id.
    pub fn identity(self: *const SenderInfo) []const u8 {
        return self.username orelse self.user_id;
    }
};

pub const ChatInfo = struct {
    chat_id: []u8,
    chat_type: ChatType = .dialog,

    pub const ChatType = enum { dialog, chat, channel };

    pub fn deinit(self: *const ChatInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.chat_id);
    }

    pub fn isGroup(self: *const ChatInfo) bool {
        return self.chat_type != .dialog;
    }
};

pub const InboundMessage = struct {
    sender: SenderInfo,
    chat: ChatInfo,
    text: ?[]u8 = null,
    mid: ?[]u8 = null,
    timestamp: u64 = 0,
    attachment_urls: [][]u8 = &.{},
    attachment_types: [][]u8 = &.{},

    pub fn deinit(self: *const InboundMessage, allocator: std.mem.Allocator) void {
        self.sender.deinit(allocator);
        self.chat.deinit(allocator);
        if (self.text) |t| allocator.free(t);
        if (self.mid) |m| allocator.free(m);
        for (self.attachment_urls) |u| allocator.free(u);
        allocator.free(self.attachment_urls);
        for (self.attachment_types) |t| allocator.free(t);
        allocator.free(self.attachment_types);
    }
};

pub const InboundCallback = struct {
    callback_id: []u8,
    payload: []u8,
    sender: SenderInfo,
    chat_id: []u8,

    pub fn deinit(self: *const InboundCallback, allocator: std.mem.Allocator) void {
        allocator.free(self.callback_id);
        allocator.free(self.payload);
        self.sender.deinit(allocator);
        allocator.free(self.chat_id);
    }
};

pub const BotStartedInfo = struct {
    sender: SenderInfo,
    chat_id: []u8,
    payload: ?[]u8 = null,

    pub fn deinit(self: *const BotStartedInfo, allocator: std.mem.Allocator) void {
        self.sender.deinit(allocator);
        allocator.free(self.chat_id);
        if (self.payload) |p| allocator.free(p);
    }
};

pub const ParsedUpdate = union(enum) {
    message: InboundMessage,
    callback: InboundCallback,
    bot_started: BotStartedInfo,
    ignored,

    pub fn deinit(self: *ParsedUpdate, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message => |*m| m.deinit(allocator),
            .callback => |*c| c.deinit(allocator),
            .bot_started => |*b| b.deinit(allocator),
            .ignored => {},
        }
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Parsing functions
// ════════════════════════════════════════════════════════════════════════════

/// Parse a single update JSON object from the updates array.
pub fn parseUpdate(allocator: std.mem.Allocator, update_obj: std.json.Value) ?ParsedUpdate {
    if (update_obj != .object) return null;
    const obj = update_obj.object;

    const update_type_str = if (obj.get("update_type")) |v|
        (if (v == .string) v.string else null)
    else
        null;
    const update_type = if (update_type_str) |s| UpdateType.fromString(s) else return null;

    return switch (update_type) {
        .message_created => parseMessageCreated(allocator, obj),
        .message_callback => parseMessageCallback(allocator, obj),
        .bot_started => parseBotStarted(allocator, obj),
        .bot_stopped, .bot_added, .bot_removed, .message_edited, .message_removed,
        .user_added, .user_removed, .chat_title_changed, .unknown => .ignored,
    };
}

fn parseMessageCreated(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?ParsedUpdate {
    const message = getObject(obj, "message") orelse return null;
    const sender = parseSender(allocator, message) orelse return null;
    errdefer sender.deinit(allocator);
    const chat = parseChat(allocator, message) orelse {
        sender.deinit(allocator);
        return null;
    };
    errdefer chat.deinit(allocator);

    const body = getObject(message, "body");
    const text: ?[]u8 = if (body) |b| (
        if (getStr(b, "text")) |t| (allocator.dupe(u8, t) catch null) else null
    ) else null;
    errdefer if (text) |t| allocator.free(t);

    const mid: ?[]u8 = if (body) |b| (
        if (getStr(b, "mid")) |m| (allocator.dupe(u8, m) catch null) else null
    ) else null;
    errdefer if (mid) |m| allocator.free(m);

    const timestamp: u64 = if (obj.get("timestamp")) |v|
        (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
    else
        0;

    // Parse attachments
    var urls: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (urls.items) |u| allocator.free(u);
        urls.deinit(allocator);
    }
    var types: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (types.items) |t| allocator.free(t);
        types.deinit(allocator);
    }

    if (body) |b| {
        if (b.get("attachments")) |att_val| {
            if (att_val == .array) {
                for (att_val.array.items) |att| {
                    if (att != .object) continue;
                    const att_type = getStr(att.object, "type") orelse continue;
                    const payload = getObject(att.object, "payload");
                    const url_str = if (payload) |p| getStr(p, "url") else null;
                    if (url_str) |url| {
                        urls.append(allocator, allocator.dupe(u8, url) catch continue) catch continue;
                        types.append(allocator, allocator.dupe(u8, att_type) catch continue) catch continue;
                    }
                }
            }
        }
    }

    return .{ .message = .{
        .sender = sender,
        .chat = chat,
        .text = text,
        .mid = mid,
        .timestamp = timestamp,
        .attachment_urls = urls.toOwnedSlice(allocator) catch &.{},
        .attachment_types = types.toOwnedSlice(allocator) catch &.{},
    } };
}

fn parseMessageCallback(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?ParsedUpdate {
    const callback_id = getStr(obj, "callback_id") orelse return null;
    const callback = getObject(obj, "callback") orelse return null;
    const payload = getStr(callback, "payload") orelse return null;

    // Sender is in the callback.user object
    const user = getObject(callback, "user") orelse return null;
    const sender = parseSenderFromUser(allocator, user) orelse return null;
    errdefer sender.deinit(allocator);

    // Chat ID from callback.message.recipient.chat_id or fallback
    var chat_id: []u8 = undefined;
    if (getObject(callback, "message")) |msg| {
        if (getObject(msg, "recipient")) |recip| {
            if (getStr(recip, "chat_id")) |cid| {
                chat_id = allocator.dupe(u8, cid) catch return null;
            } else {
                chat_id = allocator.dupe(u8, sender.user_id) catch return null;
            }
        } else {
            chat_id = allocator.dupe(u8, sender.user_id) catch return null;
        }
    } else {
        chat_id = allocator.dupe(u8, sender.user_id) catch return null;
    }

    return .{ .callback = .{
        .callback_id = allocator.dupe(u8, callback_id) catch return null,
        .payload = allocator.dupe(u8, payload) catch return null,
        .sender = sender,
        .chat_id = chat_id,
    } };
}

fn parseBotStarted(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?ParsedUpdate {
    const user = getObject(obj, "user") orelse return null;
    const sender = parseSenderFromUser(allocator, user) orelse return null;
    errdefer sender.deinit(allocator);

    const chat_id_str = if (getStr(obj, "chat_id")) |c| c else sender.user_id;
    const chat_id = allocator.dupe(u8, chat_id_str) catch return null;
    errdefer allocator.free(chat_id);

    const payload: ?[]u8 = if (getStr(obj, "payload")) |p|
        (allocator.dupe(u8, p) catch null)
    else
        null;

    return .{ .bot_started = .{
        .sender = sender,
        .chat_id = chat_id,
        .payload = payload,
    } };
}

// ════════════════════════════════════════════════════════════════════════════
// JSON helpers
// ════════════════════════════════════════════════════════════════════════════

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn parseSender(allocator: std.mem.Allocator, message_obj: std.json.ObjectMap) ?SenderInfo {
    const sender = getObject(message_obj, "sender") orelse return null;
    return parseSenderFromUser(allocator, sender);
}

fn parseSenderFromUser(allocator: std.mem.Allocator, user_obj: std.json.ObjectMap) ?SenderInfo {
    // user_id can be string or integer
    var user_id: []u8 = undefined;
    if (user_obj.get("user_id")) |uid| {
        if (uid == .string) {
            user_id = allocator.dupe(u8, uid.string) catch return null;
        } else if (uid == .integer) {
            user_id = std.fmt.allocPrint(allocator, "{d}", .{uid.integer}) catch return null;
        } else return null;
    } else return null;
    errdefer allocator.free(user_id);

    const name: ?[]u8 = if (getStr(user_obj, "name")) |n|
        (allocator.dupe(u8, n) catch null)
    else
        null;
    const username: ?[]u8 = if (getStr(user_obj, "username")) |u|
        (allocator.dupe(u8, u) catch null)
    else
        null;

    return .{
        .user_id = user_id,
        .name = name,
        .username = username,
    };
}

fn parseChat(allocator: std.mem.Allocator, message_obj: std.json.ObjectMap) ?ChatInfo {
    const recipient = getObject(message_obj, "recipient") orelse return null;
    const chat_id_str = getStr(recipient, "chat_id") orelse return null;
    const chat_type_str = getStr(recipient, "chat_type");

    const chat_type: ChatInfo.ChatType = if (chat_type_str) |ct| blk: {
        if (std.mem.eql(u8, ct, "dialog")) break :blk .dialog;
        if (std.mem.eql(u8, ct, "chat")) break :blk .chat;
        if (std.mem.eql(u8, ct, "channel")) break :blk .channel;
        break :blk .dialog;
    } else .dialog;

    return .{
        .chat_id = allocator.dupe(u8, chat_id_str) catch return null,
        .chat_type = chat_type,
    };
}

/// Map Max attachment type string to a marker prefix for ChannelMessage content.
pub fn attachmentMarkerPrefix(att_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, att_type, "image")) return "[IMAGE:";
    if (std.mem.eql(u8, att_type, "video")) return "[VIDEO:";
    if (std.mem.eql(u8, att_type, "audio")) return "[AUDIO:";
    if (std.mem.eql(u8, att_type, "file")) return "[DOCUMENT:";
    if (std.mem.eql(u8, att_type, "sticker")) return "[IMAGE:";
    return null;
}

/// Parse the marker for updates response to use for next poll.
pub fn parseUpdatesMarker(allocator: std.mem.Allocator, json_resp: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const marker = parsed.value.object.get("marker") orelse return null;
    if (marker != .string) return null;
    if (marker.string.len == 0) return null;
    return allocator.dupe(u8, marker.string) catch null;
}

/// Parse updates array from getUpdates response.
pub fn parseUpdatesArray(json_resp: []const u8, allocator: std.mem.Allocator) ?std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "UpdateType.fromString parses known types" {
    try std.testing.expectEqual(UpdateType.message_created, UpdateType.fromString("message_created"));
    try std.testing.expectEqual(UpdateType.message_callback, UpdateType.fromString("message_callback"));
    try std.testing.expectEqual(UpdateType.bot_started, UpdateType.fromString("bot_started"));
    try std.testing.expectEqual(UpdateType.unknown, UpdateType.fromString("something_else"));
}

test "parseUpdate message_created with text" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"message_created","timestamp":1710000000,
        \\"message":{"sender":{"user_id":"42","name":"Alice","username":"alice"},
        \\"recipient":{"chat_id":"100","chat_type":"dialog"},
        \\"body":{"mid":"msg-1","text":"Hello Max!"}}}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();

    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);

    switch (update) {
        .message => |msg| {
            try std.testing.expectEqualStrings("42", msg.sender.user_id);
            try std.testing.expectEqualStrings("alice", msg.sender.username.?);
            try std.testing.expectEqualStrings("Alice", msg.sender.name.?);
            try std.testing.expectEqualStrings("100", msg.chat.chat_id);
            try std.testing.expect(!msg.chat.isGroup());
            try std.testing.expectEqualStrings("Hello Max!", msg.text.?);
            try std.testing.expectEqualStrings("msg-1", msg.mid.?);
            try std.testing.expectEqual(@as(u64, 1710000000), msg.timestamp);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUpdate message_created group chat" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"message_created",
        \\"message":{"sender":{"user_id":"42","name":"Alice"},
        \\"recipient":{"chat_id":"200","chat_type":"chat"},
        \\"body":{"mid":"msg-2","text":"Hi group"}}}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);

    switch (update) {
        .message => |msg| {
            try std.testing.expect(msg.chat.isGroup());
            try std.testing.expectEqualStrings("200", msg.chat.chat_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUpdate message_created with image attachment" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"message_created",
        \\"message":{"sender":{"user_id":"42","name":"Alice"},
        \\"recipient":{"chat_id":"100","chat_type":"dialog"},
        \\"body":{"mid":"msg-3","text":"Look!","attachments":[{"type":"image","payload":{"url":"https://example.com/photo.jpg"}}]}}}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);

    switch (update) {
        .message => |msg| {
            try std.testing.expectEqual(@as(usize, 1), msg.attachment_urls.len);
            try std.testing.expectEqualStrings("https://example.com/photo.jpg", msg.attachment_urls[0]);
            try std.testing.expectEqualStrings("image", msg.attachment_types[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUpdate message_callback" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"message_callback","callback_id":"cb-1",
        \\"callback":{"payload":"opt1","user":{"user_id":"42","name":"Alice"},
        \\"message":{"recipient":{"chat_id":"100"}}}}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);

    switch (update) {
        .callback => |cb| {
            try std.testing.expectEqualStrings("cb-1", cb.callback_id);
            try std.testing.expectEqualStrings("opt1", cb.payload);
            try std.testing.expectEqualStrings("42", cb.sender.user_id);
            try std.testing.expectEqualStrings("100", cb.chat_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUpdate bot_started with payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"bot_started","chat_id":"100",
        \\"user":{"user_id":"42","name":"Alice"},"payload":"deep-link-data"}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);

    switch (update) {
        .bot_started => |bs| {
            try std.testing.expectEqualStrings("42", bs.sender.user_id);
            try std.testing.expectEqualStrings("100", bs.chat_id);
            try std.testing.expectEqualStrings("deep-link-data", bs.payload.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUpdate bot_stopped is ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"update_type":"bot_stopped","user":{"user_id":"42","name":"Alice"},"chat_id":"100"}
    ;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);
    try std.testing.expect(update == .ignored);
}

test "parseUpdate unknown type is ignored" {
    const allocator = std.testing.allocator;
    const json = "{\"update_type\":\"chat_title_changed\"}";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.TestUnexpectedResult;
    defer parsed.deinit();
    var update = parseUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer update.deinit(allocator);
    try std.testing.expect(update == .ignored);
}

test "SenderInfo.identity prefers username" {
    const sender = SenderInfo{ .user_id = @constCast("42"), .username = @constCast("alice") };
    try std.testing.expectEqualStrings("alice", sender.identity());
}

test "SenderInfo.identity falls back to user_id" {
    const sender = SenderInfo{ .user_id = @constCast("42") };
    try std.testing.expectEqualStrings("42", sender.identity());
}

test "attachmentMarkerPrefix maps types" {
    try std.testing.expectEqualStrings("[IMAGE:", attachmentMarkerPrefix("image").?);
    try std.testing.expectEqualStrings("[VIDEO:", attachmentMarkerPrefix("video").?);
    try std.testing.expectEqualStrings("[AUDIO:", attachmentMarkerPrefix("audio").?);
    try std.testing.expectEqualStrings("[DOCUMENT:", attachmentMarkerPrefix("file").?);
    try std.testing.expectEqualStrings("[IMAGE:", attachmentMarkerPrefix("sticker").?);
    try std.testing.expect(attachmentMarkerPrefix("unknown") == null);
}

test "parseUpdatesMarker extracts marker string" {
    const allocator = std.testing.allocator;
    const json = "{\"updates\":[],\"marker\":\"next-page-42\"}";
    const marker = parseUpdatesMarker(allocator, json) orelse return error.TestUnexpectedResult;
    defer allocator.free(marker);
    try std.testing.expectEqualStrings("next-page-42", marker);
}

test "parseUpdatesMarker returns null on missing marker" {
    const allocator = std.testing.allocator;
    try std.testing.expect(parseUpdatesMarker(allocator, "{\"updates\":[]}") == null);
}
```

- [ ] **Step 2: Run tests**

Run: `zig test src/channels/max_ingress.zig 2>&1 | tail -5`
Expected: All tests pass with 0 leaks

- [ ] **Step 3: Commit**

```bash
git add src/channels/max_ingress.zig
git commit -m "feat(max): add max_ingress.zig update parser with tests"
```

---

## Chunk 4: max.zig — Core Channel with VTable

### Task 6: Create max.zig with MaxChannel struct and VTable

**Files:**
- Create: `src/channels/max.zig`
- Modify: `src/channels/root.zig:174` (add import)

This is the largest task. The file implements MaxChannel with all 9 VTable methods: start, stop, send, sendEvent (streaming), sendRich (keyboards), name, healthCheck, startTyping, stopTyping.

- [ ] **Step 1: Create max.zig skeleton with basic VTable (start, stop, send, name, healthCheck)**

Create `src/channels/max.zig` with the core struct, VTable, basic text sending, and tests. Start with the 5 required vtable methods. The file will be ~800 lines initially.

Key structure:
```zig
pub const MaxChannel = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    account_id: []const u8 = "default",
    allow_from: []const []const u8,
    group_allow_from: []const []const u8,
    group_policy: []const u8,
    proxy: ?[]const u8 = null,
    mode: config_types.MaxListenerMode = .polling,
    webhook_url: ?[]const u8 = null,
    webhook_secret: ?[]const u8 = null,
    interactive: config_types.MaxInteractiveConfig = .{},
    require_mention: bool = false,
    streaming_enabled: bool = true,

    bot_username: ?[]const u8 = null,
    bot_user_id: ?[]const u8 = null,
    marker: ?[]u8 = null,  // polling marker
    running: bool = false,

    // Typing state
    typing_mu: std.Thread.Mutex = .{},
    typing_handles: std.StringHashMapUnmanaged(*TypingTask) = .empty,

    // Interaction state (for callback buttons)
    interaction_mu: std.Thread.Mutex = .{},
    pending_interactions: std.StringHashMapUnmanaged(PendingInteraction) = .empty,
    interaction_seq: Atomic(u64) = Atomic(u64).init(1),

    // Draft/streaming state
    draft_mu: std.Thread.Mutex = .{},
    draft_buffers: std.StringHashMapUnmanaged(DraftState) = .empty,

    pub const MAX_MESSAGE_LEN: usize = 4000;
    const CONTINUATION_MARKER = "\n\n\u{23EC}";
    const TYPING_INTERVAL_NS: u64 = 4 * std.time.ns_per_s;
    const DRAFT_MIN_EDIT_INTERVAL_MS: i64 = 500;
    const DRAFT_MIN_DELTA_CHARS: usize = 100;

    // ... init, initFromConfig, channelName, healthCheck, api() helper,
    //     isUserAllowed, isGroupUserAllowed, shouldProcessMessage,
    //     send methods, processUpdate, pollUpdates,
    //     streaming, typing, interactions, vtable wrappers
};
```

Include all types (TypingTask, PendingInteraction, DraftState, PendingInteractionOption) and core implementations following Telegram patterns.

- [ ] **Step 2: Add the import in root.zig**

In `src/channels/root.zig`, after line 174 (`pub const signal = @import("signal.zig");`), add:

```zig
pub const max = @import("max.zig");
```

- [ ] **Step 3: Verify full project build**

Run: `zig build -Dchannels=max 2>&1 | head -10`
Expected: clean build (MaxChannel compiles)

- [ ] **Step 4: Run max.zig tests**

Run: `zig test src/channels/max.zig 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Run full project test suite**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: All tests pass (existing + new)

- [ ] **Step 6: Commit**

```bash
git add src/channels/max.zig src/channels/root.zig
git commit -m "feat(max): add MaxChannel struct with VTable and core send/receive"
```

---

## Chunk 5: Polling + Webhook Integration

### Task 7: Add Max polling loop to channel_loop.zig and channel_adapters.zig

**Files:**
- Modify: `src/channel_loop.zig:10` (import), `src/channel_loop.zig:1649` (after MatrixLoopState), `src/channel_loop.zig:1651-1655` (PollingState union)
- Modify: `src/channel_adapters.zig:5-7` (imports), `src/channel_adapters.zig:37-52` (polling_descriptors)

- [ ] **Step 1: Add MaxLoopState and spawnMaxPolling to channel_loop.zig**

Add import at top (after line 31 `const matrix = ...`):
```zig
const max_channel = @import("channels/max.zig");
```

Add after `MatrixLoopState` (line 1649):
```zig
pub const MaxLoopState = struct {
    last_activity: Atomic(i64),
    stop_requested: Atomic(bool),
    thread: ?std.Thread = null,

    pub fn init() MaxLoopState {
        return .{
            .last_activity = Atomic(i64).init(std.time.timestamp()),
            .stop_requested = Atomic(bool).init(false),
        };
    }
};
```

Add `max: *MaxLoopState,` to `PollingState` union (line 1651-1655).

Add `spawnMaxPolling` after `spawnMatrixPolling`:
```zig
pub fn spawnMaxPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const mx_ls = try allocator.create(MaxLoopState);
    errdefer allocator.destroy(mx_ls);
    mx_ls.* = MaxLoopState.init();
    const mx_ptr: *max_channel.MaxChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE },
        runMaxLoop,
        .{ allocator, config, runtime, mx_ls, mx_ptr },
    );
    mx_ls.thread = thread;
    return .{ .thread = thread, .state = .{ .max = mx_ls } };
}
```

Add `runMaxLoop` function following `runTelegramLoop` pattern but simplified (no voice transcription, no media group debouncing):
```zig
pub fn runMaxLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *MaxLoopState,
    mx_ptr: *max_channel.MaxChannel,
) void {
    // Polling loop: getUpdates -> processUpdate -> dispatch to session
    // Pattern follows runTelegramLoop but uses marker-based pagination
    // and Max API endpoints
}
```

- [ ] **Step 2: Add Max to channel_adapters.zig**

Add import after line 6:
```zig
const max_channel = @import("channels/max.zig");
```

Add to `polling_descriptors` array (before the closing `};`):
```zig
    .{
        .channel_name = "max",
        .spawn = channel_loop.spawnMaxPolling,
    },
```

- [ ] **Step 3: Update PollingState switch arms in channel_manager.zig**

Find all `switch (state)` blocks that match on `PollingState` variants and add `.max => |ls| ls.last_activity.load(.acquire),` and `.max => |ls| ls.stop_requested.store(true, .release),` etc.

- [ ] **Step 4: Build and test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/channel_loop.zig src/channel_adapters.zig src/channel_manager.zig
git commit -m "feat(max): add polling loop and channel adapters integration"
```

---

### Task 8: Add Max webhook handler to gateway.zig

**Files:**
- Modify: `src/gateway.zig` (webhook_route_descriptors, handler function)

- [ ] **Step 1: Add webhook route descriptor**

In `webhook_route_descriptors` array, add:
```zig
    .{ .path = "/max", .handler = handleMaxWebhookRoute },
```

- [ ] **Step 2: Add handleMaxWebhookRoute function**

Follow the Line webhook handler pattern:
```zig
fn handleMaxWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_max) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"max channel disabled\"}";
        return;
    }
    // Verify method is POST
    // Check X-Max-Bot-Api-Secret header if configured
    // Parse body as JSON update
    // Call processUpdate on the MaxChannel instance
    // Return 200
}
```

- [ ] **Step 3: Build and test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add src/gateway.zig
git commit -m "feat(max): add webhook handler in gateway"
```

---

### Task 9: Add Max standalone mode to main.zig

**Files:**
- Modify: `src/main.zig:2171-2194` (channel start dispatch)

- [ ] **Step 1: Add `.max` case to channel start switch**

Before the `else` branch (line 2193), add:
```zig
        .max => {
            if (config.channels.maxPrimary()) |max_config| {
                return runMaxChannel(allocator, args, config.*, max_config);
            }
            std.debug.print("Max channel is not configured.\n", .{});
            std.process.exit(1);
        },
```

- [ ] **Step 2: Add runMaxChannel function**

Follow `runTelegramChannel` pattern but simplified. Place near the end of main.zig:
```zig
fn runMaxChannel(allocator: std.mem.Allocator, args: []const []const u8, config: yc.config.Config, max_config: yc.config.MaxConfig) !void {
    if (!build_options.enable_channel_max) {
        std.debug.print("Max channel is disabled in this build.\n", .{});
        std.process.exit(1);
    }
    // Initialize MaxChannel from config
    // Set up provider, tools, memory, security
    // Enter polling loop (similar to runTelegramChannel)
}
```

- [ ] **Step 3: Build and test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(max): add standalone channel mode in main.zig"
```

---

## Chunk 6: Final Verification

### Task 10: Full integration build and test

- [ ] **Step 1: Format all source files**

Run: `zig fmt src/`

- [ ] **Step 2: Run full test suite**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: All 5,300+ tests pass with 0 leaks (existing + ~60 new Max tests)

- [ ] **Step 3: Verify conditional compilation**

Run: `zig build -Dchannels=max`
Expected: builds only Max channel

Run: `zig build -Dchannels=none`
Expected: builds with no channels

Run: `zig build -Dchannels=telegram,max`
Expected: builds Telegram + Max

Run: `zig build`
Expected: builds all channels including Max

- [ ] **Step 4: Verify release build size**

Run: `zig build -Doptimize=ReleaseSmall -Dchannels=max && ls -la zig-out/bin/nullclaw`
Expected: binary size reasonable (verify it's still under target)

- [ ] **Step 5: Commit any formatting fixes**

```bash
git add -A
git commit -m "style: format Max channel source files"
```

- [ ] **Step 6: Final verification commit message**

Run: `zig build test --summary all`
All green.
