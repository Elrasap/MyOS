; boot/stage2/stage2.asm
; NASM second-stage BIOS bootloader, loaded at physical 0x8000.
;
; What this does:
;   - Starts with magic 'STG2' at 0x8000.
;   - Actual code starts at 0x8004.
;   - Prints '2'.
;   - Enables and tests A20.
;   - Collects the BIOS E820 memory map.
;   - Reads the kernel file from disk into a temporary low-memory buffer.
;   - Switches to 32-bit protected mode.
;   - If the kernel file is ELF64, loads its PT_LOAD segments.
;   - If it is not ELF, treats it as a flat binary and copies it to 1 MiB.
;   - Builds identity paging for the first 1 GiB using 2 MiB pages.
;   - Enters x86_64 long mode.
;   - Passes BootInfo pointer in RDI.
;   - Jumps to the kernel entry point.
;
; Limitations:
;   - ELF64 support is intentionally minimal.
;   - ELF entry, program header table, PT_LOAD destinations, filesz, and memsz
;     must fit below 4 GiB.
;   - PT_LOAD physical addresses should be >= 1 MiB and < 1 GiB.
;   - The whole kernel file must fit in KERNEL_FILE_SECTORS.

BITS 16
ORG 0x8000

; ---------------- User-adjustable constants ----------------
%define STAGE2_MAGIC          0x32475453     ; 'STG2'

%define KERNEL_FILE_LBA       33             ; MBR=0, stage2=1..32, kernel starts at 33
%define KERNEL_FILE_SECTORS   128            ; 128 * 512 = 64 KiB loaded from disk
%define READ_CHUNK_SECTORS    32             ; avoid BIOS/DMA boundary problems

%define KERNEL_TEMP_ADDR      0x00010000     ; temporary kernel-file buffer below 1 MiB
%define KERNEL_FLAT_LOAD_ADDR 0x00100000     ; flat binary load address / fallback entry

; Keep these away from stage2 at 0x8000..0xBFFF.
%define BOOTINFO_ADDR         0x00005000
%define E820_BUF_ADDR         0x00005200
%define E820_MAX_ENTRIES      64
%define REALMODE_STACK        0x00007000

%define PML4_ADDR             0x00070000
%define PDPT_ADDR             0x00071000
%define PD_ADDR               0x00072000
%define LONGMODE_STACK        0x0007E000
%define PROTMODE_STACK        0x0007F000

; GDT selectors.
%define SEL_CODE32            0x08
%define SEL_DATA32            0x10
%define SEL_CODE64            0x18
%define SEL_DATA64            0x20

; ELF constants.
%define ELF_MAGIC             0x464C457F     ; bytes: 7F 45 4C 46
%define ELFCLASS64            2
%define ELFDATA2LSB           1
%define EM_X86_64             0x3E
%define PT_LOAD               1
%define ELF64_PHDR_SIZE       56

; ---------------- Stage2 header ----------------
; MBR checks this magic at 0x8000, then jumps to 0x8004.
dd STAGE2_MAGIC

stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, REALMODE_STACK
    sti

    ; Progress marker: 2 = stage2 started.
    mov ah, 0x0E
    mov al, '2'
    mov bh, 0x00
    int 0x10

    ; Save boot drive from DL.
    mov [boot_drive], dl

    call enable_a20
    call a20_test
    jc fatal_real

    call e820_collect
    jc fatal_real

    call load_kernel_file_real
    jc fatal_real

    ; This never returns. It switches to protected mode, then long mode.
    jmp enter_protected_mode

fatal_real:
    mov ah, 0x0E
    mov al, '!'
    mov bh, 0x00
    int 0x10
.halt:
    cli
    hlt
    jmp .halt

; ------------------------------------------------------------
; Enable A20 using the fast A20 gate.
; ------------------------------------------------------------
enable_a20:
    in al, 0x92
    or al, 00000010b          ; set A20 enable bit
    and al, 11111110b         ; clear system reset bit
    out 0x92, al
    ret

; ------------------------------------------------------------
; Test A20.
; CF=0 success, CF=1 failure.
; ------------------------------------------------------------
a20_test:
    push ds
    push es
    push si
    push di
    push ax
    push bx

    cli
    xor ax, ax
    mov ds, ax                ; DS:0x0000 = physical 0x000000
    mov ax, 0xFFFF
    mov es, ax                ; ES:0x0010 = physical 0x100000

    xor si, si
    mov di, 0x0010

    mov al, [ds:si]
    mov bl, [es:di]

    mov byte [ds:si], 0x00
    mov byte [es:di], 0xFF

    cmp byte [ds:si], 0x00
    jne .fail
    cmp byte [es:di], 0xFF
    jne .fail

    ; Restore original bytes.
    mov [ds:si], al
    mov [es:di], bl
    sti
    clc
    jmp .done

.fail:
    ; Best-effort restore.
    mov [ds:si], al
    mov [es:di], bl
    sti
    stc

.done:
    pop bx
    pop ax
    pop di
    pop si
    pop es
    pop ds
    ret

; ------------------------------------------------------------
; Collect BIOS E820 memory map.
;
; BootInfo at BOOTINFO_ADDR:
;   u32 e820_count
;   u32 e820_addr
;   u32 boot_drive
;   u32 reserved
;
; E820 entries at E820_BUF_ADDR, 24 bytes each:
;   u64 base
;   u64 length
;   u32 type
;   u32 acpi_ext
;
; CF=0 success, CF=1 failure.
; ------------------------------------------------------------
e820_collect:
    push ds
    push es
    push di
    push si
    push bx

    xor ax, ax
    mov ds, ax
    mov es, ax

    mov dword [BOOTINFO_ADDR + 0], 0
    mov dword [BOOTINFO_ADDR + 4], E820_BUF_ADDR
    movzx eax, byte [boot_drive]
    mov dword [BOOTINFO_ADDR + 8], eax
    mov dword [BOOTINFO_ADDR + 12], 0

    xor ebx, ebx              ; continuation value
    mov di, E820_BUF_ADDR
    xor si, si                ; entry count

.next:
    ; ACPI 3.0 extended attributes. Some BIOSes expect this initialized.
    mov dword [es:di + 20], 1

    mov eax, 0xE820
    mov edx, 0x534D4150       ; 'SMAP'
    mov ecx, 24
    int 0x15
    jc .fail

    cmp eax, 0x534D4150
    jne .fail

    ; Accept entries >= 20 bytes. We reserve/store 24 bytes per entry.
    cmp ecx, 20
    jb .fail

    inc si
    add di, 24

    cmp si, E820_MAX_ENTRIES
    jae .success

    test ebx, ebx
    jne .next

.success:
    movzx eax, si
    mov dword [BOOTINFO_ADDR + 0], eax
    clc
    jmp .done

.fail:
    stc

.done:
    pop bx
    pop si
    pop di
    pop es
    pop ds
    ret

; ------------------------------------------------------------
; Read the kernel file from disk into KERNEL_TEMP_ADDR.
; Reads in small chunks so the BIOS buffer does not cross awkward boundaries.
; CF=0 success, CF=1 failure.
; ------------------------------------------------------------
load_kernel_file_real:
    push ds
    push si
    push bx
    push cx
    push dx

    xor ax, ax
    mov ds, ax

    mov word  [read_remaining], KERNEL_FILE_SECTORS
    mov dword [read_lba_low], KERNEL_FILE_LBA
    mov dword [read_lba_high], 0
    mov word  [read_dest_seg], (KERNEL_TEMP_ADDR >> 4)

.read_loop:
    cmp word [read_remaining], 0
    je .success

    mov ax, [read_remaining]
    cmp ax, READ_CHUNK_SECTORS
    jbe .count_ok
    mov ax, READ_CHUNK_SECTORS
.count_ok:
    mov [read_count], ax

    mov byte  [dap_kernel + 0], 0x10
    mov byte  [dap_kernel + 1], 0
    mov word  [dap_kernel + 2], ax
    mov word  [dap_kernel + 4], 0x0000
    mov bx, [read_dest_seg]
    mov word  [dap_kernel + 6], bx
    mov eax, [read_lba_low]
    mov dword [dap_kernel + 8], eax
    mov eax, [read_lba_high]
    mov dword [dap_kernel + 12], eax

    mov dl, [boot_drive]
    mov si, dap_kernel
    mov ah, 0x42
    int 0x13
    jc .fail

    ; remaining -= count
    mov ax, [read_count]
    sub [read_remaining], ax

    ; LBA += count
    movzx eax, word [read_count]
    add [read_lba_low], eax
    adc dword [read_lba_high], 0

    ; segment += count * 512 / 16 = count * 32
    mov ax, [read_count]
    shl ax, 5
    add [read_dest_seg], ax

    jmp .read_loop

.success:
    clc
    jmp .done

.fail:
    stc

.done:
    pop dx
    pop cx
    pop bx
    pop si
    pop ds
    ret

; ------------------------------------------------------------
; Switch to 32-bit protected mode.
; ------------------------------------------------------------
enter_protected_mode:
    cli
    lgdt [gdt_desc]

    mov eax, cr0
    or eax, 1                ; CR0.PE
    mov cr0, eax

    jmp SEL_CODE32:pm32_entry

; ============================================================
; 32-bit protected mode
; ============================================================
BITS 32
pm32_entry:
    mov ax, SEL_DATA32
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    mov esp, PROTMODE_STACK

    call load_kernel_image_pm
    call build_page_tables_pm

    ; Enable PAE.
    mov eax, cr4
    or eax, (1 << 5)
    mov cr4, eax

    ; Load PML4.
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable IA32_EFER.LME.
    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr

    ; Enable paging. Long mode becomes active after the far jump below.
    mov eax, cr0
    or eax, (1 << 31)        ; CR0.PG
    mov cr0, eax

    jmp SEL_CODE64:lm64_entry

; ------------------------------------------------------------
; Load either ELF64 or flat kernel image.
; On success: [kernel_entry32] contains the low 32 bits of entry point.
; ------------------------------------------------------------
load_kernel_image_pm:
    mov esi, KERNEL_TEMP_ADDR

    cmp dword [esi + 0], ELF_MAGIC
    jne .flat_binary

    ; Validate minimal ELF64 x86_64 little-endian executable/shared image.
    cmp byte [esi + 4], ELFCLASS64
    jne pm_fatal
    cmp byte [esi + 5], ELFDATA2LSB
    jne pm_fatal
    cmp word [esi + 18], EM_X86_64
    jne pm_fatal

    ; e_entry must fit in low 32 bits for this minimal loader.
    cmp dword [esi + 0x1C], 0
    jne pm_fatal
    mov eax, [esi + 0x18]
    mov [kernel_entry32], eax

    ; e_phoff must fit in low 32 bits.
    cmp dword [esi + 0x24], 0
    jne pm_fatal
    mov ebx, [esi + 0x20]
    add ebx, KERNEL_TEMP_ADDR

    movzx ecx, word [esi + 0x38]       ; e_phnum
    movzx eax, word [esi + 0x36]       ; e_phentsize
    cmp eax, ELF64_PHDR_SIZE
    jne pm_fatal
    mov [elf_phentsize32], eax

.ph_loop:
    test ecx, ecx
    jz .elf_done

    cmp dword [ebx + 0], PT_LOAD
    jne .next_ph

    ; p_offset high dword must be zero.
    cmp dword [ebx + 12], 0
    jne pm_fatal

    ; Destination = p_paddr if nonzero, otherwise p_vaddr.
    cmp dword [ebx + 28], 0            ; p_paddr high
    jne pm_fatal
    mov edi, [ebx + 24]                ; p_paddr low

    test edi, edi
    jne .have_dest

    cmp dword [ebx + 20], 0            ; p_vaddr high
    jne pm_fatal
    mov edi, [ebx + 16]                ; p_vaddr low

.have_dest:
    ; Do not let the kernel overwrite the loader's low-memory workspace.
    cmp edi, 0x00100000
    jb pm_fatal

    ; filesz and memsz must fit in low 32 bits.
    cmp dword [ebx + 36], 0            ; p_filesz high
    jne pm_fatal
    cmp dword [ebx + 44], 0            ; p_memsz high
    jne pm_fatal

    mov edx, [ebx + 32]                ; filesz
    mov ebp, [ebx + 40]                ; memsz
    cmp ebp, edx
    jb pm_fatal

    ; Destination + memsz must stay within the identity-mapped first 1 GiB.
    mov eax, edi
    add eax, ebp
    jc pm_fatal
    cmp eax, 0x40000000
    ja pm_fatal

    ; p_offset + filesz must be inside the loaded kernel file buffer.
    mov eax, [ebx + 8]
    add eax, edx
    jc pm_fatal
    cmp eax, (KERNEL_FILE_SECTORS * 512)
    ja pm_fatal

    ; Source = KERNEL_TEMP_ADDR + p_offset.
    mov esi, KERNEL_TEMP_ADDR
    add esi, [ebx + 8]

    ; Copy file bytes.
    push ecx
    push ebx
    mov ecx, edx
    rep movsb

    ; Zero BSS: memsz - filesz.
    mov ecx, ebp
    sub ecx, edx
    xor eax, eax
    rep stosb

    pop ebx
    pop ecx

.next_ph:
    add ebx, [elf_phentsize32]
    dec ecx
    jmp .ph_loop

.elf_done:
    ret

.flat_binary:
    mov esi, KERNEL_TEMP_ADDR
    mov edi, KERNEL_FLAT_LOAD_ADDR
    mov ecx, (KERNEL_FILE_SECTORS * 512)
    rep movsb

    mov dword [kernel_entry32], KERNEL_FLAT_LOAD_ADDR
    ret

; ------------------------------------------------------------
; Build identity paging for 0..1 GiB using 2 MiB pages.
; ------------------------------------------------------------
build_page_tables_pm:
    ; Clear PML4, PDPT, and PD.
    mov edi, PML4_ADDR
    mov ecx, (0x3000 / 4)
    xor eax, eax
    rep stosd

    ; PML4[0] -> PDPT.
    mov eax, PDPT_ADDR
    or eax, 0x003            ; Present | Writable
    mov dword [PML4_ADDR + 0], eax
    mov dword [PML4_ADDR + 4], 0

    ; PDPT[0] -> PD.
    mov eax, PD_ADDR
    or eax, 0x003            ; Present | Writable
    mov dword [PDPT_ADDR + 0], eax
    mov dword [PDPT_ADDR + 4], 0

    ; PD[0..511] = 512 huge pages, each 2 MiB, total 1 GiB.
    mov edi, PD_ADDR
    xor ebx, ebx             ; physical base of current 2 MiB page
    mov ecx, 512
.map_loop:
    mov eax, ebx
    or eax, 0x083            ; Present | Writable | Page Size
    mov dword [edi + 0], eax
    mov dword [edi + 4], 0
    add ebx, 0x00200000
    add edi, 8
    loop .map_loop

    ret

; Protected-mode fatal error. BIOS interrupts are no longer available.
pm_fatal:
    mov dword [0xB8000], 0x4F214F50     ; displays P! in white-on-red-ish text memory
.halt:
    cli
    hlt
    jmp .halt

; ============================================================
; 64-bit long mode
; ============================================================
BITS 64
lm64_entry:
    mov ax, SEL_DATA64
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov rsp, LONGMODE_STACK

    ; First kernel argument: BootInfo pointer in RDI.
    mov edi, BOOTINFO_ADDR

    ; Jump to kernel entry.
    mov eax, [kernel_entry32]
    jmp rax

; ============================================================
; Data and descriptors
; ============================================================
BITS 16

boot_drive:        db 0

read_remaining:    dw 0
read_count:        dw 0
read_dest_seg:     dw 0
read_lba_low:      dd 0
read_lba_high:     dd 0

dap_kernel:
    times 16 db 0

kernel_entry32:    dd KERNEL_FLAT_LOAD_ADDR
elf_phentsize32:   dd ELF64_PHDR_SIZE

align 8
gdt:
    dq 0x0000000000000000          ; null descriptor
    dq 0x00CF9A000000FFFF          ; 0x08: 32-bit code
    dq 0x00CF92000000FFFF          ; 0x10: 32-bit data
    dq 0x00AF9A000000FFFF          ; 0x18: 64-bit code
    dq 0x00AF92000000FFFF          ; 0x20: 64-bit data

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt
gdt_end:
