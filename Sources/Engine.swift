import SwiftUI
import AVFoundation
import Speech
import UserNotifications
import Observation

// MARK: - Focus timer

@Observable @MainActor final class Focus {
    static let shared = Focus()
    enum Phase { case idle, work, rest }
    var phase = Phase.idle
    var paused = false
    var title = ""
    var goalID: UUID?
    var taskID: UUID?
    var mode = TimerMode.pomodoro
    var worked = 0.0           // focused seconds this session
    var pausedFor = 0.0
    var phaseLeft = 0.0        // pomodoro work/rest or countdown remaining
    var cycle = 1
    var distractions = 0
    var start = Date()
    var exitAt: Date?          // strict blocking: the delayed way out
    var finished: Session?
    var activity: [String: AppTime] = [:]
    var notice: String?        // "x is on your blocklist"
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var last = Date()
    @ObservationIgnored private var attempted = false

    var active: Bool { phase != .idle }
    var prefs: Prefs { Store.shared.data.prefs }
    var display: String {
        let s = mode == .stopwatch ? worked : phaseLeft, t = Int(max(0, s.rounded(mode == .stopwatch ? .down : .up)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
    var quality: Int { Session.quality(seconds: worked, paused: pausedFor, distractions: distractions) }
    /// 0...1 progress through the current countdown.
    var progress: Double {
        guard mode != .stopwatch else { return 0 }
        let total = phase == .rest ? restLength : workLength
        return total > 0 ? 1 - phaseLeft / total : 0
    }
    private var workLength: Double { Double(mode == .pomodoro ? prefs.workMinutes : prefs.countdownMinutes) * 60 }
    private var restLength: Double { Double(cycle >= prefs.cycles ? prefs.longBreakMinutes : prefs.breakMinutes) * 60 }

    func begin(title: String = "", goal: UUID? = nil, task: UUID? = nil, mode: TimerMode? = nil) {
        guard !active else { return }
        if !title.isEmpty { self.title = title }
        if goal != nil { goalID = goal }
        if task != nil { taskID = task }
        self.mode = mode ?? prefs.timerMode
        worked = 0; pausedFor = 0; cycle = 1; distractions = 0; paused = false; exitAt = nil; finished = nil; activity = [:]
        start = Date(); last = Date(); phase = .work; phaseLeft = workLength
        Store.shared.data.prefs.timerMode = self.mode
        if !Store.isTesting {
            Blocker.shared.engage()
            FloatingTimer.show()
            if prefs.playOnFocus { Music.shared.play() }
            loop = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); self?.heartbeat() }
            }
        }
    }
    private func heartbeat() {
        let now = Date(), dt = now.timeIntervalSince(last); last = now
        tick(dt > 5 ? 0 : dt) // a sleeping Mac is not focus time
        if phase == .work && !paused && dt <= 5 { Tracker.sample(dt, into: &activity) }
        if let e = exitAt, now >= e { finish() }
    }
    func tick(_ dt: Double) {
        guard active else { return }
        if paused { if phase == .work { pausedFor += dt }; return }
        if phase == .work { worked += dt }
        guard mode != .stopwatch else { return }
        phaseLeft -= dt
        guard phaseLeft <= 0 else { return }
        chime()
        if mode == .countdown { finish(); return }
        if phase == .work { phase = .rest; phaseLeft = restLength; notify("Time for a break", "\(Int(restLength / 60)) minutes. Step away from the screen.") }
        else if cycle >= prefs.cycles { finish() }
        else { cycle += 1; phase = .work; phaseLeft = workLength; notify("Back to it", "Round \(cycle) of \(prefs.cycles).") }
    }
    func togglePause() {
        paused.toggle()
        if !Store.isTesting && prefs.playOnFocus { paused ? Music.shared.pause() : Music.shared.play() }
    }
    func skipBreak() { guard phase == .rest else { return }; phaseLeft = 0; tick(0) }
    /// Ends now, or starts the wait when strict blocking is on.
    func requestStop() {
        if Blocker.shared.engaged && prefs.exitDelay > 0 && !Store.isTesting { exitAt = Date().addingTimeInterval(Double(prefs.exitDelay)) }
        else { finish() }
    }
    func cancelExit() { exitAt = nil }
    func noteDistraction() { if active && phase == .work { distractions += 1 } }
    func finish() {
        guard active else { return }
        loop?.cancel(); loop = nil
        phase = .idle; paused = false; exitAt = nil
        if !Store.isTesting { Blocker.shared.release(); FloatingTimer.hide(); if prefs.playOnFocus { Music.shared.pause() } }
        if worked >= 60 {
            let s = Session(title: title.isEmpty ? "Focus" : title, goalID: goalID, taskID: taskID, start: start, seconds: worked, pausedSeconds: pausedFor, distractions: distractions, activity: activity.isEmpty ? nil : Array(activity.values))
            Store.shared.data.sessions.append(s); finished = s
        }
        title = ""; goalID = nil; taskID = nil
    }
    private func chime() { if !Store.isTesting { NSSound(named: "Glass")?.play() } }
    private func notify(_ t: String, _ b: String) {
        guard !Store.isTesting else { return }
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Blocker

@Observable @MainActor final class Blocker {
    static let shared = Blocker()
    nonisolated static let helper = "/usr/local/libexec/bearing-hosts"
    var engaged = false
    var message = ""
    var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.helper) }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Root helper. It can only rewrite Bearing's own marked section of /etc/hosts.
    static let script = #"""
    #!/bin/sh
    set -eu
    HOSTS=/etc/hosts
    BEGIN="# BEGIN BEARING"
    END="# END BEARING"
    cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in block|clear) ;; *) echo "usage: block domain... | clear" >&2; exit 2;; esac
    for d in "$@"; do
      case "$d" in ''|*[!a-z0-9.-]*|.*|*.|-*|*..*) echo "bad domain" >&2; exit 2;; esac
      case "$d" in *.*) ;; *) echo "bad domain" >&2; exit 2;; esac
    done
    TMP=$(mktemp "$HOSTS.bearing.XXXXXX")
    trap 'rm -f "$TMP"' EXIT
    sed "/^$BEGIN\$/,/^$END\$/d" "$HOSTS" > "$TMP"
    if [ "$cmd" = block ]; then
      echo "$BEGIN" >> "$TMP"
      for d in "$@"; do
        for h in "$d" "www.$d"; do printf '0.0.0.0 %s\n::1 %s\n' "$h" "$h" >> "$TMP"; done
      done
      echo "$END" >> "$TMP"
    fi
    cat "$TMP" > "$HOSTS"
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    """#

    func installHelper() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tool = dir.appendingPathComponent("helper"), rule = dir.appendingPathComponent("rule"), run = dir.appendingPathComponent("run")
        try? Self.script.write(to: tool, atomically: true, encoding: .utf8)
        try? "\(NSUserName()) ALL=(root) NOPASSWD: \(Self.helper)\n".write(to: rule, atomically: true, encoding: .utf8)
        let sh = """
        set -e
        mkdir -p /usr/local/libexec
        install -o root -g wheel -m 755 '\(tool.path)' '\(Self.helper)'
        visudo -cf '\(rule.path)'
        install -o root -g wheel -m 440 '\(rule.path)' /etc/sudoers.d/bearing
        """
        try? sh.write(to: run, atomically: true, encoding: .utf8)
        admin("/bin/sh '\(run.path)'", done: "Website blocking is ready.")
        try? FileManager.default.removeItem(at: dir)
    }
    func uninstallHelper() {
        admin("'\(Self.helper)' clear; rm -f '\(Self.helper)' /etc/sudoers.d/bearing", done: "Website blocking removed.")
    }
    private func admin(_ cmd: String, done: String) {
        var e: NSDictionary?
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&e)
        message = e == nil ? done : (e?[NSAppleScript.errorMessage] as? String ?? "Couldn't change blocking.")
    }
    private func hosts(_ args: [String]) {
        guard helperInstalled else { return }
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-n", Blocker.helper] + args
            try? p.run(); p.waitUntilExit()
        }
    }
    func engage() {
        let prefs = Store.shared.data.prefs
        guard prefs.blockDuringFocus else { return }
        engaged = true
        hosts(["block"] + prefs.blockSites)
        let c = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { if let app { Blocker.shared.police(app) } }
            })
        }
        for a in NSWorkspace.shared.runningApplications { police(a, counted: false) }
    }
    private func police(_ app: NSRunningApplication, counted: Bool = true) {
        guard engaged, Focus.shared.phase == .work, let id = app.bundleIdentifier, Store.shared.data.prefs.blockApps.contains(id) else { return }
        app.terminate() // asks politely, so the app can save
        if counted {
            Focus.shared.noteDistraction()
            let name = app.localizedName ?? id
            Focus.shared.notice = name
            Task { try? await Task.sleep(for: .seconds(4)); if Focus.shared.notice == name { Focus.shared.notice = nil } }
        }
    }
    func release() {
        guard engaged else { return }
        engaged = false
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        hosts(["clear"])
    }
    /// A crash mid-session must not leave sites blocked.
    func clearStale() { hosts(["clear"]) }
}

// MARK: - Live soundscapes (nothing to download, nothing to pay for)

/// Real-time noise generator. Runs on the audio thread: no locks, allocations or Swift arrays in render.
final class NoiseSynth: @unchecked Sendable {
    static let names = ["Brown noise", "Pink noise", "White noise", "Rain", "Ocean", "Wind"]
    private struct Ch {
        var seed: UInt32
        var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0, p4: Float = 0, p5: Float = 0, p6: Float = 0
        var brown: Float = 0, rainLP: Float = 0, drop: Float = 0, wind: Float = 0
        mutating func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Float(seed) / 2147483648 - 1 }
    }
    let target = UnsafeMutablePointer<Float>.allocate(capacity: 6)
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 6)
    private let ch = UnsafeMutablePointer<Ch>.allocate(capacity: 2)
    private var t = 0.0
    private let rate: Double
    init(rate: Double) {
        self.rate = rate
        target.initialize(repeating: 0, count: 6); gain.initialize(repeating: 0, count: 6)
        ch[0] = Ch(seed: 0x9E3779B9); ch[1] = Ch(seed: 0x7F4A7C15)
    }
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let step = 1 / rate, tau = 2 * Double.pi
        for i in 0..<n {
            t += step
            for k in 0..<6 { gain[k] += (target[k] - gain[k]) * 0.0005 } // no clicks when sliders move
            let swell = Float(pow(0.5 + 0.5 * sin(tau * t / 9 + 1.5 * sin(tau * t / 23)), 2))
            let gust = Float(0.55 + 0.3 * sin(tau * t / 7) + 0.15 * sin(tau * t / 3.1))
            let shower = Float(0.85 + 0.15 * sin(tau * t / 13))
            for c in 0..<2 {
                let w = ch[c].rnd()
                ch[c].p0 = 0.99886 * ch[c].p0 + w * 0.0555179; ch[c].p1 = 0.99332 * ch[c].p1 + w * 0.0750759
                ch[c].p2 = 0.96900 * ch[c].p2 + w * 0.1538520; ch[c].p3 = 0.86650 * ch[c].p3 + w * 0.3104856
                ch[c].p4 = 0.55000 * ch[c].p4 + w * 0.5329522; ch[c].p5 = -0.7616 * ch[c].p5 - w * 0.0168980
                let pink = (ch[c].p0 + ch[c].p1 + ch[c].p2 + ch[c].p3 + ch[c].p4 + ch[c].p5 + ch[c].p6 + w * 0.5362) * 0.11
                ch[c].p6 = w * 0.115926
                ch[c].brown = (ch[c].brown + 0.02 * w) / 1.02
                let brown = ch[c].brown * 3.5
                ch[c].rainLP += (pink - ch[c].rainLP) * 0.14
                if ch[c].rnd() > 0.9994 { ch[c].drop = abs(ch[c].rnd()) }
                ch[c].drop *= 0.994
                let rain = (pink - ch[c].rainLP) * 1.4 * shower + w * ch[c].drop * 0.22
                let ocean = brown * (0.3 + 0.7 * swell) * 1.2 + pink * swell * 0.14
                ch[c].wind += (pink - ch[c].wind) * (0.006 + 0.03 * gust * gust)
                let wind = ch[c].wind * 3.2 * gust
                var s = brown * gain[0] + pink * gain[1] + w * 0.25 * gain[2]
                s += rain * gain[3] + ocean * gain[4] + wind * gain[5]
                let o = max(-1, min(1, s))
                if c == 0 { l[i] = o } else { r[i] = o }
            }
        }
    }
}

// MARK: - Music

struct Track: Codable, Identifiable, Hashable {
    var file: String, title: String, artist: String, category: String, license: String, source: String
    var id: String { file }
}

@Observable @MainActor final class Music {
    static let shared = Music()
    var playing = false
    var nowPlaying = ""
    var status = ""
    let tracks: [Track]
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var names: [URL: String] = [:]
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var synth: NoiseSynth?
    var prefs: Prefs { Store.shared.data.prefs }
    var categories: [String] { var seen = Set<String>(); return tracks.map(\.category).filter { seen.insert($0).inserted } }

    init() {
        let u = Bundle.main.url(forResource: "tracks", withExtension: "json", subdirectory: "Music")
        tracks = u.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Track].self, from: $0) } ?? []
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Music.shared.next() }
        }
    }
    private func script(_ s: String) -> String? {
        var e: NSDictionary?
        let r = NSAppleScript(source: s)?.executeAndReturnError(&e)
        if let e { status = e[NSAppleScript.errorMessage] as? String ?? "Couldn't reach that app."; return nil }
        status = ""; return r?.stringValue ?? ""
    }
    private var externalApp: (name: String, id: String)? {
        switch prefs.musicSource { case .spotify: ("Spotify", "com.spotify.client"); case .appleMusic: ("Music", "com.apple.Music"); default: nil }
    }
    private func external(_ cmd: String) -> Bool {
        guard let a = externalApp else { return false }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.id) != nil else { status = "\(a.name) isn't installed."; return true }
        _ = script("tell application \"\(a.name)\" to \(cmd)")
        return true
    }
    private func buildQueue() {
        names = [:]
        switch prefs.musicSource {
        case .library:
            queue = tracks.filter { $0.category == prefs.musicCategory }.shuffled().compactMap { t in
                let u = Bundle.main.url(forResource: (t.file as NSString).deletingPathExtension, withExtension: "m4a", subdirectory: "Music")
                if let u { names[u] = "\(t.title) · \(t.artist)" }
                return u
            }
        case .folder:
            guard let p = prefs.musicFolder, let e = FileManager.default.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: nil) else { queue = []; return }
            queue = e.compactMap { $0 as? URL }.filter { ["mp3", "m4a", "aac", "wav", "aiff", "flac"].contains($0.pathExtension.lowercased()) }.shuffled()
            for u in queue { names[u] = u.deletingPathExtension().lastPathComponent }
        default: queue = []
        }
    }
    func play() {
        playing = true
        startAmbience()
        if let a = externalApp {
            let uri = prefs.externalURI.replacingOccurrences(of: "\"", with: "")
            let cmd = uri.isEmpty ? "play" : (a.name == "Spotify" ? "play track \"\(uri)\"" : "play playlist \"\(uri)\"")
            _ = external(cmd); refreshExternal()
        } else if prefs.musicSource != .none {
            player.volume = Float(prefs.musicVolume)
            if player.currentItem != nil { player.play() } else { next() }
        }
    }
    func pause() {
        playing = false
        player.pause(); engine?.pause()
        _ = external("pause")
    }
    func toggle() { playing ? pause() : play() }
    func next() {
        if external("next track") { refreshExternal(); return }
        if queue.isEmpty { buildQueue() }
        guard !queue.isEmpty else { nowPlaying = ""; if prefs.musicSource == .folder { status = "Choose a folder with music in it." }; return }
        let u = queue.removeFirst()
        nowPlaying = names[u] ?? ""
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        if playing { player.play() }
    }
    private func refreshExternal() {
        Task { try? await Task.sleep(for: .seconds(1))
            if let a = externalApp, NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.id) != nil { nowPlaying = script("tell application \"\(a.name)\" to get name of current track") ?? "" }
        }
    }
    /// Source or playlist changed.
    func reload() {
        let was = playing
        player.pause(); player.replaceCurrentItem(with: nil); queue = []; nowPlaying = ""; status = ""
        if was { play() }
    }
    func setVolume(_ v: Double) { Store.shared.data.prefs.musicVolume = v; player.volume = Float(v) }
    func level(_ n: String) -> Double { prefs.soundLevels[n] ?? 0 }
    func setLevel(_ n: String, _ v: Double) {
        Store.shared.data.prefs.soundLevels[n] = v
        if v > 0 && !playing { playing = true }
        startAmbience()
    }
    private func startAmbience() {
        if prefs.soundLevels.values.contains(where: { $0 > 0 }) && engine == nil {
            let e = AVAudioEngine(), rate = e.outputNode.outputFormat(forBus: 0).sampleRate
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44100, channels: 2)!
            let s = NoiseSynth(rate: fmt.sampleRate)
            let node = Self.sourceNode(fmt, s)
            e.attach(node); e.connect(node, to: e.mainMixerNode, format: fmt)
            engine = e; synth = s
        }
        guard let s = synth else { return }
        for (i, n) in NoiseSynth.names.enumerated() { s.target[i] = Float(level(n)) }
        if playing { try? engine?.start() }
    }
    private nonisolated static func sourceNode(_ fmt: AVAudioFormat, _ s: NoiseSynth) -> AVAudioSourceNode {
        AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            s.render(b[0].mData!.assumingMemoryBound(to: Float.self), b[1].mData!.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }
    }
}

// MARK: - Voice (long recordings, transcribed on this Mac)

@Observable @MainActor final class Voice {
    static let shared = Voice()
    static let maxSeconds = 90.0 * 60
    var recording = false
    var elapsed = 0.0
    var level = 0.0
    @ObservationIgnored private var rec: AVAudioRecorder?
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() async -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return "Allow the microphone for Bearing in System Settings → Privacy & Security." }
        let dir = Store.dir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        guard let r = try? AVAudioRecorder(url: u, settings: settings), r.record(forDuration: Self.maxSeconds) else { return "Couldn't start recording." }
        r.isMeteringEnabled = true
        rec = r; recording = true; elapsed = 0
        loop = Task { [weak self] in
            while !Task.isCancelled, let self, let r = self.rec {
                try? await Task.sleep(for: .milliseconds(200))
                r.updateMeters()
                self.level = Double(max(0, (r.averagePower(forChannel: 0) + 50) / 50))
                self.elapsed = r.currentTime
                if !r.isRecording { break }
            }
        }
        return nil
    }
    func stop() -> URL? {
        loop?.cancel(); recording = false; level = 0
        let u = rec?.url; rec?.stop(); rec = nil
        return u
    }
    /// On-device, free, and private. The model downloads once through macOS.
    nonisolated static func transcribe(_ url: URL) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw AIError(errorDescription: "macOS can't transcribe this language on this Mac yet.") }
        let t = SpeechTranscriber(locale: locale, preset: .transcription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        async let text: String = { var s = ""; for try await r in t.results where r.isFinal { s += String(r.text.characters) }; return s }()
        if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
        else { await analyzer.cancelAndFinishNow() }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
