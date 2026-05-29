const VGA_BUFFER: *mut u8 = 0xb8000 as *mut u8;
const WIDTH: usize = 80;
const HEIGHT: usize = 25;
const COLOR: u8 = 0x0f;

static mut ROW: usize = 0;
static mut COL: usize = 0;

pub fn clear_screen() {
    unsafe {
        for row in 0..HEIGHT {
            for col in 0..WIDTH {
                let index = (row * WIDTH + col) * 2;

                VGA_BUFFER.add(index).write_volatile(b' ');
                VGA_BUFFER.add(index + 1).write_volatile(COLOR);
            }
        }

        ROW = 0;
        COL = 0;
    }
}

pub fn write_string(s: &str) {
    for byte in s.bytes() {
        write_byte(byte);
    }
}

pub fn write_decimal(mut n: u32) {
    if n == 0 {
        write_byte(b'0');
        return;
    }

    let mut buf = [0u8; 10];
    let mut i = 0;

    while n > 0 {
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        i += 1;
    }

    while i > 0 {
        i -= 1;
        write_byte(buf[i]);
    }
}

pub fn write_hex(mut n: u64) {
    write_string("0x");

    let mut started = false;

    for i in (0..16).rev() {
        let digit = ((n >> (i * 4)) & 0xF) as u8;

        if digit != 0 || started || i == 0 {
            started = true;

            let c = match digit {
                0..=9 => b'0' + digit,
                _ => b'A' + (digit - 10),
            };

            write_byte(c);
        }
    }
}

fn write_byte(byte: u8) {
    unsafe {
        if byte == b'\n' {
            newline();
            return;
        }

        let index = (ROW * WIDTH + COL) * 2;

        VGA_BUFFER.add(index).write_volatile(byte);
        VGA_BUFFER.add(index + 1).write_volatile(COLOR);

        COL += 1;

        if COL >= WIDTH {
            newline();
        }
    }
}

fn newline() {
    unsafe {
        COL = 0;
        ROW += 1;

        if ROW >= HEIGHT {
            ROW = 0;
        }
    }
}