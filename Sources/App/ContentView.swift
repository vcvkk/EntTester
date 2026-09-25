import SwiftUI

@main
struct EntTesterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class Engine: ObservableObject {
    @Published var results: [String: ProbeResult] = [:]
    @Published var running: Set<String> = []
    @Published var runningAll = false
    let values = EntitlementValues(dict: SignatureReader.entitlements)
    let items = Catalog.all()

    var presentCount: Int { items.filter { values.has($0.key) }.count }

    func run(_ e: Entitlement) async {
        running.insert(e.key)
        let r = await e.probe(values)
        results[e.key] = r
        running.remove(e.key)
    }
    func runAll() async {
        runningAll = true
        for e in items where !e.interactive { await run(e) }
        for e in items where e.interactive { results[e.key] = ProbeResult(.present, "interactive — tap the row to run") }
        runningAll = false
    }
}

private let memoryKeys: Set<String> = [
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.increased-debugging-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing"
]

struct ContentView: View {
    @StateObject private var engine = Engine()

    private var grouped: [(Category, [Entitlement])] {
        Category.allCases.compactMap { cat in
            let items = engine.items.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(engine.presentCount) / \(engine.items.count) in signature").font(.headline)
                            Text("Tap a row to probe it. Interactive rows (⭐) open a system sheet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await engine.runAll() } } label: {
                            if engine.runningAll { ProgressView() } else { Text("Run all").bold() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.runningAll)
                    }
                }
                ForEach(grouped, id: \.0) { cat, items in
                    Section(cat.rawValue) {
                        ForEach(items) { e in row(e) }
                    }
                }
            }
            .navigationTitle("Entitlement Tester")
        }
    }

    @ViewBuilder private func row(_ e: Entitlement) -> some View {
        if e.key == "aps-environment" {
            NavigationLink { PushView() } label: { RowLabel(e: e, present: engine.values.has(e.key), result: engine.results[e.key], busy: false) }
        } else if memoryKeys.contains(e.key) {
            NavigationLink { MemoryView() } label: { RowLabel(e: e, present: engine.values.has(e.key), result: engine.results[e.key], busy: false) }
        } else {
            Button { Task { await engine.run(e) } } label: {
                RowLabel(e: e, present: engine.values.has(e.key), result: engine.results[e.key], busy: engine.running.contains(e.key))
            }.buttonStyle(.plain)
        }
    }
}

struct RowLabel: View {
    let e: Entitlement
    let present: Bool
    let result: ProbeResult?
    let busy: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if e.interactive { Text("⭐").font(.caption2) }
                    Text(e.title).font(.subheadline.bold())
                }
                Text(e.key).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let r = result, !r.detail.isEmpty {
                    Text(r.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy { ProgressView() }
        }
        .padding(.vertical, 2)
    }
    private var icon: String {
        if busy { return "⏳" }
        if let r = result { return r.status.rawValue }
        return present ? "•" : "✖️"
    }
}
