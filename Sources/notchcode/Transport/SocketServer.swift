// SocketServer.swift
// Unix domain socket listener for the hook script (hooks/notchcode-hook.sh).
//
// Protocol (see Contract.swift):
//   client -> app   one line of JSON, a HookEnvelope
//   app -> client   one line of JSON, a HookReply, then the app closes
//
// Passive kinds get `decision: none` at once, so the hook exits immediately.
// Blocking kinds (permission, pre_tool) stay open until the sink calls its
// reply handler or `replyDeadline` passes, whichever comes first.
//
// When the owner picks "always" and Claude Code offered `permission_suggestions`
// in the PermissionRequest payload, the reply line carries one extra key,
// `updated_permissions`, holding those suggestions verbatim. It is always the
// last key, so the sh hook can cut it out without a JSON parser and hand it
// back to Claude Code as `decision.updatedPermissions`.
//
// While a blocking request waits, a watcher on the client socket notices the
// hook going away first (the owner answered in the terminal, or Claude Code
// killed the script at its timeout): the connection is marked dead, the
// deadline is cancelled, and the sink gets `cancel(requestId:)`. A reply that
// arrives after that is dropped silently.
// macOS nc half-closes as soon as its stdin ends, so a read EOF arrives right
// after the envelope and means nothing. Only a full close counts; see
// ClientConnection.watchForHangup.

import Foundation
import Darwin
import os

enum SocketServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case alreadyRunning(String)
    case socketCall(String, Int32)

    var description: String {
        switch self {
        case .pathTooLong(let p): return "socket path too long: \(p)"
        case .alreadyRunning(let p): return "another notchcode is already listening on \(p)"
        case .socketCall(let call, let err): return "\(call) failed: \(String(cString: strerror(err)))"
        }
    }
}

final class SocketServer {
    static let readTimeout: Int = 2             // seconds to receive the envelope line
    /// The only deadline enforced for a request; the card's countdown draws the same value, so
    /// the owner can never press Allow after the hook was told "none" (hook waits 59 s, Claude Code 65 s).
    static let replyDeadline: TimeInterval = Theme.Timing.permissionDeadline
    static let maxLineBytes = 8 * 1024 * 1024

    private static let log = Logger(subsystem: "com.notchcode.app", category: "socket")

    private let sink: HookEventSink
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "notchcode.socket.accept")
    private let clientQueue = DispatchQueue(label: "notchcode.socket.client", attributes: .concurrent)
    private let stateLock = NSLock()
    private var acceptSource: DispatchSourceRead?

    convenience init(sink: HookEventSink) {
        self.init(sink: sink, socketURL: NotchcodePaths.socketURL)
    }

    /// `socketURL` exists for tests and harnesses; the app uses `init(sink:)`.
    init(sink: HookEventSink, socketURL: URL) {
        self.sink = sink
        self.socketPath = socketURL.path
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if acceptSource != nil { return }

        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var addr = sockaddr_un()
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw SocketServerError.pathTooLong(socketPath) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)   // the rest stays zero, so the path is NUL-terminated
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // A live socket means a second copy of the app. A dead one is stale: remove it.
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.canConnect(&addr, addrLen) { throw SocketServerError.alreadyRunning(socketPath) }
            unlink(socketPath)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.socketCall("socket", errno) }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        guard bound == 0 else {
            let err = errno
            Darwin.close(fd)
            throw SocketServerError.socketCall("bind", err)
        }
        chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw SocketServerError.socketCall("listen", err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(listenFD: fd)
        }
        source.setCancelHandler {
            _ = Darwin.close(fd)
        }
        acceptSource = source
        source.resume()
        Self.log.info("listening on \(self.socketPath, privacy: .public)")
    }

    func stop() {
        stateLock.lock()
        let source = acceptSource
        acceptSource = nil
        stateLock.unlock()
        guard let source else { return }
        source.cancel()
        unlink(socketPath)
        Self.log.info("stopped")
    }

    // MARK: Accept

    private func acceptPending(listenFD: Int32) {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN: drained
            }
            Self.configureClient(client)
            clientQueue.async { [weak self] in
                guard let self else { Darwin.close(client); return }
                self.handle(client: client)
            }
        }
    }

    private static func configureClient(_ fd: Int32) {
        // Accepted sockets inherit O_NONBLOCK on Darwin: turn it off, rely on timeouts.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: readTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: One client

    private func handle(client fd: Int32) {
        let conn = ClientConnection(fd: fd)

        guard let line = Self.readLine(fd: fd), !line.isEmpty else {
            Self.log.error("no envelope line before timeout")
            conn.finish(Self.replyLine(nil, id: "?", payload: .null))
            return
        }

        let envelope: HookEnvelope
        do {
            envelope = try JSONDecoder().decode(HookEnvelope.self, from: line)
        } catch {
            Self.log.error("bad envelope: \(String(describing: error), privacy: .public)")
            conn.finish(Self.replyLine(nil, id: "?", payload: .null))
            return
        }

        let id = envelope.id
        if envelope.isBlocking {
            let payload = envelope.payload
            let replyHandler: ReplyHandler = { r in
                conn.finish(SocketServer.replyLine(r, id: id, payload: payload))
            }
            let sink = self.sink
            // Order matters: `receive` is queued on main before the watcher can
            // queue `cancel`, so the sink always sees receive first.
            conn.armDeadline(after: Self.replyDeadline,
                             line: Self.replyLine(nil, id: id, payload: .null),
                             queue: clientQueue) {
                SocketServer.log.info("reply deadline passed for \(id, privacy: .public)")
                // The hook got "none": the terminal prompt waits now. The app drops the request
                // the timed-out way, so a late press can never look answered.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        sink.timedOut(requestId: id)
                    }
                }
            }
            deliver(envelope, reply: replyHandler)
            conn.watchForHangup(queue: clientQueue) {
                SocketServer.log.info("hook went away before a reply for \(id, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        sink.cancel(requestId: id)
                    }
                }
            }
        } else {
            conn.finish(Self.replyLine(nil, id: id, payload: .null))
            deliver(envelope, reply: { _ in true })  // nothing waits
        }
    }

    /// Calls the sink on the main actor, in arrival order.
    private func deliver(_ envelope: HookEnvelope, reply: @escaping ReplyHandler) {
        let sink = self.sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                sink.receive(envelope, reply: reply)
            }
        }
    }

    // MARK: Helpers

    /// Reads up to the first newline (or EOF). Nil on timeout with nothing read, or on error.
    private static func readLine(fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < maxLineBytes {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                let chunk = buffer[0..<n]
                if let nl = chunk.firstIndex(of: 0x0A) {
                    data.append(contentsOf: buffer[0..<nl])
                    return data
                }
                data.append(contentsOf: chunk)
            } else if n == 0 {
                return data.isEmpty ? nil : data   // EOF without newline: take what we have
            } else {
                if errno == EINTR { continue }
                return nil                         // EAGAIN (timeout) or a real error
            }
        }
        return nil
    }

    /// One reply line: the HookReply with sorted keys, plus `updated_permissions`
    /// appended last when the owner chose "always" and the payload offered suggestions.
    static func replyLine(_ reply: HookReply?, id: String, payload: JSONValue) -> Data {
        var r = reply ?? HookReply(id: id, decision: .none)
        r.id = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(r) else {
            return Data("{\"always\":false,\"decision\":\"none\",\"id\":\"?\"}\n".utf8)
        }
        if r.decision == .allow, r.always,
           let suggestions = payload["permission_suggestions"],
           let list = suggestions.arrayValue, !list.isEmpty,
           let extra = try? encoder.encode(suggestions),
           data.last == UInt8(ascii: "}") {
            data.removeLast()
            data.append(contentsOf: Array(",\"updated_permissions\":".utf8))
            data.append(extra)
            data.append(UInt8(ascii: "}"))
        }
        data.append(0x0A)
        return data
    }

    private static func canConnect(_ addr: inout sockaddr_un, _ len: socklen_t) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        return rc == 0
    }
}

/// One accepted connection. Owns the fd. `finish` writes a line and closes,
/// exactly once, from any thread. `watchForHangup` notices the client leaving
/// first; after that `finish` is a no-op.
///
/// The fd is closed in exactly one place: the hangup source's cancel handler
/// when a source was installed, otherwise directly in `close()`. That way the
/// fd number cannot be reused while the watcher still refers to it.
/// The C `struct kevent`. Swift overloads the name `kevent` for the struct and the function.
private typealias KEvent = Darwin.kevent
/// The kevent(2) function, bound by type so the call does not resolve to the struct initialiser.
private let keventSyscall: @convention(c) (Int32, UnsafePointer<KEvent>?, Int32, UnsafeMutablePointer<KEvent>?, Int32, UnsafePointer<timespec>?) -> Int32 = kevent

private final class ClientConnection {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var hangupSource: DispatchSourceRead?
    private var deadlineTimer: DispatchSourceTimer?

    init(fd: Int32) { self.fd = fd }

    /// Replies `none` after `seconds` unless something else finished first.
    func armDeadline(after seconds: TimeInterval, line: Data, queue: DispatchQueue, onFire: @escaping () -> Void) {
        lock.lock()
        if finished { lock.unlock(); return }   // never create a source we would not resume
        let timer = DispatchSource.makeTimerSource(queue: queue)
        deadlineTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now() + seconds)
        // Strong capture on purpose: the timer keeps the connection alive until the
        // deadline even if the sink drops the reply handler. Cancelling the timer in
        // finish/markDead releases the handler and breaks the cycle.
        timer.setEventHandler { [self] in
            if self.finish(line) { onFire() }
        }
        timer.resume()
    }

    /// Watches for the client going away. `onHangup` runs once, only if the
    /// connection had not finished yet.
    ///
    /// Read EOF is useless here: macOS nc half-closes (sends FIN) as soon as its
    /// stdin ends, while it still waits for our reply. A full close is different:
    /// the kqueue *write* filter reports EV_EOF only once the peer socket is gone.
    /// DispatchSource hides kevent flags, so this uses a private kqueue with the
    /// write filter edge-triggered (EV_CLEAR: one wakeup when armed, one when the
    /// peer disappears, no busy loop) and a dispatch read source on the kqueue fd.
    func watchForHangup(queue: DispatchQueue, onHangup: @escaping () -> Void) {
        let fd = self.fd
        let kq = Darwin.kqueue()
        if kq < 0 { return }   // no watcher: the deadline still ends the request
        var change = KEvent()
        change.ident = UInt(fd)
        change.filter = Int16(EVFILT_WRITE)
        change.flags = UInt16(EV_ADD | EV_CLEAR)
        if keventSyscall(kq, &change, 1, nil, 0, nil) < 0 { Darwin.close(kq); return }

        lock.lock()
        // Create the source under the lock: if we already finished, never make
        // one (releasing a never-resumed source crashes libdispatch).
        if finished { lock.unlock(); Darwin.close(kq); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        hangupSource = source
        lock.unlock()

        source.setEventHandler { [self] in   // cycle broken by source.cancel() in close()
            var events = [KEvent](repeating: KEvent(), count: 4)
            var zero = timespec(tv_sec: 0, tv_nsec: 0)
            let n = keventSyscall(kq, nil, 0, &events, Int32(events.count), &zero)
            guard n > 0 else { return }
            let gone = events[0..<Int(n)].contains {
                $0.flags & UInt16(EV_EOF) != 0 || $0.flags & UInt16(EV_ERROR) != 0
            }
            if gone, self.markDead() { onHangup() }
        }
        source.setCancelHandler {
            _ = Darwin.close(kq)
            _ = Darwin.close(fd)
        }
        source.resume()
    }

    /// Returns true if this call did the write, false if the connection was already finished or dead.
    @discardableResult
    func finish(_ line: Data) -> Bool {
        lock.lock()
        if finished { lock.unlock(); return false }
        finished = true
        let timer = deadlineTimer
        deadlineTimer = nil
        lock.unlock()
        timer?.cancel()

        // The fd stays open here: only close() (or the source cancel handler) closes it.
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                break   // peer gone (EPIPE suppressed by SO_NOSIGPIPE) or send timeout
            }
        }
        close()
        return true
    }

    /// Marks the connection dead without writing. True if this call did it.
    private func markDead() -> Bool {
        lock.lock()
        if finished { lock.unlock(); return false }
        finished = true
        let timer = deadlineTimer
        deadlineTimer = nil
        lock.unlock()
        timer?.cancel()
        close()
        return true
    }

    /// Closes the fd exactly once. Called only after `finished` was set.
    private func close() {
        lock.lock()
        let source = hangupSource
        hangupSource = nil
        lock.unlock()
        if let source {
            source.cancel()     // cancel handler closes the fd
        } else {
            Darwin.close(fd)
        }
    }
}
