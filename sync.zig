const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const BLOCK_SIZE = 4096;

fn read_and_print_file(file_path: []const u8, allocator: Allocator) !void {
    std.debug.print("Reading file {s}\n", .{file_path});

    const mode: std.os.mode_t = 0o666;
    const fd: std.os.fd_t = try std.os.open(file_path, std.os.O.RDONLY, mode);
    const fstat: std.os.Stat = try std.os.fstat(fd);
    const size: std.os.off_t = fstat.size;
    var blocks: usize = @divFloor(std.math.absCast(size), @as(usize, BLOCK_SIZE));
    // make sure we have enough blocks since we round down above
    if (@mod(size, BLOCK_SIZE) != 0) {
        blocks += 1;
    }
    std.debug.print("fd {any}\n", .{fd});
    std.debug.print("size {any}\n", .{size});
    std.debug.print("blocks {any}\n", .{blocks});

    // the way readv works, it puts the file into an array of iovec's, each
    // iovec points to a BLOCK_SIZE of data from the file
    var iovecs: []std.os.iovec = try allocator.alloc(std.os.iovec, blocks);

    // now, each iovec will hold a pointer to BLOCK_SIZE of bytes, so alloc the
    // propper number of BLOCK_SIZE buffers, and fill in the empty iovecs
    // buffer ptr.
    var bytes_remaining: std.os.off_t = size;
    var current_block: usize = 0;
    while (bytes_remaining > 0) {
        var bytes_to_read = bytes_remaining;
        if (bytes_to_read > BLOCK_SIZE) {
            bytes_to_read = BLOCK_SIZE;
        }

        var buff: []u8 = try allocator.alloc(u8, std.math.absCast(bytes_to_read));

        iovecs[current_block].iov_base = buff.ptr;
        iovecs[current_block].iov_len = std.math.absCast(bytes_to_read);

        bytes_remaining -= bytes_to_read;
        current_block += 1;
    }

    // ok! were ready for readv syscall, which will block until all the iovec
    // bufs are filled in
    const res = try std.os.readv(fd, iovecs);
    std.debug.print("BYTES READ: {any}\n", .{res});

    // finally, we can now print all the bufs to stdout
    for (iovecs) |iovec| {
        std.debug.print("{s}\n", .{iovec.iov_base[0..iovec.iov_len]});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    try read_and_print_file("test.txt", gpa.allocator());
    try read_and_print_file("test2.txt", gpa.allocator());
}
