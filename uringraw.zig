// const x86_64_bits = @import("linux/x86_64.zig");
const std = @import("std");
const os = std.os;
const linux = os.linux;
const SYS = linux.SYS;
const syscall2 = linux.syscall2;
const mem = std.mem;
const Allocator = mem.Allocator;
const QUEUE_DEPTH = 1;

const Sring = struct {
    // ptr to the array of indices
    array: [*]u32,
    // ptr to the head index
    head: *u32,
    // ptr to the tail index
    tail: *u32,
    // the actual ring mask
    mask: u32,
    // ring_entries count
    entries: u32,
    // ptr to the flags
    flags: *u32,
    // sqes
    sqes: [*]linux.io_uring_sqe,
};

const Cring = struct {
    // ptr to the array of cqes
    cqes: [*]u32,
    // ptr to the head index
    head: *u32,
    // ptr to the tail index
    tail: *u32,
    // the actual ring mask
    mask: u32,
    // the ring_entries count
    entries: u32,
};

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

    // Setup will create arrs for at least QUEUE_DEPTH number of elements (I
    // think it must round up to nearest power of 2 for the masking stuff)
    var fd: os.fd_t = @intCast(syscall2(SYS.io_uring_setup, QUEUE_DEPTH, @intFromPtr(&params)));

    // that was easy! not worrying about errors
    std.debug.print("io uring fd: {any}\n", .{fd});
    std.debug.print("params after init: {any}\n", .{params});

    // The values in params offset structs are all pointers to the real
    // values. So when you see params.cqe.head=128, that's not the head index,
    // that's a ptr to the place in mem where the head index of the cqe array
    // actually is! And to increment the head idx, you must deref the head ptr,
    // then add 1. Also note, the indexes are naturally wrapping, so just keep
    // adding. To get the actual index, you mask the head index value. So deref
    // the cqe.head, mask that val, and that's your idx! Know that the arrs are
    // a power of 2 in size to allow for this.
    //
    // there's 1 file which holds allll the data. There's 3 important areas in
    // that file that need to be mmaped (shared between kernel and user space):
    //      1. sq ring - contains head/tail/etc... and importantly conatins an
    //      array pointed to by sq_off.array, which is an array of indexes into
    //      another array, the sqe array
    //      2. cq ring - pointed to by cq_off.cqes, which is an array of cqe
    //      structs
    //      3. sqes - the actual sqes array, which is not pointed to by anything
    //      returned by setup, but implicitly starts at the IORING_OFF_SQES in
    //      the file (which starts at 0x10000000 in hex or about 268 MB - 2^28 -
    //      into the file). so i guess the sq/cq rings must all fix within 268
    //      MB? mmap requres the offset into the file to be a multiple of the
    //      page size returned by sysconf(_SC_PAGE_SIZE)
    //
    // we only need 2 mmap calls for these 3 important areas
    //      1. mmap the sq/cq rings - I guess sq/cq rings are organized by
    //      kernal in such a way that we can just do 1 mmap call for both of
    //      these.
    //
    //      2. mmap the sqes array - remember, the sq array contains indexes
    //      into the actual sqes, in the zig source, there's a comment
    //      mentioning this is important for allowing user code to "preallocate
    //      static linux.io_uring_sqe entries and then replay them when needed".
    //      Not 100% sure what that means yet.

    // For the first mmap, the logic goes like this, sq ring starts at
    // sq_off.array bytes, and extends p.sq_entries*sizeof(u32). cq ring
    // starts at cq_off.cqes and extends p.cq_entries*sizeof(cqe). These two
    // arrays live in the same memory space. Either of the arrays can come
    // before the other in the memory space, so we are required to map the
    // memory starting at IORING_OFF_SQ_RING (0), out to the last byte of
    // either the sq or cq rings array (which ever order the os sets them up
    // in). I guess the kernal ensures one of them is the last piece of data
    // that is shared between kernal/user space.
    const sq_ring_last_byte = params.sq_off.array + params.sq_entries * @sizeOf(u32);
    const cq_ring_last_byte = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
    std.debug.print("sq_ring starting byte: {any}\n", .{params.sq_off.array});
    std.debug.print("sq_ring len in bytes: {any}\n", .{params.sq_entries * @sizeOf(u32)});
    std.debug.print("cq_ring starting byte: {any}\n", .{params.cq_off.cqes});
    std.debug.print("cq_ring len in bytes: {any}\n", .{params.cq_entries * @sizeOf(linux.io_uring_cqe)});
    std.debug.print("sq_ring_last_byte: {any}\n", .{sq_ring_last_byte});
    std.debug.print("cq_ring_last_byte: {any}\n", .{cq_ring_last_byte});
    const last_byte = @max(sq_ring_last_byte, cq_ring_last_byte);
    const mmap_rings = try os.mmap(null, last_byte, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.POPULATE, fd, linux.IORING_OFF_SQ_RING);
    std.debug.print("mmap_rings len: {any}\n", .{mmap_rings.len});

    // Now time to mmap the sqes themselves, which live in another place in the
    // file for some reason. These start at byte IORING_OFF_SQES (0x10000000)
    const sqes_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);
    const mmap_sqes = try os.mmap(null, sqes_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.POPULATE, fd, linux.IORING_OFF_SQES);
    std.debug.print("mmap_sqes len: {any}\n", .{mmap_sqes.len});

    // Now, we actually want pointers back for all the stuff. The mmap is a
    // slice of u8's, so we index into it by byte. We must cast from u8 into
    // the proper types. Just getting the u8 ptrs separately to make it clearer
    // for myself how getting the correct ptr type.
    const sq_ring_ptr_u8 = &mmap_rings[params.sq_off.array];
    const sq_head_ptr_u8 = &mmap_rings[params.sq_off.head];
    const sq_tail_ptr_u8 = &mmap_rings[params.sq_off.tail];
    const sq_mask_ptr_u8 = &mmap_rings[params.sq_off.ring_mask];
    const sq_entries_ptr_u8 = &mmap_rings[params.sq_off.ring_entries];
    const sq_flags_ptr_u8 = &mmap_rings[params.sq_off.flags];
    // the sqes were mmaped by themselves, from IORING_OFF_SQES to sqes_size,
    // so just get an array ptr to the beginning of the mmap slize. (note, zig
    // io_uring impl does thing a little more nicely, i.e. not passing around
    // pointers, and just using slices, but I'm following the C example.
    const sqes_ptr_u8 = &mmap_sqes[0];

    // We can't turn a *u8 into anything higher (u32), because the compiler
    // throws an error: "cast increases pointer alignment". So we need to do an
    // alignCast before the ptrCast I guess (following what zig io_uring does)
    const sring = Sring{
        .array = @ptrCast(@alignCast(sq_ring_ptr_u8)),
        .head = @ptrCast(@alignCast(sq_head_ptr_u8)),
        .tail = @ptrCast(@alignCast(sq_tail_ptr_u8)),
        .mask = @as(*u32, @ptrCast(@alignCast(sq_mask_ptr_u8))).*, // should be entries - 1
        .entries = @as(*u32, @ptrCast(@alignCast(sq_entries_ptr_u8))).*,
        .flags = @ptrCast(@alignCast(sq_flags_ptr_u8)),
        .sqes = @ptrCast(@alignCast(sqes_ptr_u8)),
    };
    std.debug.print("sring: {any}\n", .{sring});

    // Not breaking things apart for the cqes
    const cring = Cring{
        .cqes = @ptrCast(@alignCast(&mmap_rings[params.cq_off.cqes])),
        .head = @ptrCast(@alignCast(&mmap_rings[params.cq_off.head])),
        .tail = @ptrCast(@alignCast(&mmap_rings[params.cq_off.tail])),
        .entries = @as(*u32, @ptrCast(@alignCast(&mmap_rings[params.cq_off.ring_entries]))).*,
        .mask = @as(*u32, @ptrCast(@alignCast(&mmap_rings[params.cq_off.ring_mask]))).*, // entries - 1
    };
    std.debug.print("cring: {any}\n", .{cring});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    try read_and_print_file("test.txt", gpa.allocator());
}
