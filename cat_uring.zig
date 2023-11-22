/// This cat program uses the zig stdlib iouring abstractions.
const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;
const Allocator = mem.Allocator;
const IO_URING_DEPTH = 32;
const BUFF_SIZE = 4096;


const ReadVUserData = struct {
    iovecs: []os.iovec,
};

/// Creates sqe for the read file op
fn read_file(allocator: *Allocator, io_uring: *linux.IO_Uring, file: []const u8) !void {
    var user_data = try allocator.*.create(ReadVUserData);
    const fd = try os.open(file, os.O.RDONLY, 0o666);
    const fstat: os.Stat = try os.fstat(fd);
    var buffCount = @divFloor(fstat.size, BUFF_SIZE);
    if (@mod(fstat.size, BUFF_SIZE) != 0) {
        buffCount += 1;
    }
    var iovecs = try allocator.*.alloc(os.iovec, @intCast(buffCount));
    var bytes_remaining = fstat.size;
    var current_block: u64 = 0;
    while (bytes_remaining > 0) {
        var bytes_to_read = bytes_remaining;
        if (bytes_remaining > BUFF_SIZE) {
            bytes_to_read = BUFF_SIZE;
        }
        var buff = try allocator.*.alloc(u8, BUFF_SIZE);
        var iovec = &iovecs[current_block];
        iovec.* = .{
            .iov_base = buff.ptr,
            .iov_len = @intCast(bytes_to_read),
        };

        bytes_remaining -= bytes_to_read;
        current_block += 1;
    }
    user_data.* = ReadVUserData {
        .iovecs = iovecs,
    };
    const read_buffer: linux.IO_Uring.ReadBuffer = .{
        .iovecs = iovecs,
    };
    _ = try io_uring.read(@intFromPtr(user_data), fd, read_buffer, 0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    var io_uring = try linux.IO_Uring.init(IO_URING_DEPTH, 0);
    const fileCount = 2;
    const files: [fileCount][]const u8 = .{"test2.txt", "test.txt"};

    // enter all the sqes to read in parallel
    for (files) |file| {
        try read_file(&allocator, &io_uring, file);
    }

    // not worrying about errors
    _ = try io_uring.submit();
    
    // there are only 2 submissions, so we know we need to WAIT for 2 cqes.
    // again, ignoring errors.
    var cqes: [fileCount]linux.io_uring_cqe = undefined;
    _ = try io_uring.copy_cqes(cqes[0..], fileCount);

    for (cqes) |cqe| {
        const user_data_ptr: *ReadVUserData = @ptrFromInt(cqe.user_data);

        var bytes: u64 = 0;
        for (user_data_ptr.*.iovecs) |iovec| {
            std.debug.print("{s}", .{iovec.iov_base[0..iovec.iov_len]});
            bytes += iovec.iov_len;
        }

        std.debug.print("\ntotal bytes: {any}\n", .{bytes});
    }
}
