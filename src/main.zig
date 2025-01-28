const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-f, --file <str>      Path to HTML file with scripts-links.
        \\-o, --output <str>    Output path: Ends with "/" - creates dir "scripts" at given path; Ends with name - creates dir with that name at given path.
        //\\-s, --string <str>...  An option parameter which can be specified multiple times.
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
    }
}

fn readScriptsFromFile(allocator: std.mem.Allocator, file_path: []const u8) !std.ArrayList([]const u8) {
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

fn removeStaticScripts(allocator: std.mem.Allocator, scripts: *std.ArrayList([]const u8)) void {
    var counter: usize = 0;
    for (scripts.items) |script| {
        if (std.mem.indexOf(u8, script, "https") == null) {
            allocator.free(script);
        } else {
            counter += 1;
        }
    }
    scripts.shrinkAndFree(counter);
}

fn getLinks(allocator: std.mem.Allocator, scripts: *std.ArrayList([]const u8)) !void {
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

//fn generateOutputDir(allocator: std.mem.Allocator, outputPath: )

// fn requestFileAndSave(allocator: std.mem.Allocator, link: []const u8, outputPath: null![]const u8) !void {
// }
