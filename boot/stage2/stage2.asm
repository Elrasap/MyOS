BITS 16
ORG 0x8000

start:
    cli

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x9000

    sti

    mov ah, 0x0E
    mov al, '2'
    mov bh, 0x00
    int 0x10

halt:
    hlt
    jmp halt

enable_a20:
    in al, 0x92
    or al, 00000010b
    and al, 11111110b
    out 0x92, al
    ret