package main

main :: proc() {
    save_current_terminal()
    defer restore_current_terminal()
    put_term_rawmode()

    create_child_process()
}

