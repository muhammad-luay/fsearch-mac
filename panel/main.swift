import AppKit
import Carbon

// FSearch Panel — a Spotlight-style window over the fsearch daemon.
// Option+Space toggles it. Results come live from the fsearch unix socket
// (JSON lines), same protocol the CLI uses.

// MARK: - Daemon client

final class DaemonClient {
    static let socketPath = NSString(string: "~/Library/Application Support/FSearch/fsearch.sock").expandingTildeInPath

    struct Hit {
        let path: String
        let kind: String
    }

    struct Reply {
        let hits: [Hit]
        let ms: Double
    }

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "fsearch.panel.daemon")

    private func connect() -> Bool {
        if fd >= 0 { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard DaemonClient.socketPath.utf8.count < cap else { close(s); return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { strcpy($0, DaemonClient.socketPath) }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(s); return false }
        fd = s
        return true
    }

    private func drop() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    func search(_ q: String, gen: Int, done: @escaping (Int, Reply?) -> Void) {
        queue.async {
            guard self.connect() else {
                DispatchQueue.main.async { done(gen, nil) }
                return
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["q": q, "limit": 40]) else { return }
            var req = body
            req.append(0x0A)
            let wrote: Bool = req.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(self.fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            if !wrote {
                self.drop()
                DispatchQueue.main.async { done(gen, nil) }
                return
            }
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            var line: Data?
            while line == nil {
                let n = chunk.withUnsafeMutableBytes { read(self.fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0 ..< n])
                if let i = buf.firstIndex(of: 0x0A) { line = buf.prefix(i) }
            }
            guard let lineData = line,
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let rawHits = obj["hits"] as? [[String: Any]]
            else {
                self.drop()
                DispatchQueue.main.async { done(gen, nil) }
                return
            }
            let hits = rawHits.compactMap { h -> Hit? in
                guard let p = h["path"] as? String else { return nil }
                return Hit(path: p, kind: h["kind"] as? String ?? "file")
            }
            let ms: Double
            if let t = obj["took_us"] as? Double { ms = t / 1000 }
            else if let t = obj["took_us"] as? Int { ms = Double(t) / 1000 }
            else { ms = 0 }
            DispatchQueue.main.async { done(gen, Reply(hits: hits, ms: ms)) }
        }
    }
}

// MARK: - UI pieces

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppDelegate.shared?.handleEditKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class RowView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let dir = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        dir.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dir.lineBreakMode = .byTruncatingHead
        dir.textColor = .secondaryLabelColor
        dir.font = .systemFont(ofSize: 12)
        name.font = .systemFont(ofSize: 15)
        dir.alignment = .right
        dir.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(icon)
        addSubview(name)
        addSubview(dir)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            dir.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            dir.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dir.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ hit: DaemonClient.Hit) {
        let url = URL(fileURLWithPath: hit.path)
        let isDir = hit.kind == "dir"
        icon.image = NSImage(systemSymbolName: isDir ? "folder" : "doc", accessibilityDescription: nil)
        icon.contentTintColor = isDir ? .systemBlue : .tertiaryLabelColor
        name.stringValue = url.lastPathComponent
        dir.stringValue = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static var shared: AppDelegate!

    private var panel: Panel!
    private let searchField = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "⏎ open    ⌘⏎ reveal in Finder    esc close")
    private let stats = NSTextField(labelWithString: "")
    private var hits: [DaemonClient.Hit] = []
    private let daemon = DaemonClient()
    private var gen = 0
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
        installHotKey()
        installEditKeys()
    }

    // MARK: Panel

    private func buildPanel() {
        let w: CGFloat = 760
        let h: CGFloat = 489
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 22)
        searchField.placeholderString = "Search files…"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        stats.font = .systemFont(ofSize: 11)
        stats.textColor = .secondaryLabelColor
        stats.alignment = .right
        stats.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(searchField)
        effect.addSubview(divider)
        effect.addSubview(scroll)
        effect.addSubview(hint)
        effect.addSubview(stats)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 400),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),

            stats.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            stats.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            stats.leadingAnchor.constraint(greaterThanOrEqualTo: hint.trailingAnchor, constant: 12),
        ])
    }

    // MARK: Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "FSearch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Search  (⌥Space)", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FSearch Panel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func toggleFromMenu() { toggle() }

    // MARK: Hotkey (Option+Space)

    private func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppDelegate.shared.toggle() }
            return noErr
        }, 1, &eventType, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x46_53_48_50), id: 1) // 'FSHP'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("FSearchPanel: hotkey registration failed (\(status))") }
    }

    // MARK: Edit keys & copy
    //
    // The app has no main menu, so AppKit never dispatches ⌘V/⌘C/⌘X/⌘A.

    @discardableResult
    func handleEditKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "v":
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "a":
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "c":
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                return false
            }
            return copySelectedPath()
        default:
            return false
        }
    }

    private func installEditKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.panel else { return event }
            return self.handleEditKey(event) ? nil : event
        }
    }

    @discardableResult
    private func copySelectedPath() -> Bool {
        let row = table.selectedRow
        guard hits.indices.contains(row) else { return false }
        let url = URL(fileURLWithPath: hits[row].path)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        pb.writeObjects([item])
        return true
    }

    // MARK: Show / hide

    @objc private func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private func show() {
        searchField.stringValue = ""
        hits = []
        table.reloadData()
        stats.stringValue = ""
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let x = screen.frame.midX - size.width / 2
            let y = max(screen.visibleFrame.maxY - size.height - 140, screen.visibleFrame.minY + 40)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue
        gen += 1
        let g = gen
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            hits = []
            table.reloadData()
            stats.stringValue = ""
            return
        }
        daemon.search(q, gen: g) { [weak self] g, reply in
            guard let self = self, g == self.gen else { return }
            self.hits = reply?.hits ?? []
            self.table.reloadData()
            if !self.hits.isEmpty {
                self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            if let reply = reply {
                self.stats.stringValue = String(format: "%d results · %.1f ms", reply.hits.count, reply.ms)
            } else {
                self.stats.stringValue = "daemon not running"
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                revealSelected()
            } else {
                openSelected()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), hits.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard hits.indices.contains(row) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: hits[row].path))
        hide()
    }

    private func revealSelected() {
        let row = table.selectedRow
        guard hits.indices.contains(row) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hits[row].path)])
        hide()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        var view = tableView.makeView(withIdentifier: id, owner: nil) as? RowView
        if view == nil {
            view = RowView()
            view!.identifier = id
        }
        view!.configure(hits[row])
        return view
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard hits.indices.contains(row) else { return nil }
        let path = hits[row].path
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        item.setString(path, forType: .string)
        return item
    }
}

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
