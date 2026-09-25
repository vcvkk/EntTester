import SwiftUI

@MainActor
final class MemModel: ObservableObject {
    @Published var text = ""
    @Published var stressing = false
    private var blocks: [UnsafeMutableRawPointer] = []
    private let blockSize = 64 * 1024 * 1024

    private func mb(_ b: UInt64) -> String { "\(b / 1_048_576) MB" }

    func refresh() {
        let ent = SignatureReader.entitlements
        func has(_ k: String) -> Bool { ent[k] != nil }
        let phys = SysInfo.physicalMemory
        let foot = SysInfo.physFootprint
        let avail = SysInfo.availableMemory
        let lim = SysInfo.effectiveLimit
        var s = ""
        s += "physical RAM:        \(mb(phys))\n"
        s += "phys_footprint:      \(mb(foot))\n"
        s += "os_proc_available:   \(avail < 0 ? "n/a" : mb(UInt64(avail)))\n"
        s += "effective app limit: \(lim == 0 ? "n/a" : mb(lim))"
        if lim > 0 { s += String(format: "  (%.0f%% of RAM)", 100.0 * Double(lim) / Double(phys)) }
        s += "\n"
        s += "held by stress test: \(mb(UInt64(blocks.count * blockSize)))\n\n"
        s += "entitlements:\n"
        s += "  increased-memory-limit:           \(has("com.apple.developer.kernel.increased-memory-limit") ? "✓" : "✗")\n"
        s += "  increased-debugging-memory-limit: \(has("com.apple.developer.kernel.increased-debugging-memory-limit") ? "✓" : "✗")\n"
        s += "  extended-virtual-addressing:      \(has("com.apple.developer.kernel.extended-virtual-addressing") ? "✓" : "✗")\n\n"
        s += "code-signing / debug state:\n"
        s += "  P_TRACED (debugger attached): \(SysInfo.debuggerAttached ? "YES" : "no")\n"
        s += "  CS_DEBUGGED (JIT/debug):      \(SysInfo.csDebugged ? "YES" : "no")\n"
        s += "  CS_GET_TASK_ALLOW:            \(SysInfo.csGetTaskAllow ? "YES" : "no")\n"
        text = s
    }

    func measureVA() {
        text += "\nmeasuring max virtual reservation…\n"
        let va = SysInfo.maxVirtualReservation()
        text += "max VA reservation (PROT_NONE): \(mb(va))\n"
        text += va > (UInt64(8) << 30) ? "→ >8 GiB: extended addressing ACTIVE\n" : "→ near default: extended addressing not evident\n"
    }

    func stress() {
        guard !stressing else { return }
        stressing = true
        Task {
            while stressing {
                let a = SysInfo.availableMemory
                if a >= 0 && a < 96 * 1024 * 1024 { text += "⚠️ stopping ~\(a/1_048_576) MB from OOM\n"; break }
                guard let p = malloc(blockSize) else { text += "malloc failed\n"; break }
                memset(p, 0xA5, blockSize)
                blocks.append(p)
                refresh()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            stressing = false
            refresh()
        }
    }

    func freeAll() {
        stressing = false
        for b in blocks { free(b) }
        blocks.removeAll()
        refresh()
    }
}

struct MemoryView: View {
    @StateObject private var m = MemModel()
    var body: some View {
        ScrollView {
            Text(m.text.isEmpty ? "—" : m.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Refresh") { m.refresh() }
                Button("Max VA") { m.measureVA() }
                if m.stressing { Button("Stop", role: .destructive) { m.freeAll() } }
                else { Button("Stress") { m.stress() } }
                Button("Free") { m.freeAll() }
            }
            .buttonStyle(.bordered).padding(8).background(.ultraThinMaterial)
        }
        .navigationTitle("Kernel / memory")
        .onAppear { m.refresh() }
    }
}
