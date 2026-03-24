# WeChat iLink Channel - Implementation Review & Usage Guide

## Executive Summary

Your WeChat iLink channel implementation **follows NullClaw's architectural patterns correctly**. It wraps the External Channel mechanism to bridge with the `wechat-ilink-client` Node.js package via JSON-RPC over stdio.

---

## Architecture Analysis

### Design Pattern: External Channel Wrapper

Your implementation correctly uses the **External Channel pattern** (`src/channels/external.zig`), which is the recommended way to integrate third-party channel adapters:

```
WeChatIlinkChannel (src/channels/wechat_ilink.zig)
    ↓ wraps
ExternalChannel (src/channels/external.zig)
    ↓ spawns via stdio
wechat-ilink-channel (Node.js process)
    ↓ speaks
WeChat iLink Protocol
```

### Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `src/channels/wechat_ilink.zig` | Zig wrapper, config translation | 106 |
| `src/channels/external.zig` | Generic external channel host | 668 |
| `src/channels/external_protocol.zig` | JSON-RPC protocol definition | 812 |
| `src/config_types.zig:548-562` | WeChatIlinkConfig struct | 15 |
| `src/channel_catalog.zig` | Channel registration metadata | 1 per entry |

---

## Implementation Review

### What You Did Right ✓

1. **Correct vtable delegation**: The `WeChatIlinkChannel` struct delegates to `ExternalChannel.channel()`, which provides the full Channel vtable implementation including:
   - `start`, `stop`, `send`, `name`, `healthCheck` (required)
   - `sendEvent`, `sendRich`, `sendTracked` (optional outbound)
   - `startTyping`, `stopTyping` (optional presence)
   - `editMessage`, `deleteMessage` (optional message management)
   - `setReaction`, `markRead` (optional reactions)

2. **Proper config translation**: The `buildExternalConfig()` function correctly translates `WeChatIlinkConfig` to `ExternalChannelConfig`, serializing plugin-specific options as JSON.

3. **Event bus integration**: The `setBus()` method properly wires the external channel to the event bus for inbound messages.

4. **Runtime naming**: Uses `"wechat_ilink"` as the runtime name, consistent with the channel key.

5. **Registration complete**: The channel is properly registered in:
   - `src/channels/root.zig:288` (module export)
   - `src/channel_catalog.zig:20,65,95,125,156` (catalog metadata)
   - `src/channel_manager.zig:804-844` (test fixtures)

### Code Structure Assessment

```zig
// src/channels/wechat_ilink.zig
pub const WeChatIlinkChannel = struct {
    external_channel: external.ExternalChannel,  // ✓ Composition over inheritance

    pub fn init(allocator: std.mem.Allocator, config: config_types.WeChatIlinkConfig) Error!WeChatIlinkChannel {
        const external_config = buildExternalConfig(allocator, config) catch |err| {
            log.err("Failed to build external config: {s}", .{@errorName(err)});
            return Error.BuildError;
        };
        return .{
            .external_channel = external.ExternalChannel.initFromConfig(allocator, external_config),
        };
    }
    // ... delegation methods follow
};
```

**Verdict**: Clean, idiomatic Zig following NullClaw conventions.

---

## Configuration Schema

### WeChatIlinkConfig (config_types.zig:548-562)

```zig
pub const WeChatIlinkConfig = struct {
    account_id: []const u8 = "default",
    /// QR login timeout in milliseconds (default: 480000 = 8 minutes)
    timeout_ms: ?u32 = null,
    /// Bot type parameter (default: "3")
    bot_type: ?[]const u8 = null,
    /// Max QR refreshes on expiry (default: 3)
    max_refreshes: ?u32 = null,
    /// WeChat iLink API base URL (default: "https://ilinkai.weixin.qq.com")
    base_url: ?[]const u8 = null,
    /// Pre-saved token for session resume (optional)
    token: ?[]const u8 = null,
    /// Allowed sender IDs (empty = allow all, "*" = wildcard)
    allow_from: []const []const u8 = &.{},
};
```

### Translated ExternalChannelConfig

Your `buildExternalConfig()` generates:

```zig
ExternalChannelConfig{
    .account_id = config.account_id,
    .runtime_name = "wechat_ilink",
    .transport = .{
        .command = "node",
        .args = &.{ "--experimental-vm-modules", "wechat-ilink-channel" },
        .timeout_ms = 60000,
    },
    .plugin_config_json = "{...}",  // Serialized WeChatIlinkConfig fields
}
```

---

## Usage Documentation

### 1. Prerequisites

Install the WeChat iLink client package globally:

```bash
npm install -g wechat-ilink-channel
```

Ensure `node` is in your `$PATH` and supports `--experimental-vm-modules`.

### 2. Configuration

Add to `~/.nullclaw/config.json`:

```json
{
  "channels": {
    "wechat_ilink": [
      {
        "account_id": "main",
        "timeout_ms": 480000,
        "bot_type": "3",
        "max_refreshes": 3,
        "base_url": "https://ilinkai.weixin.qq.com",
        "token": null,
        "allow_from": ["*"]
      }
    ]
  }
}
```

### 3. Running NullClaw with WeChat iLink

```bash
# Start the gateway (runs all configured channels)
nullclaw gateway

# Check channel status
nullclaw channel status

# Expected output:
# - wechat_ilink: configured (1 accounts)
```

### 4. Listener Mode

The WeChat iLink channel uses `gateway_loop` listener mode (as defined in `channel_catalog.zig:65`):

- Runs continuously in the background
- Communicates via stdio JSON-RPC with the Node.js plugin
- The plugin handles WeChat protocol specifics (QR login, message polling, etc.)

---

## External Protocol Summary

The `wechat-ilink-channel` Node.js process must implement the External Channel Protocol v2:

### Lifecycle Methods (Plugin → Host)

| Method | Description |
|--------|-------------|
| `get_manifest` | Return capabilities (streaming, health, typing, etc.) |
| `start` | Initialize with runtime config, begin listening |
| `stop` | Cleanup and exit |
| `health` | (Optional) Return health status |

### Outbound Methods (Host → Plugin)

| Method | Description |
|--------|-------------|
| `send` | Send text message to target |
| `send_rich` | Send structured payload (text + attachments + choices) |
| `start_typing` | Show typing indicator |
| `stop_typing` | Hide typing indicator |
| `edit_message` | Edit existing message |
| `delete_message` | Delete message |
| `set_reaction` | Add/remove reaction |
| `mark_read` | Mark message as read |

### Inbound Notifications (Plugin → Host)

| Method | Description |
|--------|-------------|
| `inbound_message` | Incoming message from WeChat |

See `src/channels/external_protocol.zig` for full protocol specification.

---

## Comparison: WeChat vs WeChat iLink vs WeCom

| Feature | `wechat` (Native) | `wechat_ilink` (External) | `wecom` (Enterprise) |
|---------|-------------------|---------------------------|----------------------|
| **Type** | Official Account API | Personal/Group via iLink | WeChat Work |
| **Protocol** | Webhook + REST | External JSON-RPC | Webhook + REST |
| **Inbound** | ✓ Webhook callbacks | ✓ Via plugin | ✓ Webhook callbacks |
| **Outbound** | ✓ Custom service API | ✓ Via plugin | ✓ Webhook bot |
| **Encryption** | AES-256-CBC | Handled by plugin | AES-256-CBC |
| **Use Case** | Official accounts | Personal WeChat | Enterprise messaging |
| **File** | `wechat.zig` (496 lines) | `wechat_ilink.zig` (106 lines) | `wecom.zig` (470 lines) |

---

## Testing Recommendations

### Unit Tests

Consider adding tests to `src/channels/wechat_ilink.zig`:

```zig
test "wechat_ilink builds external config correctly" {
    const allocator = std.testing.allocator;
    const config = config_types.WeChatIlinkConfig{
        .account_id = "test",
        .timeout_ms = 300000,
        .bot_type = "3",
        .allow_from = &.{"user1", "user2"},
    };
    
    const external_config = try buildExternalConfig(allocator, config);
    defer allocator.free(external_config.plugin_config_json);
    
    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, external_config.plugin_config_json, "\"timeout_ms\":300000") != null);
    try std.testing.expect(std.mem.indexOf(u8, external_config.plugin_config_json, "\"bot_type\":\"3\"") != null);
}

test "wechat_ilink channel returns correct name" {
    var ch = WeChatIlinkChannel.init(std.testing.allocator, .{
        .account_id = "test",
    });
    try std.testing.expectEqualStrings("wechat_ilink", ch.channel().name());
}
```

### Integration Testing

1. Install `wechat-ilink-channel` npm package
2. Configure with test account
3. Run `nullclaw gateway` and verify:
   - Plugin process spawns correctly
   - QR login flow completes
   - Inbound messages reach the bus
   - Outbound messages send successfully

---

## Security Considerations

1. **Token handling**: The optional `token` field supports session resume. If used:
   - Store tokens securely (encrypted)
   - Rotate periodically
   - Never commit to version control

2. **Allowlist**: Empty `allow_from` defaults to deny-all. Use `["*"]` for allow-all (logs warning).

3. **Process isolation**: The external channel spawns Node.js as a subprocess with stdio communication only.

---

## Build Verification

```bash
# Verify compilation
zig build

# Run all tests (including channel tests)
zig build test --summary all

# Release build
zig build -Doptimize=ReleaseSmall
```

Current status: ✓ Compiles successfully

---

## Summary

| Aspect | Rating | Notes |
|--------|--------|-------|
| Architecture | ✓ Excellent | Correctly uses External Channel pattern |
| Code Quality | ✓ Good | Clean Zig, follows conventions |
| Completeness | ✓ Complete | Full registration, config, vtable wiring |
| Documentation | ⚠ Needs work | This document fills the gap |
| Tests | ⚠ Missing | Add unit tests recommended |

**Overall**: Production-ready implementation following NullClaw best practices.

---

## Related Documentation

- `src/channels/external_protocol.zig` — Protocol specification
- `docs/en/configuration.md` — General channel configuration
- `docs/en/architecture.md` — Channel architecture overview

---

*Generated for NullClaw WeChat iLink Channel Review*
