#![no_std]
#![no_main]

mod vga;

use core::panic::PanicInfo;

#[repr(C)]
pub struct BootInfo {
    pub e820_count: u32,
    pub e820_addr: u32,
    pub boot_drive: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct E820Entry {
    pub base: u64,
    pub length: u64,
    pub entry_type: u32,
    pub acpi_ext: u32,
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        unsafe {
            core::arch::asm!("hlt");
        }
    }
}

#[no_mangle]
pub extern "C" fn _start(boot_info: *const BootInfo) -> ! {
    vga::clear_screen();
    vga::write_string("Rust kernel reached!\n\n");

    unsafe {
        if boot_info.is_null() {
            vga::write_string("No BootInfo pointer!\n");
            halt();
        }

        let info = &*boot_info;

        vga::write_string("E820 entries: ");
        vga::write_decimal(info.e820_count);
        vga::write_string("\n");

        vga::write_string("Boot drive: ");
        vga::write_hex(info.boot_drive as u64);
        vga::write_string("\n\n");

        vga::write_string("Memory Map:\n");

        let entries = info.e820_addr as *const E820Entry;

        let mut i = 0;
        while i < info.e820_count {
            let entry = &*entries.add(i as usize);

            vga::write_string("Entry ");
            vga::write_decimal(i);
            vga::write_string("\n");

            vga::write_string("  Base:   ");
            vga::write_hex(entry.base);
            vga::write_string("\n");

            vga::write_string("  Length: ");
            vga::write_hex(entry.length);
            vga::write_string("\n");

            vga::write_string("  Type:   ");
            vga::write_decimal(entry.entry_type);
            vga::write_string("\n\n");

            i += 1;
        }
    }

    halt();
}

fn halt() -> ! {
    loop {
        unsafe {
            core::arch::asm!("hlt");
        }
    }
}