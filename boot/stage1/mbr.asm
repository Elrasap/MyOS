; boot/stage1/mbr.asm
; NASM, 16-bit MBR boot sector
; Loads Stage2 from disk LBA=1 into 0x0000:0x8000.
; Stage2 begins with a 4-byte magic value, so execution jumps to 0x8004.

BITS 16
ORG 0x7C00

%define STAGE2_LOAD_SEG   0x0000
%define STAGE2_LOAD_OFF   0x8000
%define STAGE2_ENTRY_OFF  0x8004
%define STAGE2_LBA        1
%define STAGE2_SECTORS    32            ; must match your image packing
%define STAGE2_MAGIC      0x32475453     ; 'STG2' little-endian

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; Progress marker: M = MBR started.
    mov ah, 0x0E
    mov al, 'M'
    mov bh, 0x00
    int 0x10

    ; BIOS passes the boot drive in DL. Save it and pass it to stage2.
    mov [boot_drive], dl

    ; Read stage2 using INT 13h extensions.
    mov si, dap_stage2
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    ; Check stage2 magic at 0x8000.
    mov bx, STAGE2_LOAD_OFF
    cmp dword [bx], STAGE2_MAGIC
    jne disk_error

    ; Pass boot drive to stage2 in DL and jump past the 4-byte magic header.
    mov dl, [boot_drive]
    jmp STAGE2_LOAD_SEG:STAGE2_ENTRY_OFF

disk_error:
    mov ah, 0x0E
    mov al, 'E'
    mov bh, 0x00
    int 0x10
.halt:
    hlt
    jmp .halt

; Disk Address Packet for INT 13h AH=42h.
dap_stage2:
    db 0x10              ; DAP size
    db 0x00              ; reserved
    dw STAGE2_SECTORS    ; sectors to read
    dw STAGE2_LOAD_OFF   ; destination offset
    dw STAGE2_LOAD_SEG   ; destination segment
    dq STAGE2_LBA        ; starting LBA

boot_drive:
    db 0

times 510-($-$$) db 0
dw 0xAA55
