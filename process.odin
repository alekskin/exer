package main

import "core:fmt"
import "core:sys/posix"

create_child_process :: proc() {
    master_fd := posix.posix_openpt({.RDWR, .NOCTTY})
    assert(master_fd != -1, "Failed to open master PT")
    defer assert(posix.close(master_fd) == .OK, "Failed to close master fd from child")

    assert(posix.grantpt(master_fd) == .OK, "Failed to grant slave access to PT")
    assert(posix.unlockpt(master_fd) == .OK, "Failed to unlock master PT")

    pt_name := posix.ptsname(master_fd)
    assert(pt_name != nil, "Failed to get slave PT name")

    switch pid := posix.fork(); pid {
        case -1: panic("Failed to fork process")
        case 0: handle_child(master_fd, pt_name)
        case: handle_parent(pid, master_fd)
    }
}

handle_child :: proc(master_fd: posix.FD, pt_name: cstring) {
    sid := posix.setsid()
    if sid == -1 {
        panic("Failed to set id on child process")
    }

    slave_fd := posix.open(pt_name, {.RDWR, .NOCTTY})
    if slave_fd == -1 {
        panic("Failed to open slave PT")
    }

    assert(posix.dup2(slave_fd, posix.STDIN_FILENO) != -1, "Failed to route STDIN")
    assert(posix.dup2(slave_fd, posix.STDOUT_FILENO) != -1, "Failed to route STDOUT")
    assert(posix.dup2(slave_fd, posix.STDERR_FILENO) != -1, "Failed to route STDERR")
    assert(posix.close(master_fd) == .OK, "Failed to close master fd from child")
    assert(posix.close(slave_fd) == .OK, "Failed to close slave fd from child")

    cmd := []cstring{"sh", nil}
    ret := posix.execvp(cmd[0], raw_data(cmd))
    fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))
}

handle_parent :: proc(pid: posix.pid_t, master_fd: posix.FD) {
    fds := [?]posix.pollfd{
        {
            fd = master_fd,
            events = { .IN, .HUP },
            revents = {},
        },
        {
            fd = posix.STDIN_FILENO,
            events = { .IN },
            revents = {},
        },
    }

    buf_arr := [1024 * 4]u8{}
    buf := buf_arr[:]

    event_loop: for {
        ready := posix.poll(raw_data(fds[:]), 2, -1)
        assert(ready != -1, "Error occured during poll")

        for fd in fds {
            if fd.revents == {} {
                continue
            }

            if .HUP in fd.revents {
                break event_loop
            }

            bytes_read := posix.read(fd.fd, raw_data(buf), len(buf))
            assert(bytes_read > -1, "Error while reading bytes")

            switch fd.fd {
            case master_fd: {
                bytes_written := posix.write(posix.STDOUT_FILENO, raw_data(buf), uint(bytes_read))
                assert(bytes_written > -1, "Error while writing to stdout")
            }

            case posix.STDIN_FILENO: {
                bytes_written := posix.write(master_fd, raw_data(buf), uint(bytes_read))
                assert(bytes_written > -1, "Error while writing to stdout")
            }
            case: fmt.println("Unknown FD")
            }
        }

        // status: i32
        // wpid := posix.waitpid(pid, &status, {})
        // assert(wpid != -1, "waitpid failure")
        // if posix.WIFEXITED(status) || posix.WIFSIGNALED(status) {
        //     break
        // }
    }

    // for {
    //
    //     switch {
    //     case posix.WIFEXITED(status):
    //         fmt.printfln("child exited, status=%v", posix.WEXITSTATUS(status))
    //     case posix.WIFSIGNALED(status):
    //         fmt.printfln("child killed (signal %v)", posix.WTERMSIG(status))
    //     case posix.WIFSTOPPED(status):
    //         fmt.printfln("child stopped (signal %v", posix.WSTOPSIG(status))
    //     case posix.WIFCONTINUED(status):
    //         fmt.println("child continued")
    //     case:
    //         // Should never happen.
    //         fmt.println("unexpected status (%x)", status)
    //     }
    //
    //     if posix.WIFEXITED(status) || posix.WIFSIGNALED(status) {
    //         break
    //     }
    // }
}
