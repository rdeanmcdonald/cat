const std = @import("std");
const os = std.os;
const mem = std.mem;
const Allocator = mem.Allocator;

const My = struct {
    field: u64,
};

fn my(allocator: *Allocator) !usize {
    var user_data = try allocator.*.create(My);
    user_data.* = My{ .field = 64 };
    return @intFromPtr(user_data);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const res = try my(&allocator);
    std.debug.print("my intPtr: {any}\n", .{res});
    const ptr: *My = @ptrFromInt(res);
    std.debug.print("my: {any}\n", .{ptr});
}
