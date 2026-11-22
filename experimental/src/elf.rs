//! Just enough ELF: a static little-endian ARM64 executable and its
//! loadable segments. Every read is bounds checked; the file need not be
//! aligned in memory.

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;

fn le16(d: &[u8], off: usize) -> Option<u16> {
    let b = d.get(off..off.checked_add(2)?)?;
    Some(u16::from_le_bytes([b[0], b[1]]))
}

fn le32(d: &[u8], off: usize) -> Option<u32> {
    let b = d.get(off..off.checked_add(4)?)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn le64(d: &[u8], off: usize) -> Option<u64> {
    let lo = le32(d, off)? as u64;
    let hi = le32(d, off.checked_add(4)?)? as u64;
    Some(hi << 32 | lo)
}

pub struct Elf<'a> {
    data: &'a [u8],
    pub entry: u64,
    phoff: usize,
    phentsize: usize,
    pub phnum: usize,
}

pub struct Segment<'a> {
    pub vaddr: u64,
    pub memsz: u64,
    pub flags: u32,
    /// What the file holds of it; the rest of `memsz` is zero.
    pub bytes: &'a [u8],
}

impl Segment<'_> {
    /// The end of the segment in memory, or None if it wraps around.
    pub fn top(&self) -> Option<u64> {
        self.vaddr.checked_add(self.memsz)
    }
}

impl<'a> Elf<'a> {
    pub fn parse(data: &'a [u8]) -> Option<Elf<'a>> {
        // \x7fELF, 64-bit, little-endian; ET_EXEC; EM_AARCH64.
        if data.get(..6)? != b"\x7fELF\x02\x01" || le16(data, 16)? != 2 || le16(data, 18)? != 183 {
            return None;
        }
        let phentsize = le16(data, 54)? as usize;
        if phentsize < 56 {
            return None;
        }
        Some(Elf {
            data,
            entry: le64(data, 24)?,
            phoff: usize::try_from(le64(data, 32)?).ok()?,
            phentsize,
            phnum: le16(data, 56)? as usize,
        })
    }

    /// Program header `i`: Ok(None) if it is not PT_LOAD, Err if it is
    /// and does not fit the file.
    pub fn segment(&self, i: usize) -> Result<Option<Segment<'a>>, ()> {
        self.read(i).ok_or(())
    }

    fn read(&self, i: usize) -> Option<Option<Segment<'a>>> {
        let d = self.data;
        let ph = self.phoff.checked_add(i.checked_mul(self.phentsize)?)?;
        if le32(d, ph)? != 1 {
            // Still has to be a header that exists.
            d.get(ph..ph.checked_add(56)?)?;
            return Some(None);
        }
        let off = usize::try_from(le64(d, ph + 8)?).ok()?;
        let filesz = usize::try_from(le64(d, ph + 32)?).ok()?;
        let memsz = le64(d, ph + 40)?;
        if filesz as u64 > memsz {
            return None;
        }
        Some(Some(Segment {
            vaddr: le64(d, ph + 16)?,
            memsz,
            flags: le32(d, ph + 4)?,
            bytes: d.get(off..off.checked_add(filesz)?)?,
        }))
    }
}
