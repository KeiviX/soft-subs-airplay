import Foundation

/// Downloads segments ahead of the player and keeps them in memory.
///
/// An AirPlay TV keeps only a few seconds buffered, fetches each segment just before it needs it, and gives up
/// on a request after about 5 seconds. Fetching from the video host only when the TV asks put every CDN hiccup
/// straight into playback, so audio cut out and video stalled. With the next minute or so already on this Mac,
/// the TV's requests are answered at LAN speed and a slow or stuck download is retried before the TV notices.
actor SegmentCache {
    typealias Fetch = @Sendable (URL) async -> HTTPResponse

    /// How far ahead of the newest request to keep segments ready.
    private static let lookahead: Double = 90
    private static let maxLookaheadSegments = 24
    private static let workers = 2
    private static let byteLimit = 400 << 20

    private let fetch: Fetch
    private var ready: [URL: HTTPResponse] = [:]
    /// Least recently used first.
    private var usage: [URL] = []
    private var bytes = 0
    private var inFlight: [URL: Task<HTTPResponse, Never>] = [:]

    private var lists: [[(url: URL, duration: Double)]] = []
    private var position: [URL: (list: Int, index: Int)] = [:]
    /// Segments the workers should fetch next, in order.
    private var wanted: [URL] = []
    private var activeWorkers = 0

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// Records a media playlist's segments so requests for them can be prefetched and served from memory.
    func register(_ segments: [(url: URL, duration: Double)]) {
        guard let first = segments.first, position[first.url] == nil else { return }
        let list = lists.count
        lists.append(segments)
        for (index, segment) in segments.enumerated() where position[segment.url] == nil {
            position[segment.url] = (list, index)
        }
    }

    func isSegment(_ url: URL) -> Bool { position[url] != nil }

    /// The segment's response, from memory if it's ready, otherwise as soon as its download finishes.
    func response(for url: URL) async -> HTTPResponse {
        planAhead(of: url)
        if let response = ready[url] {
            touch(url)
            DebugLog.log("served from cache \(url.lastPathComponent)")
            return response
        }
        return await download(url).value
    }

    private func download(_ url: URL) -> Task<HTTPResponse, Never> {
        if let task = inFlight[url] { return task }
        let fetch = self.fetch
        let task = Task { await fetch(url) }
        inFlight[url] = task
        Task {
            let response = await task.value
            self.finished(url, response)
        }
        return task
    }

    private func finished(_ url: URL, _ response: HTTPResponse) {
        inFlight[url] = nil
        guard (200..<300).contains(response.status), ready[url] == nil else { return }
        ready[url] = response
        usage.append(url)
        bytes += response.body.count
        evict()
    }

    /// Queues the segments after `url` (up to `lookahead` seconds) and starts workers to fetch them.
    private func planAhead(of url: URL) {
        guard let (list, index) = position[url] else { return }
        let segments = lists[list]
        var upcoming: [URL] = []
        var seconds = 0.0
        var next = index + 1
        while next < segments.count, seconds < Self.lookahead, upcoming.count < Self.maxLookaheadSegments {
            upcoming.append(segments[next].url)
            seconds += segments[next].duration
            next += 1
        }
        wanted = upcoming
        // Keep what's around the playhead; anything else can go first when memory runs short.
        for url in upcoming.reversed() where ready[url] != nil { touch(url) }
        while activeWorkers < Self.workers, wanted.contains(where: needsDownload) {
            activeWorkers += 1
            Task { await self.work() }
        }
    }

    private func needsDownload(_ url: URL) -> Bool { ready[url] == nil && inFlight[url] == nil }

    private func work() async {
        while let url = wanted.first(where: needsDownload) {
            let response = await download(url).value
            if !(200..<300).contains(response.status) {
                // The host is refusing or failing; don't hammer it. The player's own request will try again.
                wanted.removeAll { $0 == url }
            }
        }
        activeWorkers -= 1
    }

    private func touch(_ url: URL) {
        if let index = usage.firstIndex(of: url) { usage.remove(at: index) }
        usage.append(url)
    }

    private func evict() {
        while bytes > Self.byteLimit, let oldest = usage.first {
            usage.removeFirst()
            bytes -= ready.removeValue(forKey: oldest)?.body.count ?? 0
        }
    }
}
