use std::ffi::c_void;
use std::ptr;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut c_void, goal: usize) -> usize;
}

/// Ask the platform allocator to return unused native pages to the OS.
///
/// macOS keeps freed pages in malloc zones for fast reuse. Those pages are no
/// longer live game objects, but they remain charged to `phys_footprint` until
/// pressure relief runs.
#[flutter_rust_bridge::frb(sync)]
pub fn release_unused_native_memory() -> u64 {
    #[cfg(target_os = "macos")]
    {
        // A null zone applies pressure relief to all registered malloc zones.
        return unsafe { malloc_zone_pressure_relief(ptr::null_mut(), 0) } as u64;
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = ptr::null_mut::<c_void>();
        0
    }
}
