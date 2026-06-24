use core::arch::global_asm;

use crate::{
    halt_loop,
    serial_write_hex_u64,
    serial_write_str,
};

global_asm!(
    r#"
.intel_syntax noprefix

.global isr0
isr0:
    cli
    push 0
    push 0
    jmp isr_common

.global isr6
isr6:
    cli
    push 0
    push 6
    jmp isr_common

.global isr8
isr8:
    cli
    push 8
    jmp isr_common

.global isr13
isr13:
    cli
    push 13
    jmp isr_common

.global isr14
isr14:
    cli
    push 14
    jmp isr_common


isr_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rdi, [rsp + 120]
    mov rsi, [rsp + 128]

    call rust_exception_handler

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    add rsp, 16
    iretq
"#
);

#[no_mangle]
pub extern "sysv64" fn rust_exception_handler(vector: u64, error_code: u64) {
    serial_write_str("\nEXCEPTION: ");

    match vector {
        0 => serial_write_str("divide by zero"),
        6 => serial_write_str("invalid opcode"),
        8 => serial_write_str("double fault"),
        13 => serial_write_str("general protection fault"),
        14 => serial_write_str("page fault"),
        _ => serial_write_str("unknown exception"),
    }

    serial_write_str("\nVector: ");
    serial_write_hex_u64(vector);

    serial_write_str("\nError code: ");
    serial_write_hex_u64(error_code);

    serial_write_str("\n");

    halt_loop();
}