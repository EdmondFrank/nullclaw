const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const providers = @import("../providers/root.zig");
const ProviderEntry = @import("../config_types.zig").ProviderEntry;
const provider_names = @import("../provider_names.zig");
const multimodal = @import("../multimodal.zig");
const net_security = @import("../net_security.zig");

const log = std.log.scoped(.view);

const DEFAULT_MODEL = "kimi-k2.6";
const DEFAULT_PROVIDER = "exhub";

/// View tool — analyze images using AI vision models via a configured provider.
///
/// Accepts local file paths or remote URLs. Sends images to vision-capable
/// models (e.g. kimi-k2.6, glm-5v-turbo, qwen-vl) through the nullclaw
/// provider infrastructure and returns the model's analysis as text.
pub const ViewTool = struct {
    configured_providers: []const ProviderEntry = &.{},
    fallback_api_key: ?[]const u8 = null,
    view_provider: []const u8 = DEFAULT_PROVIDER,
    view_model: []const u8 = DEFAULT_MODEL,
    workspace_dir: []const u8 = "",
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "view";
    pub const tool_description =
        \\Analyze images using AI vision models via a configured provider (e.g. Gitee AI).
        \\
        \\Accepts local file paths or remote URLs. Use this to extract text,
        \\describe contents, answer questions about images, or analyze visual data.
        \\
        \\**Supported formats:** PNG, JPG, JPEG, GIF, WebP, BMP
        \\
        \\Returns the model's analysis as text (or JSON if response_format="json").
    ;
    pub const tool_params =
        \\{"type":"object","properties":{"image":{"type":"string","description":"Local file path (absolute or ~ shorthand) or remote URL (https://...)"},"prompt":{"type":"string","description":"What to extract or analyze from the image"},"model":{"type":"string","description":"Vision model override (default: uses configured view model)"},"response_format":{"type":"string","description":"Output format: 'text' (default) or 'json'"}},"required":["image","prompt"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ViewTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ViewTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const image = root.getString(args, "image") orelse
            return ToolResult.fail("Missing required 'image' parameter");

        const prompt = root.getString(args, "prompt") orelse
            return ToolResult.fail("Missing required 'prompt' parameter");

        if (image.len == 0)
            return ToolResult.fail("'image' must not be empty");

        if (prompt.len == 0)
            return ToolResult.fail("'prompt' must not be empty");

        const model = root.getString(args, "model") orelse self.view_model;

        const response_format = root.getString(args, "response_format") orelse "text";
        if (!std.mem.eql(u8, response_format, "text") and !std.mem.eql(u8, response_format, "json"))
            return ToolResult.fail("Invalid response_format: must be 'text' or 'json'");

        // Prepare image content part
        const image_part = self.prepareImageContent(allocator, image) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to prepare image: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer self.freeImagePart(allocator, image_part);

        // Build multimodal message: text prompt + image
        const parts = try allocator.alloc(providers.ContentPart, 2);
        defer allocator.free(parts);
        parts[0] = .{ .text = prompt };
        parts[1] = image_part;

        const messages = [_]providers.ChatMessage{.{
            .role = .user,
            .content = prompt,
            .content_parts = parts,
        }};

        // Resolve provider API key
        const api_key = self.resolveProviderApiKey(allocator) orelse
            return ToolResult.fail("No API key found for view provider. Configure the provider in nullclaw config.");

        const provider_entry = self.findProviderEntry(self.view_provider);

        if (builtin.is_test) {
            return ToolResult.fail("Network disabled in tests");
        }

        // Create provider and call chat
        var provider_holder = providers.ProviderHolder.fromConfigWithApiMode(
            allocator,
            self.view_provider,
            api_key,
            if (provider_entry) |e| e.base_url else null,
            if (provider_entry) |e| e.native_tools else true,
            if (provider_entry) |e| e.user_agent else null,
            if (provider_entry) |e| e.api_mode else .chat_completions,
            if (provider_entry) |e| e.max_streaming_prompt_bytes else null,
            if (provider_entry) |e| e.chat_template_enable_thinking_param else false,
            if (provider_entry) |e| e.extra_body_params else null,
        );
        defer provider_holder.deinit();

        const provider = provider_holder.provider();

        var response = provider.chat(
            allocator,
            .{
                .messages = &messages,
                .model = model,
                .temperature = 0.2,
                .max_tokens = 4096,
                .timeout_secs = 120,
            },
            model,
            0.2,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Vision API call failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer response.deinit(allocator);

        const content = response.content orelse "";
        if (content.len == 0)
            return ToolResult.fail("Vision model returned empty response");

        // Optionally wrap response in JSON envelope
        if (std.mem.eql(u8, response_format, "json")) {
            // Return as-is; the model should have been instructed to return JSON
            const output = try allocator.dupe(u8, content);
            return ToolResult{ .success = true, .output = output };
        }

        const output = try allocator.dupe(u8, content);
        return ToolResult{ .success = true, .output = output };
    }

    fn prepareImageContent(self: *ViewTool, allocator: std.mem.Allocator, image: []const u8) !providers.ContentPart {
        if (isHttpsUrl(image)) {
            return providers.makeImageUrlPart(image);
        }

        if (isHttpUrl(image)) {
            return error.HttpNotSupported;
        }

        // Local file — read and base64 encode
        const mm_config = multimodal.MultimodalConfig{
            .allowed_dirs = self.allowed_paths,
            .skip_dir_check = self.allowed_paths.len == 0,
        };
        const img_data = try multimodal.readLocalImage(allocator, image, mm_config);
        defer allocator.free(img_data.data);

        const b64 = try multimodal.encodeBase64(allocator, img_data.data);
        errdefer allocator.free(b64);

        return .{ .image_base64 = .{
            .data = b64,
            .media_type = img_data.mime_type,
        } };
    }

    fn freeImagePart(self: *ViewTool, allocator: std.mem.Allocator, part: providers.ContentPart) void {
        _ = self;
        switch (part) {
            .image_base64 => |img| {
                allocator.free(img.data);
                // mime_type is a static string from detectMimeType, not freed
            },
            .image_url => {}, // url is borrowed from input
            .text => {}, // text is borrowed
        }
    }

    fn resolveProviderApiKey(self: *ViewTool, allocator: std.mem.Allocator) ?[]const u8 {
        _ = allocator;
        // Check configured providers for a matching entry
        for (self.configured_providers) |entry| {
            if (provider_names.providerNamesMatch(entry.name, self.view_provider)) {
                if (entry.api_key) |key| return key;
            }
        }
        return self.fallback_api_key;
    }

    fn findProviderEntry(self: *const ViewTool, provider_name: []const u8) ?ProviderEntry {
        for (self.configured_providers) |entry| {
            if (provider_names.providerNamesMatch(entry.name, provider_name)) return entry;
        }
        return null;
    }
};

fn isHttpsUrl(s: []const u8) bool {
    if (s.len < 8) return false;
    return std.ascii.eqlIgnoreCase(s[0..8], "https://");
}

fn isHttpUrl(s: []const u8) bool {
    if (s.len < 7) return false;
    return std.ascii.eqlIgnoreCase(s[0..7], "http://");
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "view tool name" {
    var vt = ViewTool{};
    const t = vt.tool();
    try std.testing.expectEqualStrings("view", t.name());
}

test "view tool description mentions vision" {
    var vt = ViewTool{};
    const t = vt.tool();
    const desc = t.description();
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, desc, "vision") != null or
        std.mem.indexOf(u8, desc, "image") != null);
}

test "view schema has image and prompt" {
    var vt = ViewTool{};
    const t = vt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "image") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "view schema has model and response_format" {
    var vt = ViewTool{};
    const t = vt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "model") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "response_format") != null);
}

test "view missing image fails" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"prompt\": \"describe\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "image") != null);
}

test "view missing prompt fails" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"/tmp/test.png\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "prompt") != null);
}

test "view empty image fails" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"\", \"prompt\": \"describe\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "view empty prompt fails" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"/tmp/test.png\", \"prompt\": \"\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "view invalid response_format fails" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"https://example.com/a.png\", \"prompt\": \"describe\", \"response_format\": \"xml\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "response_format") != null);
}

test "view http URL rejected" {
    var vt = ViewTool{};
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"http://example.com/a.png\", \"prompt\": \"describe\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "HTTP") != null or
        std.mem.indexOf(u8, result.error_msg.?, "http") != null or
        std.mem.indexOf(u8, result.error_msg.?, "HTTPS") != null);
}

test "view network disabled in tests" {
    var vt = ViewTool{
        .fallback_api_key = "test-key",
    };
    const t = vt.tool();
    const parsed = try root.parseTestArgs("{\"image\": \"https://example.com/cat.jpg\", \"prompt\": \"describe\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Network disabled in tests", result.error_msg.?);
}

test "view configured_providers stored" {
    const providers_cfg = [_]ProviderEntry{.{
        .name = "gitee-ai",
        .api_key = "test-key",
    }};
    const vt = ViewTool{
        .configured_providers = &providers_cfg,
        .view_model = "glm-5v-turbo",
    };
    try std.testing.expectEqual(@as(usize, 1), vt.configured_providers.len);
    try std.testing.expectEqualStrings("gitee-ai", vt.configured_providers[0].name);
    try std.testing.expectEqualStrings("glm-5v-turbo", vt.view_model);
}

test "view default model is kimi-k2.6" {
    const vt = ViewTool{};
    try std.testing.expectEqualStrings("kimi-k2.6", vt.view_model);
    try std.testing.expectEqualStrings("exhub", vt.view_provider);
}

test "isHttpsUrl detects https" {
    try std.testing.expect(isHttpsUrl("https://example.com/img.png"));
    try std.testing.expect(!isHttpsUrl("http://example.com/img.png"));
    try std.testing.expect(!isHttpsUrl("/tmp/img.png"));
    try std.testing.expect(!isHttpsUrl("short"));
}

test "isHttpUrl detects http" {
    try std.testing.expect(isHttpUrl("http://example.com/img.png"));
    try std.testing.expect(!isHttpUrl("https://example.com/img.png"));
    try std.testing.expect(!isHttpUrl("/tmp/img.png"));
}
