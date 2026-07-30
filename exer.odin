package main

main :: proc() {
    save_current_terminal()
    defer restore_current_terminal()

    put_term_rawmode()

    enter_alt_mode()
    defer exit_alt_mode()

    create_child_process()
}

