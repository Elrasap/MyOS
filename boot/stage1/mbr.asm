; boot/stage1/mbr.asm
; 16-bit MBR boot sector
; Lädt Stage2 von LBA 1 nach 0x0000:0x8000
; Prüft Magic "STG2"
; Springt nach 0x8004, weil 0x8000..0x8003 Header ist

BITS 16
ORG 0x7C00

%define STAGE2_LOAD_SEG 0x0000
%define STAGE2_LOAD_OFF 0x8000
%define STAGE2_ENTRY_OFF 0x8004
%define STAGE2_LBA      1
%define STAGE2_SECTORS  32
%define STAGE2_MAGIC    0x32475453     ; "STG2" little-endian

start:
    cli

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    sti

    ; BIOS boot drive speichern
    mov [boot_drive], dl

    ; Marker: Stage1 läuft
    mov ah, 0x0E
    mov al, 'M'
    mov bh, 0
    int 0x10

    ; Stage2 per BIOS INT 13h Extended Read laden
    mov si, dap_stage2
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    ; Stage2 Magic prüfen
    mov bx, STAGE2_LOAD_OFF
    cmp dword [bx], STAGE2_MAGIC
    jne disk_error

    ; DL für Stage2 wiederherstellen
    mov dl, [boot_drive]

    ; Zu Stage2 springen, aber hinter den 4-byte Header
    jmp STAGE2_LOAD_SEG:STAGE2_ENTRY_OFF

disk_error:
    mov ah, 0x0E
    mov al, 'E'
    mov bh, 0
    int 0x10

.halt:
    hlt
    jmp .halt


; Disk Address Packet für INT 13h AH=42h
dap_stage2:
    db 0x10
    db 0x00
    dw STAGE2_SECTORS
    dw STAGE2_LOAD_OFF
    dw STAGE2_LOAD_SEG
    dq STAGE2_LBA

boot_drive:
    db 0

times 510-($-$$) db 0
dw 0xAA55