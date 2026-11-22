//! The checksum of POSIX `cksum`, so the image can be made with a shell
//! script. It finds corruption; it does not authenticate anything.

fn step(mut crc: u32, byte: u8) -> u32 {
    crc ^= (byte as u32) << 24;
    for _ in 0..8 {
        crc = if crc & 0x8000_0000 != 0 { (crc << 1) ^ 0x04C1_1DB7 } else { crc << 1 };
    }
    crc
}

pub fn cksum(data: &[u8]) -> u32 {
    let mut crc = 0;
    for &b in data {
        crc = step(crc, b);
    }
    let mut len = data.len();
    while len != 0 {
        crc = step(crc, len as u8);
        len >>= 8;
    }
    !crc
}
