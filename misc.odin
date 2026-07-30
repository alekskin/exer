package main

import "core:sys/posix"

/** Writes to FD until data is exhausted */
write :: proc(fd: posix.FD, buf: [^]u8, len: uint) {
    b: [^]u8 = buf
    written: uint = 0
    for written < len {
        bytes_written := posix.write(fd, buf, len - written)
        assert(bytes_written > 0, "Failed to write")
        written += uint(bytes_written)
        b = b[written:]
    }
}

