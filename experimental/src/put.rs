//! Numbers to text and back, without `core::fmt`.

/// `v` in hexadecimal with `0x` in front.
pub fn hex(v: u64, buf: &mut [u8; 18]) -> &[u8] {
    let mut i = buf.len();
    let mut v = v;
    loop {
        i -= 1;
        buf[i] = b"0123456789abcdef"[(v & 15) as usize];
        v >>= 4;
        if v == 0 {
            break;
        }
    }
    buf[i - 1] = b'x';
    buf[i - 2] = b'0';
    &buf[i - 2..]
}

/// `v` in decimal.
pub fn dec(v: u64, buf: &mut [u8; 20]) -> &[u8] {
    let mut i = buf.len();
    let mut v = v;
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    &buf[i..]
}

/// Hexadecimal digits, without a prefix. None if empty, not hexadecimal
/// or more than 64 bits.
pub fn parse_hex(s: &[u8]) -> Option<u64> {
    if s.is_empty() || s.len() > 16 {
        return None;
    }
    let mut v = 0u64;
    for &c in s {
        let d = match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => return None,
        };
        v = v << 4 | d as u64;
    }
    Some(v)
}

/// Decimal digits. None if empty, not decimal or more than 64 bits.
pub fn parse_dec(s: &[u8]) -> Option<u64> {
    if s.is_empty() {
        return None;
    }
    let mut v = 0u64;
    for &c in s {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u64)?;
    }
    Some(v)
}
