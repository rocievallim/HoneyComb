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
struct Config: Codable {
    var holdMilliseconds: Double = 250
    var enabled: Bool = true
    var startAtLogin: Bool = true
    var darkGlass: Bool = true
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
            config = value
            if oldLogin != value.startAtLogin { setLogin(value.startAtLogin) }
        } catch { log("Config unchanged; invalid JSON: \(error.localizedDescription)") }
    }
    func permissions() {
        ax = AXIsProcessTrusted(); input = CGPreflightListenEventAccess()
        if ax && !tapOK { Gesture.shared.install() }
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
func targets(_ ext: String) -> [String] {
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
struct Choice {
    var id: String
    var title: String {
        switch id { case "compress": return "Compress"; case "trash": return "Trash…"; case "clipboard": return "Copy…"; case "zip": return "ZIP"; case "more": return "More"; default: return id.uppercased() }
    }
    var icon: String {
        switch id { case "compress": return "arrow.down.right.and.arrow.up.left"; case "trash": return "trash"; case "clipboard": return "doc.on.clipboard"; case "zip": return "archivebox"; case "more": return "ellipsis"; default:
            switch category(id) { case "images": return "photo"; case "audio": return "waveform"; case "video": return "film"; default: return "doc.text" }
        }
    }
    var color: NSColor {
        if ["compress", "trash", "clipboard", "zip", "more"].contains(id) { return .systemOrange }
        switch category(id) { case "images": return .systemBlue; case "audio": return .systemPurple; case "video": return .systemRed; default: return .systemGreen }
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
                if folder { stem += " \(target.uppercased()) pages" }
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
final class HexView: NSView {
    let glass = NSVisualEffectView()
    let border = CAShapeLayer()
    let wash = CAShapeLayer()
    let text = NSTextField(labelWithString: "")
    let symbol = NSImageView()
    let color: NSColor
    init(frame: NSRect, title: String, icon: String, color: NSColor, center: Bool, dark: Bool) {
        self.color = color; super.init(frame: frame)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer?.position = CGPoint(x: frame.midX, y: frame.midY)
        layer?.masksToBounds = false
        glass.frame = bounds; glass.autoresizingMask = [.width, .height]; glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active; glass.wantsLayer = true
        glass.appearance = dark ? NSAppearance(named: .darkAqua) : nil
        let path = roundedHex(bounds.insetBy(dx: 1, dy: 1))
        let mask = CAShapeLayer(); mask.path = path; glass.layer?.mask = mask; addSubview(glass)
        wash.path = path; wash.fillColor = color.withAlphaComponent(center ? 0.05 : 0.13).cgColor; layer?.addSublayer(wash)
        border.path = path; border.fillColor = NSColor.clear.cgColor; border.strokeColor = NSColor.white.withAlphaComponent(0.26).cgColor; border.lineWidth = 0.5; layer?.addSublayer(border)
        text.stringValue = title; text.alignment = .center
        let font = NSFont.systemFont(ofSize: title.count > 6 ? 12 : center ? 15 : 19, weight: .semibold)
        text.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        text.textColor = dark ? .white : .labelColor
        text.frame = NSRect(x: 3, y: bounds.midY - 18, width: bounds.width - 6, height: 25)
        addSubview(text)
        symbol.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        symbol.contentTintColor = center ? .secondaryLabelColor : color
        symbol.frame = NSRect(x: bounds.midX - 8, y: bounds.midY + 10, width: 16, height: 16); addSubview(symbol)
        layer?.shadowColor = color.cgColor; layer?.shadowRadius = 12; layer?.shadowOpacity = 0; layer?.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func hover(_ active: Bool, dim: Bool) {
        guard let layer = layer else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.075)
        layer.transform = CATransform3DMakeScale(active ? 1.12 : 1, active ? 1.12 : 1, 1)
        layer.shadowOpacity = active ? 0.7 : 0
        border.strokeColor = active ? color.withAlphaComponent(0.95).cgColor : NSColor.white.withAlphaComponent(0.26).cgColor
        layer.opacity = dim ? 0.55 : 1; CATransaction.commit()
    }
    func pulse() {
        let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 0.2; pulse.toValue = 0.85; pulse.duration = 0.038; pulse.autoreverses = true
        wash.add(pulse, forKey: "pulse")
    }
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
    var files: [URL] = []
    var mode: String?
    var sourceLabel = "HEIC"
    var active = false
    var testing = false
    var onComplete: ((Choice?) -> Void)?
    var rootPoint = CGPoint.zero
    func show(files: [URL], point: CGPoint, test: Bool = false) {
        self.files = files; testing = test; mode = nil; page = 0; rootPoint = point
        let ext = files.first?.pathExtension.lowercased() ?? "heic"
        sourceLabel = Set(files.map { $0.pathExtension.lowercased() }).count > 1 ? "BATCH" : ext.uppercased()
        if files.count > 1 { sourceLabel += " ×\(files.count)" }
        var common = files.isEmpty ? targets(ext) : targets(ext).filter { target in files.allSatisfy { targets($0.pathExtension.lowercased()).contains(target) } }
        if common.allSatisfy({ ["trash", "clipboard", "zip"].contains($0) }) { common.removeAll { $0 == "trash" || $0 == "clipboard" } }
        menuIDs = Store.shared.ordered(ext, category(ext), common)
        draw(point: point, animate: true)
    }
    func draw(point: CGPoint, animate: Bool) {
        panel?.orderOut(nil); active = true; hover = -1
        let count = menuIDs.count, pageSize = count > 6 ? 5 : 6
        let start = page * pageSize
        choices = Array(menuIDs.dropFirst(start).prefix(pageSize)).map { Choice(id: $0) }
        if count > 6 { choices.append(Choice(id: "more")) }
        let size: CGFloat = 306
        let appPoint = toAppKit(point)
        let screen = NSScreen.screens.first { $0.frame.contains(appPoint) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let x = min(max(visible.minX, appPoint.x-size/2), visible.maxX-size)
        let y = min(max(visible.minY, appPoint.y-size/2), visible.maxY-size)
        let window = NSPanel(contentRect: NSRect(x: x, y: y, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); content.wantsLayer = true; window.contentView = content
        panel = window; hexes = []; paths = []
        let center = CGPoint(x: size/2, y: size/2), r: CGFloat = 49, distance: CGFloat = sqrt(3)*49 + 3
        let dark = Store.shared.config.darkGlass
        let middle = HexView(frame: NSRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r), title: sourceLabel, icon: mode == "trash" ? "trash" : mode == "clipboard" ? "doc.on.clipboard" : testing ? "cursorarrow" : "hexagon", color: .systemGray, center: true, dark: dark)
        content.addSubview(middle)
        if animate {
            let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.55; spring.toValue = 1; spring.mass = 0.35; spring.stiffness = 550; spring.damping = 23; spring.duration = 0.11; middle.layer?.add(spring, forKey: "appear")
        }
        for (index, choice) in choices.enumerated() {
            let a = .pi/2 - CGFloat(index) * .pi/3
            let origin = CGPoint(x: center.x + cos(a)*distance-r, y: center.y + sin(a)*distance-r)
            let rect = CGRect(origin: origin, size: CGSize(width: 2*r, height: 2*r))
            let view = HexView(frame: rect, title: choice.title, icon: choice.icon, color: choice.color, center: false, dark: dark)
            content.addSubview(view); hexes.append(view); paths.append(roundedHex(rect.insetBy(dx: 1, dy: 1)))
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
        if chosen.id == "more" {
            page = (page+1) % max(1, Int(ceil(Double(menuIDs.count)/5)))
            draw(point: rootPoint, animate: false); return true
        }
        if chosen.id == "trash" || chosen.id == "clipboard" {
            mode = chosen.id; page = 0; menuIDs.removeAll { ["trash", "clipboard", "zip", "compress"].contains($0) }
            draw(point: rootPoint, animate: false); return true
        }
        hexes[hover].pulse(); dismiss()
        if !testing { submit(files, target: chosen.id, mode: mode) }
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
    return FinderSnapshot(urls: files, reason: files.isEmpty ? "Select a file in Finder, then hold Option and the left mouse button." : nil)
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
    var pending = false
    var open = false
    var trackingClick = false
    var start = CGPoint.zero
    var buffered: [CGEvent] = []
    var snapshot: FinderSnapshot?
    var token = UUID()
    let replayTag: Int64 = 0x48434F4D42
    var testTimer: Timer?
    var testMode = false
    var lastHealth = Date.distantPast
    var finderPID: pid_t = 0
    func install() {
        guard tap == nil else { return }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .flagsChanged, .keyDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // An active tap buffers the candidate click; early release/motion replays it with a bypass tag.
        guard let value = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<Gesture>.fromOpaque(info).takeUnretainedValue().event(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { Store.shared.tapOK = false; return }
        tap = value; runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, value, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes); CGEvent.tapEnable(tap: value, enable: true); Store.shared.tapOK = true
        finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
        log("Active event tap ready")
    }
    func finderAt(_ point: CGPoint) -> Bool {
        if finderPID == 0 { finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0 }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.025)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element = element {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { return pid == finderPID && pid != 0 }
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    func event(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if e.getIntegerValueField(.eventSourceUserData) == replayTag { return Unmanaged.passUnretained(e) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            abort(); if open { Overlay.shared.dismiss(); open = false }
            trackingClick = CGEventSource.buttonState(.combinedSessionState, button: .left)
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("Event tap re-enabled"); return Unmanaged.passUnretained(e)
        }
        if open {
            if type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode) == 53 {
                Overlay.shared.dismiss(); open = false
                // Keep swallowing the rest of the held click after Escape.
                if trackingClick { pending = false }
                return nil
            }
            if type == .leftMouseDown { trackingClick = true; return nil }
            if type == .leftMouseUp { open = Overlay.shared.release(e.location); trackingClick = false; return nil }
            if type == .leftMouseDragged || type == .mouseMoved { Overlay.shared.update(e.location); return type == .leftMouseDragged ? nil : Unmanaged.passUnretained(e) }
            return Unmanaged.passUnretained(e)
        }
        if trackingClick && !pending {
            if type == .leftMouseUp { trackingClick = false; return nil }
            if type == .leftMouseDragged || type == .leftMouseDown { return nil }
        }
        if pending {
            if type == .leftMouseDragged || type == .leftMouseUp {
                if let copy = e.copy() { buffered.append(copy) }
                if type == .leftMouseUp || hypot(e.location.x-start.x, e.location.y-start.y) > 5 { abort() }
                return nil
            }
            if type == .flagsChanged && !e.flags.contains(.maskAlternate) { abort() }
            return Unmanaged.passUnretained(e)
        }
        guard Store.shared.config.enabled, type == .leftMouseDown, e.flags.contains(.maskAlternate), !e.flags.contains(.maskCommand), !e.flags.contains(.maskControl), finderAt(e.location) else { return Unmanaged.passUnretained(e) }
        pending = true; start = e.location; buffered = e.copy().map { [$0] } ?? []; snapshot = nil; token = UUID(); let current = token
        let clickPoint = e.location
        finderQueue.async {
            let result = readFinder(at: clickPoint)
            DispatchQueue.main.async {
                guard self.pending && self.token == current else { return }
                self.snapshot = result
            }
        }
        let delay = Store.shared.config.holdMilliseconds / 1000
        let work = DispatchWorkItem { [weak self] in self?.activate(current) }; timer = work
        // The timer never waits for AppleScript; a slow/denied query restores the ordinary click.
        DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
        return nil
    }
    func activate(_ current: UUID) {
        guard pending, token == current else { return }
        guard Store.shared.config.enabled, CGEventSource.buttonState(.combinedSessionState, button: .left), let result = snapshot, !result.urls.isEmpty else {
            let reason = snapshot?.reason; abort()
            if let reason = reason { Notices.shared.send("Honeycomb", reason, []) }
            return
        }
        pending = false; buffered = []; timer = nil; open = true; trackingClick = true
        Overlay.shared.show(files: result.urls, point: start)
    }
    func abort() {
        timer?.cancel(); timer = nil; pending = false; token = UUID(); snapshot = nil
        let events = buffered; buffered = []
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: replayTag); event.post(tap: .cghidEventTap) }
    }
    func test() {
        if pending { abort() }; Overlay.shared.dismiss(); open = false
        let point = CGEvent(source: nil)?.location ?? .zero
        Overlay.shared.show(files: [], point: point, test: true)
        if tap != nil { open = true; return }
        testMode = true
        testTimer?.invalidate()
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Overlay.shared.update(CGEvent(source: nil)?.location ?? point)
            if !Overlay.shared.active { self.testTimer?.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self = self, self.testMode else { return }; self.testTimer?.invalidate(); Overlay.shared.dismiss(); self.testMode = false
        }
    }
}
struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct MainView: View {
    @ObservedObject var store = Store.shared
    func permission(_ title: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack { Circle().fill(ok ? Color.green : Color.red).frame(width: 7, height: 7); Text(title).font(.system(size: 12)); Spacer(); Button(ok ? "Settings" : "Enable", action: action).controlSize(.small) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "hexagon.fill").font(.system(size: 31)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) { Text("Honeycomb").font(.system(size: 25, weight: .semibold, design: .rounded)); Text("Hold. Choose. Keep working.").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Toggle("On", isOn: Binding(get: { store.config.enabled }, set: { store.config.enabled = $0; store.save(); if !$0 { if Gesture.shared.pending { Gesture.shared.abort() }; if Gesture.shared.open { Gesture.shared.open = false; Overlay.shared.dismiss() } } })).labelsHidden().toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 7) {
                permission("Accessibility", store.ax) { let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary; _ = AXIsProcessTrustedWithOptions(opts); settings("Privacy_Accessibility") }
                permission("Input Monitoring", store.input) { _ = CGRequestListenEventAccess(); settings("Privacy_ListenEvent") }
                permission("Automation · Finder", store.automation) { finderPermission(true); settings("Privacy_Automation") }
                if store.ax && !store.tapOK { Text("Waiting for macOS. Restart Honeycomb after granting access.").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Hold time"); Spacer(); Text("\(Int(store.config.holdMilliseconds)) ms").foregroundStyle(.secondary) }.font(.system(size: 12))
                Slider(value: Binding(get: { store.config.holdMilliseconds }, set: { store.config.holdMilliseconds = $0; store.save() }), in: 150...600, step: 10)
                Toggle("Start at login", isOn: Binding(get: { store.config.startAtLogin }, set: { store.config.startAtLogin = $0; setLogin($0); store.save() })).font(.system(size: 12))
            }
            HStack { Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button("Test menu") { Gesture.shared.test() }.controlSize(.small) }
            ScrollView {
                VStack(spacing: 8) {
                    if store.recent.isEmpty { Text("Your last 10 conversions appear here.\nSelect files in Finder, then hold Option + click.\nMore cycles formats; Trash… and Copy… open a target menu.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 15) }
                    ForEach(store.recent) { record in
                        HStack(spacing: 8) {
                            Image(systemName: record.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(record.failed ? Color.orange : Color.green)
                            VStack(alignment: .leading, spacing: 2) { Text(record.title).font(.system(size: 11, weight: .medium)); Text(record.paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting(record.paths.map { URL(fileURLWithPath: $0) }) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
                        }.padding(8).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }.frame(height: 168)
            HStack {
                Button("Edit settings") { NSWorkspace.shared.open(store.configURL) }.controlSize(.small)
                Spacer(); Button("Restart") { AppDelegate.shared?.restart() }.controlSize(.small); Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }.padding(22).frame(width: 374).background(Glass()).preferredColorScheme(store.config.darkGlass ? .dark : nil)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 418, height: 570), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Honeycomb"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self; window.backgroundColor = .clear; window.isOpaque = false
        window.contentView = NSHostingView(rootView: MainView()); window.center()
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
        log("Honeycomb started")
    }
    @objc func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); finderPermission(false) }
    @objc func toggle() { Store.shared.config.enabled.toggle(); Store.shared.save(); if !Store.shared.config.enabled { Gesture.shared.abort(); Gesture.shared.open = false; Overlay.shared.dismiss() } }
    @objc func quit() { NSApp.terminate(nil) }
    func restart() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; /usr/bin/open -n /Applications/Honeycomb.app"]
        try? p.run(); NSApp.terminate(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Gesture.shared.abort(); if let tap = Gesture.shared.tap { CGEvent.tapEnable(tap: tap, enable: false) }; log("Honeycomb stopped") }
}

func makeIcon(_ directory: URL) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]
    for (name, pixels) in sizes {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HCError("Icon allocation failed.") }
        ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let bg = CGPath(roundedRect: CGRect(x: 35, y: 35, width: 954, height: 954), cornerWidth: 218, cornerHeight: 218, transform: nil)
        ctx.addPath(bg); ctx.clip()
        let colors = [NSColor(srgbRed: 0.19, green: 0.20, blue: 0.23, alpha: 1).cgColor, NSColor(srgbRed: 0.045, green: 0.05, blue: 0.065, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0,1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 1024), end: CGPoint(x: 800, y: 0), options: [])
        let radius: CGFloat = 120, distance: CGFloat = 215
        var centers = [CGPoint(x: 512, y: 512)]
        for i in 0..<6 { let a = CGFloat.pi / 2 - CGFloat(i) * .pi / 3; centers.append(CGPoint(x:512+cos(a)*distance,y:512+sin(a)*distance)) }
        for (i, point) in centers.enumerated() {
            let shape = roundedHex(CGRect(x: point.x-radius,y:point.y-radius,width:radius*2,height:radius*2), radius: 21)
            ctx.setShadow(offset: CGSize(width: 0, height: -9), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor(srgbRed: 1, green: i == 0 ? 0.83 : 0.65+Double(i)*0.025, blue: i == 0 ? 0.30 : 0.09, alpha: 1).cgColor)
            ctx.addPath(shape); ctx.fillPath(); ctx.setShadow(offset: .zero, blur: 0)
            ctx.addPath(shape); ctx.setLineWidth(3); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor); ctx.strokePath()
        }
        guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw HCError("Icon encoding failed.") }
        try png.write(to: directory.appendingPathComponent(name+".png"))
    }
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--make-icon" {
    do { try makeIcon(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)); exit(0) }
    catch { fputs("Icon error: \(error.localizedDescription)\n", stderr); exit(1) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
