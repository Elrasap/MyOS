BITS 64
ORG 0x00100000

_start:
    ; Write "OK" to VGA text memory.
    mov rax, 0x0F4B0F4F
    mov dword [0xB8000], eax

.halt:
    cli
    hlt
    jmp .halt
