const std = @import("std");
const clap = @import("clap");

const Allocator = std.mem.Allocator;

const GetDataError = error{BadHttpResponse};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-f, --file <str>      Path to HTML file with scripts-links. Use when -l doesn't set
        \\-l, --link <str>      Link to html page - search for scripts-links at given page. Use when -f doesn't set
        \\-o, --output <str>    Output path: Ends with "/" - creates dir "scripts" at given path; Ends with name - creates dir with that name at given path.
    );

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    if (res.args.file) |f| {
        var file_data = readScriptsFromFile(allocator, f) catch |err| {
            try stderr.print("Error: can't read scripts from file - {} \n", .{err});
            return;
        };
        defer {
            for (file_data.items) |line| {
                allocator.free(line);
            }
            file_data.deinit();
        }

        removeStaticScripts(allocator, &file_data);
        getLinks(allocator, &file_data) catch |err| {
            try stderr.print("Error: can't get links from scripts - {} \n", .{err});
            return;
        };

        const fullOutputPath = generateExportDirectory(allocator, res.args.output orelse "") catch |err| {
            try stderr.print("Error: can't generate output path - {} \n", .{err});
            return;
        };
        defer allocator.free(fullOutputPath);

        downloadAndSaveFiles(allocator, file_data, fullOutputPath) catch |err| {
            try stderr.print("Error: can't download and save files - {} \n", .{err});
            return;
        };
    }
    if (res.args.link) |l| {
        var link_data = readScriptsFromLink(allocator, l) catch |err| {
            try stderr.print("Error: can't get page by link - {} \n", .{err});
            return;
        };
        defer {
            for (link_data.items) |line| {
                allocator.free(line);
            }
            link_data.deinit();
        }

        removeStaticScripts(allocator, &link_data);

        getLinks(allocator, &link_data) catch |err| {
            try stderr.print("Error: can't get links from scripts - {} \n", .{err});
            return;
        };

        const fullOutputPath = generateExportDirectory(allocator, res.args.output orelse "") catch |err| {
            try stderr.print("Error: can't generate output path - {} \n", .{err});
            return;
        };
        defer allocator.free(fullOutputPath);

        downloadAndSaveFiles(allocator, link_data, fullOutputPath) catch |err| {
            try stderr.print("Error: can't download and save files - {} \n", .{err});
            return;
        };

        //var result = try readScriptsFromLink(allocator, l);
    }
}

fn readScriptsFromFile(allocator: Allocator, file_path: []const u8) !std.ArrayList([]const u8) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var lines = std.ArrayList([]const u8).init(allocator);
    errdefer lines.deinit();

    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    var tag = std.ArrayList(u8).init(allocator);
    defer tag.deinit();
    var is_tag_open = false;

    while (true) {
        line_buffer.clearAndFree();

        reader.streamUntilDelimiter(line_buffer.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (std.mem.indexOf(u8, line_buffer.items, "<script") != null) {
            is_tag_open = true;
        }
        if (is_tag_open == true) {
            const line = try allocator.dupe(u8, line_buffer.items);
            const trim_line = std.mem.trim(u8, line, &[_]u8{ ' ', '\r', '\t', '\n' });
            try tag.appendSlice(trim_line);
            allocator.free(line);

            if (std.mem.indexOf(u8, line_buffer.items, "</") == null and std.mem.indexOf(u8, line_buffer.items, "/>") == null) {
                try tag.append(' ');
                continue;
            } else {
                is_tag_open = false;
            }
        }
        if (is_tag_open == false and tag.items.len > 0) {
            const one_liner = try allocator.alloc(u8, std.mem.replacementSize(u8, tag.items, "\n", " "));
            defer allocator.free(one_liner);

            _ = std.mem.replace(u8, tag.items, "\n", " ", one_liner);

            const trim_line = std.mem.trim(u8, one_liner, &[_]u8{ ' ', '\r', '\t', '\n' });
            const trim_copy = try allocator.dupe(u8, trim_line);
            try lines.append(trim_copy);
            tag.clearAndFree();
        }
    }

    return lines;
}

fn readScriptsFromLink(allocator: Allocator, link: []const u8) !std.ArrayList([]const u8) {
    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "X-Custom-Header", .value = "application" },
    };

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .extra_headers = headers,
        .location = .{ .url = link },
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != .ok) {
        return GetDataError.BadHttpResponse;
    }

    var response_iterator = std.mem.splitSequence(u8, response_body.items, "\n");

    var lines = std.ArrayList([]const u8).init(allocator);
    errdefer lines.deinit();

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    while (response_iterator.next()) |line| {
        if (line.len > 1 and std.mem.indexOf(u8, line, "<script") != null) {
            try line_buffer.appendSlice(line);
            while (response_iterator.next()) |inner_line| {
                if (std.mem.indexOf(u8, inner_line, "</") == null and std.mem.indexOf(u8, inner_line, "/>") == null) {
                    try line_buffer.appendSlice(inner_line);
                } else {
                    break;
                }
            }

            const one_liner = try allocator.alloc(u8, std.mem.replacementSize(u8, line_buffer.items, "\n", ""));
            defer allocator.free(one_liner);

            _ = std.mem.replace(u8, line_buffer.items, "\n", "", one_liner);
            const trim_line = std.mem.trim(u8, one_liner, &[_]u8{ ' ', '\r', '\t', '\n' });

            const trim_copy = try allocator.dupe(u8, trim_line);

            //std.debug.print("{s} \n---------\n", .{trim_copy});

            try lines.append(trim_copy);

            line_buffer.clearRetainingCapacity();
        }
    }

    return lines;
}

fn removeStaticScripts(allocator: Allocator, scripts: *std.ArrayList([]const u8)) void {
    var i: usize = 0;
    while (i < scripts.items.len) {
        if (std.mem.indexOf(u8, scripts.items[i], "http") != null and std.mem.indexOf(u8, scripts.items[i], "src") != null) {
            i += 1;
        } else {
            allocator.free(scripts.items[i]);
            _ = scripts.swapRemove(i);
        }
    }
}

fn getLinks(allocator: Allocator, scripts: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < scripts.items.len) {
        var start = std.mem.indexOf(u8, scripts.items[i], "src=");
        if (start != null) {
            start.? += 5;
        } else {
            allocator.free(scripts.items[i]);
            _ = scripts.swapRemove(i);
            continue;
        }
        var end = start.?;
        while (end < scripts.items[i].len and scripts.items[i][end] != '"' and scripts.items[i][end] != '\'') {
            end += 1;
        }

        _ = std.Uri.parse(scripts.items[i][start.?..end]) catch {
            allocator.free(scripts.items[i]);
            _ = scripts.swapRemove(i);
            continue;
        };

        const link = try allocator.dupe(u8, scripts.items[i][start.?..end]);

        allocator.free(scripts.items[i]);
        scripts.items[i] = link;

        i += 1;
    }
}

fn generateExportDirectory(allocator: Allocator, outputPath: []const u8) ![]const u8 {
    if (outputPath.len == 0) {
        std.fs.cwd().makeDir("./scripts") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                return err;
            },
        };
        return "./scripts";
    } else if (std.mem.endsWith(u8, outputPath, "/")) {
        const fullPath = try std.mem.concat(allocator, u8, &[_][]const u8{ outputPath, "scripts" });
        std.fs.cwd().makePath(fullPath) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                return err;
            },
        };
        return fullPath;
    } else {
        std.fs.cwd().makePath(outputPath) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                return err;
            },
        };
        return try allocator.dupe(u8, outputPath);
    }
}

fn downloadAndSaveFiles(allocator: Allocator, links: std.ArrayList([]const u8), outputPath: []const u8) !void {
    var dir = try std.fs.cwd().openDir(outputPath, .{});
    defer dir.close();

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "X-Custom-Header", .value = "application" },
    };

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    for (links.items) |link| {
        //std.debug.print("LINK: {s} \n---------\n", .{link});
        const response = try client.fetch(.{
            .method = .GET,
            .extra_headers = headers,
            .location = .{ .url = link },
            .response_storage = .{ .dynamic = &response_body },
        });

        if (response.status == .ok) {
            const file_name = try getFileNameFromLink(allocator, link);
            defer allocator.free(file_name);
            const file = try generateFileWithName(file_name, outputPath);
            _ = try file.write(response_body.items);

            file.close();
        }
    }
}

fn getFileNameFromLink(allocator: Allocator, link: []const u8) ![]const u8 {
    const last_slash = std.mem.lastIndexOf(u8, link, "/").? + 1;

    const file_name = try allocator.dupe(u8, link[last_slash..link.len]);
    errdefer file_name;

    return file_name;
}

fn generateFileWithName(name: []const u8, dir_path: []const u8) !std.fs.File {
    const working_dir = try std.fs.cwd().openDir(dir_path, .{});
    return working_dir.createFile(name, .{});
}
