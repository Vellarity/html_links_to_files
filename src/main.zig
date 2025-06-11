const std = @import("std");
const clap = @import("clap");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // TODO: ADD \\-l, --link <str>      Link to html page - search for scripts-links at given page. Use when -f doesn't set
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-f, --file <str>      Path to HTML file with scripts-links. Use when -l doesn't set
        \\-o, --output <str>    Output path: Ends with "/" - creates dir "scripts" at given path; Ends with name - creates dir with that name at given path.
    );

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
        var result = try readScriptsFromFile(allocator, f);
        defer {
            for (result.items) |line| {
                allocator.free(line);
            }
            result.deinit();
        }

        removeStaticScripts(allocator, &result);
        try getLinks(allocator, &result);

        const fullOutputPath = try generateExportDirectory(allocator, res.args.output orelse "");
        defer allocator.free(fullOutputPath);

        try downloadAndSaveFiles(allocator, result, fullOutputPath);
    }
    // TODO: Add readScriptsFromLink
    // if (res.args.link) |l| {
    //     //var result = try readScriptsFromLink(allocator, l);
    // }
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

    while (true) {
        reader.streamUntilDelimiter(line_buffer.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const trim_line = std.mem.trim(u8, line_buffer.items, &[_]u8{ '\n', '\r', ' ', '\t' });
        defer line_buffer.clearRetainingCapacity();

        if (trim_line.len > 1 and std.mem.startsWith(u8, trim_line, "<script")) {
            const trim_copy = try allocator.dupe(u8, trim_line);
            try lines.append(trim_copy);
        }
    }

    return lines;
}

// TODO: Add readScriptsFromLink
// fn readScriptsFromLink(allocator: Allocator, link: []const u8) !std.ArrayList([]const u8) {

// }

fn removeStaticScripts(allocator: Allocator, scripts: *std.ArrayList([]const u8)) void {
    for (scripts.items, 0..) |script, index| {
        if (std.mem.indexOf(u8, script, "http") == null) {
            allocator.free(script);
            _ = scripts.swapRemove(index);
        }
    }
}

fn getLinks(allocator: Allocator, scripts: *std.ArrayList([]const u8)) !void {
    for (scripts.items, 0..) |script, index| {
        const start = std.mem.indexOf(u8, script, "src=").? + 5;
        var end = start;
        while (end < script.len and script[end] != '"' and script[end] != '\'') {
            end += 1;
        }
        const link = try allocator.dupe(u8, script[start..end]);
        scripts.items[index] = link;
        allocator.free(script);
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
        std.debug.print("{s}", .{fullPath});
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
    _ = allocator.ptr;

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
        std.debug.print("{s}\n", .{link});
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

    std.debug.print("{s} \n", .{link[last_slash..link.len]});

    const file_name = try allocator.dupe(u8, link[last_slash..link.len]);
    errdefer file_name;

    return file_name;
}

fn generateFileWithName(name: []const u8, dir_path: []const u8) !std.fs.File {
    const working_dir = try std.fs.cwd().openDir(dir_path, .{});
    return working_dir.createFile(name, .{});
}
