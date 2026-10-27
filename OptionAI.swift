// optionai — system-wide "agent at the cursor" for macOS
//
// Option+A+I (two-hand chord) → capture the focused textbox's context → send it to a
// coding agent (claude -p) → paste the response at the cursor.
// Option+L+M uses the same workflow with a local Qwen model through Ollama.
//
// Context rule (simple, by design):
//   1. Highlighted text → the highlight is the context. Works everywhere:
//      native apps via AX; web canvas apps (Google Docs) via an invisible
//      copy transaction that restores your clipboard afterward.
//   2. No highlight, readable textbox → the whole document is the context,
//      split at the cursor.
//   3. No highlight and nothing readable → beep. Highlight first.
//
// Build:   ./build.sh
// Install: ./install.sh

import AppKit
import ApplicationServices
import Foundation
import WebKit

// MARK: - Config

struct Config {
    var claudeBinary: String
    var model: String?
    var timeoutSeconds: Double
    var maxContextChars: Int
    var orbDir: URL?
    var orbFollowsMouse: Bool

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let claude =
            env["CLAUDE_CLI"]
            ?? which("claude")
            ?? firstExisting([
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
            ?? "claude"

        let orbDir =
            env["OPTIONAI_ORB_DIR"].map { URL(fileURLWithPath: $0) }
            ?? firstExisting([
                "\(home)/.local/share/optionai/orb",
            ]).map { URL(fileURLWithPath: $0) }

        // Empty env values (e.g. an unset plist key) mean "not set".
        let model = env["OPTIONAI_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Config(
            claudeBinary: claude,
            model: (model?.isEmpty == false) ? model : nil,
            timeoutSeconds: Double(env["OPTIONAI_TIMEOUT"] ?? "") ?? 180,
            maxContextChars: Int(env["OPTIONAI_MAX_CONTEXT"] ?? "") ?? 100_000,
            orbDir: orbDir,
            orbFollowsMouse: (env["OPTIONAI_ORB_MODE"] ?? "follow") != "caret"
        )
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func which(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Context capture (Accessibility)

enum CapturedContext {
    case selection(String)
    case document(before: String, after: String)
    case webSelection(String)
}

struct Capture {
    let context: CapturedContext
    let appPID: pid_t
    let appName: String
    let caretScreenPoint: NSPoint?  // Cocoa coords (bottom-left origin)
}

enum ContextCapturer {

    enum CaptureError: LocalizedError {
        case tooLong

        var errorDescription: String? {
            "The text is too long for local capture. Select a shorter excerpt; nothing was sent."
        }
    }

    static func capture(maxChars: Int, requireComplete: Bool = false) throws -> Capture? {
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier ?? 0
        let appName = front?.localizedName ?? "unknown"

        if !AXIsProcessTrusted() {
            fputs(
                "optionai: Accessibility not granted\n",
                stderr
            )
        }

        var element = focusedElement()
        var selected = element.flatMap { stringAttr($0, kAXSelectedTextAttribute) }
        var value = element.flatMap { stringAttr($0, kAXValueAttribute) }

        // Electron/Chromium apps (Obsidian, Chrome, VS Code) keep their AX
        // tree dormant until an assistive client announces itself. Poke the
        // app element and retry once.
        if (selected?.isEmpty ?? true), (value?.isEmpty ?? true), pid != 0 {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(
                appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue
            )
            AXUIElementSetAttributeValue(
                appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
            )
            usleep(300_000)
            element = focusedElement()
            selected = element.flatMap { stringAttr($0, kAXSelectedTextAttribute) }
            value = element.flatMap { stringAttr($0, kAXValueAttribute) }
            // Undo the window-manager-visible flag; the tree stays warm.
            AXUIElementSetAttributeValue(
                appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse
            )
            if !(value?.isEmpty ?? true) || !(selected?.isEmpty ?? true) {
                fputs("optionai: AX tree woke up after poke (\(appName))\n", stderr)
            }
        }

        let caret = element.flatMap { caretPoint($0) }

        // Rule 1: a native selection is the context.
        if let selected, !selected.isEmpty {
            if requireComplete, selected.count > maxChars { throw CaptureError.tooLong }
            return Capture(
                context: .selection(clamp(selected, maxChars)),
                appPID: pid, appName: appName, caretScreenPoint: caret
            )
        }

        // Rule 2: a readable textbox — the whole document, split at the cursor.
        if let value, !value.isEmpty {
            if requireComplete, value.count > maxChars { throw CaptureError.tooLong }
            let cursor = cursorIndex(element) ?? value.utf16.count
            let (before, after) = split(
                value, at: cursor, maxChars: maxChars, requireComplete: requireComplete
            )
            return Capture(
                context: .document(before: before, after: after),
                appPID: pid, appName: appName, caretScreenPoint: caret
            )
        }

        // Rule 3: opaque app (web canvas, e.g. Google Docs) — the highlight
        // is still the context. AX cannot read it, so optionai copies it itself:
        // a scoped transaction (synthesize ⌘C → detect via changeCount →
        // read → restore the user's clipboard). The clipboard is transport,
        // never an input channel — stale contents are never used.
        if let highlighted = captureSelectionViaCopy() {
            if requireComplete, highlighted.count > maxChars { throw CaptureError.tooLong }
            return Capture(
                context: .webSelection(clamp(highlighted, maxChars)),
                appPID: pid, appName: appName, caretScreenPoint: caret
            )
        }

        return nil
    }

    /// Synthesize ⌘C into the frontmost app and return what it copied,
    /// or nil if nothing was selected. Restores the previous clipboard.
    private static func captureSelectionViaCopy() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        let countBefore = pb.changeCount

        // Let the user release the chord keys so held physical modifiers
        // cannot combine with the synthetic ⌘C.
        usleep(200_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let cKey: CGKeyCode = 0x08 // kVK_ANSI_C
        if let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }

        // Web apps mediate ⌘C through JS; poll briefly for the write.
        var waited: useconds_t = 0
        while pb.changeCount == countBefore, waited < 800_000 {
            usleep(40_000)
            waited += 40_000
        }

        // changeCount unchanged → nothing was selected. Clipboard untouched.
        guard pb.changeCount != countBefore else { return nil }

        let copied = pb.string(forType: .string)

        // Restore the user's clipboard: the copy was ours, not theirs.
        pb.clearContents()
        if let previous {
            pb.setString(previous, forType: .string)
        }

        guard let copied,
            !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return copied
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard err == .success, let ref = focusedRef,
            CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func cursorIndex(_ el: AXUIElement?) -> Int? {
        guard let el else { return nil }
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                el, kAXSelectedTextRangeAttribute as CFString, &ref
            ) == .success,
            let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let axValue = (ref as! AXValue)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Caret bounds via the parameterized bounds-for-range attribute.
    /// AX uses top-left screen coords; convert to Cocoa bottom-left.
    private static func caretPoint(_ el: AXUIElement) -> NSPoint? {
        var rangeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                el, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }

        var boundsRef: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                el,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeRef,
                &boundsRef
            ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }

        let axValue = (boundsRef as! AXValue)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        guard rect.width.isFinite, rect.height.isFinite else { return nil }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: rect.origin.x, y: screenHeight - rect.origin.y - rect.height)
    }

    private static func clamp(_ s: String, _ maxChars: Int) -> String {
        s.count <= maxChars ? s : String(s.suffix(maxChars))
    }

    /// AX offsets are UTF-16. Local requests keep all captured text; the
    /// Claude path retains its existing ~75% before / ~25% after budget.
    private static func split(
        _ s: String, at index: Int, maxChars: Int, requireComplete: Bool
    )
        -> (String, String)
    {
        let offset = max(0, min(index, s.utf16.count))
        let utf16Index = s.utf16.index(s.utf16.startIndex, offsetBy: offset)
        let splitIndex = String.Index(utf16Index, within: s) ?? s.endIndex
        var before = String(s[..<splitIndex])
        var after = String(s[splitIndex...])
        if requireComplete { return (before, after) }
        let beforeBudget = maxChars * 3 / 4
        let afterBudget = maxChars - beforeBudget
        if before.count > beforeBudget { before = String(before.suffix(beforeBudget)) }
        if after.count > afterBudget { after = String(after.prefix(afterBudget)) }
        return (before, after)
    }
}

// MARK: - Agent (claude -p)

final class AgentEngine {
    private let config: Config
    private var process: Process?
    private var generation = 0
    private(set) var isBusy = false

    init(config: Config) {
        self.config = config
    }

    static let instruction = """
        You are OptionAI, a text-insertion agent. The input is the context of a \
        text field on the user's screen. Write ONLY the text to insert at the \
        cursor. No preamble, no explanation, no surrounding quotes, and no \
        markdown code fences unless the document itself is code. Match the \
        document's language, tone, and formatting. If the context contains an \
        instruction or question directed at an assistant near the cursor, \
        fulfill it. If the input is a <selection>, respond to the selection. \
        Otherwise, continue the document naturally from <cursor/>. Never \
        repeat text that is already in the document.
        """

    func run(
        capture: Capture,
        onDone: @escaping (Result<String, Error>) -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        generation += 1
        let gen = generation

        let payload = Self.payload(for: capture.context)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudeBinary)
        var args = ["-p", Self.instruction, "--output-format", "text"]
        if let model = config.model {
            args += ["--model", model]
        }
        p.arguments = args
        // Neutral cwd so no project CLAUDE.md leaks into the context.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory

        var env = ProcessInfo.processInfo.environment
        let basePATH = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePATH
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderrPipe

        do {
            try p.run()
        } catch {
            isBusy = false
            onDone(.failure(error))
            return
        }
        process = p

        // Feed the context and close stdin.
        if let data = payload.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        // Timeout.
        let timeout = config.timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == gen, p.isRunning else { return }
            p.terminate()
            fputs("optionai: agent timed out after \(Int(timeout))s\n", stderr)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.isBusy = false
                self.process = nil

                let status = p.terminationStatus
                let text = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""

                guard status == 0 else {
                    onDone(
                        .failure(
                            NSError(
                                domain: "optionai", code: Int(status),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "claude exited \(status): \(errText)"
                                ]
                            )
                        )
                    )
                    return
                }
                onDone(.success(Self.postProcess(text)))
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        generation += 1
        process?.terminate()
        process = nil
        isBusy = false
    }

    static func payload(for context: CapturedContext) -> String {
        switch context {
        case .selection(let text), .webSelection(let text):
            return "<selection>\n\(text)\n</selection>"
        case .document(let before, let after):
            return "<document>\n\(before)<cursor/>\(after)\n</document>"
        }
    }

    /// Trim, and strip one wrapping code fence if the model added one anyway.
    static func postProcess(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6 {
            var lines = s.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                lines.removeLast()
                s = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }
}

// MARK: - Local model (loopback Ollama only)

enum AgentBackend {
    case claude
    case local

    var label: String { self == .local ? "local Qwen" : "Claude" }
}

/// No configurable URL, model, redirects, proxy, or cloud fallback. Only the
/// final assistant content is eligible for insertion; thinking is never used.
final class LocalAgentEngine: NSObject, URLSessionTaskDelegate {
    static let model = "qwen3.5:9b-q4_K_M"
    static let timeoutSeconds: TimeInterval = 600
    // Ollama 0.34.2 supports disabling both prompt truncation and context
    // shifting. Check the version before sending text so older servers cannot
    // silently ignore these flags. The backend rejects context overflow.
    private static let minimumVersion = [0, 34, 2]

    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var timeoutWork: DispatchWorkItem?
    private var generation = 0
    private(set) var isBusy = false

    private struct Response: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let model: String
        let done: Bool
        let done_reason: String?
        let message: Message
    }

    private static func failure(_ description: String) -> NSError {
        NSError(
            domain: "optionai.local", code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    /// Call and cancel on the main thread; callbacks also arrive there.
    func run(context: CapturedContext, onDone: @escaping (Result<String, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !isBusy else { return }
        let payload = AgentEngine.payload(for: context)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": Self.model,
                "messages": [
                    ["role": "system", "content": AgentEngine.instruction],
                    ["role": "user", "content": payload],
                ],
                "think": false,
                "stream": false,
                "truncate": false,
                "shift": false,
                "keep_alive": "5m",
                "options": [
                    "num_ctx": 32768,
                    "num_predict": 2048,
                    "temperature": 0.2,
                    "top_p": 0.9,
                ],
            ])
        } catch {
            onDone(.failure(Self.failure("Unable to prepare the local model request.")))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        isBusy = true
        generation += 1
        let gen = generation

        let chatTask = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.isBusy else { return }
                self.finish()
                // Never include server bodies or localized network errors in
                // logs: either can contain captured private text.
                if let error = error as NSError? {
                    let description = error.code == NSURLErrorTimedOut
                        ? "Local model timed out after 600 seconds. Try a shorter excerpt."
                        : "Cannot reach the local model. Check that local Ollama is running and the Qwen model is installed."
                    onDone(.failure(Self.failure(description)))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let hint = status == 400
                        ? " The text may exceed the 32K context; select a shorter excerpt."
                        : " Check local Ollama and the installed Qwen model."
                    onDone(.failure(Self.failure("Local model request failed (HTTP \(status))." + hint)))
                    return
                }
                guard let data, let reply = try? JSONDecoder().decode(Response.self, from: data),
                    reply.model == Self.model, reply.done, reply.message.role == "assistant"
                else {
                    onDone(.failure(Self.failure("Local model returned an invalid or incomplete response.")))
                    return
                }
                guard reply.done_reason == "stop" else {
                    onDone(.failure(Self.failure(
                        "Local model stopped before finishing. Ask for a shorter response; nothing was inserted."
                    )))
                    return
                }
                let text = AgentEngine.postProcess(reply.message.content)
                guard !text.isEmpty, !text.contains("<think>"), !text.contains("</think>") else {
                    onDone(.failure(Self.failure("Local model returned no usable final answer.")))
                    return
                }
                onDone(.success(text))
            }
        }
        var versionRequest = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        versionRequest.timeoutInterval = 10
        versionRequest.cachePolicy = .reloadIgnoringLocalCacheData
        versionRequest.httpShouldHandleCookies = false
        let versionTask = session.dataTask(with: versionRequest) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.isBusy else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                    let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let version = object["version"] as? String,
                    Self.supportsCompleteContext(version)
                else {
                    chatTask.cancel()
                    self.finish()
                    onDone(.failure(Self.failure(
                        "Local Ollama 0.34.2 or later must be running with Qwen installed. "
                        + "The local connection/version check failed; no text was sent."
                    )))
                    return
                }
                self.task = chatTask
                chatTask.resume()
            }
        }
        self.task = versionTask
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, self.isBusy else { return }
            self.cancel()
            onDone(.failure(Self.failure("Local model timed out after 600 seconds. Try a shorter excerpt.")))
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeout)
        versionTask.resume()
    }

    private static func supportsCompleteContext(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return false }
        return !numbers.lexicographicallyPrecedes(minimumVersion)
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation += 1
        task?.cancel()
        session?.invalidateAndCancel()
        finish()
    }

    private func finish() {
        timeoutWork?.cancel()
        timeoutWork = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        isBusy = false
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Paste into focused app

enum PasteboardInjector {
    /// Copy text, then simulate ⌘V into the frontmost app.
    /// Requires Accessibility permission.
    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        let previousString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        usleep(80_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V

        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }

        if let previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pb.clearContents()
                pb.setString(previousString, forType: .string)
            }
        }
    }

    /// Leave text on the clipboard without pasting (focus-changed fallback).
    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Orb spinner (thinking-orbs "composing", via WKWebView)

final class OrbPanel {
    private var panel: NSPanel?
    private var followTimer: Timer?
    private let orbDir: URL?
    private let followsMouse: Bool
    private let size: CGFloat = 64

    init(orbDir: URL?, followsMouse: Bool) {
        self.orbDir = orbDir
        self.followsMouse = followsMouse
    }

    /// Panel origin for an anchor point, offset like a cursor badge and
    /// clamped to the anchor's screen.
    private func origin(for anchor: NSPoint) -> NSPoint {
        var origin = NSPoint(x: anchor.x + 14, y: anchor.y - size - 6)
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(anchor)
        }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        return origin
    }

    func show(near point: NSPoint?) {
        guard let orbDir else { return }
        let html = orbDir.appendingPathComponent("orb.html")
        guard FileManager.default.fileExists(atPath: html.path) else { return }

        hide()

        // The real cursor cannot be overridden from a background app, so the
        // orb rides alongside it instead: follow mode tracks the pointer.
        let anchor = followsMouse ? NSEvent.mouseLocation : (point ?? NSEvent.mouseLocation)
        let origin = origin(for: anchor)

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: size, height: size)
        )
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.loadFileURL(html, allowingReadAccessTo: orbDir)
        p.contentView = webView

        p.orderFrontRegardless()
        panel = p

        if followsMouse {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                panel.setFrameOrigin(self.origin(for: NSEvent.mouseLocation))
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: Config!
    private var engine: AgentEngine!
    private let localEngine = LocalAgentEngine()
    private var activeBackend: AgentBackend?
    private var orb: OrbPanel!
    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var tapRetryTimer: Timer?
    private var chordHeld: Set<Int64> = []
    private var swallowedKeys: Set<Int64> = []
    private var chordTriggered = false
    private let chords: [(backend: AgentBackend, keys: Set<Int64>)] = [
        (.claude, [0, 34]),  // kVK_ANSI_A, kVK_ANSI_I
        (.local, [37, 46]),  // kVK_ANSI_L, kVK_ANSI_M
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        engine = AgentEngine(config: config)
        orb = OrbPanel(orbDir: config.orbDir, followsMouse: config.orbFollowsMouse)

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted {
            fputs(
                """
                optionai: grant Accessibility access so context can be read and text pasted.
                  System Settings → Privacy & Security → Accessibility → enable optionai

                """,
                stderr
            )
        }

        fputs(
            """
            optionai ready
              claude: \(config.claudeBinary)
              model:  \(config.model ?? "(cli default)")
              local:  \(LocalAgentEngine.model) at 127.0.0.1:11434 (no cloud fallback)
              orb:    \(config.orbDir?.path ?? "(none — menu-bar indicator only)")

            """,
            stderr
        )

        setupStatusItem()

        // The chord needs a CGEvent tap, which macOS grants only after the
        // Accessibility approval. If the tap fails now (fresh install, dialog
        // still open), keep retrying — the hotkey activates the moment the
        // user flips the toggle. There is no fallback hotkey: the app is
        // named after its chord.
        if registerChordTap() {
            hotkeyActive()
        } else {
            updateStatus("waiting")
            fputs(
                "optionai: waiting for Accessibility — Option+A+I and Option+L+M activate automatically once granted\n",
                stderr
            )
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.registerChordTap() {
                    self.tapRetryTimer?.invalidate()
                    self.tapRetryTimer = nil
                    self.hotkeyActive()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tapRetryTimer = timer
        }
    }

    private func hotkeyActive() {
        updateStatus("idle")
        fputs(
            "optionai: hotkeys Option+A+I (Claude), Option+L+M (local Qwen) active; ⌥A/⌥I/⌥L/⌥M are reserved\n",
            stderr
        )
    }

    // MARK: trigger

    func trigger(backend: AgentBackend = .claude) {
        if engine.isBusy || localEngine.isBusy {
            // Either chord cancels the active request. It never changes the
            // backend or starts a second request as a side effect.
            engine.cancel()
            localEngine.cancel()
            activeBackend = nil
            orb.hide()
            updateStatus("idle")
            NSSound(named: .init("Pop"))?.play()
            fputs("optionai: canceled\n", stderr)
            return
        }

        let captured: Capture?
        do {
            captured = try ContextCapturer.capture(
                maxChars: config.maxContextChars, requireComplete: backend == .local
            )
        } catch {
            showFailure(error, backend: backend)
            return
        }
        guard let capture = captured else {
            NSSound.beep()
            fputs(
                """
                optionai: nothing to capture. No readable textbox and no \
                highlighted text. In web apps (Google Docs), highlight the \
                text you want the agent to see, then press the hotkey.

                """,
                stderr
            )
            return
        }

        let kind: String
        switch capture.context {
        case .selection: kind = "selection"
        case .document(let b, let a):
            kind = "document (\(b.count)+\(a.count) chars)"
        case .webSelection: kind = "highlight (via synthetic copy)"
        }
        fputs("optionai: \(backend.label) captured \(kind) from \(capture.appName)\n", stderr)

        NSSound(named: .init("Tink"))?.play()
        activeBackend = backend
        updateStatus("thinking")
        orb.show(near: capture.caretScreenPoint)

        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.orb.hide()
            self.activeBackend = nil
            self.updateStatus("idle")

            switch result {
            case .failure(let error):
                self.showFailure(error, backend: backend)

            case .success(let text):
                guard !text.isEmpty else {
                    NSSound.beep()
                    fputs("optionai: agent returned nothing\n", stderr)
                    return
                }
                // Synthetic Cmd+V is silently dropped by macOS when
                // Accessibility is not granted — and the clipboard restore
                // would then destroy the response. Refuse to paste; keep
                // the response on the clipboard and re-prompt for the grant.
                guard AXIsProcessTrusted() else {
                    PasteboardInjector.copyOnly(text)
                    NSSound(named: .init("Submarine"))?.play()
                    fputs(
                        """
                        optionai: Accessibility not granted — cannot paste. \
                        Response is on the clipboard (Cmd+V to paste).
                          System Settings → Privacy & Security → Accessibility → optionai

                        """,
                        stderr
                    )
                    AXIsProcessTrustedWithOptions(
                        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                            as CFDictionary
                    )
                    return
                }

                let frontPID = NSWorkspace.shared.frontmostApplication?
                    .processIdentifier
                if frontPID == capture.appPID {
                    PasteboardInjector.paste(text)
                    NSSound(named: .init("Glass"))?.play()
                    fputs("optionai: pasted \(text.count) chars\n", stderr)
                } else {
                    // Focus moved. Do not paste into the wrong app —
                    // leave the response on the clipboard instead.
                    PasteboardInjector.copyOnly(text)
                    NSSound(named: .init("Submarine"))?.play()
                    fputs(
                        "optionai: focus changed — response is on the clipboard (Cmd+V to paste)\n",
                        stderr
                    )
                }
            }
        }
        switch backend {
        case .claude:
            engine.run(capture: capture, onDone: completion)
        case .local:
            localEngine.run(context: capture.context, onDone: completion)
        }
    }

    private func showFailure(_ error: Error, backend: AgentBackend) {
        NSSound(named: .init("Basso"))?.play()
        fputs("optionai: \(backend.label) failed: \(error.localizedDescription)\n", stderr)
        if backend == .local {
            statusItem?.button?.title = "LM!"
            statusItem?.button?.toolTip = "Local model: \(error.localizedDescription)"
        }
    }

    // MARK: status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "AI"
            button.toolTip = "optionai — ⌥A+I: Claude · ⌥L+M: local Qwen"
        }
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Claude on Focused Textbox (⌥A+I)",
                action: #selector(triggerFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Local Qwen on Focused Textbox (⌥L+M)",
                action: #selector(triggerLocalFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Cancel",
                action: #selector(cancelFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func updateStatus(_ state: String) {
        switch state {
        case "thinking":
            statusItem?.button?.title = activeBackend == .local ? "LM ◍" : "◍"
            statusItem?.button?.toolTip =
                "optionai — \(activeBackend?.label ?? "agent") working (either chord to cancel)"
        case "waiting":
            statusItem?.button?.title = "◌"
            statusItem?.button?.toolTip =
                "optionai — grant Accessibility to enable Option+A+I / Option+L+M "
                + "(System Settings → Privacy & Security → Accessibility)"
        default:
            statusItem?.button?.title = "AI"
            statusItem?.button?.toolTip = "optionai — ⌥A+I: Claude · ⌥L+M: local Qwen"
        }
    }

    @objc private func triggerFromMenu() {
        trigger(backend: .claude)
    }

    @objc private func triggerLocalFromMenu() {
        trigger(backend: .local)
    }

    @objc private func cancelFromMenu() {
        engine.cancel()
        localEngine.cancel()
        activeBackend = nil
        orb.hide()
        updateStatus("idle")
    }

    @objc private func quit() {
        engine.cancel()
        localEngine.cancel()
        NSApp.terminate(nil)
    }

    // MARK: hotkeys — Option+A+I / Option+L+M chords (CGEvent tap)

    /// A two-letter chord is not expressible as a normal global hotkey, so a
    /// session event tap tracks held keys. Both chords' key events are
    /// swallowed so the chord never types characters into the focused app.
    private func registerChordTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let app = Unmanaged<AppDelegate>.fromOpaque(refcon)
                        .takeUnretainedValue()
                    return app.handleTapEvent(type: type, event: event)
                },
                userInfo: refcon
            )
        else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleTapEvent(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            chordHeld.removeAll()
            swallowedKeys.removeAll()
            chordTriggered = false
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let optionDown = event.flags.contains(.maskAlternate)
        let isChordKey = chords.contains { $0.keys.contains(keycode) }

        switch type {
        case .flagsChanged:
            if !optionDown {
                chordHeld.removeAll()
                chordTriggered = false
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // A swallowed key remains swallowed even if Option is released
            // before its autorepeats or key-up event arrive.
            if swallowedKeys.contains(keycode) { return nil }
            guard optionDown, isChordKey,
                !event.flags.contains(.maskCommand),
                !event.flags.contains(.maskControl)
            else { return Unmanaged.passUnretained(event) }

            // Swallow autorepeats without re-evaluating the chord, so
            // holding the keys cannot fire-then-cancel.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }

            swallowedKeys.insert(keycode)
            guard !chordTriggered else { return nil }
            chordHeld.insert(keycode)
            if let chord = chords.first(where: { $0.keys.isSubset(of: chordHeld) }) {
                chordTriggered = true
                let backend = chord.backend
                DispatchQueue.main.async { self.trigger(backend: backend) }
            }
            return nil

        case .keyUp:
            chordHeld.remove(keycode)
            if swallowedKeys.remove(keycode) != nil {
                // Holding Option is fine: release the letter keys, then
                // press either chord again to cancel the active request.
                if swallowedKeys.isEmpty { chordTriggered = false }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

}

// MARK: - main

if CommandLine.arguments.contains("--local-smoke-test") {
    // Diagnostic mode never touches Accessibility, the clipboard, or Claude.
    // Piped stdin is treated as a selected passage; an interactive terminal
    // uses a fixed public instruction. Only this explicit mode prints output.
    let input: String
    if isatty(STDIN_FILENO) != 0 {
        input = "Reply with exactly: Local model ready."
    } else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        input = String(data: data, encoding: .utf8) ?? ""
    }
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("optionai: provide UTF-8 text on stdin, or run from a terminal for the default test.\n", stderr)
        exit(1)
    }
    let engine = LocalAgentEngine()
    var finished = false
    var status: Int32 = 1
    engine.run(context: .selection(input)) { result in
        switch result {
        case .success(let text):
            print(text)
            status = 0
        case .failure(let error):
            fputs("optionai: local smoke test failed: \(error.localizedDescription)\n", stderr)
        }
        finished = true
    }
    while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    exit(status)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
