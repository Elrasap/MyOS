use core::arch::asm;

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct IdtEntry {
    offset_low: u16,
    selector: u16,
    ist: u8,
    attributes: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
}

impl IdtEntry {
    const fn missing() -> Self {
        Self {
            offset_low: 0,
            selector: 0,
            ist: 0,
            attributes: 0,
            offset_mid: 0,
            offset_high: 0,
            zero: 0,
        }
    }

    fn set_handler(&mut self, handler: usize) {
        self.offset_low = handler as u16;
        self.selector = 0x08;
        self.ist = 0;
        self.attributes = 0x8E;
        self.offset_mid = (handler >> 16) as u16;
        self.offset_high = (handler >> 32) as u32;
        self.zero = 0;
    }
}

#[repr(C, packed)]
struct IdtPointer {
    limit: u16,
    base: u64,
}

static mut IDT: [IdtEntry; 256] = [IdtEntry::missing(); 256];

unsafe extern "C" {
    fn isr0();
    fn isr6();
    fn isr8();
    fn isr13();
    fn isr14();
}

pub fn init() {
    unsafe {
        IDT[0].set_handler(isr0 as usize);   // Divide by zero
        IDT[6].set_handler(isr6 as usize);   // Invalid opcode
        IDT[8].set_handler(isr8 as usize);   // Double fault
        IDT[13].set_handler(isr13 as usize); // General protection fault
        IDT[14].set_handler(isr14 as usize); // Page fault

        let idt_ptr = IdtPointer {
            limit: core::mem::size_of::<[IdtEntry; 256]>() as u16 - 1,
            base: core::ptr::addr_of!(IDT) as u64,
        };

        asm!(
            "lidt [{}]",
            in(reg) &idt_ptr,
            options(readonly, nostack, preserves_flags)
        );
    }
}