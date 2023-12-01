Following the "io_uring by example" article series, implementing in zig. Zig
implements liburing in it's stdlib. It's an amazing reference, and pairs very
well with the referenced articles series.

# Programs
## Synchronous cat
A cat program in zig using normal readv syscall

## Raw uring cat
The same cat program in zig using io_uring raw syscalls (i.e. no lib involved).

## Lib uring cat
The same cat program in zig using zig's io_uring library (much easier).

## Lib uring copy
A copy program in zig. Read a large file in many chunks, write to the
destination file in chunks using io_uring. It's really just an example problem
to use io_uring in a more advanced way:
1. Many submissions/completions
1. A variety of submission/completion types (readv and writev)

# Notes
This is just for my own learning, lots of bad code, but all the concepts are
there.
