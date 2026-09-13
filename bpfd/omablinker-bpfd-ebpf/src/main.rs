#![no_std]
#![no_main]

use aya_ebpf::{macros::map, macros::tracepoint, maps::PerCpuArray, programs::TracePointContext};

/// Per-CPU hit counter, one slot. Per-CPU (rather than a single shared
/// counter) means no atomics and no cross-CPU cache-line bouncing under
/// concurrent I/O from multiple cores — userspace sums the slots itself,
/// which is cheap and only happens a few dozen times a second.
#[map]
static ACTIVITY: PerCpuArray<u64> = PerCpuArray::<u64>::with_max_entries(1, 0);

#[inline(always)]
fn bump() {
    if let Some(counter) = ACTIVITY.get_ptr_mut(0) {
        // SAFETY: `counter` points at this CPU's slot in a 1-entry
        // PerCpuArray; eBPF programs run non-preemptibly with respect to
        // other programs on the same CPU, so this can't race.
        unsafe { *counter += 1 };
    }
}

/// Fires when the kernel hands a request to a block device.
#[tracepoint]
pub fn block_rq_issue(_ctx: TracePointContext) -> u32 {
    bump();
    0
}

/// Fires when a block device finishes a request. Counting both issue and
/// complete means a single slow request still reads as continuous activity
/// rather than two isolated blips.
#[tracepoint]
pub fn block_rq_complete(_ctx: TracePointContext) -> u32 {
    bump();
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
