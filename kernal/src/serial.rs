const COM1: u16 = 0x3F8;

unsafe fn outb(port: u16, value: u8) {
    core::arch::asm!(
        "out dx, al",
        in("dx") port,
        in("al") value,
        options(nomem, nostack, preserves_flags)
    );
}

unsafe fn inb(port: u16) -> u8 {
    let value: u8;

    core::arch::asm!(
        "in al, dx",
        out("al") value,
        in("dx") port,
        options(nomem, nostack, preserves_flags)
    );

    value
}

pub fn init() {
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

fn is_transmit_empty() -> bool {
    unsafe {
        inb(COM1 + 5) & 0x20 != 0
    }
}

pub fn write_byte(byte: u8) {
    while !is_transmit_empty() {}

    unsafe {
        outb(COM1, byte);
    }
}

pub fn write_string(s: &str) {
    for byte in s.bytes() {
        write_byte(byte);
    }
}