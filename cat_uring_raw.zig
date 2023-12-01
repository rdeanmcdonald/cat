/// This is the cat program using io_uring to perform the read syscall. It's
/// not using any lib support, so all the io_uring stuff is as raw as it gets!
/// Which means it is quite cumbersome, but just awesome to see it all laid out
/// In cat_uring.zig we use zig's implementation of liburing, which makes
/// things way nicer (but hides a lot of what is going on with io_uring
/// interface).
///
/// This is just for my personal education about zig and io_uring, so it's
/// mostly laid out in very careless/excessive ways so I can come back to it
/// and understand what I was thinking.
const std = @import("std");
const os = std.os;
const linux = os.linux;
const SYS = linux.SYS;
const syscall2 = linux.syscall2;
const syscall6 = linux.syscall6;
const mem = std.mem;
const Allocator = mem.Allocator;
const QUEUE_DEPTH = 1;
const BUFF_SIZE = 4096;

const ReadVUserData = struct {
    /// ptr to array of iovec
    iovecs: []os.iovec,
};

const Sring = struct {
    /// ptr to the array of indices
    array: [*]u32,
    /// ptr to the head index
    head: *u32,
    /// ptr to the tail index
    tail: *u32,
    /// the actual ring mask
    mask: u32,
    /// ring_entries count
    entries: u32,
    /// flags
    flags: u32,
    /// ptr to the array of sqes
    sqes: [*]linux.io_uring_sqe,
};

const Cring = struct {
    // ptr to the array of cqes
    cqes: [*]linux.io_uring_cqe,
    // ptr to the head index
    head: *u32,
    // ptr to the tail index
    tail: *u32,
    // the actual ring mask
    mask: u32,
    // the ring_entries count
    entries: u32,
};

const IoUring = struct {
    sring: *Sring,
    cring: *Cring,
    fd: os.fd_t,
};

// Not worrying about cleaning up memory, since the program exits after reading
// and printing
fn io_uring_setup(allocator: *Allocator) !IoUring {
    // set io uring params fields to 0. since linux.io_uring_params struct
    // provides no defaults, the fields all default to 0. to override a specific
    // field in the struct to non-zero, just add it to the .{} arg the value you
    // want it to init to... eg:
    // var params = mem.zeroInit(linux.io_uring_params, .{
    //     .flags = flags,
    //     .sq_thread_idle = 1000,
    // });
    var params = mem.zeroInit(linux.io_uring_params, .{});

    // Setup will create arrs for at least QUEUE_DEPTH number of elements (must
    // round the sq/cq size up to nearest power of 2 for the masking stuff)
    const fd: os.fd_t = @intCast(syscall2(SYS.io_uring_setup, QUEUE_DEPTH, @intFromPtr(&params)));

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
    // There's 1 file which holds allll the data. There's 3 important areas in
    // that file that need to be mmaped (shared between kernel and user space):
    //      1. sq ring - contains head/tail/etc... and importantly conatins an
    //      array pointed to by sq_off.array, which is an array of indexes into
    //      another array, the sqe array
    //      2. cq ring - again contains head/tail/etc... and an array pointed
    //      to by cq_off.cqes, which is an array of cqe structs
    //      3. sqes - the actual sqes array, which is not pointed to by anything
    //      returned by setup, but implicitly starts at the IORING_OFF_SQES in
    //      the file (which starts at 0x10000000 in hex or about 268 MB - 2^28 -
    //      into the file). so i guess the sq/cq rings must all fix within 268
    //      MB? mmap requres the offset into the file to be a multiple of the
    //      page size returned by sysconf(_SC_PAGE_SIZE)
    //
    // we only need 2 mmap calls for these 3 important areas
    //      1. mmap the sq/cq rings - I guess sq/cq rings are organized by the
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
    // arrays live in the same mapped memory space. Either of the arrays can
    // come before the other in the memory space, so we are required to map the
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
    // io_uring impl does things a little more nicely, i.e. not passing around
    // pointers, and just using slices, but I'm following the C example.
    const sqes_ptr_u8 = &mmap_sqes[0];

    // We can't turn a *u8 into anything higher (u32), because the compiler
    // throws an error: "cast increases pointer alignment". So we need to do an
    // alignCast before the ptrCast I guess (following what zig io_uring does).
    // Also, we need to alloc, otherwise the mem where the sring lives (stack
    // frame of the function)
    const sring = try allocator.create(Sring);
    sring.*.array = @ptrCast(@alignCast(sq_ring_ptr_u8));
    sring.*.head = @ptrCast(@alignCast(sq_head_ptr_u8));
    sring.*.tail = @ptrCast(@alignCast(sq_tail_ptr_u8));
    sring.*.mask = @as(*u32, @ptrCast(@alignCast(sq_mask_ptr_u8))).*; // should be entries - 1
    sring.*.entries = @as(*u32, @ptrCast(@alignCast(sq_entries_ptr_u8))).*;
    sring.*.flags = @as(*u32, @ptrCast(@alignCast(sq_flags_ptr_u8))).*;
    sring.*.sqes = @ptrCast(@alignCast(sqes_ptr_u8));
    std.debug.print("sring: {any}\n", .{sring});
    std.debug.print("sring head: {any}\n", .{sring.*.head.*});
    std.debug.print("sring tail: {any}\n", .{sring.*.tail.*});

    // Not breaking things apart for the cqes
    const cring = try allocator.create(Cring);
    cring.*.cqes = @ptrCast(@alignCast(&mmap_rings[params.cq_off.cqes]));
    cring.*.head = @ptrCast(@alignCast(&mmap_rings[params.cq_off.head]));
    cring.*.tail = @ptrCast(@alignCast(&mmap_rings[params.cq_off.tail]));
    cring.*.entries = @as(*u32, @ptrCast(@alignCast(&mmap_rings[params.cq_off.ring_entries]))).*;
    cring.*.mask = @as(*u32, @ptrCast(@alignCast(&mmap_rings[params.cq_off.ring_mask]))).*; // entries - 1
    std.debug.print("cring: {any}\n", .{cring});

    return .{ .sring = sring, .cring = cring, .fd = fd };
}

fn submit_read(file_path: []const u8, allocator: *Allocator, io_uring: *IoUring) !void {
    // Here we perform our "read" using io_uring. The read will work much the
    // same as it did in the sync.zig example, we'll perpare the iovec
    // structures and underlying buffers, then rather than performing our readv
    // syscall, we fill in an sqe for the io_uring IORING_OP_READV operation.
    // First, like in sync, create a file description entry
    const fd = try os.open(file_path, os.O.RDONLY, 0o666);
    const fstat: os.Stat = try os.fstat(fd);

    // Now, produce an array of iovecs, each containing a buf of BUFF_SIZE.
    // Given the file size, how many buffers do we need?
    var buffCount = @divFloor(fstat.size, BUFF_SIZE);
    // If not evenly divisible into buff_size, need to add one
    if (@mod(fstat.size, BUFF_SIZE) != 0) {
        buffCount += 1;
    }
    std.debug.print("buffCount: {any}\n", .{buffCount});
    std.debug.print("file size: {any}\n", .{fstat.size});

    // Now alloc all the iovecs
    const iovecs: []os.iovec = try allocator.*.alloc(os.iovec, @intCast(buffCount));

    // Now alloc all the buffs and put them in the iovec. Again, being lazy
    // about deallocating, since this cat program will just exit when done
    // anyways.
    for (iovecs) |*iovec| {
        const buff = try allocator.*.alloc(u8, BUFF_SIZE);

        iovec.*.iov_len = buff.len;
        iovec.*.iov_base = buff.ptr;
    }

    std.debug.print("iovecs: {any}\n", .{iovecs});

    // Ok! Now we have all we need to fill in an SQE, then submit that to the
    // io_uring. First "get" a vacant sqe from io_uring, fill it in, then
    // "enter" it into io_uring. By vacant I just mean the next sqe in the
    // array that hasn't been submitted yet, aka the sqe pointed at by the tail
    // index of the sqes is the one we need to get a hold of. Userspace is the
    // only "writer" to the tail index. So reading the tail requires nothing
    // special.
    // - Technically, you'd want to see if the queue is full, but this is just
    // a one and done use of the ring, and we control the QUEUE_DEPTH (i.e
    // won't write to a full queue, in other words, we have 1 readv call to
    // make, and a QUEUE_DEPTH of 1), so not worrying about it right now. Also
    // reading the head requires atomicLoad, since it's written to by the
    // kernal thread, so we'd need the latest update to the head. And just for
    // my own recollection, there is nothing to guarantee that after we load
    // the head that it's not updated by the kernal, however, having a slightly
    // stale head value would only cause our thead to think the queue is full
    // when it technically isn't, so it's not detrimental, "conservative",
    // better than using a lock to ensure a totally correct value for the head)
    const tail = io_uring.*.sring.*.tail.*;
    std.debug.print("current tail?: {any}\n", .{io_uring.*.sring.*.tail.*});
    const next_tail = tail + 1;
    const sqe_idx = tail & io_uring.*.sring.*.mask;
    const sqe: *linux.io_uring_sqe = &io_uring.*.sring.*.sqes[sqe_idx];

    // Now the "user_data". Technically, here we're only making one io_uring
    // submission, so we know what we're getting out on the cq side, but might
    // as well set the following up since it's so easy. On the cqe size, how do
    // we know the number of iovecs submitted with the readv? We need to setup
    // a structure which holds some relevant info, so on the cq side we can do
    // what we need with the filled in iovec buffs, namely print the buffs to
    // stdout. Again, must alloc, so it can be valid outside the scope of the
    // stack.
    const user_data = try allocator.*.create(ReadVUserData);
    user_data.* = ReadVUserData{ .iovecs = iovecs };
    sqe.* = .{
        .opcode = linux.IORING_OP.READV,
        .flags = 0,
        .ioprio = 0,
        .fd = fd,
        .off = 0,
        .addr = @intFromPtr(iovecs.ptr),
        .len = @as(u32, @intCast(iovecs.len)),
        .rw_flags = 0,
        .user_data = @intFromPtr(user_data),
        // not sure what the rest do
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .resv = 0,
    };

    // now update the sq_ring array, which is an array of indecies into the
    // actual sqe array. remember, the tail is an index into the sq_ring array,
    // which contains the index into the sqe array, which is just tail
    // (masked!)
    io_uring.*.sring.*.array[sqe_idx] = sqe_idx;
    std.debug.print("vacant sqe: {any}\n", .{sqe});

    // now, update the sq_ring tail, to point to the next vacant sqe (note,
    // this is just for our thread to know the tail is updated. later we will
    // atomically load the tail, so the kernal gets the latest tail. not doing
    // it now just to show that perhaps you would fill in multiple sqes before
    // "entering" them to the kernal. At the moment of entering, you would do
    // the atomic load. This way the kernal would see multiple new sqes to act
    // on.)
    // io_uring.*.sring.*.tail.* = next_tail;
    // @atomicStore(u32, io_uring.*.sring.*.tail.*, next_tail, .Release);

    // Since we're just doing 1 readv operation, we can finally submit the
    // read! First make sure the kernal has an updated view of the tail, and
    // then perform the "enter" syscall.
    @atomicStore(u32, io_uring.*.sring.*.tail, next_tail, .Release);
    std.debug.print("new tail?: {any}\n", .{io_uring.*.sring.*.tail.*});
    const to_submit = 1;
    const flags = linux.IORING_ENTER_GETEVENTS;
    // With flags set to what we have, this tells the syscall to wait till 1
    // sqe is complete, so we can proceed after it returns to process a filled
    // in cqe.
    const min_complete = 1;
    // Not too sure what these next 2 are, but the example sets them to this
    const sig: ?*os.sigset_t = null;
    const sz = 0;
    const ios_consumed = syscall6(SYS.io_uring_enter, @as(usize, @bitCast(@as(isize, io_uring.*.fd))), to_submit, min_complete, flags, @intFromPtr(sig), sz);
    // syscall6(.io_uring_enter, @as(usize, @bitCast(@as(isize, fd))), to_submit, min_complete, flags, @intFromPtr(sig), NSIG / 8);
    std.debug.print("ios_consumed: {any}\n", .{ios_consumed});
}

fn consume_completion_and_print(allocator: *Allocator, io_uring: *IoUring) !void {
    _ = allocator;
    // Now that the submition has been made (with the configuration to wait for
    // the completion before returning), we can get the cqe, get the user_data,
    // get the iovecs (which should now be all filled in), and print the filled
    // in buffs to stdout.
    //
    // First, get the completed cqe (again not trying to be robust or anything
    // just assume everything worked). Remember, with the cq side, we write the
    // head, and kernal writes the tail, so head reads do not need to be atomic
    // (since our code only runs in 1 thread), but tail reads need to be
    // atomic, and head writes should be atomic when we're ready to let the
    // kernal know about them.
    const head = io_uring.*.cring.*.head.*;
    const ready_cqes = @atomicLoad(u32, io_uring.*.cring.*.tail, .Acquire) - head;
    std.debug.print("ready_cqes: {any}\n", .{ready_cqes});
    const tail = io_uring.*.cring.*.tail.*;
    std.debug.print("head: {any}\n", .{head});
    std.debug.print("tail: {any}\n", .{tail});
    const cqe_idx = head & io_uring.*.cring.*.mask;
    std.debug.print("cqe_idx: {any}\n", .{cqe_idx});
    const cqe = io_uring.*.cring.*.cqes[cqe_idx];
    std.debug.print("cqe: {any}\n", .{cqe});
    // now in theory we should update the head but we're not submitting more
    // than one sqe so forgetting about it

    // now that we have the cqe, we can get the user_data struct, get the
    // iovecs, and print all the data :tada:
    const user_data_ptr: *ReadVUserData = @ptrFromInt(cqe.user_data);
    const iovecs = user_data_ptr.*.iovecs;
    for (iovecs) |iovec| {
        // write each byte to stdout!
        std.debug.print("{s}", .{iovec.iov_base[0..iovec.iov_len]});
    }
}

fn read_and_print_file(file_path: []const u8, allocator: *Allocator) !void {
    var io_uring = try io_uring_setup(allocator);
    const head = io_uring.cring.*.head.*;
    const tail = io_uring.cring.*.tail.*;
    std.debug.print("cring head: {any}\n", .{head});
    std.debug.print("cring tail: {any}\n", .{tail});
    std.debug.print("starting io_uring: {any}\n", .{io_uring});

    // With io_uring set up, we can nowwe'll perform an io_uring submission, and
    // then consume the io_uring for the corresponding completion.
    try submit_read(file_path, allocator, &io_uring);
    try consume_completion_and_print(allocator, &io_uring);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    try read_and_print_file("test_file_small.txt", &allocator);
}
