// const x86_64_bits = @import("linux/x86_64.zig");
const std = @import("std");
const os = std.os;
const linux = os.linux;
const SYS = linux.SYS;
const syscall2 = linux.syscall2;
const mem = std.mem;
const Allocator = mem.Allocator;
const QUEUE_DEPTH = 1;

fn read_and_print_file(file_path: []const u8, allocator: Allocator) !void {
    _ = allocator;
    _ = file_path;

    // setup iouring
    // set io uring params fields to 0. since linux.io_uring_params struct
    // provides no defaults, the fields all default to 0. to override a specific
    // field in the struct to non-zero, just add it to the .{} arg the value you
    // want it to init to... eg:
    // var params = mem.zeroInit(linux.io_uring_params, .{
    //     .flags = flags,
    //     .sq_thread_idle = 1000,
    // });
    var params = mem.zeroInit(linux.io_uring_params, .{});
    std.debug.print("sizeof cqe: {}\n", .{@sizeOf(linux.io_uring_cqe)});
    std.debug.print("MASK: {}\n", .{64 & 256});
    // Setup will create arrs for at least QUEUE_DEPTH number of elements (I
    // think it must round up to nearest power of 2 for the masking stuff)
    var fd = syscall2(SYS.io_uring_setup, QUEUE_DEPTH, @intFromPtr(&params));
    std.debug.print("io uring fd: {any}\n", .{fd});
    // NOTE: the values in params offset structs are all pointers to the real
    // values. So when you see params.cqe.head=128, that's not the head index,
    // that's a ptr to the place in mem where the head index of the cqe array
    // actually is! And to increment the head idx, you must deref the head ptr,
    // then add 1.
    std.debug.print("params after init: {any}\n", .{params});

    // that was easy! not worrying about errors :shrug:
    //
    // now, we need to mmap the sq and cq ring buffers. there's 1 file for
    // io_uring, so both buffers live in there. the sq ring and cq ring have a
    // ptr to the begining of the array returned from the setup syscall. So to
    // mmap enough memory, take the higher of the the following:
    //      cq_cqes-ptr + sizeof(cqe struct)*num-of-cqe's
    //      sq_array-ptr + sizeof(u32)
    //
    // remember, a ptr is just a memory addr, and taken as an integer is a
    // number of bytes, and we know the 0 addr is the beginning of the file, so
    // the total size of mmap must add the offset of the beginning of the array.
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    try read_and_print_file("test.txt", gpa.allocator());
}
