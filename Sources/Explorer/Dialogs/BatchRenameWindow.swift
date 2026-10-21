import AppKit
import SwiftUI
import ExplorerKit

/// Batch Rename dialog: chain of steps with live preview.
final class BatchRenameModel: ObservableObject {
    struct Step: Identifiable { let id = UUID(); var value: RenameStep }
    @Published var steps: [Step] = [Step(value: .replaceText(find: "", replace: "", caseSensitive: false, target: .name))]
    @Published private(set) var results: [RenameResult] = []
    let inputs: [RenameInput]

    init(urls: [URL]) {
        let keys = MetadataValues.renameKeys.map(\.key)
        inputs = urls.map { RenameInput.load($0, metadataKeys: keys) }
        recompute()
    }

    func recompute() { results = BatchRenamer.preview(inputs, steps: steps.map(\.value)) }
}

enum StepKind: String, CaseIterable, Identifiable {
    case replaceText = "Replace text", replaceRegex = "Replace RegEx", changeCase = "Change case", addText = "Add text"
    case addDate = "Add date", addNumber = "Add number sequence", addMetadata = "Add metadata value"
    var id: String { rawValue }
    func make() -> RenameStep {
        switch self {
        case .replaceText: return .replaceText(find: "", replace: "", caseSensitive: false, target: .name)
        case .replaceRegex: return .replaceRegex(pattern: "", template: "", caseSensitive: false, target: .name)
        case .changeCase: return .changeCase(.title, target: .name)
        case .addText: return .addText("", position: .end, offset: 0, fromEnd: false, target: .name)
        case .addDate: return .addDate(source: .created, format: "yyyy-MM-dd", position: .beginning, offset: 0, fromEnd: false, delimiter: " ", target: .name)
        case .addNumber: return .addNumber(start: 1, step: 1, padding: 3, order: .current, descending: false, position: .end, offset: 0, fromEnd: false, delimiter: " ", target: .name)
        case .addMetadata: return .addMetadata(key: MetadataValues.renameKeys[0].key, position: .end, offset: 0, fromEnd: false, delimiter: " ", target: .name)
        }
    }
    static func of(_ s: RenameStep) -> StepKind {
        switch s {
        case .replaceText: return .replaceText; case .replaceRegex: return .replaceRegex; case .changeCase: return .changeCase
        case .addText: return .addText; case .addDate: return .addDate; case .addNumber: return .addNumber; case .addMetadata: return .addMetadata
        }
    }
}

struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel
    var onRename: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch Rename").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.steps) { $step in
                        StepEditor(step: $step.value, canRemove: model.steps.count > 1) {
                            model.steps.removeAll { $0.id == step.id }; model.recompute()
                        }
                        .onChange(of: StepKind.of(step.value)) { _ in model.recompute() }
                    }
                    HStack {
                        Spacer()
                        Button { model.steps.append(.init(value: StepKind.replaceText.make())); model.recompute() } label: { Label("Add", systemImage: "plus") }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
            Divider()
            Table(model.results) {
                TableColumn("Current file name") { r in Text(r.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                TableColumn("Resulting file name") { r in
                    HStack {
                        Text(r.newName).lineLimit(1).truncationMode(.middle).foregroundColor(r.error != nil ? .red : (r.changed ? .primary : .secondary))
                        if let e = r.error { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(e) }
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                Text(String(format: "%lld items", Int64(model.results.count))).foregroundColor(.secondary).font(.caption)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename", action: onRename).keyboardShortcut(.defaultAction)
                    .disabled(!model.results.contains { $0.changed && FileNaming.validate($0.newName) == nil })
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 560)
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main)) { _ in }
    }
}

/// Editor for one step. Rebuilds the enum on every change and triggers recompute through the binding owner.
struct StepEditor: View {
    @Binding var step: RenameStep
    var canRemove: Bool
    var remove: () -> Void
    @EnvironmentObject var model: BatchRenameModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: Binding(get: { StepKind.of(step) }, set: { step = $0.make() })) {
                        ForEach(StepKind.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 200)
                    Picker("Apply to", selection: targetBinding) {
                        ForEach(RenameTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 260)
                    Spacer()
                    if canRemove { Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                }
                fields
            }
            .onChange(of: step) { _ in model.recompute() }
        }
    }

    var targetBinding: Binding<RenameTarget> {
        Binding(get: { step.target }, set: { t in
            switch step {
            case let .replaceText(a, b, c, _): step = .replaceText(find: a, replace: b, caseSensitive: c, target: t)
            case let .replaceRegex(a, b, c, _): step = .replaceRegex(pattern: a, template: b, caseSensitive: c, target: t)
            case let .changeCase(c, _): step = .changeCase(c, target: t)
            case let .addText(a, b, c, d, _): step = .addText(a, position: b, offset: c, fromEnd: d, target: t)
            case let .addDate(a, b, c, d, e, f, _): step = .addDate(source: a, format: b, position: c, offset: d, fromEnd: e, delimiter: f, target: t)
            case let .addNumber(a, b, c, d, e, f, g, h, i, _): step = .addNumber(start: a, step: b, padding: c, order: d, descending: e, position: f, offset: g, fromEnd: h, delimiter: i, target: t)
            case let .addMetadata(a, b, c, d, e, _): step = .addMetadata(key: a, position: b, offset: c, fromEnd: d, delimiter: e, target: t)
            }
        })
    }

    @ViewBuilder var fields: some View {
        switch step {
        case let .replaceText(find, rep, cs, t):
            HStack {
                TextField("Find text", text: Binding(get: { find }, set: { step = .replaceText(find: $0, replace: rep, caseSensitive: cs, target: t) }))
                TextField("Replace with", text: Binding(get: { rep }, set: { step = .replaceText(find: find, replace: $0, caseSensitive: cs, target: t) }))
                Toggle("Case sensitive", isOn: Binding(get: { cs }, set: { step = .replaceText(find: find, replace: rep, caseSensitive: $0, target: t) }))
            }
        case let .replaceRegex(p, tpl, cs, t):
            HStack {
                TextField("Find regEx", text: Binding(get: { p }, set: { step = .replaceRegex(pattern: $0, template: tpl, caseSensitive: cs, target: t) }))
                TextField("Replace with ($1, $2…)", text: Binding(get: { tpl }, set: { step = .replaceRegex(pattern: p, template: $0, caseSensitive: cs, target: t) }))
                Toggle("Case sensitive", isOn: Binding(get: { cs }, set: { step = .replaceRegex(pattern: p, template: tpl, caseSensitive: $0, target: t) }))
            }
            if !p.isEmpty, (try? NSRegularExpression(pattern: p)) == nil { Text("Invalid regular expression").font(.caption).foregroundColor(.red) }
        case let .changeCase(c, t):
            Picker("Case", selection: Binding(get: { c }, set: { step = .changeCase($0, target: t) })) {
                ForEach(CaseStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        case let .addText(txt, pos, off, fe, t):
            HStack {
                TextField("Text to add", text: Binding(get: { txt }, set: { step = .addText($0, position: pos, offset: off, fromEnd: fe, target: t) }))
                positionPicker(pos, off, fe) { p, o, f in step = .addText(txt, position: p, offset: o, fromEnd: f, target: t) }
            }
        case let .addDate(src, fmt, pos, off, fe, delim, t):
            HStack {
                Picker("Date to add", selection: Binding(get: { src }, set: { step = .addDate(source: $0, format: fmt, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) })) {
                    ForEach(DateSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 220)
                TextField("Date format", text: Binding(get: { fmt }, set: { step = .addDate(source: src, format: $0, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) })).frame(width: 140)
                TextField("Delimiter", text: Binding(get: { delim }, set: { step = .addDate(source: src, format: fmt, position: pos, offset: off, fromEnd: fe, delimiter: $0, target: t) })).frame(width: 60)
            }
            positionPicker(pos, off, fe) { p, o, f in step = .addDate(source: src, format: fmt, position: p, offset: o, fromEnd: f, delimiter: delim, target: t) }
        case let .addNumber(start, by, pad, order, desc, pos, off, fe, delim, t):
            HStack {
                Stepper("Start at \(start)", value: Binding(get: { start }, set: { step = .addNumber(start: $0, step: by, padding: pad, order: order, descending: desc, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) }))
                Stepper("Step \(by)", value: Binding(get: { by }, set: { step = .addNumber(start: start, step: $0, padding: pad, order: order, descending: desc, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) }))
                Stepper("Padding \(pad)", value: Binding(get: { pad }, set: { step = .addNumber(start: start, step: by, padding: max(0, $0), order: order, descending: desc, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) }), in: 0...10)
                TextField("Delimiter", text: Binding(get: { delim }, set: { step = .addNumber(start: start, step: by, padding: pad, order: order, descending: desc, position: pos, offset: off, fromEnd: fe, delimiter: $0, target: t) })).frame(width: 60)
            }
            HStack {
                Picker("Sorted by", selection: Binding(get: { order }, set: { step = .addNumber(start: start, step: by, padding: pad, order: $0, descending: desc, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) })) {
                    ForEach(NumberOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 240)
                Toggle("Descending", isOn: Binding(get: { desc }, set: { step = .addNumber(start: start, step: by, padding: pad, order: order, descending: $0, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) }))
                positionPicker(pos, off, fe) { p, o, f in step = .addNumber(start: start, step: by, padding: pad, order: order, descending: desc, position: p, offset: o, fromEnd: f, delimiter: delim, target: t) }
            }
        case let .addMetadata(key, pos, off, fe, delim, t):
            HStack {
                Picker("Data to add", selection: Binding(get: { key }, set: { step = .addMetadata(key: $0, position: pos, offset: off, fromEnd: fe, delimiter: delim, target: t) })) {
                    ForEach(MetadataValues.renameKeys, id: \.key) { Text($0.title).tag($0.key) }
                }.frame(width: 260)
                TextField("Delimiter", text: Binding(get: { delim }, set: { step = .addMetadata(key: key, position: pos, offset: off, fromEnd: fe, delimiter: $0, target: t) })).frame(width: 60)
                positionPicker(pos, off, fe) { p, o, f in step = .addMetadata(key: key, position: p, offset: o, fromEnd: f, delimiter: delim, target: t) }
            }
        }
    }

    func positionPicker(_ pos: InsertPosition, _ off: Int, _ fe: Bool, set: @escaping (InsertPosition, Int, Bool) -> Void) -> some View {
        HStack {
            Picker("Position", selection: Binding(get: { pos }, set: { set($0, off, fe) })) {
                ForEach(InsertPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 220)
            if pos == .custom {
                Stepper("Offset \(off)", value: Binding(get: { off }, set: { set(pos, max(0, $0), fe) }))
                Picker("", selection: Binding(get: { fe }, set: { set(pos, off, $0) })) {
                    Text("From the beginning").tag(false); Text("From the end").tag(true)
                }.labelsHidden().frame(width: 160)
            }
        }
    }
}

enum BatchRenameWindow {
    static func show(urls: [URL], host: BrowserWindowController) {
        let model = BatchRenameModel(urls: urls)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let close: () -> Void = { [weak host] in host?.window?.endSheet(panel) }
        let view = BatchRenameView(model: model, onRename: { [weak host] in
            do {
                let undo = try BatchRenamer.commit(model.results)
                FileOps.shared.history.record("Batch Rename", undo)
                if case .moved(let pairs) = undo { host?.state.pendingSelection = pairs.map(\.to) }
                host?.state.softReload()
                Sounds.play(.done)
            } catch {
                Alerts.error("Error while renaming", error.localizedDescription, window: host?.window)
            }
            close()
        }, onCancel: close).environmentObject(model)
        panel.contentViewController = NSHostingController(rootView: view)
        host.window?.beginSheet(panel)
    }
}
