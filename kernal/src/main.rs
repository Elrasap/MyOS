#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;

mod idt;
mod exceptions;

const COM1: u16 = 0x3F8;

#[repr(C)]
pub struct BootInfo {
    pub boot_drive: u8,
    pub _reserved: [u8; 7],
    pub e820_entry_count: u64,
    pub e820_entries_addr: u64,
}

unsafe extern "C" {
    static mut __bss_start: u8;
    static mut __bss_end: u8;
}

#[no_mangle]
pub extern "sysv64" fn _start(boot_info: *const BootInfo) -> ! {
    serial_init();

    unsafe {
        zero_bss();
    }

    kernel_main(boot_info)
}

fn kernel_main(boot_info: *const BootInfo) -> ! {
    serial_write_str("K\n");

    if boot_info.is_null() {
        kernel_panic("BootInfo pointer is null");
    }

    let info = unsafe { &*boot_info };

    serial_write_str("BootInfo found\n");

    serial_write_str("E820 entries: ");
    serial_write_u64(info.e820_entry_count);
    serial_write_str("\n");

    serial_write_str("Boot drive: 0x");
    serial_write_hex_u8(info.boot_drive);
    serial_write_str("\n");

    serial_write_str("Installing IDT\n");
    idt::init();

    serial_write_str("IDT loaded\n");

    serial_write_str("Triggering test exception\n");

    unsafe {
        asm!("ud2");
    }

    serial_write_str("This should never print\n");

    halt_loop()
}

unsafe fn zero_bss() {
    let mut ptr = core::ptr::addr_of_mut!(__bss_start);
    let end = core::ptr::addr_of_mut!(__bss_end);

    while ptr < end {
        ptr.write_volatile(0);
        ptr = ptr.add(1);
    }
}

pub fn kernel_panic(message: &str) -> ! {
    serial_write_str("\nKERNEL PANIC: ");
    serial_write_str(message);
    serial_write_str("\n");

    halt_loop()
}

pub fn halt_loop() -> ! {
    serial_write_str("Kernel halted\n");

    loop {
        unsafe {
            asm!("cli");
            asm!("hlt");
        }
    }
}

pub fn serial_init() {
    unsafe {
        outb(COM1 + 1, 0x00);
        outb(COM1 + 3, 0x80);
        outb(COM1 + 0, 0x03);
        outb(COM1 + 1, 0x00);
        outb(COM1 + 3, 0x03);
        outb(COM1 + 2, 0xC7);
        outb(COM1 + 4, 0x0B);
    }
}

pub fn serial_write_str(s: &str) {
    for byte in s.bytes() {
        serial_write_byte(byte);
    }
}

pub fn serial_write_byte(byte: u8) {
    while !serial_can_send() {}

    unsafe {
        outb(COM1, byte);
    }
}

fn serial_can_send() -> bool {
    unsafe { inb(COM1 + 5) & 0x20 != 0 }
}

pub fn serial_write_u64(mut value: u64) {
    if value == 0 {
        serial_write_byte(b'0');
        return;
    }

    let mut buffer = [0u8; 20];
    let mut i = 0;

    while value > 0 {
        buffer[i] = b'0' + (value % 10) as u8;
        value /= 10;
        i += 1;
    }

    while i > 0 {
        i -= 1;
        serial_write_byte(buffer[i]);
    }
}

pub fn serial_write_hex_u64(value: u64) {
    for i in (0..16).rev() {
        let nibble = ((value >> (i * 4)) & 0xF) as u8;
        serial_write_hex_digit(nibble);
    }
}

pub fn serial_write_hex_u8(value: u8) {
    let high = value >> 4;
    let low = value & 0x0F;

    serial_write_hex_digit(high);
    serial_write_hex_digit(low);
}

fn serial_write_hex_digit(value: u8) {
    let c = match value {
        0..=9 => b'0' + value,
        10..=15 => b'A' + (value - 10),
        _ => b'?',
    };

    serial_write_byte(c);
}

unsafe fn outb(port: u16, value: u8) {
    asm!(
        "out dx, al",
        in("dx") port,
        in("al") value,
        options(nomem, nostack, preserves_flags)
    );
}

unsafe fn inb(port: u16) -> u8 {
    let value: u8;

    asm!(
        "in al, dx",
        out("al") value,
        in("dx") port,
        options(nomem, nostack, preserves_flags)
    );

    value
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    kernel_panic("Rust panic");
}