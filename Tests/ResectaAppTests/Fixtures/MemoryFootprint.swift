import Foundation
import os

// CAT-227 — physical-memory footprint seam (C-E deep plan §5).
//
// No footprint seam exists at the pin. `ApplyPhaseMemoryStressTests` needs to
// observe the test process's resident physical-memory footprint at the
// streaming-append hook and around the full apply phase, to prove the
// collect-then-drain jetsam cliff (CAT-125) is gone. This reads
// `task_vm_info.phys_footprint` — the same number iOS uses for jetsam
// accounting — via `task_info(TASK_VM_INFO)`.
//
// Privacy: this measures only the process's own memory accounting. It reads
// no document content, file paths, or redaction coordinates (ARCH §12.2).
enum MemoryFootprint {

    /// The process's current physical-memory footprint in bytes, or `-1` on
    /// failure. Callers treat `-1` as "unmeasurable on this host" and
    /// skip-record rather than fail — a footprint read failure is not a
    /// redaction defect (deep plan §5: "-1 on failure (skip-record, don't
    /// fail)").
    ///
    /// `phys_footprint` is populated from `TASK_VM_INFO` revision 1 onward and
    /// is always present on the iOS 26 simulator/device the suite targets; the
    /// `KERN_SUCCESS` guard is the load-bearing failure check.
    static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }

    /// Darwin's per-process available-memory estimate. Logged, never asserted:
    /// this is the D-1 probe data the deep plan (§7 Q2) wants captured against
    /// `phys_footprint` to judge whether post-CAT-125 readings track real
    /// pressure. On the simulator this returns host memory, not a jetsam
    /// ceiling ("sim over-reports available memory").
    static func osProcAvailableMemory() -> Int64 {
        Int64(os_proc_available_memory())
    }
}
