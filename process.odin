package main

import "core:fmt"
import "core:sys/posix"
import "core:sys/linux"
import "core:mem"
import "core:os"
import "core:strings"
import "base:runtime"

log_file: ^os.File

create_logfile :: proc() {
    f, err := os.open(
        "/tmp/mux.log",
        os.File_Flags{ .Create, .Write, .Append, .Trunc },
        os.Permissions{.Execute_User, .Write_User, .Read_User, .Read_Group, .Read_Other}
    )
    if err != nil {
        fmt.eprintln("Error:", err)
    }
    assert(err == nil, "Failed to create logfile")
    log_file = f
}


create_child_process :: proc() {
    create_logfile()
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

// get win size
TIOCGWINSZ :: 0x5413
// set win size
TIOCSWINSZ :: 0x5414

winsize :: struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16
};

LEADER :: 0x02 // Ctrl+B
Q :: 0x71 // q
LSBR :: 0x5B // [
RSBR :: 0x5D // ]
ZERO :: 0x30
WSPACE :: 0x20

// control bytes
BEL :: 0x07	// \a Terminal bell
BS  :: 0x08	// \b Backspace
HT  :: 0x09	// \t Horizontal TAB
LF  :: 0x0A	// \n Linefeed (newline)
VT  :: 0x0B	// \v Vertical TAB
FF  :: 0x0C	// \f Formfeed (also: New page NP)
CR  :: 0x0D	// \r Carriage return
ESC :: 0x1B	// \e* Escape character
DEL :: 0x7F	// <none> Delete character

cell_styles :: enum {
    BOLD = 1,
    DIM = 2,
    ITALIC = 3,
    UNDERLINE = 4,
    BLINKING = 5,
    INVERSE = 7,
    HIDDEN = 8,
    STRIKETHROUGH = 9,
    DOUBLE_UNDERLINE = 21,
}

PaletteColor :: struct { idx: int }
RgbColor :: struct { r, g, b: int }
Color :: union { int, PaletteColor, RgbColor }
Cell :: struct {
    r: rune,
    styles: bit_set[cell_styles],
    fg: Color,
    bg: Color
}

sequence_type :: enum {
    NONE, // definitely no sequence
    UNKNOWN, // ESC key was detected
    CSI,
    OSC,
    DCS,
    SIMPLE,
    CONTROL, // contorl chars, such as '\n'
}

sequence_status :: enum {
    NOT_STARTED,
    PENDING, // ESC key was detected
    CONSUMED
}

// start with ?
private_modes :: enum {
    APP_CURSOR,
    REVERSE,
    ORIGIN,
    AUTOWRAP,
    CURSOR_BLINK,
    CURSOR_VISIBLE,
    MOUSE_CLICK,
    MOUSE_DRAG,
    MOUSE_MOTION,
    MOUSE_SGR_ENCODING,
    FOCUS_REPORTING,
    ALT_SCREEN,
    BRACKETED_PASTE,
}

private_modes_values :: [private_modes]uint{
    .APP_CURSOR = 1,
    .REVERSE = 5,
    .ORIGIN = 6,
    .AUTOWRAP = 7,
    .CURSOR_BLINK = 12,
    .CURSOR_VISIBLE = 25,
    .MOUSE_CLICK = 1000,
    .MOUSE_DRAG = 1002,
    .MOUSE_MOTION = 1003,
    .MOUSE_SGR_ENCODING = 1006,
    .FOCUS_REPORTING = 1004,
    .ALT_SCREEN = 1049,
    .BRACKETED_PASTE = 2004,
}

private_modes_enums: map[uint]private_modes
@(init)
fill_private_modes_map :: proc "contextless" () {
    context = runtime.default_context()

    private_modes_enums := make(map[uint]private_modes)
    private_modes_enums[1] = .APP_CURSOR
    private_modes_enums[5] = .REVERSE
    private_modes_enums[6] = .ORIGIN
    private_modes_enums[7] = .AUTOWRAP
    private_modes_enums[12] = .CURSOR_BLINK
    private_modes_enums[25] = .CURSOR_VISIBLE
    private_modes_enums[1000] = .MOUSE_CLICK
    private_modes_enums[1002] = .MOUSE_DRAG
    private_modes_enums[1003] = .MOUSE_MOTION
    private_modes_enums[1006] = .MOUSE_SGR_ENCODING
    private_modes_enums[1004] = .FOCUS_REPORTING
    private_modes_enums[1049] = .ALT_SCREEN
    private_modes_enums[2004] = .BRACKETED_PASTE
}

// start without marker
ansi_modes :: enum {
    INSERT = 4,
    NEW_LINE = 20,
}

esc_codes :: enum {
    BELL, CURSOR_VISIBLE, CURSOR_HIDDEN,
}

State :: struct {
    leader_pending: bool,
    cursor_position: struct {
        row: int,
        col: int
    },
    esc_seq: struct {
        type: sequence_type,
        status: sequence_status,
        marker: byte,
        intermediate: byte,
        invalid: bool,
        command: byte,
        // all the styling params applied at once would be 18
        // but leave a room just in case
        params: [30]int, 
        params_len: Maybe(int)
    },
    scroll_region: struct {
        top: int,
        bottom: int
    },
    modes: struct {
        private: bit_set[private_modes],
        ansi: bit_set[ansi_modes]
    },
    size: struct {
        row: int,
        col: int,
    },
    default_grid: [dynamic]Cell,
    alt_grid: [dynamic]Cell,
    grid: ^[dynamic]Cell,
    codes: bit_set[esc_codes],
}

handle_parent :: proc(pid: posix.pid_t, master_fd: posix.FD) {
    ws: winsize
    assert(linux.ioctl(linux.STDIN_FILENO, TIOCGWINSZ, uintptr(&ws)) == 0, "Failed to get terminal size")
    assert(linux.ioctl(linux.Fd(master_fd), TIOCSWINSZ, uintptr(&ws)) == 0, "Failed to set terminal size")
    assert(ws.ws_col > 0, "ws_col should be greater than zero")
    assert(ws.ws_row > 0, "ws_row should be greater than zero")

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

    state := State{
        size = {
            row = int(ws.ws_row),
            col = int(ws.ws_col)
        },
        default_grid = make([dynamic]Cell, ws.ws_row * ws.ws_col),
        alt_grid = make([dynamic]Cell, ws.ws_row * ws.ws_col),
        leader_pending = false,
        cursor_position = {
            row = 0,
            col = 0,
        },
        scroll_region = {
            top = 0,
            bottom = int(ws.ws_row) - 1
        },
        modes = {
            private = {.CURSOR_VISIBLE, .AUTOWRAP},
            ansi = {},
        },
        esc_seq = {
            type = .NONE,
            marker = 0,
            intermediate = 0,
            invalid = false,
            command = 0,
            params = [30]int{},
            params_len = nil
        },
        // emit = strings.builder_make(0, 100), // TODO: tweak the number
    }
    state.grid = &state.default_grid

    // fill the grid with empty values
    for i in 0..<(ws.ws_row * ws.ws_col) {
        state.default_grid[i].r = WSPACE
        state.alt_grid[i].r = WSPACE
    }
    buf_arr := [1024 * 4]byte{}
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
                for i in 0..<bytes_read {
                    b := buf[i]
                    fmt.fprintfln(log_file, "Consuming byte: %d (%q)", b, rune(b))

                    if state.esc_seq.status == .NOT_STARTED {
                        pass_control := consume_byte(&state, b)
                        fmt.fprintfln(log_file, "State after byte consumption. Status = %s, type = %s", state.esc_seq.status, state.esc_seq.type)
                        if !pass_control do continue
                    }

                    if state.esc_seq.status == .PENDING {
                        switch state.esc_seq.type {
                            case .CSI: consume_csi_sequence(&state, b) 
                            case .OSC: consume_ocs_sequence(&state, b) 
                            case .DCS: consume_dcs_sequence(&state, b) 
                            case .SIMPLE: consume_simple_sequence(&state, b) 
                            case .UNKNOWN: consume_introducer(&state, b) 
                            // control char is a single byte operation,
                            // it's expected to be consumed by [consume_byte] proc
                            // and then immideately handled in the code below
                            case .NONE, .CONTROL: fmt.panicf("Attempt to consume %s sequence", state.esc_seq.type)
                        }
                    }

                    if state.esc_seq.status == .CONSUMED {
                        switch state.esc_seq.type {
                            case .CSI: handle_csi_sequence(&state) 
                            case .OSC: handle_osc_sequence(&state) 
                            case .DCS: handle_dcs_sequence(&state) 
                            case .SIMPLE: handle_simple_sequence(&state) 
                            case .CONTROL: handle_control_char(&state, b) 
                            case .UNKNOWN, .NONE: fmt.panicf("Attempt to handle consumed %s", state.esc_seq.type)
                        }
                    }
                }

                render_grid(&state)
                dump_grid(&state)
            }

            case posix.STDIN_FILENO: {
                bytes_before_leader := bytes_read
                for i in 0..<bytes_read {
                    switch buf[i] {
                        case LEADER: {
                            if !state.leader_pending {
                                state.leader_pending = true
                                bytes_before_leader = max(i - 1, 0)
                            }
                        }
                        case Q: {
                            if state.leader_pending {
                                break event_loop
                            }
                        }
                        case: {
                            state.leader_pending = false
                        }
                    }
                }
                if bytes_before_leader > 0 {
                    write(master_fd, raw_data(buf), uint(bytes_before_leader))
                }
            }

            case: fmt.fprintln(log_file, "Unknown FD")
            }
        }
    }
}

COL :: 0x3A // :
SEMCOL :: 0x3B // ;

consume_csi_sequence :: proc (state: ^State, b: byte) {
    fmt.fprintln(log_file, "Consume csi seq")
    switch b {
    // marker flags: < = > ?
    case 0x3C..=0x3F:
        // if private flag appears after param, the sequence is invalid
        if state.esc_seq.params_len != nil {
            state.esc_seq.invalid = true
        } else {
            state.esc_seq.marker = b
        }

    // params
    case 0x30..<COL:
        // if it's the first param, need to assign the correct length
        len := state.esc_seq.params_len.? or_else 1
        state.esc_seq.params_len = len
        state.esc_seq.params[len - 1] = state.esc_seq.params[len - 1] * 10 + int(b - ZERO);

    // params separators
    case COL, SEMCOL:
        len := state.esc_seq.params_len.? or_else 1
        state.esc_seq.params_len = len + 1
        state.esc_seq.params[len] = 0

    // intermediate byte
    case 0x20..=0x2F:
        if state.esc_seq.intermediate != 0 {
            state.esc_seq.invalid = true
        } else {
            state.esc_seq.intermediate = b
        }

    // command
    case 0x40..=0x7E:
        state.esc_seq.command = b
        state.esc_seq.status = .CONSUMED

    case: fmt.panicf("Unexpected byte consumed in CSI sequence: %c (%d)\n", b, b)
    }
}
consume_ocs_sequence :: proc (state: ^State, b: byte) {
    fmt.fprintln(log_file, "Consume ocs seq")
}
consume_dcs_sequence :: proc (state: ^State, b: byte) {
    fmt.fprintln(log_file, "Consume dcs seq")
}
consume_simple_sequence :: proc (state: ^State, b: byte) {
    fmt.fprintln(log_file, "Consume simple seq")
}
consume_introducer :: proc (state: ^State, b: byte) {
    fmt.fprintfln(log_file, "Consume introducer: %c (%d)", b, b)
    assert(state.esc_seq.type == .UNKNOWN, "Cannot consume introducer on not started escape sequence")

    switch b {
    case LSBR: state.esc_seq.type = .CSI
    case RSBR: state.esc_seq.type = .OSC
    case 'P': state.esc_seq.type = .DCS
    // whitespaces are ignored in escape sequences
    case WSPACE: // no op
    case: state.esc_seq.type = .SIMPLE
    }
}
consume_byte :: proc(state: ^State, b: byte) -> (pass_control: bool) {
    assert(state.esc_seq.type == .NONE, "Attempt to consume regular byte on escape sequence")
    fmt.fprintln(log_file, "Consume regular byte")

    pass_control = false

    switch b {
        case ESC:
            state.esc_seq.type = .UNKNOWN
            state.esc_seq.status = .PENDING
        // byte means "ESC["
        case 0x9B:
            state.esc_seq.type = .CSI
            state.esc_seq.status = .PENDING

        case 0..<0x20:
            fmt.fprintfln(log_file, "Control seq detected (%d)", b)
            state.esc_seq.type = .CONTROL
            state.esc_seq.status = .CONSUMED
            pass_control = true

        case:
            // TODO: optimize this
            clear_esc(state)
            print_and_advance(state, b)
    }

    return
}

clear_esc :: proc(state: ^State) {
    state.esc_seq.type = .NONE
    state.esc_seq.status = .NOT_STARTED
    state.esc_seq.marker = 0
    state.esc_seq.invalid = false
    state.esc_seq.command = 0
    state.esc_seq.params_len = nil
    mem.zero(&state.esc_seq.params, len(state.esc_seq.params) * size_of(state.esc_seq.params[0]))
}

print_and_advance :: proc(state: ^State, b: byte) {
    fmt.fprintfln(log_file, "[PA] row: %d, col: %d, sym: %c", state.cursor_position.row, state.cursor_position.col, b)
    // we're in the very last cell
    if state.cursor_position.row == state.size.row - 1 && state.cursor_position.col == state.size.col - 1 {
        scroll_up(state, 1, state.scroll_region.top, state.scroll_region.bottom)
        state.cursor_position.col = 0
    }
    state.grid[state.cursor_position.row * state.size.col + state.cursor_position.col].r = rune(b)
    state.cursor_position.row += (state.cursor_position.col + 1) / state.size.col
    state.cursor_position.col = (state.cursor_position.col + 1) % state.size.col
    fmt.fprintfln(log_file, "[PA] cursor advanced to: %d, col: %d, %c", state.cursor_position.row, state.cursor_position.col, state.grid[state.cursor_position.row * state.size.col + state.cursor_position.col-1].r)
}

handle_control_char :: proc(state: ^State, char: byte) {
    // clean escape sequence state after handling
    defer {
        state.esc_seq.type = .NONE
        state.esc_seq.status = .NOT_STARTED
    }

    switch char {
    // will be sent to a terminal for actual bell
    case BEL: state.codes += { .BELL }
    // move cursor left
    case BS: state.cursor_position.col = max(state.cursor_position.col - 1, 0)
    // move cursor to the next tabstop
    case HT: {
        // next multiple of eight
        next_multiple := ((state.cursor_position.col | 7) + 1)
        state.cursor_position.col = max(next_multiple, state.size.row - 1)
    }
    // move cursor next line
    case LF, FF, VT: {
        if state.cursor_position.row == state.size.row - 1 {
            scroll_up(state, 1, state.scroll_region.top, state.scroll_region.bottom)
        } else {
            state.cursor_position.row += 1
        }
    }
    // move cursor to the beginning of the line
    case CR: state.cursor_position.col = 0
    // ignore
    case DEL: fmt.fprintln(log_file, "Del char")
    case: fmt.fprintfln(log_file, "Unknown control char: %d (%c)",  char, char)
    }
}

move_row :: proc(state: ^State, source_row_idx, target_row_idx: int) {
    assert(state.size.row > 0 && state.size.col > 0, "Move: Window size must be greater than zero")
    assert(source_row_idx < state.size.row, "Move: Source row index is out of bounds")
    assert(target_row_idx < state.size.row, "Move: Target row index is out of bounds")

    source_start := source_row_idx * state.size.col
    target_start := target_row_idx * state.size.col

    for i in 0..<state.size.col {
        state.grid[target_start + i].r = state.grid[source_start + i].r
    }
}

clean_row :: proc(state: ^State, row_idx: int) {
    assert(state.size.row > 0 && state.size.col > 0, "Clean: Window size must be greater than zero")
    assert(row_idx < state.size.row, "Clean: Row index is out of bounds")

    source_start := row_idx * state.size.col

    for i in 0..<state.size.col {
        state.grid[source_start + i].r = WSPACE
    }
}

scroll_down :: proc(state: ^State, rows_count, top_bound, bottom_bound: int) {
    assert(bottom_bound > 0 && bottom_bound > top_bound, "Invalid bounds")

    scroll_height := bottom_bound - top_bound

    for i := scroll_height - 1; i >= 0; i -= 1 {
        row_idx := state.scroll_region.top + i
        move_row(state, row_idx - rows_count, row_idx)
    }
    for i in 0..<rows_count {
        row_idx := state.scroll_region.top + i
        clean_row(state, row_idx)
    }
}

scroll_up :: proc(state: ^State, rows_count, top_bound, bottom_bound: int) {
    assert(bottom_bound > 0 && bottom_bound > top_bound, "Invalid bounds")
    fmt.fprintfln(log_file, "Scrolling up by %d rows (t: %d, b: %d)", rows_count, top_bound, bottom_bound)

    scroll_height := bottom_bound - top_bound

    for i in 0..=(scroll_height - rows_count) {
        row_idx := state.scroll_region.top + i
        move_row(state, row_idx + rows_count, row_idx)
    }
    for i in 0..<rows_count {
        row_idx := state.scroll_region.bottom - i
        clean_row(state, row_idx)
    }
}

handle_csi_sequence :: proc(state: ^State) {
    assert(state.esc_seq.type == .CSI, "Attempt to handle non-CSI sequence in CSI handler")

    // clean after handling
    defer clear_esc(state)

    switch {
    // private mode
    case state.esc_seq.marker == '?': {
        fmt.fprintln(log_file, "PRIVATE mode: %d", state.esc_seq.params[0])
        switch state.esc_seq.command {
        // enabled
        case 'h':
            if m, ok := private_modes_enums[uint(state.esc_seq.params[0])]; ok {
                state.modes.private += {m}
                #partial switch m {
                case .ALT_SCREEN:
                    state.grid = &state.alt_grid
                case .ORIGIN:
                    state.cursor_position.row = state.scroll_region.top
                    state.cursor_position.col = 1
                case: fmt.fprintfln(log_file, "Skipping the %sh", m)
                }
            }

        // disabled
        case 'l':
            if m, ok := private_modes_enums[uint(state.esc_seq.params[0])]; ok {
                state.modes.private -= {m}
                #partial switch m {
                case .ALT_SCREEN:
                    state.grid = &state.default_grid
                case .ORIGIN:
                    state.cursor_position.row = 1
                    state.cursor_position.col = 1
                case: fmt.fprintfln(log_file, "Skipping the %sh", m)
                }
            }

        case: fmt.fprintfln(log_file, "Invalid private mode command: %s", state.esc_seq.command)
        }
    }

    // ansi mode
    case state.esc_seq.command == 'l' || state.esc_seq.command == 'h': {
        fmt.fprintln(log_file, "ANSI mode: %d", state.esc_seq.params[0])
        switch state.esc_seq.command {
        case 'h': state.modes.ansi += {ansi_modes(state.esc_seq.params[0])}
        case 'l': state.modes.ansi -= {ansi_modes(state.esc_seq.params[0])}
        }
    }

    case: {
        switch state.esc_seq.command {
        // move cursor up
        case 'A': {
            // TODO: support scrollback
            p0 := min(state.esc_seq.params[0], 1)
            state.cursor_position.row = max(state.cursor_position.row - p0, 0)
        }
        // move cursor down
        case 'B', 'e': {
            p0 := max(state.esc_seq.params[0], 1)
            state.cursor_position.row = min(state.cursor_position.row + p0, state.size.col - 1)
        }
        // move cursor right
        case 'C', 'a': {
            p0 := max(state.esc_seq.params[0], 1)
            state.cursor_position.col = min(state.cursor_position.col + p0, state.size.col - 1)
        }
        // move cursor left
        case 'D': {
            p0 := max(state.esc_seq.params[0], 1)
            state.cursor_position.col = max(state.cursor_position.col - p0, 0)
        }
        // move cursor to row
        case 'd': {
            p0 := max(state.esc_seq.params[0] - 1, 0)
            if .ORIGIN in state.modes.private {
                state.cursor_position.row = min(state.scroll_region.top + p0, state.scroll_region.bottom)
            } else {
                state.cursor_position.row = min(p0, state.size.row - 1)
            }
        }
        // move cursor down N rows and to column 1
        case 'E': {
            p0 := max(state.esc_seq.params[0], 1)
            state.cursor_position.row = min(state.cursor_position.row + p0, state.size.row - 1)
            state.cursor_position.col = 0
        }
        // move cursor up N rows and column 1
        case 'F': {
            p0 := max(state.esc_seq.params[0], 1)
            state.cursor_position.row = min(state.cursor_position.row - p0, 1)
            state.cursor_position.col = 0
        }
        // set cursor
        case 'H', 'f': {
            p0 := max(state.esc_seq.params[0] - 1, 0)
            p1 := min(max(state.esc_seq.params[1] - 1, 0), state.size.col - 1)
            fmt.fprintfln(log_file, "Set cursor params: r=%d (%d), c=%d (%d)", state.esc_seq.params[0], state.esc_seq.params[1], p0, p1)
            if .ORIGIN in state.modes.private {
                p0 = min(state.scroll_region.top + p0, state.scroll_region.bottom)
            } else {
                p0 = min(p0, state.size.row - 1)
            }
            state.cursor_position.row = p0
            state.cursor_position.col = p1
            fmt.fprintfln(log_file, "Set cursor to: r=%d, c=%d", state.cursor_position.row, state.cursor_position.col)
        }
        // move cursor to column
        case 'G', '`': {
            p0 := max(state.esc_seq.params[0] - 1, 0)
            // TODO: support horizontal scroll region
            state.cursor_position.col = min(p0, state.size.col - 1)
        }
        // line erase
        case 'K': {
            switch state.esc_seq.params[0] {
            // erase from cursor
            case 0: {
                for i in state.cursor_position.col..=(state.size.col - 1) {
                    state.grid[(state.cursor_position.row * state.size.col) + i].r = WSPACE
                }
            }

            // erase to cursor
            case 1: {
                for i in 0..=state.cursor_position.col {
                    state.grid[(state.cursor_position.row * state.size.col) + i].r = WSPACE
                }
            }

            // entire line
            case 2: {
                for i in 0..=(state.size.col - 1) {
                    state.grid[(state.cursor_position.row * state.size.col) + i].r = WSPACE
                }
            }

            case:
                fmt.panicf("[CSI] Invalid K (erase line) param: %d\n", state.esc_seq.params[0])
            }
        }
        // erase screen
        case 'J': {
            switch p := state.esc_seq.params[0]; p {
            // erase from cursor
            case 0: {
                cell_under_cursor_idx := state.cursor_position.row * state.size.col + state.cursor_position.col
                last_cell_idx := state.size.row + state.size.col
                for i in cell_under_cursor_idx..=last_cell_idx {
                    state.grid[i].r = WSPACE
                }
            }

            // erase to cursor
            case 1: {
                cell_under_cursor_idx := state.cursor_position.row * state.size.col + state.cursor_position.col
                for i in 0..=cell_under_cursor_idx {
                    state.grid[i].r = WSPACE
                }
            }

            // entire screen
            case 2: {
                last_cell_idx := state.size.row + state.size.col
                for i in 0..=last_cell_idx {
                    state.grid[i].r = WSPACE
                }
            }
            
            // entire screen and scrollback
            case 3: {
                // TODO: add scrollback erase
                last_cell_idx := state.size.row + state.size.col
                for i in 0..=last_cell_idx {
                    state.grid[i].r = WSPACE
                }
            }

            case: fmt.panicf("[CSI] Invalid J (erase screen) param: %d\n", p)
            }
        }

        // erase (fill with whitespace) N cells from cursor without shift
        // preserves only background color
        case 'X': {
            p0 := max(state.esc_seq.params[0], 1)
            end := min(state.cursor_position.col + p0, state.size.col)

            for i in state.cursor_position.col..<end {
                state.grid[(state.cursor_position.row * state.size.col) + i].r = WSPACE
            }
        }

        // inserts N empty cells from the cursor shifting the content
        // content falls of the edge (not wrapped, deleted)
        case '@': {
            p0 := min(max(state.esc_seq.params[0], 1), state.size.col - (state.cursor_position.col + 1))
            eol := state.cursor_position.row * state.size.col + (state.size.col - 1)
            for i in 0..<p0 {
                cur_idx := state.cursor_position.row * state.size.col + state.cursor_position.col + i
                // move current byte to the shifted position
                state.grid[eol - (p0 - i)].r = state.grid[cur_idx].r
                state.grid[cur_idx].r = WSPACE
            }
        }

        // deletes N cells shifting towards the cursor
        case 'P': {
            p0 := min(max(state.esc_seq.params[0], 1), state.size.col - (state.cursor_position.col + 1))
            eol := state.cursor_position.row * state.size.col + (state.size.col - 1)
            // shift
            for i in 0..<p0 {
                cur_idx := state.cursor_position.row * state.size.col + state.cursor_position.col + i
                state.grid[cur_idx].r = state.grid[cur_idx + (p0 - i)].r
            }
            // erase rest
            for i in 0..<p0 {
                state.grid[eol - i].r = WSPACE
            }
        }

        // inserts N rows at the cursor row and pushes lines down
        case 'L': {
            // if cursor out of scroll region, do nothing
            if state.cursor_position.row < state.scroll_region.top || state.cursor_position.row > state.scroll_region.bottom {
                break
            }

            p0 := min(state.esc_seq.params[0], 1)
            scroll_down(state, p0, state.cursor_position.row, state.scroll_region.bottom)
        }

        // removes N rows from cursor, shifting underline rows to the top
        // new rows from bottom filled with whitespace
        case 'M': {
            // if cursor out of scroll region, do nothing
            if state.cursor_position.row < state.scroll_region.top || state.cursor_position.row > state.scroll_region.bottom {
                break
            }

            p0 := min(state.esc_seq.params[0], 1)
            scroll_up(state, p0, state.cursor_position.row, state.scroll_region.bottom)
        }

        // scroll up N rows within scroll region
        // scrolled out content is lost
        case 'S': {
            p0 := min(state.esc_seq.params[0], 1)
            scroll_up(state, p0, state.cursor_position.row, state.scroll_region.bottom)
        }

        // scroll down N rows within scroll region
        case 'T': {
            p0 := min(state.esc_seq.params[0], 1)
            scroll_down(state, p0, state.scroll_region.top, state.scroll_region.bottom)
        }

        // sets the scroll region
        case 'r': {
            state.scroll_region.top = state.esc_seq.params[0]
            state.scroll_region.bottom = min(state.esc_seq.params[1], state.size.row - 1)
        }

        case 'm': {
            fmt.fprintfln(log_file, "Handling styling. Params: %d, %d, %d", state.esc_seq.params[0], state.esc_seq.params[1] ,state.esc_seq.params[2])
            i := 0
            for i < (state.esc_seq.params_len.? or_else 0) {
                defer i += 1
                cell := &state.grid[state.cursor_position.row * state.size.col + state.cursor_position.col]

                fmt.fprintfln(log_file, "Handling int param: %d", state.esc_seq.params[i])

                switch state.esc_seq.params[i] {
                case 0:
                    fmt.fprintln(log_file, "Clearing styles")
                    cell.styles = {}
                    cell.fg = nil
                    cell.bg = nil
                case int(cell_styles.BOLD): cell.styles += { .BOLD }
                case int(cell_styles.DIM): cell.styles += { .DIM }
                case 22: cell.styles -= { .BOLD, .DIM }
                case int(cell_styles.ITALIC): cell.styles += { .ITALIC }
                case 23: cell.styles -= { .ITALIC }
                case int(cell_styles.UNDERLINE): cell.styles += { .UNDERLINE }
                case int(cell_styles.DOUBLE_UNDERLINE): cell.styles += { .DOUBLE_UNDERLINE }
                case 24: cell.styles -= { .UNDERLINE, .DOUBLE_UNDERLINE }
                case int(cell_styles.BLINKING): cell.styles += { .BLINKING }
                case 25: cell.styles -= { .BLINKING }
                case int(cell_styles.INVERSE): cell.styles += { .INVERSE }
                case 27: cell.styles -= { .INVERSE }
                case int(cell_styles.HIDDEN): cell.styles += { .HIDDEN }
                case 28: cell.styles -= { .HIDDEN }
                case int(cell_styles.STRIKETHROUGH): cell.styles += { .STRIKETHROUGH }
                case 29: cell.styles -= { .STRIKETHROUGH }
                // 16-bit foreground
                case 38: {
                    switch state.esc_seq.params[i + i] {
                    // rgb color
                    case 2:
                        cell.fg = RgbColor{
                            r = state.esc_seq.params[i + 2],
                            g = state.esc_seq.params[i + 3],
                            b = state.esc_seq.params[i + 4],
                        }
                        i += 4

                    // 256 colors palette
                    case 5:
                        cell.fg = PaletteColor{
                            idx = state.esc_seq.params[i + 2]
                        }
                        i += 2
                    
                    case: fmt.fprintfln(log_file, "Unexpected color sequence: 38 > %d", state.esc_seq.params[i + 1])
                    }
                }
                // 16-bit background
                case 48: {
                    switch state.esc_seq.params[i + i] {
                    // rgb color
                    case 2:
                        cell.bg = RgbColor{
                            r = state.esc_seq.params[i + 2],
                            g = state.esc_seq.params[i + 3],
                            b = state.esc_seq.params[i + 4],
                        }
                        i += 4

                    // 256 colors palette
                    case 5:
                        cell.bg = PaletteColor{
                            idx = state.esc_seq.params[i + 2]
                        }
                        i += 2
                    
                    case: fmt.fprintfln(log_file, "Unexpected color sequence: 38 > %d", state.esc_seq.params[i + 1])
                    }
                }
                // foreground
                case 30..=39, 90..=97: {
                    fmt.fprintfln(log_file, "Simple foreground detected: %d", state.esc_seq.params[i])
                    cell.fg = state.esc_seq.params[i]
                }
                case 40..=49, 100..=107: cell.bg = state.esc_seq.params[i]

                case: fmt.fprintfln(log_file, "Unknown color param: %d", state.esc_seq.params[i])
                }
            }

            cell := &state.grid[state.cursor_position.row * state.size.col + state.cursor_position.col]
            fmt.fprintf(log_file, "Styles after: %v, fg: ", cell.styles)
            switch color in cell.fg {
            case nil: fmt.fprint(log_file, "null")
            case int: fmt.fprint(log_file, color)
            case PaletteColor: fmt.fprintf(log_file, "38;5;%d", color.idx)
            case RgbColor: fmt.fprintf(log_file, "38;2;%d;%d;%d", color.r, color.g, color.b)
            }
            fmt.fprint(log_file, ", bg: ")
            switch color in cell.fg {
            case nil: fmt.fprint(log_file, "null")
            case int: fmt.fprint(log_file, color)
            case PaletteColor: fmt.fprintf(log_file, "38;5;%d", color.idx)
            case RgbColor: fmt.fprintf(log_file, "38;2;%d;%d;%d", color.r, color.g, color.b)
            }
            fmt.fprint(log_file, "\n")
        }
            

        case 'h': fmt.fprintln(log_file, "h command: unhandled")

        case: fmt.fprintfln(log_file, "Unhandled command: %c", state.esc_seq.command)
        }
    }
    }
}

handle_osc_sequence :: proc (state: ^State) {}
handle_dcs_sequence :: proc (state: ^State) {}
handle_simple_sequence :: proc(state: ^State) {}

render_grid :: proc(state: ^State) {
    assert(int(state.size.row * state.size.col) == len(state.grid), "Screen size and grid size mismatch")

    builder, err := strings.builder_make(len(state.grid))
    if err != nil {
        panic("Failed to allocate")
    }
    defer strings.builder_destroy(&builder)

    // move cursor to the start and erase styles
    fmt.sbprintf(&builder, "\e[H\e[0m")

    // write the whole screen
    for r in 0..<state.size.row {
        for c in 0..<state.size.col {
            cell := &state.grid[r * state.size.col + c]
            if cell.styles != {} || cell.fg != nil || cell.bg != nil {
                // start and end sequence
                fmt.sbprint(&builder, "\e[")
                defer {
                    // replacing trailing ';' separator, which is important
                    // otherwise the absent value after that equals '0' (which is styles erasing)
                    switch last_byte := &builder.buf[strings.builder_len(builder) - 1]; last_byte^ {
                    case ';': last_byte^ = 'm'
                    case: fmt.sbprint(&builder, "m")
                    }
                }

                // emit styles
                for s in cell.styles do fmt.sbprintf(&builder, "%d;", int(s))

                // emit foreground
                switch color in cell.fg {
                case nil: // nothing
                case int: fmt.sbprint(&builder, color)
                case PaletteColor: fmt.sbprintf(&builder, "38;5;%d;", color.idx)
                case RgbColor: fmt.sbprintf(&builder, "38;2;%d;%d;%d;", color.r, color.g, color.b)
                }

                // emit background
                switch color in cell.bg {
                case nil: // nothing
                case int: fmt.sbprint(&builder, color)
                case PaletteColor: fmt.sbprintf(&builder, "48;5;%d;", color.idx)
                case RgbColor: fmt.sbprintf(&builder, "48;2;%d;%d;%d;", color.r, color.g, color.b)
                }
            }
            strings.write_rune(&builder, cell.r)
        }
        // move cursor to a new line
        fmt.sbprintf(&builder, "\e[%d;%dH", r + 2, 1)
    }

    switch {
    case .BELL in state.codes: strings.write_rune(&builder, BEL)
    case .CURSOR_VISIBLE in state.codes: fmt.sbprint(&builder, "\e[?25h")
    case .CURSOR_HIDDEN in state.codes: fmt.sbprint(&builder, "\e[?25l")
    }

    state.codes = {}

    // restore cursor
    fmt.sbprintf(&builder, "\e[%d;%dH", state.cursor_position.row + 1, state.cursor_position.col + 1)
    write(posix.STDOUT_FILENO, raw_data(builder.buf[:]), uint(strings.builder_len(builder)))
}

counter := 0
dump_grid :: proc(state: ^State) {
    defer counter += 1
    fmt.fprintfln(log_file, "dumping grid #%d", counter)

    f, err := os.open(
        fmt.tprintf("./dumps/grid_%d.txt", counter),
        os.File_Flags{ .Create, .Write, .Append, .Trunc },
        os.Permissions{.Execute_User, .Write_User, .Read_User, .Read_Group, .Read_Other}
    )
    if err != nil {
        fmt.eprintln("Error creating a file:", err)
        return
    }
    defer os.close(f)

    buf := make([dynamic]byte, 0)
    for r in 0..<state.size.row {
        for c in 0..<state.size.col {
            i := r * state.size.col + c
            cell := &state.grid[r * state.size.col + c]

            if cell.styles != {} || cell.fg != nil || cell.bg != nil {
                append(&buf, '\e')
                append(&buf, '[')
                defer append(&buf, 'm')

                // emit styles
                for s in cell.styles do append(&buf, byte(s))

                // emit foreground
                // switch color in cell.fg {
                // case nil: // nothing
                // case u16: fmt.sbprint(&builder, color)
                // case PaletteColor: fmt.sbprintf(&builder, "38;5;%d", color.idx)
                // case RgbColor: fmt.sbprintf(&builder, "38;2;%d;%d;%d", color.r, color.g, color.b)
                // }
                //
                // // emit background
                // switch color in cell.bg {
                // case nil: // nothing
                // case u16: fmt.sbprint(&builder, color)
                // case PaletteColor: fmt.sbprintf(&builder, "48;5;%d", color.idx)
                // case RgbColor: fmt.sbprintf(&builder, "48;2;%d;%d;%d", color.r, color.g, color.b)
                // }
            }
            append(&buf, byte(cell.r))
        }
        append(&buf, byte('\n'))
    }
    _, err = os.write(f, buf[:])
    if err != nil {
        fmt.eprintln("Error writing a file:", err)
    }
}
