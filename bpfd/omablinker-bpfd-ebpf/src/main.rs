#![no_std]
#![no_main]

use aya_ebpf::{macros::map, macros::tracepoint, maps::PerCpuArray, programs::TracePointContext};

/// Per-CPU counters: `[READ_INDEX]` counts read requests, `[WRITE_INDEX]`
/// counts everything else (writes, flushes, discards, zone management —
/// anything that isn't a plain read). "Combined" activity for the
/// single-LED mode is just read + write summed in userspace; there's no
/// need for a third counter here.
#[map]
static ACTIVITY: PerCpuArray<u64> = PerCpuArray::<u64>::with_max_entries(2, 0);

const READ_INDEX: u32 = 0;
const WRITE_INDEX: u32 = 1;

#[inline(always)]
fn bump(index: u32) {
    if let Some(counter) = ACTIVITY.get_ptr_mut(index) {
        // SAFETY: `counter` points at this CPU's slot for `index` (0 or 1)
        // in a 2-entry PerCpuArray; eBPF programs run non-preemptibly with
        // respect to other programs on the same CPU, so this can't race.
        unsafe { *counter += 1 };
    }
}

/// Mirrors the start of `include/trace/events/block.h`'s `TP_STRUCT__entry`
/// for the `block_rq` tracepoint class (used by `block_rq_issue`) and the
/// `block_rq_completion` class (used by `block_rq_complete`), as of:
/// https://github.com/torvalds/linux/blob/master/include/trace/events/block.h
///
///   block_rq:            dev_t dev; sector_t sector; unsigned int nr_sector;
///                         unsigned int bytes; unsigned short ioprio; char rwbs[10]; ...
///   block_rq_completion:  dev_t dev; sector_t sector; unsigned int nr_sector;
///                         int error;          unsigned short ioprio; char rwbs[10]; ...
///
/// The two classes differ in the field right before `rwbs` (`bytes` vs
/// `error`), but both are 4-byte fields, so both lay out identically up to
/// and including `rwbs` — one offset covers both tracepoints. Field sizes
/// (`dev_t` = u32, `sector_t` = u64, `RWBS_LEN` = 10) are taken from
/// `include/linux/types.h` / `include/trace/events/block.h`, not assumed.
/// `offset_of!` — not hand arithmetic — computes the real offset (34,
/// verified separately), including the kernel's fixed 8-byte common
/// `trace_entry` header (`type`, `flags`, `preempt_count`, `pid`) that
/// precedes every tracepoint's own fields.
///
/// If this ever misclassifies on a real machine, compare against the
/// actual layout: `cat /sys/kernel/tracing/events/block/block_rq_issue/format`
/// (needs root) and adjust the struct below to match.
#[repr(C)]
struct BlockRqEntryPrefix {
    _common: [u8; 8],
    _dev: u32,
    _sector_pad: u32, // sector_t needs 8-byte alignment; this is that padding
    _sector: u64,
    _nr_sector: u32,
    _bytes_or_error: u32,
    _ioprio: u16,
    rwbs: [u8; 2], // only need the first couple of bytes to classify
}

const RWBS_OFFSET: usize = core::mem::offset_of!(BlockRqEntryPrefix, rwbs);

/// Classifies a block request as a read or a write from its `rwbs` field —
/// the same field `biosnoop`/`biotop` read from these tracepoints to show
/// their R/W column (`blk_fill_rwbs()` in `kernel/trace/blktrace.c`: 'R'
/// for a plain read, 'W' for a write, optionally prefixed with 'F' for a
/// combined flush; other operations — discard, secure-erase, zone
/// management — get their own letters with no 'R' or 'W' at all).
/// Checking both of the first two bytes catches a flush+write ("FW")
/// without needing to parse the whole string. Anything that isn't clearly
/// a read — including a failed read of the field — is bucketed as a
/// write, since those operations modify the device rather than retrieve
/// data from it.
#[inline(always)]
fn classify(ctx: &TracePointContext) -> u32 {
    // SAFETY: RWBS_OFFSET is a fixed, verified constant well within the
    // tracepoint's argument buffer; read_at() itself uses
    // bpf_probe_read_kernel(), which safely handles an invalid read by
    // returning an error rather than faulting.
    match unsafe { ctx.read_at::<[u8; 2]>(RWBS_OFFSET) } {
        Ok(rwbs) if rwbs[0] == b'R' || rwbs[1] == b'R' => READ_INDEX,
        _ => WRITE_INDEX,
    }
}

/// Fires when the kernel hands a request to a block device.
#[tracepoint]
pub fn block_rq_issue(ctx: TracePointContext) -> u32 {
    bump(classify(&ctx));
    0
}

/// Fires when a block device finishes a request. Counting both issue and
/// complete means a single slow request still reads as continuous activity
/// rather than two isolated blips.
#[tracepoint]
pub fn block_rq_complete(ctx: TracePointContext) -> u32 {
    bump(classify(&ctx));
    0
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
