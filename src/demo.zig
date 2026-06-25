//! A tiny CLI demo: `regex-demo <pattern> <input>` prints whether the pattern
//! matches, the leftmost match, and any submatches. Output goes to stderr via
//! std.debug.print to keep the demo free of the Io writer plumbing.

const std = @import("std");
const regex = @import("regex");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next(); // skip argv0
    const pattern = args.next() orelse {
        std.debug.print("usage: regex-demo <pattern> <input>\n", .{});
        return;
    };
    const input = args.next() orelse "";

    var re = regex.compile(gpa, pattern) catch |e| {
        std.debug.print("compile error: {s}\n", .{@errorName(e)});
        return;
    };
    defer re.deinit();

    std.debug.print("pattern : /{s}/\n", .{pattern});
    std.debug.print("input   : \"{s}\"\n", .{input});
    std.debug.print("match   : {}\n", .{try re.match(gpa, input)});

    if (try re.findIndex(gpa, input)) |m| {
        std.debug.print("find    : [{d},{d}) = \"{s}\"\n", .{ m.start, m.end, input[m.start..m.end] });
    } else {
        std.debug.print("find    : <no match>\n", .{});
    }

    if (try re.findSubmatch(gpa, input)) |subs| {
        defer gpa.free(subs);
        for (subs, 0..) |s, i| {
            if (s) |text| {
                std.debug.print("  group {d}: \"{s}\"\n", .{ i, text });
            } else {
                std.debug.print("  group {d}: <none>\n", .{i});
            }
        }
    }
}
