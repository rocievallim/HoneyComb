// Honeycomb combines the Open Tangerine native editors (GPL-3.0-only) with Honeycomb's UI and workflows.
// License and third-party notices are installed in Honeycomb.app/Contents/Resources/Licenses.
import SwiftUI
typealias HCState<Value> = SwiftUI.State<Value>
import Cocoa
import SwiftUI
import ApplicationServices
import Carbon
import UserNotifications
import PDFKit
import Quartz
import Darwin

let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("honeycomb", isDirectory: true)
let fm = FileManager.default
let jobs = DispatchQueue(label: "app.honeycomb.conversions", qos: .userInitiated, attributes: .concurrent)
let finderQueue = DispatchQueue(label: "app.honeycomb.finder", qos: .userInitiated)
let logLock = NSLock()
func log(_ message: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let url = home.appendingPathComponent("log.txt")
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    }
}
struct HCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func settings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
}

let shortcutModifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
struct Shortcut: Codable {
    var keyCode: Int? = 49
    var modifiers: UInt64 = CGEventFlags.maskAlternate.rawValue
    var label: String = "⌥ Space"
    func requiredHeld(_ flags: CGEventFlags, _ keys: Set<Int>) -> Bool {
        flags.rawValue & modifiers == modifiers && (keyCode == nil || keys.contains(keyCode!))
    }
    func matches(_ flags: CGEventFlags, _ keys: Set<Int>) -> Bool {
        modifiers != 0 && flags.intersection(shortcutModifierMask).rawValue == modifiers && requiredHeld(flags, keys)
    }
}
func modifierLabel(_ flags: NSEvent.ModifierFlags) -> String {
    (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
}
func quartzModifiers(_ flags: NSEvent.ModifierFlags) -> UInt64 {
    var result: CGEventFlags = []
    if flags.contains(.control) { result.insert(.maskControl) }; if flags.contains(.option) { result.insert(.maskAlternate) }
    if flags.contains(.shift) { result.insert(.maskShift) }; if flags.contains(.command) { result.insert(.maskCommand) }
    return result.rawValue
}

struct Config: Codable {
    var gestureMode: String = "shortcut"
    var shortcut = Shortcut()
    var holdMilliseconds: Double = 250
    var enabled: Bool = true
    var startAtLogin: Bool = true
    var darkGlass: Bool = false
    var glassTint = GlassTint()
    var tintStrength: Double = 0
    var separateArchives = false
    var uiTint: NSColor { glassTint.color }
    var hexOrder: [String: [String]] = [
        "images": ["jpg", "png", "webp", "pdf", "compress"],
        "audio": ["mp3", "m4a", "wav", "flac", "opus"],
        "video": ["mp4", "mov", "mp3", "gif", "compress"],
        "documents": ["pdf", "docx", "txt", "md", "html"],
        "pdf": ["png", "jpg", "txt", "compress", "zip"],
        "spreadsheets": ["pdf", "csv", "xlsx", "zip"],
        "slides": ["pdf", "zip"]
    ]
    var favorites: [String: [String]] = [:]
    var pinned: [String: String] = [:]
}
struct Record: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var paths: [String]
    var failed: Bool
}
final class Store: ObservableObject {
    static let shared = Store()
    @Published var config = Config()
    @Published var recent: [Record] = []
    @Published var ax = false
    @Published var input = false
    @Published var automation = false
    @Published var tapOK = false
    @Published var recordingShortcut = false
    @Published var gestureStatus = "Waiting for Accessibility access"
    private var stamp: Date?
    private var usage: [String: [String: Int]] = [:]
    private var timer: Timer?
    let configURL = home.appendingPathComponent("config.json")
    init() {
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) { save() }
        reload()
        if let data = try? Data(contentsOf: home.appendingPathComponent("usage.json")), let v = try? JSONDecoder().decode([String: [String: Int]].self, from: data) { usage = v }
        if let data = try? Data(contentsOf: home.appendingPathComponent("history.json")), let v = try? JSONDecoder().decode([Record].self, from: data) { recent = v }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.reload(); self?.permissions()
        }
    }
    func save() {
        config.holdMilliseconds = min(600, max(150, config.holdMilliseconds))
        config.tintStrength = min(1, max(0, config.tintStrength))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(config).write(to: configURL, options: .atomic)
            stamp = (try? fm.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        } catch { log("Config save: \(error.localizedDescription)") }
    }
    func reload() {
        let date = (try? fm.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        guard date != stamp else { return }
        stamp = date
        do {
            let data = try Data(contentsOf: configURL)
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
            let edited = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let merged = defaults.merging(edited) { _, new in new }
            var value = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
            value.holdMilliseconds = min(600, max(150, value.holdMilliseconds))
            let oldLogin = config.startAtLogin
            if value.gestureMode != "clickHold" { value.gestureMode = "shortcut" }
            value.shortcut.modifiers &= shortcutModifierMask.rawValue
            if value.shortcut.modifiers == 0 { value.shortcut = Shortcut() }
            value.tintStrength = min(1, max(0, value.tintStrength))
            config = value
            if edited["shortcut"] == nil || edited["gestureMode"] == nil { save() }
            if oldLogin != value.startAtLogin { setLogin(value.startAtLogin) }
        } catch { log("Config unchanged; invalid JSON: \(error.localizedDescription)") }
    }
    func permissions() {
        ax = AXIsProcessTrusted(); input = CGPreflightListenEventAccess()
        if ax && !tapOK { Gesture.shared.install() }
        else if !ax && tapOK { Gesture.shared.uninstall(); tapOK = false }
    }
    func record(_ record: Record) {
        recent.insert(record, at: 0); recent = Array(recent.prefix(10))
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: home.appendingPathComponent("history.json"), options: .atomic) }
    }
    func used(_ ext: String, _ target: String) {
        usage[ext, default: [:]][target, default: 0] += 1
        if let data = try? JSONEncoder().encode(usage) { try? data.write(to: home.appendingPathComponent("usage.json"), options: .atomic) }
    }
    func ordered(_ ext: String, _ category: String, _ available: [String]) -> [String] {
        let wanted = (config.favorites[ext] ?? config.favorites[category] ?? []) + (config.hexOrder[ext] ?? config.hexOrder[category] ?? []) + available
        var result: [String] = []
        for item in wanted.map({ $0.lowercased() }) where available.contains(item) && !result.contains(item) { result.append(item) }
        let counts = usage[ext] ?? [:]
        let winner = config.pinned[ext] ?? result.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        if let pin = winner, available.contains(pin), config.pinned[ext] != nil || (counts[pin] ?? 0) > 0 {
            result.removeAll { $0 == pin }; result.insert(pin, at: 0)
        }
        return result
    }
}
func setLogin(_ enabled: Bool) {
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("app.honeycomb.personal.plist")
    if enabled {
        let plist: [String: Any] = ["Label": "app.honeycomb.personal", "ProgramArguments": ["/usr/bin/open", "-g", "/Applications/Honeycomb.app", "--args", "--background"], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { try? data.write(to: path, options: .atomic) }
    } else { try? fm.removeItem(at: path) }
}
final class Notices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notices()
    func setup() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let action = UNNotificationAction(identifier: "show", title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "result", actions: [action], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, error in if let e = error { log(e.localizedDescription) } }
    }
    func send(_ title: String, _ body: String, _ urls: [URL]) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = String(body.prefix(240)); content.categoryIdentifier = "result"
        content.userInfo = ["paths": urls.map(\.path)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { e in if let e = e { log(e.localizedDescription) } }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([.banner, .list]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        DispatchQueue.main.async { if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }; done() }
    }
}
let imageExt = ["heic", "heif", "jpg", "jpeg", "png", "webp", "gif", "tif", "tiff", "bmp", "avif", "svg", "ico"]
let audioExt = ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "aif"]
let videoExt = ["mp4", "mov", "mkv", "webm", "avi", "m4v"]
let docExt = ["docx", "doc", "odt", "rtf", "txt", "md", "html", "htm", "epub"]
func category(_ ext: String) -> String {
    if ext == "pdf" { return "pdf" }
    if imageExt.contains(ext) { return "images" }
    if audioExt.contains(ext) { return "audio" }
    if videoExt.contains(ext) { return "video" }
    if ["xlsx", "xls", "csv", "ods"].contains(ext) { return "spreadsheets" }
    if ["pptx", "ppt", "odp"].contains(ext) { return "slides" }
    if docExt.contains(ext) { return "documents" }
    return "files"
}
func coreTargets(_ ext: String) -> [String] {
    var items: [String]
    switch category(ext) {
    case "images": items = ["jpg", "png", "webp", "gif", "tiff", "bmp", "heic", "heif", "avif", "ico", "pdf", "compress"]
    case "audio": items = ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff"]
    case "video": items = ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav", "compress"]
    case "documents": items = ["docx", "doc", "odt", "rtf", "txt", "md", "html", "epub", "pdf"]
    case "spreadsheets": items = ["pdf"]; if ext == "xlsx" { items.append("csv") }; if ext == "csv" { items.append("xlsx") }
    case "slides": items = ["pdf"]
    case "pdf": items = ["png", "jpg", "txt", "compress"]
    default: return ["zip"]
    }
    items.removeAll { $0 == ext || (ext == "jpeg" && $0 == "jpg") || (ext == "tif" && $0 == "tiff") || (ext == "aif" && $0 == "aiff") }
    return items + ["trash", "clipboard", "zip"]
}
func targets(_ ext: String) -> [String] {
    var available = coreTargets(ext)
    for format in FileeBridge.shared.routes(ext)?.all ?? [] where format != ext && !available.contains(format) {
        available.append(format)
    }
    return available
}
struct Choice {
    var id: String
    var label: String? = nil
    var tool: ToolID? { id.hasPrefix("tool:") ? ToolID(rawValue: String(id.dropFirst(5))) : nil }
    var title: String {
        if let label = label { return label }
        if let tool = tool { return tool.radialLabel.capitalized + "…" }
        if id == "back" { return "Back" }
        switch id { case "compress": return "Compress"; case "trash": return "Trash…"; case "clipboard": return "Copy…"; case "zip": return "ZIP"; case "folder": return "Extract"; case "more": return "More"; default: return id.uppercased() }
    }
    var icon: String {
        if let tool = tool { return tool.symbol }
        if id == "back" { return "arrow.uturn.left" }
        switch id { case "compress": return "arrow.down.right.and.arrow.up.left"; case "trash": return "trash"; case "clipboard": return "doc.on.clipboard"; case "zip": return "archivebox"; case "folder": return "folder.badge.plus"; case "more": return "ellipsis.circle"; default:
            switch category(id) { case "images": return "photo"; case "audio": return "waveform"; case "video": return "film"; default: return "doc.text" }
        }
    }

}
func executable(_ name: String) throws -> URL {
    let names = name == "soffice" ? ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"] : ["/usr/bin/\(name)", "/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    guard let path = names.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw HCError("Missing tool: \(name). Rerun the installer.") }
    return URL(fileURLWithPath: path)
}
@discardableResult func run(_ name: String, _ args: [String], in dir: URL? = nil) throws -> String {
    let process = Process(); process.executableURL = try executable(name); process.arguments = args; process.currentDirectoryURL = dir
    var env = ProcessInfo.processInfo.environment; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; env["LC_ALL"] = "en_US.UTF-8"; process.environment = env
    let output = fm.temporaryDirectory.appendingPathComponent("hc-process-\(UUID().uuidString)")
    fm.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output); process.standardOutput = handle; process.standardError = handle
    defer { try? handle.close(); try? fm.removeItem(at: output) }
    try process.run(); process.waitUntilExit(); try? handle.synchronize()
    let data = (try? Data(contentsOf: output)) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        log("\(name) exited \(process.terminationStatus): \(text.suffix(5000))")
        let reason = text.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
        throw HCError("\(name): \(reason.prefix(170))")
    }
    return text
}
func workDirectory() throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("honeycomb-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true); return dir
}
// An exclusive move publishes complete output without overwriting a racing job or another app.
func publish(_ staged: URL, beside source: URL, stem: String, ext: String, folder: Bool = false) throws -> URL {
    let parent = source.deletingLastPathComponent()
    for n in 0..<10000 {
        let suffix = n == 0 ? "" : " (\(n))"
        let name = stem + suffix + (ext.isEmpty ? "" : ".\(ext)")
        let dest = parent.appendingPathComponent(name, isDirectory: folder)
        let result = staged.path.withCString { a in dest.path.withCString { b in renamex_np(a, b, UInt32(RENAME_EXCL)) } }
        if result == 0 { return dest }
        let e = errno
        if e == EEXIST { continue }
        if e == EXDEV {
            let sibling = parent.appendingPathComponent(".honeycomb-\(UUID().uuidString)", isDirectory: folder)
            try fm.copyItem(at: staged, to: sibling)
            defer { try? fm.removeItem(at: sibling) }
            return try publish(sibling, beside: source, stem: stem, ext: ext, folder: folder)
        }
        throw HCError("Cannot save beside \(source.lastPathComponent): \(String(cString: strerror(e)))")
    }
    throw HCError("Too many output names already exist.")
}
func office(_ input: URL, to ext: String, work: URL) throws -> URL {
    let profile = work.appendingPathComponent("lo-profile-\(UUID().uuidString)")
    let outdir = work.appendingPathComponent("lo-out-\(UUID().uuidString)")
    try fm.createDirectory(at: outdir, withIntermediateDirectories: true)
    let format: String
    switch ext {
    case "doc": format = "doc:MS Word 97"
    case "docx": format = "docx:Office Open XML Text"
    case "txt": format = "txt:Text (encoded):UTF8"
    case "csv": format = "csv:Text - txt - csv (StarCalc):44,34,76,1"
    case "xlsx": format = "xlsx:Calc MS Excel 2007 XML"
    default: format = ext
    }
    try run("soffice", ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--nologo", "--nodefault", "--nolockcheck", "--convert-to", format, "--outdir", outdir.path, input.path])
    let out = outdir.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
    guard fm.fileExists(atPath: out.path) else { throw HCError("LibreOffice could not export \(ext.uppercased()).") }
    return out
}
func imagePDF(_ input: URL, _ output: URL) throws {
    guard let image = NSImage(contentsOf: input), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw HCError("Cannot decode this image.") }
    var box = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else { throw HCError("Cannot create PDF.") }
    ctx.beginPDFPage(nil); ctx.draw(cg, in: box); ctx.endPDFPage(); ctx.closePDF()
}
func compressPDF(_ input: URL, _ output: URL) throws {
    guard let doc = CGPDFDocument(input as CFURL), doc.numberOfPages > 0, let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else { throw HCError("Cannot open PDF.") }
    let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
    guard let filter = QuartzFilter(url: filterURL), filter.apply(to: ctx) else { ctx.closePDF(); throw HCError("macOS PDF compression filter is unavailable.") }
    for index in 1...doc.numberOfPages {
        guard let page = doc.page(at: index) else { continue }
        let box = page.getBoxRect(.mediaBox), rotated = page.rotationAngle % 180 != 0
        var pageRect = CGRect(x: 0, y: 0, width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        let pageData = Data(bytes: &pageRect, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: pageData] as CFDictionary)
        ctx.saveGState(); ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: pageRect, rotate: 0, preserveAspectRatio: true)); ctx.drawPDFPage(page); ctx.restoreGState(); ctx.endPDFPage()
    }
    filter.remove(from: ctx); ctx.closePDF()
    let oldSize = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    if newSize >= oldSize { try fm.removeItem(at: output); try fm.copyItem(at: input, to: output) }
}
struct Probe: Decodable {
    struct Stream: Decodable { var codec_name: String?; var codec_type: String? }
    var streams: [Stream]
}
func media(_ input: URL, _ output: URL, _ target: String, compress: Bool = false) throws {
    let probeText = try run("ffprobe", ["-v", "quiet", "-show_streams", "-of", "json", input.path])
    let streams = (try? JSONDecoder().decode(Probe.self, from: Data(probeText.utf8)).streams) ?? []
    let v = streams.first { $0.codec_type == "video" }?.codec_name ?? ""
    let a = streams.first { $0.codec_type == "audio" }?.codec_name ?? ""
    let audioOnly = audioExt.contains(target)
    var options: [String] = []
    if audioOnly {
        let copyCodecs: [String: [String]] = ["mp3": ["mp3"], "aac": ["aac"], "m4a": ["aac", "alac"], "flac": ["flac"], "wav": ["pcm_s16le", "pcm_s24le", "pcm_f32le"], "aiff": ["pcm_s16be", "pcm_s24be"], "ogg": ["vorbis", "opus"], "opus": ["opus"]]
        options = ["-map", "0:a:0", "-vn"]
        if copyCodecs[target, default: []].contains(a) { options += ["-c:a", "copy"] }
        else {
            let codec = ["mp3": "libmp3lame", "wav": "pcm_s16le", "flac": "flac", "aac": "aac", "m4a": "aac", "ogg": "libvorbis", "opus": "libopus", "aiff": "pcm_s16be"][target] ?? "aac"
            options += ["-c:a", codec]
            if ["mp3", "m4a", "aac"].contains(target) { options += ["-b:a", "192k"] }
            if target == "opus" { options += ["-b:a", "128k"] }
        }
    } else if target == "gif" {
        options = ["-filter_complex", "[0:v:0]fps=15,scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-an", "-loop", "0"]
    } else {
        let videoCopy: [String: [String]] = ["mp4": ["h264", "hevc", "av1", "mpeg4"], "mov": ["h264", "hevc", "prores", "mjpeg", "png", "mpeg4"], "webm": ["vp8", "vp9", "av1"], "avi": ["h264", "mpeg4", "msmpeg4v3", "mjpeg"]]
        let audioCopy: [String: [String]] = ["mp4": ["aac", "mp3", "alac"], "mov": ["aac", "alac", "mp3", "pcm_s16le", "pcm_s24le"], "webm": ["opus", "vorbis"], "avi": ["mp3", "pcm_s16le"]]
        let vc = !compress && (target == "mkv" || videoCopy[target, default: []].contains(v))
        let ac = !compress && (target == "mkv" || audioCopy[target, default: []].contains(a))
        options = ["-map", "0:v:0", "-map", "0:a:0?"]
        if vc { options += ["-c:v", "copy"] }
        else if target == "webm" { options += ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "6", "-crf", "34", "-b:v", "0"] }
        else if target == "avi" { options += ["-c:v", "mpeg4", "-q:v", "5"] }
        else { options += ["-c:v", "h264_videotoolbox", "-b:v", compress ? "2500k" : "6000k", "-pix_fmt", "yuv420p", "-allow_sw", "1"] }
        if ac { options += ["-c:a", "copy"] }
        else { options += ["-c:a", target == "webm" ? "libopus" : target == "avi" ? "libmp3lame" : "aac", "-b:a", "160k"] }
        if ["mp4", "mov"].contains(target) { options += ["-movflags", "+faststart"] }
        if target == "mp4" && v == "hevc" && vc { options += ["-tag:v", "hvc1"] }
    }
    func attempt(_ hardware: Bool, _ opts: [String]) throws {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if hardware && !audioOnly { args += ["-hwaccel", "videotoolbox"] }
        args += ["-i", input.path] + opts + [output.path]
        try run("ffmpeg", args)
    }
    do { try attempt(true, options) }
    catch {
        do { try attempt(false, options) }
        catch {
            if let i = options.firstIndex(of: "h264_videotoolbox") {
                var soft = options; soft[i] = "libx264"
                if let j = soft.firstIndex(of: "-allow_sw") { soft.removeSubrange(j...j+1) }
                soft += ["-preset", "veryfast"]
                try attempt(false, soft)
            } else { throw error }
        }
    }
}
func convert(_ input: URL, target: String, work: URL) throws -> (URL, Bool, String) {
    let ext = input.pathExtension.lowercased(), kind = category(ext)
    let out = work.appendingPathComponent("result").appendingPathExtension(target)
    if !coreTargets(ext).contains(target), FileeBridge.shared.available {
        let outputs = try FileeBridge.shared.convert([input], target: target, into: work)
        if outputs.count == 1 { let output = outputs[0]; return (output, isFolder(output), output.pathExtension) }
        let directory = work.appendingPathComponent("outputs", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for output in outputs { try fm.moveItem(at: output, to: directory.appendingPathComponent(output.lastPathComponent)) }
        return (directory, true, "")
    }
    if target == "zip" {
        try run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, out.path]); return (out, false, target)
    }
    if target == "compress" {
        let destination: URL
        switch kind {
        case "pdf": destination = work.appendingPathComponent("compressed.pdf"); try compressPDF(input, destination)
        case "video": destination = work.appendingPathComponent("compressed.mp4"); try media(input, destination, "mp4", compress: true)
        case "images":
            let format = ["png", "webp", "gif", "avif"].contains(ext) ? ext : "jpg"
            destination = work.appendingPathComponent("compressed").appendingPathExtension(format)
            if format == "jpg" {
                do { try run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "74", input.path, "--out", destination.path]) }
                catch { try run("magick", [input.path + "[0]", "-strip", "-quality", "74", destination.path]) }
            } else { try run("magick", [input.path, "-strip", "-quality", "74", destination.path]) }
        default: throw HCError("Compression is unavailable for this type.")
        }
        return (destination, false, destination.pathExtension)
    }
    if ext == "pdf" {
        if target == "txt" { try run("pdftotext", ["-layout", input.path, out.path]); return (out, false, target) }
        let folder = work.appendingPathComponent("pages", isDirectory: true); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("pdftoppm", [target == "jpg" ? "-jpeg" : "-png", "-r", "150", input.path, folder.appendingPathComponent("page").path])
        guard !(try fm.contentsOfDirectory(atPath: folder.path)).isEmpty else { throw HCError("PDF has no exportable pages.") }
        return (folder, true, "")
    }
    if kind == "images" {
        let magickInput = ["gif", "webp"].contains(target) && ["gif", "webp"].contains(ext) ? input.path : input.path + "[0]"
        if target == "pdf" {
            let png = work.appendingPathComponent("decoded.png")
            do { try run("sips", ["-s", "format", "png", input.path, "--out", png.path]) }
            catch { try run("magick", [input.path + "[0]", png.path]) }
            try imagePDF(png, out)
        } else {
            let sipsFormats = ["jpg": "jpeg", "png": "png", "tiff": "tiff", "bmp": "bmp", "heic": "heic", "heif": "heic"]
            if let format = sipsFormats[target], !["svg", "gif", "ico"].contains(ext) {
                do { try run("sips", ["-s", "format", format, input.path, "--out", out.path]) }
                catch { try run("magick", [magickInput, out.path]) }
            } else { try run("magick", [magickInput, out.path]) }
        }
        return (out, false, target)
    }
    if kind == "audio" || kind == "video" { try media(input, out, target); return (out, false, target) }
    if kind == "spreadsheets" || kind == "slides" { return (try office(input, to: target, work: work), false, target) }
    if kind == "documents" {
        var source = input
        if ["doc", "odt", "rtf"].contains(ext) { source = try office(input, to: "docx", work: work) }
        if target == "pdf" {
            let printable = ["md", "html", "htm", "txt", "epub"].contains(ext) ? work.appendingPathComponent("printable.docx") : source
            if printable != source { try run("pandoc", [source.path, "-o", printable.path]) }
            return (try office(printable, to: "pdf", work: work), false, target)
        }
        if ["doc", "odt", "rtf"].contains(target) {
            if ["md", "html", "htm", "txt", "epub"].contains(ext) {
                source = work.appendingPathComponent("intermediate.docx"); try run("pandoc", [input.path, "-o", source.path])
            }
            return (try office(source, to: target, work: work), false, target)
        }
        let format = ["txt": "plain", "md": "gfm", "html": "html5", "docx": "docx", "epub": "epub"][target] ?? target
        var args = [source.path, "-t", format, "-o", out.path]
        if target == "html" { args += ["--standalone", "--embed-resources"] }
        if ext == "txt" { args += ["-f", "markdown"] }
        try run("pandoc", args); return (out, false, target)
    }
    throw HCError("Unsupported conversion.")
}
func submit(_ files: [URL], target: String, mode: String?) {
    guard !files.isEmpty else { return }
    if target == "zip" {
        do { submitWorkflow(files, workspace: try WorkflowWorkspace(files), target: nil, archive: true, separate: Store.shared.config.separateArchives) }
        catch { finishJob("ZIP", outputs: [], originals: files, error: error) }
        return
    }
    let ext = files[0].pathExtension.lowercased()
    Store.shared.used(ext, target)
    jobs.async {
        var outputs: [URL] = [], failures: [String] = []
        for file in files {
            do {
                let work = try workDirectory(); defer { try? fm.removeItem(at: work) }
                let (staged, folder, newExt) = try convert(file, target: target, work: work)
                guard fm.fileExists(atPath: staged.path) else { throw HCError("The converter created no output.") }
                var stem = file.deletingPathExtension().lastPathComponent
                if target == "compress" { stem += " compressed" }
                if folder { stem += target == "folder" ? " extracted" : category(file.pathExtension.lowercased()) == "pdf" ? " \(target.uppercased()) pages" : " \(target.uppercased()) outputs" }
                let output = try publish(staged, beside: file, stem: stem, ext: newExt, folder: folder)
                outputs.append(output)
                if mode == "trash" { _ = try fm.trashItem(at: file, resultingItemURL: nil) }
                log("Converted \(file.path) -> \(output.path)\(mode == "trash" ? " (original trashed)" : "")")
            } catch { failures.append("\(file.lastPathComponent): \(error.localizedDescription)"); log(failures.last!) }
        }
        let resultOutputs = outputs, errors = failures
        DispatchQueue.main.async {
            if mode == "clipboard" && !resultOutputs.isEmpty {
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(resultOutputs as [NSURL])
            }
            let title = errors.isEmpty ? "\(resultOutputs.count) conversion\(resultOutputs.count == 1 ? "" : "s") finished" : "\(resultOutputs.count) finished · \(errors.count) failed"
            let body = errors.first ?? (mode == "clipboard" ? "Converted files copied to clipboard." : resultOutputs.map(\.lastPathComponent).joined(separator: ", "))
            let reveal = resultOutputs.isEmpty ? files : resultOutputs
            Store.shared.record(Record(title: title, paths: reveal.map(\.path), failed: !errors.isEmpty))
            Notices.shared.send(title, body, reveal)
        }
    }
}

func roundedHex(_ rect: CGRect, radius: CGFloat = 7) -> CGPath {
    let center = CGPoint(x: rect.midX, y: rect.midY), r = rect.width / 2
    let vertices = (0..<6).map { i -> CGPoint in let a = CGFloat(i) * .pi / 3; return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)) }
    let path = CGMutablePath()
    for i in 0..<6 {
        let prev = vertices[(i+5)%6], v = vertices[i], next = vertices[(i+1)%6]
        func inset(_ a: CGPoint) -> CGPoint { let d = hypot(a.x-v.x, a.y-v.y); let f = min(0.35, radius / max(1, d)); return CGPoint(x: v.x + (a.x-v.x)*f, y: v.y + (a.y-v.y)*f) }
        let start = inset(prev), end = inset(next)
        if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addQuadCurve(to: end, control: v)
    }
    path.closeSubpath(); return path
}
final class Overlay {
    static let shared = Overlay()
    var panel: NSPanel?
    var hexes: [HexView] = []
    var paths: [CGPath] = []
    var choices: [Choice] = []
    var hover = -1
    var menuIDs: [String] = []
    var page = 0
    var returnPage = 0
    var extraChoices: [Choice] = []
    var files: [URL] = []
    var mode: String?
    var sourceLabel = "HEIC"
    var active = false
    var testing = false
    var onComplete: ((Choice?) -> Void)?
    var rootPoint = CGPoint.zero
    func show(files: [URL], point: CGPoint, test: Bool = false) {
        self.files = files; testing = test; mode = nil; page = 0; rootPoint = point
        extraChoices = []
        FileeBridge.shared.prepare(files)
        let ext = files.first.map(fileeExtension) ?? "heic"
        sourceLabel = Set(files.map { $0.pathExtension.lowercased() }).count > 1 ? "BATCH" : ext.uppercased()
        if files.count > 1 { sourceLabel += " ×\(files.count)" }
        var common = files.isEmpty ? targets(ext) : targets(ext).filter { target in files.allSatisfy { target == "zip" || (!$0.hasDirectoryPath && targets(fileeExtension($0)).contains(target)) } }
        if common.allSatisfy({ ["trash", "clipboard", "zip"].contains($0) }) { common.removeAll { $0 == "trash" || $0 == "clipboard" } }
        menuIDs = Store.shared.ordered(ext, category(ext), common)
        draw(point: point, animate: true)
    }
    func draw(point: CGPoint, animate: Bool) {
        active = true; hover = -1
        if mode != nil {
            let targets = menuIDs.filter { !["trash", "clipboard", "zip", "compress"].contains($0) }
            choices = radialPage(targets.map { Choice(id: $0) }, index: page, back: true)
        } else if page == 0 {
            choices = menuIDs.prefix(5).map { Choice(id: $0) } + [Choice(id: "more")]
        } else {
            choices = radialPage(extraChoices, index: page - 1, back: true)
        }
        let size: CGFloat = 332
        let animate = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let appPoint = toAppKit(point)
        let screen = NSScreen.screens.first { $0.frame.contains(appPoint) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let x = min(max(visible.minX, appPoint.x-size/2), visible.maxX-size)
        let y = min(max(visible.minY, appPoint.y-size/2), visible.maxY-size)
        let frame = NSRect(x: x, y: y, width: size, height: size)
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if window.frame != frame { window.setFrame(frame, display: false) }
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); content.wantsLayer = true; window.contentView = content
        panel = window; hexes = []; paths = []
        let center = CGPoint(x: size/2, y: size/2), r: CGFloat = 53, distance: CGFloat = sqrt(3)*53 + 2.4
        let middle = HexView(frame: NSRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r), title: sourceLabel, icon: "hexagon", center: true)
        content.addSubview(middle)
        if animate {
            let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.55; spring.toValue = 1; spring.mass = 0.35; spring.stiffness = 550; spring.damping = 23; spring.duration = 0.11; middle.layer?.add(spring, forKey: "appear")
        }
        for (index, choice) in choices.enumerated() {
            let slot = choice.id == "more" ? 5 : choice.id == "back" ? 4 : index
            let a = .pi/2 - CGFloat(slot) * .pi/3
            let origin = CGPoint(x: center.x + cos(a)*distance-r, y: center.y + sin(a)*distance-r)
            let rect = CGRect(origin: origin, size: CGSize(width: 2*r, height: 2*r))
            let view = HexView(frame: rect, title: choice.title, icon: choice.icon, center: false)
            content.addSubview(view); hexes.append(view); paths.append(roundedHex(rect.insetBy(dx: 0.75, dy: 0.75), radius: 9))
            if animate {
                let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.55; spring.toValue = 1; spring.mass = 0.35; spring.stiffness = 550; spring.damping = 23; spring.duration = 0.11; spring.beginTime = CACurrentMediaTime() + Double(index)*0.001
                view.layer?.add(spring, forKey: "appear")
            }
        }
        window.alphaValue = animate ? 0 : 1; window.orderFrontRegardless()
        if animate { NSAnimationContext.runAnimationGroup { context in context.duration = 0.09; window.animator().alphaValue = 1 } }
        update(point)
    }
    func update(_ point: CGPoint) {
        guard active, let panel = panel else { return }
        let app = toAppKit(point), p = CGPoint(x: app.x-panel.frame.minX, y: app.y-panel.frame.minY)
        // Hit-test Quartz coordinates against our own rounded hex paths; the panel remains click-through.
        let index = paths.firstIndex { $0.contains(p) } ?? -1
        if hover != index {
            hover = index
            for (i, view) in hexes.enumerated() { view.hover(i == index, dim: index >= 0 && i != index) }
            if index >= 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
    func release(_ point: CGPoint) -> Bool {
        update(point)
        guard hover >= 0 && hover < choices.count else { dismiss(); return false }
        let chosen = choices[hover]
        if chosen.id == "more" || chosen.id == "back" {
            if chosen.id == "more" {
                if page == 0, mode == nil {
                    let newTargets = availableTargets(files).filter { !menuIDs.contains($0) }
                    extraChoices = radialOptions(files: files, ordered: menuIDs + newTargets, test: testing)
                }
                page += 1
            } else if page == 0, mode != nil {
                mode = nil; page = returnPage
            } else {
                page -= 1
            }
            draw(point: rootPoint, animate: false)
            return true
        }
        if chosen.id == "trash" || chosen.id == "clipboard" {
            mode = chosen.id; returnPage = page; page = 0
            draw(point: rootPoint, animate: false); return true
        }
        if let tool = chosen.tool {
            let selected = files
            hexes[hover].pulse(); dismiss()
            if !testing { DispatchQueue.main.async { ToolWindowManager.shared.open(tool, files: selected) } }
            return false
        }
        hexes[hover].pulse(); dismiss()
        if !testing {
            if chosen.id.hasPrefix("preset:") {
                do { submitWorkflow(files, workspace: try WorkflowWorkspace(files), target: chosen.id, archive: false, separate: false) }
                catch { finishJob(chosen.title, outputs: [], originals: files, error: error) }
            } else {
                submit(files, target: chosen.id, mode: mode)
            }
        }
        return false
    }
    func dismiss() {
        active = false
        guard let old = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.085; old.animator().alphaValue = 0 }) { old.orderOut(nil) }
    }
}
func toAppKit(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0)-point.y) }
struct FinderSnapshot {
    var urls: [URL]
    var reason: String?
}

func clickedFile(_ point: CGPoint) -> URL? {
    let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.04)
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success else { return nil }
    for _ in 0..<5 {
        guard let current = element else { break }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue) == .success, let role = roleValue as? String, ["AXWindow", "AXScrollArea", "AXBrowser", "AXApplication", "AXTable", "AXOutline", "AXToolbar"].contains(role) { break }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &value) == .success {
            if let url = value as? URL, url.isFileURL, fm.fileExists(atPath: url.path) { return url }
            if let text = value as? String, let url = URL(string: text), url.isFileURL, fm.fileExists(atPath: url.path) { return url }
        }
        value = nil
        if AXUIElementCopyAttributeValue(current, "AXFilename" as CFString, &value) == .success, let path = value as? String, path.hasPrefix("/"), fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        value = nil
        if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &value) == .success, let role = value as? String, ["AXWindow", "AXScrollArea", "AXBrowser"].contains(role) { break }
        value = nil
        if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &value) != .success { break }
        if let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() { element = (value as! AXUIElement) } else { break }
    }
    return nil
}

func readFinder(at point: CGPoint) -> FinderSnapshot {
    let source = """
    tell application "Finder"
        set outPaths to {}
        repeat with f in (get selection)
            try
                set end of outPaths to POSIX path of (f as alias)
            end try
        end repeat
        return outPaths
    end tell
    """
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error = error {
        log("Finder: \(error)")
        return FinderSnapshot(urls: [], reason: "Allow Automation → Finder for Honeycomb.")
    }
    var files: [URL] = []
    if let result = result, result.numberOfItems > 0 {
        for i in 1...result.numberOfItems { if let path = result.atIndex(i)?.stringValue { let url = URL(fileURLWithPath: path); if fm.fileExists(atPath: url.path) { files.append(url) } } }
    }
    if let clicked = clickedFile(point), !files.contains(where: { $0.standardizedFileURL == clicked.standardizedFileURL }) { files = [clicked] }
    return FinderSnapshot(urls: files, reason: files.isEmpty ? "Select a file on your desktop, then hold your Honeycomb shortcut and move the pointer." : nil)
}
func finderPermission(_ prompt: Bool) {
    finderQueue.async {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
        DispatchQueue.main.async { Store.shared.automation = status == noErr }
    }
}
final class Gesture {
    static let shared = Gesture()
    var tap: CFMachPort?
    var runSource: CFRunLoopSource?
    var timer: DispatchWorkItem?
    var selectionDeadline: DispatchWorkItem?
    var pending = false
    var holdElapsed = false
    var open = false
    var trackingClick = false
    var shortcutGesture = false
    var needsShortcutRelease = false
    var heldKeys = Set<Int>()
    var swallowedShortcutKey: Int?
    var start = CGPoint.zero
    var lastPoint = CGPoint.zero
    var buffered: [CGEvent] = []
    var snapshot: FinderSnapshot?
    var token = UUID()
    let replayTag: Int64 = 0x48434F4D42
    var testTimer: Timer?
    var testMode = false
    var finderPID: pid_t = 0
    var finderContext: ((CGPoint) -> Bool)?
    var pointerLocation: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    var presentMenu: ([URL], CGPoint) -> Void = { Overlay.shared.show(files: $0, point: $1) }
    var releaseMenu: (CGPoint) -> Bool = { Overlay.shared.release($0) }
    var replayEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    var resolveFiles: (CGPoint, @escaping (FinderSnapshot) -> Void) -> Void = { point, done in
        finderQueue.async { let result = readFinder(at: point); DispatchQueue.main.async { done(result) } }
    }
    var readyText: String { Store.shared.config.gestureMode == "shortcut" ? "Ready · hold \(Store.shared.config.shortcut.label) and move the pointer" : "Ready · Option + click-and-hold" }
    func install() {
        guard tap == nil else { return }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .flagsChanged, .keyDown, .keyUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // The active tap consumes the shortcut/click before Finder can start a drag or Quick Look.
        guard let value = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<Gesture>.fromOpaque(info).takeUnretainedValue().event(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Store.shared.tapOK = false; Store.shared.gestureStatus = "Grant Accessibility and Input Monitoring, then Restart"; return
        }
        tap = value; runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, value, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes); CGEvent.tapEnable(tap: value, enable: true)
        Store.shared.tapOK = true; Store.shared.gestureStatus = readyText
        finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
        log("Active event tap ready; gesture=\(Store.shared.config.gestureMode), shortcut=\(Store.shared.config.shortcut.label)")
    }
    func uninstall() {
        abort(); Overlay.shared.dismiss(); open = false; trackingClick = false
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = runSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; runSource = nil; heldKeys.removeAll(); swallowedShortcutKey = nil
    }
    func finderAt(_ point: CGPoint) -> Bool {
        if let test = finderContext { return test(point) }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" { return true }
        if finderPID == 0 { finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0 }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.025)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element = element {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { return pid == finderPID && pid != 0 }
        }
        return false
    }
    func begin(at point: CGPoint, mouseDown: CGEvent? = nil, shortcut: Bool) {
        guard !pending, !open else { return }
        pending = true; holdElapsed = false; shortcutGesture = shortcut; start = point; lastPoint = point
        buffered = mouseDown?.copy().map { [$0] } ?? []; trackingClick = mouseDown != nil; snapshot = nil
        token = UUID(); let current = token
        log("Gesture candidate captured: \(shortcut ? "shortcut" : "click hold")")
        resolveFiles(point) { [weak self] result in
            guard let self = self, self.pending, self.token == current else { return }
            self.snapshot = result; log("Desktop/Finder selection ready: \(result.urls.count) item(s)")
            if self.holdElapsed { self.activate(current) }
        }
        let delay = Store.shared.config.holdMilliseconds / 1000
        if !shortcut {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.pending, self.token == current else { return }
                self.holdElapsed = true; self.activate(current)
            }; timer = work
            DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
        }
        // A delayed selection query keeps the hold armed; mouse-up always remains a way to cancel.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.pending, self.token == current else { return }
            Store.shared.gestureStatus = "Desktop selection unavailable — check Automation → Finder"
            log("Selection query timed out; restoring click"); self.abort()
        }
        selectionDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now()+max(3, delay+1.5), execute: timeout)
    }
    func keyboard(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown { heldKeys.insert(code) }
        if type == .keyUp { heldKeys.remove(code) }
        if type == .keyDown && code == 53 && (open || pending) {
            if pending { abort() }; Overlay.shared.dismiss(); open = false; needsShortcutRelease = true; return true
        }
        guard Store.shared.config.gestureMode == "shortcut" else { return false }
        let shortcut = Store.shared.config.shortcut
        let isHeld = shortcut.requiredHeld(event.flags, heldKeys)
        if !isHeld {
            needsShortcutRelease = false
            if shortcutGesture {
                if pending { abort() }
                if open { open = releaseMenu(pointerLocation()); shortcutGesture = false }
            }
        }
        if type == .keyUp && swallowedShortcutKey == code { swallowedShortcutKey = nil; return true }
        if type == .keyDown && swallowedShortcutKey == code { return true }
        guard Store.shared.config.enabled, !Store.shared.recordingShortcut, !needsShortcutRelease, shortcut.matches(event.flags, heldKeys) else { return false }
        let point = pointerLocation()
        if !open && !pending && finderAt(point) { begin(at: point, shortcut: true) }
        if type == .keyDown && code == shortcut.keyCode && (pending || open) && shortcutGesture { swallowedShortcutKey = code; return true }
        return false
    }
    func event(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == replayTag { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            abort(); if open { Overlay.shared.dismiss(); open = false }
            trackingClick = CGEventSource.buttonState(.hidSystemState, button: .left)
            heldKeys.removeAll(); swallowedShortcutKey = nil; needsShortcutRelease = false
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("Event tap re-enabled"); return Unmanaged.passUnretained(event)
        }
        if Store.shared.recordingShortcut { heldKeys.removeAll(); return Unmanaged.passUnretained(event) }
        if [.keyDown, .keyUp, .flagsChanged].contains(type) {
            if keyboard(type, event) { return nil }
            if pending && !shortcutGesture && type == .flagsChanged && !event.flags.contains(.maskAlternate) { abort() }
            return Unmanaged.passUnretained(event)
        }
        lastPoint = event.location
        if open {
            if type == .leftMouseDown { trackingClick = true; return nil }
            if type == .leftMouseUp {
                open = releaseMenu(event.location); trackingClick = false
                if shortcutGesture { needsShortcutRelease = true; shortcutGesture = false }
                return nil
            }
            if type == .leftMouseDragged || type == .mouseMoved { Overlay.shared.update(event.location); return type == .leftMouseDragged ? nil : Unmanaged.passUnretained(event) }
            return Unmanaged.passUnretained(event)
        }
        if trackingClick && !pending {
            if type == .leftMouseUp { trackingClick = false; return nil }
            if type == .leftMouseDragged || type == .leftMouseDown { return nil }
        }
        if !pending && Store.shared.config.enabled && Store.shared.config.gestureMode == "shortcut" && !needsShortcutRelease && type == .mouseMoved && Store.shared.config.shortcut.matches(event.flags, heldKeys) && finderAt(event.location) { begin(at: event.location, shortcut: true) }
        if pending {
            if shortcutGesture && type == .leftMouseDown {
                if let copy = event.copy() { buffered.append(copy) }; trackingClick = true; return nil
            }
            if type == .leftMouseDragged || type == .leftMouseUp {
                if let copy = event.copy() { buffered.append(copy) }
                if type == .leftMouseUp { abort(); return nil }
                if shortcutGesture {
                    holdElapsed = true; activate(token)
                } else if !holdElapsed && hypot(event.location.x-start.x, event.location.y-start.y) > 5 { abort() }
                return nil
            }
            if shortcutGesture && type == .mouseMoved && hypot(event.location.x-start.x, event.location.y-start.y) > 1 {
                holdElapsed = true; activate(token)
            }
            return Unmanaged.passUnretained(event)
        }
        guard Store.shared.config.enabled, Store.shared.config.gestureMode == "clickHold", type == .leftMouseDown, event.flags.contains(.maskAlternate), !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl), finderAt(event.location) else { return Unmanaged.passUnretained(event) }
        begin(at: event.location, mouseDown: event, shortcut: false); return nil
    }
    func activate(_ current: UUID) {
        guard pending, holdElapsed, token == current else { return }
        guard Store.shared.config.enabled else { abort(); return }
        guard let result = snapshot else { return }
        guard !result.urls.isEmpty else {
            let reason = result.reason ?? "Select a desktop file first."
            Store.shared.gestureStatus = reason; log(reason); abort(); Notices.shared.send("Honeycomb", reason, []); return
        }
        // Track the captured down/up ourselves: swallowing mouse-down can leave session button state false.
        pending = false; holdElapsed = false; buffered = []; timer?.cancel(); timer = nil
        selectionDeadline?.cancel(); selectionDeadline = nil; open = true
        Store.shared.gestureStatus = readyText; log("Honeycomb menu opened")
        presentMenu(result.urls, start); Overlay.shared.update(lastPoint)
    }
    func abort() {
        timer?.cancel(); timer = nil; selectionDeadline?.cancel(); selectionDeadline = nil
        pending = false; holdElapsed = false; token = UUID(); snapshot = nil; shortcutGesture = false
        let events = buffered; buffered = []
        if events.contains(where: { $0.type == .leftMouseDown }) { trackingClick = false }
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: replayTag); replayEvent(event) }
    }
    func test() {
        if pending { abort() }; Overlay.shared.dismiss(); open = false; shortcutGesture = false
        let point = pointerLocation(); Overlay.shared.show(files: [], point: point, test: true)
        if tap != nil { open = true; return }
        testMode = true; testTimer?.invalidate()
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self else { return }; Overlay.shared.update(self.pointerLocation())
            if !Overlay.shared.active { self.testTimer?.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self = self, self.testMode else { return }; self.testTimer?.invalidate(); Overlay.shared.dismiss(); self.testMode = false
        }
    }
}
final class ShortcutButton: NSButton {
    var capturedModifiers: NSEvent.ModifierFlags = []
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        capturedModifiers = []; Store.shared.recordingShortcut = true; window?.makeFirstResponder(self); title = "Press shortcut…"
    }
    func finish(_ shortcut: Shortcut?) {
        if let shortcut = shortcut { Store.shared.config.shortcut = shortcut; Store.shared.save() }
        Store.shared.recordingShortcut = false; title = Store.shared.config.shortcut.label; window?.makeFirstResponder(nil)
    }
    override func keyDown(with event: NSEvent) {
        guard Store.shared.recordingShortcut else { return }
        if event.keyCode == 53 { finish(nil); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { title = "Include ⌥, ⌃, ⌘ or ⇧"; return }
        let names: [UInt16: String] = [49:"Space",36:"Return",48:"Tab",51:"Delete",123:"←",124:"→",125:"↓",126:"↑"]
        let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        finish(Shortcut(keyCode: Int(event.keyCode), modifiers: quartzModifiers(flags), label: modifierLabel(flags)+" "+key))
    }
    override func flagsChanged(with event: NSEvent) {
        guard Store.shared.recordingShortcut else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && !capturedModifiers.isEmpty {
            finish(Shortcut(keyCode: nil, modifiers: quartzModifiers(capturedModifiers), label: modifierLabel(capturedModifiers)))
        } else if !flags.isEmpty { capturedModifiers = flags; title = modifierLabel(flags)+" …" }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Store.shared.recordingShortcut { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool { Store.shared.recordingShortcut = false; return true }
}
struct ShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton(title: Store.shared.config.shortcut.label, target: nil, action: nil)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        if !Store.shared.recordingShortcut { button.title = Store.shared.config.shortcut.label }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    var window: NSWindow!
    var status: NSStatusItem!
    var enabledItem: NSMenuItem!
    var refresh: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: "app.honeycomb.personal").filter { $0.processIdentifier != getpid() }
        if !other.isEmpty { other.first?.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return }
        _ = Store.shared
        Notices.shared.setup(); finderPermission(true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 425, height: 615), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Honeycomb"; window.appearance = NSAppearance(named: .aqua); window.titleVisibility = .visible; window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false; window.delegate = self; window.backgroundColor = .clear; window.isOpaque = false
        window.contentView = NSHostingView(rootView: MainView()); window.center()
        window.contentMinSize = NSSize(width: 390, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        installMainMenu()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "hexagon", accessibilityDescription: "Honeycomb")
        let menu = NSMenu(); enabledItem = NSMenuItem(title: "On", action: #selector(toggle), keyEquivalent: ""); enabledItem.target = self; menu.addItem(enabledItem)
        let openItem = NSMenuItem(title: "Open Honeycomb", action: #selector(show), keyEquivalent: ""); openItem.target = self; menu.addItem(openItem)
        menu.addItem(.separator()); let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self; menu.addItem(quitItem); status.menu = menu
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.enabledItem.state = Store.shared.config.enabled ? .on : .off
            if let tap = Gesture.shared.tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        Store.shared.permissions(); setLogin(Store.shared.config.startAtLogin)
        if !CommandLine.arguments.contains("--background") { show() }
        if CommandLine.arguments.contains("--request-accessibility"), !Store.shared.ax {
            requestAccessibility()
        }
        if CommandLine.arguments.contains("--request-input-monitoring"), !Store.shared.input {
            DispatchQueue.main.async { _ = CGRequestListenEventAccess() }
        }
        log("Honeycomb started")
    }
    func installMainMenu() {
        let main = NSMenu()
        func addMenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            for entry in items { menu.addItem(entry) }
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        _ = addMenu("Honeycomb", [
            NSMenuItem(title: "Hide Honeycomb", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit Honeycomb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ])
        _ = addMenu("Edit", [
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ])
        let fullscreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        let windows = addMenu("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            fullscreen,
            .separator(),
            NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }
    @MainActor @objc func show() {
        showAppWindow(window)
        finderPermission(false)
    }
    func windowWillClose(_ notification: Notification) {
        updateActivationAfterClose()
    }
    @objc func toggle() { Store.shared.config.enabled.toggle(); Store.shared.save(); if !Store.shared.config.enabled { Gesture.shared.abort(); Gesture.shared.open = false; Overlay.shared.dismiss() } }
    @objc func quit() { NSApp.terminate(nil) }
    func restart() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; /usr/bin/open -n -g /Applications/Honeycomb.app --args --background"]
        try? p.run(); NSApp.terminate(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Gesture.shared.abort(); if let tap = Gesture.shared.tap { CGEvent.tapEnable(tap: tap, enable: false) }; log("Honeycomb stopped") }
}

func makeIcon(_ destination: URL) throws {
    let sizes = [("icp4",16), ("ic11",32), ("icp5",32), ("ic12",64), ("ic07",128),
                 ("ic13",256), ("ic08",256), ("ic14",512), ("ic09",512), ("ic10",1024)]
    func length(_ size: Int) -> Data {
        var value = UInt32(size).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    var images = Data()
    for (kind, pixels) in sizes {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HCError("Icon allocation failed.") }
        ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let bg = CGPath(roundedRect: CGRect(x: 35, y: 35, width: 954, height: 954), cornerWidth: 218, cornerHeight: 218, transform: nil)
        ctx.addPath(bg); ctx.clip()
        let colors = [NSColor(white: 0.94, alpha: 1).cgColor, NSColor(white: 0.55, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0,1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 1024), end: CGPoint(x: 800, y: 0), options: [])
        let radius: CGFloat = 120, distance: CGFloat = 215
        var centers = [CGPoint(x: 512, y: 512)]
        for i in 0..<6 { let a = CGFloat.pi / 2 - CGFloat(i) * .pi / 3; centers.append(CGPoint(x:512+cos(a)*distance,y:512+sin(a)*distance)) }
        for (i, point) in centers.enumerated() {
            let shape = roundedHex(CGRect(x: point.x-radius,y:point.y-radius,width:radius*2,height:radius*2), radius: 21)
            ctx.setShadow(offset: CGSize(width: 0, height: -9), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor(white: i == 0 ? 0.91 : 0.99, alpha: 0.82).cgColor)
            ctx.addPath(shape); ctx.fillPath(); ctx.setShadow(offset: .zero, blur: 0)
            ctx.addPath(shape); ctx.setLineWidth(3); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor); ctx.strokePath()
        }
        guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw HCError("Icon encoding failed.") }
        images.append(Data(kind.utf8))
        images.append(length(png.count + 8))
        images.append(png)
    }
    var icon = Data("icns".utf8)
    icon.append(length(images.count + 8))
    icon.append(images)
    try icon.write(to: destination, options: .atomic)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--make-icon" {
    do { try makeIcon(URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
    catch { fputs("Icon error: \(error.localizedDescription)\n", stderr); exit(1) }
}

// Open Tangerine / Formats/ConversionMatrix.swift
import Foundation

enum ConversionMatrix {
    static func targets(for source: FileFormat) -> [FileFormat] {
        let list: [FileFormat]
        switch source {
        case .jpg, .png:
            list = FileFormat.imageTargets + [.docx]
        case .webp, .heic, .tiff, .svg, .avif, .bmp:
            list = FileFormat.imageTargets
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            list = FileFormat.audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            list = FileFormat.video + [.gif, .mp3]
        case .gif:
            list = FileFormat.video
        case .pdf:
            list = [.docx, .jpg, .png, .txt]
        case .txt:
            list = [.pdf, .jpg, .png, .srt, .vtt]
        case .srt, .vtt:
            list = FileFormat.subtitles + [.txt]
        case .zip, .tar, .gz, .rar:
            list = [] // Archive engine is disabled; do not offer operations that always fail.
        case .docx:
            list = []
        }
        return list.filter { $0 != source }
    }

    static func targets(for sources: [FileFormat]) -> [FileFormat] {
        guard let first = sources.first else { return [] }
        var common = targets(for: first)
        for source in sources.dropFirst() {
            let next = Set(targets(for: source))
            common = common.filter { next.contains($0) }
        }
        return common
    }

    static var totalConversions: Int {
        FileFormat.allCases.reduce(0) { $0 + targets(for: $1).count }
    }

    static func outputURL(for source: URL, target: FileFormat, in directory: URL, existing: Set<String> = []) -> URL {
        let base = strippedBaseName(source.lastPathComponent)
        var candidate = "\(base).\(target.fileExtension)"
        var counter = 2
        let fm = FileManager.default
        while existing.contains(candidate) || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter).\(target.fileExtension)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func uniqueURL(directory: URL, baseName: String, suffix: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = suffix.isEmpty ? "\(baseName).\(ext)" : "\(baseName) \(suffix).\(ext)"
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = suffix.isEmpty ? "\(baseName) \(counter).\(ext)" : "\(baseName) \(suffix) \(counter).\(ext)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func uniqueDirectory(directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func strippedBaseName(_ fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(fileName.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(fileName.dropLast(4)) }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }
}



// Open Tangerine / Formats/FileFormat.swift
import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String, CaseIterable {
    case image
    case audio
    case video
    case document
    case subtitle
    case archive

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return "doc.text"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        }
    }

    var title: String {
        switch self {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Document"
        case .subtitle: return "Subtitle"
        case .archive: return "Archive"
        }
    }
}

enum FileFormat: String, CaseIterable, Identifiable, Hashable {
    case jpg, png, webp, heic, tiff, svg, avif, bmp, gif
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv
    case pdf, docx, txt
    case srt, vtt
    case zip, tar, gz, rar

    var id: String { rawValue }

    static let images: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp]
    static let imageTargets: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
    static let audio: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let video: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    static let subtitles: [FileFormat] = [.srt, .vtt]
    static let archives: [FileFormat] = [.zip, .tar, .gz, .rar]

    var category: FormatCategory {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp: return .image
        case .gif: return .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: return .video
        case .pdf, .docx, .txt: return .document
        case .srt, .vtt: return .subtitle
        case .zip, .tar, .gz, .rar: return .archive
        }
    }

    var displayName: String {
        switch self {
        case .gz: return "GZIP"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .gz: return "tar.gz"
        default: return rawValue
        }
    }

    var aliases: [String] {
        switch self {
        case .jpg: return ["jpg", "jpeg", "jpe", "jfif"]
        case .tiff: return ["tiff", "tif"]
        case .heic: return ["heic", "heif"]
        case .m4a: return ["m4a", "aac", "m4b"]
        case .mp4: return ["mp4", "m4v"]
        case .mov: return ["mov", "qt"]
        case .gz: return ["gz", "tgz"]
        case .txt: return ["txt", "text", "md", "log"]
        case .aiff: return ["aiff", "aif"]
        default: return [rawValue]
        }
    }

    var utType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .svg: return .svg
        case .avif: return UTType("public.avif")
        case .bmp: return .bmp
        case .gif: return .gif
        case .mp3: return .mp3
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        case .flac: return UTType("org.xiph.flac")
        case .ogg: return UTType("org.xiph.ogg-audio") ?? UTType("public.ogg")
        case .opus: return UTType("public.opus") ?? UTType("org.xiph.opus")
        case .aiff: return .aiff
        case .wma: return UTType("com.microsoft.windows-media-wma")
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .mkv: return UTType("org.matroska.mkv")
        case .webm: return UTType("org.webmproject.webm")
        case .avi: return .avi
        case .wmv: return UTType("com.microsoft.windows-media-wmv")
        case .pdf: return .pdf
        case .docx: return UTType("org.openxmlformats.wordprocessingml.document")
        case .txt: return .plainText
        case .srt: return UTType("com.subrip.srt") ?? .plainText
        case .vtt: return UTType("org.w3.webvtt") ?? .plainText
        case .zip: return .zip
        case .tar: return UTType("public.tar-archive")
        case .gz: return .gzip
        case .rar: return UTType("com.rarlab.rar-archive")
        }
    }

    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .gz }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.aliases.contains(ext) }
    }

    static func detect(extension ext: String) -> FileFormat? {
        let lower = ext.lowercased()
        return allCases.first { $0.aliases.contains(lower) }
    }

    var isMultiTrack: Bool { category == .video || category == .audio }
}



// Open Tangerine / Engines/AVExporter.swift
import AVFoundation
import Foundation

enum AVExporter {
    static func fileType(for format: FileFormat) -> AVFileType? {
        switch format {
        case .mp4: return .mp4
        case .mov: return .mov
        case .m4a: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        default: return nil
        }
    }

    static func export(
        asset: AVAsset,
        to destination: URL,
        format: FileFormat,
        preset: String = AVAssetExportPresetHighestQuality,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil,
        metadata: [AVMetadataItem]? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        guard let type = fileType(for: format) else { throw OpenTangerineError.unsupportedConversion(.mp4, format) }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OpenTangerineError.encodeFailed("export session for \(format.displayName)")
        }
        session.outputURL = destination
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let audioMix { session.audioMix = audioMix }
        if let metadata { session.metadata = metadata }
        try? FileManager.default.removeItem(at: destination)

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let value = Double(session.progress)
                await MainActor.run { progress?(value) }
            }
        }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        ticker.cancel()
        try Task.checkCancellation()
        switch session.status {
        case .completed:
            progress?(1)
        case .cancelled:
            throw OpenTangerineError.cancelled
        default:
            throw OpenTangerineError.encodeFailed(session.error?.localizedDescription ?? "export failed")
        }
    }

    static func exportAudioPCM(asset: AVAsset, to destination: URL, format: FileFormat, timeRange: CMTimeRange? = nil, audioMix: AVAudioMix? = nil, progress: ((Double) -> Void)? = nil) async throws {
        try await withPCMWriter(asset: asset, to: destination, format: format, timeRange: timeRange, audioMix: audioMix, progress: progress)
    }

    private static func withPCMWriter(asset: AVAsset, to destination: URL, format: FileFormat, timeRange: CMTimeRange?, audioMix: AVAudioMix?, progress: ((Double) -> Void)?) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw OpenTangerineError.invalidInput("No audio track found.") }
        let duration = try await asset.load(.duration)
        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw OpenTangerineError.encodeFailed("Unsupported PCM audio reader format") }
        reader.add(output)
        if let timeRange { reader.timeRange = timeRange }

        let formatDescriptions = try await track.load(.formatDescriptions)
        var channels = 2
        var sampleRate = 44_100.0
        if let first = formatDescriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            sampleRate = asbd.pointee.mSampleRate
        }
        let fileType: AVFileType = format == .aiff ? .aiff : .wav
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw OpenTangerineError.encodeFailed("Unsupported PCM audio writer format") }
        writer.add(input)
        guard reader.startReading() else { throw OpenTangerineError.encodeFailed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw OpenTangerineError.encodeFailed(writer.error?.localizedDescription ?? "writer") }
        let start = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: start)
        let total = CMTimeGetSeconds(timeRange?.duration ?? duration)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "opentangerine.pcm.writer")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        guard input.append(sample) else {
                            reader.cancelReading()
                            input.markAsFinished()
                            let error = writer.error
                            writer.cancelWriting()
                            continuation.resume(throwing: OpenTangerineError.encodeFailed(error?.localizedDescription ?? "Could not write PCM audio sample"))
                            return
                        }
                        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - CMTimeGetSeconds(start)
                        if total > 0 { let value = min(1, max(0, time / total)); DispatchQueue.main.async { progress?(value) } }
                    } else {
                        input.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: OpenTangerineError.encodeFailed(reader.error?.localizedDescription ?? "reader"))
                        } else {
                            writer.finishWriting {
                                if writer.status == .completed {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: OpenTangerineError.encodeFailed(writer.error?.localizedDescription ?? "writer"))
                                }
                            }
                        }
                        return
                    }
                }
            }
        }
    }

    static func timeRange(start: Double, end: Double) -> CMTimeRange {
        let s = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let e = CMTime(seconds: max(start, end), preferredTimescale: 600)
        return CMTimeRange(start: s, end: e)
    }
}



// Open Tangerine / Engines/ArchiveEngine.swift
import Foundation

struct ArchiveEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar
    }

    func convert(_ request: ConversionRequest) async throws {
        throw OpenTangerineError.invalidInput("Archive conversion is disabled in this trial pending bounded, isolated extraction. Original archives are unchanged.")
    }

    func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.unzip(archive, into: directory)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        case .gz:
            let name = archive.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                let result = try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
                guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
            } else {
                let output = directory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                let result = try await Shell.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", archive.path, output.path])
                guard result.succeeded else { throw OpenTangerineError.toolFailed("gunzip", result.stderr) }
            }
        case .rar:
            let candidates = ["unar", "unrar", "bsdtar"]
            for tool in candidates {
                guard let path = Shell.which(tool) else { continue }
                let args: [String]
                switch tool {
                case "unar": args = ["-q", "-o", directory.path, archive.path]
                case "unrar": args = ["x", "-y", "-idq", archive.path, directory.path + "/"]
                default: args = ["-xf", archive.path, "-C", directory.path]
                }
                let result = try await Shell.run(path, args)
                if result.succeeded { return }
            }
            let bsdtar = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard bsdtar.succeeded else {
                throw OpenTangerineError.toolFailed("rar", "Install `unar` (`brew install unar`) to extract RAR archives.")
            }
        default:
            throw OpenTangerineError.unsupportedConversion(format, .zip)
        }
    }

    func pack(_ directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        default:
            throw OpenTangerineError.unsupportedConversion(.zip, format)
        }
    }
}



// Open Tangerine / Engines/AudioEngine.swift
import AVFoundation
import Foundation

struct AudioEngine: ConversionEngine {
    static let nativeTargets: Set<FileFormat> = [.m4a, .wav, .aiff]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .audio && to.category == .audio
    }

    func convert(_ request: ConversionRequest) async throws {
        if Self.nativeTargets.contains(request.target), await MediaInfo.isNativelyReadable(request.source) {
            do {
                let asset = AVURLAsset(url: request.source)
                if request.target == .m4a {
                    try await AVExporter.export(asset: asset, to: request.destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, progress: request.progress)
                } else {
                    try await AVExporter.exportAudioPCM(asset: asset, to: request.destination, format: request.target, progress: request.progress)
                }
                return
            } catch {
                try Task.checkCancellation()
                guard FFmpeg.isAvailable else { throw error }
            }
        }
        try await Self.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
    }

    static func codecArguments(for target: FileFormat, bitrate: Int? = nil) -> [String] {
        switch target {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "\(bitrate ?? 192_000)"]
        case .m4a: return ["-c:a", "aac", "-b:a", "\(bitrate ?? 192_000)", "-movflags", "+faststart"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac: return ["-c:a", "flac"]
        case .ogg: return ["-c:a", "libvorbis", "-q:a", "5"]
        case .opus: return ["-c:a", "libopus", "-b:a", "\(bitrate ?? 128_000)"]
        case .wma: return ["-c:a", "wmav2", "-b:a", "\(bitrate ?? 192_000)"]
        default: return []
        }
    }

    static func resolvedCodecArguments(for target: FileFormat, bitrate: Int? = nil) async -> [String] {
        if target == .ogg {
            let encoders = await FFmpeg.availableEncoders()
            if !encoders.contains("libvorbis"), encoders.contains("libopus") {
                return ["-c:a", "libopus", "-b:a", "\(bitrate ?? 128_000)"]
            }
        }
        return codecArguments(for: target, bitrate: bitrate)
    }

    static func containerArguments(for target: FileFormat) -> [String] {
        switch target {
        case .m4a: return ["-f", "ipod"]
        case .ogg: return ["-f", "ogg"]
        case .opus: return ["-f", "opus"]
        case .wma: return ["-f", "asf"]
        case .aiff: return ["-f", "aiff"]
        case .wav: return ["-f", "wav"]
        case .mp3: return ["-f", "mp3"]
        case .flac: return ["-f", "flac"]
        default: return []
        }
    }

    static func ffmpegConvert(source: URL, destination: URL, target: FileFormat, extraFilters: [String] = [], bitrate: Int? = nil, progress: @escaping (Double) -> Void) async throws {
        let duration = await FFmpeg.probeDuration(source)
        var args = ["-i", source.path, "-vn", "-map_metadata", "0"]
        if !extraFilters.isEmpty { args += ["-af", extraFilters.joined(separator: ",")] }
        args += await resolvedCodecArguments(for: target, bitrate: bitrate)
        args += containerArguments(for: target)
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: "Converting to \(target.displayName)", duration: duration, progress: progress)
    }
}



// Open Tangerine / Engines/ConversionEngine.swift
import Foundation

struct ConversionRequest {
    let source: URL
    let sourceFormat: FileFormat
    let target: FileFormat
    let destination: URL
    let progress: (Double) -> Void
}

protocol ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool
    func convert(_ request: ConversionRequest) async throws
}

enum Engines {
    static let all: [ConversionEngine] = [
        ImageEngine(),
        AudioEngine(),
        VideoEngine(),
        DocumentEngine(),
        SubtitleEngine(),
        ArchiveEngine(),
    ]

    static func engine(from: FileFormat, to: FileFormat) -> ConversionEngine? {
        all.first { $0.supports(from: from, to: to) }
    }

    static func convert(_ request: ConversionRequest) async throws {
        guard let engine = engine(from: request.sourceFormat, to: request.target) else {
            DiagnosticLog.log("no engine for \(request.sourceFormat.rawValue) -> \(request.target.rawValue)")
            throw OpenTangerineError.unsupportedConversion(request.sourceFormat, request.target)
        }
        DiagnosticLog.log("engine \(type(of: engine)) \(request.sourceFormat.rawValue) -> \(request.target.rawValue) src=\(request.source.path)")
        let temp = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".opentangerine-\(UUID().uuidString).\(request.destination.pathExtension)")
        let staged = ConversionRequest(
            source: request.source,
            sourceFormat: request.sourceFormat,
            target: request.target,
            destination: temp,
            progress: request.progress
        )
        do {
            try await engine.convert(staged)
            try Task.checkCancellation()
            DiagnosticLog.log("engine finished, staged=\(temp.lastPathComponent)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory) {
                // moveItem refuses an existing destination; never delete another file.
                try FileManager.default.moveItem(at: temp, to: request.destination)
            } else {
                throw OpenTangerineError.encodeFailed(request.destination.lastPathComponent)
            }
        } catch {
            DiagnosticLog.log("engine threw: \(error)")
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}



// Open Tangerine / Engines/DocumentEngine.swift
import AppKit
import CoreText
import Foundation
import PDFKit

enum TextRenderer {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }

    static func paginate(_ text: String) -> [CFRange] {
        let attributed = attributed(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let box = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var ranges: [CFRange] = []
        var start = 0
        let length = attributed.length
        while start < length {
            let path = CGPath(rect: box, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            ranges.append(visible)
            start = visible.location + visible.length
        }
        if ranges.isEmpty { ranges.append(CFRange(location: 0, length: 0)) }
        return ranges
    }

    static func draw(_ text: String, range: CFRange, in context: CGContext, scale: CGFloat = 1) {
        let attributed = attributed(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let box = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        let path = CGPath(rect: box, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    static func writePDF(_ text: String, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw OpenTangerineError.encodeFailed(url.lastPathComponent) }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OpenTangerineError.encodeFailed(url.lastPathComponent) }
        for range in paginate(text) {
            context.beginPDFPage(nil)
            draw(text, range: range, in: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func renderWholeDocument(_ text: String, dpi: CGFloat = 150) throws -> CGImage {
        let ranges = paginate(text)
        let scale = dpi / 72
        let width = Int(pageSize.width * scale)
        let pageHeight = Int(pageSize.height * scale)
        let totalHeight = pageHeight * ranges.count
        try ImageIOBridge.validateDimensions(width: width, height: totalHeight)
        guard let context = CGContext(
            data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw OpenTangerineError.encodeFailed("image") }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        for (index, range) in ranges.enumerated() {
            context.saveGState()
            let offsetY = CGFloat(totalHeight - pageHeight * (index + 1))
            context.translateBy(x: 0, y: offsetY)
            draw(text, range: range, in: context, scale: scale)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw OpenTangerineError.encodeFailed("image") }
        return image
    }
}

enum PDFRenderer {
    static func writeImagesPDF(_ urls: [URL], pageSize: CGSize, margin: CGFloat = 36, to destination: URL, progress: @escaping (Double) -> Void) throws {
        guard !urls.isEmpty else { throw OpenTangerineError.invalidInput("No images to place in the PDF.") }
        guard let consumer = CGDataConsumer(url: destination as CFURL) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        for (index, url) in urls.enumerated() {
            let image = try ImageIOBridge.load(url)
            let available = mediaBox.insetBy(dx: margin, dy: margin)
            let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = CGRect(x: available.midX - drawn.width / 2, y: available.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
            context.beginPDFPage(nil)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.endPDFPage()
            progress(Double(index + 1) / Double(urls.count))
        }
        context.closePDF()
    }

    static func render(page: PDFPage, dpi: CGFloat = 300) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let rotation = page.rotation
        let rotated = rotation % 180 != 0
        let pixelWidth = ((rotated ? bounds.height : bounds.width) * scale).rounded()
        let pixelHeight = ((rotated ? bounds.width : bounds.height) * scale).rounded()
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
              pixelWidth * pixelHeight <= 40_000_000 else { return nil }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }

    static func thumbnail(page: PDFPage, maxSize: CGFloat) -> NSImage {
        page.thumbnail(of: CGSize(width: maxSize, height: maxSize), for: .mediaBox)
    }
}

struct DocumentEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        switch (from, to) {
        case (.pdf, .docx), (.pdf, .jpg), (.pdf, .png), (.pdf, .txt): return true
        case (.txt, .pdf), (.txt, .jpg), (.txt, .png), (.txt, .srt), (.txt, .vtt): return true
        default: return false
        }
    }

    func convert(_ request: ConversionRequest) async throws {
        switch request.sourceFormat {
        case .pdf: try await convertPDF(request)
        case .txt: try await convertText(request)
        default: throw OpenTangerineError.unsupportedConversion(request.sourceFormat, request.target)
        }
    }

    private func convertPDF(_ request: ConversionRequest) async throws {
        let document = try PDFOps.document(request.source)
        let pageCount = document.pageCount
        switch request.target {
        case .txt:
            var text = ""
            for index in 0..<pageCount {
                if let page = document.page(at: index), let content = page.string { text += content + "\n\n" }
                request.progress(Double(index + 1) / Double(pageCount))
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenTangerineError.invalidInput("This PDF has no selectable text. Scanned pages require OCR, which is not supported yet.")
            }
            try text.write(to: request.destination, atomically: true, encoding: .utf8)
        case .jpg, .png:
            if pageCount == 1, let page = document.page(at: 0) {
                guard let image = PDFRenderer.render(page: page) else { throw OpenTangerineError.encodeFailed(request.destination.lastPathComponent) }
                try ImageIOBridge.write(image, to: request.destination, format: request.target, quality: 0.92)
            } else {
                let folder = request.destination.deletingPathExtension()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let base = ConversionMatrix.strippedBaseName(request.source.lastPathComponent)
                for index in 0..<pageCount {
                    guard let page = document.page(at: index), let image = PDFRenderer.render(page: page) else { throw OpenTangerineError.encodeFailed("PDF page \(index + 1)") }
                    let pageURL = folder.appendingPathComponent("\(base) - page \(index + 1).\(request.target.fileExtension)")
                    try ImageIOBridge.write(image, to: pageURL, format: request.target, quality: 0.92)
                    request.progress(Double(index + 1) / Double(pageCount))
                }
                try? FileManager.default.removeItem(at: request.destination)
                try FileManager.default.moveItem(at: folder, to: request.destination)
            }
        case .docx:
            var blocks: [DocxWriter.Block] = []
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-pdfdocx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            for index in 0..<pageCount {
                guard let page = document.page(at: index) else { throw OpenTangerineError.encodeFailed("PDF page \(index + 1)") }
                if index > 0 { blocks.append(.pageBreak) }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    blocks += text.components(separatedBy: "\n").map { .paragraph($0.trimmingCharacters(in: .whitespaces)) }
                } else if let image = PDFRenderer.render(page: page, dpi: 150) {
                    let pageImage = temp.appendingPathComponent("page\(index + 1).png")
                    try ImageIOBridge.write(image, to: pageImage, format: .png)
                    blocks.append(.image(pageImage))
                }
                request.progress(Double(index + 1) / Double(pageCount) * 0.8)
            }
            try await DocxWriter.write(blocks: blocks, to: request.destination)
        default:
            throw OpenTangerineError.unsupportedConversion(.pdf, request.target)
        }
        request.progress(1)
    }

    private func convertText(_ request: ConversionRequest) async throws {
        let text = try TextFile.read(request.source)
        switch request.target {
        case .pdf:
            try TextRenderer.writePDF(text, to: request.destination)
        case .jpg, .png:
            let image = try TextRenderer.renderWholeDocument(text)
            try ImageIOBridge.write(image, to: request.destination, format: request.target, quality: 0.92)
        case .srt, .vtt:
            let cues = SubtitleParser.parse(text, hint: .txt)
            try SubtitleParser.serialize(cues, as: request.target).write(to: request.destination, atomically: true, encoding: .utf8)
        default:
            throw OpenTangerineError.unsupportedConversion(.txt, request.target)
        }
        request.progress(1)
    }
}

enum TextFile {
    static func read(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        throw OpenTangerineError.unreadable(url)
    }
}



// Open Tangerine / Engines/DocxWriter.swift
import Foundation
import ImageIO

enum ZipTool {
    static func zip(directory: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let result = try await Shell.run("/usr/bin/zip", ["-r", "-X", "-q", destination.path, "."], currentDirectory: directory)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
    }

    static func zipOrdered(directory: URL, entries: [String], to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        var args = ["-X", "-q", destination.path]
        args += entries
        let result = try await Shell.run("/usr/bin/zip", args, currentDirectory: directory)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
    }

    static func unzip(_ archive: URL, into directory: URL) async throws {
        let result = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        guard result.succeeded else { throw OpenTangerineError.toolFailed("ditto", result.stderr) }
    }
}

enum DocxWriter {
    enum Block { case paragraph(String), image(URL), pageBreak }

    static func write(paragraphs: [String], images: [URL], to destination: URL) async throws {
        try await write(blocks: paragraphs.map { .paragraph($0) } + images.map { .image($0) }, to: destination)
    }

    static func write(blocks: [Block], to destination: URL) async throws {
        let images = blocks.compactMap { block -> URL? in if case .image(let url) = block { return url }; return nil }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("opentangerine-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        var relationships = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        var body = ""
        var contentTypesExtra = ""
        var seenExtensions = Set<String>()
        var imageIndex = 0
        for block in blocks {
            switch block {
            case .paragraph(let paragraph):
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(escape(paragraph))</w:t></w:r></w:p>"
                continue
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                continue
            case .image: break
            }
            guard case .image(let image) = block else { continue }
            let index = imageIndex
            imageIndex += 1
            let ext = image.pathExtension.lowercased().isEmpty ? "png" : image.pathExtension.lowercased()
            let name = "image\(index + 1).\(ext)"
            try fm.copyItem(at: image, to: staging.appendingPathComponent("word/media/\(name)"))
            let rid = "rId\(index + 10)"
            relationships += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
            let size = ImageIOBridge.pixelSize(image)
            let maxWidthEMU = 5_943_600.0
            let maxHeightEMU = 8_229_600.0
            var widthEMU = max(size.width, 1) * 9525
            var heightEMU = max(size.height, 1) * 9525
            let scale = min(maxWidthEMU / widthEMU, maxHeightEMU / heightEMU, 1)
            widthEMU *= scale
            heightEMU *= scale
            body += drawing(rid: rid, id: index + 1, name: name, cx: Int(widthEMU), cy: Int(heightEMU))
            if !seenExtensions.contains(ext) {
                seenExtensions.insert(ext)
                let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext)"
                contentTypesExtra += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
            }
        }

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(contentTypesExtra)
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body>
        </w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        </w:styles>
        """

        try contentTypes.write(to: staging.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: staging.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try documentRels.write(to: staging.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try document.write(to: staging.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try styles.write(to: staging.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)

        var entries = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels"]
        for index in images.indices {
            let ext = images[index].pathExtension.lowercased().isEmpty ? "png" : images[index].pathExtension.lowercased()
            entries.append("word/media/image\(index + 1).\(ext)")
        }
        try await ZipTool.zipOrdered(directory: staging, entries: entries, to: destination)
    }

    private static func drawing(rid: String, id: Int, name: String, cx: Int, cy: Int) -> String {
        """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="\(name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}



// Open Tangerine / Engines/FFmpeg.swift
import Foundation

enum FFmpeg {
    static var path: String? {
        let configured = AppSettings.shared.ffmpegPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) { return configured }
        return Shell.which("ffmpeg")
    }

    static var probePath: String? {
        if let ffmpeg = path {
            let sibling = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return Shell.which("ffprobe")
    }

    static var isAvailable: Bool { path != nil }

    enum Health: Equatable {
        case missing
        case broken(path: String, reason: String)
        case ready(path: String, version: String)
    }

    static func checkHealth() async -> Health {
        guard let ffmpeg = path else { return .missing }
        do {
            let result = try await Shell.run(ffmpeg, ["-hide_banner", "-version"])
            let firstLine = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
            guard result.succeeded, firstLine.hasPrefix("ffmpeg version") else {
                return .broken(path: ffmpeg, reason: summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
            }
            let version = firstLine.replacingOccurrences(of: "ffmpeg version ", with: "")
                .split(separator: " ").first.map(String.init) ?? ""
            return .ready(path: ffmpeg, version: version)
        } catch {
            return .broken(path: ffmpeg, reason: error.localizedDescription)
        }
    }

    static func availableEncoders() async -> Set<String> {
        guard let executable = path,
              let result = try? await Shell.run(executable, ["-hide_banner", "-encoders"]), result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[0].count == 6,
                  ["V", "A", "S"].contains(String(fields[0].prefix(1))), fields[1] != "=" else { return nil }
            return String(fields[1])
        })
    }

    static func summarize(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let dyld = lines.first(where: { $0.contains("Library not loaded") }) {
            let library = dyld.components(separatedBy: "Library not loaded: ").last.map { ($0 as NSString).lastPathComponent } ?? ""
            return "missing library \(library). Reinstall ffmpeg and its dependencies (for example `brew reinstall ffmpeg`)."
        }
        if let cause = lines.first(where: { $0.contains("Unknown encoder") || $0.contains("Encoder not found") || $0.contains("Invalid data found") || $0.contains("Permission denied") }) { return cause }
        return lines.last(where: { !$0.hasPrefix("Referenced from") && !$0.hasPrefix("Reason:") }) ?? output
    }

    @discardableResult
    static func run(_ arguments: [String], purpose: String, duration: Double? = nil, progress: ((Double) -> Void)? = nil) async throws -> ShellResult {
        guard let ffmpeg = path else { throw OpenTangerineError.ffmpegMissing(purpose) }
        var args = ["-hide_banner", "-y", "-nostdin"]
        if progress != nil { args += ["-progress", "pipe:1", "-loglevel", "error"] }
        args += arguments
        let result: ShellResult
        if let progress, let duration, duration > 0 {
            result = try await runStreaming(ffmpeg, args, duration: duration, progress: progress)
        } else {
            result = try await Shell.run(ffmpeg, args)
        }
        guard result.succeeded else {
            throw OpenTangerineError.toolFailed("ffmpeg", summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return result
    }

    private static func runStreaming(_ executable: String, _ arguments: [String], duration: Double, progress: @escaping (Double) -> Void) async throws -> ShellResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = box.process
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let output = PipeBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output.set(stderr: errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    let handle = outPipe.fileHandleForReading
                    var buffer = ""
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer += String(decoding: chunk, as: UTF8.self)
                        while let range = buffer.range(of: "\n") {
                            let line = String(buffer[..<range.lowerBound])
                            buffer.removeSubrange(..<range.upperBound)
                            if line.hasPrefix("out_time_ms="), let ms = Double(line.dropFirst(12)) {
                                let fraction = min(1, max(0, ms / 1_000_000 / duration))
                                DispatchQueue.main.async { progress(fraction) }
                            }
                        }
                    }
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.wait()
                    continuation.resume(returning: output.result(status: proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    static func probeDuration(_ url: URL) async -> Double? {
        guard let probe = probePath else { return nil }
        let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        return result.flatMap { Double($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = clamped - Double(hours * 3600 + minutes * 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, secs)
    }
}



// Open Tangerine / Engines/ImageEngine.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageIOBridge {
    static let nativeEncoders: Set<String> = {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    static func canEncodeNatively(_ format: FileFormat) -> Bool {
        guard let type = format.utType else { return false }
        return nativeEncoders.contains(type.identifier)
    }

    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard url.isFileURL else { throw OpenTangerineError.invalidInput("Only local files are accepted.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 100_000_000 else {
            throw OpenTangerineError.invalidInput("Use a regular image file smaller than 100 MB.")
        }
        if FileFormat.detect(url) == .svg {
            return try rasterizeSVG(url, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw OpenTangerineError.unreadable(url) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        DiagnosticLog.log("image load \(url.lastPathComponent) type=\((CGImageSourceGetType(source) as String?) ?? "?") \(width)x\(height) max=\(maxPixelSize.map(String.init) ?? "none")")
        try validateDimensions(width: width, height: height)
        let longest = max(width, height, 1)
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize.map { min($0, longest) } ?? longest,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            DiagnosticLog.log("thumbnail decoded \(image.width)x\(image.height) alpha=\(image.alphaInfo.rawValue)")
            return image
        }
        options[kCGImageSourceCreateThumbnailWithTransform] = false
        DiagnosticLog.log("thumbnail failed, falling back to full decode")
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        if let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        throw OpenTangerineError.unreadable(url)
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw OpenTangerineError.invalidInput("Cannot read image dimensions. Re-export this image as PNG or JPEG and retry.")
        }
        guard Double(width) * Double(height) <= 40_000_000 else {
            throw OpenTangerineError.invalidInput("Image is \(width) × \(height) pixels; the limit is 40 megapixels. Resize it first, then retry.")
        }
    }

    static func rasterizeSVG(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let image = NSImage(contentsOf: url) else { throw OpenTangerineError.unreadable(url) }
        var size = image.size
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: 1024, height: 1024) }
        let target = CGFloat(maxPixelSize ?? 2048)
        let scale = target / max(size.width, size.height)
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw OpenTangerineError.unreadable(url) }
        rep.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { throw OpenTangerineError.unreadable(url) }
        return cg
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func pixelSize(_ url: URL) -> CGSize {
        let props = properties(url)
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if orientation >= 5 { return CGSize(width: height, height: width) }
        return CGSize(width: width, height: height)
    }

    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double = 0.9, metadata: [CFString: Any]? = nil, allowRasterFallback: Bool = true) throws {
        guard let type = format.utType, nativeEncoders.contains(type.identifier) else {
            throw OpenTangerineError.encodeFailed("\(format.displayName) natively")
        }
        DiagnosticLog.log("image write \(url.lastPathComponent) as \(type.identifier) quality=\(quality) metadata=\(metadata?.count ?? 0)")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OpenTangerineError.encodeFailed(url.lastPathComponent)
        }
        var options: [CFString: Any] = metadata ?? [:]
        if format == .jpg || format == .heic || format == .webp || format == .avif {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        var output = image
        if format == .jpg || format == .bmp, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            output = flatten(image, background: .white)
            DiagnosticLog.log("flattened alpha \(output.width)x\(output.height)")
        }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        DiagnosticLog.log("image added, finalizing")
        guard CGImageDestinationFinalize(destination) else {
            // Decoded AVIF/HEIC images can carry a pixel layout the PNG writer cannot consume.
            if allowRasterFallback, format != .heic,
               let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                if let raster = context.makeImage() {
                    try write(raster, to: url, format: format, quality: quality, metadata: metadata, allowRasterFallback: false)
                    return
                }
            }
            throw OpenTangerineError.encodeFailed(url.lastPathComponent)
        }
        DiagnosticLog.log("image finalized \(url.lastPathComponent)")
    }

    static func writeAnyFormat(_ image: CGImage, to url: URL, format: FileFormat, quality: Double = 0.9) async throws {
        if canEncodeNatively(format) {
            try write(image, to: url, format: format, quality: quality)
            return
        }
        if format == .webp, !(await FFmpeg.availableEncoders()).contains("libwebp") {
            try WebPLossless.write(image, to: url)
            return
        }
        DiagnosticLog.log("no native encoder for \(format.rawValue), using ffmpeg")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, to: temp, format: .png)
        try await encodeWithFFmpeg(png: temp, to: url, format: format, quality: quality)
    }

    static func encodeWithFFmpeg(png: URL, to url: URL, format: FileFormat, quality: Double) async throws {
        var args = ["-i", png.path, "-frames:v", "1"]
        switch format {
        case .webp:
            args += ["-c:v", "libwebp", "-quality", String(Int(quality * 100)), "-f", "webp"]
        case .avif:
            let crf = Int((1 - quality) * 50 + 10)
            let encoders = await FFmpeg.availableEncoders()
            if encoders.contains("libaom-av1") {
                args += ["-c:v", "libaom-av1", "-still-picture", "1"]
            } else if encoders.contains("libsvtav1") {
                args += ["-c:v", "libsvtav1", "-preset", "8"]
            } else {
                throw OpenTangerineError.invalidInput("AVIF needs an FFmpeg build with libaom-av1 or libsvtav1 encoding support.")
            }
            args += ["-crf", String(crf), "-b:v", "0", "-pix_fmt", "yuv420p", "-f", "avif"]
        case .heic:
            throw OpenTangerineError.invalidInput("HEIC requires the native macOS encoder.")
        case .bmp:
            args += ["-f", "image2", "-c:v", "bmp"]
        case .tiff:
            args += ["-f", "image2", "-c:v", "tiff"]
        case .jpg:
            args += ["-f", "image2", "-c:v", "mjpeg", "-q:v", String(Int((1 - quality) * 30 + 2))]
        default:
            throw OpenTangerineError.unsupportedConversion(.png, format)
        }
        args.append(url.path)
        try await FFmpeg.run(args, purpose: "Encoding \(format.displayName)")
    }

    static func flatten(_ image: CGImage, background: NSColor) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func resized(_ image: CGImage, longEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longEdge > 0, longest > longEdge else { return image }
        let scale = CGFloat(longEdge) / CGFloat(longest)
        return scaled(image, to: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage {
        let bounded = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: bounded) ?? image
    }

    static func writePDF(images: [CGImage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw OpenTangerineError.encodeFailed(url.lastPathComponent) }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OpenTangerineError.encodeFailed(url.lastPathComponent) }
        for image in images {
            let pointsWidth = CGFloat(image.width) * 72 / 150
            let pointsHeight = CGFloat(image.height) * 72 / 150
            var box = CGRect(x: 0, y: 0, width: pointsWidth, height: pointsHeight)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

struct ImageEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .image else { return false }
        return to.category == .image || to == .pdf || to == .docx
    }

    func convert(_ request: ConversionRequest) async throws {
        let image = try ImageIOBridge.load(request.source)
        request.progress(0.3)
        switch request.target {
        case .pdf:
            try ImageIOBridge.writePDF(images: [image], to: request.destination)
        case .docx:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ImageIOBridge.write(image, to: temp, format: .png)
            try await DocxWriter.write(paragraphs: [], images: [temp], to: request.destination)
        default:
            let quality = AppSettings.shared.jpegQuality
            try await ImageIOBridge.writeAnyFormat(image, to: request.destination, format: request.target, quality: quality)
        }
        request.progress(1)
    }
}



// Open Tangerine / Engines/SubtitleEngine.swift
import Foundation

struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleParser {
    static func parse(_ text: String, hint: FileFormat) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if hint == .vtt || lines.first?.hasPrefix("WEBVTT") == true {
            lines = Array(lines.drop { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("-->") }.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        var cues: [SubtitleCue] = []
        var index = 0
        var sawTimecode = false
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                sawTimecode = true
                let parts = line.components(separatedBy: "-->")
                let start = parseTimestamp(parts[0])
                let endToken = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" : ""
                let end = parseTimestamp(endToken)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(lines[index])
                    index += 1
                }
                if let start, let end, end >= start {
                    cues.append(SubtitleCue(start: start, end: end, text: body.joined(separator: "\n")))
                }
            } else {
                index += 1
            }
        }
        if !sawTimecode {
            return plainTextCues(normalized)
        }
        return cues
    }

    static func plainTextCues(_ text: String) -> [SubtitleCue] {
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let source = blocks.isEmpty ? text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : blocks
        var cues: [SubtitleCue] = []
        var clock = 0.0
        for block in source {
            let words = block.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            let duration = max(1.5, min(8, Double(words) * 0.35))
            cues.append(SubtitleCue(start: clock, end: clock + duration, text: block))
            clock += duration
        }
        return cues
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func format(_ seconds: Double, separator: String) -> String {
        let clamped = seconds.isFinite ? min(max(0, seconds), 315_360_000) : 0
        let totalMillis = Int((clamped * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis / 60_000) % 60
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d\(separator)%03d", hours, minutes, secs, min(millis, 999))
    }

    static func serialize(_ cues: [SubtitleCue], as format: FileFormat) -> String {
        switch format {
        case .vtt:
            var output = "WEBVTT\n\n"
            for cue in cues {
                output += "\(SubtitleParser.format(cue.start, separator: ".")) --> \(SubtitleParser.format(cue.end, separator: "."))\n\(cue.text)\n\n"
            }
            return output
        case .srt:
            var output = ""
            for (index, cue) in cues.enumerated() {
                output += "\(index + 1)\n\(SubtitleParser.format(cue.start, separator: ",")) --> \(SubtitleParser.format(cue.end, separator: ","))\n\(cue.text)\n\n"
            }
            return output
        default:
            return cues.map { stripTags($0.text) }.joined(separator: "\n\n") + "\n"
        }
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }
}

struct SubtitleEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .subtitle && (to.category == .subtitle || to == .txt)
    }

    func convert(_ request: ConversionRequest) async throws {
        let text = try TextFile.read(request.source)
        let cues = SubtitleParser.parse(text, hint: request.sourceFormat)
        guard !cues.isEmpty else { throw OpenTangerineError.invalidInput("No valid subtitle cues were found.") }
        let output = SubtitleParser.serialize(cues, as: request.target)
        try output.write(to: request.destination, atomically: true, encoding: .utf8)
        request.progress(1)
    }
}



// Open Tangerine / Engines/VideoEngine.swift
import AVFoundation
import Foundation

struct VideoEngine: ConversionEngine {
    static let nativeTargets: Set<FileFormat> = [.mp4, .mov]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .video else { return false }
        return to.category == .video || to == .mp3
    }

    func convert(_ request: ConversionRequest) async throws {
        if Self.nativeTargets.contains(request.target), request.sourceFormat != .gif, await MediaInfo.isNativelyReadable(request.source) {
            do {
                let asset = AVURLAsset(url: request.source)
                try await AVExporter.export(asset: asset, to: request.destination, format: request.target, preset: AVAssetExportPresetHighestQuality, progress: request.progress)
                return
            } catch {
                try Task.checkCancellation()
                guard FFmpeg.isAvailable else { throw error }
            }
        }
        if request.target == .mp3 {
            try await AudioEngine.ffmpegConvert(source: request.source, destination: request.destination, target: .mp3, progress: request.progress)
            return
        }
        try await Self.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
    }

    static func codecArguments(for target: FileFormat, videoBitrate: Int? = nil, audioBitrate: Int? = nil) -> [String] {
        var args: [String] = []
        switch target {
        case .mp4:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", "-f", "mp4"]
        case .mov:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "mov"]
        case .mkv:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "matroska"]
        case .webm:
            args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1", "-c:a", "libopus", "-f", "webm"]
        case .avi:
            args += ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4", "-c:a", "libmp3lame", "-f", "avi"]
        case .wmv:
            args += ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2", "-f", "asf"]
        default:
            break
        }
        if let videoBitrate, target != .webm, target != .avi, target != .wmv {
            args += ["-b:v", "\(videoBitrate)", "-maxrate", "\(Int(Double(videoBitrate) * 1.4))", "-bufsize", "\(videoBitrate * 2)"]
        } else if target == .mp4 || target == .mov || target == .mkv {
            args += ["-crf", "20"]
        }
        if let audioBitrate, target != .avi, target != .wmv { args += ["-b:a", "\(audioBitrate)"] }
        return args
    }

    static func ffmpegConvert(source: URL, destination: URL, target: FileFormat, videoFilters: [String] = [], videoBitrate: Int? = nil, audioBitrate: Int? = nil, progress: @escaping (Double) -> Void) async throws {
        let duration = await FFmpeg.probeDuration(source)
        if target == .gif {
            let filters = videoFilters + ["fps=12", "scale='min(640,iw)':-2:flags=lanczos", "split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"]
            let args = ["-i", source.path, "-vf", filters.joined(separator: ","), "-loop", "0", "-f", "gif", destination.path]
            try await FFmpeg.run(args, purpose: "Creating GIF", duration: duration, progress: progress)
            return
        }
        var args = ["-i", source.path, "-map_metadata", "0"]
        var filters = videoFilters
        if target == .mp4 || target == .mov || target == .mkv || target == .webm {
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += codecArguments(for: target, videoBitrate: videoBitrate, audioBitrate: audioBitrate)
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: "Converting to \(target.displayName)", duration: duration, progress: progress)
    }
}



// Open Tangerine / Engines/WebPLossless.swift
import Foundation
import CoreGraphics

/// Minimal literal-only VP8L writer. Fallback when ImageIO/FFmpeg cannot encode WebP.
/// Writes 8-bit sRGB pixels (premultiplication may round colors); intentionally trades compression ratio for no dependencies.
/// Format: https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification
enum WebPLossless {
    private struct Bits {
        var data = Data()
        var pending: UInt64 = 0
        var count = 0
        mutating func put(_ value: Int, _ width: Int) {
            pending |= UInt64(value) << count
            count += width
            while count >= 8 {
                data.append(UInt8(pending & 255)); pending >>= 8; count -= 8
            }
        }
        mutating func finish() { if count > 0 { data.append(UInt8(pending & 255)); count = 0 } }
        mutating func literalTree(_ alphabet: Int) {
            put(0, 1); put(8, 4) // normal tree, twelve code-length symbols
            for symbol in [17,18,0,1,2,3,4,5,16,6,7,8] { put(symbol == 0 || symbol == 8 ? 1 : 0, 3) }
            put(0, 1) // full alphabet
            for index in 0..<alphabet { put(index < 256 ? 1 : 0, 1) }
        }
    }
    static func write(_ image: CGImage, to url: URL) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 40_000_000 else {
            throw OpenTangerineError.invalidInput("WebP requires dimensions up to 16,384 pixels and at most 40 megapixels.")
        }
        guard w * h * 4 + 180 <= 100_000_000 else {
            throw OpenTangerineError.invalidInput("This image needs a compressed WebP encoder to stay within the 100 MB file limit. Use an FFmpeg build with libwebp, or resize the image below 25 megapixels.")
        }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let memory = context.data else { throw OpenTangerineError.encodeFailed("WebP pixel buffer") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = memory.assumingMemoryBound(to: UInt8.self)
        var bits = Bits()
        bits.data.reserveCapacity(w * h * 4 + 180)
        bits.put(0x2f, 8); bits.put(w - 1, 14); bits.put(h - 1, 14); bits.put(1, 1); bits.put(0, 3)
        bits.put(0, 1); bits.put(0, 1); bits.put(0, 1) // no transform, cache, or meta image
        bits.literalTree(280)
        for _ in 0..<3 { bits.literalTree(256) }
        bits.put(1, 1); bits.put(0, 1); bits.put(0, 1); bits.put(0, 1) // single distance symbol
        let reversed = (0..<256).map { value -> Int in
            var n = value, r = 0
            for _ in 0..<8 { r = (r << 1) | (n & 1); n >>= 1 }
            return r
        }
        for i in 0..<(w * h) {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let alpha = Int(pixels[i * 4 + 3])
            for channel in [1, 0, 2] {
                let value = alpha == 0 ? 0 : min(255, (Int(pixels[i * 4 + channel]) * 255 + alpha / 2) / alpha)
                bits.put(reversed[value], 8)
            }
            bits.put(reversed[alpha], 8)
        }
        bits.finish()
        var result = Data("RIFF".utf8)
        func append32(_ n: Int) { for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8((n >> shift) & 255)) } }
        append32(12 + bits.data.count + (bits.data.count & 1))
        result.append(Data("WEBPVP8L".utf8)); append32(bits.data.count); result.append(bits.data)
        if bits.data.count & 1 != 0 { result.append(0) }
        try result.write(to: url, options: .atomic)
    }
}


// Open Tangerine / Operations/AudioOps.swift
import AVFoundation
import Foundation

struct LoudnessStats {
    var integrated: Double
    var truePeak: Double
    var range: Double
}

enum AudioOps {
    static func outputFormat(for url: URL) -> FileFormat {
        let format = FileFormat.detect(url) ?? .m4a
        if AudioEngine.nativeTargets.contains(format) || FFmpeg.isAvailable { return format }
        return .m4a
    }

    static func trim(_ url: URL, start: Double, end: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let range = AVExporter.timeRange(start: start, end: end)
        if !FFmpeg.isAvailable, AudioEngine.nativeTargets.contains(format), await MediaInfo.isNativelyReadable(url) {
            let asset = AVURLAsset(url: url)
            if format == .m4a {
                try await AVExporter.export(asset: asset, to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, timeRange: range, progress: progress)
            } else {
                try await AVExporter.exportAudioPCM(asset: asset, to: destination, format: format, timeRange: range, progress: progress)
            }
            return
        }
        var args = ["-ss", FFmpeg.timecode(start), "-to", FFmpeg.timecode(end), "-i", url.path, "-vn"]
        args += await AudioEngine.resolvedCodecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
        try await FFmpeg.run(args, purpose: "Trimming audio", duration: end - start, progress: progress)
    }

    static func detectSilence(_ url: URL, threshold: Float = 0.01) async -> (leading: Double, trailing: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var first = -1
        var last = -1
        for frame in 0..<count {
            var peak: Float = 0
            for c in 0..<channelCount { peak = max(peak, abs(channels[c][frame])) }
            if peak > threshold {
                if first < 0 { first = frame }
                last = frame
            }
        }
        guard first >= 0 else { return nil }
        let rate = format.sampleRate
        return (Double(first) / rate, Double(last + 1) / rate)
    }

    static func waveform(_ url: URL, buckets: Int) async -> [Float] {
        guard buckets > 0 else { return [] }
        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            if frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount), (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                let per = max(1, count / buckets)
                var result: [Float] = []
                result.reserveCapacity(buckets)
                for b in 0..<buckets {
                    let start = b * per
                    let end = min(count, start + per)
                    guard start < end else { result.append(0); continue }
                    var peak: Float = 0
                    var frame = start
                    while frame < end {
                        for c in 0..<Int(format.channelCount) { peak = max(peak, abs(channels[c][frame])) }
                        frame += max(1, per / 64)
                    }
                    result.append(peak)
                }
                return result
            }
        }
        guard FFmpeg.isAvailable else { return [] }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-wave-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await FFmpeg.run(["-i", url.path, "-ac", "1", "-ar", "8000", "-c:a", "pcm_s16le", temp.path], purpose: "Waveform")
        } catch { return [] }
        guard FileManager.default.fileExists(atPath: temp.path) else { return [] }
        return await waveformFromFile(temp, buckets: buckets)
    }

    private static func waveformFromFile(_ url: URL, buckets: Int) async -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount), (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        let per = max(1, count / buckets)
        return (0..<buckets).map { b in
            let start = b * per, end = min(count, start + per)
            guard start < end else { return 0 }
            var peak: Float = 0
            for frame in stride(from: start, to: end, by: max(1, per / 64)) { peak = max(peak, abs(channels[0][frame])) }
            return peak
        }
    }

    static func measureLoudness(_ url: URL) async -> LoudnessStats? {
        guard FFmpeg.isAvailable else { return nil }
        let result = try? await FFmpeg.run(["-i", url.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"], purpose: "Measuring loudness")
        guard let text = result?.stderr, let start = text.range(of: "{"), let end = text.range(of: "}", options: .backwards) else { return nil }
        let json = String(text[start.lowerBound...end.lowerBound])
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return LoudnessStats(
            integrated: Double(object["input_i"] ?? "") ?? -23,
            truePeak: Double(object["input_tp"] ?? "") ?? -2,
            range: Double(object["input_lra"] ?? "") ?? 7
        )
    }

    static func normalize(_ url: URL, targetLUFS: Double, range: Double, truePeak: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        if FFmpeg.isAvailable {
            let duration = await FFmpeg.probeDuration(url)
            let filter = "loudnorm=I=\(targetLUFS):LRA=\(range):TP=\(truePeak)"
            var args = ["-i", url.path, "-vn", "-af", filter]
            args += await AudioEngine.resolvedCodecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
            try await FFmpeg.run(args, purpose: "Normalizing", duration: duration, progress: progress)
            return
        }
        let peak = await peakAmplitude(url) ?? 1
        let targetLinear = pow(10, truePeak / 20)
        let gain = Float(min(4, max(0.1, targetLinear / max(Double(peak), 0.0001))))
        try await applyGain(url, left: gain, right: gain, to: destination, format: format, progress: progress)
    }

    static func peakAmplitude(_ url: URL) async -> Float? {
        let samples = await waveform(url, buckets: 2048)
        return samples.max()
    }

    static func applyGain(_ url: URL, left: Float, right: Float, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw OpenTangerineError.invalidInput("No audio track found.") }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume((left + right) / 2, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        if format == .m4a {
            try await AVExporter.export(asset: asset, to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, audioMix: mix, progress: progress)
        } else {
            try await AVExporter.exportAudioPCM(asset: asset, to: destination, format: AudioEngine.nativeTargets.contains(format) ? format : .wav, audioMix: mix, progress: progress)
        }
    }

    enum ChannelMode: String, CaseIterable, Identifiable {
        case stereo, mono, leftOnly, rightOnly, swap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .stereo: return "Stereo"
            case .mono: return "Mono (mix down)"
            case .leftOnly: return "Left channel to both"
            case .rightOnly: return "Right channel to both"
            case .swap: return "Swap left and right"
            }
        }
    }

    static func convertChannels(_ url: URL, mode: ChannelMode, leftGain: Double, rightGain: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        guard FFmpeg.isAvailable else {
            throw OpenTangerineError.ffmpegMissing("Channel conversion")
        }
        let pan: String
        switch mode {
        case .stereo: pan = "pan=stereo|c0=\(leftGain)*c0|c1=\(rightGain)*c1"
        case .mono: pan = "pan=mono|c0=\(leftGain * 0.5)*c0+\(rightGain * 0.5)*c1"
        case .leftOnly: pan = "pan=stereo|c0=\(leftGain)*c0|c1=\(leftGain)*c0"
        case .rightOnly: pan = "pan=stereo|c0=\(rightGain)*c1|c1=\(rightGain)*c1"
        case .swap: pan = "pan=stereo|c0=\(rightGain)*c1|c1=\(leftGain)*c0"
        }
        let duration = await FFmpeg.probeDuration(url)
        var args = ["-i", url.path, "-vn", "-af", "aformat=channel_layouts=stereo," + pan]
        args += await AudioEngine.resolvedCodecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
        try await FFmpeg.run(args, purpose: "Converting channels", duration: duration, progress: progress)
    }

    struct BleepRange: Identifiable, Equatable {
        let id = UUID()
        var start: Double
        var end: Double
    }

    static func bleep(_ url: URL, ranges: [BleepRange], frequency: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { throw OpenTangerineError.invalidInput("Add at least one bleep range.") }
        if FFmpeg.isAvailable {
            let duration = await FFmpeg.probeDuration(url)
            let mute = sorted.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
            let toneEnable = sorted.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
            let filter = "[0:a]volume=enable='\(mute)':volume=0[muted];sine=frequency=\(Int(frequency)):sample_rate=48000,volume=0.5,volume=enable='not(\(toneEnable))':volume=0[tone];[muted][tone]amix=inputs=2:duration=first:dropout_transition=0,volume=2[out]"
            var args = ["-i", url.path, "-filter_complex", filter, "-map", "[out]"]
            args += await AudioEngine.resolvedCodecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
            try await FFmpeg.run(args, purpose: "Bleeping audio", duration: duration, progress: progress)
            return
        }
        throw OpenTangerineError.ffmpegMissing("Bleep tone generation")
    }

    enum VisualizerStyle: String, CaseIterable, Identifiable {
        case waveform, bars, stillImage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .waveform: return "Animated waveform"
            case .bars: return "Frequency bars"
            case .stillImage: return "Still image"
            }
        }
    }

    enum VisualizerOrientation: String, CaseIterable, Identifiable {
        case landscape, portrait, square
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var size: CGSize {
            switch self {
            case .landscape: return CGSize(width: 1920, height: 1080)
            case .portrait: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1080)
            }
        }
    }

    static func visualize(_ url: URL, style: VisualizerStyle, orientation: VisualizerOrientation, accent: String, background: String, image: URL?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let size = orientation.size
        let w = Int(size.width), h = Int(size.height)
        let duration = await FFmpeg.probeDuration(url)
        var args: [String] = ["-i", url.path]
        let filter: String
        switch style {
        case .waveform:
            filter = "[0:a]showwaves=s=\(w)x\(h / 3):mode=cline:colors=\(accent):rate=30[w];color=c=\(background):s=\(w)x\(h):r=30[bg];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .bars:
            filter = "[0:a]showfreqs=s=\(w)x\(h / 2):mode=bar:colors=\(accent):fscale=log:ascale=sqrt:win_size=2048:rate=30[w];color=c=\(background):s=\(w)x\(h):r=30[bg];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .stillImage:
            guard let image else { throw OpenTangerineError.invalidInput("Choose an image for the still-image visualizer.") }
            args += ["-loop", "1", "-framerate", "30", "-i", image.path]
            filter = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=\(background),format=yuv420p[v]"
        }
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", destination.path]
        try await FFmpeg.run(args, purpose: "Creating visualizer", duration: duration, progress: progress)
    }
}



// Open Tangerine / Operations/Compressor.swift
import AVFoundation
import Foundation

enum Compressor {
    static func compress(_ url: URL, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw OpenTangerineError.unreadable(url) }
        switch format.category {
        case .image:
            try await compressImage(url, format: format, preset: preset, resizeLongEdge: resizeLongEdge, targetBytes: targetBytes, to: destination, progress: progress)
        case .video:
            try await VideoOps.compress(url, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .audio:
            try await compressAudio(url, format: format, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .document where format == .pdf:
            try PDFOps.compress(url, strong: preset == .strong, to: destination)
            progress(1)
        default:
            throw OpenTangerineError.invalidInput("\(format.displayName) files can't be compressed. Convert to ZIP instead.")
        }
    }

    static func outputFormat(for url: URL) -> FileFormat {
        guard let format = FileFormat.detect(url) else { return .jpg }
        switch format.category {
        case .image:
            switch format {
            case .png:
                if let image = try? ImageIOBridge.load(url), image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst { return .png }
                return .jpg
            case .bmp, .tiff, .svg: return .jpg
            case .avif, .webp: return ImageIOBridge.canEncodeNatively(format) || FFmpeg.isAvailable ? format : .jpg
            default: return format
            }
        case .video:
            return VideoEngine.nativeTargets.contains(format) ? format : .mp4
        case .audio:
            return format == .mp3 && FFmpeg.isAvailable ? .mp3 : .m4a
        default:
            return format
        }
    }

    static func compressImage(_ url: URL, format: FileFormat, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var image = try ImageIOBridge.load(url)
        if resizeLongEdge > 0 { image = ImageIOBridge.resized(image, longEdge: resizeLongEdge) }
        let output = outputFormat(for: url)
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst
        let finalFormat: FileFormat = (output == .jpg && hasAlpha && format == .png) ? .png : output
        progress(0.2)

        guard let targetBytes else {
            if finalFormat == .png {
                let scaled = preset == .strong ? ImageIOBridge.resized(image, longEdge: Int(Double(max(image.width, image.height)) * 0.7)) : image
                try ImageIOBridge.write(scaled, to: destination, format: .png)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: finalFormat, quality: preset.imageQuality)
            }
            progress(1)
            return
        }

        guard targetBytes > 0 else { throw OpenTangerineError.invalidInput("Target size must be greater than zero.") }
        if finalFormat == .png {
            var candidate = image
            for attempt in 0..<12 {
                try ImageIOBridge.write(candidate, to: destination, format: .png)
                if FileSizeFormatter.size(of: destination) <= targetBytes { progress(1); return }
                guard candidate.width > 1 && candidate.height > 1 else { break }
                candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: max(1, Double(candidate.width) * 0.8), height: max(1, Double(candidate.height) * 0.8)))
                progress(0.2 + 0.7 * Double(attempt + 1) / 12)
            }
            throw OpenTangerineError.invalidInput("The requested size is too small while preserving PNG transparency. Choose a larger target size.")
        }
        var low = 0.15, high = 0.95
        var candidate = image
        var attempts = 0
        var best: Double?
        while attempts < 12 {
            attempts += 1
            let quality = (low + high) / 2
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: quality)
            let size = FileSizeFormatter.size(of: destination)
            progress(0.2 + 0.7 * Double(attempts) / 12)
            if size <= targetBytes {
                best = quality
                low = quality
                if Double(size) > Double(targetBytes) * 0.9 { break }
            } else {
                high = quality
            }
            if high - low < 0.03 {
                if best == nil {
                    let shrink = 0.8
                    candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: Double(candidate.width) * shrink, height: Double(candidate.height) * shrink))
                    low = 0.15
                    high = 0.95
                    guard candidate.width > 64 else { break }
                } else {
                    break
                }
            }
        }
        if let best {
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: best)
        }
        progress(1)
    }

    static func compressAudio(_ url: URL, format: FileFormat, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        var bitrate = preset.audioBitrate
        if let targetBytes, info.duration > 0 {
            bitrate = max(32_000, min(320_000, Int(Double(targetBytes) * 8 * 0.96 / info.duration)))
        }
        let output = outputFormat(for: url)
        if output == .m4a, !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) {
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, progress: progress)
            return
        }
        try await AudioEngine.ffmpegConvert(source: url, destination: destination, target: output, bitrate: bitrate, progress: progress)
    }
}



// Open Tangerine / Operations/ImageOps.swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct PhotoAdjustments: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var highlights: Double = 1
    var shadows: Double = 0
    var saturation: Double = 1
    var vibrance: Double = 0
    var temperature: Double = 6500
    var tint: Double = 0
    var sharpness: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var noiseReduction: Double = 0
    var grain: Double = 0
    var vignette: Double = 0
    var sepia: Double = 0
    var monochrome: Bool = false

    static let neutral = PhotoAdjustments()
}

enum RedactionStyle: String, CaseIterable, Identifiable {
    case solid
    case blur
    case pixelate

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Redaction: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    var style: RedactionStyle = .solid
    var color: CGColor = CGColor(gray: 0, alpha: 1)
    var start: Double = 0
    var end: Double = .infinity

    static func == (lhs: Redaction, rhs: Redaction) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.style == rhs.style && lhs.start == rhs.start && lhs.end == rhs.end
    }
}

enum ImageOps {
    static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    private static let softwareContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    static func ciImage(_ image: CGImage) -> CIImage { CIImage(cgImage: image) }

    static func render(_ image: CIImage, extent: CGRect? = nil) -> CGImage? {
        let rect = extent ?? image.extent
        guard !rect.isInfinite, !rect.isEmpty else { return nil }
        return context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            ?? softwareContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func adjusted(_ input: CIImage, _ a: PhotoAdjustments) -> CIImage {
        var image = input
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(a.exposure); image = f.outputImage ?? image
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = image
            f.brightness = Float(a.brightness); f.contrast = Float(a.contrast); f.saturation = Float(a.saturation)
            image = f.outputImage ?? image
        }
        if a.highlights != 1 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = image
            f.highlightAmount = Float(a.highlights); f.shadowAmount = Float(a.shadows); f.radius = 8
            image = f.outputImage ?? image
        }
        if a.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = image; f.amount = Float(a.vibrance); image = f.outputImage ?? image
        }
        if a.temperature != 6500 || a.tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(a.temperature), y: CGFloat(a.tint))
            image = f.outputImage ?? image
        }
        if a.dehaze != 0 {
            let contrast = CIFilter.colorControls(); contrast.inputImage = image
            contrast.contrast = Float(1 + a.dehaze * 0.35); contrast.saturation = Float(1 + a.dehaze * 0.2); contrast.brightness = Float(-a.dehaze * 0.05)
            let boosted = contrast.outputImage ?? image
            let curve = CIFilter.toneCurve(); curve.inputImage = boosted
            let k = CGFloat(a.dehaze) * 0.12
            curve.point0 = CGPoint(x: 0, y: 0); curve.point1 = CGPoint(x: 0.25, y: max(0, 0.25 - k)); curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: min(1, 0.75 + k * 0.5)); curve.point4 = CGPoint(x: 1, y: 1)
            image = curve.outputImage ?? boosted
        }
        if a.noiseReduction != 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = image
            f.noiseLevel = Float(a.noiseReduction * 0.1); f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if a.clarity != 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = image
            f.radius = 40; f.intensity = Float(a.clarity * 0.8)
            image = f.outputImage ?? image
        }
        if a.sharpness != 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = image; f.sharpness = Float(a.sharpness); image = f.outputImage ?? image
        }
        if a.sepia != 0 {
            let f = CIFilter.sepiaTone(); f.inputImage = image; f.intensity = Float(a.sepia); image = f.outputImage ?? image
        }
        if a.monochrome {
            let f = CIFilter.photoEffectMono(); f.inputImage = image; image = f.outputImage ?? image
        }
        if a.vignette != 0 {
            let f = CIFilter.vignette(); f.inputImage = image; f.intensity = Float(a.vignette * 2); f.radius = Float(min(input.extent.width, input.extent.height) / 2); image = f.outputImage ?? image
        }
        if a.grain != 0 {
            let noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
            let matrix = CIFilter.colorMatrix(); matrix.inputImage = noise
            let amount = CGFloat(a.grain) * 0.35
            matrix.rVector = CIVector(x: 0, y: amount, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: amount, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: amount, z: 0, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            matrix.biasVector = CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 1)
            let grain = (matrix.outputImage ?? noise).cropped(to: input.extent)
            let blend = CIFilter.softLightBlendMode(); blend.inputImage = grain; blend.backgroundImage = image
            image = (blend.outputImage ?? image).cropped(to: input.extent)
        }
        return image.cropped(to: input.extent)
    }

    static func redact(_ input: CIImage, redactions: [Redaction], flipped: Bool = true) -> CIImage {
        var image = input
        let extent = input.extent
        for redaction in redactions {
            var rect = redaction.rect.intersection(extent)
            if flipped {
                rect = CGRect(x: rect.minX, y: extent.maxY - rect.maxY, width: rect.width, height: rect.height)
            }
            guard !rect.isEmpty else { continue }
            let patch: CIImage
            switch redaction.style {
            case .solid:
                patch = CIImage(color: CIColor(cgColor: redaction.color)).cropped(to: rect)
            case .blur:
                let blur = CIFilter.gaussianBlur(); blur.inputImage = image.clampedToExtent(); blur.radius = Float(max(12, min(rect.width, rect.height) / 8))
                patch = (blur.outputImage ?? image).cropped(to: rect)
            case .pixelate:
                let pixel = CIFilter.pixellate(); pixel.inputImage = image.clampedToExtent(); pixel.scale = Float(max(12, min(rect.width, rect.height) / 8))
                pixel.center = CGPoint(x: rect.midX, y: rect.midY)
                patch = (pixel.outputImage ?? image).cropped(to: rect)
            }
            image = patch.composited(over: image)
        }
        return image.cropped(to: extent)
    }

    static func rotated(_ image: CGImage, quarterTurns: Int, flipHorizontal: Bool, flipVertical: Bool) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        }
        if flipHorizontal { ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if flipVertical { ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)) }
        let extent = ci.extent
        ci = ci.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if let result = render(ci) { return result }
        // Quarter turns and flips need no GPU. Preserve exact pixels with a bitmap transform.
        var transform = CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)
        if flipHorizontal { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if flipVertical { transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OpenTangerineError.encodeFailed("Could not allocate the rotated image.")
        }
        bitmap.interpolationQuality = .none
        bitmap.setShouldAntialias(false)
        bitmap.concatenate(transform)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = bitmap.makeImage() else { throw OpenTangerineError.encodeFailed("Could not render the rotated image.") }
        return result
    }

    enum Background {
        case color(NSColor)
        case gradient(NSColor, NSColor, angle: CGFloat)
        case image(CGImage, blur: CGFloat)
    }

    struct FrameOptions {
        var aspect: CGSize? = nil
        var padding: CGFloat = 0.08
        var cornerRadius: CGFloat = 24
        var shadow: CGFloat = 24
        var background: Background = .color(.white)
    }

    static func framed(_ image: CGImage, options: FrameOptions) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        var canvas = imageSize
        if let aspect = options.aspect, aspect.width > 0, aspect.height > 0 {
            let ratio = aspect.width / aspect.height
            if imageSize.width / imageSize.height > ratio {
                canvas = CGSize(width: imageSize.width, height: imageSize.width / ratio)
            } else {
                canvas = CGSize(width: imageSize.height * ratio, height: imageSize.height)
            }
        }
        let pad = options.padding * min(canvas.width, canvas.height)
        if let aspect = options.aspect, aspect.width > 0, aspect.height > 0 {
            // Expand uniformly so padding never changes the chosen output ratio.
            let factor = max((canvas.width + pad * 2) / canvas.width, (canvas.height + pad * 2) / canvas.height)
            canvas = CGSize(width: canvas.width * factor, height: canvas.height * factor)
        } else {
            canvas = CGSize(width: canvas.width + pad * 2, height: canvas.height + pad * 2)
        }
        let scale = min((canvas.width - pad * 2) / imageSize.width, (canvas.height - pad * 2) / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2)

        guard let ctx = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let full = CGRect(origin: .zero, size: canvas)
        switch options.background {
        case .color(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(full)
        case .gradient(let a, let b, let angle):
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            let radians = angle * .pi / 180
            let dx = cos(radians) * canvas.width / 2
            let dy = sin(radians) * canvas.height / 2
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx, y: center.y - dy), end: CGPoint(x: center.x + dx, y: center.y + dy), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image(let bg, let blur):
            var ci = CIImage(cgImage: bg)
            let bgScale = max(canvas.width / ci.extent.width, canvas.height / ci.extent.height)
            ci = ci.transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
            ci = ci.transformed(by: CGAffineTransform(translationX: (canvas.width - ci.extent.width) / 2 - ci.extent.minX, y: (canvas.height - ci.extent.height) / 2 - ci.extent.minY))
            if blur > 0 {
                let f = CIFilter.gaussianBlur(); f.inputImage = ci.clampedToExtent(); f.radius = Float(blur)
                ci = f.outputImage ?? ci
            }
            if let rendered = render(ci.cropped(to: full), extent: full) {
                ctx.draw(rendered, in: full)
            }
        }
        let target = CGRect(origin: origin, size: drawn)
        if options.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -options.shadow / 3), blur: options.shadow, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(CGPath(roundedRect: target, cornerWidth: options.cornerRadius, cornerHeight: options.cornerRadius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: target, cornerWidth: min(options.cornerRadius, drawn.width / 2), cornerHeight: min(options.cornerRadius, drawn.height / 2), transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: target)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    enum CollageLayout: String, CaseIterable, Identifiable {
        case grid, row, column, featured
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    struct CollageOptions {
        var layout: CollageLayout = .grid
        var width: CGFloat = 2400
        var height: CGFloat = 2400
        var spacing: CGFloat = 24
        var cornerRadius: CGFloat = 16
        var background: NSColor = .white
    }

    static func collageFrames(count: Int, options: CollageOptions) -> [CGRect] {
        guard count > 0 else { return [] }
        let s = options.spacing
        let w = options.width, h = options.height
        var frames: [CGRect] = []
        switch options.layout {
        case .row:
            let cell = (w - s * CGFloat(count + 1)) / CGFloat(count)
            for i in 0..<count { frames.append(CGRect(x: s + CGFloat(i) * (cell + s), y: s, width: cell, height: h - 2 * s)) }
        case .column:
            let cell = (h - s * CGFloat(count + 1)) / CGFloat(count)
            for i in 0..<count { frames.append(CGRect(x: s, y: h - s - CGFloat(i + 1) * cell - CGFloat(i) * s, width: w - 2 * s, height: cell)) }
        case .grid:
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellW = (w - s * CGFloat(columns + 1)) / CGFloat(columns)
            let cellH = (h - s * CGFloat(rows + 1)) / CGFloat(rows)
            for i in 0..<count {
                let c = i % columns, r = i / columns
                frames.append(CGRect(x: s + CGFloat(c) * (cellW + s), y: h - s - CGFloat(r + 1) * cellH - CGFloat(r) * s, width: cellW, height: cellH))
            }
        case .featured:
            if count == 1 { return [CGRect(x: s, y: s, width: w - 2 * s, height: h - 2 * s)] }
            let featureH = (h - 3 * s) * 0.62
            frames.append(CGRect(x: s, y: h - s - featureH, width: w - 2 * s, height: featureH))
            let rest = count - 1
            let cell = (w - s * CGFloat(rest + 1)) / CGFloat(rest)
            let restH = h - 3 * s - featureH
            for i in 0..<rest { frames.append(CGRect(x: s + CGFloat(i) * (cell + s), y: s, width: cell, height: restH)) }
        }
        return frames
    }

    static func collage(_ images: [CGImage], options: CollageOptions) -> CGImage? {
        let frames = collageFrames(count: images.count, options: options)
        guard let ctx = CGContext(
            data: nil, width: Int(options.width), height: Int(options.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(options.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: options.width, height: options.height))
        ctx.interpolationQuality = .high
        for (image, frame) in zip(images, frames) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: options.cornerRadius, cornerHeight: options.cornerRadius, transform: nil))
            ctx.clip()
            let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.draw(image, in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}



// Open Tangerine / Operations/MetadataOps.swift
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct MetadataField: Identifiable, Hashable {
    let id: String
    let group: String
    let key: String
    var value: String
    let editable: Bool
    let sensitive: Bool
}

enum MetadataOps {
    static let sensitiveGroups: Set<String> = ["GPS", "Exif", "MakerApple", "TIFF", "IPTC", "XMP"]

    static func read(_ url: URL) async -> [MetadataField] {
        guard let format = FileFormat.detect(url) else { return [] }
        switch format.category {
        case .image: return readImage(url)
        case .audio, .video: return await readAV(url)
        case .document where format == .pdf: return readPDF(url)
        default: return fileFields(url)
        }
    }

    static func fileFields(_ url: URL) -> [MetadataField] {
        var fields: [MetadataField] = []
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        fields.append(MetadataField(id: "file.name", group: "File", key: "Name", value: url.lastPathComponent, editable: false, sensitive: false))
        if let size = attrs?[.size] as? Int64 {
            fields.append(MetadataField(id: "file.size", group: "File", key: "Size", value: FileSizeFormatter.string(size), editable: false, sensitive: false))
        }
        if let created = attrs?[.creationDate] as? Date {
            fields.append(MetadataField(id: "file.created", group: "File", key: "Created", value: created.formatted(), editable: false, sensitive: false))
        }
        if let modified = attrs?[.modificationDate] as? Date {
            fields.append(MetadataField(id: "file.modified", group: "File", key: "Modified", value: modified.formatted(), editable: false, sensitive: false))
        }
        return fields
    }

    static func readImage(_ url: URL) -> [MetadataField] {
        var fields = fileFields(url)
        let props = ImageIOBridge.properties(url)
        for (key, value) in props {
            let name = key as String
            if let dictionary = value as? [CFString: Any] {
                let group = name.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                for (subKey, subValue) in dictionary {
                    let sub = subKey as String
                    fields.append(MetadataField(id: "\(group).\(sub)", group: group, key: sub, value: describe(subValue), editable: isEditableImageKey(group: group, key: sub), sensitive: sensitiveGroups.contains(group)))
                }
            } else {
                fields.append(MetadataField(id: "Image.\(name)", group: "Image", key: name, value: describe(value), editable: false, sensitive: false))
            }
        }
        return fields.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    private static func isEditableImageKey(group: String, key: String) -> Bool {
        let editable: Set<String> = ["Artist", "Copyright", "ImageDescription", "Software", "Make", "Model", "UserComment", "DateTimeOriginal", "DateTimeDigitized", "DateTime", "LensModel", "Keywords", "Caption/Abstract", "Byline", "CopyrightNotice", "ObjectName", "City", "Country/PrimaryLocationName"]
        return editable.contains(key)
    }

    static func readAV(_ url: URL) async -> [MetadataField] {
        var fields = fileFields(url)
        let asset = AVURLAsset(url: url)
        let info = await MediaInfo.load(url)
        if info.duration > 0 { fields.append(MetadataField(id: "media.duration", group: "Media", key: "Duration", value: TimeFormatter.clock(info.duration), editable: false, sensitive: false)) }
        if info.hasVideo { fields.append(MetadataField(id: "media.size", group: "Media", key: "Dimensions", value: "\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height))", editable: false, sensitive: false)) }
        if info.frameRate > 0 { fields.append(MetadataField(id: "media.fps", group: "Media", key: "Frame rate", value: String(format: "%.2f fps", info.frameRate), editable: false, sensitive: false)) }
        if info.channelCount > 0 { fields.append(MetadataField(id: "media.channels", group: "Media", key: "Channels", value: "\(info.channelCount)", editable: false, sensitive: false)) }
        if info.sampleRate > 0 { fields.append(MetadataField(id: "media.rate", group: "Media", key: "Sample rate", value: "\(Int(info.sampleRate)) Hz", editable: false, sensitive: false)) }
        let items = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in common + items {
            guard let key = item.commonKey?.rawValue ?? (item.key.map { "\($0)" }) else { continue }
            var value = (try? await item.load(.stringValue)) ?? ""
            if value.isEmpty, let raw = try? await item.load(.value) { value = "\(raw)" }
            guard !value.isEmpty else { continue }
            let id = "av.\(item.keySpace?.rawValue ?? "common").\(key)"
            if fields.contains(where: { $0.id == id }) { continue }
            fields.append(MetadataField(id: id, group: "Tags", key: key.replacingOccurrences(of: "©", with: ""), value: value, editable: item.commonKey != nil, sensitive: key.lowercased().contains("location")))
        }
        if let ffmpegFields = await readWithFFprobe(url), !ffmpegFields.isEmpty {
            for field in ffmpegFields where !fields.contains(where: { $0.key.lowercased() == field.key.lowercased() && $0.group == field.group }) {
                fields.append(field)
            }
        }
        return fields
    }

    private static func readWithFFprobe(_ url: URL) async -> [MetadataField]? {
        guard let probe = FFmpeg.probePath else { return nil }
        guard let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format_tags:stream_tags:chapters", "-of", "json", url.path]), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields: [MetadataField] = []
        if let format = object["format"] as? [String: Any], let tags = format["tags"] as? [String: Any] {
            for (key, value) in tags {
                fields.append(MetadataField(id: "ff.format.\(key)", group: "Tags", key: key, value: describe(value), editable: true, sensitive: key.lowercased().contains("location")))
            }
        }
        if let streams = object["streams"] as? [[String: Any]] {
            for (index, stream) in streams.enumerated() {
                guard let tags = stream["tags"] as? [String: Any] else { continue }
                for (key, value) in tags {
                    fields.append(MetadataField(id: "ff.stream\(index).\(key)", group: "Track \(index + 1)", key: key, value: describe(value), editable: false, sensitive: false))
                }
            }
        }
        if let chapters = object["chapters"] as? [[String: Any]] {
            for (index, chapter) in chapters.enumerated() {
                let title = ((chapter["tags"] as? [String: Any])?["title"] as? String) ?? "Chapter \(index + 1)"
                let start = chapter["start_time"] as? String ?? ""
                fields.append(MetadataField(id: "ff.chapter\(index)", group: "Chapters", key: title, value: start, editable: false, sensitive: false))
            }
        }
        return fields
    }

    static func readPDF(_ url: URL) -> [MetadataField] {
        var fields = fileFields(url)
        guard let document = PDFDocument(url: url) else { return fields }
        fields.append(MetadataField(id: "pdf.pages", group: "Document", key: "Pages", value: "\(document.pageCount)", editable: false, sensitive: false))
        for (key, value) in document.documentAttributes ?? [:] {
            let name = (key.base as? PDFDocumentAttribute)?.rawValue ?? "\(key)"
            fields.append(MetadataField(id: "pdf.\(name)", group: "Document", key: name, value: describe(value), editable: true, sensitive: name == "Author" || name == "Creator" || name == "Producer"))
        }
        return fields
    }

    static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let date = value as? Date { return date.formatted() }
        if let array = value as? [Any] { return array.map(describe).joined(separator: ", ") }
        if let dictionary = value as? [AnyHashable: Any] { return dictionary.map { "\($0.key)=\(describe($0.value))" }.sorted().joined(separator: "; ") }
        return "\(value)"
    }

    static func write(_ url: URL, edits: [MetadataField], removeAll: Bool, removeSensitive: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw OpenTangerineError.unreadable(url) }
        switch format.category {
        case .image:
            try writeImage(url, edits: edits, removeAll: removeAll, removeSensitive: removeSensitive, to: destination)
        case .audio, .video:
            try await writeAV(url, format: format, edits: edits, removeAll: removeAll || removeSensitive, to: destination, progress: progress)
        case .document where format == .pdf:
            try writePDF(url, edits: edits, removeAll: removeAll, removeSensitive: removeSensitive, to: destination)
        default:
            throw OpenTangerineError.invalidInput("Metadata editing is not supported for \(format.displayName).")
        }
        progress(1)
    }

    private static func writeImage(_ url: URL, edits: [MetadataField], removeAll: Bool, removeSensitive: Bool, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { throw OpenTangerineError.unreadable(url) }
        let count = CGImageSourceGetCount(source)
        let outputType: CFString = ImageIOBridge.nativeEncoders.contains(type as String) ? type : (UTType.png.identifier as CFString)
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, outputType, count, nil) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        for index in 0..<count {
            var props = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            if removeAll {
                let keep: Set<CFString> = [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyColorModel, kCGImagePropertyHasAlpha, kCGImagePropertyDepth, kCGImagePropertyProfileName]
                props = props.filter { keep.contains($0.key) }
                props[kCGImagePropertyExifDictionary] = kCFNull
                props[kCGImagePropertyGPSDictionary] = kCFNull
                props[kCGImagePropertyIPTCDictionary] = kCFNull
                props[kCGImagePropertyTIFFDictionary] = kCFNull
                props[kCGImagePropertyMakerAppleDictionary] = kCFNull
                props[kCGImagePropertyExifAuxDictionary] = kCFNull
            } else {
                if removeSensitive {
                    props[kCGImagePropertyIPTCDictionary] = kCFNull
                    props[kCGImagePropertyGPSDictionary] = kCFNull
                    props[kCGImagePropertyMakerAppleDictionary] = kCFNull
                    props[kCGImagePropertyExifAuxDictionary] = kCFNull
                    if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                        for key in [kCGImagePropertyExifUserComment, kCGImagePropertyExifSubjectLocation, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName] {
                            exif[key] = kCFNull
                        }
                        props[kCGImagePropertyExifDictionary] = exif
                    }
                    if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFHostComputer] {
                            tiff[key] = kCFNull
                        }
                        props[kCGImagePropertyTIFFDictionary] = tiff
                    }
                }
                for edit in edits where edit.editable && !(removeSensitive && edit.sensitive) {
                    let groupKey = groupDictionaryKey(edit.group)
                    guard let groupKey else { continue }
                    var dict = (props[groupKey] as? [CFString: Any]) ?? [:]
                    if edit.value.isEmpty {
                        dict[edit.key as CFString] = kCFNull
                    } else {
                        dict[edit.key as CFString] = edit.value
                    }
                    props[groupKey] = dict
                }
            }
            var options = props
            options[kCGImageDestinationMetadata] = kCFNull
            if removeAll { options[kCGImageDestinationMergeMetadata] = false }
            CGImageDestinationAddImageFromSource(dest, source, index, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    private static func groupDictionaryKey(_ group: String) -> CFString? {
        switch group {
        case "Exif": return kCGImagePropertyExifDictionary
        case "TIFF": return kCGImagePropertyTIFFDictionary
        case "IPTC": return kCGImagePropertyIPTCDictionary
        case "GPS": return kCGImagePropertyGPSDictionary
        case "PNG": return kCGImagePropertyPNGDictionary
        default: return nil
        }
    }

    private static func writeAV(_ url: URL, format: FileFormat, edits: [MetadataField], removeAll: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let nativeTarget = VideoEngine.nativeTargets.contains(format) || format == .m4a
        if nativeTarget, await MediaInfo.isNativelyReadable(url) {
            var items: [AVMetadataItem] = []
            if !removeAll {
                for edit in edits where edit.editable && edit.id.hasPrefix("av.") {
                    let key = edit.id.components(separatedBy: ".").last ?? ""
                    let commonKey = AVMetadataKey(rawValue: key)
                    let item = AVMutableMetadataItem()
                    item.keySpace = .common
                    item.key = commonKey.rawValue as NSString
                    item.value = edit.value as NSString
                    items.append(item)
                }
            }
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: format, preset: AVAssetExportPresetPassthrough, metadata: items, progress: progress)
            return
        }
        var args = ["-i", url.path, "-map", "0", "-c", "copy"]
        if removeAll {
            args += ["-map_metadata", "-1", "-map_chapters", "-1"]
        } else {
            args += ["-map_metadata", "0"]
            for edit in edits where edit.editable {
                args += ["-metadata", "\(edit.key)=\(edit.value)"]
            }
        }
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: "Writing metadata")
    }

    private static func writePDF(_ url: URL, edits: [MetadataField], removeAll: Bool, removeSensitive: Bool, to destination: URL) throws {
        let document = try PDFOps.document(url)
        if removeAll {
            document.documentAttributes = [:]
        } else {
            var attrs = document.documentAttributes ?? [:]
            if removeSensitive {
                for key in [PDFDocumentAttribute.authorAttribute, .creatorAttribute, .producerAttribute] { attrs.removeValue(forKey: key) }
            }
            for edit in edits where edit.editable && edit.id.hasPrefix("pdf.") && !(removeSensitive && edit.sensitive) {
                let name = String(edit.id.dropFirst(4))
                let key = AnyHashable(PDFDocumentAttribute(rawValue: name))
                if edit.value.isEmpty {
                    attrs.removeValue(forKey: key)
                } else {
                    attrs[key] = edit.value
                }
            }
            document.documentAttributes = attrs
        }
        guard document.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }
}



// Open Tangerine / Operations/PDFOps.swift
import AppKit
import Foundation
import PDFKit

struct PDFPageRef: Identifiable, Equatable {
    let id = UUID()
    let sourceIndex: Int
    var rotation: Int
    var sourceURL: URL

    static func == (lhs: PDFPageRef, rhs: PDFPageRef) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation
    }
}

enum PDFOps {
    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw OpenTangerineError.unreadable(url) }
        if document.isLocked { throw OpenTangerineError.invalidInput("\(url.lastPathComponent) is password protected.") }
        guard document.pageCount > 0 else { throw OpenTangerineError.invalidInput("The PDF has no pages.") }
        return document
    }

    static func merge(_ urls: [URL], to destination: URL) throws {
        guard !urls.isEmpty else { throw OpenTangerineError.invalidInput("Choose at least one PDF to merge.") }
        let output = PDFDocument()
        for url in urls {
            let source = try document(url)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    static func assemble(pages: [PDFPageRef], to destination: URL) throws {
        var cache: [URL: PDFDocument] = [:]
        let output = PDFDocument()
        for ref in pages {
            let source: PDFDocument
            if let cached = cache[ref.sourceURL] {
                source = cached
            } else {
                source = try document(ref.sourceURL)
                cache[ref.sourceURL] = source
            }
            guard let page = source.page(at: ref.sourceIndex), let copy = page.copy() as? PDFPage else { throw OpenTangerineError.invalidInput("A selected PDF page is unavailable.") }
            copy.rotation = ref.rotation
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw OpenTangerineError.invalidInput("The document would have no pages.") }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyPage: return "One file per page"
            case .everyN: return "Every N pages"
            case .ranges: return "Custom page ranges"
            }
        }
    }

    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { token in
            let part = token.trimmingCharacters(in: .whitespaces)
            if let dash = part.range(of: "-") {
                let a = Int(part[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1
                let b = Int(part[dash.upperBound...].trimmingCharacters(in: .whitespaces)) ?? pageCount
                let lower = max(1, min(a, b)), upper = min(pageCount, max(a, b))
                return lower <= upper ? lower...upper : nil
            }
            if let single = Int(part), single >= 1, single <= pageCount { return single...single }
            return nil
        }
    }

    static func split(_ url: URL, mode: SplitMode, every: Int, ranges: String, into folder: URL) throws -> [URL] {
        let source = try document(url)
        let count = source.pageCount
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        var groups: [ClosedRange<Int>] = []
        switch mode {
        case .everyPage:
            groups = (1...max(1, count)).map { $0...$0 }
        case .everyN:
            let n = max(1, every)
            var start = 1
            while start <= count {
                groups.append(start...min(count, start + n - 1))
                start += n
            }
        case .ranges:
            groups = parseRanges(ranges, pageCount: count)
        }
        guard !groups.isEmpty else { throw OpenTangerineError.invalidInput("No valid page ranges.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, group) in groups.enumerated() {
            let part = PDFDocument()
            for pageNumber in group {
                guard let page = source.page(at: pageNumber - 1) else { continue }
                part.insert(page, at: part.pageCount)
            }
            let name = group.count == 1 ? "\(base) page \(group.lowerBound).pdf" : "\(base) pages \(group.lowerBound)-\(group.upperBound).pdf"
            let output = folder.appendingPathComponent(name.isEmpty ? "\(base) part \(index + 1).pdf" : name)
            guard part.write(to: output) else { throw OpenTangerineError.encodeFailed(output.lastPathComponent) }
            outputs.append(output)
        }
        return outputs
    }

    static func compress(_ url: URL, strong: Bool, to destination: URL) throws {
        let source = try document(url)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        if strong {
            let rendered = PDFDocument()
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index), let image = PDFRenderer.render(page: page, dpi: 110) else { throw OpenTangerineError.encodeFailed("PDF page \(index + 1)") }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-pdfpage-\(UUID().uuidString).jpg")
                try ImageIOBridge.write(image, to: temp, format: .jpg, quality: 0.6)
                defer { try? FileManager.default.removeItem(at: temp) }
                if let nsImage = NSImage(contentsOf: temp), let newPage = PDFPage(image: nsImage) {
                    rendered.insert(newPage, at: rendered.pageCount)
                }
            }
            guard rendered.write(to: destination, withOptions: options) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
            return
        }
        guard source.write(to: destination, withOptions: options) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    static func fromImages(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) throws {
        let output = PDFDocument()
        for (index, url) in urls.enumerated() {
            let image = try ImageIOBridge.load(url)
            let nsImage = ImageOps.nsImage(image)
            if let page = PDFPage(image: nsImage) {
                output.insert(page, at: output.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        guard output.pageCount > 0 else { throw OpenTangerineError.invalidInput("No images could be read.") }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }
}



// Open Tangerine / Operations/VideoOps.swift
import AVFoundation
import CoreImage
import Foundation

enum VideoOps {
    static func trim(_ url: URL, start: Double, end: Double, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw OpenTangerineError.invalidInput("Choose a valid trim range.") }
        let format = FileFormat.detect(url) ?? .mp4
        let range = AVExporter.timeRange(start: start, end: end)
        if VideoEngine.nativeTargets.contains(format), await MediaInfo.isNativelyReadable(url) {
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: format, preset: AVAssetExportPresetPassthrough, timeRange: range, progress: progress)
            return
        }
        // Stream-copy seeks to a keyframe and can include content outside the chosen range.
        let args = ["-ss", FFmpeg.timecode(start), "-i", url.path, "-t", FFmpeg.timecode(end - start)] + VideoEngine.codecArguments(for: format) + [destination.path]
        try await FFmpeg.run(args, purpose: "Trimming video", duration: end - start, progress: progress)
    }

    static func split(_ url: URL, at points: [Double], duration: Double, into folder: URL, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let sorted = ([0] + points.filter { $0 > 0 && $0 < duration }.sorted() + [duration])
        var outputs: [URL] = []
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index], end = sorted[index + 1]
            guard end - start > 0.05 else { continue }
            let output = folder.appendingPathComponent("\(base) part \(index + 1).\(url.pathExtension)")
            let count = Double(sorted.count - 1)
            try await trim(url, start: start, end: end, to: output) { p in progress((Double(index) + p) / count) }
            outputs.append(output)
        }
        return outputs
    }

    static func videoComposition(for asset: AVAsset, crop: CGRect?, outputSize: CGSize?, filter: ((CIImage, CMTime) -> CIImage)? = nil) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw OpenTangerineError.invalidInput("No video track found.") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let cropRect = crop ?? CGRect(origin: .zero, size: orientedSize)
        let renderSize = outputSize ?? cropRect.size

        let composition = AVMutableVideoComposition(asset: asset) { request in
            var image = request.sourceImage
            let flippedCrop = CGRect(x: cropRect.minX, y: orientedSize.height - cropRect.maxY, width: cropRect.width, height: cropRect.height)
            if let filter { image = filter(image, request.compositionTime) }
            image = image.cropped(to: flippedCrop)
            image = image.transformed(by: CGAffineTransform(translationX: -flippedCrop.minX, y: -flippedCrop.minY))
            let scale = min(renderSize.width / flippedCrop.width, renderSize.height / flippedCrop.height)
            if abs(scale - 1) > 0.001 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: renderSize)), context: nil)
        }
        composition.renderSize = CGSize(width: (renderSize.width / 2).rounded(.down) * 2, height: (renderSize.height / 2).rounded(.down) * 2)
        composition.frameDuration = CMTime(value: 1, timescale: fps > 0 ? CMTimeScale(fps.rounded()) : 30)
        return composition
    }

    static func crop(_ url: URL, rect: CGRect, outputSize: CGSize?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        if !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) {
            let composition = try await videoComposition(for: asset, crop: rect, outputSize: outputSize)
            try await AVExporter.export(asset: asset, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: composition, progress: progress)
            return
        }
        var filters = ["crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"]
        if let outputSize { filters.append("scale=\(Int(outputSize.width)):\(Int(outputSize.height))") }
        try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: .mp4, videoFilters: filters, progress: progress)
    }

    static func changeSpeed(_ url: URL, factor: Double, preservePitch: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard factor.isFinite, factor > 0 else { throw OpenTangerineError.invalidInput("Speed must be greater than zero.") }
        let asset = AVURLAsset(url: url)
        guard !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) else {
            let info = try await streamInfo(url)
            let videoFilter = "setpts=\(1 / factor)*PTS"
            let audioFilter = preservePitch ? atempoChain(factor) : "asetrate=\(info.sampleRate)*\(factor),aresample=\(info.sampleRate)"
            let duration = (await FFmpeg.probeDuration(url) ?? 0) / factor
            var args = ["-i", url.path, "-vf", videoFilter]
            if info.hasAudio { args += ["-af", audioFilter] }
            args += VideoEngine.codecArguments(for: .mp4) + [destination.path]
            try await FFmpeg.run(args, purpose: "Changing speed", duration: duration, progress: progress)
            return
        }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        for source in videoTracks {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(fullRange, of: source, at: .zero)
            track.scaleTimeRange(fullRange, toDuration: scaled)
            track.preferredTransform = try await source.load(.preferredTransform)
        }
        for source in audioTracks {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(fullRange, of: source, at: .zero)
            track.scaleTimeRange(fullRange, toDuration: scaled)
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
            audioMixParams.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioMixParams
        try await AVExporter.export(asset: composition, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, audioMix: audioMixParams.isEmpty ? nil : mix, progress: progress)
    }

    static func atempoChain(_ factor: Double) -> String {
        guard factor.isFinite, factor > 0 else { return "anull" }
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 { parts.append("atempo=2.0"); remaining /= 2.0 }
        while remaining < 0.5 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append(String(format: "atempo=%.4f", remaining))
        return parts.joined(separator: ",")
    }

    static func join(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard !urls.isEmpty else { throw OpenTangerineError.invalidInput("Choose at least one video to join.") }
        var allNative = true
        for url in urls {
            if !(await MediaInfo.isNativelyReadable(url)) { allNative = false }
        }
        if allNative && !FFmpeg.isAvailable {
            let composition = AVMutableComposition()
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var cursor = CMTime.zero
            var canvas: CGSize?
            var instructions: [AVMutableVideoCompositionInstruction] = []
            for url in urls {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                if let source = try await asset.loadTracks(withMediaType: .video).first, let videoTrack {
                    try videoTrack.insertTimeRange(range, of: source, at: cursor)
                    let natural = try await source.load(.naturalSize)
                    let transform = try await source.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: natural).applying(transform)
                    let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                    if canvas == nil { canvas = size }
                    let target = canvas ?? size
                    let scale = min(target.width / size.width, target.height / size.height)
                    let translate = CGAffineTransform(translationX: (target.width - size.width * scale) / 2 - oriented.minX * scale, y: (target.height - size.height * scale) / 2 - oriented.minY * scale)
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(translate), at: cursor)
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
                    instruction.layerInstructions = [layer]
                    instructions.append(instruction)
                }
                if let source = try await asset.loadTracks(withMediaType: .audio).first, let audioTrack {
                    try audioTrack.insertTimeRange(range, of: source, at: cursor)
                }
                cursor = CMTimeAdd(cursor, duration)
            }
            let videoComposition = AVMutableVideoComposition()
            videoComposition.instructions = instructions
            videoComposition.renderSize = canvas ?? CGSize(width: 1920, height: 1080)
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            try await AVExporter.export(asset: composition, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: videoComposition, progress: progress)
            return
        }
        var args: [String] = []
        for url in urls { args += ["-i", url.path] }
        let first = try await streamInfo(urls[0])
        let w = max(2, first.width / 2 * 2), h = max(2, first.height / 2 * 2)
        var filter = ""
        for index in urls.indices {
            let info = try await streamInfo(urls[index])
            filter += "[\(index):v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,setpts=PTS-STARTPTS[v\(index)];"
            if info.hasAudio {
                filter += "[\(index):a]aresample=48000,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(index)];"
            } else {
                let duration = await FFmpeg.probeDuration(urls[index]) ?? 0
                guard duration > 0 else { throw OpenTangerineError.invalidInput("Could not read the video duration.") }
                filter += "anullsrc=r=48000:cl=stereo,atrim=duration=\(duration)[a\(index)];"
            }
        }
        filter += urls.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(urls.count):v=1:a=1[v][a]"
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "[a]"] + VideoEngine.codecArguments(for: .mp4) + [destination.path]
        var total = 0.0
        for url in urls { total += await FFmpeg.probeDuration(url) ?? 0 }
        try await FFmpeg.run(args, purpose: "Joining videos", duration: total, progress: progress)
    }

    private static func streamInfo(_ url: URL) async throws -> (width: Int, height: Int, hasAudio: Bool, sampleRate: Int) {
        guard let probe = FFmpeg.probePath else { throw OpenTangerineError.ffmpegMissing("Reading media streams") }
        let result = try await Shell.run(probe, ["-v", "error", "-show_streams", "-of", "json", url.path])
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw OpenTangerineError.invalidInput("No readable video stream found.")
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        return (video["width"] as? Int ?? 0, video["height"] as? Int ?? 0, audio != nil, Int(audio?["sample_rate"] as? String ?? "48000") ?? 48000)
    }

    static func snapshot(_ url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if let result = try? await generator.image(at: time) { return result.image }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await FFmpeg.run(["-ss", FFmpeg.timecode(seconds), "-i", url.path, "-frames:v", "1", temp.path], purpose: "Extracting frame")
        return try ImageIOBridge.load(temp)
    }

    static func redact(_ url: URL, redactions: [Redaction], displaySize: CGSize, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) else {
            guard displaySize.width > 0, displaySize.height > 0 else { throw OpenTangerineError.invalidInput("Invalid video preview size.") }
            let info = try await streamInfo(url)
            let sx = Double(info.width) / displaySize.width, sy = Double(info.height) / displaySize.height
            var filters: [String] = []
            for (index, r) in redactions.enumerated() {
                let x = max(0, min(info.width - 1, Int(r.rect.minX * sx)))
                let y = max(0, min(info.height - 1, Int(r.rect.minY * sy)))
                let w = min(info.width - x, max(1, Int(r.rect.width * sx)))
                let h = min(info.height - y, max(1, Int(r.rect.height * sy)))
                let enable = r.end.isFinite ? ":enable='between(t,\(r.start),\(r.end))'" : ":enable='gte(t,\(r.start))'"
                switch r.style {
                case .solid: filters.append("drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill\(enable)")
                case .blur, .pixelate:
                    let effect = r.style == .blur ? "boxblur=luma_radius=\(max(1, min(w, h) / 8)):luma_power=2" : "scale=\(max(1,w/12)):\(max(1,h/12)),scale=\(w):\(h):flags=neighbor"
                    filters.append("split[base\(index)][region\(index)];[region\(index)]crop=\(w):\(h):\(x):\(y),\(effect)[patch\(index)];[base\(index)][patch\(index)]overlay=\(x):\(y)\(enable)")
                }
            }
            try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: .mp4, videoFilters: filters, progress: progress)
            return
        }
        let composition = try await videoComposition(for: asset, crop: nil, outputSize: nil) { image, time in
            let seconds = CMTimeGetSeconds(time)
            let active = redactions.filter { seconds >= $0.start && seconds <= $0.end }
            guard !active.isEmpty else { return image }
            let scaleX = image.extent.width / displaySize.width
            let scaleY = image.extent.height / displaySize.height
            let scaled = active.map { r -> Redaction in
                var copy = r
                copy.rect = CGRect(x: r.rect.minX * scaleX, y: r.rect.minY * scaleY, width: r.rect.width * scaleX, height: r.rect.height * scaleY)
                return copy
            }
            return ImageOps.redact(image, redactions: scaled, flipped: true)
        }
        try await AVExporter.export(asset: asset, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: composition, progress: progress)
    }

    static func compress(_ url: URL, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        let target = FileFormat.detect(url) ?? .mp4
        let outputFormat: FileFormat = VideoEngine.nativeTargets.contains(target) ? target : .mp4
        if let targetBytes, info.duration > 0 {
            let totalBits = Double(targetBytes) * 8 * 0.94
            let audioBits = Double(min(preset.audioBitrate, 128_000))
            let videoBitrate = max(150_000, Int(totalBits / info.duration - audioBits))
            let scale = preset.videoScale
            var filters: [String] = []
            if scale < 1 { filters.append("scale=trunc(iw*\(scale)/2)*2:trunc(ih*\(scale)/2)*2") }
            try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: outputFormat, videoFilters: filters, videoBitrate: videoBitrate, audioBitrate: Int(audioBits), progress: progress)
            return
        }
        if !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) {
            let longEdge = max(info.naturalSize.width, info.naturalSize.height) * preset.videoScale
            let presetName: String
            if preset == .strong || longEdge <= 1280 {
                presetName = longEdge > 1280 ? AVAssetExportPreset1280x720 : (longEdge > 960 ? AVAssetExportPreset960x540 : AVAssetExportPreset640x480)
            } else {
                presetName = longEdge > 1920 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
            }
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: outputFormat, preset: presetName, progress: progress)
            return
        }
        let videoBitrate = Int(max(300_000, info.estimatedBitrate * preset.videoBitrateFactor))
        var filters: [String] = []
        if preset.videoScale < 1 { filters.append("scale=trunc(iw*\(preset.videoScale)/2)*2:trunc(ih*\(preset.videoScale)/2)*2") }
        try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: outputFormat, videoFilters: filters, videoBitrate: videoBitrate, audioBitrate: preset.audioBitrate, progress: progress)
    }
}



// Open Tangerine / Tools/AnyFile/CompressToolView.swift
import SwiftUI

@MainActor
struct CompressToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @HCState private var useTarget = false
    @HCState private var targetValue: Double = 1
    @HCState private var targetUnit: SizeUnit = .megabytes
    @HCState private var resize = 0

    enum SizeUnit: String, CaseIterable, Identifiable {
        case kilobytes = "KB"
        case megabytes = "MB"
        var id: String { rawValue }
        var multiplier: Double { self == .kilobytes ? 1_000 : 1_000_000 }
    }

    private var totalSize: Int64 { session.files.reduce(0) { $0 + FileSizeFormatter.size(of: $1) } }
    private var perFileTarget: Int64? {
        guard useTarget else { return nil }
        return Int64(targetValue * targetUnit.multiplier)
    }

    private enum ImageSize: Int, CaseIterable, Identifiable {
        case original = 0
        case large = 2560
        case medium = 1920
        case small = 1280

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .large: return "2560 px"
            case .medium: return "1920 px"
            case .small: return "1280 px"
            }
        }
    }

    private var imageSize: Binding<ImageSize> {
        Binding(
            get: { ImageSize(rawValue: resize) ?? .original },
            set: { resize = $0.rawValue }
        )
    }

    private var hasImages: Bool { session.files.contains { FileFormat.detect($0)?.category == .image } }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? "Compress" : "Compress \(session.files.count) files", onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as \(Compressor.outputFormat(for: url).displayName)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            FormRow(title: "Compression") {
                SegmentedPicker(selection: $settings.compressionPreset, options: CompressionPreset.allCases.map { ($0, $0.title) })
            }
            FormHint(settings.compressionPreset == .balanced ? "Noticeably smaller with little visible change." : "Smallest output; quality loss is visible.")

            if hasImages {
                FormRow(title: "Image size") {
                    SegmentedPicker(selection: imageSize, options: ImageSize.allCases.map { ($0, $0.title) })
                }
                FormHint("Longest edge of each image. Smaller images are never upscaled.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $useTarget.animation(.easeInOut(duration: 0.18))) {
                    Text("Target file size")
                }
                .toggleStyle(.switch)

                if useTarget {
                    HStack(spacing: 10) {
                        TextField("Size", value: $targetValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                        SegmentedPicker(selection: $targetUnit, options: SizeUnit.allCases.map { ($0, $0.rawValue) })
                        Text("per file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    FormHint("Images use a quality search and downscale if needed. Videos and audio pick a bitrate from the duration (FFmpeg required).")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("\(session.files.count) file\(session.files.count == 1 ? "" : "s"), \(FileSizeFormatter.string(totalSize)) total. Originals stay untouched; compressed copies are saved to \(settings.outputLocation.title.lowercased()).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { resize = settings.compressionResizeLongEdge }
    }

    private func run() {
        let preset = settings.compressionPreset, target = perFileTarget, resize = resize
        let files = session.files, directory = session.outputDirectory
        session.run(title: "Compressing", detail: "\(files.count) files") { _ in
            var outputs: [URL] = []
            for url in files {
                let format = Compressor.outputFormat(for: url)
                let destination = ConversionMatrix.uniqueURL(directory: directory, baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "compressed", ext: format.fileExtension)
                try await Compressor.compress(url, preset: preset, resizeLongEdge: resize, targetBytes: target, to: destination, progress: { _ in })
                outputs.append(destination)
            }
            return outputs
        }
    }
}


// Open Tangerine / Tools/AnyFile/MetadataToolView.swift
import SwiftUI

@MainActor
struct MetadataToolView: View {
    let session: ToolSession
    @HCState private var fields: [MetadataField] = []
    @HCState private var loading = true
    @HCState private var search = ""
    @HCState private var removeAll = false
    @HCState private var removeSensitive = false
    @HCState private var selectedFile: URL

    init(session: ToolSession) {
        self.session = session
        _selectedFile = State(initialValue: session.primary)
    }

    private var groups: [(String, [MetadataField])] {
        let filtered = fields.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        let order = ["File", "Media", "Document", "Tags", "Image", "Exif", "TIFF", "GPS", "IPTC", "MakerApple", "Chapters"]
        var dict: [String: [MetadataField]] = [:]
        for field in filtered { dict[field.group, default: []].append(field) }
        return dict.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }.map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Save copy" : "Apply to \(session.files.count) files", onSave: run) {
            VStack(spacing: 0) {
                HStack {
                    if session.files.count > 1 {
                        Picker("File", selection: $selectedFile) {
                            ForEach(session.files, id: \.self) { Text($0.lastPathComponent).tag($0) }
                        }
                        .frame(maxWidth: 320)
                    }
                    Spacer()
                    TextField("Search fields", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                .padding(12)
                Divider()
                if loading {
                    LoadingOrError(error: nil)
                } else if fields.isEmpty {
                    Text("No metadata found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.0) { group, items in
                            Section(group) {
                                ForEach(items) { field in
                                    row(field)
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .disabled(removeAll)
                    .opacity(removeAll ? 0.4 : 1)
                }
            }
        } sidebar: {
            SidebarSection(title: "Remove") {
                Toggle("Remove all metadata", isOn: $removeAll)
                Toggle("Remove camera, GPS and processing data", isOn: $removeSensitive).disabled(removeAll)
                Text("Orientation and color profile are kept. Removing sensitive data clears all audio/video tags, and author/creator details from PDFs. Images may be re-encoded.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Editing") {
                Text("Editable fields show a text box. Clear a value to remove that field. Changes apply to a new copy; the original stays as is.")
                    .font(.caption2).foregroundStyle(.secondary)
                if session.files.count > 1 {
                    Text("Edited field values are applied to every selected file; removal options apply to all.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Summary") {
                let sensitive = fields.filter(\.sensitive).count
                Text("\(fields.count) fields · \(sensitive) sensitive").font(.callout.monospacedDigit())
            }
        }
        .task(id: selectedFile) { await load() }
    }

    @ViewBuilder
    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                if field.sensitive {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent).font(.caption)
                }
                Text(field.key).font(.callout).frame(width: 200, alignment: .leading).lineLimit(1)
            }
            if field.editable, let index = fields.firstIndex(where: { $0.id == field.id }) {
                TextField("", text: $fields[index].value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(field.value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer()
            }
        }
    }

    private func load() async {
        loading = true
        let url = selectedFile
        let result = await MetadataOps.read(url)
        fields = result
        loading = false
    }

    private func run() {
        let edits = fields.filter(\.editable), removeAll = removeAll, removeSensitive = removeSensitive
        let files = session.files, directory = session.outputDirectory
        session.run(title: "Editing metadata", detail: "\(files.count) files") { _ in
            var outputs: [URL] = []
            for url in files {
                guard let format = FileFormat.detect(url) else { continue }
                let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
                let ext = format.category == .image && !ImageIOBridge.canEncodeNatively(format) ? "png" : url.pathExtension
                let destination = ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: removeAll ? "clean" : "edited", ext: ext)
                try await MetadataOps.write(url, edits: edits, removeAll: removeAll, removeSensitive: removeSensitive, to: destination, progress: { _ in })
                outputs.append(destination)
            }
            return outputs
        }
    }
}


// Open Tangerine / Tools/Audio/AudioToolViews.swift
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TrimAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var start: Double = 0
    @HCState private var end: Double = 0
    @HCState private var silence: (leading: Double, trailing: Double)?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Trim", saveEnabled: end > start, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Range") {
                TimecodeField(title: "Start", seconds: $start, maximum: media.duration)
                TimecodeField(title: "End", seconds: $end, maximum: media.duration)
                HStack {
                    Button("Start at playhead") { start = min(media.currentTime, end - 0.01) }
                    Button("End at playhead") { end = max(media.currentTime, start + 0.01) }
                }
                .controlSize(.small)
                Text("Length: \(TimeFormatter.clock(max(0, end - start)))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Silence") {
                Button("Remove silence from beginning and end") {
                    if let silence { start = silence.leading; end = silence.trailing }
                }
                .disabled(silence == nil)
                if let silence {
                    Text("Detected \(TimeFormatter.clock(silence.leading)) leading and \(TimeFormatter.clock(media.duration - silence.trailing)) trailing silence.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Analyzing…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Preview") {
                Button("Play selection") { media.playRange(start, end) }
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: media.duration) { duration in if end == 0 { end = duration } }
        .task { silence = await AudioOps.detectSilence(session.primary) }
    }

    private func save() {
        let url = session.primary, start = start, end = end
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: "trimmed", ext: format.fileExtension)
        session.run(title: "Trimming", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.trim(url, start: start, end: end, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct NormalizeAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var target: Double = -16
    @HCState private var range: Double = 11
    @HCState private var truePeak: Double = -1.5
    @HCState private var stats: LoudnessStats?
    @HCState private var analyzed = false

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Normalize" : "Normalize \(session.files.count) files", onSave: save) {
            VStack(spacing: 14) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack(spacing: 24) {
                    LevelColumn(title: "Input", integrated: stats?.integrated, range: stats?.range, peak: stats?.truePeak, pending: !analyzed)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    LevelColumn(title: "Output", integrated: target, range: range, peak: truePeak, pending: false)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Loudness") {
                LabeledSlider(title: "Target loudness", value: $target, range: -30...(-8)) { String(format: "%.1f LUFS", $0) }
                LabeledSlider(title: "Loudness range", value: $range, range: 1...20) { String(format: "%.0f LU", $0) }
                LabeledSlider(title: "True peak", value: $truePeak, range: -9...0) { String(format: "%.1f dBTP", $0) }
            }
            SidebarSection(title: "Presets") {
                HStack {
                    Button("Podcast") { target = -16; range = 11; truePeak = -1.5 }
                    Button("Music") { target = -14; range = 9; truePeak = -1 }
                    Button("Broadcast") { target = -23; range = 7; truePeak = -2 }
                }
                .controlSize(.small)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: "Note") {
                    Text("Without FFmpeg, OpenTangerine applies peak normalization instead of EBU R128 loudness. Set an FFmpeg path in Settings for full loudness control.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform() }
        .task {
            stats = await AudioOps.measureLoudness(session.primary)
            analyzed = true
        }
    }

    private func save() {
        let files = session.files, target = target, range = range, peak = truePeak
        let outputs = files.map { url -> (URL, FileFormat) in
            let format = AudioOps.outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: session.outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "normalized", ext: format.fileExtension), format)
        }
        session.run(title: "Normalizing", detail: "\(files.count) file\(files.count == 1 ? "" : "s")") { progress in
            for (index, url) in files.enumerated() {
                let (destination, format) = outputs[index]
                try await AudioOps.normalize(url, targetLUFS: target, range: range, truePeak: peak, to: destination, format: format) { p in
                    progress((Double(index) + p) / Double(files.count))
                }
            }
            return outputs.map(\.0)
        }
    }
}

private struct LevelColumn: View {
    let title: String
    let integrated: Double?
    let range: Double?
    let peak: Double?
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            row("Integrated", integrated, "LUFS")
            row("Range", range, "LU")
            row("True peak", peak, "dBTP")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, unit)).font(.callout.monospacedDigit())
            } else {
                Text(pending ? "…" : "n/a").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct AudioChannelsToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var mode: AudioOps.ChannelMode = .stereo
    @HCState private var left: Double = 1
    @HCState private var right: Double = 1
    @HCState private var previewChannel: PreviewChannel = .both

    enum PreviewChannel: String, CaseIterable, Identifiable {
        case both, left, right
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", saveEnabled: FFmpeg.isAvailable, onSave: save) {
            VStack(spacing: 12) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack {
                    Text("Preview").font(.callout)
                    Picker("", selection: $previewChannel) {
                        ForEach(PreviewChannel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer()
                    Text(media.info.channelCount > 0 ? "\(media.info.channelCount) channel\(media.info.channelCount == 1 ? "" : "s") · \(Int(media.info.sampleRate)) Hz" : "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        } sidebar: {
            if !FFmpeg.isAvailable { Text("Channel conversion requires FFmpeg. Set its path in Settings.").font(.caption).foregroundStyle(.secondary) }
            SidebarSection(title: "Channels") {
                Picker("", selection: $mode) {
                    ForEach(AudioOps.ChannelMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            SidebarSection(title: "Volume") {
                LabeledSlider(title: "Left", value: $left, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: "Right", value: $right, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                Button("Reset") { left = 1; right = 1 }.controlSize(.small)
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: previewChannel) { channel in applyPreview(channel) }
        .onChange(of: left) { _ in applyPreview(previewChannel) }
        .onChange(of: right) { _ in applyPreview(previewChannel) }
        .onChange(of: media.loaded) { _ in applyPreview(previewChannel) }
    }

    private func applyPreview(_ channel: PreviewChannel) {
        guard let item = media.player.currentItem, let track = item.asset.tracks(withMediaType: .audio).first else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        let mix = AVMutableAudioMix()
        switch channel {
        case .both: params.setVolume(Float(max(left, right)), at: .zero)
        case .left: params.setVolume(Float(left), at: .zero)
        case .right: params.setVolume(Float(right), at: .zero)
        }
        mix.inputParameters = [params]
        item.audioMix = mix
        media.player.volume = 1
    }

    private func save() {
        let url = session.primary, mode = mode, left = left, right = right
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: mode == .mono ? "mono" : "channels", ext: format.fileExtension)
        session.run(title: "Converting channels", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.convertChannels(url, mode: mode, leftGain: left, rightGain: right, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct RedactAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var ranges: [AudioOps.BleepRange] = []
    @HCState private var selected: UUID?
    @HCState private var frequency: Double = 1000

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var selectedIndex: Int? { ranges.firstIndex { $0.id == selected } }

    var body: some View {
        ToolShell(session: session, saveTitle: "Bleep", saveEnabled: FFmpeg.isAvailable && !ranges.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(
                    duration: media.duration,
                    start: Binding(get: { selectedIndex.map { ranges[$0].start } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].start = min(new, ranges[i].end - 0.01) } }),
                    end: Binding(get: { selectedIndex.map { ranges[$0].end } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].end = max(new, ranges[i].start + 0.01) } }),
                    playhead: media.currentTime,
                    waveform: media.waveform,
                    markers: ranges.flatMap { [$0.start, $0.end] },
                    onScrub: { media.seek($0) }
                )
                .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Bleeps (\(ranges.count))") {
                Button("Add bleep at playhead") {
                    let start = media.currentTime
                    let range = AudioOps.BleepRange(start: start, end: min(media.duration, start + 1))
                    ranges.append(range)
                    selected = range.id
                }
                ForEach(ranges) { range in
                    HStack {
                        Circle().fill(range.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("\(TimeFormatter.clock(range.start)) – \(TimeFormatter.clock(range.end))").font(.callout.monospacedDigit())
                        Spacer()
                        Button { media.playRange(range.start, range.end) } label: { Image(systemName: "play.fill") }
                        Button { ranges.removeAll { $0.id == range.id }; if selected == range.id { selected = nil } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = range.id }
                }
            }
            if let i = selectedIndex {
                SidebarSection(title: "Selected bleep") {
                    TimecodeField(title: "Start", seconds: Binding(get: { ranges[i].start }, set: { ranges[i].start = min($0, ranges[i].end - 0.01) }), maximum: media.duration)
                    TimecodeField(title: "End", seconds: Binding(get: { ranges[i].end }, set: { ranges[i].end = max($0, ranges[i].start + 0.01) }), maximum: media.duration)
                    HStack {
                        Button("Nudge −0.1 s") { shift(i, -0.1) }
                        Button("Nudge +0.1 s") { shift(i, 0.1) }
                    }
                    .controlSize(.small)
                }
            }
            SidebarSection(title: "Tone") {
                LabeledSlider(title: "Frequency", value: $frequency, range: 300...2000) { String(format: "%.0f Hz", $0) }
            }
            SidebarSection(title: "Compare") {
                Text(FFmpeg.isAvailable ? "Play a bleep row to hear the original section. The saved copy replaces those sections with the tone." : "Bleep requires FFmpeg. Set its path in Settings.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { media.loadWaveform() }
    }

    private func shift(_ index: Int, _ delta: Double) {
        let length = ranges[index].end - ranges[index].start
        let start = max(0, min(media.duration - length, ranges[index].start + delta))
        ranges[index].start = start
        ranges[index].end = start + length
    }

    private func save() {
        let url = session.primary, ranges = ranges, frequency = frequency
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: "bleeped", ext: format.fileExtension)
        session.run(title: "Bleeping", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.bleep(url, ranges: ranges, frequency: frequency, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct AudioToVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var style: AudioOps.VisualizerStyle = .waveform
    @HCState private var orientation: AudioOps.VisualizerOrientation = .landscape
    @HCState private var accent = Color.orange
    @HCState private var background = Color.black
    @HCState private var imageURL: URL?
    @HCState private var image: NSImage?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Create MP4", saveEnabled: FFmpeg.isAvailable && (style != .stillImage || imageURL != nil), onSave: save) {
            VStack(spacing: 12) {
                ZStack {
                    background
                    if style == .stillImage {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text("Choose an image").foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        WaveformShape(samples: media.waveform.isEmpty ? Array(repeating: 0.3, count: 120) : media.waveform)
                            .fill(accent)
                            .padding(.horizontal, 24)
                            .frame(maxHeight: style == .bars ? .infinity : nil)
                            .opacity(0.95)
                    }
                }
                .aspectRatio(orientation.size.width / orientation.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("", selection: $style) {
                    ForEach(AudioOps.VisualizerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if style == .stillImage {
                    HStack {
                        Text(imageURL?.lastPathComponent ?? "No image").font(.callout).lineLimit(1)
                        Spacer()
                        Button("Choose…") { chooseImage() }
                    }
                }
            }
            SidebarSection(title: "Video") {
                Picker("", selection: $orientation) {
                    ForEach(AudioOps.VisualizerOrientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("\(Int(orientation.size.width)) × \(Int(orientation.size.height)) · 30 fps · H.264 + AAC").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Colors") {
                if style != .stillImage { ColorSwatchPicker(title: "Accent", color: $accent) }
                ColorSwatchPicker(title: "Background", color: $background)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: "Requires FFmpeg") {
                    Text("Rendering a visualizer needs FFmpeg. Set its path in Settings.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform(buckets: 240) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageURL = url
        image = (try? ImageIOBridge.load(url, maxPixelSize: 1200)).map(ImageOps.nsImage)
    }

    private func save() {
        let url = session.primary, style = style, orientation = orientation, imageURL = imageURL
        let accentHex = accent.nsColor.ffmpegHex, backgroundHex = background.nsColor.ffmpegHex
        let destination = session.outputURL(suffix: "visualizer", ext: "mp4")
        session.run(title: "Creating visualizer", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.visualize(url, style: style, orientation: orientation, accent: accentHex, background: backgroundHex, image: imageURL, to: destination, progress: progress)
            return [destination]
        }
    }
}

extension NSColor {
    var ffmpegHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "0x%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}



// Open Tangerine / Tools/FileAction.swift
import AppKit
import CryptoKit

enum FileAction: String, CaseIterable, Hashable {
    case reveal = "Reveal", copy = "Copy Files", paths = "Copy Paths", duplicate = "Duplicate", hash = "SHA-256"
    var symbol: String {
        switch self {
        case .reveal: return "folder"
        case .copy: return "doc.on.doc"
        case .paths: return "link"
        case .duplicate: return "plus.square.on.square"
        case .hash: return "number"
        }
    }

    static func duplicateFiles(_ urls: [URL]) throws -> [URL] {
        try urls.map { source in
            let destination = ConversionMatrix.uniqueURL(directory: source.deletingLastPathComponent(), baseName: source.deletingPathExtension().lastPathComponent, suffix: "copy", ext: source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    static func hashReport(_ urls: [URL]) throws -> String {
        try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw OpenTangerineError.unreadable(url) }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() + "  " + url.lastPathComponent
        }.joined(separator: "\n")
    }
    @MainActor func run(_ urls: [URL]) {
        switch self {
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        case .paths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .duplicate:
            JobRunner.shared.run(title: "Duplicate", detail: "\(urls.count) files") { _ in
                try Self.duplicateFiles(urls)
            }
        case .hash:
            Task {
                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try Self.hashReport(urls)
                    }.value
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    let alert = NSAlert()
                    alert.messageText = "SHA-256 copied"
                    alert.informativeText = report
                    alert.runModal()
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}


// Open Tangerine / Tools/Images/CreatePDFCollageToolViews.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OrderedFileList: View {
    @Binding var files: [URL]
    var thumbnails: [URL: NSImage] = [:]
    var allowedTypes: [UTType] = [.image]
    var addTitle = "Add images…"

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(files.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        if let thumb = thumbnails[url] {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(FileSizeFormatter.string(FileSizeFormatter.size(of: url))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == files.count - 1)
                        Button { files.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.disabled(files.count <= 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .onMove { from, to in files.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button(addTitle) { add() }
                Button("Sort by name") { files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
                Spacer()
                Text("Drag rows to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !files.contains(url) { files.append(url) }
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    @Published var images: [URL: NSImage] = [:]

    func load(_ urls: [URL], maxPixels: Int = 320) {
        for url in urls where images[url] == nil {
            Task.detached { [url] in
                guard let cg = try? ImageIOBridge.load(url, maxPixelSize: maxPixels) else { return }
                let ns = ImageOps.nsImage(cg)
                await MainActor.run { self.images[url] = ns }
            }
        }
    }
}

@MainActor
struct CreatePDFToolView: View {
    let session: ToolSession
    @HCState private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    @HCState private var pageMode: PageMode = .fitImage

    enum PageMode: String, CaseIterable, Identifiable {
        case fitImage, letter, a4
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fitImage: return "Page per image size"
            case .letter: return "US Letter"
            case .a4: return "A4"
            }
        }
        var size: CGSize? {
            switch self {
            case .fitImage: return nil
            case .letter: return CGSize(width: 612, height: 792)
            case .a4: return CGSize(width: 595, height: 842)
            }
        }
    }

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Create PDF", saveEnabled: !files.isEmpty, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs.images)
        } sidebar: {
            SidebarSection(title: "Pages") {
                Picker("", selection: $pageMode) {
                    ForEach(PageMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text("One page per image, in list order. HEIC, WebP, SVG and other formats are rasterized as needed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Summary") {
                Text("\(files.count) page\(files.count == 1 ? "" : "s")").font(.callout)
            }
        }
        .onAppear { thumbs.load(files) }
        .onChange(of: files) { thumbs.load($0) }
    }

    private func save() {
        let files = files
        let pageSize = pageMode.size
        let destination = session.outputURL(suffix: files.count > 1 ? "combined" : "", ext: "pdf")
        session.run(title: "Creating PDF", detail: "\(files.count) image\(files.count == 1 ? "" : "s")") { progress in
            if let pageSize {
                try PDFRenderer.writeImagesPDF(files, pageSize: pageSize, to: destination, progress: progress)
            } else {
                try PDFOps.fromImages(files, to: destination, progress: progress)
            }
            return [destination]
        }
    }
}

@MainActor
struct CollageToolView: View {
    let session: ToolSession
    @HCState private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    @HCState private var layout: ImageOps.CollageLayout = .grid
    @HCState private var width = 2400
    @HCState private var height = 2400
    @HCState private var spacing: Double = 24
    @HCState private var corner: Double = 16
    @HCState private var background = Color.white
    @HCState private var preview: NSImage?
    @HCState private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var options: ImageOps.CollageOptions {
        var o = ImageOps.CollageOptions()
        o.layout = layout
        o.width = CGFloat(max(64, width))
        o.height = CGFloat(max(64, height))
        o.spacing = spacing
        o.cornerRadius = corner
        o.background = background.nsColor
        return o
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save collage", saveEnabled: files.count >= 2, onSave: save) {
            HSplitView {
                OrderedFileList(files: $files, thumbnails: thumbs.images)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                ZStack {
                    CheckerboardBackground()
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(16)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 320)
            }
        } sidebar: {
            SidebarSection(title: "Layout") {
                Picker("", selection: $layout) {
                    ForEach(ImageOps.CollageLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Final size") {
                NumberField(title: "Width", value: $width, suffix: "px")
                NumberField(title: "Height", value: $height, suffix: "px")
                HStack {
                    Button("Square") { width = 2400; height = 2400 }
                    Button("Landscape") { width = 3000; height = 2000 }
                    Button("Portrait") { width = 2000; height = 3000 }
                }
                .controlSize(.mini)
            }
            SidebarSection(title: "Style") {
                LabeledSlider(title: "Spacing", value: $spacing, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: "Corner radius", value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                ColorSwatchPicker(title: "Background", color: $background)
            }
        }
        .onAppear { thumbs.load(files, maxPixels: 600); render() }
        .onChange(of: files) { thumbs.load($0, maxPixels: 600); render() }
        .onChange(of: thumbs.images.count) { _ in render() }
        .onChange(of: layout) { _ in render() }
        .onChange(of: width) { _ in render() }
        .onChange(of: height) { _ in render() }
        .onChange(of: spacing) { _ in render() }
        .onChange(of: corner) { _ in render() }
        .onChange(of: background) { _ in render() }
    }

    private func render() {
        renderTask?.cancel()
        let images = files.compactMap { thumbs.images[$0]?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard !images.isEmpty else { return }
        var scaled = options
        let scale = min(1, 1200 / max(scaled.width, scaled.height))
        scaled.width *= scale
        scaled.height *= scale
        scaled.spacing *= scale
        scaled.cornerRadius *= scale
        let o = scaled
        renderTask = Task.detached(priority: .userInitiated) {
            guard let cg = ImageOps.collage(images, options: o), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { preview = ns }
        }
    }

    private func save() {
        let files = files
        let o = options
        ImageToolSupport.save(session, suffix: "collage", format: .jpg, title: "Creating collage") {
            let images = try files.map { try ImageIOBridge.load($0, maxPixelSize: 4000) }
            guard let cg = ImageOps.collage(images, options: o) else { throw OpenTangerineError.encodeFailed("Collage rendering failed") }
            return cg
        }
    }
}



// Open Tangerine / Tools/Images/CropImageToolView.swift
import AppKit
import SwiftUI

@MainActor
struct CropImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @HCState private var rects: [RectangleOverlay] = []
    @HCState private var selected: UUID?
    @HCState private var aspect = AspectPreset.all[0]
    @HCState private var width = 0
    @HCState private var height = 0

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary))
    }

    private var cropRect: CGRect? { rects.first?.rect }

    private var aspectRatio: CGFloat? {
        guard let ratio = aspect.ratio else { return nil }
        if ratio < 0, document.size.height > 0 { return document.size.width / document.size.height }
        return ratio
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: cropRect.map { $0.width >= 1 && $0.height >= 1 } ?? false, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    RectangleEditorCanvas(image: preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: false, aspect: aspectRatio)
                        .padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("", selection: $aspect) {
                    ForEach(AspectPreset.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: "Dimensions") {
                NumberField(title: "Width", value: $width, suffix: "px")
                NumberField(title: "Height", value: $height, suffix: "px")
                Text("Original: \(Int(document.size.width)) × \(Int(document.size.height))").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Center") { centerCrop() }
                    Button("Whole image") { setCrop(CGRect(origin: .zero, size: document.size)) }
                }
                .controlSize(.small)
            }
            SidebarSection(title: "How to") {
                Text("Drag on the photo to draw the crop. Drag the corners to resize, or type pixel dimensions. The copy is saved at full resolution.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: rects) { new in
            guard let rect = new.first?.rect else { return }
            let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
            if w != width { width = w }
            if h != height { height = h }
        }
        .onChange(of: width) { _ in applyDimensions() }
        .onChange(of: height) { _ in applyDimensions() }
        .onChange(of: aspect) { _ in applyAspect() }
        .onChange(of: document.preview) { _ in
            if rects.isEmpty { setCrop(CGRect(origin: .zero, size: document.size).insetBy(dx: document.size.width * 0.1, dy: document.size.height * 0.1)) }
        }
    }

    private func setCrop(_ rect: CGRect) {
        let clamped = rect.intersection(CGRect(origin: .zero, size: document.size)).integral
        if let first = rects.first {
            rects = [RectangleOverlay(id: first.id, rect: clamped, color: Theme.accent, label: "")]
        } else {
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: clamped, color: Theme.accent, label: "")]
            selected = id
        }
    }

    private func applyDimensions() {
        guard let rect = cropRect, width > 0, height > 0 else { return }
        if Int(rect.width.rounded()) == width, Int(rect.height.rounded()) == height { return }
        var new = CGRect(x: rect.minX, y: rect.minY, width: CGFloat(width), height: CGFloat(height))
        new.origin.x = min(new.minX, max(0, document.size.width - new.width))
        new.origin.y = min(new.minY, max(0, document.size.height - new.height))
        setCrop(new)
    }

    private func applyAspect() {
        guard let ratio = aspectRatio, let rect = cropRect else { return }
        var new = rect
        new.size.height = rect.width / ratio
        if new.maxY > document.size.height {
            new.size.height = document.size.height - rect.minY
            new.size.width = new.height * ratio
        }
        setCrop(new)
    }

    private func centerCrop() {
        guard let rect = cropRect else { return }
        setCrop(CGRect(x: (document.size.width - rect.width) / 2, y: (document.size.height - rect.height) / 2, width: rect.width, height: rect.height))
    }

    private func save() {
        guard let original = document.original, let rect = cropRect else { return }
        ImageToolSupport.save(session, suffix: "cropped") {
            ImageIOBridge.cropped(original, to: rect.integral)
        }
    }
}

extension RectangleOverlay: Equatable {
    static func == (lhs: RectangleOverlay, rhs: RectangleOverlay) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.label == rhs.label
    }
}



// Open Tangerine / Tools/Images/EditImageToolView.swift
import CoreImage
import SwiftUI

@MainActor
struct EditImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @HCState private var adjustments = PhotoAdjustments()
    @HCState private var rendered: NSImage?
    @HCState private var showOriginal = false
    @HCState private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1800))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let image = (showOriginal ? document.preview : rendered) ?? document.preview {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(showOriginal ? "Showing original" : "Hold to compare") {}
                            .buttonStyle(.bordered)
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in showOriginal = true }.onEnded { _ in showOriginal = false })
                            .padding(12)
                    }
                }
            }
        } sidebar: {
            SidebarSection(title: "Light") {
                LabeledSlider(title: "Exposure", value: $adjustments.exposure, range: -2...2)
                LabeledSlider(title: "Brightness", value: $adjustments.brightness, range: -0.5...0.5)
                LabeledSlider(title: "Contrast", value: $adjustments.contrast, range: 0.5...1.5)
                LabeledSlider(title: "Highlights", value: $adjustments.highlights, range: 0.3...1)
                LabeledSlider(title: "Shadows", value: $adjustments.shadows, range: -1...1)
            }
            SidebarSection(title: "Color") {
                LabeledSlider(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                LabeledSlider(title: "Vibrance", value: $adjustments.vibrance, range: -1...1)
                LabeledSlider(title: "Temperature", value: $adjustments.temperature, range: 3000...10000) { String(format: "%.0fK", $0) }
                LabeledSlider(title: "Tint", value: $adjustments.tint, range: -100...100) { String(format: "%.0f", $0) }
                Toggle("Monochrome", isOn: $adjustments.monochrome)
                LabeledSlider(title: "Sepia", value: $adjustments.sepia, range: 0...1)
            }
            SidebarSection(title: "Detail") {
                LabeledSlider(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
                LabeledSlider(title: "Clarity", value: $adjustments.clarity, range: 0...1)
                LabeledSlider(title: "Dehaze", value: $adjustments.dehaze, range: 0...1)
                LabeledSlider(title: "Noise reduction", value: $adjustments.noiseReduction, range: 0...1)
            }
            SidebarSection(title: "Effects") {
                LabeledSlider(title: "Grain", value: $adjustments.grain, range: 0...1)
                LabeledSlider(title: "Vignette", value: $adjustments.vignette, range: 0...2)
            }
            Button("Reset all") { adjustments = PhotoAdjustments() }
                .buttonStyle(.link)
        }
        .onChange(of: adjustments) { _ in scheduleRender() }
        .onChange(of: document.preview) { _ in scheduleRender() }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let adjustments = adjustments
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.adjusted(CIImage(cgImage: cg), adjustments)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func save() {
        guard let original = document.original else { return }
        let adjustments = adjustments
        ImageToolSupport.save(session, suffix: "edited") {
            let output = ImageOps.adjusted(CIImage(cgImage: original), adjustments)
            guard let image = ImageToolSupport.cgImage(output) else { throw OpenTangerineError.encodeFailed("Rendering failed") }
            return image
        }
    }
}



// Open Tangerine / Tools/Images/FrameImageToolView.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FrameImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @HCState private var backgroundKind: Kind = .color
    @HCState private var color = Color.white
    @HCState private var gradientA = Color(red: 1.0, green: 0.6, blue: 0.2)
    @HCState private var gradientB = Color(red: 0.95, green: 0.25, blue: 0.45)
    @HCState private var gradientAngle: Double = 45
    @HCState private var backgroundImageURL: URL?
    @HCState private var backgroundImage: CGImage?
    @HCState private var backgroundBlur: Double = 30
    @HCState private var aspect = AspectPreset.all[1]
    @HCState private var padding: Double = 0.08
    @HCState private var corner: Double = 24
    @HCState private var shadow: Double = 24
    @HCState private var rendered: NSImage?
    @HCState private var renderTask: Task<Void, Never>?

    enum Kind: String, CaseIterable, Identifiable {
        case color, gradient, image
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1400))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let rendered {
                    Image(nsImage: rendered).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Background") {
                Picker("", selection: $backgroundKind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch backgroundKind {
                case .color:
                    ColorSwatchPicker(title: "Color", color: $color)
                case .gradient:
                    ColorSwatchPicker(title: "Start", color: $gradientA)
                    ColorSwatchPicker(title: "End", color: $gradientB)
                    LabeledSlider(title: "Angle", value: $gradientAngle, range: 0...360) { String(format: "%.0f°", $0) }
                case .image:
                    HStack {
                        Text(backgroundImageURL?.lastPathComponent ?? "Same photo, blurred").font(.callout).lineLimit(1)
                        Spacer()
                        Button("Choose…") { chooseBackground() }
                    }
                    LabeledSlider(title: "Blur", value: $backgroundBlur, range: 0...100) { String(format: "%.0f", $0) }
                }
            }
            SidebarSection(title: "Canvas") {
                Picker("Aspect ratio", selection: $aspect) {
                    ForEach(AspectPreset.all.filter { $0.ratio != nil }) { Text($0.title).tag($0) }
                }
                LabeledSlider(title: "Spacing", value: $padding, range: 0...0.3) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: "Corner radius", value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: "Shadow", value: $shadow, range: 0...120) { String(format: "%.0f", $0) }
            }
        }
        .onChange(of: document.preview) { _ in scheduleRender() }
        .onChange(of: backgroundKind) { _ in scheduleRender() }
        .onChange(of: color) { _ in scheduleRender() }
        .onChange(of: gradientA) { _ in scheduleRender() }
        .onChange(of: gradientB) { _ in scheduleRender() }
        .onChange(of: gradientAngle) { _ in scheduleRender() }
        .onChange(of: backgroundBlur) { _ in scheduleRender() }
        .onChange(of: aspect) { _ in scheduleRender() }
        .onChange(of: padding) { _ in scheduleRender() }
        .onChange(of: corner) { _ in scheduleRender() }
        .onChange(of: shadow) { _ in scheduleRender() }
        .onChange(of: backgroundImageURL) { _ in scheduleRender() }
    }

    private func options(scale: CGFloat, source: CGImage) -> ImageOps.FrameOptions {
        var options = ImageOps.FrameOptions()
        if let ratio = aspect.ratio {
            options.aspect = ratio < 0 ? CGSize(width: source.width, height: source.height) : CGSize(width: ratio, height: 1)
        }
        options.padding = padding
        options.cornerRadius = corner * scale
        options.shadow = shadow * scale
        switch backgroundKind {
        case .color: options.background = .color(color.nsColor)
        case .gradient: options.background = .gradient(gradientA.nsColor, gradientB.nsColor, angle: gradientAngle)
        case .image: options.background = .image(backgroundImage ?? source, blur: backgroundBlur * scale)
        }
        return options
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), let original = document.original else { return }
        let scale = CGFloat(cg.width) / CGFloat(original.width)
        let opts = options(scale: scale, source: cg)
        renderTask = Task.detached(priority: .userInitiated) {
            guard let framed = ImageOps.framed(cg, options: opts), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(framed)
            await MainActor.run { rendered = ns }
        }
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageIOBridge.load(url, maxPixelSize: 3000) else { return }
        backgroundImageURL = url
        backgroundImage = image
    }

    private func save() {
        guard let original = document.original else { return }
        let opts = options(scale: 1, source: original)
        let format: FileFormat = backgroundKind == .color && color.nsColor.alphaComponent >= 1 ? ImageToolSupport.outputFormat(for: session.primary) : .png
        ImageToolSupport.save(session, suffix: "framed", format: format) {
            guard let framed = ImageOps.framed(original, options: opts) else { throw OpenTangerineError.encodeFailed("Rendering failed") }
            return framed
        }
    }
}



// Open Tangerine / Tools/Images/ImageToolSupport.swift
import AppKit
import CoreImage
import SwiftUI

enum ImageToolSupport {
    static func outputFormat(for source: URL) -> FileFormat {
        let format = FileFormat.detect(source) ?? .png
        switch format {
        case .svg, .bmp: return .png
        case .avif, .webp: return ImageIOBridge.canEncodeNatively(format) ? format : .png
        default: return format
        }
    }

    @MainActor
    static func save(_ session: ToolSession, suffix: String, format: FileFormat? = nil, title: String? = nil, render: @escaping () async throws -> CGImage) {
        let output = format ?? outputFormat(for: session.primary)
        let destination = session.outputURL(suffix: suffix, ext: output.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        let metadata = ImageIOBridge.properties(session.primary)
        session.run(title: title ?? session.tool.progressTitle, detail: session.primary.lastPathComponent) { progress in
            let image = try await render()
            progress(0.7)
            if ImageIOBridge.canEncodeNatively(output) {
                var keep: [CFString: Any] = [:]
                if let exif = metadata[kCGImagePropertyExifDictionary] { keep[kCGImagePropertyExifDictionary] = exif }
                if let tiff = metadata[kCGImagePropertyTIFFDictionary] { keep[kCGImagePropertyTIFFDictionary] = tiff }
                try ImageIOBridge.write(image, to: destination, format: output, quality: quality, metadata: keep.isEmpty ? nil : keep)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: output, quality: quality)
            }
            return [destination]
        }
    }

    @MainActor
    static func saveEach(_ session: ToolSession, suffix: String, title: String, detail: String, render: @escaping (URL, CGImage) throws -> CGImage) {
        let files = session.files
        let quality = AppSettings.shared.jpegQuality
        let destinations = files.map { url -> (URL, FileFormat) in
            let output = outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: session.outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: suffix, ext: output.fileExtension), output)
        }
        session.run(title: title, detail: detail) { progress in
            var outputs: [URL] = []
            for (index, url) in files.enumerated() {
                let (destination, output) = destinations[index]
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let source = try ImageIOBridge.load(url)
                let result = try render(url, source)
                try await ImageIOBridge.writeAnyFormat(result, to: destination, format: output, quality: quality)
                outputs.append(destination)
                progress(Double(index + 1) / Double(files.count))
            }
            return outputs
        }
    }

    static func cgImage(_ ci: CIImage, context: CIContext = sharedContext) -> CGImage? {
        context.createCGImage(ci, from: ci.extent)
    }

    static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
}

struct AspectPreset: Identifiable, Hashable {
    let title: String
    let ratio: CGFloat?
    var id: String { title }

    static let all: [AspectPreset] = [
        AspectPreset(title: "Free", ratio: nil),
        AspectPreset(title: "Original", ratio: -1),
        AspectPreset(title: "Square", ratio: 1),
        AspectPreset(title: "4:3", ratio: 4 / 3),
        AspectPreset(title: "3:2", ratio: 3 / 2),
        AspectPreset(title: "16:9", ratio: 16 / 9),
        AspectPreset(title: "9:16", ratio: 9 / 16),
        AspectPreset(title: "3:4", ratio: 3 / 4),
        AspectPreset(title: "2:3", ratio: 2 / 3),
        AspectPreset(title: "5:4", ratio: 5 / 4),
    ]
}

struct ColorSwatchPicker: View {
    let title: String
    @Binding var color: Color

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
        }
    }
}



// Open Tangerine / Tools/Images/RedactImageToolView.swift
import CoreImage
import SwiftUI

@MainActor
struct RedactImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @HCState private var rects: [RectangleOverlay] = []
    @HCState private var selected: UUID?
    @HCState private var styles: [UUID: RedactionStyle] = [:]
    @HCState private var defaultStyle: RedactionStyle = .solid
    @HCState private var color = Color.black
    @HCState private var showPreview = false
    @HCState private var rendered: NSImage?
    @HCState private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 2000))
    }

    private var redactions: [Redaction] {
        rects.map { overlay in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            r.color = color.nsColor.cgColor
            return r
        }
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: !rects.isEmpty, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    if showPreview, let rendered {
                        GeometryReader { proxy in
                            let fit = FitGeometry(container: proxy.size, image: document.size)
                            Image(nsImage: rendered).resizable().interpolation(.high)
                                .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                                .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                        }
                        .padding(12)
                    } else {
                        RectangleEditorCanvas(image: preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: true)
                            .padding(12)
                    }
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Redaction style") {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if (selected.flatMap { styles[$0] } ?? defaultStyle) == .solid {
                    ColorSwatchPicker(title: "Color", color: $color)
                }
                Text(selected == nil ? "Applies to new areas." : "Applies to the selected area.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Areas (\(rects.count))") {
                if rects.isEmpty {
                    Text("Drag on the photo to cover an area. Drag areas to move them and their corners to resize.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("Area \(overlay.label)").font(.callout)
                        Text((styles[overlay.id] ?? defaultStyle).title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { remove(overlay.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
                if !rects.isEmpty {
                    Button("Remove all") { rects.removeAll(); styles.removeAll(); selected = nil }.controlSize(.small)
                }
            }
            SidebarSection(title: "Preview") {
                Toggle("Show result", isOn: $showPreview)
            }
        }
        .onChange(of: rects) { _ in relabel(); scheduleRender() }
        .onChange(of: styles) { _ in scheduleRender() }
        .onChange(of: color) { _ in scheduleRender() }
        .onChange(of: defaultStyle) { _ in scheduleRender() }
        .onChange(of: showPreview) { _ in scheduleRender() }
        .onDeleteCommand { if let selected { remove(selected) } }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { selected.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in
                if let selected { styles[selected] = new } else { defaultStyle = new }
                scheduleRender()
            }
        )
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        styles.removeValue(forKey: id)
        if selected == id { selected = nil }
    }

    private func relabel() {
        for index in rects.indices where rects[index].label != "\(index + 1)" {
            rects[index].label = "\(index + 1)"
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard showPreview, let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), document.size.width > 0 else { return }
        let scale = CGFloat(cg.width) / document.size.width
        let scaled = redactions.map { r -> Redaction in
            var copy = r
            copy.rect = r.rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            return copy
        }
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.redact(CIImage(cgImage: cg), redactions: scaled)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func save() {
        guard let original = document.original else { return }
        let redactions = redactions
        ImageToolSupport.save(session, suffix: "redacted") {
            let output = ImageOps.redact(CIImage(cgImage: original), redactions: redactions)
            guard let image = ImageToolSupport.cgImage(output) else { throw OpenTangerineError.encodeFailed("Rendering failed") }
            return image
        }
    }
}



// Open Tangerine / Tools/Images/ResizeRotateToolViews.swift
import AppKit
import SwiftUI

@MainActor
struct ResizeImageToolView: View {
    let session: ToolSession
    @HCState private var mode: Mode = .longEdge
    @HCState private var longEdge = 1920
    @HCState private var percent = 50
    @HCState private var width = 0
    @HCState private var height = 0
    @HCState private var lockAspect = true
    @HCState private var sizes: [URL: CGSize] = [:]

    enum Mode: String, CaseIterable, Identifiable {
        case longEdge, percent, exact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .longEdge: return "Long edge"
            case .percent: return "Percent"
            case .exact: return "Exact"
            }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Resize" : "Resize \(session.files.count) images", onSave: save) {
            List(session.files, id: \.self) { url in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).lineLimit(1)
                        if let size = sizes[url] {
                            let target = targetSize(for: size)
                            Text("\(Int(size.width)) × \(Int(size.height))  →  \(Int(target.width)) × \(Int(target.height))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } sidebar: {
            SidebarSection(title: "Resize by") {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .longEdge:
                    NumberField(title: "Long edge", value: $longEdge, suffix: "px")
                    HStack {
                        ForEach([640, 1080, 1920, 2560, 4096], id: \.self) { value in
                            Button("\(value)") { longEdge = value }.controlSize(.mini)
                        }
                    }
                case .percent:
                    NumberField(title: "Scale", value: $percent, suffix: "%")
                case .exact:
                    NumberField(title: "Width", value: $width, suffix: "px")
                    NumberField(title: "Height", value: $height, suffix: "px")
                    Toggle("Keep aspect ratio (fit inside)", isOn: $lockAspect)
                }
            }
            SidebarSection(title: "Notes") {
                Text("Images are never enlarged beyond the requested size with the long-edge mode. Output keeps the original format where it can be written natively.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            for url in session.files { sizes[url] = ImageIOBridge.pixelSize(url) }
            if let first = sizes[session.primary] { width = Int(first.width); height = Int(first.height) }
        }
    }

    private func targetSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        switch mode {
        case .longEdge:
            let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .percent:
            let scale = CGFloat(max(1, percent)) / 100
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .exact:
            let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
            if lockAspect {
                let scale = min(w / size.width, h / size.height)
                return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            }
            return CGSize(width: w, height: h)
        }
    }

    private func save() {
        let mode = mode, longEdge = longEdge, percent = percent, width = width, height = height, lockAspect = lockAspect
        ImageToolSupport.saveEach(session, suffix: "resized", title: "Resizing", detail: "\(session.files.count) image\(session.files.count == 1 ? "" : "s")") { _, image in
            let size = CGSize(width: image.width, height: image.height)
            let target: CGSize
            switch mode {
            case .longEdge:
                let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .percent:
                let scale = CGFloat(max(1, percent)) / 100
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .exact:
                let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
                if lockAspect {
                    let scale = min(w / size.width, h / size.height)
                    target = CGSize(width: size.width * scale, height: size.height * scale)
                } else {
                    target = CGSize(width: w, height: h)
                }
            }
            return ImageIOBridge.scaled(image, to: CGSize(width: max(1, target.width.rounded()), height: max(1, target.height.rounded())))
        }
    }
}

@MainActor
struct RotateImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @HCState private var quarterTurns = 0
    @HCState private var flipH = false
    @HCState private var flipV = false

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1600))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Save copy" : "Apply to \(session.files.count) images", saveEnabled: document.preview != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    Image(nsImage: preview)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(quarterTurns) * 90))
                        .scaleEffect(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
                        .padding(40)
                        .animation(.easeInOut(duration: 0.18), value: quarterTurns)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Rotate") {
                HStack {
                    Button { quarterTurns = (quarterTurns + 3) % 4 } label: { Label("Left", systemImage: "rotate.left") }
                    Button { quarterTurns = (quarterTurns + 1) % 4 } label: { Label("Right", systemImage: "rotate.right") }
                }
                Text("\(quarterTurns * 90)°").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Flip") {
                Toggle("Flip horizontally", isOn: $flipH)
                Toggle("Flip vertically", isOn: $flipV)
            }
            if session.files.count > 1 {
                SidebarSection(title: "Batch") {
                    Text("The same rotation and flips are applied to all \(session.files.count) images.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        let turns = quarterTurns, h = flipH, v = flipV
        ImageToolSupport.saveEach(session, suffix: "rotated", title: "Rotating", detail: "\(session.files.count) image\(session.files.count == 1 ? "" : "s")") { _, image in
            try ImageOps.rotated(image, quarterTurns: turns, flipHorizontal: h, flipVertical: v)
        }
    }
}



// Open Tangerine / Tools/PDF/PDFToolViews.swift
import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MergePDFToolView: View {
    let session: ToolSession
    @HCState private var files: [URL]
    @HCState private var thumbs: [URL: NSImage] = [:]
    @HCState private var pageCounts: [URL: Int] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Merge", saveEnabled: files.count >= 1, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.pdf], addTitle: "Add PDFs…")
        } sidebar: {
            SidebarSection(title: "Summary") {
                Text("\(files.count) document\(files.count == 1 ? "" : "s") · \(files.reduce(0) { $0 + (pageCounts[$1] ?? 0) }) pages").font(.callout.monospacedDigit())
                Text("Documents are merged in list order, starting with the Finder selection order. Password-protected PDFs are skipped with an error.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: files) {
            for url in files where thumbs[url] == nil {
                guard let doc = PDFDocument(url: url) else { continue }
                pageCounts[url] = doc.pageCount
                if let page = doc.page(at: 0) {
                    thumbs[url] = page.thumbnail(of: NSSize(width: 88, height: 88), for: .mediaBox)
                }
            }
        }
    }

    private func save() {
        let files = files
        let destination = session.outputURL(suffix: "merged", ext: "pdf")
        session.run(title: "Merging", detail: "\(files.count) PDFs") { _ in
            try PDFOps.merge(files, to: destination)
            return [destination]
        }
    }
}

@MainActor
struct SplitPDFToolView: View {
    let session: ToolSession
    @HCState private var mode: PDFOps.SplitMode = .everyPage
    @HCState private var every = 2
    @HCState private var ranges = ""
    @HCState private var pageCount = 0
    @HCState private var thumbnails: [NSImage] = []

    private var outputCount: Int {
        switch mode {
        case .everyPage: return pageCount
        case .everyN: return every > 0 ? Int(ceil(Double(pageCount) / Double(every))) : 0
        case .ranges: return PDFOps.parseRanges(ranges, pageCount: pageCount).count
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Split into \(outputCount) files", saveEnabled: outputCount > 0, onSave: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: 4) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 130)
                                .background(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(groupColor(for: index + 1), lineWidth: 2))
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        } sidebar: {
            SidebarSection(title: "Split") {
                Picker("", selection: $mode) {
                    ForEach(PDFOps.SplitMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                switch mode {
                case .everyPage:
                    EmptyView()
                case .everyN:
                    Stepper("Pages per file: \(every)", value: $every, in: 1...max(1, pageCount))
                case .ranges:
                    TextField("e.g. 1-3, 4, 5-8", text: $ranges).textFieldStyle(.roundedBorder)
                    Text("Comma-separated pages or ranges. Each entry becomes one file.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Summary") {
                Text("\(pageCount) pages → \(outputCount) file\(outputCount == 1 ? "" : "s")").font(.callout.monospacedDigit())
                Text("Output files are placed in one folder next to the original.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            guard let doc = PDFDocument(url: session.primary) else { return }
            pageCount = doc.pageCount
            ranges = "1-\(doc.pageCount)"
            thumbnails = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.thumbnail(of: NSSize(width: 220, height: 220), for: .mediaBox) }
        }
    }

    private func groupColor(for page: Int) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal]
        let group: Int
        switch mode {
        case .everyPage: group = page - 1
        case .everyN: group = (page - 1) / max(1, every)
        case .ranges:
            guard let index = PDFOps.parseRanges(ranges, pageCount: pageCount).firstIndex(where: { $0.contains(page) }) else { return .clear }
            group = index
        }
        return palette[group % palette.count]
    }

    private func save() {
        let url = session.primary, mode = mode, every = every, ranges = ranges
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) pages")
        session.run(title: "Splitting", detail: "\(url.lastPathComponent)") { _ in
            try PDFOps.split(url, mode: mode, every: every, ranges: ranges, into: folder)
        }
    }
}

@MainActor
struct OrganizePDFToolView: View {
    let session: ToolSession
    @HCState private var pages: [PDFPageRef] = []
    @HCState private var thumbnails: [String: NSImage] = [:]
    @HCState private var selected: Set<UUID> = []
    @HCState private var error: String?

    private var sources: [URL] { session.files }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", saveEnabled: !pages.isEmpty, onSave: save) {
            if let error {
                LoadingOrError(error: error)
            } else if pages.isEmpty {
                ProgressView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(index: index, page: page, image: thumbnails[key(page)], selected: selected.contains(page.id), sourceLabel: sources.count > 1 ? page.sourceURL.lastPathComponent : nil)
                                .onTapGesture { toggle(page.id) }
                                .contextMenu {
                                    Button("Rotate left") { rotate([page.id], by: -90) }
                                    Button("Rotate right") { rotate([page.id], by: 90) }
                                    Button("Duplicate") { duplicate([page.id]) }
                                    Divider()
                                    Button("Move to start") { move(page.id, to: 0) }
                                    Button("Move to end") { move(page.id, to: pages.count) }
                                    Divider()
                                    Button("Remove", role: .destructive) { remove([page.id]) }
                                }
                                .onDrag { NSItemProvider(object: page.id.uuidString as NSString) }
                                .onDrop(of: [.plainText], delegate: PageDropDelegate(target: page.id, pages: $pages))
                        }
                    }
                    .padding(16)
                }
            }
        } sidebar: {
            SidebarSection(title: "Selection") {
                Text(selected.isEmpty ? "Click pages to select. Drag to reorder." : "\(selected.count) selected").font(.callout)
                HStack {
                    Button("All") { selected = Set(pages.map(\.id)) }
                    Button("None") { selected.removeAll() }
                }
                .controlSize(.small)
            }
            SidebarSection(title: "Pages") {
                let targets = selected.isEmpty ? pages.map(\.id) : Array(selected)
                HStack {
                    Button { rotate(targets, by: -90) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { rotate(targets, by: 90) } label: { Label("Right", systemImage: "rotate.right") }
                }
                Button("Duplicate") { duplicate(targets) }.disabled(selected.isEmpty)
                Button("Remove", role: .destructive) { remove(targets) }.disabled(selected.isEmpty || selected.count == pages.count)
                Button("Reverse order") { pages.reverse() }
            }
            SidebarSection(title: "Summary") {
                Text("\(pages.count) page\(pages.count == 1 ? "" : "s")").font(.callout.monospacedDigit())
                if sources.count > 1 {
                    Text("Pages from \(sources.count) documents are combined into one.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task { load() }
        .onDeleteCommand { if !selected.isEmpty { remove(Array(selected)) } }
    }

    private func key(_ page: PDFPageRef) -> String { "\(page.sourceURL.path)#\(page.sourceIndex)" }

    private func load() {
        var refs: [PDFPageRef] = []
        for url in sources {
            guard let doc = PDFDocument(url: url) else { error = "Could not open \(url.lastPathComponent)."; return }
            if doc.isLocked { error = "\(url.lastPathComponent) is password protected."; return }
            for index in 0..<doc.pageCount {
                let ref = PDFPageRef(sourceIndex: index, rotation: doc.page(at: index)?.rotation ?? 0, sourceURL: url)
                refs.append(ref)
                if let page = doc.page(at: index) {
                    thumbnails[key(ref)] = page.thumbnail(of: NSSize(width: 260, height: 260), for: .mediaBox)
                }
            }
        }
        pages = refs
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = selected == [id] ? [] : [id]
        }
    }

    private func rotate(_ ids: [UUID], by degrees: Int) {
        for index in pages.indices where ids.contains(pages[index].id) {
            pages[index].rotation = ((pages[index].rotation + degrees) % 360 + 360) % 360
        }
    }

    private func duplicate(_ ids: [UUID]) {
        var result: [PDFPageRef] = []
        for page in pages {
            result.append(page)
            if ids.contains(page.id) {
                result.append(PDFPageRef(sourceIndex: page.sourceIndex, rotation: page.rotation, sourceURL: page.sourceURL))
            }
        }
        pages = result
    }

    private func remove(_ ids: [UUID]) {
        guard pages.count > ids.count else { return }
        pages.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
    }

    private func move(_ id: UUID, to index: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(index > from ? index - 1 : index, pages.count))
    }

    private func save() {
        let pages = pages
        let destination = session.outputURL(suffix: "organized", ext: "pdf")
        session.run(title: "Organizing", detail: "\(session.primary.lastPathComponent)") { _ in
            try PDFOps.assemble(pages: pages, to: destination)
            return [destination]
        }
    }
}

private struct PageCell: View {
    let index: Int
    let page: PDFPageRef
    let image: NSImage?
    let selected: Bool
    let sourceLabel: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.rotation)))
                        .padding(6)
                }
            }
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let sourceLabel {
                Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var pages: [PDFPageRef]

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let from = pages.firstIndex(where: { $0.id == id }), let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
                let page = pages.remove(at: from)
                pages.insert(page, at: to)
            }
        }
        return true
    }
}



// Open Tangerine / Tools/Shared/ImageCanvas.swift
import AppKit
import SwiftUI

struct FitGeometry {
    let container: CGSize
    let image: CGSize

    var scale: CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(container.width / image.width, container.height / image.height, 1000)
    }

    var displayRect: CGRect {
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        let rect = displayRect
        return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    func toImage(_ rect: CGRect) -> CGRect {
        let origin = toImage(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / scale, height: rect.height / scale)
    }

    func toDisplay(_ rect: CGRect) -> CGRect {
        let display = displayRect
        return CGRect(x: display.minX + rect.minX * scale, y: display.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    func clampToImage(_ rect: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: image)
        var result = rect.standardized.intersection(bounds)
        if result.isNull { result = .zero }
        return result
    }
}

struct RectangleOverlay: Identifiable {
    let id: UUID
    var rect: CGRect
    var color: Color
    var label: String
}

struct RectangleEditorCanvas: View {
    let image: NSImage
    let imageSize: CGSize
    @Binding var rectangles: [RectangleOverlay]
    @Binding var selected: UUID?
    var allowMultiple = true
    var aspect: CGFloat? = nil
    var minimumSize: CGFloat = 8

    @HCState private var dragStart: CGPoint?
    @HCState private var dragMode: DragMode = .none
    @HCState private var originalRect: CGRect = .zero

    private enum DragMode {
        case none
        case create(UUID)
        case move(UUID)
        case resize(UUID, corner: Int)
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = FitGeometry(container: proxy.size, image: imageSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                    .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                ForEach(rectangles) { overlay in
                    let display = fit.toDisplay(overlay.rect)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(overlay.color.opacity(overlay.id == selected ? 0.35 : 0.22))
                        Rectangle()
                            .strokeBorder(overlay.color, lineWidth: overlay.id == selected ? 2 : 1)
                        if !overlay.label.isEmpty {
                            Text(overlay.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(overlay.color, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .offset(x: 2, y: 2)
                        }
                        if overlay.id == selected {
                            ForEach(0..<4, id: \.self) { corner in
                                Circle()
                                    .fill(Color.white)
                                    .overlay(Circle().stroke(overlay.color, lineWidth: 1.5))
                                    .frame(width: 10, height: 10)
                                    .position(cornerPoint(corner, in: CGRect(origin: .zero, size: display.size)))
                            }
                        }
                    }
                    .frame(width: max(display.width, 1), height: max(display.height, 1))
                    .offset(x: display.minX, y: display.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in handleChanged(value, fit: fit) }
                    .onEnded { value in handleEnded(value, fit: fit) }
            )
        }
    }

    private func cornerPoint(_ corner: Int, in rect: CGRect) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    private func handleChanged(_ value: DragGesture.Value, fit: FitGeometry) {
        let current = fit.toImage(value.location)
        if dragStart == nil {
            let start = fit.toImage(value.startLocation)
            dragStart = start
            if let selectedID = selected, let overlay = rectangles.first(where: { $0.id == selectedID }) {
                let handle = 12 / fit.scale
                for corner in 0..<4 {
                    let point = cornerPoint(corner, in: overlay.rect)
                    if abs(point.x - start.x) < handle, abs(point.y - start.y) < handle {
                        dragMode = .resize(selectedID, corner: corner)
                        originalRect = overlay.rect
                        return
                    }
                }
            }
            if let hit = rectangles.last(where: { $0.rect.insetBy(dx: -4 / fit.scale, dy: -4 / fit.scale).contains(start) }) {
                selected = hit.id
                dragMode = .move(hit.id)
                originalRect = hit.rect
                return
            }
            let id = UUID()
            if !allowMultiple { rectangles.removeAll() }
            rectangles.append(RectangleOverlay(id: id, rect: CGRect(origin: start, size: .zero), color: Theme.accent, label: allowMultiple ? "\(rectangles.count + 1)" : ""))
            selected = id
            dragMode = .create(id)
            return
        }
        guard let start = dragStart else { return }
        switch dragMode {
        case .create(let id):
            var rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            if let aspect, aspect > 0 {
                let width = rect.width
                let height = width / aspect
                rect = CGRect(x: rect.minX, y: current.y < start.y ? start.y - height : start.y, width: width, height: height)
            }
            update(id, fit.clampToImage(rect))
        case .move(let id):
            var rect = originalRect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
            rect.origin.x = min(max(0, rect.minX), imageSize.width - rect.width)
            rect.origin.y = min(max(0, rect.minY), imageSize.height - rect.height)
            update(id, rect)
        case .resize(let id, let corner):
            var rect = originalRect
            switch corner {
            case 0: rect = CGRect(x: current.x, y: current.y, width: rect.maxX - current.x, height: rect.maxY - current.y)
            case 1: rect = CGRect(x: rect.minX, y: current.y, width: current.x - rect.minX, height: rect.maxY - current.y)
            case 2: rect = CGRect(x: rect.minX, y: rect.minY, width: current.x - rect.minX, height: current.y - rect.minY)
            default: rect = CGRect(x: current.x, y: rect.minY, width: rect.maxX - current.x, height: current.y - rect.minY)
            }
            rect = rect.standardized
            if let aspect, aspect > 0 {
                let height = rect.width / aspect
                rect = CGRect(x: rect.minX, y: corner < 2 ? rect.maxY - height : rect.minY, width: rect.width, height: height)
            }
            update(id, fit.clampToImage(rect))
        case .none:
            break
        }
    }

    private func update(_ id: UUID, _ rect: CGRect) {
        guard let index = rectangles.firstIndex(where: { $0.id == id }) else { return }
        rectangles[index].rect = rect
    }

    private func handleEnded(_ value: DragGesture.Value, fit: FitGeometry) {
        if case .create(let id) = dragMode, let index = rectangles.firstIndex(where: { $0.id == id }) {
            let rect = rectangles[index].rect
            if rect.width < minimumSize || rect.height < minimumSize {
                rectangles.remove(at: index)
                let point = fit.toImage(value.startLocation)
                selected = rectangles.last(where: { $0.rect.contains(point) })?.id
            }
        }
        dragStart = nil
        dragMode = .none
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let dark = (row + col) % 2 == 0
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(dark ? Color(white: 0.22) : Color(white: 0.26)))
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
    }
}

@MainActor
final class ImageDocument: ObservableObject {
    @Published var original: CGImage?
    @Published var preview: NSImage?
    @Published var error: String?
    let url: URL

    var size: CGSize {
        guard let original else { return .zero }
        return CGSize(width: original.width, height: original.height)
    }

    init(url: URL, previewMaxPixels: Int? = 2400) {
        self.url = url
        Task.detached { [url] in
            do {
                let full = try ImageIOBridge.load(url)
                let previewImage = previewMaxPixels.map { ImageIOBridge.resized(full, longEdge: $0) } ?? full
                await MainActor.run {
                    self.original = full
                    self.preview = ImageOps.nsImage(previewImage)
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

struct LoadingOrError: View {
    let error: String?

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).font(.largeTitle).foregroundStyle(Theme.accent)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}



// Open Tangerine / Tools/Shared/MediaPlayer.swift
import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class MediaController: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var info = MediaInfo()
    @Published var loaded = false
    @Published var waveform: [Float] = []
    private var observer: Any?
    private var endObserver: Any?
    private var boundaryObserver: Any?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.isPlaying = self.player.rate != 0
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
        Task {
            let info = await MediaInfo.load(url)
            self.info = info
            self.duration = info.duration
            self.loaded = true
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func loadWaveform(buckets: Int = 600) {
        Task.detached { [url] in
            let samples = await AudioOps.waveform(url, buckets: buckets)
            await MainActor.run { self.waveform = samples }
        }
    }

    func seek(_ seconds: Double, exact: Bool = true) {
        let time = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        if exact {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
        currentTime = CMTimeGetSeconds(time)
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.01 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() { player.pause(); isPlaying = false }

    func stepFrame(_ delta: Int) {
        pause()
        if let item = player.currentItem, (delta > 0 ? item.canStepForward : item.canStepBackward) {
            item.step(byCount: delta)
            currentTime = CMTimeGetSeconds(item.currentTime())
        } else {
            let frame = info.frameRate > 0 ? 1 / info.frameRate : 1 / 30
            seek(currentTime + Double(delta) * frame)
        }
    }

    func playRange(_ start: Double, _ end: Double) {
        seek(start)
        player.play()
        isPlaying = true
        let boundary = CMTime(seconds: end, preferredTimescale: 600)
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
            guard let self else { return }
            self.pause()
            if let token = self.boundaryObserver {
                self.player.removeTimeObserver(token)
                self.boundaryObserver = nil
            }
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.showsFrameSteppingButtons = true
        view.allowsPictureInPicturePlayback = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct VideoStage<Footer: View>: View {
    let player: AVPlayer
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: player)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 10) {
                footer()
            }
            .padding(12)
        }
    }
}

struct TransportBar: View {
    @ObservedObject var controller: MediaController
    var showFrameSteps = true

    var body: some View {
        HStack(spacing: 10) {
            if showFrameSteps {
                Button { controller.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
                    .help("Previous frame")
            }
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            if showFrameSteps {
                Button { controller.stepFrame(1) } label: { Image(systemName: "forward.frame") }
                    .help("Next frame")
            }
            Text(TimeFormatter.clock(controller.currentTime))
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Slider(value: Binding(get: { controller.currentTime }, set: { controller.seek($0, exact: false) }), in: 0...max(controller.duration, 0.01))
            Text(TimeFormatter.clock(controller.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}

struct RangeTrack: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var playhead: Double = 0
    var waveform: [Float] = []
    var markers: [Double] = []
    var onScrub: ((Double) -> Void)? = nil

    @HCState private var dragging: Handle?
    private enum Handle { case start, end, playhead }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                if !waveform.isEmpty {
                    WaveformShape(samples: waveform).fill(Color.secondary.opacity(0.45))
                }
                Rectangle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: max(0, x(end, width) - x(start, width)))
                    .offset(x: x(start, width))
                ForEach(markers.indices, id: \.self) { index in
                    Rectangle().fill(Color.blue).frame(width: 2).offset(x: x(markers[index], width) - 1)
                }
                handle(x: x(start, width), height: height, color: Theme.accent)
                handle(x: x(end, width), height: height, color: Theme.accent)
                Rectangle().fill(Color.white).frame(width: 2).offset(x: x(playhead, width) - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = t(value.location.x, width)
                        if dragging == nil {
                            let sx = x(start, width), ex = x(end, width)
                            if abs(value.startLocation.x - sx) < 10 { dragging = .start }
                            else if abs(value.startLocation.x - ex) < 10 { dragging = .end }
                            else { dragging = .playhead }
                        }
                        switch dragging {
                        case .start: start = min(time, end - 0.05)
                        case .end: end = max(time, start + 0.05)
                        case .playhead: onScrub?(time)
                        case nil: break
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 56)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func t(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * duration), duration)
    }

    private func handle(x: CGFloat, height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 8, height: height)
            .offset(x: x - 4)
    }
}

struct WaveformShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let step = rect.width / CGFloat(samples.count)
        let mid = rect.midY
        for (index, sample) in samples.enumerated() {
            let h = max(1, CGFloat(sample) * rect.height * 0.95)
            path.addRect(CGRect(x: rect.minX + CGFloat(index) * step, y: mid - h / 2, width: max(1, step - 1), height: h))
        }
        return path
    }
}



// Open Tangerine / Tools/ToolID.swift
import Foundation

enum ToolArity {
    case single
    case multiple
    case any
}

enum ToolID: String, CaseIterable, Identifiable {
    case compress
    case editMetadata
    case editImage
    case frameImage
    case cropImage
    case redactImage
    case resizeImage
    case rotateImage
    case createPDF
    case createCollage
    case trimVideo
    case cropVideo
    case changeVideoSpeed
    case joinVideos
    case videoSnapshots
    case splitVideo
    case redactVideo
    case normalizeAudio
    case audioToVideo
    case trimAudio
    case audioChannels
    case redactAudio
    case mergePDF
    case organizePDF
    case splitPDF
    case cropPDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .editMetadata: return "Edit metadata"
        case .editImage: return "Edit photo"
        case .frameImage: return "Add a background"
        case .cropImage: return "Crop image"
        case .redactImage: return "Redact photo"
        case .resizeImage: return "Resize images"
        case .rotateImage: return "Rotate & flip"
        case .createPDF: return "Create a PDF"
        case .createCollage: return "Create a collage"
        case .trimVideo: return "Trim video"
        case .cropVideo: return "Crop video"
        case .changeVideoSpeed: return "Change video speed"
        case .joinVideos: return "Join videos"
        case .videoSnapshots: return "Save video frames"
        case .splitVideo: return "Split video"
        case .redactVideo: return "Redact video"
        case .normalizeAudio: return "Normalize volume"
        case .audioToVideo: return "Audio visualizer"
        case .trimAudio: return "Trim audio"
        case .audioChannels: return "Audio channels"
        case .redactAudio: return "Bleep audio"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Organize PDF pages"
        case .splitPDF: return "Split PDF"
        case .cropPDF: return "Crop PDF pages"
        }
    }

    var progressTitle: String {
        switch self {
        case .compress: return "Compressing"
        case .editMetadata: return "Editing metadata"
        case .editImage: return "Editing photo"
        case .frameImage: return "Adding background"
        case .cropImage, .cropVideo, .cropPDF: return "Cropping"
        case .redactImage, .redactVideo: return "Redacting"
        case .resizeImage: return "Resizing"
        case .rotateImage: return "Rotating"
        case .createPDF: return "Creating PDF"
        case .createCollage: return "Creating collage"
        case .trimVideo, .trimAudio: return "Trimming"
        case .changeVideoSpeed: return "Changing speed"
        case .joinVideos: return "Joining"
        case .videoSnapshots: return "Saving frames"
        case .splitVideo, .splitPDF: return "Splitting"
        case .normalizeAudio: return "Normalizing"
        case .audioToVideo: return "Creating visualizer"
        case .audioChannels: return "Converting channels"
        case .redactAudio: return "Bleeping"
        case .mergePDF: return "Merging"
        case .organizePDF: return "Organizing"
        }
    }

    var radialLabel: String {
        switch self {
        case .compress: return "COMPRESS"
        case .editMetadata: return "METADATA"
        case .editImage: return "EDIT"
        case .frameImage: return "ADD BG"
        case .cropImage, .cropVideo, .cropPDF: return "CROP"
        case .redactImage, .redactVideo: return "REDACT"
        case .resizeImage: return "RESIZE"
        case .rotateImage: return "ROTATE"
        case .createPDF: return "PDF"
        case .createCollage: return "COLLAGE"
        case .trimVideo, .trimAudio: return "TRIM"
        case .changeVideoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "FRAMES"
        case .splitVideo, .splitPDF: return "SPLIT"
        case .normalizeAudio: return "NORMALIZE"
        case .audioToVideo: return "VISUALIZE"
        case .audioChannels: return "CHANNELS"
        case .redactAudio: return "BLEEP"
        case .mergePDF: return "MERGE"
        case .organizePDF: return "ORGANIZE"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .editMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo, .cropPDF: return "crop"
        case .redactImage: return "eye.slash"
        case .redactVideo: return "video.slash"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .rotateImage: return "rotate.right"
        case .createPDF: return "doc.richtext"
        case .createCollage: return "square.grid.2x2"
        case .trimVideo, .trimAudio: return "scissors"
        case .changeVideoSpeed: return "gauge.with.dots.needle.67percent"
        case .joinVideos: return "link"
        case .videoSnapshots: return "camera.viewfinder"
        case .splitVideo: return "rectangle.split.2x1"
        case .splitPDF: return "doc.on.doc"
        case .normalizeAudio: return "waveform"
        case .audioToVideo: return "waveform.and.magnifyingglass"
        case .audioChannels: return "headphones"
        case .redactAudio: return "speaker.slash"
        case .mergePDF: return "doc.on.doc.fill"
        case .organizePDF: return "rectangle.stack"
        }
    }

    var categories: Set<FormatCategory> {
        switch self {
        case .compress, .editMetadata:
            return [.image, .video, .audio, .document]
        case .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF, .createCollage:
            return [.image]
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo:
            return [.video]
        case .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio:
            return [.audio]
        case .mergePDF, .organizePDF, .splitPDF, .cropPDF:
            return [.document]
        }
    }

    var arity: ToolArity {
        switch self {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF: return .any
        case .createCollage, .joinVideos, .mergePDF: return .multiple
        default: return .single
        }
    }

    func applies(to formats: [FileFormat]) -> Bool {
        guard !formats.isEmpty else { return false }
        let categories = Set(formats.map(\.category))
        guard categories.count == 1, let category = categories.first, self.categories.contains(category) else { return false }
        if category == .document {
            switch self {
            case .mergePDF, .organizePDF, .splitPDF, .cropPDF, .editMetadata, .compress:
                guard formats.allSatisfy({ $0 == .pdf }) else { return false }
            default:
                return false
            }
        }
        if category == .video, formats.contains(.gif), self != .compress, self != .editMetadata { return false }
        switch arity {
        case .single: return formats.count == 1
        case .multiple: return formats.count >= 2
        case .any: return true
        }
    }

    static func available(for formats: [FileFormat]) -> [ToolID] {
        allCases.filter { $0.applies(to: formats) }
    }

    static var total: Int { allCases.count }
}



// Open Tangerine / Tools/ToolWindowManager.swift
import AppKit
import SwiftUI

struct ToolSession: Identifiable {
    let id = UUID()
    let tool: ToolID
    let files: [URL]
    let workspace: WorkflowWorkspace
    let outputDirectory: URL
    let export = EditorExport()

    var formats: [FileFormat] { files.compactMap(FileFormat.detect) }
    var primary: URL { files[0] }
    var primaryFormat: FileFormat { FileFormat.detect(primary) ?? .png }
    var baseName: String { ConversionMatrix.strippedBaseName(primary.lastPathComponent) }

    func outputURL(suffix: String, ext: String, baseName: String? = nil) -> URL {
        ConversionMatrix.uniqueURL(directory: outputDirectory, baseName: baseName ?? self.baseName, suffix: suffix, ext: ext)
    }
}

@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()

    private var windows: [UUID: NSWindow] = [:]

    var openWindows: [NSWindow] { Array(windows.values) }

    func closeAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    func open(_ tool: ToolID, files: [URL], workspace existing: WorkflowWorkspace? = nil) {
        guard !files.isEmpty else { return }
        let session: ToolSession
        do {
            let workspace = try existing ?? WorkflowWorkspace(files)
            session = ToolSession(tool: tool, files: files, workspace: workspace, outputDirectory: try workspace.stage())
        } catch { finishJob("Open editor", outputs: [], originals: files, error: error); return }
        let root = ToolRootView(session: session)
            .environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear; window.isOpaque = false
        window.title = tool.title
        window.subtitle = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.preferredSize(for: tool))
        window.minSize = Self.minimumSize(for: tool)
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(session.id.uuidString)
        windows[session.id] = window
        showAppWindow(window)
    }

    func close(_ session: ToolSession) {
        windows[session.id]?.close()
        windows.removeValue(forKey: session.id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue, let uuid = UUID(uuidString: id) else { return }
        windows.removeValue(forKey: uuid)
        updateActivationAfterClose()
    }

    enum WindowClass {
        case compact, standard, editor

        var sidebarWidth: CGFloat {
            switch self {
            case .compact: return 260
            case .standard: return 290
            case .editor: return 320
            }
        }
    }

    static func windowClass(for tool: ToolID) -> WindowClass {
        switch tool {
        case .compress, .resizeImage, .createPDF, .mergePDF, .splitPDF, .audioChannels, .rotateImage:
            return .compact
        case .editMetadata, .normalizeAudio, .organizePDF, .createCollage, .joinVideos, .audioToVideo, .trimAudio, .redactAudio:
            return .standard
        default:
            return .editor
        }
    }

    static func preferredSize(for tool: ToolID) -> NSSize {
        switch tool {
        case .compress:
            return NSSize(width: 640, height: 560)
        case .resizeImage:
            return NSSize(width: 620, height: 400)
        case .createPDF, .mergePDF:
            return NSSize(width: 680, height: 440)
        case .splitPDF, .audioChannels:
            return NSSize(width: 720, height: 460)
        case .rotateImage:
            return NSSize(width: 760, height: 500)
        case .editMetadata, .normalizeAudio, .trimAudio, .redactAudio, .audioToVideo:
            return NSSize(width: 820, height: 560)
        case .organizePDF, .createCollage, .joinVideos:
            return NSSize(width: 940, height: 620)
        default:
            return NSSize(width: 1040, height: 700)
        }
    }

    static func minimumSize(for tool: ToolID) -> NSSize {
        switch windowClass(for: tool) {
        case .compact: return NSSize(width: 560, height: 360)
        case .standard: return NSSize(width: 640, height: 440)
        case .editor: return NSSize(width: 760, height: 520)
        }
    }
}

struct ToolRootView: View {
    let session: ToolSession

    var body: some View {
        Group {
            switch session.tool {
            case .compress: CompressToolView(session: session)
            case .editMetadata: MetadataToolView(session: session)
            case .editImage: EditImageToolView(session: session)
            case .frameImage: FrameImageToolView(session: session)
            case .cropImage: CropImageToolView(session: session)
            case .redactImage: RedactImageToolView(session: session)
            case .resizeImage: ResizeImageToolView(session: session)
            case .rotateImage: RotateImageToolView(session: session)
            case .createPDF: CreatePDFToolView(session: session)
            case .createCollage: CollageToolView(session: session)
            case .trimVideo: TrimVideoToolView(session: session)
            case .cropVideo: CropVideoToolView(session: session)
            case .changeVideoSpeed: VideoSpeedToolView(session: session)
            case .joinVideos: JoinVideosToolView(session: session)
            case .videoSnapshots: VideoSnapshotsToolView(session: session)
            case .splitVideo: SplitVideoToolView(session: session)
            case .redactVideo: RedactVideoToolView(session: session)
            case .normalizeAudio: NormalizeAudioToolView(session: session)
            case .audioToVideo: AudioToVideoToolView(session: session)
            case .trimAudio: TrimAudioToolView(session: session)
            case .audioChannels: AudioChannelsToolView(session: session)
            case .redactAudio: RedactAudioToolView(session: session)
            case .mergePDF: MergePDFToolView(session: session)
            case .organizePDF: OrganizePDFToolView(session: session)
            case .splitPDF: SplitPDFToolView(session: session)
            case .cropPDF: CropPDFToolView(session: session)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct ExportPicker: View {
    @ObservedObject var export: EditorExport
    var body: some View {
        Picker("Result", selection: $export.finish) {
            ForEach(EditorFinish.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().frame(width: 148)
    }
}
struct WindowChrome<Content: View>: View {
    @ObservedObject var store = Store.shared
    let session: ToolSession
    var saveTitle: String
    var saveEnabled: Bool
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    private var fileLabel: String {
        session.files.count == 1 ? session.primary.lastPathComponent : "\(session.files.count) files"
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                Label {
                    Text(fileLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: session.tool.symbol)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { ToolWindowManager.shared.close(session) }
                    .keyboardShortcut(.cancelAction)
                ExportPicker(export: session.export)
                Button("Apply") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saveEnabled)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.white.opacity(0.35))
        }
        .background(Glass(tint: store.config.uiTint, strength: store.config.tintStrength))
        .preferredColorScheme(.light).tint(Theme.accent)
    }
}

struct ToolShell<Content: View, Sidebar: View>: View {
    let session: ToolSession
    var saveTitle = "Save copy"
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var sidebar: () -> Sidebar

    private var windowClass: ToolWindowManager.WindowClass { ToolWindowManager.windowClass(for: session.tool) }

    var body: some View {
        let compact = windowClass == .compact
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            HStack(spacing: compact ? 12 : 16) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                    .card()
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                        sidebar()
                    }
                }
                .scrollIndicators(.automatic)
                .frame(width: windowClass.sidebarWidth)
            }
            .padding(compact ? 14 : 20)
        }
    }
}

struct FormShell<Content: View>: View {
    let session: ToolSession
    var saveTitle = "Save copy"
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.body)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct FormHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
    }
}

struct FormHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int
    var suffix = ""

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).font(.callout) }
        }
    }
}

struct TimecodeField: View {
    let title: String
    @Binding var seconds: Double
    var maximum: Double
    @HCState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("0:00.00", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = TimeFormatter.clock(seconds) }
        .onChange(of: seconds) { newValue in if !focused { text = TimeFormatter.clock(newValue) } }
    }

    private func commit() {
        if let parsed = TimeFormatter.parseClock(text) {
            seconds = min(max(0, parsed), maximum)
        }
        text = TimeFormatter.clock(seconds)
    }
}


// Open Tangerine / Tools/Video/CropSpeedJoinVideoToolViews.swift
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CropVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var frame: NSImage?
    @HCState private var rects: [RectangleOverlay] = []
    @HCState private var selected: UUID?
    @HCState private var aspect = AspectPreset.all[0]
    @HCState private var outWidth = 0
    @HCState private var outHeight = 0
    @HCState private var keepSize = true

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var cropRect: CGRect? { rects.first?.rect }
    private var videoSize: CGSize { media.info.naturalSize }
    private var aspectRatio: CGFloat? {
        guard let ratio = aspect.ratio else { return nil }
        if ratio < 0, videoSize.height > 0 { return videoSize.width / videoSize.height }
        return ratio
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Crop", saveEnabled: cropRect.map { $0.width > 8 && $0.height > 8 } ?? false, onSave: save) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let frame {
                        RectangleEditorCanvas(image: frame, imageSize: videoSize, rectangles: $rects, selected: $selected, allowMultiple: false, aspect: aspectRatio)
                    } else {
                        ProgressView()
                    }
                }
                TransportBar(controller: media)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("", selection: $aspect) {
                    ForEach(AspectPreset.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: "Crop area") {
                if let rect = cropRect {
                    Text("\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))").font(.callout.monospacedDigit())
                }
                Text("Video: \(Int(videoSize.width)) × \(Int(videoSize.height))").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Output dimensions") {
                Toggle("Same as crop area", isOn: $keepSize)
                NumberField(title: "Width", value: $outWidth, suffix: "px").disabled(keepSize)
                NumberField(title: "Height", value: $outHeight, suffix: "px").disabled(keepSize)
                Text("Audio is kept as is. Output is MP4 (H.264).").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.currentTime) { _ in loadFrame() }
        .onChange(of: media.loaded) { loaded in
            guard loaded else { return }
            loadFrame()
            let inset = CGRect(origin: .zero, size: videoSize).insetBy(dx: videoSize.width * 0.1, dy: videoSize.height * 0.1)
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: inset.integral, color: Theme.accent, label: "")]
            selected = id
        }
        .onChange(of: rects) { new in
            if keepSize, let rect = new.first?.rect { outWidth = Int(rect.width); outHeight = Int(rect.height) }
        }
        .onChange(of: aspect) { _ in
            guard let ratio = aspectRatio, let rect = cropRect else { return }
            var new = rect
            new.size.height = rect.width / ratio
            if new.maxY > videoSize.height { new.size.height = videoSize.height - rect.minY; new.size.width = new.height * ratio }
            rects = [RectangleOverlay(id: rects[0].id, rect: new.integral, color: Theme.accent, label: "")]
        }
    }

    private func loadFrame() {
        let url = session.primary
        let time = media.currentTime
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { frame = ns }
        }
    }

    private func save() {
        guard let rect = cropRect else { return }
        let url = session.primary
        let even = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: (rect.width / 2).rounded(.down) * 2, height: (rect.height / 2).rounded(.down) * 2)
        let output: CGSize? = keepSize ? nil : CGSize(width: (CGFloat(outWidth) / 2).rounded(.down) * 2, height: (CGFloat(outHeight) / 2).rounded(.down) * 2)
        let destination = session.outputURL(suffix: "cropped", ext: "mp4")
        session.run(title: "Cropping", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.crop(url, rect: even, outputSize: output, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct VideoSpeedToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var factor: Double = 2
    @HCState private var preservePitch = true

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", onSave: save) {
            PlayerSurface(player: media.player)
                .background(Color.black)
        } sidebar: {
            SidebarSection(title: "Speed") {
                LabeledSlider(title: "Factor", value: $factor, range: 0.1...8) { String(format: "%.2f×", $0) }
                HStack {
                    ForEach([0.25, 0.5, 1.5, 2, 4], id: \.self) { value in
                        Button(String(format: "%g×", value)) { factor = value }.controlSize(.mini)
                    }
                }
                Text("New length: \(TimeFormatter.clock(media.duration / factor))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Audio") {
                Toggle("Preserve pitch", isOn: $preservePitch).disabled(!media.info.hasAudio)
                Text(media.info.hasAudio ? "Pitch is kept natural; disable for a classic tape-speed effect." : "This video has no audio track.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Preview") {
                Button(media.isPlaying ? "Pause" : "Play at \(String(format: "%g", factor))×") {
                    if media.isPlaying { media.pause() } else {
                        media.player.currentItem?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
                        media.player.rate = Float(factor)
                        media.isPlaying = true
                    }
                }
            }
        }
    }

    private func save() {
        let url = session.primary, factor = factor, pitch = preservePitch
        let destination = session.outputURL(suffix: String(format: "%gx", factor), ext: "mp4")
        session.run(title: "Changing speed", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.changeSpeed(url, factor: factor, preservePitch: pitch, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct JoinVideosToolView: View {
    let session: ToolSession
    @HCState private var files: [URL]
    @HCState private var thumbs: [URL: NSImage] = [:]
    @HCState private var infos: [URL: MediaInfo] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var totalDuration: Double { files.reduce(0) { $0 + (infos[$1]?.duration ?? 0) } }

    var body: some View {
        ToolShell(session: session, saveTitle: "Join \(files.count) clips", saveEnabled: files.count >= 2, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], addTitle: "Add clips…")
        } sidebar: {
            SidebarSection(title: "Canvas") {
                if let first = files.first, let info = infos[first] {
                    Text("\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height)) from the first clip").font(.callout)
                }
                Text("Other clips are scaled to fit and letterboxed if their aspect ratio differs. Output is a single MP4.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Summary") {
                Text("\(files.count) clips · \(TimeFormatter.clock(totalDuration))").font(.callout.monospacedDigit())
            }
        }
        .task(id: files) { await loadInfo() }
    }

    private func loadInfo() async {
        for url in files where infos[url] == nil {
            infos[url] = await MediaInfo.load(url)
            if let cg = try? await VideoOps.snapshot(url, at: 0.5) {
                thumbs[url] = ImageOps.nsImage(ImageIOBridge.resized(cg, longEdge: 200))
            }
        }
    }

    private func save() {
        let files = files
        let destination = session.outputURL(suffix: "joined", ext: "mp4")
        session.run(title: "Joining", detail: "\(files.count) videos") { progress in
            try await VideoOps.join(files, to: destination, progress: progress)
            return [destination]
        }
    }
}



// Open Tangerine / Tools/Video/SnapshotsRedactVideoToolViews.swift
import AVFoundation
import SwiftUI

@MainActor
struct VideoSnapshotsToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var frames: [Snapshot] = []
    @HCState private var format: FileFormat = .png
    @HCState private var intervalMode = false
    @HCState private var everySeconds: Double = 5

    struct Snapshot: Identifiable, Equatable {
        let id = UUID()
        let time: Double
        var thumbnail: NSImage?
        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.id == rhs.id }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var plannedTimes: [Double] {
        if intervalMode {
            guard media.duration > 0, everySeconds > 0 else { return [] }
            return stride(from: 0, to: media.duration, by: everySeconds).map { $0 }
        }
        return frames.map(\.time).sorted()
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save \(plannedTimes.count) frame\(plannedTimes.count == 1 ? "" : "s")", saveEnabled: !plannedTimes.isEmpty, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(0), playhead: media.currentTime, markers: plannedTimes, onScrub: { media.seek($0) })
                    .frame(height: 28)
                if !intervalMode {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(frames.sorted { $0.time < $1.time }) { snap in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .topTrailing) {
                                        if let thumb = snap.thumbnail {
                                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)).frame(width: 128, height: 72)
                                        }
                                        Button { frames.removeAll { $0.id == snap.id } } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.borderless).padding(3)
                                    }
                                    Text(TimeFormatter.clock(snap.time)).font(.caption2.monospacedDigit())
                                }
                                .onTapGesture { media.seek(snap.time) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 100)
                }
            }
        } sidebar: {
            SidebarSection(title: "Frames") {
                Toggle("Every N seconds", isOn: $intervalMode)
                if intervalMode {
                    LabeledSlider(title: "Interval", value: $everySeconds, range: 0.5...60) { String(format: "%.1f s", $0) }
                    Text("\(plannedTimes.count) frames").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Button("Add current frame") { addCurrent() }
                        .keyboardShortcut("f", modifiers: [])
                    Text("Step with ← → to pick exact frames, then press F or the button. \(frames.count) chosen.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Format") {
                Picker("", selection: $format) {
                    Text("PNG (lossless)").tag(FileFormat.png)
                    Text("JPG").tag(FileFormat.jpg)
                    Text("HEIC").tag(FileFormat.heic)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Frames are exported at full video resolution into one folder.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .background(KeyCaptureView { key in
            switch key {
            case .left: media.stepFrame(-1)
            case .right: media.stepFrame(1)
            case .space: media.togglePlay()
            }
        })
    }

    private func addCurrent() {
        let time = media.currentTime
        guard !frames.contains(where: { abs($0.time - time) < 0.001 }) else { return }
        let snap = Snapshot(time: time)
        frames.append(snap)
        let url = session.primary
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(ImageIOBridge.resized(cg, longEdge: 256))
            await MainActor.run {
                if let index = frames.firstIndex(where: { $0.id == snap.id }) { frames[index].thumbnail = ns }
            }
        }
    }

    private func save() {
        let url = session.primary
        let times = plannedTimes
        let format = format
        let quality = AppSettings.shared.jpegQuality
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) frames")
        session.run(title: "Saving", detail: "\(times.count) frames") { progress in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var outputs: [URL] = []
            for (index, time) in times.enumerated() {
                let image = try await VideoOps.snapshot(url, at: time)
                let name = TimeFormatter.clock(time, fractionDigits: 3).replacingOccurrences(of: ":", with: "-")
                let destination = folder.appendingPathComponent("frame \(String(format: "%03d", index + 1)) @ \(name).\(format.fileExtension)")
                try ImageIOBridge.write(image, to: destination, format: format, quality: quality)
                outputs.append(destination)
                progress(Double(index + 1) / Double(times.count))
            }
            return outputs
        }
    }
}

@MainActor
struct RedactVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var frame: NSImage?
    @HCState private var rects: [RectangleOverlay] = []
    @HCState private var selected: UUID?
    @HCState private var ranges: [UUID: ClosedRange<Double>] = [:]
    @HCState private var styles: [UUID: RedactionStyle] = [:]
    @HCState private var defaultStyle: RedactionStyle = .solid

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var videoSize: CGSize { media.info.naturalSize }

    private var selectedRange: Binding<ClosedRange<Double>> {
        Binding(
            get: { selected.flatMap { ranges[$0] } ?? 0...max(media.duration, 0.01) },
            set: { new in if let selected { ranges[selected] = new } }
        )
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Redact", saveEnabled: !rects.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let frame {
                        RectangleEditorCanvas(image: frame, imageSize: videoSize, rectangles: $rects, selected: $selected, allowMultiple: true)
                    } else {
                        ProgressView()
                    }
                }
                TransportBar(controller: media)
                RangeTrack(
                    duration: media.duration,
                    start: Binding(get: { selectedRange.wrappedValue.lowerBound }, set: { new in updateRange(lower: new) }),
                    end: Binding(get: { selectedRange.wrappedValue.upperBound }, set: { new in updateRange(upper: new) }),
                    playhead: media.currentTime,
                    onScrub: { media.seek($0) }
                )
                .opacity(selected == nil ? 0.4 : 1)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Time range") {
                if let selected, let range = ranges[selected] {
                    TimecodeField(title: "From", seconds: Binding(get: { range.lowerBound }, set: { updateRange(lower: $0) }), maximum: media.duration)
                    TimecodeField(title: "To", seconds: Binding(get: { range.upperBound }, set: { updateRange(upper: $0) }), maximum: media.duration)
                    Button("Whole video") { ranges[selected] = 0...media.duration }.controlSize(.small)
                } else {
                    Text("Select an area to set when it is covered. New areas cover the whole video.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Areas (\(rects.count))") {
                if rects.isEmpty {
                    Text("Drag on the frame to add a redaction. Each area can have its own time range.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text("Area \(overlay.label) · \((styles[overlay.id] ?? defaultStyle).title)").font(.callout)
                            if let range = ranges[overlay.id] {
                                Text("\(TimeFormatter.clock(range.lowerBound)) – \(TimeFormatter.clock(range.upperBound))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { remove(overlay.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
            }
        }
        .onChange(of: media.currentTime) { _ in loadFrame() }
        .onChange(of: media.loaded) { if $0 { loadFrame() } }
        .onChange(of: rects) { new in
            for (index, overlay) in new.enumerated() {
                if ranges[overlay.id] == nil { ranges[overlay.id] = 0...max(media.duration, 0.01) }
                if rects[index].label != "\(index + 1)" { rects[index].label = "\(index + 1)" }
            }
        }
        .onDeleteCommand { if let selected { remove(selected) } }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { selected.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in if let selected { styles[selected] = new } else { defaultStyle = new } }
        )
    }

    private func updateRange(lower: Double? = nil, upper: Double? = nil) {
        guard let selected else { return }
        let current = ranges[selected] ?? 0...media.duration
        let low = min(lower ?? current.lowerBound, current.upperBound - 0.01)
        let high = max(upper ?? current.upperBound, low + 0.01)
        ranges[selected] = max(0, low)...min(media.duration, high)
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        ranges.removeValue(forKey: id)
        styles.removeValue(forKey: id)
        if selected == id { selected = nil }
    }

    private func loadFrame() {
        let url = session.primary
        let time = media.currentTime
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { frame = ns }
        }
    }

    private func save() {
        let url = session.primary
        let size = videoSize
        let redactions = rects.map { overlay -> Redaction in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            if let range = ranges[overlay.id] { r.start = range.lowerBound; r.end = range.upperBound }
            return r
        }
        let destination = session.outputURL(suffix: "redacted", ext: "mp4")
        session.run(title: "Redacting", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.redact(url, redactions: redactions, displaySize: size, to: destination, progress: progress)
            return [destination]
        }
    }
}



// Open Tangerine / Tools/Video/TrimSplitVideoToolViews.swift
import AVFoundation
import SwiftUI

@MainActor
struct TrimVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var start: Double = 0
    @HCState private var end: Double = 0

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Trim", saveEnabled: end > start, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, onScrub: { media.seek($0) })
            }
        } sidebar: {
            SidebarSection(title: "Range") {
                TimecodeField(title: "Start", seconds: $start, maximum: media.duration)
                TimecodeField(title: "End", seconds: $end, maximum: media.duration)
                HStack {
                    Button("Set start to playhead") { start = min(media.currentTime, end - 0.05) }
                    Button("Set end") { end = max(media.currentTime, start + 0.05) }
                }
                .controlSize(.small)
                Text("Length: \(TimeFormatter.clock(max(0, end - start)))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Preview") {
                Button("Play selection") { media.playRange(start, end) }
                Text("Use the frame buttons or ← → to step frame by frame while the video is paused.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Output") {
                Text("The selection is copied without re-encoding when the format allows it, so the trim is fast and lossless.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { duration in if end == 0 { end = duration } }
        .onChange(of: start) { new in if abs(media.currentTime - new) > 0.01 { media.seek(new) } }
        .onChange(of: end) { new in media.seek(new) }
        .background(KeyCaptureView { key in
            switch key {
            case .left: media.stepFrame(-1)
            case .right: media.stepFrame(1)
            case .space: media.togglePlay()
            }
        })
    }

    private func save() {
        let url = session.primary, start = start, end = end
        let destination = session.outputURL(suffix: "trimmed", ext: url.pathExtension)
        session.run(title: "Trimming", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.trim(url, start: start, end: end, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct SplitVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @HCState private var mode: Mode = .points
    @HCState private var points: [Double] = []
    @HCState private var parts = 2
    @HCState private var unusedStart: Double = 0
    @HCState private var unusedEnd: Double = 0

    enum Mode: String, CaseIterable, Identifiable {
        case points, equal
        var id: String { rawValue }
        var title: String { self == .points ? "Custom points" : "Equal parts" }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var effectivePoints: [Double] {
        switch mode {
        case .points: return points.sorted()
        case .equal:
            guard parts > 1, media.duration > 0 else { return [] }
            return (1..<parts).map { media.duration * Double($0) / Double(parts) }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Split into \(effectivePoints.count + 1) clips", saveEnabled: !effectivePoints.isEmpty, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: $unusedStart, end: $unusedEnd, playhead: media.currentTime, markers: effectivePoints, onScrub: { media.seek($0) })
            }
        } sidebar: {
            SidebarSection(title: "Split") {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .points:
                    Button("Add split at playhead") {
                        let t = media.currentTime
                        if t > 0.1, t < media.duration - 0.1, !points.contains(where: { abs($0 - t) < 0.05 }) { points.append(t) }
                    }
                    ForEach(points.sorted(), id: \.self) { point in
                        HStack {
                            Text(TimeFormatter.clock(point)).font(.callout.monospacedDigit())
                            Spacer()
                            Button { media.seek(point) } label: { Image(systemName: "forward.frame") }
                            Button { points.removeAll { $0 == point } } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                    }
                case .equal:
                    Stepper("Parts: \(parts)", value: $parts, in: 2...50)
                    Text("Each clip lasts about \(TimeFormatter.clock(media.duration / Double(parts))).").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Output") {
                Text("All clips are placed in one folder next to the original, numbered in order. Clips are copied without re-encoding when possible.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { unusedEnd = $0 }
    }

    private func save() {
        let url = session.primary
        let points = effectivePoints
        let duration = media.duration
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) clips")
        session.run(title: "Splitting", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.split(url, at: points, duration: duration, into: folder, progress: progress)
        }
    }
}

struct KeyCaptureView: NSViewRepresentable {
    enum Key { case left, right, space }
    let handler: (Key) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) { nsView.handler = handler }

    final class KeyView: NSView {
        var handler: ((Key) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, !(self.window?.firstResponder is NSTextView) else { return event }
                switch event.keyCode {
                case 123: self.handler?(.left); return nil
                case 124: self.handler?(.right); return nil
                case 49: self.handler?(.space); return nil
                default: return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}



import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(stdout data: Data) { lock.withLock { stdout = data } }
    func set(stderr data: Data) { lock.withLock { stderr = data } }

    func result(status: Int32) -> ShellResult {
        lock.withLock {
            ShellResult(status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
        }
    }
}

final class ProcessBox: @unchecked Sendable {
    let process = Process()
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ShellResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = box.process
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let output = PipeBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output.set(stdout: drain(outPipe.fileHandleForReading))
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    output.set(stderr: drain(errPipe.fileHandleForReading))
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.wait()
                    continuation.resume(returning: output.result(status: proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func drain(_ handle: FileHandle) -> Data {
        var result = Data()
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            if result.count < 2_000_000 { result.append(chunk.prefix(2_000_000 - result.count)) }
        }
        return result
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates = extra
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            candidates.insert(bundled, at: 0)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.insert(resource, at: 1)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}



import AVFoundation
import Foundation

struct MediaInfo {
    var duration: Double = 0
    var naturalSize: CGSize = .zero
    var frameRate: Double = 0
    var hasAudio: Bool = false
    var hasVideo: Bool = false
    var estimatedBitrate: Double = 0
    var channelCount: Int = 0
    var sampleRate: Double = 0

    static func load(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            info.duration = CMTimeGetSeconds(duration)
        }
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                if track.mediaType == .video {
                    info.hasVideo = true
                    if let size = try? await track.load(.naturalSize),
                       let transform = try? await track.load(.preferredTransform) {
                        let rect = CGRect(origin: .zero, size: size).applying(transform)
                        info.naturalSize = CGSize(width: abs(rect.width), height: abs(rect.height))
                    }
                    if let fps = try? await track.load(.nominalFrameRate) { info.frameRate = Double(fps) }
                    if let rate = try? await track.load(.estimatedDataRate) { info.estimatedBitrate += Double(rate) }
                } else if track.mediaType == .audio {
                    info.hasAudio = true
                    if let rate = try? await track.load(.estimatedDataRate) { info.estimatedBitrate += Double(rate) }
                    if let descriptions = try? await track.load(.formatDescriptions),
                       let first = descriptions.first,
                       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                        info.channelCount = Int(asbd.pointee.mChannelsPerFrame)
                        info.sampleRate = asbd.pointee.mSampleRate
                    }
                }
            }
        }
        if info.duration == 0 || (!info.hasAudio && !info.hasVideo) {
            if let probed = await FFmpeg.probeDuration(url) { info.duration = probed }
        }
        return info
    }

    static func isNativelyReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        return !tracks.isEmpty
    }
}

enum FileSizeFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

enum TimeFormatter {
    static func clock(_ seconds: Double, fractionDigits: Int = 2) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        return String(format: "%d:%0\(3 + fractionDigits).\(fractionDigits)f", minutes, secs)
    }

    static func parseClock(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { String($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return Double(text) }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}



import Foundation

enum OpenTangerineError: LocalizedError {
    case unsupportedConversion(FileFormat, FileFormat)
    case unreadable(URL)
    case encodeFailed(String)
    case ffmpegMissing(String)
    case toolFailed(String, String)
    case cancelled
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedConversion(from, to):
            return "Converting \(from.displayName) to \(to.displayName) is not supported."
        case let .unreadable(url):
            return "Could not read \(url.lastPathComponent)."
        case let .encodeFailed(what):
            return "Could not write \(what)."
        case let .ffmpegMissing(what):
            return "\(what) needs ffmpeg. Install it (for example with `brew install ffmpeg`) or set its path in Settings."
        case let .toolFailed(tool, output):
            return "\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .cancelled:
            return "Cancelled."
        case let .invalidInput(reason):
            return reason
        }
    }
}



import Foundation

/// Diagnostics are explicitly opt-in because converter errors may contain filenames.
enum DiagnosticLog {
    static let enabled = ProcessInfo.processInfo.environment["HONEYCOMB_DEBUG"] == "1"
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTangerine-Diagnostics")
    static let logFile = directory.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "com.sintaxerror.opentangerine.log")
    static func start() {}
    static func flush() {}
    static func log(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard enabled else { return }
        let entry = Data((String(message().prefix(4000)) + "\n").utf8)
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
                try? Data().write(to: logFile)
            }
            if !FileManager.default.fileExists(atPath: logFile.path) { try? Data().write(to: logFile) }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            }
        }
    }
}


import AppKit
import Foundation
import Combine
import ServiceManagement

enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced
    case strong

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var imageQuality: Double { self == .balanced ? 0.72 : 0.5 }
    var videoScale: Double { self == .balanced ? 1.0 : 0.75 }
    var videoBitrateFactor: Double { self == .balanced ? 0.6 : 0.35 }
    var audioBitrate: Int { self == .balanced ? 128_000 : 64_000 }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal
    case downloads
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }

    func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }
}


final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var compressionPreset: CompressionPreset = .balanced
    @Published var compressionResizeLongEdge = 0
    @Published var outputLocation: OutputLocation = .besideOriginal
    @Published var ffmpegPath = ""
    @Published var jpegQuality = 0.90
}


struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}




import Foundation

// Filee is a separate, locally built helper. Its settings and engine cache are isolated from Filee.app.
final class FileeBridge: @unchecked Sendable {
    static let shared = FileeBridge()
    struct PresetRoute: Decodable, Identifiable {
        let id: String
        let name: String
        var selection: String { "preset:" + id }
    }
    struct Routes: Decodable {
        var targets: [String]
        var withEngines: [String]
        var presets: [PresetRoute]? = nil
        var all: [String] { targets + withEngines.filter { !targets.contains($0) } }
    }
    struct Result: Decodable {
        struct Entry: Decodable {
            var outputs: [String]
            var error: String?
            var needsEngines: [String]?
        }
        var files: [Entry]
    }
    struct EngineList: Decodable {
        struct Engine: Decodable { var id: String; var downloadable: Bool }
        var engines: [Engine]
    }
    private let lock = NSLock()
    private let downloads = NSLock()
    private var cache: [String: (Date, Routes)] = [:]
    private var querying = Set<String>()
    private let catalogQueue = DispatchQueue(label: "app.honeycomb.formats", qos: .utility)
    let executableURL = home.appendingPathComponent("extended/bin/filee-cli")
    var available: Bool { fm.isExecutableFile(atPath: executableURL.path) }
    var dataDirectory: URL { home.appendingPathComponent("extended/data", isDirectory: true) }
    func routes(_ ext: String) -> Routes? { lock.lock(); defer { lock.unlock() }; return cache[ext]?.1 }
    func prepare(_ files: [URL], done: @escaping () -> Void = {}) {
        guard available else { DispatchQueue.main.async(execute: done); return }
        let exts = Set(files.filter { !$0.hasDirectoryPath }.map(fileeExtension).filter { !$0.isEmpty })
        catalogQueue.async {
            for ext in exts {
                self.lock.lock()
                let ready = self.cache[ext].map { Date().timeIntervalSince($0.0) < 120 } ?? false
                let inFlight = self.querying.contains(ext)
                if !ready && !inFlight { self.querying.insert(ext) }
                self.lock.unlock()
                if ready || inFlight { continue }
                let result = (try? self.command(["formats", ext, "--json"], seconds: 20)).flatMap {
                    try? JSONDecoder().decode(Routes.self, from: $0.data)
                } ?? Routes(targets: [], withEngines: [])
                self.lock.lock(); self.cache[ext] = (Date(), result); self.querying.remove(ext); self.lock.unlock()
            }
            DispatchQueue.main.async(execute: done)
        }
    }
    struct CommandResult { var status: Int32; var data: Data; var error: String }
    func command(_ args: [String], seconds: Double = 1800) throws -> CommandResult {
        guard available else { throw HCError("Extended formats are unavailable. Check setup in Honeycomb.") }
        let dir = try workDirectory(); defer { try? fm.removeItem(at: dir) }
        let out = dir.appendingPathComponent("stdout"), err = dir.appendingPathComponent("stderr")
        fm.createFile(atPath: out.path, contents: nil); fm.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out), errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process(); process.executableURL = executableURL; process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["FILEE_DATA_DIR"] = dataDirectory.path
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env; process.standardOutput = outHandle; process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0); process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now()+seconds) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now()+3) == .timedOut { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw HCError("Extended converter timed out.")
        }
        let stdout = try Data(contentsOf: out)
        let errors = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, data: stdout, error: String(errors.suffix(4000)))
    }
    private func ensure(_ requested: Set<String>) throws {
        downloads.lock(); defer { downloads.unlock() }
        let list = try command(["engines", "--json"], seconds: 30)
        let catalog = try JSONDecoder().decode(EngineList.self, from: list.data)
        let allowed = Set(catalog.engines.filter(\.downloadable).map(\.id))
        guard !requested.isEmpty, requested.isSubset(of: allowed) else { throw HCError("A required engine is unavailable on this Mac.") }
        for id in requested.sorted() {
            log("Preparing optional engine: \(id)")
            let result = try command(["engines", "install", id, "--json"])
            if result.status != 0 { log(result.error); throw HCError("Could not prepare the \(id) engine. Check your connection and try again.") }
        }
        lock.lock(); cache.removeAll(); lock.unlock()
    }
    func convert(_ inputs: [URL], target: String?, preset: String? = nil, into directory: URL, quality: Int? = nil, pages: String? = nil) throws -> [URL] {
        guard !inputs.isEmpty, inputs.allSatisfy({ !isFolder($0) }) else { throw HCError("Choose files to convert.") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var args = ["convert"] + inputs.map(\.path) + ["--output", directory.path, "--json"]
        if let preset = preset { args += ["--preset", preset] }
        else if let target = target { args += ["--to", target] }
        if let quality = quality { args += ["--quality", String(quality)] }
        if let pages = pages, !pages.isEmpty { args += ["--pages", pages] }
        var response = try command(args)
        var result = try? JSONDecoder().decode(Result.self, from: response.data)
        let needed = Set(result?.files.flatMap { $0.needsEngines ?? [] } ?? [])
        if !needed.isEmpty, result?.files.allSatisfy({ $0.outputs.isEmpty }) == true {
            try ensure(needed); response = try command(args); result = try? JSONDecoder().decode(Result.self, from: response.data)
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let outputs = (result?.files.flatMap(\.outputs) ?? []).map { URL(fileURLWithPath: $0) }
        guard !outputs.isEmpty, outputs.allSatisfy({ $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) && fm.fileExists(atPath: $0.path) }) else {
            log("Extended converter: \(response.error)")
            throw HCError(result?.files.compactMap(\.error).first ?? "The extended converter did not produce an output.")
        }
        if response.status != 0 { throw HCError(result?.files.compactMap(\.error).first ?? "An extended conversion failed.") }
        return outputs
    }
}

func fileeExtension(_ url: URL) -> String {
    let name = url.lastPathComponent.lowercased()
    let compounds = ["tar.gz", "tar.bz2", "tar.bz", "tar.xz", "tar.7z", "tar.lz", "tar.z", "kepub.epub", "7z.001", "zip.001", "tar.001"]
    return compounds.first(where: { name.hasSuffix("." + $0) }) ?? url.pathExtension.lowercased()
}

func availableTargets(_ files: [URL]) -> [String] {
    guard let first = files.first, !files.contains(where: \.hasDirectoryPath) else { return [] }
    let ext = fileeExtension(first)
    return targets(ext).filter { target in
        !["trash", "clipboard", "zip", "compress"].contains(target) && files.allSatisfy {
            targets(fileeExtension($0)).contains(target)
        }
    }
}

func availablePresets(_ files: [URL]) -> [FileeBridge.PresetRoute] {
    guard let first = files.first, !files.contains(where: \.hasDirectoryPath) else { return [] }
    let bridge = FileeBridge.shared
    return (bridge.routes(fileeExtension(first))?.presets ?? []).filter { route in
        files.dropFirst().allSatisfy { file in
            bridge.routes(fileeExtension(file))?.presets?.contains(where: { $0.id == route.id }) == true
        }
    }
}


import AppKit
import SwiftUI
import PDFKit
import Combine

final class WorkflowWorkspace {
    let root: URL
    let originals: [URL]
    init(_ originals: [URL]) throws { self.originals = originals; root = try workDirectory() }
    func stage() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    deinit { try? fm.removeItem(at: root) }
}

enum EditorFinish: String, CaseIterable, Identifiable {
    case save = "Save copy", archive = "ZIP outputs", next = "Continue editing"
    var id: String { rawValue }
}

func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

func publishOutput(_ staged: URL, beside original: URL) throws -> URL {
    let folder = isFolder(staged)
    return try publish(staged, beside: original, stem: folder ? staged.lastPathComponent : staged.deletingPathExtension().lastPathComponent, ext: folder ? "" : staged.pathExtension, folder: folder)
}

func makeArchives(_ files: [URL], workspace: WorkflowWorkspace, separate: Bool, label: String) throws -> [URL] {
    guard let original = workspace.originals.first, !files.isEmpty else { throw HCError("There are no files to archive.") }
    let stage = try workspace.stage()
    if separate {
        return try files.enumerated().map { index, source in
            let zip = stage.appendingPathComponent("\(index).zip")
            try run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path])
            let beside = workspace.originals[min(index, workspace.originals.count-1)]
            return try publish(zip, beside: beside, stem: source.deletingPathExtension().lastPathComponent, ext: "zip")
        }
    }
    let contents = stage.appendingPathComponent("Contents", isDirectory: true)
    try fm.createDirectory(at: contents, withIntermediateDirectories: false)
    for source in files {
        let suffix = source.pathExtension, stem = source.deletingPathExtension().lastPathComponent
        var destination = contents.appendingPathComponent(source.lastPathComponent)
        var index = 1
        while fm.fileExists(atPath: destination.path) {
            let name = stem + " (\(index))" + (suffix.isEmpty ? "" : ".\(suffix)")
            destination = contents.appendingPathComponent(name); index += 1
        }
        try fm.copyItem(at: source, to: destination)
    }
    let zip = stage.appendingPathComponent("archive.zip")
    try run("ditto", ["-c", "-k", "--sequesterRsrc", contents.path, zip.path])
    return [try publish(zip, beside: original, stem: label, ext: "zip")]
}

func finishJob(_ title: String, outputs: [URL], originals: [URL], error: Error? = nil) {
    let failed = error != nil
    let message = error?.localizedDescription ?? outputs.map(\.lastPathComponent).joined(separator: ", ")
    let paths = outputs.isEmpty ? originals : outputs
    let heading = failed ? "\(title) failed" : title
    if failed { log("\(heading): \(message)") }
    Store.shared.record(Record(title: heading, paths: paths.map(\.path), failed: failed))
    Notices.shared.send(heading, message, paths)
}

final class JobRunner {
    static let shared = JobRunner()
    @MainActor
    func run(title: String, detail: String, symbol: String = "hexagon", work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work { _ in }
                await MainActor.run { finishJob(title, outputs: outputs, originals: []) }
            } catch {
                await MainActor.run { finishJob(title, outputs: [], originals: [], error: error) }
            }
        }
    }
}

final class EditorExport: ObservableObject {
    @Published var finish: EditorFinish = .save
}

extension ToolSession {
    @MainActor
    func run(title: String, detail: String, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        let disposition = export.finish, separate = Store.shared.config.separateArchives
        let workspace = workspace, originals = workspace.originals
        ToolWindowManager.shared.close(self)
        Task.detached(priority: .userInitiated) {
            do {
                let staged = try await work { _ in }
                guard !staged.isEmpty else { throw HCError("The editor did not produce a file.") }
                if disposition == .next {
                    await MainActor.run { WorkbenchWindow.shared.open(staged, workspace: workspace) }
                    return
                }
                let result: [URL]
                if disposition == .archive {
                    result = try makeArchives(staged, workspace: workspace, separate: separate, label: originals.count == 1 ? originals[0].deletingPathExtension().lastPathComponent + " edited" : "Honeycomb edits")
                } else {
                    result = try staged.enumerated().map { index, url in
                        try publishOutput(url, beside: originals[staged.count == originals.count ? index : 0])
                    }
                }
                await MainActor.run { finishJob(disposition == .archive ? "ZIP created" : "Edits saved", outputs: result, originals: originals) }
            } catch { await MainActor.run { finishJob(title, outputs: [], originals: originals, error: error) } }
        }
    }
}

func submitWorkflow(_ files: [URL], workspace: WorkflowWorkspace, target: String?, archive: Bool, separate: Bool, quality: Int? = nil, pages: String? = nil, mode: String? = nil) {
    let originals = workspace.originals
    jobs.async {
        var published: [URL] = []
        do {
            var staged = files
            if let target = target {
                staged = []
                for (index, file) in files.enumerated() {
                    let directory = try workspace.stage()
                    let outputs: [URL]
                    if FileeBridge.shared.available && (target.hasPrefix("preset:") || !coreTargets(file.pathExtension.lowercased()).contains(target) || pages != nil || quality != nil) {
                        let preset = target.hasPrefix("preset:") ? String(target.dropFirst(7)) : nil
                        outputs = try FileeBridge.shared.convert([file], target: preset == nil ? target : nil, preset: preset, into: directory, quality: quality, pages: pages)
                    } else {
                        let (output, folder, ext) = try convert(file, target: target, work: directory)
                        let name = file.deletingPathExtension().lastPathComponent + (folder ? " \(target.uppercased()) pages" : "." + ext)
                        let renamed = directory.appendingPathComponent(name, isDirectory: folder)
                        if output != renamed { try fm.moveItem(at: output, to: renamed) }
                        outputs = [renamed]
                    }
                    if archive { staged += outputs }
                    else {
                        for output in outputs { published.append(try publishOutput(output, beside: originals[files.count == originals.count ? index : 0])) }
                        if mode == "trash", files == originals { try fm.trashItem(at: file, resultingItemURL: nil) }
                    }
                }
            }
            if archive {
                published = try makeArchives(staged, workspace: workspace, separate: separate, label: originals.count == 1 ? originals[0].deletingPathExtension().lastPathComponent + (target == nil && files == originals ? "" : " edited") : "Honeycomb files")
            } else if target == nil {
                for (index, output) in staged.enumerated() {
                    guard output.resolvingSymlinksInPath().path.hasPrefix(workspace.root.resolvingSymlinksInPath().path + "/") else { continue }
                    published.append(try publishOutput(output, beside: originals[staged.count == originals.count ? index : 0]))
                }
            }
            let completed = published
            DispatchQueue.main.async {
                if mode == "clipboard", !completed.isEmpty { FileAction.copy.run(completed) }
                finishJob(archive ? "ZIP created" : "Files saved", outputs: completed, originals: originals)
            }
        } catch {
            let completed = published
            DispatchQueue.main.async { finishJob(archive ? "ZIP" : "Export", outputs: completed, originals: originals, error: error) }
        }
    }
}

@MainActor
final class WorkbenchWindow: NSObject, NSWindowDelegate {
    static let shared = WorkbenchWindow()
    var windows: [ObjectIdentifier: NSWindow] = [:]
    func open(_ files: [URL], workspace existing: WorkflowWorkspace? = nil) {
        guard !files.isEmpty else { return }
        do {
            let workspace = try existing ?? WorkflowWorkspace(files)
            let window = NSWindow()
            let view = Workbench(files: files, workspace: workspace, close: { [weak window] in window?.close() })
            window.contentViewController = NSHostingController(rootView: view)
            window.title = "Honeycomb · Tools"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
            window.backgroundColor = .clear; window.isOpaque = false
            window.setContentSize(NSSize(width: 530, height: 630)); window.minSize = NSSize(width: 440, height: 475)
            window.center(); window.delegate = self; windows[ObjectIdentifier(window)] = window
            showAppWindow(window)
        } catch { finishJob("Open tools", outputs: [], originals: files, error: error) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.removeValue(forKey: ObjectIdentifier(window)) }
        updateActivationAfterClose()
    }
}

struct Workbench: View {
    let files: [URL]
    let workspace: WorkflowWorkspace
    let close: () -> Void
    @ObservedObject var store = Store.shared
    @HCState private var query = ""
    @HCState private var format = ""
    @HCState private var archive = false
    @HCState private var options = false
    @HCState private var quality = 90.0
    @HCState private var pages = ""
    @HCState private var mode = ""
    @HCState private var confirmTrash = false
    @HCState private var catalogRevision = 0
    var formats: [String] { let _ = catalogRevision; return availableTargets(files) }
    var tools: [ToolID] {
        let types = files.filter { !isFolder($0) }.compactMap(FileFormat.detect)
        return types.count == files.count ? ToolID.available(for: types) : []
    }
    var filteredFormats: [String] { formats.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var filteredTools: [ToolID] { tools.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var presets: [FileeBridge.PresetRoute] { let _ = catalogRevision; return availablePresets(files) }
    var filteredPresets: [FileeBridge.PresetRoute] { presets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var exportLabel: String {
        if archive { return "Create ZIP" }
        if format.isEmpty { return "Save copies" }
        if let preset = presets.first(where: { $0.selection == format }) { return preset.name }
        return format == "folder" ? "Extract" : "Convert to " + format.uppercased()
    }
    var staged: Bool { files != workspace.originals }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hexagon").font(.title2)
                VStack(alignment: .leading) {
                    Text(staged ? "Continue editing" : "File tools").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) selected files").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            TextField("Search formats and tools", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !filteredTools.isEmpty {
                        Text("TOOLS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 7) {
                            ForEach(filteredTools) { tool in
                                Button { ToolWindowManager.shared.open(tool, files: files, workspace: workspace); close() } label: {
                                    Label(tool.title, systemImage: tool.symbol).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if !filteredFormats.isEmpty {
                        Text("CONVERT TO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74))], spacing: 7) {
                            ForEach(filteredFormats, id: \.self) { item in
                                Button(Choice(id: item).title) { format = item }
                                    .buttonStyle(.bordered).tint(format == item ? Color.black : Color.gray)
                                    .help(FileeBridge.shared.routes(fileeExtension(files[0]))?.withEngines.contains(item) == true ? "Prepares the required engine when used" : "Convert to \(item.uppercased())")
                            }
                        }
                    }
                    if !filteredPresets.isEmpty {
                        Text("PRESETS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154))], spacing: 7) {
                            ForEach(filteredPresets) { preset in
                                Button(preset.name) { format = preset.selection }
                                    .buttonStyle(.bordered).tint(format == preset.selection ? Color.black : Color.gray)
                            }
                        }
                    }
                    if query.isEmpty {
                        HStack {
                            Button("Reveal") { FileAction.reveal.run(files) }
                            if !staged { Button("Copy files") { FileAction.copy.run(files) } }
                            Button("Copy paths") { FileAction.paths.run(files) }
                            Button("SHA-256") { FileAction.hash.run(files) }
                            if !staged { Button("Duplicate") { FileAction.duplicate.run(files) } }
                        }.controlSize(.small)
                    }
                    if !format.isEmpty {
                        DisclosureGroup("Export options", isExpanded: $options) {
                            if !archive {
                                Picker("After converting", selection: $mode) {
                                    Text("Keep originals").tag("")
                                    Text("Copy outputs to clipboard").tag("clipboard")
                                    if !staged { Text("Move originals to Trash").tag("trash") }
                                }
                            }
                            if FileeBridge.shared.available, imageExt.contains(format) {
                                LabeledSlider(title: "Quality", value: $quality, range: 1...100, format: { "\(Int($0))%" })
                            }
                            if FileeBridge.shared.available, files.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
                                TextField("Pages, e.g. 1-3, 5", text: $pages)
                            }
                        }
                    }
                }.padding(2)
            }
            Divider()
            HStack {
                Toggle("ZIP outputs", isOn: $archive)
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(exportLabel) {
                    if !archive && !staged && mode == "trash" && !format.isEmpty { confirmTrash = true }
                    else { export() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(format.isEmpty && !archive && !staged)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Glass(tint: store.config.uiTint, strength: store.config.tintStrength))
        .preferredColorScheme(.light)
        .onAppear { FileeBridge.shared.prepare(files) { catalogRevision += 1 } }
        .alert("Move originals to Trash after conversion?", isPresented: $confirmTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Convert and Trash", role: .destructive) { export() }
        }
    }
    func export() {
        let advanced = FileeBridge.shared.available
        let adjustedQuality = advanced && imageExt.contains(format) && quality != 90 ? Int(quality) : nil
        let pageRange = advanced && files.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) && !pages.isEmpty ? pages : nil
        submitWorkflow(files, workspace: workspace, target: format.isEmpty ? nil : format, archive: archive, separate: store.config.separateArchives, quality: adjustedQuality, pages: pageRange, mode: archive ? nil : mode)
        close()
    }
}


import AppKit
import SwiftUI

@MainActor
func showAppWindow(_ window: NSWindow) {
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}

@MainActor
func updateActivationAfterClose() {
    DispatchQueue.main.async {
        let hasWindow = NSApp.windows.contains { window in
            !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
        if !hasWindow { NSApp.setActivationPolicy(.accessory) }
    }
}

func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

struct GlassTint: Codable {
    var red = 0.57, green = 0.69, blue = 0.82
    var color: NSColor { NSColor(srgbRed: min(1,max(0,red)), green: min(1,max(0,green)), blue: min(1,max(0,blue)), alpha: 1) }
    init() {}
    init(_ color: Color) {
        if let rgb = NSColor(color).usingColorSpace(.sRGB) { red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent }
    }
}

struct Glass: NSViewRepresentable {
    var tint = NSColor.white
    var strength: Double = 0
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        let veil = NSView(frame: view.bounds); veil.wantsLayer = true; veil.autoresizingMask = [.width, .height]
        view.addSubview(veil)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let base = NSColor(white: 0.99, alpha: 1)
        view.subviews.first?.layer?.backgroundColor = (base.blended(withFraction: strength * 0.43, of: tint) ?? base).withAlphaComponent(opaque ? 1 : 0.55 + strength * 0.16).cgColor
    }
}

enum Theme {
    static var accentNS: NSColor {
        NSColor(white: 0.20, alpha: 1).blended(withFraction: Store.shared.config.tintStrength * 0.55, of: Store.shared.config.uiTint) ?? .darkGray
    }
    static var accent: Color { Color(nsColor: accentNS) }
    static let cardCorner: CGFloat = 13
    static func isDark(_ appearance: NSAppearance) -> Bool { false }
}
extension View {
    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        self.background(.white.opacity(0.32), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.60), lineWidth: 1).allowsHitTesting(false) }
    }
}

final class HexView: NSView {
    let glass = NSVisualEffectView()
    let border = CAShapeLayer()
    let wash = CAShapeLayer()
    let shine = CAGradientLayer()
    let tint: NSColor
    let strength: Double
    let center: Bool
    init(frame: NSRect, title: String, icon: String, center: Bool) {
        tint = Store.shared.config.uiTint; strength = Store.shared.config.tintStrength; self.center = center
        super.init(frame: frame)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer?.position = CGPoint(x: frame.midX, y: frame.midY)
        layer?.masksToBounds = false
        let path = roundedHex(bounds.insetBy(dx: 0.75, dy: 0.75), radius: 9)
        glass.frame = bounds; glass.material = .popover; glass.blendingMode = .behindWindow
        glass.state = .active; glass.appearance = NSAppearance(named: .aqua); glass.wantsLayer = true
        let mask = CAShapeLayer(); mask.path = path; glass.layer?.mask = mask
        addSubview(glass)
        wash.path = path; wash.fillColor = surface(active: false).cgColor; glass.layer?.addSublayer(wash)
        shine.frame = bounds; shine.colors = [NSColor.white.withAlphaComponent(0.48).cgColor, NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.19).cgColor]
        shine.locations = [0, 0.57, 1]; glass.layer?.addSublayer(shine)

        let edge = NSView(frame: bounds); edge.wantsLayer = true
        border.path = path; border.fillColor = NSColor.clear.cgColor; border.strokeColor = NSColor.white.withAlphaComponent(0.77).cgColor; border.lineWidth = 1
        edge.layer?.addSublayer(border); addSubview(edge)
        let text = NSTextField(labelWithString: title); text.alignment = .center
        let font = NSFont.systemFont(ofSize: title.count > 7 ? 12.5 : center ? 16 : 19, weight: center ? .medium : .semibold)
        text.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        text.textColor = NSColor(white: center ? 0.32 : 0.09, alpha: 1)
        text.lineBreakMode = .byTruncatingTail
        text.frame = NSRect(x: 4, y: bounds.midY-(center ? 13 : 20), width: bounds.width-8, height: 26)
        addSubview(text)
        if !center {
            let symbol = NSImageView()
            symbol.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
            symbol.contentTintColor = NSColor(white: 0.20, alpha: 1)
            symbol.frame = NSRect(x: bounds.midX-11, y: bounds.midY+9, width: 22, height: 21)
            addSubview(symbol)
        }
        layer?.shadowPath = path; layer?.shadowRadius = 6; layer?.shadowOpacity = 0.18
        layer?.shadowOffset = CGSize(width: 0, height: -2); layer?.shadowColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }
    func surface(active: Bool) -> NSColor {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let base = NSColor(white: active ? 1 : center ? 0.94 : 0.98, alpha: 1)
        return (base.blended(withFraction: strength * (active ? 0.35 : 0.23), of: tint) ?? base).withAlphaComponent(opaque ? 1 : active ? 0.83 : center ? 0.59 : 0.63)
    }
    func hover(_ active: Bool, dim: Bool) {
        guard let layer = layer else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.075)
        let scale: CGFloat = active ? 1.055 : 1
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.zPosition = active ? 2 : 0
        layer.shadowColor = (active ? NSColor.white.blended(withFraction: strength * 0.35, of: tint) ?? .white : .black).cgColor
        layer.shadowOpacity = active ? 0.55 : 0.18; layer.shadowRadius = active ? 11 : 6
        wash.fillColor = surface(active: active).cgColor
        border.strokeColor = NSColor.white.withAlphaComponent(active ? 0.98 : 0.72).cgColor
        border.lineWidth = active ? 1.5 : 1
        layer.opacity = dim ? 0.93 : 1; CATransaction.commit()
    }
    func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = 0.45; animation.toValue = 1
        animation.duration = 0.04; animation.autoreverses = true; wash.add(animation, forKey: "pulse")
    }
}

struct MainView: View {
    @ObservedObject var store = Store.shared
    @HCState private var permissionsOpen = false
    @HCState private var appearanceOpen = false
    var allPermissions: Bool { store.ax && store.input && store.automation }
    var statusText: String {
        if !store.config.enabled { return "Paused" }
        if !store.ax { return "Grant Accessibility to use the gesture" }
        if !store.input { return "Grant Input Monitoring to use the gesture" }
        if !store.automation { return "Allow Finder access to read your selection" }
        if !store.tapOK { return "Gesture unavailable · restart Honeycomb" }
        return store.gestureStatus.hasPrefix("Ready") || store.gestureStatus.hasPrefix("Waiting") ? Gesture.shared.readyText : store.gestureStatus
    }
    func permission(_ title: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(.secondary)
            Text(title); Spacer(); Button(ok ? "Settings" : "Enable", action: action).controlSize(.small)
        }.font(.system(size: 12))
    }
    func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack { Text(title).font(.system(size: 12)); Spacer(); control() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hexagon.fill").font(.system(size: 22, weight: .medium)).frame(width: 42, height: 42)
                    .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Honeycomb").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Convert and edit from your desktop.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { store.config.enabled }, set: { store.config.enabled = $0; store.save(); if !$0 { Gesture.shared.abort(); Gesture.shared.open = false; Overlay.shared.dismiss() } })).labelsHidden().toggleStyle(.switch)
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup(isExpanded: $permissionsOpen) {
                            VStack(spacing: 8) {
                                permission("Accessibility", store.ax) { if !store.ax { requestAccessibility() }; settings("Privacy_Accessibility") }
                                permission("Input Monitoring", store.input) { _ = CGRequestListenEventAccess(); settings("Privacy_ListenEvent") }
                                permission("Automation · Finder", store.automation) { finderPermission(true); settings("Privacy_Automation") }
                            }.padding(.top, 8)
                        } label: {
                            Label(allPermissions ? "Permissions granted" : "Permissions need attention", systemImage: allPermissions ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 12, weight: .semibold))
                        }
                        Text(statusText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).card()
                    VStack(alignment: .leading, spacing: 10) {
                        row("Gesture") {
                            Picker("Gesture", selection: Binding(get: { store.config.gestureMode }, set: {
                                Gesture.shared.abort(); Overlay.shared.dismiss(); Gesture.shared.open = false
                                store.config.gestureMode = $0; store.save()
                            })) {
                                Text("Shortcut + move").tag("shortcut")
                                Text("Option + click-and-hold").tag("clickHold")
                            }.labelsHidden().frame(width: 195)
                        }
                        if store.config.gestureMode == "shortcut" {
                            row("Shortcut") { ShortcutRecorder().frame(width: 150, height: 25).help("Click, then press your shortcut. Escape cancels.") }
                        } else {
                            LabeledSlider(title: "Hold time", value: Binding(get: { store.config.holdMilliseconds }, set: { store.config.holdMilliseconds = $0; store.save() }), range: 150...600, format: { "\(Int($0)) ms" })
                        }
                        row("Start at login") {
                            Toggle("Start at login", isOn: Binding(get: { store.config.startAtLogin }, set: { store.config.startAtLogin = $0; setLogin($0); store.save() })).labelsHidden().toggleStyle(.switch)
                        }
                    }.padding(12).card()
                    DisclosureGroup(isExpanded: $appearanceOpen) {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Tint color") {
                                ColorPicker("Tint color", selection: Binding(get: { Color(nsColor: store.config.uiTint) }, set: {
                                    store.config.glassTint = GlassTint($0); if store.config.tintStrength == 0 { store.config.tintStrength = 0.25 }; store.save()
                                }), supportsOpacity: false).labelsHidden()
                            }
                            LabeledSlider(title: "Tint strength", value: Binding(get: { store.config.tintStrength }, set: { store.config.tintStrength = $0; store.save() }), range: 0...1, format: { "\(Int($0*100))%" })
                            HStack { Spacer(); Button("Reset to neutral") { store.config.glassTint = GlassTint(); store.config.tintStrength = 0; store.save() }.controlSize(.small) }
                        }.padding(.top, 8)
                    } label: { Label("Glass appearance", systemImage: "circle.lefthalf.filled").font(.system(size: 12, weight: .semibold)) }
                    .padding(12).card()
                    row("Separate ZIPs for batches") {
                        Toggle("Separate ZIPs for batches", isOn: Binding(get: { store.config.separateArchives }, set: { store.config.separateArchives = $0; store.save() })).labelsHidden().toggleStyle(.switch)
                    }.padding(.horizontal, 4)
                    HStack {
                        Text("RECENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open files…") {
                            let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = true
                            if picker.runModal() == .OK { WorkbenchWindow.shared.open(picker.urls) }
                        }.controlSize(.small)
                    }
                    if store.recent.isEmpty {
                        Text("Your conversions and edits appear here.").font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(store.recent) { record in
                        HStack(spacing: 8) {
                            Image(systemName: record.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title).font(.system(size: 12, weight: .medium))
                                Text(record.paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting(record.paths.map { URL(fileURLWithPath: $0) }) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
                        }.padding(10).card(cornerRadius: 10)
                    }
                    if !FileeBridge.shared.available {
                        Text("Extended formats are not installed. See setup details.").font(.caption).foregroundStyle(.secondary)
                        Button("Open install log") { NSWorkspace.shared.open(home.appendingPathComponent("install.log")) }.controlSize(.small)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Test menu") { Gesture.shared.test() }
                Spacer()
                Button("Restart") { AppDelegate.shared?.restart() }
                Button("Quit") { NSApp.terminate(nil) }
            }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
        }.background(Glass(tint: store.config.uiTint, strength: store.config.tintStrength))
        .preferredColorScheme(.light).tint(Theme.accent)
    }
}


import AppKit
import SwiftUI
import PDFKit

struct PDFCropPreview {
    let image: NSImage
    let size: CGSize
    let fromPDF: CGAffineTransform
}
func pdfCropPreview(_ page: PDFPage) -> PDFCropPreview? {
    guard let ref = page.pageRef else { return nil }
    let box = ref.getBoxRect(.cropBox)
    let rotated = ref.rotationAngle % 180 != 0
    let width = rotated ? box.height : box.width, height = rotated ? box.width : box.height
    guard width > 0, height > 0 else { return nil }
    let scale = min(1000 / max(width,height), 2)
    let pixels = CGSize(width: max(1, (width*scale).rounded()), height: max(1, (height*scale).rounded()))
    let rect = CGRect(origin: .zero, size: pixels)
    guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let transform = ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: false)
    context.setFillColor(NSColor.white.cgColor); context.fill(rect)
    context.concatenate(transform); context.drawPDFPage(ref)
    guard let image = context.makeImage() else { return nil }
    return PDFCropPreview(image: NSImage(cgImage: image, size: pixels), size: pixels, fromPDF: transform)
}
func cropPDFPages(_ source: URL, normalized: CGRect, pageIndex: Int?, to output: URL) throws {
    guard let document = PDFDocument(url: source), !document.isLocked else { throw HCError("Cannot open this PDF.") }
    for i in 0..<document.pageCount where pageIndex == nil || i == pageIndex {
        guard let page = document.page(at: i), let ref = page.pageRef else { continue }
        let target = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let transform = ref.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: false)
        let box = CGRect(x: normalized.minX * 1000, y: (1-normalized.maxY) * 1000, width: normalized.width * 1000, height: normalized.height * 1000)
        let clipped = box.applying(transform.inverted()).intersection(ref.getBoxRect(.cropBox))
        guard !clipped.isEmpty else { throw HCError("The crop is outside the page.") }
        page.setBounds(clipped, for: .cropBox)
    }
    guard document.write(to: output) else { throw HCError("Could not save the cropped PDF.") }
}
struct CropPDFToolView: View {
    let session: ToolSession
    @HCState private var document: PDFDocument?
    @HCState private var preview: PDFCropPreview?
    @HCState private var page = 0
    @HCState private var allPages = false
    @HCState private var rects: [RectangleOverlay] = []
    @HCState private var selection: UUID?
    var body: some View {
        ToolShell(session: session, saveEnabled: rects.first?.rect.isEmpty == false, onSave: save) {
            if let preview = preview {
                RectangleEditorCanvas(image: preview.image, imageSize: preview.size, rectangles: $rects, selected: $selection, allowMultiple: false)
                    .padding(12)
            } else { Text("This PDF cannot be previewed.").foregroundStyle(.secondary) }
        } sidebar: {
            SidebarSection(title: "Crop pages") {
                Picker("Preview page", selection: $page) {
                    ForEach(0..<(document?.pageCount ?? 0), id: \.self) { Text("Page \($0+1)").tag($0) }
                }
                Toggle("Apply this crop to every page", isOn: $allPages)
                Text("Drag the crop frame. The PDF remains searchable. Cropping changes page boundaries; use a redaction tool to remove sensitive content.").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { document = PDFDocument(url: session.primary); updatePreview() }
        .onChange(of: page) { _ in updatePreview() }
    }
    func updatePreview() {
        preview = document?.page(at: page).flatMap(pdfCropPreview)
        if let preview = preview {
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: CGRect(origin: .zero, size: preview.size).insetBy(dx: preview.size.width*0.08, dy: preview.size.height*0.08), color: Theme.accent, label: "")]
            selection = id
        } else { rects = [] }
    }
    func save() {
        guard let preview = preview, let crop = rects.first?.rect, !crop.isEmpty else { return }
        let normalized = CGRect(x: crop.minX/preview.size.width, y: crop.minY/preview.size.height, width: crop.width/preview.size.width, height: crop.height/preview.size.height)
        let index = allPages ? nil : page, source = session.primary, output = session.outputURL(suffix: "cropped", ext: "pdf")
        session.run(title: "Cropping PDF", detail: source.lastPathComponent) { _ in
            try cropPDFPages(source, normalized: normalized, pageIndex: index, to: output)
            return [output]
        }
    }
}


func radialOptions(files: [URL], ordered: [String], test: Bool) -> [Choice] {
    let formats = test ? [.heic] : files.filter { !$0.hasDirectoryPath }.compactMap { FileFormat.detect(extension: fileeExtension($0)) }
    var tools = formats.count == files.count || test ? ToolID.available(for: formats) : []
    let priority: [ToolID] = [.cropImage, .cropVideo, .cropPDF, .resizeImage, .trimVideo, .trimAudio, .mergePDF]
    let primary = priority.filter { tools.contains($0) }
    tools.removeAll { primary.contains($0) }
    let remaining = ordered.dropFirst(5)
    let actions = ["zip", "compress", "clipboard", "trash"].filter { remaining.contains($0) }
    let targets = remaining.filter { !actions.contains($0) }
    return primary.map { Choice(id: "tool:" + $0.rawValue) }
        + actions.prefix(2).map { Choice(id: $0) }
        + targets.map { Choice(id: $0) }
        + tools.map { Choice(id: "tool:" + $0.rawValue) }
        + availablePresets(files).map { Choice(id: $0.selection, label: $0.name) }
        + actions.dropFirst(2).map { Choice(id: $0) }
}

func radialPage(_ options: [Choice], index: Int, back: Bool) -> [Choice] {
    let count = back ? 4 : 5
    let start = index * count
    var visible = Array(options.dropFirst(start).prefix(count))
    if back { visible.append(Choice(id: "back")) }
    if options.count > start + count { visible.append(Choice(id: "more")) }
    return visible
}


let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
