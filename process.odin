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
        case: handle_parent(pid)
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

    cmd := []cstring{"sleep", "1", nil}
    ret := posix.execvp(cmd[0], raw_data(cmd))
    fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))
}

handle_parent :: proc(pid: posix.pid_t) {
    for {
        status: i32
        wpid := posix.waitpid(pid, &status, {})
        assert(wpid != -1, "waitpid failure")

        switch {
        case posix.WIFEXITED(status):
            fmt.printfln("child exited, status=%v", posix.WEXITSTATUS(status))
        case posix.WIFSIGNALED(status):
            fmt.printfln("child killed (signal %v)", posix.WTERMSIG(status))
        case posix.WIFSTOPPED(status):
            fmt.printfln("child stopped (signal %v", posix.WSTOPSIG(status))
        case posix.WIFCONTINUED(status):
            fmt.println("child continued")
        case:
            // Should never happen.
            fmt.println("unexpected status (%x)", status)
        }

        if posix.WIFEXITED(status) || posix.WIFSIGNALED(status) {
            break
        }
    }
}
