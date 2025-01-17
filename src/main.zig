const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-f, --file <str>       Path to HTML file with scripts-links.
        //\\-s, --string <str>...  An option parameter which can be specified multiple times.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        std.debug.print("--help\n", .{});
    if (res.args.file) |f| {
        const result = try parseFile(allocator, f);
        defer result.deinit();
        std.debug.print("lines = {}\n", .{result.items.len});
    }
}

fn parseFile(allocator: std.mem.Allocator, filePath: []const u8) !std.ArrayListAligned([]u8, null) {
    const file = try std.fs.cwd().openFile(filePath, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var result = std.ArrayList([]u8).init(allocator);

    var line = std.ArrayList(u8).init(allocator);
    defer line.deinit();

    const writer = line.writer();
    var line_no: usize = 0;
    while (reader.streamUntilDelimiter(writer, '\n', null)) {
        // Clear the line so we can reuse it.
        line_no += 1;

        std.debug.print("{d}--{s}\n", .{ line_no, line.items });
        try result.append(line.items);
        line.clearRetainingCapacity();
    } else |err| switch (err) {
        error.EndOfStream => { // end of file
            if (line.items.len > 0) {
                line_no += 1;
                std.debug.print("{d}--{s}\n", .{ line_no, line.items });
            }
        },
        else => return err, // Propagate error
    }

    return result;
}
