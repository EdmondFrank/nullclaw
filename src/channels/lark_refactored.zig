    /// POST /im/v1/messages?receive_id_type=chat_id
    /// On 401, invalidates cached token and retries once.
    pub fn sendMessage(self: *LarkChannel, recipient: []const u8, text: []const u8) !void {
        const base = self.apiBase();

        // Build URL
        var url_buf: [256]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/im/v1/messages?receive_id_type=chat_id", .{base});
        const url = url_fbs.getWritten();

        // Build inner content JSON: {\"text\":\"...\"}
        var content_buf: [4096]u8 = undefined;
        var content_fbs = std.io.fixedBufferStream(&content_buf);
        const cw = content_fbs.writer();
        try cw.writeAll("{\"text\":");
        try root.appendJsonStringW(cw, text);
        try cw.writeAll("}");
        const content_json = content_fbs.getWritten();

        // Build outer body JSON
        var body_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const w = fbs.writer();
        try w.writeAll("{\"receive_id\":\"");
        try w.writeAll(recipient);
        try w.writeAll("\",\"msg_type\":\"text\",\"content\":");
        // Escape the content JSON string for embedding
        try root.appendJsonStringW(w, content_json);
        try w.writeAll("}");
        const body = fbs.getWritten();

        // Retry up to 3 times
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            log.info("Lark send attempt {d}/3", .{attempt + 1});

            const result = self.trySendOnce(url, body, attempt + 1);
            switch (result) {
                .success => return,
                .should_retry => {
                    if (attempt < 2) {
                        std.Thread.sleep(1000 * 1000 * 1000); // 1 second delay
                    }
                    continue;
                },
                .fatal_error => return error.LarkApiError,
            }
        }

        log.err("All 3 attempts failed, giving up", .{});
        return error.LarkApiError;
    }

    const SendResult = enum {
        success,
        should_retry,
        fatal_error,
    };

    /// Try to send message once. Handles token lifecycle internally.
    fn trySendOnce(self: *LarkChannel, url: []const u8, body: []const u8, attempt_num: u8) SendResult {
        // Get fresh token for this attempt
        const token = self.getTenantAccessToken() catch |err| {
            log.err("Failed to get tenant access token on attempt {d}: {}", .{attempt_num, err});
            return .should_retry;
        };
        defer self.allocator.free(token);

        // Build auth header
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Bearer {s}", .{token}) catch return .fatal_error;
        const auth_value = auth_fbs.getWritten();

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const send_result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
                .{ .name = "Authorization", .value = auth_value },
            },
        }) catch |err| {
            log.err("Lark API POST failed on attempt {d}: {}", .{attempt_num, err});
            log.err("Request details - URL: {s}", .{url});
            log.err("Request details - Body: {s}", .{body});
            log.err("Request details - Auth: {s}", .{auth_value});
            return .should_retry;
        };

        if (send_result.status == .ok) {
            log.info("Lark message sent successfully on attempt {d}", .{attempt_num});
            return .success;
        }

        // Handle non-OK status
        if (send_result.status == .unauthorized) {
            log.warn("Lark token expired (401) on attempt {d}, invalidating token", .{attempt_num});
            self.invalidateToken();
        } else {
            log.err("Lark API POST returned status {d} on attempt {d}", .{@intFromEnum(send_result.status), attempt_num});
            log.err("Response details - Status: {}", .{send_result.status});
            log.err("Response details - URL: {s}", .{url});
            log.err("Response details - Body: {s}", .{body});
            log.err("Response details - Auth: {s}", .{auth_value});
        }

        return .should_retry;
    }
