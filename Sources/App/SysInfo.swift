import Foundation

// csops (SPI, in libSystem) resolved dynamically to read code-signing status flags.
private typealias CsopsFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

enum SysInfo {
    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    static var physFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static var availableMemory: Int {
        typealias Fn = @convention(c) () -> Int
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "os_proc_available_memory") else { return -1 }
        let v = unsafeBitCast(sym, to: Fn.self)()
        return v > 0 ? v : -1
    }

    static var effectiveLimit: UInt64 {
        let a = availableMemory, f = physFootprint
        return (a < 0 || f == 0) ? 0 : f + UInt64(a)
    }

    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let r = sysctl(&mib, 4, &info, &size, nil, 0)
        return r == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static var csFlags: UInt32 {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "csops") else { return 0 }
        let fn = unsafeBitCast(sym, to: CsopsFn.self)
        var flags: UInt32 = 0
        _ = withUnsafeMutablePointer(to: &flags) { fn(getpid(), 0 /*CS_OPS_STATUS*/, $0, MemoryLayout<UInt32>.size) }
        return flags
    }
    static var csDebugged: Bool { csFlags & 0x10000000 != 0 }        // CS_DEBUGGED
    static var csGetTaskAllow: Bool { csFlags & 0x00000004 != 0 }    // CS_GET_TASK_ALLOW

    static func maxVirtualReservation() -> UInt64 {
        let gb: UInt64 = 1 << 30
        var best: UInt64 = 0
        for gbs in [UInt64(2), 4, 8, 16, 32, 64, 128, 256] {
            let size = gbs * gb
            let p = mmap(nil, Int(size), PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
            if p != MAP_FAILED {
                munmap(p, Int(size))
                best = size
            } else { break }
        }
        return best
    }
}
