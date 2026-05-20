; boot/stage2/stage2.asm
; NASM, initially 16-bit real mode at ORG 0x8000
; - Prints '2'
; - Enables A20 (fast gate)
; - Collects BIOS E820 memory map
; - Loads a flat kernel from disk to 0x0010_0000
; - Enters x86_64 long mode with identity map of first 2 MiB
; - Jumps to kernel entry at 0x0010_0000
; - Passes BootInfo pointer in RDI

BITS 16
ORG 0x8000

; ----------- Constants you may want to change -----------
%define STAGE2_MAGIC        0x32475453     ; 'STG2'
%define BOOTINFO_ADDR       0x00009000     ; BootInfo struct (below 1 MiB)
%define E820_BUF_ADDR       0x00009200     ; E820 entries buffer
%define E820_MAX_ENTRIES    64

%define KERNEL_LOAD_ADDR    0x00100000     ; 1 MiB physical
%define KERNEL_LBA          33             ; kernel starts right after stage2 (LBA=1..32 used by stage2)
%define KERNEL_SECTORS      128            ; 128 * 512 = 64 KiB kernel (adjust as needed)

%define PML4_ADDR           0x0000A000
%define PDPT_ADDR           0x0000B000
%define PD_ADDR             0x0000C000

; Segment selectors (from our GDT)
%define SEL_CODE32          0x08
%define SEL_DATA32          0x10
%define SEL_CODE64          0x18
%define SEL_DATA64          0x20

; ---------------- Stage2 header (magic) ----------------
dd STAGE2_MAGIC

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x9000
    sti

    ; Print '2'
    mov ah, 0x0E
    mov al, '2'
    mov bh, 0x00
    int 0x10

    ; Save boot drive (DL) passed from stage1
    mov [boot_drive], dl

    ; Enable A20 (fast gate)
    call enable_a20
    call a20_test
    jc fatal

    ; Collect E820 map into E820_BUF_ADDR and store count into BootInfo
    call e820_collect
    jc fatal

    ; Load flat kernel from disk into 0x0010_0000
    call load_kernel
    jc fatal

    ; Enter long mode and jump to kernel
    call enter_long_mode

fatal:
    mov ah, 0x0E
    mov al, '!'
    mov bh, 0x00
    int 0x10
.halt:
    hlt
    jmp .halt

; -------------------------------------------------------
; A20 enable (fast A20 gate)
; -------------------------------------------------------
enable_a20:
    in al, 0x92
    or al, 00000010b        ; set A20 enable
    and al, 11111110b       ; clear reset bit
    out 0x92, al
    ret

; Simple A20 alias test:
; Writes and compares at 0x000000 and 0x100000 via segment tricks.
; CF=1 on failure, CF=0 on success.
a20_test:
    pushf
    push ds
    push es
    cli

    xor ax, ax
    mov ds, ax              ; DS=0x0000
    mov ax, 0xFFFF
    mov es, ax              ; ES=0xFFFF -> ES:0x0010 == physical 0x100000

    ; Save original bytes
    mov si, 0x0000
    mov di, 0x0010
    mov al, [ds:si]
    mov bl, [es:di]

    ; Write test pattern
    mov byte [ds:si], 0x00
    mov byte [es:di], 0xFF

    ; If A20 is OFF, these alias and DS:0 changes too.
    cmp byte [ds:si], 0x00
    jne .fail
    cmp byte [es:di], 0xFF
    jne .fail

    ; Restore
    mov [ds:si], al
    mov [es:di], bl

    clc
    jmp .done

.fail:
    ; Restore best-effort
    mov [ds:si], al
    mov [es:di], bl
    stc

.done:
    pop es
    pop ds
    popf
    ret

; -------------------------------------------------------
; BootInfo + E820 collection
; BootInfo layout at BOOTINFO_ADDR:
;   u32 e820_count
;   u32 e820_addr   (physical address of entries)
;   u32 boot_drive  (DL)
;   u32 reserved
; Entries are 24 bytes each (E820 "SMAP" v1):
;   u64 base, u64 length, u32 type, u32 acpi_ext
; -------------------------------------------------------
e820_collect:
    pushf
    push ds
    push es
    push di
    push si
    cli

    xor ax, ax
    mov ds, ax
    mov es, ax

    ; Write BootInfo basics
    mov dword [BOOTINFO_ADDR + 0], 0          ; e820_count = 0
    mov dword [BOOTINFO_ADDR + 4], E820_BUF_ADDR
    movzx eax, byte [boot_drive]
    mov dword [BOOTINFO_ADDR + 8], eax        ; boot_drive
    mov dword [BOOTINFO_ADDR + 12], 0

    xor ebx, ebx                              ; continuation value = 0
    mov di, E820_BUF_ADDR
    xor si, si                                 ; entry count in SI

.next:
    mov eax, 0xE820
    mov edx, 0x534D4150                        ; 'SMAP'
    mov ecx, 24
    ; ES:DI points to buffer for entry
    int 0x15
    jc .fail
    cmp eax, 0x534D4150
    jne .fail

    ; Some BIOSes may return ECX < 24; we accept >= 20 but store 24 bytes anyway.
    inc si
    add di, 24

    cmp si, E820_MAX_ENTRIES
    jae .done

    test ebx, ebx
    jne .next

.done:
    movzx eax, si
    mov dword [BOOTINFO_ADDR + 0], eax        ; e820_count
    clc
    jmp .out

.fail:
    stc

.out:
    pop si
    pop di
    pop es
    pop ds
    popf
    ret

; -------------------------------------------------------
; Load kernel: INT 13h AH=42 extended read to KERNEL_LOAD_ADDR
; Uses DAP in memory. Reads KERNEL_SECTORS from KERNEL_LBA.
; -------------------------------------------------------
load_kernel:
    pushf
    push ds
    push si
    cli

    xor ax, ax
    mov ds, ax

    ; Prepare DAP for kernel load
    mov byte  [dap_k + 0], 0x10
    mov byte  [dap_k + 1], 0x00
    mov word  [dap_k + 2], KERNEL_SECTORS

    ; destination segment:offset for 0x0010_0000 = 0x1000:0x0000
    mov word  [dap_k + 4], 0x0000            ; off
    mov word  [dap_k + 6], 0x1000            ; seg

    mov dword [dap_k + 8], KERNEL_LBA        ; LBA low (fits in 32-bit here)
    mov dword [dap_k + 12], 0x00000000       ; LBA high

    mov dl, [boot_drive]
    mov si, dap_k
    mov ah, 0x42
    int 0x13
    jc .fail

    clc
    jmp .out

.fail:
    stc
.out:
    pop si
    pop ds
    popf
    ret

dap_k:
    times 16 db 0

boot_drive:
    db 0

; -------------------------------------------------------
; Enter long mode (x86_64) with identity mapping for first 2 MiB.
; Then jump to kernel at 0x0010_0000.
; Pass BootInfo pointer in RDI.
; -------------------------------------------------------
enter_long_mode:
    cli

    ; Build GDT and load it (still in real mode)
    lgdt [gdt_desc]

    ; Enable Protected Mode (CR0.PE=1)
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; Far jump to 32-bit protected mode
    jmp SEL_CODE32:pm32_entry

; ---------------- 32-bit Protected Mode ----------------
BITS 32
pm32_entry:
    mov ax, SEL_DATA32
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov esp, 0x0009F000

    ; Zero page tables region (PML4/PDPT/PD)
    mov edi, PML4_ADDR
    mov ecx, (0x3000 / 4)
    xor eax, eax
    rep stosd

    ; Set up identity map for 0..2MiB using a 2MiB page:
    ; PML4[0] -> PDPT
    mov eax, PDPT_ADDR
    or eax, 0x003              ; Present | RW
    mov dword [PML4_ADDR + 0], eax
    mov dword [PML4_ADDR + 4], 0

    ; PDPT[0] -> PD
    mov eax, PD_ADDR
    or eax, 0x003
    mov dword [PDPT_ADDR + 0], eax
    mov dword [PDPT_ADDR + 4], 0

    ; PD[0] = 2MiB page mapping 0..2MiB
    ; flags: Present|RW|PS
    mov eax, 0x00000000
    or eax, 0x083              ; P|RW|PS
    mov dword [PD_ADDR + 0], eax
    mov dword [PD_ADDR + 4], 0

    ; Enable PAE (CR4.PAE=1)
    mov eax, cr4
    or eax, (1 << 5)
    mov cr4, eax

    ; Load CR3 with PML4
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable Long Mode in EFER (IA32_EFER.LME=1)
    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr

    ; Enable paging (CR0.PG=1)
    mov eax, cr0
    or eax, (1 << 31)
    mov cr0, eax

    ; Far jump to 64-bit mode
    jmp SEL_CODE64:lm64_entry

; -------------------- 64-bit Long Mode -----------------
BITS 64
lm64_entry:
    mov ax, SEL_DATA64
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov rsp, 0x0009E000

    ; Put BootInfo pointer into RDI for the kernel
    mov rdi, BOOTINFO_ADDR

    ; Jump to kernel entry at physical 0x0010_0000 (identity mapped)
    mov rax, KERNEL_LOAD_ADDR
    jmp rax

; --------------------------- GDT ------------------------
BITS 16
gdt:
    dq 0x0000000000000000          ; null

    ; 0x08: 32-bit code segment
    dq 0x00CF9A000000FFFF

    ; 0x10: 32-bit data segment
    dq 0x00CF92000000FFFF

    ; 0x18: 64-bit code segment
    dq 0x00AF9A000000FFFF

    ; 0x20: 64-bit data segment
    dq 0x00AF92000000FFFF

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt
gdt_end:

