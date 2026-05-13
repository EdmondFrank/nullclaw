const std = @import("std");
const root = @import("root.zig");
const external = @import("external.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");

const log = std.log.scoped(.wechat_ilink);

pub const WeChatIlinkChannel = struct {
    external_channel: external.ExternalChannel,

    pub const Error = error{
        InvalidConfiguration,
        BuildError,
    };

    pub fn init(allocator: std.mem.Allocator, config: config_types.WeChatIlinkConfig) Error!WeChatIlinkChannel {
        const external_config = buildExternalConfig(allocator, config) catch |err| {
            log.err("Failed to build external config: {s}", .{@errorName(err)});
            return Error.BuildError;
        };

        return .{
            .external_channel = external.ExternalChannel.initFromConfig(allocator, external_config),
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.WeChatIlinkConfig) WeChatIlinkChannel {
        return init(allocator, cfg) catch @panic("WeChat iLink channel init failed");
    }

    pub fn setBus(self: *WeChatIlinkChannel, event_bus: *bus_mod.Bus) void {
        self.external_channel.setBus(event_bus);
    }

    pub fn channel(self: *WeChatIlinkChannel) root.Channel {
        return self.external_channel.channel();
    }

    fn buildExternalConfig(allocator: std.mem.Allocator, config: config_types.WeChatIlinkConfig) !config_types.ExternalChannelConfig {
        var plugin_config_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer plugin_config_buf.deinit(allocator);

        var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &plugin_config_buf);
        const writer = &buf_writer.writer;

        try writer.writeAll("{");

        var first = true;

        if (config.timeout_ms) |timeout| {
            if (!first) try writer.writeAll(",");
            try writer.print("\"timeout_ms\":{d}", .{timeout});
            first = false;
        }

        if (config.bot_type) |bot_type| {
            if (!first) try writer.writeAll(",");
            try writer.print("\"bot_type\":\"{s}\"", .{bot_type});
            first = false;
        }

        if (config.max_refreshes) |max| {
            if (!first) try writer.writeAll(",");
            try writer.print("\"max_refreshes\":{d}", .{max});
            first = false;
        }

        if (config.base_url) |url| {
            if (!first) try writer.writeAll(",");
            try writer.print("\"base_url\":\"{s}\"", .{url});
            first = false;
        }

        if (config.token) |token| {
            if (!first) try writer.writeAll(",");
            try writer.print("\"token\":\"{s}\"", .{token});
            first = false;
        }

        if (config.allow_from.len > 0) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"allow_from\":[");
            for (config.allow_from, 0..) |entry, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{entry});
            }
            try writer.writeAll("]");
            first = false;
        }

        try writer.writeAll("}");
        plugin_config_buf = buf_writer.toArrayList();

        const plugin_config_json = try allocator.dupe(u8, plugin_config_buf.items);

        // Determine command and args based on config
        var command: []const u8 = undefined;
        var args: []const []const u8 = undefined;

        if (config.command) |custom_cmd| {
            // Use custom command
            command = custom_cmd;
            if (config.args) |custom_args| {
                args = custom_args;
            } else {
                // Default: no args for custom command
                args = &.{};
            }
            log.info("Using custom command '{s}' for WeChat iLink channel (account: {s})", .{ command, config.account_id });
        } else {
            // Use runtime detection
            const is_bun = std.mem.eql(u8, config.runtime, "bun");
            command = if (is_bun) "bun" else "node";

            // Build args slice based on runtime
            if (is_bun) {
                args = &.{ "run", "wechat-ilink-channel" };
            } else {
                args = &.{ "--experimental-vm-modules", "wechat-ilink-channel" };
            }
            log.info("Using runtime '{s}' for WeChat iLink channel (account: {s})", .{ command, config.account_id });
        }

        return config_types.ExternalChannelConfig{
            .account_id = config.account_id,
            .runtime_name = "wechat_ilink",
            .transport = .{
                .command = command,
                .args = args,
                .timeout_ms = config.control_timeout_ms orelse 60000,
            },
            .plugin_config_json = plugin_config_json,
        };
    }
};

// Regression: buildExternalConfig previously read plugin_config_buf.items before
// calling buf_writer.toArrayList(), so plugin_config_json was always "". The start
// params then contained "config":} which caused the plugin to log:
//   Error handling request: SyntaxError: JSON Parse error: Unexpected token '}'
test "buildExternalConfig plugin_config_json is non-empty and valid JSON" {
    const allocator = std.testing.allocator;
    const cfg = config_types.WeChatIlinkConfig{
        .account_id = "test",
        .token = "tok123",
        .command = "bun",
    };
    const ext = try WeChatIlinkChannel.buildExternalConfig(allocator, cfg);
    defer allocator.free(ext.plugin_config_json);

    // Must not be empty
    try std.testing.expect(ext.plugin_config_json.len > 0);
    // Must be valid JSON (parseable)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ext.plugin_config_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    // token field must be present
    const token_val = parsed.value.object.get("token") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tok123", token_val.string);
}

test "buildExternalConfig plugin_config_json is valid JSON with no fields" {
    const allocator = std.testing.allocator;
    const cfg = config_types.WeChatIlinkConfig{
        .account_id = "default",
        .command = "bun",
    };
    const ext = try WeChatIlinkChannel.buildExternalConfig(allocator, cfg);
    defer allocator.free(ext.plugin_config_json);

    // Must be "{}" — an empty object, not an empty string
    try std.testing.expectEqualStrings("{}", ext.plugin_config_json);
}
