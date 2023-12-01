/// This is a file copy program using io_uring. The main idea is to just use
/// io_uring for many submisions and many completions. I'm attempting to write
/// this program with mostly my own knowledge, having gone through the last 3
/// examples of sync cat, raw uring cat, and zig uring cat. The problem and
/// solution concept come from "io_uring by example" article series. The idea
/// is this, given a RING_DEPTH, keep the io_uring sqe queue as full as
/// possible until the entire file is copied. So, we'll be adding as many reads
/// to the sqe as we can, then reading any available completed reads, and
/// submitting as many writes as possible, and on an on until we're done. This
/// presupposes that we read and write in chunks (16kb in the article). This is
/// the general concept from the article. There may be more interesting things
/// we could do to maximize throughput, but I'm just going to follow the
/// general idea from the article because it's a really nice example leveraging
/// io_uring for many submits and many completions.
const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;
const Allocator = mem.Allocator;
const RING_DEPTH = 16;
const BUFF_SIZE = 4 * 1024;
const CHUNK_SIZE = 16 * 1024;

const UserData = struct {
    off: u64,
    bytes: u64,
    iovecs: []os.iovec,
    // It was annoying trying to convert []os.iovec to this type for the writev
    // calls, I'm sure there's a way but I'm being lazy and just doing this
    iovecs_const: []const os.iovec_const,
    is_read: bool,
};

fn create_user_data(allocator: *Allocator, off: u64, bytes: u64) !*UserData {
    const user_data = try allocator.create(UserData);

    var buff_cnt = @divFloor(bytes, BUFF_SIZE);
    if (@mod(bytes, BUFF_SIZE) != 0) {
        buff_cnt += 1;
    }
    const iovecs = try allocator.alloc(os.iovec, buff_cnt);
    const iovecs_const = try allocator.alloc(os.iovec_const, buff_cnt);
    var bytes_remaining: u64 = bytes;
    var i: u64 = 0;
    while (bytes_remaining > 0) {
        var bytes_prepped = bytes_remaining;
        if (bytes_prepped > BUFF_SIZE) {
            bytes_prepped = BUFF_SIZE;
        }
        const buffs = try allocator.alloc(u8, bytes_prepped);
        const iovec = &iovecs[i];
        const iovec_const = &iovecs_const[i];
        iovec.* = .{
            .iov_base = buffs.ptr,
            .iov_len = @intCast(bytes_prepped),
        };
        iovec_const.* = .{
            .iov_base = buffs.ptr,
            .iov_len = @intCast(bytes_prepped),
        };
        i += 1;
        bytes_remaining -= bytes_prepped;
    }
    user_data.* = UserData{
        .off = off,
        .bytes = bytes,
        .iovecs = iovecs,
        .iovecs_const = iovecs_const,
        .is_read = true,
    };

    return user_data;
}

fn copy(allocator: *Allocator, ring: *linux.IO_Uring, src: []const u8, dst: []const u8) !void {
    const sqe_len = ring.sq.sqes.len;
    const src_fd = try os.open(src, os.O.RDONLY, 0o666);
    const dst_fd = try os.open(dst, os.O.WRONLY | os.O.CREAT, 0o666);
    _ = try os.ftruncate(dst_fd, 0);
    const src_stats: os.Stat = try os.fstat(src_fd);
    const total_bytes = src_stats.size;
    var total_reads = @divFloor(total_bytes, CHUNK_SIZE);
    if (@mod(total_bytes, CHUNK_SIZE) != 0) {
        total_reads += 1;
    }
    var read_bytes_submitted: u64 = 0;
    var bytes_read: u64 = 0;
    var write_bytes_submitted: u64 = 0;
    var bytes_written: u64 = 0;
    var total_cqes: u64 = 0;
    var total_sqes: u64 = 0;
    while (bytes_read < total_bytes or bytes_written < total_bytes) {
        if (read_bytes_submitted < total_bytes) {
            const sqes_ready = ring.sq_ready();
            var to_read = sqe_len - sqes_ready;
            while (to_read > 0 and read_bytes_submitted < total_bytes) {
                var bytes_remaining = @as(u64, @intCast(total_bytes)) - read_bytes_submitted;
                if (bytes_remaining > CHUNK_SIZE) {
                    bytes_remaining = CHUNK_SIZE;
                } else {
                    to_read = 1;
                }

                const user_data = try create_user_data(allocator, read_bytes_submitted, bytes_remaining);
                const read_buffer: linux.IO_Uring.ReadBuffer = .{
                    .iovecs = user_data.iovecs,
                };
                _ = try ring.read(@intFromPtr(user_data), src_fd, read_buffer, user_data.off);
                total_sqes += 1;
                to_read -= 1;
                read_bytes_submitted += bytes_remaining;
            }
            _ = try ring.submit();
        }
        var cqes_ready = ring.cq_ready();
        const sqes_ready = ring.sq_ready();
        var to_write = sqe_len - sqes_ready;
        while (cqes_ready != 0 and to_write != 0) {
            const cqe = try ring.copy_cqe();
            cqes_ready -= 1;
            total_cqes += 1;
            const user_data_ptr = cqe.user_data;
            const user_data: *UserData = @ptrFromInt(user_data_ptr);
            if (user_data.bytes != cqe.res) {
                // Not handling this but is nice to know if it happens
                std.debug.print("partial io!!\nread?: {any}\nsubmitted: {any}\ncompleted: {any}\n", .{ user_data.is_read, user_data.bytes, cqe.res });
            }
            if (user_data.is_read) {
                bytes_read += @intCast(cqe.res);

                const is_read = &user_data.*.is_read;
                is_read.* = false;
                _ = try ring.writev(@intFromPtr(user_data), dst_fd, user_data.iovecs_const, user_data.off);
                to_write -= 1;
                write_bytes_submitted += user_data.bytes;
            } else {
                bytes_written += @intCast(cqe.res);
            }
        }
        if (ring.sq_ready() > 0) {
            _ = try ring.submit();
        }
        // std.debug.print("total_reads: {any}\n", .{total_reads});
        // std.debug.print("read_bytes_submitted: {any}\n", .{read_bytes_submitted});
        // std.debug.print("bytes_read: {any}\n", .{bytes_read});
        // std.debug.print("write_bytes_submitted: {any}\n", .{write_bytes_submitted});
        // std.debug.print("bytes_written: {any}\n", .{bytes_written});
        // std.debug.print("total_sqes: {any}\n", .{total_sqes});
        // std.debug.print("total_cqes: {any}\n", .{total_cqes});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    var ring = try linux.IO_Uring.init(RING_DEPTH, 0);

    _ = try copy(&allocator, &ring, "test2.txt", "result.txt");
}
