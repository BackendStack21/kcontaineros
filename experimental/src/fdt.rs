//! Just enough flattened device tree to learn where RAM is and how much
//! there is. Every read is bounds checked: a malformed tree is None.

const MAGIC: u32 = 0xd00d_feed;

fn be32(d: &[u8], off: usize) -> Option<u32> {
    let b = d.get(off..off.checked_add(4)?)?;
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

fn cstr(d: &[u8], off: usize) -> Option<&[u8]> {
    let rest = d.get(off..)?;
    let len = rest.iter().position(|&b| b == 0)?;
    Some(&rest[..len])
}

/// A number of `cells` 32-bit cells at `off`.
fn cells(d: &[u8], off: usize, cells: u32) -> Option<u64> {
    match cells {
        1 => Some(be32(d, off)? as u64),
        2 => Some((be32(d, off)? as u64) << 32 | be32(d, off + 4)? as u64),
        _ => None,
    }
}

/// The size of the whole tree, from its first eight bytes.
pub fn total_size(head: &[u8]) -> Option<usize> {
    if be32(head, 0)? != MAGIC {
        return None;
    }
    Some(be32(head, 4)? as usize)
}

/// Base and size of the first region of the `/memory` node.
pub fn memory(d: &[u8]) -> Option<(u64, u64)> {
    if be32(d, 0)? != MAGIC {
        return None;
    }
    let strings = be32(d, 12)? as usize;
    let mut p = be32(d, 8)? as usize;
    let mut depth = 0u32;
    let (mut addr_cells, mut size_cells) = (2, 1);
    let mut in_memory = false;
    loop {
        let token = be32(d, p)?;
        p += 4;
        match token {
            // FDT_BEGIN_NODE: the name, padded to four bytes.
            1 => {
                let name = cstr(d, p)?;
                p = (p + name.len() + 4) & !3;
                depth += 1;
                in_memory = depth == 2 && (name == b"memory" || name.starts_with(b"memory@"));
            }
            // FDT_END_NODE
            2 => {
                depth = depth.checked_sub(1)?;
                in_memory = false;
                if depth == 0 {
                    return None;
                }
            }
            // FDT_PROP: length, name offset, value padded to four bytes.
            3 => {
                let len = be32(d, p)? as usize;
                let name = cstr(d, strings + be32(d, p + 4)? as usize)?;
                p += 8;
                let value = d.get(p..p + len)?;
                p = (p + len + 3) & !3;
                if depth == 1 && name == b"#address-cells" {
                    addr_cells = be32(value, 0)?;
                } else if depth == 1 && name == b"#size-cells" {
                    size_cells = be32(value, 0)?;
                } else if in_memory && name == b"reg" {
                    let base = cells(value, 0, addr_cells)?;
                    let size = cells(value, 4 * addr_cells as usize, size_cells)?;
                    return Some((base, size));
                }
            }
            // FDT_NOP
            4 => {}
            // FDT_END, or something that is not a token.
            _ => return None,
        }
    }
}
