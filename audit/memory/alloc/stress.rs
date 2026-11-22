// Stress test of the kContainerOS allocator (track: memory, part c).
//
// heap.rs is cut out of src/main.rs by run_alloc.sh (from "struct Heap;" to
// "#[global_allocator]"), and sys.rs / util.rs are the real files, so this
// exercises the shipped code, not a copy. `Heap` is called directly through
// the GlobalAlloc trait; the bookkeeping lives in std's own allocator.
extern crate alloc;

#[allow(dead_code)]
#[path = "/src/sys.rs"]
mod sys;
#[allow(dead_code)]
#[path = "/src/util.rs"]
mod util;

use core::alloc::{GlobalAlloc, Layout};
use std::collections::BTreeMap;
use util::write_all;

include!("/work/heap.rs");

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

struct Block {
    layout: Layout,
    seed: u8,
}

fn fill(p: *mut u8, n: usize, seed: u8) {
    for i in 0..n {
        unsafe { *p.add(i) = seed.wrapping_add(i as u8).wrapping_mul(31) };
    }
}

fn verify(p: *const u8, n: usize, seed: u8) -> bool {
    (0..n).all(|i| unsafe { *p.add(i) } == seed.wrapping_add(i as u8).wrapping_mul(31))
}

fn pick_size(r: &mut Rng, small_only: bool) -> usize {
    match r.below(if small_only { 9 } else { 10 }) {
        0 => 1 + r.below(16) as usize,
        1..=4 => 1 + r.below(300) as usize,
        5 | 6 => 1 + r.below(5000) as usize,
        7 if small_only => 60000 + r.below(5537) as usize,
        7 => 60000 + r.below(12000) as usize, // around the 64 KiB class limit
        8 if small_only => 1usize << (4 + r.below(13)),
        8 => 1usize << (4 + r.below(14)), // exact powers of two, 16 .. 128 KiB
        _ => 65537 + r.below(1 << 20) as usize,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let ops: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(200_000);
    let max_align_shift: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(12);
    let mut r = Rng(0x9e3779b97f4a7c15 ^ args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1u64));
    let small_only = args.get(4).map(|s| s == "small").unwrap_or(false);
    let h = Heap;
    // start address -> block, for overlap checks
    let mut live: BTreeMap<usize, Block> = BTreeMap::new();
    let (mut allocs, mut reallocs, mut inplace, mut frees) = (0u64, 0u64, 0u64, 0u64);
    let mut errors = 0u64;
    let mut live_bytes = 0usize;
    let mut report = |what: &str, detail: String| {
        errors += 1;
        if errors <= 10 {
            println!("ERROR {}: {}", what, detail);
        }
    };
    let overlaps = |live: &BTreeMap<usize, Block>, p: usize, n: usize| -> Option<usize> {
        if let Some((&a, b)) = live.range(..=p).next_back() {
            if a + b.layout.size() > p {
                return Some(a);
            }
        }
        if let Some((&a, _)) = live.range(p..).next() {
            if a < p + n {
                return Some(a);
            }
        }
        None
    };
    for _ in 0..ops {
        // keep about 3000 blocks alive, so that overlaps have something to hit
        let action = if live.is_empty() { 0 } else if live_bytes > 256 << 20 { 9 } else if live.len() < 3000 { r.below(7) } else { 3 + r.below(7) };
        match action {
            0..=2 => {
                let size = pick_size(&mut r, small_only);
                let align = 1usize << r.below(max_align_shift + 1);
                let layout = Layout::from_size_align(size, align).unwrap();
                let p = if r.below(8) == 0 { unsafe { h.alloc_zeroed(layout) } } else { unsafe { h.alloc(layout) } };
                allocs += 1;
                if p.is_null() {
                    report("alloc returned null", format!("{:?}", layout));
                    continue;
                }
                if p as usize % align != 0 {
                    report("misaligned", format!("{:p} for {:?}", p, layout));
                }
                if let Some(o) = overlaps(&live, p as usize, size) {
                    report("overlap", format!("{:p}+{} with live block at {:#x}", p, size, o));
                    continue;
                }
                let seed = r.next() as u8;
                fill(p, size, seed);
                live_bytes += size;
                live.insert(p as usize, Block { layout, seed });
            }
            3..=5 => {
                // realloc a random live block
                let k = r.below(live.len() as u64) as usize;
                let (&p, _) = live.iter().nth(k).unwrap();
                let b = live.remove(&p).unwrap();
                let new = pick_size(&mut r, small_only);
                let q = unsafe { h.realloc(p as *mut u8, b.layout, new) };
                reallocs += 1;
                inplace += (q as usize == p) as u64;
                let kept = b.layout.size().min(new);
                if q as usize % b.layout.align() != 0 {
                    report("realloc misaligned", format!("{:p} align {}", q, b.layout.align()));
                }
                if !verify(q, kept, b.seed) {
                    report("realloc lost contents", format!("{} -> {} bytes, align {}", b.layout.size(), new, b.layout.align()));
                }
                if let Some(o) = overlaps(&live, q as usize, new) {
                    report("realloc overlap", format!("{:p}+{} with live block at {:#x}", q, new, o));
                    continue;
                }
                let seed = r.next() as u8;
                fill(q, new, seed);
                live_bytes = live_bytes - b.layout.size() + new;
                live.insert(q as usize, Block { layout: Layout::from_size_align(new, b.layout.align()).unwrap(), seed });
            }
            _ => {
                let k = r.below(live.len() as u64) as usize;
                let (&p, _) = live.iter().nth(k).unwrap();
                let b = live.remove(&p).unwrap();
                if !verify(p as *const u8, b.layout.size(), b.seed) {
                    report("contents changed while live", format!("{:#x} {:?}", p, b.layout));
                }
                unsafe { h.dealloc(p as *mut u8, b.layout) };
                live_bytes -= b.layout.size();
                frees += 1;
            }
        }
    }
    for (&p, b) in &live {
        if !verify(p as *const u8, b.layout.size(), b.seed) {
            errors += 1;
            println!("ERROR contents changed while live at end: {:#x} {:?}", p, b.layout);
        }
    }
    println!(
        "ops={} max_align=2^{} allocs={} reallocs={} (in place {}) frees={} live_at_end={} errors={}",
        ops, max_align_shift, allocs, reallocs, inplace, frees, live.len(), errors
    );
    std::process::exit((errors != 0) as i32);
}
