// SpotifyLyrics.swift
// Combined from Sources/App and Sources/SpotifyLyricsCore.
// Generated from the supplied SpotifyLyrics project ZIP.

import Foundation
import FoundationModels
import SwiftUI
import CoreGraphics
import Speech
import AVFoundation
import NaturalLanguage
import Translation
import Vision
import AppKit
import CreateML
import Combine
import AppIntents

// MARK: - SpotifyLyricsCore/Models/AITranslationMode.swift

#if canImport(FoundationModels) && compiler(>=6.2)
#endif

/// Controls how on-device AI (Apple Intelligence) is used for translation.
public enum AITranslationMode: String, CaseIterable {
    /// AI translates all lyrics directly (best quality, uses more resources).
    case primary
    /// Apple Translation first, AI improves in background (balanced).
    case refine
    /// AI disabled, Apple Translation only (fastest, lowest resource usage).
    case off

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .refine:  return "Refine"
        case .off:     return "Off"
        }
    }

    /// Check if Apple Intelligence is available and enabled on this device.
    /// Requires macOS 26+ with Apple Intelligence enabled in System Settings.
    public static var isAIAvailable: Bool {
        #if canImport(FoundationModels) && compiler(>=6.2)
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }
}

// MARK: - SpotifyLyricsCore/Models/AnimationMode.swift

/// User-selectable animation style for the lyrics overlay.
public enum AnimationMode: String, CaseIterable {
    /// Japanese-karaoke style: the active line fills with color as it plays.
    case karaoke
    /// Polished default: gentle scale/opacity on the active line.
    case smooth
    /// Bouncy spring pop on the active line.
    case spring
    /// Calm pulsing glow on the active line.
    case glow

    public var displayName: String {
        switch self {
        case .karaoke: return "Karaoke"
        case .smooth:  return "Smooth"
        case .spring:  return "Spring"
        case .glow:    return "Glow"
        }
    }

    /// Animation used for active-state changes and auto-scroll transitions.
    /// Snappy response with moderate damping — fast enough to feel responsive, damped enough
    /// to settle cleanly. (Very long response + very high damping reads as "stiff/laggy".)
    public var transition: Animation {
        switch self {
        case .karaoke: return .spring(response: 0.40, dampingFraction: 0.82)
        case .smooth:  return .spring(response: 0.38, dampingFraction: 0.85)
        case .spring:  return .spring(response: 0.42, dampingFraction: 0.68)
        case .glow:    return .easeInOut(duration: 0.35)
        }
    }
}

// MARK: - SpotifyLyricsCore/Models/AppVersionDisplay.swift

public enum AppVersionDisplay {
    public static func marketingVersion(from infoDictionary: [String: Any]?) -> String {
        guard let rawVersion = infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "v0.0.0"
        }

        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return "v0.0.0" }
        return version.hasPrefix("v") ? version : "v\(version)"
    }

    public static func marketingVersion(from infoDictionary: [String: Any]?, fallbackInfoPlistURL: URL) -> String {
        let bundledVersion = marketingVersion(from: infoDictionary)
        if bundledVersion != "v0.0.0" {
            return bundledVersion
        }

        guard
            let data = try? Data(contentsOf: fallbackInfoPlistURL),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let fallbackInfoDictionary = propertyList as? [String: Any]
        else {
            return bundledVersion
        }

        return marketingVersion(from: fallbackInfoDictionary)
    }

    public static func currentMarketingVersion() -> String {
        let infoPlistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Info.plist")

        return marketingVersion(from: Bundle.main.infoDictionary, fallbackInfoPlistURL: infoPlistURL)
    }
}

// MARK: - SpotifyLyricsCore/Models/LineEnrichment.swift

public struct LineEnrichment: Equatable {
    public var romanization: String?
    public var translation: String?

    public init(romanization: String? = nil, translation: String? = nil) {
        self.romanization = romanization
        self.translation = translation
    }

    public var isEmpty: Bool {
        romanization == nil && translation == nil
    }
}

// MARK: - SpotifyLyricsCore/Models/LyricLine.swift

public struct LyricLine: Identifiable, Equatable, Codable {
    public let id: UUID
    public let timestamp: TimeInterval
    public let text: String
    /// Per-word timings for karaoke fill, when available (enhanced-LRC / richsync / local alignment).
    public var words: [LyricWord]?
    /// Absolute end time of this line, when known.
    public let endTime: TimeInterval?

    public init(timestamp: TimeInterval, text: String, words: [LyricWord]? = nil, endTime: TimeInterval? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.text = text
        self.words = words
        self.endTime = endTime
    }

    public static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.text == rhs.text && lhs.words == rhs.words
    }

    /// 0…1 karaoke fill fraction at the given absolute playback position.
    ///
    /// When per-word timings exist the fill follows word boundaries (completed
    /// words fully filled, the in-progress word filled proportionally), measured
    /// by character count so the visual sweep matches the text width. Otherwise it
    /// interpolates linearly from this line's `timestamp` to `lineEnd`.
    public func fillFraction(at position: TimeInterval, lineEnd: TimeInterval) -> Double {
        if let words, !words.isEmpty {
            return wordFillFraction(at: position, words: words, lineEnd: lineEnd)
        }
        let end = endTime ?? lineEnd
        guard end > timestamp else { return position >= timestamp ? 1 : 0 }
        let raw = (position - timestamp) / (end - timestamp)
        return min(max(raw, 0), 1)
    }

    private func wordFillFraction(at position: TimeInterval, words: [LyricWord], lineEnd: TimeInterval) -> Double {
        let totalChars = words.reduce(0) { $0 + max($1.text.count, 1) }
        guard totalChars > 0 else { return 0 }

        var filledChars = 0.0
        for word in words {
            let count = Double(max(word.text.count, 1))
            // The last word's end is often unknown (inline tags); fall back to lineEnd.
            let effectiveEnd = word.end > word.start ? word.end : lineEnd
            if position >= effectiveEnd {
                filledChars += count
            } else if position <= word.start {
                break
            } else if effectiveEnd > word.start {
                let wordProgress = (position - word.start) / (effectiveEnd - word.start)
                filledChars += count * wordProgress
                break
            } else {
                filledChars += count
                break
            }
        }
        return min(max(filledChars / Double(totalChars), 0), 1)
    }
}

// MARK: - SpotifyLyricsCore/Models/LyricWord.swift

/// A single word (or syllable) with absolute start/end times, used for
/// word-level karaoke fill. Sourced from enhanced-LRC inline tags.
public struct LyricWord: Equatable, Codable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

// MARK: - SpotifyLyricsCore/Models/OverlaySize.swift

public enum OverlaySize: String, CaseIterable {
    case mini, small, medium, large, squareAlbum

    public var dimensions: (width: CGFloat, height: CGFloat) {
        switch self {
        case .mini:   return (600, 48)
        case .small:  return (500, 200)
        case .medium: return (700, 260)
        case .large:  return (900, 360)
        case .squareAlbum: return (360, 360)
        }
    }

    public var displayName: String {
        switch self {
        case .mini:   return "Mini"
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .squareAlbum: return "Square Album"
        }
    }

    public var isMini: Bool { self == .mini }

    public var frameAutosaveName: String {
        switch self {
        case .mini: return "LyricsOverlayMini"
        case .squareAlbum: return "LyricsOverlaySquareAlbum"
        case .small, .medium, .large: return "LyricsOverlay"
        }
    }
}

// MARK: - SpotifyLyricsCore/Models/TrackInfo.swift

public struct TrackInfo: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval

    public var cacheKey: String {
        "\(artist.lowercased())|\(title.lowercased())"
    }

    public init(title: String, artist: String, album: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

// MARK: - SpotifyLyricsCore/Models/TranslationLanguage.swift

public enum TranslationLanguage: String, CaseIterable, Equatable {
    case indonesian = "id"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case thai = "th"
    case vietnamese = "vi"
    case arabic = "ar"
    case russian = "ru"
    case hindi = "hi"

    public var displayName: String {
        switch self {
        case .indonesian: return "Indonesia"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chinese: return "中文"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .thai: return "ไทย"
        case .vietnamese: return "Tiếng Việt"
        case .arabic: return "العربية"
        case .russian: return "Русский"
        case .hindi: return "हिन्दी"
        }
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/LRCLibProvider.swift

public final class LRCLibProvider {
    struct SearchResult: Codable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    public init() {}

    /// Fetch every usable lyrics candidate for a track, ranked best-first.
    ///
    /// LRCLIB's search endpoint can find records that an exact `track_name` +
    /// `artist_name` query misses. Try the exact query first, then progressively
    /// broader keyword searches and merge/deduplicate the results.
    ///
    /// Ranking: synced results before plain ones; within each group the result
    /// whose duration is closest to the playing track wins (when `trackDuration`
    /// is known), with stronger title/artist matches preferred before LRCLIB's
    /// original ordering.
    public func fetchOptions(
        title: String,
        artist: String,
        trackDuration: TimeInterval? = nil
    ) async -> [LyricsOption] {
        var allResults: [SearchResult] = []
        var seenIDs = Set<Int>()

        // 1. Keep the original precise query as the first attempt.
        if let results = await search(trackName: title, artistName: artist) {
            appendUnique(results, to: &allResults, seenIDs: &seenIDs)
            let options = allResults.compactMap(Self.makeOption)
            if !options.isEmpty {
                return Self.rank(options, title: title, artist: artist, trackDuration: trackDuration)
            }
        }

        // 2. LRCLIB's `q` search searches title, artist and album fields and can
        // find records that the two-field query misses.
        let combinedQuery = "\(title) \(artist)"
        if let results = await search(query: combinedQuery) {
            appendUnique(results, to: &allResults, seenIDs: &seenIDs)
            let options = allResults.compactMap(Self.makeOption)
            if !options.isEmpty {
                return Self.rank(options, title: title, artist: artist, trackDuration: trackDuration)
            }
        }

        // 3. Last fallback: search the title alone. This is intentionally done
        // only after the more specific searches to avoid unnecessary requests.
        if let results = await search(query: title) {
            appendUnique(results, to: &allResults, seenIDs: &seenIDs)
        }

        let options = allResults.compactMap(Self.makeOption)
        return Self.rank(options, title: title, artist: artist, trackDuration: trackDuration)
    }

    /// Convenience: the single best option's lines, or nil if none.
    public func fetchLyrics(title: String, artist: String) async -> [LyricLine]? {
        let options = await fetchOptions(title: title, artist: artist)
        return options.first?.lines
    }

    private func search(
        query: String? = nil,
        trackName: String? = nil,
        artistName: String? = nil
    ) async -> [SearchResult]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var queryItems: [URLQueryItem] = []

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let trackName, !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "track_name", value: trackName))
        }
        if let artistName, !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artistName))
        }

        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("SpotifyLyrics/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode([SearchResult].self, from: data)
        } catch {
            // Cancellation is expected when the track changes mid-fetch — not an error.
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                return nil
            }
            print("LRCLib search error: \(error)")
            return nil
        }
    }

    private func appendUnique(
        _ results: [SearchResult],
        to allResults: inout [SearchResult],
        seenIDs: inout Set<Int>
    ) {
        for result in results where seenIDs.insert(result.id).inserted {
            allResults.append(result)
        }
    }

    private static func makeOption(from r: SearchResult) -> LyricsOption? {
        // Prefer synced lyrics for this result.
        if let synced = r.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty {
                return LyricsOption(
                    id: r.id, trackName: r.trackName, artistName: r.artistName,
                    albumName: r.albumName, duration: r.duration,
                    isSynced: true, lines: lines
                )
            }
        }

        // Fall back to plain (unsynced) lyrics with evenly-spaced placeholder timing.
        if let plain = r.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .enumerated()
                .map { LyricLine(timestamp: Double($0.offset) * 4.0, text: $0.element) }
            if !lines.isEmpty {
                return LyricsOption(
                    id: r.id, trackName: r.trackName, artistName: r.artistName,
                    albumName: r.albumName, duration: r.duration,
                    isSynced: false, lines: lines
                )
            }
        }

        return nil
    }

    private static func rank(
        _ options: [LyricsOption],
        title: String,
        artist: String,
        trackDuration: TimeInterval?
    ) -> [LyricsOption] {
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)

        return options.enumerated().sorted { a, b in
            let lhs = a.element
            let rhs = b.element

            // Synced beats plain.
            if lhs.isSynced != rhs.isSynced { return lhs.isSynced }

            // Prefer exact normalized title + artist matches.
            let lhsExact = normalize(lhs.trackName) == normalizedTitle && normalize(lhs.artistName) == normalizedArtist
            let rhsExact = normalize(rhs.trackName) == normalizedTitle && normalize(rhs.artistName) == normalizedArtist
            if lhsExact != rhsExact { return lhsExact }

            // Then prefer title and artist matches independently.
            let lhsTitle = normalize(lhs.trackName) == normalizedTitle
            let rhsTitle = normalize(rhs.trackName) == normalizedTitle
            if lhsTitle != rhsTitle { return lhsTitle }

            let lhsArtist = normalize(lhs.artistName) == normalizedArtist
            let rhsArtist = normalize(rhs.artistName) == normalizedArtist
            if lhsArtist != rhsArtist { return lhsArtist }

            // Then closest duration to the playing track.
            if let target = trackDuration, target > 0 {
                let da = lhs.duration.map { abs($0 - target) } ?? .greatestFiniteMagnitude
                let db = rhs.duration.map { abs($0 - target) } ?? .greatestFiniteMagnitude
                if da != db { return da < db }
            }

            // Stable: preserve merged LRCLIB ordering.
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[\\p{Punct}]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/LRCParser.swift

public struct LRCParser {
    private static let lineTagPattern = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})\.(\d{2,3})\]"#)
    private static let wordTagPattern = try? NSRegularExpression(pattern: #"<(\d{2}):(\d{2})\.(\d{2,3})>"#)

    public static func parse(_ lrcString: String) -> [LyricLine] {
        guard let lineTagPattern, let wordTagPattern else { return [] }

        var lines: [LyricLine] = []

        for raw in lrcString.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let fullRange = NSRange(line.startIndex..., in: line)
            let tagMatches = lineTagPattern.matches(in: line, range: fullRange)
            guard !tagMatches.isEmpty else { continue }

            // Collect the run of contiguous leading `[mm:ss.xx]` timestamps.
            var timestamps: [TimeInterval] = []
            var contentStart = line.startIndex
            var expectedStart = line.startIndex
            for tag in tagMatches {
                guard let range = Range(tag.range, in: line), range.lowerBound == expectedStart else { break }
                timestamps.append(time(from: tag, in: line))
                expectedStart = range.upperBound
                contentStart = range.upperBound
            }
            guard !timestamps.isEmpty else { continue }

            let content = String(line[contentStart...])
            let (text, words) = parseWords(content, lineStart: timestamps[0], wordTagPattern: wordTagPattern)
            guard !text.isEmpty else { continue }

            for ts in timestamps {
                lines.append(LyricLine(timestamp: ts, text: text, words: words))
            }
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    /// Parses inline enhanced-LRC word tags (`<mm:ss.xx>word`). Returns the plain
    /// line text and, when word tags are present, the per-word timings.
    private static func parseWords(_ content: String, lineStart: TimeInterval, wordTagPattern: NSRegularExpression) -> (text: String, words: [LyricWord]?) {
        let fullRange = NSRange(content.startIndex..., in: content)
        let tagMatches = wordTagPattern.matches(in: content, range: fullRange)

        guard !tagMatches.isEmpty else {
            return (content.trimmingCharacters(in: .whitespaces), nil)
        }

        var words: [LyricWord] = []

        // Any text before the first word tag belongs to the line start.
        if let firstRange = Range(tagMatches[0].range, in: content), firstRange.lowerBound != content.startIndex {
            let leading = String(content[content.startIndex..<firstRange.lowerBound])
            if !leading.trimmingCharacters(in: .whitespaces).isEmpty {
                let end = time(from: tagMatches[0], in: content)
                words.append(LyricWord(text: leading, start: lineStart, end: end))
            }
        }

        for (index, tag) in tagMatches.enumerated() {
            guard let tagRange = Range(tag.range, in: content) else { continue }
            let start = time(from: tag, in: content)
            let textStart = tagRange.upperBound
            let textEnd: String.Index
            let end: TimeInterval
            if index + 1 < tagMatches.count, let nextRange = Range(tagMatches[index + 1].range, in: content) {
                textEnd = nextRange.lowerBound
                end = time(from: tagMatches[index + 1], in: content)
            } else {
                textEnd = content.endIndex
                end = start // unknown; resolved against the line end at fill time
            }
            let wordText = String(content[textStart..<textEnd])
            if !wordText.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(LyricWord(text: wordText, start: start, end: end))
            }
        }

        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return (text, words.isEmpty ? nil : words)
    }

    private static func time(from match: NSTextCheckingResult, in string: String) -> TimeInterval {
        guard match.numberOfRanges >= 4,
              let minRange = Range(match.range(at: 1), in: string),
              let secRange = Range(match.range(at: 2), in: string),
              let msRange = Range(match.range(at: 3), in: string) else { return 0 }

        let minutes = Double(string[minRange]) ?? 0
        let seconds = Double(string[secRange]) ?? 0
        let msString = String(string[msRange])
        let milliseconds = msString.count == 2 ? (Double(msString) ?? 0) * 10 : (Double(msString) ?? 0)
        return minutes * 60 + seconds + milliseconds / 1000
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/LyricsManager.swift

@MainActor
public final class LyricsManager: ObservableObject {
    @Published public var currentLines: [LyricLine] = []
    @Published public var currentLineIndex: Int = 0
    @Published public var isLoading = false
    @Published public var hasLyrics = false
    @Published public var enrichment: [Int: LineEnrichment] = [:]
    @Published public var songSummary: String?
    @Published public var translationNotice: String?
    @Published public var isInstrumentalBreak = false
    @Published public var instrumentalBreakCountdown: TimeInterval = 0
    @Published public var nextVocalLineText: String?

    /// All lyrics candidates for the current track, ranked best-first.
    @Published public var lyricsOptions: [LyricsOption] = []
    /// The id of the option currently shown (matches one of `lyricsOptions`).
    @Published public var selectedOptionID: Int?

    /// Minimum gap (seconds) between current line end and next line start to trigger a break.
    public static let instrumentalBreakThreshold: TimeInterval = 8.0
    /// Seconds before the next vocal line to dismiss the break view.
    public static let breakDismissLeadTime: TimeInterval = 1.0
    /// Fallback vocal-line duration for timestamp-only LRC, which has no explicit line end.
    public static let estimatedLineDuration: TimeInterval = 5.0

    public var showRomanization = false
    public var showTranslation = false
    public var showSongSummary = false
    public var aiTranslationMode: AITranslationMode = .refine
    public var targetLanguage: String = "en"

    private let lrcLib = LRCLibProvider()
    private let speechProvider = SpeechRecognitionProvider()
    private var optionsCache: [String: [LyricsOption]] = [:]
    private var enrichmentCache: [String: [Int: LineEnrichment]] = [:]
    /// Cache key + track for the lyrics currently displayed (needed when switching source).
    private var currentKey: String?
    private var currentTrack: TrackInfo?
    private var enrichmentTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private let enrichmentCoordinator = EnrichmentCoordinator()
    private let foundationModelProvider = FoundationModelProvider()
    private var fetchTask: Task<Void, any Error>?

    // MARK: - Disk Cache

    private nonisolated static let diskCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SpotifyLyrics/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated func diskCacheURL(for key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return Self.diskCacheDirectory.appendingPathComponent("\(safe).json")
    }

    private nonisolated func loadFromDisk(key: String) -> [LyricsOption]? {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = caches.appendingPathComponent("SpotifyLyrics/lyrics/\(safe).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LyricsOption].self, from: data)
    }

    private nonisolated func saveToDisk(options: [LyricsOption], key: String) {
        let url = diskCacheURL(for: key)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(options) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Per-track source selection (persisted)

    private nonisolated func selectionDefaultsKey(for key: String) -> String {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return "lyricsSelection.\(safe)"
    }

    private func persistedSelection(for key: String) -> Int? {
        let dk = selectionDefaultsKey(for: key)
        guard UserDefaults.standard.object(forKey: dk) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: dk)
    }

    private func persistSelection(_ id: Int, for key: String) {
        UserDefaults.standard.set(id, forKey: selectionDefaultsKey(for: key))
    }

    public init() {}

    public func fetchLyrics(for track: TrackInfo) {
        let key = track.cacheKey
        currentTrack = track

        // Cancel any in-flight fetch and enrichment work
        fetchTask?.cancel()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        summaryTask?.cancel()
        summaryTask = nil

        // L1: In-memory cache (synchronous, no race)
        if let cached = optionsCache[key], !cached.isEmpty {
            isLoading = false
            applyOptions(cached, key: key, track: track)
            return
        }

        // Reset state immediately for the new song
        isLoading = true
        currentLines = []
        lyricsOptions = []
        selectedOptionID = nil
        enrichment = [:]
        songSummary = nil
        hasLyrics = false
        currentLineIndex = 0

        // Launch a cancellable fetch task
        fetchTask = Task { [weak self] in
            guard let self else { return }

            // L2: Disk cache
            if let diskCached = await Task.detached(priority: .userInitiated, operation: { [self] in
                self.loadFromDisk(key: key)
            }).value, !diskCached.isEmpty {
                try Task.checkCancellation()
                self.optionsCache[key] = diskCached
                self.applyOptions(diskCached, key: key, track: track)
                self.isLoading = false
                return
            }

            try Task.checkCancellation()

            let options = await lrcLib.fetchOptions(
                title: track.title, artist: track.artist, trackDuration: track.duration
            )

            try Task.checkCancellation()

            if !options.isEmpty {
                self.optionsCache[key] = options
                self.saveToDisk(options: options, key: key)
                self.applyOptions(options, key: key, track: track)
            }

            self.isLoading = false
        }
    }

    /// Publish a freshly-fetched (or cached) option list and display the preferred one.
    private func applyOptions(_ options: [LyricsOption], key: String, track: TrackInfo) {
        lyricsOptions = options
        currentKey = key
        apply(preferredOption(in: options, key: key), key: key, track: track)
    }

    /// The option to show by default: the user's last choice for this track if it
    /// still exists, otherwise the top-ranked candidate.
    private func preferredOption(in options: [LyricsOption], key: String) -> LyricsOption {
        if let savedID = persistedSelection(for: key),
           let match = options.first(where: { $0.id == savedID }) {
            return match
        }
        return options[0]
    }

    /// Display a specific option and kick off enrichment/summary for it.
    private func apply(_ option: LyricsOption, key: String, track: TrackInfo) {
        selectedOptionID = option.id
        currentLines = option.lines
        hasLyrics = !option.lines.isEmpty
        currentLineIndex = 0
        startEnrichment(for: key)
        startSummary(track: track)
    }

    /// Switch the displayed lyrics to another candidate and remember the choice.
    public func selectOption(_ id: Int) {
        guard id != selectedOptionID,
              let key = currentKey,
              let track = currentTrack,
              let option = lyricsOptions.first(where: { $0.id == id }) else { return }

        enrichmentTask?.cancel()
        enrichmentTask = nil
        enrichment = [:]
        summaryTask?.cancel()
        summaryTask = nil

        persistSelection(id, for: key)
        apply(option, key: key, track: track)
    }

    /// Attempt speech recognition on captured audio as a last-resort lyrics source.
    /// Called by the alignment coordinator when lyrics fetch returned empty.
    public func attemptSpeechRecognition(
        audioBuffer: [Float],
        captureStartPosition: TimeInterval,
        cacheKey: String
    ) async {
        guard !hasLyrics else { return }

        isLoading = true
        if let lines = await speechProvider.recognizeLyrics(
            from: audioBuffer,
            captureStartPosition: captureStartPosition
        ) {
            guard !Task.isCancelled else { return }
            let option = LyricsOption(
                id: -1, trackName: "", artistName: "", albumName: nil,
                duration: nil, isSynced: true, lines: lines
            )
            optionsCache[cacheKey] = [option]
            lyricsOptions = [option]
            selectedOptionID = option.id
            currentKey = cacheKey
            currentLines = lines
            hasLyrics = true
            startEnrichment(for: cacheKey)
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    /// Re-run enrichment for the current lyrics (e.g. when settings change).
    public func refreshEnrichment() {
        guard hasLyrics, !currentLines.isEmpty, let key = currentKey else { return }
        // Cancel any in-flight enrichment
        enrichmentTask?.cancel()
        enrichmentTask = nil
        enrichment = [:]
        // Restart — the new enrichment cache key (which encodes current settings)
        // will naturally miss stale entries.
        startEnrichment(for: key)
    }

    private func startEnrichment(for lyricsKey: String) {
        let enrichKey = enrichmentCacheKey(for: lyricsKey)

        // Check enrichment cache
        if let cached = enrichmentCache[enrichKey] {
            enrichment = cached
            return
        }

        guard showRomanization || showTranslation else {
            enrichment = [:]
            return
        }

        let lines = currentLines.map(\.text)
        let romanize = showRomanization
        let translate = showTranslation
        let target = targetLanguage
        let aiMode = aiTranslationMode

        // Check translation language availability
        if translate {
            Task { [weak self] in
                guard let self else { return }
                let notice = await self.enrichmentCoordinator.checkTranslationAvailability(
                    lines: lines, targetLanguage: target
                )
                self.translationNotice = notice
            }
        } else {
            translationNotice = nil
        }

        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.enrichmentCoordinator.enrich(
                lines: lines,
                romanize: romanize,
                translate: translate,
                targetLanguage: target,
                aiTranslationMode: aiMode,
                onRefinement: aiMode != .off ? { [weak self] refined in
                    guard let self, !Task.isCancelled else { return }
                    self.enrichmentCache[enrichKey] = refined
                    self.enrichment = refined
                } : nil
            )
            guard !Task.isCancelled else { return }
            self.enrichmentCache[enrichKey] = result
            self.enrichment = result
        }
    }

    private func startSummary(track: TrackInfo) {
        guard showSongSummary, !currentLines.isEmpty else {
            songSummary = nil
            return
        }

        let lines = currentLines.map(\.text)
        let title = track.title
        let artist = track.artist

        summaryTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.foundationModelProvider.summarizeLyrics(lines, title: title, artist: artist)
            guard !Task.isCancelled else { return }
            self.songSummary = result
        }
    }

    private func enrichmentCacheKey(for lyricsKey: String) -> String {
        "\(lyricsKey)|r:\(showRomanization)|t:\(showTranslation)|ai:\(aiTranslationMode.rawValue)|\(targetLanguage)"
    }

    public func updateCurrentLine(at position: TimeInterval) {
        guard !currentLines.isEmpty else { return }

        // Incremental search from the current index. Normal playback advances by one line,
        // so this is O(1) per call instead of re-scanning from the start; seeks walk a few
        // steps either direction. (Called several times per second from the position timer.)
        var index = min(currentLineIndex, currentLines.count - 1)
        while index + 1 < currentLines.count && currentLines[index + 1].timestamp <= position {
            index += 1
        }
        while index > 0 && currentLines[index].timestamp > position {
            index -= 1
        }

        if index != currentLineIndex {
            currentLineIndex = index
        }
    }

    /// Returns the timestamp of the next lyric line after the current one,
    /// or nil if at the last line or no lyrics are loaded.
    public var nextLineTimestamp: TimeInterval? {
        let nextIndex = currentLineIndex + 1
        guard nextIndex < currentLines.count else { return nil }
        return currentLines[nextIndex].timestamp
    }

    /// Update instrumental break state based on current playback position.
    /// Call this alongside `updateCurrentLine(at:)` from the polling loop.
    public func updateInstrumentalBreak(at position: TimeInterval) {
        guard !currentLines.isEmpty, currentLineIndex < currentLines.count else {
            if isInstrumentalBreak { isInstrumentalBreak = false }
            return
        }

        guard currentLineIndex + 1 < currentLines.count else {
            if isInstrumentalBreak { isInstrumentalBreak = false }
            return
        }

        let currentLine = currentLines[currentLineIndex]
        let nextLine = currentLines[currentLineIndex + 1]
        let currentEnd = currentLine.endTime ?? min(
            currentLine.timestamp + Self.estimatedLineDuration,
            nextLine.timestamp
        )
        let gap = nextLine.timestamp - currentEnd

        // Only consider it a break if gap exceeds threshold and we're past the current line's end
        if gap >= Self.instrumentalBreakThreshold && position >= currentEnd {
            let countdown = nextLine.timestamp - Self.breakDismissLeadTime - position
            if countdown > 0 {
                isInstrumentalBreak = true
                instrumentalBreakCountdown = countdown
                nextVocalLineText = nextLine.text
            } else {
                // Within lead time — dismiss break
                isInstrumentalBreak = false
                instrumentalBreakCountdown = 0
                nextVocalLineText = nil
            }
        } else {
            if isInstrumentalBreak {
                isInstrumentalBreak = false
                instrumentalBreakCountdown = 0
                nextVocalLineText = nil
            }
        }
    }

    public func clearCache() {
        optionsCache.removeAll()
        enrichmentCache.removeAll()
        enrichment = [:]
        lyricsOptions = []
        selectedOptionID = nil
        // Forget persisted per-track source selections.
        let defaults = UserDefaults.standard
        for dkey in defaults.dictionaryRepresentation().keys where dkey.hasPrefix("lyricsSelection.") {
            defaults.removeObject(forKey: dkey)
        }
        // Clear disk cache
        Task.detached(priority: .utility) {
            let dir = Self.diskCacheDirectory
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/LyricsOption.swift

/// One candidate lyrics result from LRCLIB for a given track.
///
/// A search usually returns several matches (different albums, versions, or
/// synced vs. plain). The provider ranks them best-first; the user can switch
/// between them from the menu bar. `id` is the stable LRCLIB result id, used
/// both for the picker selection and for persisting the user's choice.
public struct LyricsOption: Identifiable, Equatable, Codable {
    public let id: Int
    public let trackName: String
    public let artistName: String
    public let albumName: String?
    public let duration: TimeInterval?
    /// True when these lines carry real timestamps (synced), false for plain text.
    public let isSynced: Bool
    public let lines: [LyricLine]

    public init(
        id: Int,
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: TimeInterval?,
        isSynced: Bool,
        lines: [LyricLine]
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.isSynced = isSynced
        self.lines = lines
    }

    /// Short label for the picker, e.g. "Synced · Album · 3:42".
    public var menuLabel: String {
        var parts: [String] = [isSynced ? "Synced" : "Plain"]
        if let albumName, !albumName.isEmpty { parts.append(albumName) }
        if let duration, duration > 0 { parts.append(Self.formatDuration(duration)) }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/SpeechRecognitionProvider.swift

/// Generates lyrics from captured audio using Apple's Speech framework (SFSpeechRecognizer).
/// Used as a last-resort fallback when LRCLIB has no results.
///
/// Requires:
/// - Speech Recognition permission (prompted on first use)
/// - Audio buffer from AudioCaptureService (16kHz mono Float32)
@MainActor
public final class SpeechRecognitionProvider: ObservableObject {

    public enum RecognitionState: Equatable {
        case idle
        case recognizing
        case completed
        case failed(String)
    }

    @Published public private(set) var state: RecognitionState = .idle

    private let recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?

    public init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Permission

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Recognition

    /// Recognize lyrics from a 16kHz mono Float32 audio buffer.
    ///
    /// - Parameters:
    ///   - audioBuffer: Raw Float32 samples at 16kHz mono
    ///   - captureStartPosition: The song playback position when capture started
    /// - Returns: Array of LyricLines with word-level timings, or nil on failure
    public func recognizeLyrics(
        from audioBuffer: [Float],
        captureStartPosition: TimeInterval
    ) async -> [LyricLine]? {
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Speech recognizer unavailable")
            return nil
        }

        if !Self.isAuthorized {
            let granted = await Self.requestPermission()
            guard granted else {
                state = .failed("Speech recognition not authorized")
                return nil
            }
        }

        state = .recognizing

        // Write audio buffer to a temporary WAV file for SFSpeechRecognizer
        guard let tempURL = writeWAV(samples: audioBuffer, sampleRate: 16000) else {
            state = .failed("Failed to create audio file")
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Request word-level timestamps
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult?, Never>) in
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if (error as NSError).code != 1 { // Ignore cancellation
                        continuation.resume(returning: nil)
                    }
                    return
                }
                if let result, result.isFinal {
                    continuation.resume(returning: result)
                }
            }
        }

        recognitionTask = nil

        guard let result else {
            state = .failed("Recognition failed")
            return nil
        }

        let lines = buildLyricLines(from: result, captureStartPosition: captureStartPosition)
        state = lines.isEmpty ? .failed("No speech detected") : .completed
        return lines.isEmpty ? nil : lines
    }

    /// Cancel any in-progress recognition.
    public func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        state = .idle
    }

    // MARK: - Line Building

    /// Converts SFSpeechRecognitionResult into LyricLine array.
    /// Groups words into lines based on pauses between words (>0.8s gap = new line).
    private func buildLyricLines(
        from result: SFSpeechRecognitionResult,
        captureStartPosition: TimeInterval
    ) -> [LyricLine] {
        let bestTranscription = result.bestTranscription
        let segments = bestTranscription.segments

        guard !segments.isEmpty else { return [] }

        var lines: [LyricLine] = []
        var currentWords: [LyricWord] = []
        var lineStartTime: TimeInterval = 0
        var lastEndTime: TimeInterval = 0
        let pauseThreshold: TimeInterval = 0.8

        for (i, segment) in segments.enumerated() {
            let wordStart = captureStartPosition + segment.timestamp
            let wordEnd = captureStartPosition + segment.timestamp + segment.duration

            // Detect line breaks based on pauses
            if i > 0 && (segment.timestamp - lastEndTime) > pauseThreshold {
                // Flush current line
                if !currentWords.isEmpty {
                    let text = currentWords.map(\.text).joined(separator: " ")
                    lines.append(LyricLine(
                        timestamp: lineStartTime,
                        text: text,
                        words: currentWords,
                        endTime: currentWords.last?.end
                    ))
                    currentWords.removeAll()
                }
                lineStartTime = wordStart
            }

            if currentWords.isEmpty {
                lineStartTime = wordStart
            }

            currentWords.append(LyricWord(
                text: segment.substring,
                start: wordStart,
                end: wordEnd
            ))
            lastEndTime = segment.timestamp + segment.duration
        }

        // Flush remaining words
        if !currentWords.isEmpty {
            let text = currentWords.map(\.text).joined(separator: " ")
            lines.append(LyricLine(
                timestamp: lineStartTime,
                text: text,
                words: currentWords,
                endTime: currentWords.last?.end
            ))
        }

        return lines
    }

    // MARK: - WAV Writing

    /// Write Float32 samples to a temporary 16kHz mono WAV file.
    private func writeWAV(samples: [Float], sampleRate: Int) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("speech_recognition_\(UUID().uuidString).wav")

        let numSamples = samples.count
        let dataSize = numSamples * 2  // 16-bit PCM
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })     // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })     // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) }) // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })     // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })    // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        // Convert Float32 [-1, 1] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/Enrichment/AppleTranslationProvider.swift

#if canImport(Translation) && compiler(>=6.2)
@available(macOS 26.0, *)
public struct AppleTranslationProvider: LyricsEnrichmentProvider, Sendable {
    public let capabilities: EnrichmentCapabilities = .translation

    public init() {}

    public func translate(_ lines: [String], to targetLanguage: String, from sourceLanguage: String?) async throws -> [String?] {
        let target = Locale.Language(identifier: targetLanguage)
        let targetCode = target.languageCode?.identifier ?? targetLanguage
        let availability = LanguageAvailability()

        var sessions: [String: TranslationSession] = [:]

        func session(for srcLang: String) async -> TranslationSession? {
            if let existing = sessions[srcLang] { return existing }
            let src = Locale.Language(identifier: srcLang)
            let status = await availability.status(from: src, to: target)
            guard status == .installed else { return nil }
            let s = TranslationSession(installedSource: src, target: target)
            sessions[srcLang] = s
            return s
        }

        var results = [String?](repeating: nil, count: lines.count)
        let recognizer = NLLanguageRecognizer()

        // Classify each line: detect language, check if mixed
        struct LineInfo {
            let index: Int
            let trimmed: String
            let detectedLang: String?
            let isMixed: Bool
            let segments: [LangSegment]
        }

        var lineInfos: [LineInfo] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            recognizer.reset()
            recognizer.processString(trimmed)
            let lineLang = recognizer.dominantLanguage?.rawValue

            // Skip if line is already in target language
            if let lineLang {
                let lineCode = Locale.Language(identifier: lineLang).languageCode?.identifier ?? lineLang
                if lineCode == targetCode { continue }
            }

            let segments = segmentByLanguage(trimmed, recognizer: recognizer)
            let isMixed = segments.count > 1
            lineInfos.append(LineInfo(index: i, trimmed: trimmed, detectedLang: lineLang, isMixed: isMixed, segments: segments))
        }

        // Handle mixed-language lines individually
        for info in lineInfos where info.isMixed {
            var translatedParts: [String] = []
            var anyTranslated = false

            for segment in info.segments {
                let segCode = Locale.Language(identifier: segment.language).languageCode?.identifier ?? segment.language
                if segCode == targetCode {
                    translatedParts.append(segment.text)
                } else if let sess = await session(for: segment.language) {
                    if let response = try? await sess.translate(segment.text),
                       response.targetText != segment.text {
                        translatedParts.append(response.targetText)
                        anyTranslated = true
                    } else {
                        translatedParts.append(segment.text)
                    }
                } else {
                    translatedParts.append(segment.text)
                }
            }

            if anyTranslated {
                results[info.index] = translatedParts.joined(separator: " ")
            }
        }

        // Batch single-language lines by detected language for contextual translation
        let singleLangInfos = lineInfos.filter { !$0.isMixed }

        var langBatches: [String: [(info: LineInfo, lang: String)]] = [:]
        for info in singleLangInfos {
            guard let lang = info.detectedLang ?? sourceLanguage else { continue }
            langBatches[lang, default: []].append((info, lang))
        }

        let batchSeparator = "\n"

        for (lang, batch) in langBatches {
            guard let sess = await session(for: lang) else {
                if let fallbackLang = sourceLanguage, fallbackLang != lang,
                   let fallbackSess = await session(for: fallbackLang) {
                    for item in batch {
                        if let response = try? await fallbackSess.translate(item.info.trimmed),
                           response.targetText != item.info.trimmed {
                            results[item.info.index] = response.targetText
                        }
                    }
                }
                continue
            }

            // Translate lines as a joined paragraph for better context
            let paragraph = batch.map(\.info.trimmed).joined(separator: batchSeparator)

            do {
                let response = try await sess.translate(paragraph)
                let translatedLines = response.targetText.components(separatedBy: batchSeparator)

                if translatedLines.count == batch.count {
                    for (j, item) in batch.enumerated() {
                        let translated = translatedLines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !translated.isEmpty && translated != item.info.trimmed {
                            results[item.info.index] = translated
                        }
                    }
                } else {
                    // Fallback: translate individually if paragraph splitting failed
                    for item in batch {
                        if let singleResponse = try? await sess.translate(item.info.trimmed),
                           singleResponse.targetText != item.info.trimmed {
                            results[item.info.index] = singleResponse.targetText
                        }
                    }
                }
            } catch {
                for item in batch {
                    if let singleResponse = try? await sess.translate(item.info.trimmed),
                       singleResponse.targetText != item.info.trimmed {
                        results[item.info.index] = singleResponse.targetText
                    }
                }
            }
        }

        return results
    }

    /// Splits text into segments by detected language using NLTagger.
    private func segmentByLanguage(_ text: String, recognizer: NLLanguageRecognizer) -> [LangSegment] {
        let tagger = NLTagger(tagSchemes: [.language])
        tagger.string = text

        var segments: [LangSegment] = []
        var lastLang: String?
        var currentText = ""

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .language) { tag, range in
            let word = String(text[range])
            let lang = tag?.rawValue ?? "und"

            if lang == lastLang || lastLang == nil {
                currentText += word
                lastLang = lang
            } else {
                if !currentText.isEmpty, let prevLang = lastLang {
                    segments.append(LangSegment(text: currentText.trimmingCharacters(in: .whitespaces), language: prevLang))
                }
                currentText = word
                lastLang = lang
            }
            return true
        }

        // Flush remaining
        if !currentText.isEmpty, let lang = lastLang {
            segments.append(LangSegment(text: currentText.trimmingCharacters(in: .whitespaces), language: lang))
        }

        // Merge adjacent segments with the same language
        var merged: [LangSegment] = []
        for seg in segments where !seg.text.isEmpty {
            if let last = merged.last, last.language == seg.language {
                merged[merged.count - 1] = LangSegment(text: last.text + " " + seg.text, language: seg.language)
            } else {
                merged.append(seg)
            }
        }

        // Filter out "und" (undetermined) — attach to nearest neighbor
        if merged.count > 1 {
            var resolved: [LangSegment] = []
            for seg in merged {
                if seg.language == "und" {
                    // Attach to previous segment if exists, else next
                    if var prev = resolved.last {
                        prev = LangSegment(text: prev.text + " " + seg.text, language: prev.language)
                        resolved[resolved.count - 1] = prev
                    } else {
                        resolved.append(seg)
                    }
                } else {
                    resolved.append(seg)
                }
            }
            return resolved
        }

        return merged
    }
}

private struct LangSegment {
    let text: String
    let language: String
}
#endif

// MARK: - SpotifyLyricsCore/Lyrics/Enrichment/EnrichmentCoordinator.swift

#if canImport(FoundationModels) && compiler(>=6.2)
#endif
#if canImport(Translation) && compiler(>=6.2)
#endif

@MainActor
public final class EnrichmentCoordinator {
    private var providers: [LyricsEnrichmentProvider]

    public init() {
        var list: [LyricsEnrichmentProvider] = [ICURomanizationProvider()]
        #if canImport(Translation) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            list.append(AppleTranslationProvider())
        }
        #endif
        providers = list
    }

    /// Enrich lyrics lines with romanization and/or translation.
    /// The `onRefinement` callback fires asynchronously when AI-refined translations are ready.
    public func enrich(
        lines: [String],
        romanize: Bool,
        translate: Bool,
        targetLanguage: String = "en",
        aiTranslationMode: AITranslationMode = .refine,
        onRefinement: (([Int: LineEnrichment]) -> Void)? = nil
    ) async -> [Int: LineEnrichment] {
        guard !lines.isEmpty, romanize || translate else { return [:] }

        let sourceLanguage = detectLanguage(from: lines)
        print("[Enrichment] Starting enrichment: \(lines.count) lines, source=\(sourceLanguage ?? "nil"), target=\(targetLanguage), romanize=\(romanize), translate=\(translate), aiMode=\(aiTranslationMode.rawValue)")
        var result: [Int: LineEnrichment] = [:]

        // Romanization
        if romanize, let provider = provider(for: .romanization) {
            do {
                let romanized = try await provider.romanize(lines, from: sourceLanguage)
                for (i, rom) in romanized.enumerated() {
                    if let rom, !rom.isEmpty {
                        var enrichment = result[i] ?? LineEnrichment()
                        enrichment.romanization = rom
                        result[i] = enrichment
                    }
                }
            } catch {
                // Best-effort
            }
        }

        // Translation
        if translate, sourceLanguage != targetLanguage {
            switch aiTranslationMode {
            case .primary:
                // AI translates first, Apple Translation fills gaps
                print("[Enrichment] AI Primary mode: translating with Foundation Model")
                let aiTranslations = await translateWithFoundationModel(lines, targetLanguage: targetLanguage)
                for (i, trans) in aiTranslations {
                    var enrichment = result[i] ?? LineEnrichment()
                    enrichment.translation = fixPostCommaCapitalization(trans)
                    result[i] = enrichment
                    print("[Enrichment]   [\(i)] AI: \"\(lines[i])\" → \"\(trans)\"")
                }

                // Fill gaps with Apple Translation
                if let provider = provider(for: .translation) {
                    let missingIndices = lines.indices.filter { i in
                        let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        return !trimmed.isEmpty && result[i]?.translation == nil
                    }
                    if !missingIndices.isEmpty {
                        print("[Enrichment] Apple Translation fallback for \(missingIndices.count) lines")
                        if let translated = try? await provider.translate(lines, to: targetLanguage, from: sourceLanguage) {
                            for i in missingIndices {
                                if let trans = translated[i], !trans.isEmpty {
                                    var enrichment = result[i] ?? LineEnrichment()
                                    enrichment.translation = fixPostCommaCapitalization(trans)
                                    result[i] = enrichment
                                }
                            }
                        }
                    }
                }

            case .refine:
                // Apple Translation first, AI refines in background
                if let provider = provider(for: .translation) {
                    print("[Enrichment] Refine mode: Apple Translation first")
                    do {
                        let translated = try await provider.translate(lines, to: targetLanguage, from: sourceLanguage)
                        for (i, trans) in translated.enumerated() {
                            if let trans, !trans.isEmpty {
                                var enrichment = result[i] ?? LineEnrichment()
                                enrichment.translation = fixPostCommaCapitalization(trans)
                                result[i] = enrichment
                                print("[Enrichment]   [\(i)] \"\(lines[i])\" → \"\(trans)\"")
                            }
                        }
                    } catch {
                        print("[Enrichment] Apple Translation error: \(error)")
                    }
                }

                if let onRefinement {
                    let baseResult = result
                    let target = targetLanguage
                    let capturedLines = lines
                    Task { [weak self] in
                        guard let self else { return }
                        let aiTranslations = await self.translateWithFoundationModel(capturedLines, targetLanguage: target)
                        guard !aiTranslations.isEmpty, !Task.isCancelled else {
                            print("[Enrichment] AI refinement: no improvements")
                            return
                        }
                        var updated = baseResult
                        for (index, trans) in aiTranslations {
                            var enrichment = updated[index] ?? LineEnrichment()
                            enrichment.translation = fixPostCommaCapitalization(trans)
                            updated[index] = enrichment
                        }
                        print("[Enrichment] AI refinement: replaced \(aiTranslations.count) translations")
                        onRefinement(updated)
                    }
                }

            case .off:
                // Apple Translation only
                if let provider = provider(for: .translation) {
                    print("[Enrichment] Off mode: Apple Translation only")
                    do {
                        let translated = try await provider.translate(lines, to: targetLanguage, from: sourceLanguage)
                        for (i, trans) in translated.enumerated() {
                            if let trans, !trans.isEmpty {
                                var enrichment = result[i] ?? LineEnrichment()
                                enrichment.translation = fixPostCommaCapitalization(trans)
                                result[i] = enrichment
                            }
                        }
                    } catch {
                        print("[Enrichment] Apple Translation error: \(error)")
                    }
                }
            }
        } else if translate {
            print("[Enrichment] Skipping translation: source (\(sourceLanguage ?? "nil")) == target (\(targetLanguage))")
        }

        return result
    }

    /// Detect the dominant language from a sample of lyric lines.
    func detectLanguage(from lines: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        let sample = lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(20)
            .joined(separator: "\n")
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    private func provider(for capability: EnrichmentCapabilities) -> LyricsEnrichmentProvider? {
        providers.first { $0.capabilities.contains(capability) }
    }

    /// Lowercase words after commas that were incorrectly capitalized by translation APIs.
    /// e.g. "Ya, Ah" → "Ya, ah"
    private func fixPostCommaCapitalization(_ text: String) -> String {
        var result = text
        let pattern = try! NSRegularExpression(pattern: #",\s+([A-Z])"#)
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let capRange = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(capRange, with: result[capRange].lowercased())
        }
        return result
    }

    /// Check if the translation language pair is available and return a user-facing notice if not.
    public func checkTranslationAvailability(lines: [String], targetLanguage: String) async -> String? {
        #if canImport(Translation) && compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return nil }

        let sourceLanguage = detectLanguage(from: lines)
        guard let srcLang = sourceLanguage else { return nil }

        let src = Locale.Language(identifier: srcLang)
        let target = Locale.Language(identifier: targetLanguage)

        let srcCode = src.languageCode?.identifier ?? srcLang
        let targetCode = target.languageCode?.identifier ?? targetLanguage
        guard srcCode != targetCode else { return nil }

        let availability = LanguageAvailability()
        let status = await availability.status(from: src, to: target)

        switch status {
        case .installed:
            return nil
        case .supported:
            let srcName = Locale.current.localizedString(forLanguageCode: srcLang) ?? srcLang
            let targetName = Locale.current.localizedString(forLanguageCode: targetLanguage) ?? targetLanguage
            return "Download \(srcName) → \(targetName) language pack in Settings → Translation & Languages."
        case .unsupported:
            let srcName = Locale.current.localizedString(forLanguageCode: srcLang) ?? srcLang
            let targetName = Locale.current.localizedString(forLanguageCode: targetLanguage) ?? targetLanguage
            return "\(srcName) → \(targetName) translation is not supported."
        @unknown default:
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Translate song lyrics using Foundation Models (on-device AI).
    /// Returns a dictionary of line index → translated text.
    private func translateWithFoundationModel(
        _ lines: [String],
        targetLanguage: String
    ) async -> [Int: String] {
        #if canImport(FoundationModels) && compiler(>=6.2)
        guard #available(macOS 26, *) else {
            print("[AI-Translate] macOS 26 not available")
            return [:]
        }
        guard SystemLanguageModel.default.availability == .available else {
            print("[AI-Translate] Apple Intelligence not enabled")
            return [:]
        }

        // Filter to non-empty lines
        let indexedLines = lines.enumerated().compactMap { (i, line) -> (Int, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (i, trimmed)
        }
        guard !indexedLines.isEmpty else { return [:] }

        let langName = Locale.current.localizedString(forLanguageCode: targetLanguage) ?? targetLanguage

        // Split into batches to reduce guardrail violations
        let batchSize = 10
        let batches = stride(from: 0, to: indexedLines.count, by: batchSize).map {
            Array(indexedLines[$0..<min($0 + batchSize, indexedLines.count)])
        }

        print("[AI-Translate] Sending \(indexedLines.count) lines in \(batches.count) batches to Foundation Model")

        var translations: [Int: String] = [:]

        // Use permissive guardrails: lyric translation is a content-transformation
        // task, so the default safety guardrails (which flag explicit lyrics as
        // "unsafe content") are too aggressive and drop whole batches.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model) {
            "You are a professional song lyric translator. Translate lyrics accurately with correct contextual meaning for slang, idioms, and figurative language. Output only numbered translations."
        }

        for (batchIndex, batch) in batches.enumerated() {
                guard !Task.isCancelled else { break }

                let numberedLyrics = batch.enumerated().map { (n, pair) in
                    "\(n + 1). \(pair.1)"
                }.joined(separator: "\n")

                let prompt = """
                Translate these song lyrics to \(langName). Use correct contextual meaning (e.g. "high" = mabuk/melayang, "blue" = sedih).
                Output ONLY: NUMBER. translation

                \(numberedLyrics)
                """

                do {
                    let response: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask {
                            let resp = try await session.respond(to: prompt)
                            return resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(15))
                            return nil
                        }
                        if let first = try await group.next() {
                            group.cancelAll()
                            return first
                        }
                        return nil
                    }

                    guard let response, !response.isEmpty else {
                        print("[AI-Translate] Batch \(batchIndex + 1): no response or timed out")
                        continue
                    }

                    // Parse "NUMBER. translation" lines
                    for line in response.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        guard let dotIndex = trimmed.firstIndex(of: ".") else { continue }
                        let numStr = trimmed[trimmed.startIndex..<dotIndex].trimmingCharacters(in: .whitespaces)
                        guard let num = Int(numStr), num >= 1, num <= batch.count else { continue }
                        let translatedText = trimmed[trimmed.index(after: dotIndex)...].trimmingCharacters(in: .whitespaces)
                        if !translatedText.isEmpty {
                            let originalIndex = batch[num - 1].0
                            translations[originalIndex] = translatedText
                        }
                    }
                    print("[AI-Translate] Batch \(batchIndex + 1): translated \(batch.count) lines")
                } catch {
                    // Guardrail violation or other error — skip this batch silently
                    print("[AI-Translate] Batch \(batchIndex + 1) skipped (guardrail/error): \(error)")
                    continue
                }
            }

        print("[AI-Translate] Total: \(translations.count)/\(indexedLines.count) lines translated")
        return translations
        #else
        print("[AI-Translate] FoundationModels not available at compile time")
        return [:]
        #endif
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/Enrichment/FoundationModelProvider.swift

#if canImport(FoundationModels) && compiler(>=6.2)
#endif

/// On-device AI lyrics summary using Apple Foundation Models (macOS 26+).
/// Generates a one-line theme summary of a song's lyrics, cached per (title, artist).
///
/// When Foundation Models is not available (macOS < 26 or unsupported hardware),
/// `summarizeLyrics` returns nil gracefully.
@MainActor
public final class FoundationModelProvider {
    private var cache: [String: String] = [:]

    public init() {}

    private func cacheKey(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    /// Build the prompt for lyrics summarization.
    public func buildPrompt(lines: [String], title: String, artist: String) -> String {
        let lyricsText = lines.prefix(40).joined(separator: "\n")
        return "Song: \(title) by \(artist)\nLyrics:\n\(lyricsText)"
    }

    /// Summarize lyrics into a one-line theme description.
    /// Returns nil if Foundation Models is unavailable or the request times out.
    public func summarizeLyrics(_ lines: [String], title: String, artist: String) async -> String? {
        let key = cacheKey(title: title, artist: artist)
        if let cached = cache[key] { return cached }
        guard !lines.isEmpty else { return nil }

        guard let summary = await invokeFoundationModel(lines: lines, title: title, artist: artist) else {
            return nil
        }

        cache[key] = summary
        return summary
    }

    /// Cache a summary directly (useful for testing or manual input).
    public func cacheSummary(_ summary: String, title: String, artist: String) {
        cache[cacheKey(title: title, artist: artist)] = summary
    }

    /// Check if a summary is cached for the given track.
    public func hasCachedSummary(title: String, artist: String) -> Bool {
        cache[cacheKey(title: title, artist: artist)] != nil
    }

    private func invokeFoundationModel(lines: [String], title: String, artist: String) async -> String? {
        #if canImport(FoundationModels) && compiler(>=6.2)
        guard #available(macOS 26, *) else { return nil }
        guard SystemLanguageModel.default.availability == .available else {
            print("[AI-Summary] Apple Intelligence not enabled")
            return nil
        }

        let prompt = buildPrompt(lines: lines, title: title, artist: artist)

        do {
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model) {
                "You summarize song themes in one short sentence (max 15 words). Output only the summary sentence, nothing else."
            }

            // Race the model call against a 10-second timeout
            let summary: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    return nil
                }

                if let first = try await group.next() {
                    group.cancelAll()
                    return first
                }
                return nil
            }

            if let summary, !summary.isEmpty {
                return summary
            }
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/Enrichment/ICURomanizationProvider.swift

public struct ICURomanizationProvider: LyricsEnrichmentProvider {
    public let capabilities: EnrichmentCapabilities = .romanization

    public init() {}

    public func romanize(_ lines: [String], from sourceLanguage: String?) async throws -> [String?] {
        let isJapanese = sourceLanguage == "ja"
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard !isLatin(line) else { return nil }
            if isJapanese || containsJapanese(line) {
                return transliterateJapanese(line)
            }
            return transliterate(line)
        }
    }

    /// Japanese-aware romanization using CFStringTokenizer which provides
    /// correct readings (e.g. 大丈夫 → daijoubu, not da zhang fu).
    private func transliterateJapanese(_ text: String) -> String? {
        let cfText = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, cfText, CFRangeMake(0, CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        )

        var parts: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)

        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let tokenText = CFStringCreateWithSubstring(nil, cfText, range) as String

            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                parts.append(latin)
            } else {
                // Keep non-transliterable tokens (punctuation, Latin text) as-is
                parts.append(tokenText)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        let result = parts.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty, result != text else { return nil }
        return result
    }

    private func transliterate(_ text: String) -> String? {
        let mutable = NSMutableString(string: text)
        // toLatin converts CJK, Cyrillic, Arabic, etc. to Latin script
        guard CFStringTransform(mutable, nil, kCFStringTransformToLatin, false) else { return nil }
        // Strip combining marks (diacritics) for cleaner output
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let result = mutable as String
        // If the result is identical to input, no useful transform happened
        guard result != text else { return nil }
        return result
    }

    /// Detects if text contains Hiragana, Katakana, or CJK characters in Japanese context.
    private func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Hiragana
            (0x3040...0x309F).contains(scalar.value) ||
            // Katakana
            (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    /// Returns true if the string is predominantly Latin script (ASCII letters + common Latin Extended).
    func isLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let latinCount = letters.filter { scalar in
            // Basic Latin + Latin Extended-A/B + Latin Extended Additional
            (0x0041...0x024F).contains(scalar.value) ||
            (0x1E00...0x1EFF).contains(scalar.value)
        }.count
        return Double(latinCount) / Double(letters.count) > 0.5
    }
}

// MARK: - SpotifyLyricsCore/Lyrics/Enrichment/LyricsEnrichmentProvider.swift

public struct EnrichmentCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let romanization = EnrichmentCapabilities(rawValue: 1 << 0)
    public static let translation = EnrichmentCapabilities(rawValue: 1 << 1)
}

public protocol LyricsEnrichmentProvider: Sendable {
    var capabilities: EnrichmentCapabilities { get }
    func romanize(_ lines: [String], from sourceLanguage: String?) async throws -> [String?]
    func translate(_ lines: [String], to targetLanguage: String, from sourceLanguage: String?) async throws -> [String?]
}

extension LyricsEnrichmentProvider {
    public func romanize(_ lines: [String], from sourceLanguage: String?) async throws -> [String?] {
        Array(repeating: nil, count: lines.count)
    }

    public func translate(_ lines: [String], to targetLanguage: String, from sourceLanguage: String?) async throws -> [String?] {
        Array(repeating: nil, count: lines.count)
    }
}

// MARK: - SpotifyLyricsCore/Analysis/SoundClassifier.swift

@preconcurrency import SoundAnalysis
@preconcurrency import AVFoundation

/// Classifies audio using Apple's SoundAnalysis framework to detect music characteristics.
/// Exposes music mood/genre results for dynamic overlay theming.
///
/// Uses the built-in SNClassifySoundRequest to identify sounds like music, singing, etc.
/// On macOS 15+, can also detect musical genre for richer theming.
@MainActor
public final class SoundClassifier: ObservableObject {

    /// High-level mood derived from sound classification results.
    public enum MusicMood: String, CaseIterable {
        case energetic    // Fast, upbeat, loud
        case calm         // Slow, quiet, ambient
        case vocal        // Singing-dominant
        case instrumental // No vocals detected
        case unknown

        public var themeHue: Double {
            switch self {
            case .energetic:    return 0.05   // Warm orange-red
            case .calm:         return 0.6    // Cool blue
            case .vocal:        return 0.8    // Purple
            case .instrumental: return 0.45   // Teal
            case .unknown:      return 0.0    // Neutral
            }
        }

        public var animationSpeed: Double {
            switch self {
            case .energetic:    return 1.5
            case .calm:         return 0.6
            case .vocal:        return 1.0
            case .instrumental: return 0.8
            case .unknown:      return 1.0
            }
        }
    }

    @Published public private(set) var currentMood: MusicMood = .unknown
    @Published public private(set) var confidence: Double = 0.0
    @Published public private(set) var isSinging: Bool = false
    @Published public private(set) var detectedSounds: [String: Double] = [:]

    private var analyzer: SNAudioStreamAnalyzer?
    private var analysisQueue = DispatchQueue(label: "com.spotifylyrics.soundanalysis", qos: .userInitiated)
    private var observer: ClassificationObserver?
    private var format: AVAudioFormat?

    public init() {}

    // MARK: - Analysis Control

    /// Start analyzing audio from a continuous stream of Float32 samples.
    /// Call `appendSamples(_:)` to feed audio data.
    public func startAnalysis() {
        let audioFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16000,
            channels: 1
        )!
        self.format = audioFormat

        let analyzer = SNAudioStreamAnalyzer(format: audioFormat)
        self.analyzer = analyzer

        let observer = ClassificationObserver { [weak self] results in
            Task { @MainActor [weak self] in
                self?.processResults(results)
            }
        }
        self.observer = observer

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 3.0, preferredTimescale: 1000)
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: observer)
        } catch {
            // Classifier not available on this system
        }
    }

    /// Feed audio samples into the analyzer.
    /// Samples should be 16kHz mono Float32 (same format as AudioCaptureService).
    public func appendSamples(_ samples: [Float]) {
        guard let analyzer, let format else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        let time = AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        analysisQueue.async {
            analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
    }

    /// Stop analysis and reset state.
    public func stopAnalysis() {
        if let analyzer {
            analyzer.removeAllRequests()
        }
        analyzer = nil
        observer = nil
        format = nil
        currentMood = .unknown
        confidence = 0.0
        isSinging = false
        detectedSounds.removeAll()
    }

    // MARK: - Result Processing

    private func processResults(_ results: [String: Double]) {
        detectedSounds = results

        // Determine if singing is happening
        let singingScore = results["singing"] ?? 0
        let musicScore = results["music"] ?? 0
        let speechScore = results["speech"] ?? 0

        isSinging = singingScore > 0.3 || (speechScore > 0.3 && musicScore > 0.3)

        // Determine mood from sound classifications
        let newMood: MusicMood
        let newConfidence: Double

        if singingScore > 0.5 {
            newMood = .vocal
            newConfidence = singingScore
        } else if musicScore > 0.5 && singingScore < 0.1 && speechScore < 0.1 {
            newMood = .instrumental
            newConfidence = musicScore
        } else if musicScore > 0.3 {
            // Use energy-related classifications to differentiate energetic vs calm
            let drumScore = results["drum"] ?? 0
            let guitarScore = results["guitar"] ?? 0
            let pianoScore = results["piano"] ?? 0

            if drumScore > 0.2 || guitarScore > 0.3 {
                newMood = .energetic
                newConfidence = max(drumScore, guitarScore)
            } else if pianoScore > 0.2 {
                newMood = .calm
                newConfidence = pianoScore
            } else {
                newMood = .unknown
                newConfidence = musicScore
            }
        } else {
            newMood = .unknown
            newConfidence = 0.0
        }

        if newConfidence > 0.2 {
            currentMood = newMood
            confidence = newConfidence
        }
    }
}

// MARK: - Classification Observer

private final class ClassificationObserver: NSObject, SNResultsObserving {
    let onResults: ([String: Double]) -> Void

    init(onResults: @escaping ([String: Double]) -> Void) {
        self.onResults = onResults
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        var results: [String: Double] = [:]
        for item in classification.classifications {
            results[item.identifier] = item.confidence
        }
        onResults(results)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // Classification failed — not critical
    }

    func requestDidComplete(_ request: SNRequest) {
        // Analysis complete
    }
}

// MARK: - SpotifyLyricsCore/Analysis/VisionAnalyzer.swift

/// Uses the Vision framework for advanced album art analysis:
/// - Multi-color palette extraction (dominant + accent colors)
/// - Text recognition from album art (title, artist embedded in artwork)
/// - Image saliency detection for focus areas
@MainActor
public final class VisionAnalyzer: ObservableObject {

    /// A color palette extracted from album art.
    public struct ColorPalette: Equatable {
        public let dominant: NSColor
        public let accent: NSColor
        public let background: NSColor
        public let isLight: Bool

        public init(dominant: NSColor, accent: NSColor, background: NSColor, isLight: Bool) {
            self.dominant = dominant
            self.accent = accent
            self.background = background
            self.isLight = isLight
        }
    }

    @Published public private(set) var palette: ColorPalette?
    @Published public private(set) var detectedText: [String] = []
    @Published public private(set) var saliencyCenter: CGPoint?

    private var cachedURL: URL?

    public init() {}

    // MARK: - Analysis

    /// Analyze album art from a URL. Extracts color palette, text, and saliency.
    public func analyze(imageURL: URL?) {
        guard let url = imageURL, url != cachedURL else { return }
        cachedURL = url

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }

            async let paletteResult = VisionAnalyzer.extractColorPalette(from: cgImage)
            async let textResult = VisionAnalyzer.recognizeText(in: cgImage)
            async let saliencyResult = VisionAnalyzer.detectSaliency(in: cgImage)

            let palette = await paletteResult
            let text = await textResult
            let saliency = await saliencyResult

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let palette {
                    self.palette = palette
                }
                self.detectedText = text
                self.saliencyCenter = saliency
            }
        }
    }

    // MARK: - Color Palette Extraction

    /// Extract a multi-color palette from an image using Vision's feature print
    /// combined with k-means-style region sampling.
    private nonisolated static func extractColorPalette(from cgImage: CGImage) async -> ColorPalette? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // Sample colors from a grid across the image
        let sampleSize = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Collect sampled colors as HSB tuples
        struct HSBColor: Hashable {
            let hue: CGFloat
            let saturation: CGFloat
            let brightness: CGFloat
        }

        var colorCounts: [HSBColor: Int] = [:]
        let stepX = max(width / sampleSize, 1)
        let stepY = max(height / sampleSize, 1)

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = (y * width + x) * bytesPerPixel
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                let color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

                // Quantize to reduce noise
                let qh = (h * 12).rounded() / 12
                let qs = (s * 4).rounded() / 4
                let qb = (br * 4).rounded() / 4

                let quantized = HSBColor(hue: qh, saturation: qs, brightness: qb)
                colorCounts[quantized, default: 0] += 1
            }
        }

        // Sort by frequency
        let sorted = colorCounts.sorted { $0.value > $1.value }
        guard !sorted.isEmpty else { return nil }

        // Dominant = most frequent saturated color
        let dominantHSB = sorted.first(where: { $0.key.saturation > 0.15 })?.key ?? sorted[0].key
        let dominant = NSColor(hue: dominantHSB.hue, saturation: min(dominantHSB.saturation * 1.2, 1.0),
                              brightness: max(dominantHSB.brightness, 0.6), alpha: 1.0)

        // Accent = most frequent color that's visually distinct from dominant
        let accentHSB = sorted.first(where: {
            let hueDiff = abs($0.key.hue - dominantHSB.hue)
            let minHueDiff = min(hueDiff, 1.0 - hueDiff)
            return minHueDiff > 0.15 && $0.key.saturation > 0.1
        })?.key ?? dominantHSB

        let accent = NSColor(hue: accentHSB.hue, saturation: min(accentHSB.saturation * 1.1, 1.0),
                            brightness: max(accentHSB.brightness, 0.5), alpha: 1.0)

        // Background = darkest frequent color
        let bgHSB = sorted.first(where: { $0.key.brightness < 0.4 })?.key
            ?? HSBColor(hue: dominantHSB.hue, saturation: 0.3, brightness: 0.15)
        let background = NSColor(hue: bgHSB.hue, saturation: bgHSB.saturation * 0.5,
                                brightness: bgHSB.brightness, alpha: 1.0)

        // Determine if the image is predominantly light
        let avgBrightness = sorted.prefix(5).reduce(0.0) {
            $0 + $1.key.brightness * CGFloat($1.value)
        } / CGFloat(sorted.prefix(5).reduce(0) { $0 + $1.value })

        return ColorPalette(
            dominant: dominant,
            accent: accent,
            background: background,
            isLight: avgBrightness > 0.6
        )
    }

    // MARK: - Text Recognition

    /// Recognize text embedded in album art using VNRecognizeTextRequest.
    private nonisolated static func recognizeText(in cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let texts = results.compactMap { observation -> String? in
                    guard observation.confidence > 0.5 else { return nil }
                    return observation.topCandidates(1).first?.string
                }
                continuation.resume(returning: texts)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Saliency Detection

    /// Detect the most salient point in the image using VNGenerateAttentionBasedSaliencyImageRequest.
    private nonisolated static func detectSaliency(in cgImage: CGImage) async -> CGPoint? {
        await withCheckedContinuation { continuation in
            let request = VNGenerateAttentionBasedSaliencyImageRequest { request, error in
                guard let results = request.results as? [VNSaliencyImageObservation],
                      let saliency = results.first,
                      let salientObject = saliency.salientObjects?.first else {
                    continuation.resume(returning: nil)
                    return
                }

                let box = salientObject.boundingBox
                let center = CGPoint(x: box.midX, y: box.midY)
                continuation.resume(returning: center)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - SpotifyLyricsCore/Analysis/VocalActivityDetector.swift

/// Detects vocal activity (singing vs instrumental) in audio segments
/// and classifies lyrics language using CreateML / NaturalLanguage frameworks.
///
/// Two capabilities:
/// 1. **Vocal Activity Detection**: Analyzes audio energy to detect when singing
///    occurs, helping the alignment pipeline skip instrumental sections.
/// 2. **Lyrics Language Classification**: Uses NLLanguageRecognizer with custom
///    hints tuned for song lyrics (handles slang, romanized text, mixed language).
@MainActor
public final class VocalActivityDetector: ObservableObject {

    /// Whether a given time window contains vocal activity.
    public struct VocalSegment: Equatable {
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let isVocal: Bool
        public let energy: Float

        public init(startTime: TimeInterval, endTime: TimeInterval, isVocal: Bool, energy: Float) {
            self.startTime = startTime
            self.endTime = endTime
            self.isVocal = isVocal
            self.energy = energy
        }
    }

    /// Language classification result for lyrics.
    public struct LyricsLanguageResult: Equatable {
        public let language: String
        public let confidence: Double
        public let script: String

        public init(language: String, confidence: Double, script: String) {
            self.language = language
            self.confidence = confidence
            self.script = script
        }
    }

    @Published public private(set) var vocalSegments: [VocalSegment] = []
    @Published public private(set) var languageResult: LyricsLanguageResult?
    @Published public private(set) var vocalRatio: Double = 0.0

    /// Energy threshold for vocal detection.
    /// Audio energy above this level in speech-frequency bands indicates vocals.
    private let energyThreshold: Float = 0.02
    /// Minimum segment duration in seconds.
    private let segmentDuration: TimeInterval = 0.5

    public init() {}

    // MARK: - Vocal Activity Detection

    /// Analyze an audio buffer to detect vocal segments.
    ///
    /// Uses spectral energy analysis: vocals concentrate energy in 300Hz-3kHz range.
    /// Compares mid-band energy to full-band energy ratio to distinguish vocals
    /// from instruments.
    ///
    /// - Parameters:
    ///   - audioBuffer: 16kHz mono Float32 samples
    ///   - captureStartPosition: Song time at buffer start
    /// - Returns: Array of vocal segments
    public func detectVocalActivity(
        in audioBuffer: [Float],
        captureStartPosition: TimeInterval
    ) -> [VocalSegment] {
        let sampleRate: Double = 16000
        let samplesPerSegment = Int(segmentDuration * sampleRate)
        guard audioBuffer.count >= samplesPerSegment else { return [] }

        var segments: [VocalSegment] = []
        let totalSegments = audioBuffer.count / samplesPerSegment

        for i in 0..<totalSegments {
            let start = i * samplesPerSegment
            let end = min(start + samplesPerSegment, audioBuffer.count)
            let window = Array(audioBuffer[start..<end])

            let energy = computeRMSEnergy(window)
            let spectralCentroid = computeSpectralCentroid(window, sampleRate: sampleRate)
            let zeroCrossingRate = computeZeroCrossingRate(window)

            // Vocal detection heuristic:
            // - Vocals have energy concentrated in 300Hz-3kHz (spectral centroid in this range)
            // - Vocals have moderate zero-crossing rate (not too high like noise, not too low like bass)
            // - Energy must be above threshold
            let isVocal = energy > energyThreshold
                && spectralCentroid > 300 && spectralCentroid < 4000
                && zeroCrossingRate > 0.02 && zeroCrossingRate < 0.3

            let segStartTime = captureStartPosition + Double(start) / sampleRate
            let segEndTime = captureStartPosition + Double(end) / sampleRate

            segments.append(VocalSegment(
                startTime: segStartTime,
                endTime: segEndTime,
                isVocal: isVocal,
                energy: energy
            ))
        }

        vocalSegments = segments

        // Compute vocal ratio
        let vocalCount = segments.filter(\.isVocal).count
        vocalRatio = segments.isEmpty ? 0 : Double(vocalCount) / Double(segments.count)

        return segments
    }

    /// Check if a specific time range contains vocal activity.
    public func isVocalAt(time: TimeInterval) -> Bool {
        vocalSegments.first(where: { time >= $0.startTime && time < $0.endTime })?.isVocal ?? false
    }

    /// Get vocal segments within a time range (useful for per-line alignment decisions).
    public func vocalSegments(from startTime: TimeInterval, to endTime: TimeInterval) -> [VocalSegment] {
        vocalSegments.filter { $0.endTime > startTime && $0.startTime < endTime }
    }

    // MARK: - Lyrics Language Classification

    /// Classify the language of lyrics text using NaturalLanguage with lyrics-aware tuning.
    ///
    /// Better than raw NLLanguageRecognizer for song lyrics because it:
    /// - Handles romanized text (e.g. "watashi wa" → Japanese)
    /// - Handles mixed-language lines
    /// - Recognizes slang and informal contractions
    public func classifyLyricsLanguage(_ lines: [String]) -> LyricsLanguageResult {
        let recognizer = NLLanguageRecognizer()

        // Provide language hints weighted for common lyrics languages
        recognizer.languageHints = [
            .english: 0.2,
            .japanese: 0.15,
            .korean: 0.15,
            .simplifiedChinese: 0.1,
            .spanish: 0.1,
            .indonesian: 0.1,
            .french: 0.05,
            .german: 0.05,
            .portuguese: 0.05,
            .thai: 0.025,
            .arabic: 0.025,
        ]

        // Combine all lines for overall language detection
        let fullText = lines.joined(separator: "\n")
        recognizer.processString(fullText)

        guard let dominantLanguage = recognizer.dominantLanguage else {
            let result = LyricsLanguageResult(language: "und", confidence: 0, script: "unknown")
            languageResult = result
            return result
        }

        // Get confidence for dominant language
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let confidence = hypotheses[dominantLanguage] ?? 0

        // Detect script type
        let script = detectScript(fullText)

        let result = LyricsLanguageResult(
            language: dominantLanguage.rawValue,
            confidence: confidence,
            script: script
        )
        languageResult = result
        return result
    }

    /// Classify language per line, useful for mixed-language songs.
    public func classifyPerLine(_ lines: [String]) -> [LyricsLanguageResult] {
        lines.map { classifyLyricsLanguage([$0]) }
    }

    // MARK: - Audio Feature Computation

    /// Root mean square energy of a signal window.
    private func computeRMSEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    /// Spectral centroid — the "center of mass" of the frequency spectrum.
    /// Higher values indicate brighter/higher-pitched content (vocals).
    private func computeSpectralCentroid(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count >= 2 else { return 0 }

        // Simple DFT magnitude spectrum (first half)
        let n = samples.count
        let halfN = n / 2
        var magnitudes = [Double](repeating: 0, count: halfN)
        var totalMagnitude: Double = 0

        for k in 0..<halfN {
            var real: Double = 0
            var imag: Double = 0
            for i in 0..<n {
                let angle = 2.0 * Double.pi * Double(k) * Double(i) / Double(n)
                real += Double(samples[i]) * cos(angle)
                imag += Double(samples[i]) * sin(angle)
            }
            magnitudes[k] = sqrt(real * real + imag * imag)
            totalMagnitude += magnitudes[k]
        }

        guard totalMagnitude > 0 else { return 0 }

        // Weighted average frequency
        var centroid: Double = 0
        for k in 0..<halfN {
            let freq = Double(k) * sampleRate / Double(n)
            centroid += freq * magnitudes[k]
        }
        return centroid / totalMagnitude
    }

    /// Zero-crossing rate — how often the signal changes sign.
    /// Moderate values indicate voiced speech/singing.
    private func computeZeroCrossingRate(_ samples: [Float]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0) != (samples[i-1] >= 0) {
                crossings += 1
            }
        }
        return Double(crossings) / Double(samples.count - 1)
    }

    // MARK: - Script Detection

    private func detectScript(_ text: String) -> String {
        var scriptCounts: [String: Int] = [:]

        for scalar in text.unicodeScalars {
            let script: String
            switch scalar.value {
            case 0x3040...0x309F: script = "hiragana"
            case 0x30A0...0x30FF: script = "katakana"
            case 0x4E00...0x9FFF: script = "cjk"
            case 0xAC00...0xD7AF: script = "hangul"
            case 0x0041...0x007A: script = "latin"
            case 0x0600...0x06FF: script = "arabic"
            case 0x0900...0x097F: script = "devanagari"
            case 0x0E00...0x0E7F: script = "thai"
            case 0x0400...0x04FF: script = "cyrillic"
            default: continue
            }
            scriptCounts[script, default: 0] += 1
        }

        return scriptCounts.max(by: { $0.value < $1.value })?.key ?? "unknown"
    }
}

// MARK: - SpotifyLyricsCore/Spotify/AccessibilityBridge.swift

/// Reads Spotify's UI state via macOS Accessibility APIs (AXUIElement).
///
/// Faster than AppleScript polling (~1-5ms vs ~50-200ms) and can access
/// UI elements not exposed via AppleScript, such as:
/// - Now Playing bar text (song title, artist, album)
/// - Playback progress bar position
/// - Like/dislike button state
/// - Queue visibility
///
/// Requires Accessibility permission (System Settings > Privacy > Accessibility).
public final class AccessibilityBridge: @unchecked Sendable {

    /// Playback info extracted from Spotify's Accessibility tree.
    public struct AXPlaybackInfo: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let isPlaying: Bool?
        public let progress: Double?  // 0..1 normalized progress
        public let isLiked: Bool

        public init(title: String, artist: String, isPlaying: Bool?, progress: Double?, isLiked: Bool) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.progress = progress
            self.isLiked = isLiked
        }
    }

    public init() {}

    // MARK: - Permission

    /// Check if Accessibility access is granted.
    public static var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission if not granted.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Spotify App Reference

    /// Find the Spotify process and return its AXUIElement.
    private func spotifyApp() -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.spotify.client"
        }
        guard let spotify = apps.first else { return nil }
        return AXUIElementCreateApplication(spotify.processIdentifier)
    }

    // MARK: - Read Playback Info

    /// Read the current playback info from Spotify's Accessibility tree.
    /// Returns nil if Spotify isn't running or Accessibility isn't enabled.
    public func getPlaybackInfo() -> AXPlaybackInfo? {
        guard Self.isAccessibilityEnabled else { return nil }
        guard let app = spotifyApp() else { return nil }

        // Get all windows
        guard let windows = getAttribute(app, attribute: kAXWindowsAttribute) as? [AXUIElement],
              let mainWindow = windows.first else {
            return nil
        }

        // Traverse the UI tree to find Now Playing elements
        var title = ""
        var artist = ""
        var isPlaying: Bool?
        var progress: Double?
        var isLiked = false

        // Search for relevant UI elements in the window
        traverseTree(mainWindow) { element, role, elementTitle, elementValue in
            let roleStr = role as String? ?? ""
            let titleStr = elementTitle as String? ?? ""
            let valueStr = elementValue as? String ?? ""

            // Detect play/pause button
            if roleStr == "AXButton" {
                let desc = (getAttribute(element, attribute: kAXDescriptionAttribute) as? String) ?? ""
                if let inferredState = Self.inferPlaybackState(buttonDescription: desc, title: titleStr) {
                    isPlaying = inferredState
                }

                // Like button
                if titleStr.lowercased().contains("save") || desc.lowercased().contains("like") {
                    let pressed = getAttribute(element, attribute: kAXValueAttribute) as? Int
                    isLiked = pressed == 1
                }
            }

            // Detect slider (progress bar)
            if roleStr == "AXSlider" {
                if let value = getAttribute(element, attribute: kAXValueAttribute) as? Double {
                    // Spotify's progress slider typically has value 0-100
                    if value >= 0 && value <= 100 {
                        progress = value / 100.0
                    }
                }
            }

            // Detect static text elements in the Now Playing area
            if roleStr == "AXStaticText" || roleStr == "AXLink" {
                if !valueStr.isEmpty {
                    // Heuristic: first text element is title, second is artist
                    if title.isEmpty {
                        title = valueStr
                    } else if artist.isEmpty && valueStr != title {
                        artist = valueStr
                    }
                } else if !titleStr.isEmpty {
                    if title.isEmpty {
                        title = titleStr
                    } else if artist.isEmpty && titleStr != title {
                        artist = titleStr
                    }
                }
            }

            return true // continue traversal
        }

        guard !title.isEmpty else { return nil }

        return AXPlaybackInfo(
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            progress: progress,
            isLiked: isLiked
        )
    }

    static func inferPlaybackState(buttonDescription: String?, title: String?) -> Bool? {
        for rawText in [buttonDescription, title] {
            let text = (rawText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if text == "pause" || text.hasPrefix("pause ") {
                return true
            }
            if text == "play" {
                return false
            }
        }
        return nil
    }

    /// Read the focused element description (useful for debugging the AX tree).
    public func getFocusedElementInfo() -> String? {
        guard let app = spotifyApp() else { return nil }
        guard let focusedObj = getAttribute(app, attribute: kAXFocusedUIElementAttribute) else {
            return nil
        }
        // AXUIElement is a CFTypeRef, bridge via unsafeBitCast
        let focused: AXUIElement = unsafeBitCast(focusedObj, to: AXUIElement.self)

        let role = getAttribute(focused, attribute: kAXRoleAttribute) as? String ?? "unknown"
        let title = getAttribute(focused, attribute: kAXTitleAttribute) as? String ?? ""
        let value = getAttribute(focused, attribute: kAXValueAttribute)
        return "Role: \(role), Title: \(title), Value: \(String(describing: value))"
    }

    // MARK: - Window Info

    /// Get Spotify's main window position and size.
    public func getWindowFrame() -> NSRect? {
        guard let app = spotifyApp() else { return nil }
        guard let windows = getAttribute(app, attribute: kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first else { return nil }

        guard let position = getPointAttribute(window, attribute: kAXPositionAttribute),
              let size = getSizeAttribute(window, attribute: kAXSizeAttribute) else {
            return nil
        }

        return NSRect(origin: position, size: size)
    }

    // MARK: - AX Helpers

    private func getAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func getPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = getAttribute(element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private func getSizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = getAttribute(element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    /// Traverse the Accessibility tree depth-first.
    /// The visitor receives each element with its role, title, and value.
    /// Return false from the visitor to stop traversal.
    private func traverseTree(
        _ element: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 10,
        visitor: (AXUIElement, CFString?, CFString?, AnyObject?) -> Bool
    ) {
        guard depth < maxDepth else { return }

        let role = getAttribute(element, attribute: kAXRoleAttribute).flatMap { $0 as? NSString } as CFString?
        let titleAttr = getAttribute(element, attribute: kAXTitleAttribute).flatMap { $0 as? NSString } as CFString?
        let value = getAttribute(element, attribute: kAXValueAttribute)

        guard visitor(element, role, titleAttr, value) else { return }

        // Traverse children
        guard let children = getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }

        for child in children {
            traverseTree(child, depth: depth + 1, maxDepth: maxDepth, visitor: visitor)
        }
    }
}

// MARK: - SpotifyLyricsCore/Spotify/AppleScriptBridge.swift

/// Stateless bridge to Spotify via AppleScript. Holds no mutable state, so it is safe to
/// invoke from any thread — callers run `getPlaybackInfo()` off the main thread to avoid
/// blocking SwiftUI rendering while the (slow) Apple-event round-trip completes.
public final class AppleScriptBridge: @unchecked Sendable {
    public enum PlayerState: String, Sendable {
        case playing, paused, stopped, unknown
    }

    public struct PlaybackInfo: Sendable {
        public let track: TrackInfo
        public let state: PlayerState
        public let position: TimeInterval
        public let artworkURLString: String?
        public let isShuffling: Bool
        public let isRepeating: Bool

        public init(track: TrackInfo, state: PlayerState, position: TimeInterval,
                     artworkURLString: String? = nil, isShuffling: Bool = false, isRepeating: Bool = false) {
            self.track = track
            self.state = state
            self.position = position
            self.artworkURLString = artworkURLString
            self.isShuffling = isShuffling
            self.isRepeating = isRepeating
        }
    }

    public init() {}

    /// Cheap, in-process check (no Apple event) for whether Spotify is running.
    public static var isSpotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.spotify.client"
        }
    }

    public func getPlaybackInfo() -> PlaybackInfo? {
        // Skip the AppleScript entirely when Spotify isn't running. This avoids both the
        // Apple-event round-trip and any chance of launching Spotify, and is essentially free
        // compared to the old `tell System Events ... exists process` probe.
        guard Self.isSpotifyRunning else { return nil }

        // Single combined script reads everything in one round-trip.
        let script = """
        tell application "Spotify"
            if player state is stopped then
                return "stopped|||||||0|||0"
            end if
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set playerPos to player position
            set pState to player state as string
            set artUrl to artwork url of current track
            set shuf to shuffling
            set rep to repeating
            return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (trackDuration / 1000) & "|||" & playerPos & "|||" & pState & "|||" & artUrl & "|||" & shuf & "|||" & rep
        end tell
        """

        guard let result = runAppleScript(script) else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleScript coerces numbers using system locale — comma decimal separators
        // (e.g. "120,5" instead of "120.5") cause TimeInterval() to return nil.
        let duration = Self.parseNumber(parts[3])
        let position = Self.parseNumber(parts[4])
        let stateStr = parts[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if stateStr == "stopped" && title.isEmpty {
            return PlaybackInfo(
                track: TrackInfo(title: "", artist: "", album: "", duration: 0),
                state: .stopped,
                position: 0
            )
        }

        let state: PlayerState = switch stateStr {
        case "playing", "kpsplaying": .playing
        case "paused", "kpsppaused": .paused
        case "stopped", "kpspstopped": .stopped
        default: .unknown
        }

        var artworkURLString: String? = nil
        var isShuffling = false
        var isRepeating = false

        if parts.count >= 7 {
            let url = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { artworkURLString = url }
        }
        if parts.count >= 8 {
            isShuffling = parts[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        }
        if parts.count >= 9 {
            isRepeating = parts[8].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        }

        return PlaybackInfo(
            track: TrackInfo(title: title, artist: artist, album: album, duration: duration),
            state: state,
            position: position,
            artworkURLString: artworkURLString,
            isShuffling: isShuffling,
            isRepeating: isRepeating
        )
    }

    public func playPause() {
        _ = runAppleScript("tell application \"Spotify\" to playpause")
    }

    public func nextTrack() {
        _ = runAppleScript("tell application \"Spotify\" to next track")
    }

    public func previousTrack() {
        _ = runAppleScript("tell application \"Spotify\" to previous track")
    }

    public func setShuffling(_ enabled: Bool) {
        _ = runAppleScript("tell application \"Spotify\" to set shuffling to \(enabled)")
    }

    public func setRepeating(_ enabled: Bool) {
        _ = runAppleScript("tell application \"Spotify\" to set repeating to \(enabled)")
    }

    public func seekTo(_ position: TimeInterval) {
        let script = """
        tell application "Spotify"
            set player position to \(position)
        end tell
        """
        _ = runAppleScript(script)
    }

    public static func parseNumber(_ raw: String) -> TimeInterval {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return TimeInterval(cleaned) ?? 0
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}

// MARK: - SpotifyLyricsCore/Spotify/SpotifyPlayerManager.swift

@MainActor
public final class SpotifyPlayerManager: ObservableObject {
    @Published public var currentTrack: TrackInfo?
    @Published public var playerState: AppleScriptBridge.PlayerState = .stopped
    @Published public var isSpotifyRunning = false
    @Published public var isShuffling = false
    @Published public var isRepeating = false
    @Published public var artworkURL: URL?
    @Published public var isLiked: Bool = false

    private let bridge = AppleScriptBridge()
    private let accessibilityBridge = AccessibilityBridge()
    private var pollTimer: Timer?
    private var axPollTimer: Timer?
    private var lastTrackKey: String?

    // MARK: - Poll Scheduling

    /// True while a background AppleScript read is in flight — prevents overlapping
    /// (and therefore contending) Apple-event round-trips if one runs long.
    private var isAppleScriptPolling = false
    /// True while a background Accessibility read is in flight.
    private var isAXPolling = false
    /// Counts skipped AppleScript ticks while idle (paused/stopped) so we can back the
    /// expensive poll off to ~1.2s instead of running it 3×/sec for no benefit.
    private var idlePollTicks = 0
    /// Set by the fast AX poll on a play-state transition to force the next AppleScript
    /// poll to run immediately (so resume refreshes position/track without backoff lag).
    private var forceFullPoll = false

    // MARK: - Interpolation State

    private var lastPolledPosition: TimeInterval = 0
    private var lastPollTime: CFAbsoluteTime = 0

    // MARK: - Drift Correction

    /// Accumulated drift correction factor. Positive = interpolation runs ahead.
    /// Applied as: correctedPosition = interpolatedPosition - driftOffset
    private var driftOffset: TimeInterval = 0

    /// Smoothing factor for exponential moving average of drift measurements.
    private let driftAlpha: Double = 0.3


    /// Returns the interpolated playback position with drift correction.
    public var playbackPosition: TimeInterval {
        guard playerState == .playing else { return lastPolledPosition }
        let elapsed = CFAbsoluteTimeGetCurrent() - lastPollTime
        return lastPolledPosition + elapsed - driftOffset
    }

    public var onTrackChanged: ((TrackInfo) -> Void)?

    // MARK: - Predictive Line Switching

    /// Timer for precise next-line switching.
    private var nextLineTimer: Timer?
    /// Timestamp the live `nextLineTimer` is scheduled for, so repeated calls with the same
    /// target don't tear down and rebuild the timer on every position tick.
    private var scheduledNextLineTimestamp: TimeInterval?
    /// Callback invoked when the predictive timer fires at the next line's timestamp.
    public var onPredictiveLineSwitch: ((TimeInterval) -> Void)?

    public init() {}

    // MARK: - Polling

    public func startPolling() {
        pollTimer?.invalidate()
        // Primary AppleScript poll every 300ms
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        poll()

        // Supplementary Accessibility poll every 200ms for fast play/pause + like detection.
        // The full AX-tree traversal is comparatively expensive (many IPC calls), so it runs
        // on a background thread and at a lower rate than position interpolation needs.
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityPoll()
            }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        axPollTimer?.invalidate()
        axPollTimer = nil
        nextLineTimer?.invalidate()
        nextLineTimer = nil
        scheduledNextLineTimestamp = nil
    }

    /// Fast supplementary poll using Accessibility APIs. The (relatively expensive) AX-tree
    /// traversal runs on a background thread so it never blocks SwiftUI rendering; results are
    /// applied back on the main actor.
    private func accessibilityPoll() {
        guard AccessibilityBridge.isAccessibilityEnabled, !isAXPolling else { return }
        isAXPolling = true
        let axBridge = accessibilityBridge
        Task.detached(priority: .userInitiated) { [weak self] in
            let info = axBridge.getPlaybackInfo()
            await self?.applyAXPoll(info)
        }
    }

    func applyAXPoll(_ info: AccessibilityBridge.AXPlaybackInfo?) {
        isAXPolling = false
        guard let info else { return }

        // Guard every @Published assignment: `@Published` fires objectWillChange on *every*
        // set (even when the value is unchanged), so an unconditional assignment here would
        // rebuild the entire SwiftUI overlay several×/sec and make animations feel laggy.
        if isLiked != info.isLiked { isLiked = info.isLiked }

        if let isPlaying = info.isPlaying {
            let newState: AppleScriptBridge.PlayerState = isPlaying ? .playing : .paused
            if newState != playerState {
                playerState = newState
                // A state change (e.g. resume) should refresh the authoritative AppleScript read
                // promptly even if we're currently in idle backoff.
                forceFullPoll = true
            }
        }
        // Do not use AX slider progress to correct playbackPosition: Spotify exposes other
        // sliders in the same tree, so AppleScript remains the authoritative position source.
    }

    private func poll() {
        guard !isAppleScriptPolling else { return }

        // Idle backoff: while paused/stopped the position doesn't advance and the track
        // rarely changes, so the expensive AppleScript read can run far less often. The AX
        // poll flips `forceFullPoll` on resume so we never lag a real state change.
        if playerState != .playing && !forceFullPoll {
            idlePollTicks += 1
            if idlePollTicks < 4 { return }   // run ~every 1.2s while idle
        }
        idlePollTicks = 0
        forceFullPoll = false

        isAppleScriptPolling = true
        let bridge = self.bridge
        Task.detached(priority: .userInitiated) { [weak self] in
            let pollStart = CFAbsoluteTimeGetCurrent()
            let info = bridge.getPlaybackInfo()
            let pollEnd = CFAbsoluteTimeGetCurrent()
            await self?.applyPoll(info, pollStart: pollStart, pollEnd: pollEnd)
        }
    }

    private func applyPoll(_ info: AppleScriptBridge.PlaybackInfo?, pollStart: CFAbsoluteTime, pollEnd: CFAbsoluteTime) {
        isAppleScriptPolling = false

        guard let info else {
            if isSpotifyRunning { isSpotifyRunning = false }
            if currentTrack != nil { currentTrack = nil }
            if playerState != .stopped { playerState = .stopped }
            lastPolledPosition = 0
            lastTrackKey = nil
            driftOffset = 0
            return
        }

        let pollMid = (pollStart + pollEnd) / 2

        // Drift correction: compare what we predicted vs what Spotify reports
        if playerState == .playing && lastPollTime > 0 {
            let predicted = lastPolledPosition + (pollMid - lastPollTime) - driftOffset
            let actual = info.position
            let error = predicted - actual

            // Only apply drift correction for reasonable errors (< 2s).
            // Larger jumps indicate seeks or track changes.
            if abs(error) < 2.0 {
                driftOffset = driftOffset * (1 - driftAlpha) + error * driftAlpha
            } else {
                // Large jump — reset drift
                driftOffset = 0
            }
        }

        // Only assign @Published properties when they actually change — see applyAXPoll().
        if !isSpotifyRunning { isSpotifyRunning = true }
        if playerState != info.state { playerState = info.state }
        if isShuffling != info.isShuffling { isShuffling = info.isShuffling }
        if isRepeating != info.isRepeating { isRepeating = info.isRepeating }
        lastPolledPosition = info.position
        lastPollTime = pollMid

        let newKey = info.track.cacheKey
        if newKey != lastTrackKey && !info.track.title.isEmpty {
            lastTrackKey = newKey
            currentTrack = info.track
            driftOffset = 0  // Reset drift on track change
            if let urlStr = info.artworkURLString, let url = URL(string: urlStr) {
                artworkURL = url
            } else {
                artworkURL = nil
            }
            onTrackChanged?(info.track)
        }
    }

    // MARK: - Predictive Line Switching

    /// Schedule a precise timer to fire at the next lyric line's timestamp.
    /// Much more accurate than polling at fixed intervals — fires exactly when needed.
    ///
    /// - Parameter nextLineTimestamp: The absolute song timestamp of the next line.
    public func scheduleNextLineSwitch(at nextLineTimestamp: TimeInterval) {
        // The position timer calls this several×/sec with the same target; only (re)build the
        // timer when the target actually changes, otherwise we churn a Timer continuously.
        if scheduledNextLineTimestamp == nextLineTimestamp && nextLineTimer != nil { return }

        nextLineTimer?.invalidate()
        nextLineTimer = nil
        scheduledNextLineTimestamp = nil

        guard playerState == .playing else { return }

        let delay = nextLineTimestamp - playbackPosition
        guard delay > 0 && delay < 30 else { return }

        scheduledNextLineTimestamp = nextLineTimestamp
        nextLineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nextLineTimer = nil
                self.scheduledNextLineTimestamp = nil
                self.onPredictiveLineSwitch?(self.playbackPosition)
            }
        }
    }

    // MARK: - Controls

    public func seekTo(_ position: TimeInterval) {
        bridge.seekTo(position)
        lastPolledPosition = position
        lastPollTime = CFAbsoluteTimeGetCurrent()
        driftOffset = 0
        nextLineTimer?.invalidate()
        nextLineTimer = nil
        scheduledNextLineTimestamp = nil
    }

    public func playPause() {
        bridge.playPause()
        playerState = (playerState == .playing) ? .paused : .playing
        if playerState == .paused {
            nextLineTimer?.invalidate()
            nextLineTimer = nil
            scheduledNextLineTimestamp = nil
        }
    }

    public func nextTrack() {
        bridge.nextTrack()
    }

    public func previousTrack() {
        bridge.previousTrack()
    }

    public func toggleShuffle() {
        let newValue = !isShuffling
        bridge.setShuffling(newValue)
        isShuffling = newValue
    }

    public func toggleRepeat() {
        let newValue = !isRepeating
        bridge.setRepeating(newValue)
        isRepeating = newValue
    }

    /// Test helper: directly set interpolation state without polling Spotify.
    public func setInterpolationState(position: TimeInterval, pollTime: CFAbsoluteTime) {
        lastPolledPosition = position
        lastPollTime = pollTime
        driftOffset = 0
    }

    deinit {
        pollTimer?.invalidate()
        axPollTimer?.invalidate()
        nextLineTimer?.invalidate()
    }
}

// MARK: - SpotifyLyricsCore/Controls/MusicControlsView.swift

public enum ControlsStyle {
    case compact
    case full
}

private struct HoverableCircleButton: View {
    let size: CGFloat
    let isPressed: Bool
    let label: AnyView

    @State private var isHovered = false

    var body: some View {
        label
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(
                Circle().fill(.white.opacity(isHovered ? 0.15 : 0.001))
            )
            .scaleEffect(isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct ControlButtonStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HoverableCircleButton(
            size: size,
            isPressed: configuration.isPressed,
            label: AnyView(configuration.label)
        )
    }
}

private struct HoverablePillButton: View {
    let isPressed: Bool
    let label: AnyView

    @State private var isHovered = false

    var body: some View {
        label
            .background(
                Capsule().fill(.white.opacity(isHovered ? 0.1 : 0))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .opacity(isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverablePillButton(
            isPressed: configuration.isPressed,
            label: AnyView(configuration.label)
        )
    }
}

public struct MusicControlsView: View {
    @ObservedObject var playerManager: SpotifyPlayerManager

    let style: ControlsStyle
    let tint: Color

    public init(playerManager: SpotifyPlayerManager, style: ControlsStyle = .full, tint: Color = .white) {
        self.playerManager = playerManager
        self.style = style
        self.tint = tint
    }

    private var iconSize: CGFloat {
        style == .compact ? 14 : 18
    }

    private var playPauseSize: CGFloat {
        style == .compact ? 20 : 26
    }

    private var spacing: CGFloat {
        style == .compact ? 12 : 16
    }

    private var hitSize: CGFloat {
        style == .compact ? 30 : 36
    }

    public var body: some View {
        HStack(spacing: spacing) {
            // Shuffle
            Button { playerManager.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(playerManager.isShuffling ? .green : tint.opacity(0.7))
            }
            .buttonStyle(ControlButtonStyle(size: hitSize))

            // Previous
            Button { playerManager.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(tint)
            }
            .buttonStyle(ControlButtonStyle(size: hitSize))

            // Play / Pause
            Button { playerManager.playPause() } label: {
                Image(systemName: playerManager.playerState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: playPauseSize, weight: .medium))
                    .foregroundStyle(tint)
            }
            .buttonStyle(ControlButtonStyle(size: hitSize + 4))

            // Next
            Button { playerManager.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(tint)
            }
            .buttonStyle(ControlButtonStyle(size: hitSize))

            // Repeat
            Button { playerManager.toggleRepeat() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(playerManager.isRepeating ? .green : tint.opacity(0.7))
            }
            .buttonStyle(ControlButtonStyle(size: hitSize))
        }
    }
}

// MARK: - SpotifyLyricsCore/Controls/SeekBarView.swift

public struct SeekBarView: View {
    @ObservedObject var playerManager: SpotifyPlayerManager

    let tint: Color
    let showTotalDuration: Bool

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    public init(playerManager: SpotifyPlayerManager, tint: Color = .white, showTotalDuration: Bool = false) {
        self.playerManager = playerManager
        self.tint = tint
        self.showTotalDuration = showTotalDuration
    }

    private var duration: TimeInterval {
        playerManager.currentTrack?.duration ?? 0
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            content
        }
    }

    private var content: some View {
        let position = isDragging ? dragProgress * duration : playerManager.playbackPosition
        let progress = duration > 0 ? (isDragging ? dragProgress : playerManager.playbackPosition / duration) : 0

        return VStack(spacing: 4) {
            // Track bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(tint.opacity(0.2))
                        .frame(height: 4)

                    // Filled track
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(0, geo.size.width * min(1, progress)), height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragProgress = max(0, min(1, value.location.x / geo.size.width))
                        }
                        .onEnded { value in
                            let finalProgress = max(0, min(1, value.location.x / geo.size.width))
                            let seekPosition = finalProgress * duration
                            playerManager.seekTo(seekPosition)
                            isDragging = false
                        }
                )
            }
            .frame(height: 20)

            // Time labels
            HStack {
                Text(formatTime(position))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.7))
                Spacer()
                Text(showTotalDuration ? formatTime(duration) : "-\(formatTime(max(0, duration - position)))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - SpotifyLyricsCore/Sharing/LyricsCardGenerator.swift

/// Generates shareable lyrics card images using offscreen rendering.
@MainActor
public final class LyricsCardGenerator {

    public enum CardSize {
        case square     // 1080x1080
        case landscape  // 1920x1080

        public var dimensions: CGSize {
            switch self {
            case .square:    return CGSize(width: 1080, height: 1080)
            case .landscape: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    public init() {}

    /// Generate a lyrics card as an NSImage.
    public func generateCard(
        line: LyricLine,
        enrichment: LineEnrichment?,
        title: String,
        artist: String,
        artworkImage: NSImage? = nil,
        accentColor: Color = .white,
        cardSize: CardSize = .square
    ) -> NSImage {
        let size = cardSize.dimensions
        let view = LyricsCardView(
            lineText: line.text,
            romanization: enrichment?.romanization,
            translation: enrichment?.translation,
            title: title,
            artist: artist,
            artworkImage: artworkImage,
            accentColor: accentColor,
            size: size
        )

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0 // Retina
        renderer.proposedSize = .init(width: size.width, height: size.height)

        if let cgImage = renderer.cgImage {
            return NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height))
        }

        // Fallback: return a blank image
        return NSImage(size: NSSize(width: size.width, height: size.height))
    }

    /// Copy the generated card to the system clipboard.
    public func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// Save the generated card as a PNG file.
    public func saveAsPNG(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CardGeneratorError.renderFailed
        }
        try pngData.write(to: url)
    }

    public enum CardGeneratorError: Error {
        case renderFailed
    }
}

// MARK: - SpotifyLyricsCore/Sharing/LyricsCardView.swift

/// SwiftUI template for a shareable lyrics card image.
/// Renders a single lyric line over a blurred album art background
/// with optional enrichment text and artist credit.
public struct LyricsCardView: View {
    public let lineText: String
    public let romanization: String?
    public let translation: String?
    public let title: String
    public let artist: String
    public let artworkImage: NSImage?
    public let accentColor: Color
    public let size: CGSize

    public init(
        lineText: String,
        romanization: String? = nil,
        translation: String? = nil,
        title: String,
        artist: String,
        artworkImage: NSImage? = nil,
        accentColor: Color = .white,
        size: CGSize = CGSize(width: 1080, height: 1080)
    ) {
        self.lineText = lineText
        self.romanization = romanization
        self.translation = translation
        self.title = title
        self.artist = artist
        self.artworkImage = artworkImage
        self.accentColor = accentColor
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Background
            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 30)
                    .scaleEffect(1.3)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.15), Color(white: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // Dark overlay
            Color.black.opacity(0.45)

            // Content
            VStack(spacing: 0) {
                Spacer()

                // Accent quote mark
                Text("\u{201C}")
                    .font(.system(size: 72, weight: .bold, design: .serif))
                    .foregroundStyle(accentColor.opacity(0.5))
                    .padding(.bottom, -20)

                // Romanization (above main text)
                if let romanization {
                    Text(romanization)
                        .font(.system(size: fontSize * 0.55, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 8)
                }

                // Main lyric text
                Text(lineText)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
                    .padding(.horizontal, horizontalPadding)

                // Translation (below main text)
                if let translation {
                    Text(translation)
                        .font(.system(size: fontSize * 0.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .italic()
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 12)
                }

                Spacer()

                // Credit line
                HStack(spacing: 4) {
                    Text("\(title)")
                        .fontWeight(.semibold)
                    Text("—")
                    Text(artist)
                }
                .font(.system(size: creditFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .padding(.bottom, bottomPadding)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var fontSize: CGFloat { size.width * 0.045 }
    private var creditFontSize: CGFloat { size.width * 0.018 }
    private var horizontalPadding: CGFloat { size.width * 0.1 }
    private var bottomPadding: CGFloat { size.height * 0.06 }
}

// MARK: - SpotifyLyricsCore/Overlay/InstrumentalBreakView.swift

/// Overlay view shown during instrumental breaks (gaps > 8s between lyric lines).
/// Displays a countdown to the next vocal line with a preview of the upcoming text.
public struct InstrumentalBreakView: View {
    @ObservedObject var lyricsManager: LyricsManager
    @ObservedObject var playerManager: SpotifyPlayerManager
    let showsUpcomingLinePreview: Bool

    public init(
        lyricsManager: LyricsManager,
        playerManager: SpotifyPlayerManager,
        showsUpcomingLinePreview: Bool = true
    ) {
        self.lyricsManager = lyricsManager
        self.playerManager = playerManager
        self.showsUpcomingLinePreview = showsUpcomingLinePreview
    }

    public var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Musical note icon with render-server breathing (no per-frame main-thread cost).
            Image(systemName: "music.note")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
                .breathing(duration: 2.0, maxScale: 1.08, minOpacity: 0.6)

            // Countdown text
            Text(countdownText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .contentTransition(.numericText())

            // Upcoming line preview
            if showsUpcomingLinePreview, let nextText = lyricsManager.nextVocalLineText {
                Text(nextText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var countdownText: String {
        LyricLineVisualStyle.instrumentalCountdownText(seconds: lyricsManager.instrumentalBreakCountdown)
    }
}

/// Inline break indicator rendered in the lyrics list during full-overlay instrumental gaps.
public struct InlineInstrumentalBreakLineView: View {
    @ObservedObject var lyricsManager: LyricsManager

    public init(lyricsManager: LyricsManager) {
        self.lyricsManager = lyricsManager
    }

    public var body: some View {
        let countdownText = LyricLineVisualStyle.instrumentalCountdownText(seconds: lyricsManager.instrumentalBreakCountdown)
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
                .breathing(duration: 2.0, maxScale: 1.08, minOpacity: 0.6)

            if !countdownText.isEmpty {
                Text(countdownText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .accessibilityLabel(accessibilityText(countdownText: countdownText))
    }

    private func accessibilityText(countdownText: String) -> String {
        if !countdownText.isEmpty {
            return "Instrumental break, \(countdownText) until next line"
        }
        return "Instrumental break"
    }
}

/// Compact break indicator for mini overlay mode.
public struct MiniInstrumentalBreakView: View {
    @ObservedObject var lyricsManager: LyricsManager

    public init(lyricsManager: LyricsManager) {
        self.lyricsManager = lyricsManager
    }

    public var body: some View {
        let countdownText = LyricLineVisualStyle.instrumentalCountdownText(seconds: lyricsManager.instrumentalBreakCountdown)
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .breathing(duration: 1.5, maxScale: 1.0, minOpacity: 0.4)

            if !countdownText.isEmpty {
                Text(countdownText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - SpotifyLyricsCore/Overlay/LyricLineView.swift

public struct LyricLineView: View {
    public let line: LyricLine
    public let isActive: Bool
    public let offset: Int
    public let mode: AnimationMode
    /// Live playback position; only meaningful for the active line (karaoke/glow).
    public let position: TimeInterval
    /// Effective end time of this line, used for the karaoke sweep.
    public let lineEnd: TimeInterval
    /// Optional enrichment (romanization / translation) for this line.
    public let enrichment: LineEnrichment?
    /// Callback for "Share as Card" context menu action.
    public var onShareAsCard: ((LyricLine, LineEnrichment?) -> Void)?

    public init(line: LyricLine, isActive: Bool, offset: Int, mode: AnimationMode, position: TimeInterval, lineEnd: TimeInterval, enrichment: LineEnrichment? = nil, onShareAsCard: ((LyricLine, LineEnrichment?) -> Void)? = nil) {
        self.line = line
        self.isActive = isActive
        self.offset = offset
        self.mode = mode
        self.position = position
        self.lineEnd = lineEnd
        self.enrichment = enrichment
        self.onShareAsCard = onShareAsCard
    }

    @State private var isHovered = false

    public var body: some View {
        VStack(spacing: 4) {
            if let rom = enrichment?.romanization {
                Text(rom)
                    .font(.system(size: enrichmentFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(LyricLineVisualStyle.enrichmentOpacity(isActive: isActive)))
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity
                    ))
            }

            content

            if let trans = enrichment?.translation {
                Text(trans)
                    .font(.system(size: enrichmentFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(LyricLineVisualStyle.enrichmentOpacity(isActive: isActive)))
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity
                    ))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        // Depth blur is applied innermost and its transaction animation is cleared, so changes
        // to the radius snap instantly. Animating a Gaussian blur radius is GPU-expensive and
        // stutters; several far lines crossing a blur threshold on every line change was a
        // major source of jank. Scale/opacity/offset below still animate with the spring.
        .blur(radius: lineBlur)
        .transaction { $0.animation = nil }
        .opacity(lineOpacity)
        .scaleEffect(scale)
        .offset(y: lineYOffset)
        .padding(.vertical, enrichment != nil ? 6 : 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(isHovered ? 0.1 : 0))
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .contextMenu {
            Button("Share as Card") {
                onShareAsCard?(line, enrichment)
            }
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    /// A single, identity-stable view tree for every line in every mode. The active⇄inactive
    /// difference is expressed purely through animatable values (color, opacity, shadow, mask
    /// width) rather than swapping between different view types — swapping breaks SwiftUI
    /// identity and makes the line *pop* instead of transitioning.
    private var content: some View {
        let isGlowActive = isActive && mode == .glow
        let glowPulse = (sin(position * 3) + 1) / 2 // 0…1

        return baseText(textBaseColor)
            // Glow: a white halo that fades in/out via radius+opacity (0 when inactive).
            .shadow(
                color: .white.opacity(isGlowActive ? 0.25 + 0.45 * glowPulse : 0),
                radius: isGlowActive ? 3 + 9 * glowPulse : 0
            )
            // Karaoke fill: a bright copy revealed left-to-right. Present in every karaoke-mode
            // line (not just the active one) so activation animates the overlay's opacity
            // instead of inserting/removing a whole subtree.
            .overlay(alignment: .leading) {
                if mode == .karaoke {
                    let fraction = line.fillFraction(at: position, lineEnd: lineEnd)
                    baseText(.white)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle().frame(width: geo.size.width * fraction)
                            }
                        }
                        .opacity(isActive ? 1 : 0)
                }
            }
    }

    private func baseText(_ color: Color) -> some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: fontWeight, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.5), radius: isActive ? 4 : 2, x: 0, y: 1)
    }

    /// Base text color. Karaoke's active line is dimmed because its brightness comes from the
    /// fill overlay; every other case uses the standard foreground color.
    private var textBaseColor: Color {
        if isActive && mode == .karaoke { return .white }
        return foregroundColor
    }

    /// Constant font size — size differentiation is handled by animatable `scaleEffect`
    /// so transitions between active/inactive are smooth (font size changes can't animate).
    private var fontSize: CGFloat { 21 }

    /// Constant weight — weight changes can't animate and cause visible jumps.
    /// Opacity + scale provide sufficient visual distinction.
    private var fontWeight: Font.Weight { .semibold }

    private var enrichmentFontSize: CGFloat { 13 }

    private var scale: CGFloat {
        CGFloat(LyricLineVisualStyle.scale(isActive: isActive, mode: mode))
    }

    private var foregroundColor: Color {
        if isHovered && !isActive {
            return .white.opacity(0.9)
        }
        return .white.opacity(LyricLineVisualStyle.mainTextOpacity(isActive: isActive))
    }

    private var lineOpacity: Double {
        if isHovered { return 1.0 }
        switch abs(offset) {
        case 0: return 1.0
        case 1: return 0.7
        case 2: return 0.5
        case 3: return 0.35
        default: return 0.25
        }
    }

    /// Depth-of-field blur for distant lines (disabled for smooth mode — too expensive to animate)
    private var lineBlur: CGFloat {
        if mode == .smooth { return 0 }
        if isHovered { return 0 }
        switch abs(offset) {
        case 0...2: return 0
        case 3: return 1.0
        case 4: return 2.0
        default: return 3.0
        }
    }

    /// Subtle vertical offset for inactive lines, creating a parallax feel
    private var lineYOffset: CGFloat {
        guard !isActive else { return 0 }
        let direction: CGFloat = offset > 0 ? 1 : -1
        let distance = min(abs(offset), 5)
        return direction * CGFloat(distance) * 0.5
    }
}

// MARK: - SpotifyLyricsCore/Overlay/LyricLineVisualStyle.swift

public enum LyricLineVisualStyle {
    public static func isLineActive(index: Int, activeIndex: Int, isInstrumentalBreak: Bool) -> Bool {
        !isInstrumentalBreak && index == activeIndex
    }

    public static func showsInlineInstrumentalBreak(index: Int, activeIndex: Int, isInstrumentalBreak: Bool) -> Bool {
        isInstrumentalBreak && index == activeIndex
    }

    public static func showsLyricLine(index: Int, activeIndex: Int, isInstrumentalBreak: Bool) -> Bool {
        true
    }

    public static func instrumentalCountdownText(seconds: Double) -> String {
        let totalSeconds = Int(ceil(seconds))
        guard totalSeconds > 0 else { return "" }
        return String(format: "-%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    public static func mainTextOpacity(isActive: Bool) -> Double {
        isActive ? 1.0 : 0.7
    }

    public static func enrichmentOpacity(isActive: Bool) -> Double {
        isActive ? 1.0 : 0.4
    }

    public static func scale(isActive: Bool, mode: AnimationMode) -> Double {
        if mode == .smooth {
            return isActive ? 1.14 : 0.88
        }
        guard isActive else { return 0.86 }
        return mode == .spring ? 1.28 : 1.22
    }
}

// MARK: - SpotifyLyricsCore/Overlay/LyricsOverlayView.swift

public struct LyricsOverlayView: View {
    @ObservedObject var lyricsManager: LyricsManager
    @ObservedObject var playerManager: SpotifyPlayerManager
    @Binding var backgroundOpacity: Double
    @Binding var animationMode: AnimationMode
    @Binding var overlaySize: OverlaySize
    var onClose: (() -> Void)?

    public init(
        lyricsManager: LyricsManager,
        playerManager: SpotifyPlayerManager,
        backgroundOpacity: Binding<Double> = .constant(0.85),
        animationMode: Binding<AnimationMode> = .constant(.karaoke),
        overlaySize: Binding<OverlaySize> = .constant(.medium),
        onClose: (() -> Void)? = nil
    ) {
        self.lyricsManager = lyricsManager
        self.playerManager = playerManager
        self._backgroundOpacity = backgroundOpacity
        self._animationMode = animationMode
        self._overlaySize = overlaySize
        self.onClose = onClose
    }

    @State private var isManualScrolling = false
    @State private var isAutoScrolling = false
    @State private var scrollGeneration = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isOverlayHovered = false
    @State private var displayedLineIndex: Int = 0
    @State private var cardPreviewImage: NSImage?
    @State private var showCardPreview = false
    private let cardGenerator = LyricsCardGenerator()

    public var body: some View {
        ZStack {
            if !playerManager.isSpotifyRunning {
                statusView("Waiting for Spotify...")
            } else if lyricsManager.isLoading {
                statusView("Loading lyrics...")
            } else if !lyricsManager.hasLyrics {
                statusView("No lyrics available")
            } else {
                lyricsScrollView
                    .blur(radius: playerManager.playerState == .paused ? 6 : 0)
                    .animation(.easeInOut(duration: 0.35), value: playerManager.playerState == .paused)
                    .animation(.easeInOut(duration: 0.5), value: lyricsManager.isInstrumentalBreak)
            }

            if lyricsManager.hasLyrics {
                pausedOverlay
                    .opacity(playerManager.playerState == .paused ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: playerManager.playerState == .paused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(overlayBackground)
        // Natural title/drag area. It covers the upper part of the overlay rather
        // than forcing the user to find a narrow strip, while the close button
        // and all lower controls remain interactive.
        .overlay(alignment: .topLeading) {
            WindowDragHandle()
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .padding(.trailing, 44)
        }
        .overlay(alignment: .topLeading) {
            if let track = playerManager.currentTrack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(track.artist)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    if let summary = lyricsManager.songSummary {
                        SummaryMarqueeText(summary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .padding(.trailing, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isOverlayHovered ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(ControlButtonStyle(size: 24))
            .padding(10)
            .opacity(isOverlayHovered ? 1 : 0)
            .allowsHitTesting(isOverlayHovered)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                ZStack {
                    MusicControlsView(playerManager: playerManager, style: .compact)

                    if isManualScrolling {
                        Button {
                            scrollBackToCurrent()
                        } label: {
                            HStack(spacing: OverlayRecenterButtonPresentation.showsTitle(for: overlaySize) ? 3 : 0) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10, weight: .semibold))
                                if OverlayRecenterButtonPresentation.showsTitle(for: overlaySize) {
                                    Text("Current")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: OverlayRecenterButtonPresentation.showsTitle(for: overlaySize) ? nil : 24, height: 24)
                            .padding(.horizontal, OverlayRecenterButtonPresentation.showsTitle(for: overlaySize) ? 8 : 0)
                            .padding(.vertical, OverlayRecenterButtonPresentation.showsTitle(for: overlaySize) ? 4 : 0)
                            .background(Capsule().fill(.white.opacity(0.15)))
                        }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityLabel(OverlayRecenterButtonPresentation.accessibilityLabel)
                        .help(OverlayRecenterButtonPresentation.accessibilityLabel)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity)
                    }
                }
                SeekBarView(playerManager: playerManager)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            )
            .opacity(isOverlayHovered && playerManager.isSpotifyRunning ? 1 : 0)
            .allowsHitTesting(isOverlayHovered && playerManager.isSpotifyRunning)
        }
        .animation(.easeInOut(duration: 0.2), value: isOverlayHovered)
        .onWindowHover { isOverlayHovered = $0 }
        // Clip the entire overlay, not just its background. This prevents the
        // translucent material/overlays from bleeding into the window corners.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if showCardPreview, let image = cardPreviewImage {
                cardPreviewOverlay(image: image)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCardPreview)
    }

    private var pausedOverlay: some View {
        ZStack {
            // Keep the lyrics visible underneath. The blur is applied to the
            // lyrics layer itself; this is intentionally only a translucent
            // tint, not an opaque material which can turn into a grey sheet.
            Color.black.opacity(0.18)

            VStack(spacing: 7) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text("Paused")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var overlayBackground: some View {
        if overlaySize == .squareAlbum {
            AlbumArtworkBackground(
                artworkURL: playerManager.artworkURL,
                opacity: backgroundOpacity
            )
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .opacity(backgroundOpacity)
        }
    }

    @ViewBuilder
    private func cardPreviewOverlay(image: NSImage) -> some View {
        ZStack {
            Color.black.opacity(0.7)
                .onTapGesture { showCardPreview = false }

            VStack(spacing: 12) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 10)

                HStack(spacing: 10) {
                    Button("Copy to Clipboard") {
                        cardGenerator.copyToClipboard(image)
                        showCardPreview = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") {
                        showCardPreview = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func scrollBackToCurrent() {
        isManualScrolling = false
        if let proxy = scrollProxy {
            animateToLine(lyricsManager.currentLineIndex, proxy: proxy)
        }
    }

    /// Single entry point for moving the active line. Centers `index` and updates the active
    /// state inside *one* spring transaction, so the scroll offset and the per-line
    /// scale/opacity ride the exact same curve (mismatched curves read as jank). A generation
    /// token guards `isAutoScrolling`: during a rapid run of line changes, only the latest
    /// transition's timer clears the flag, so an early timer can't release it mid-flight and
    /// misread the tail of an auto-scroll as a user scroll.
    private func animateToLine(_ index: Int, proxy: ScrollViewProxy, animated: Bool = true) {
        isAutoScrolling = true
        scrollGeneration += 1
        let generation = scrollGeneration
        let move = {
            displayedLineIndex = index
            proxy.scrollTo(index, anchor: .center)
        }
        if animated {
            withAnimation(animationMode.transition, move)
        } else {
            move()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if generation == scrollGeneration { isAutoScrolling = false }
        }
    }

    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    Spacer().frame(height: 60)

                    ForEach(Array(lyricsManager.currentLines.enumerated()), id: \.element.id) { index, line in
                        lineView(index: index, line: line)
                            .id(index)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playerManager.seekTo(line.timestamp)
                                lyricsManager.updateCurrentLine(at: line.timestamp)
                                isManualScrolling = false
                                animateToLine(lyricsManager.currentLineIndex, proxy: proxy)
                            }
                    }

                    Spacer().frame(height: 60)
                }
                .padding(.horizontal, 24)
            }
            .mask(lyricPanelFadeMask)
            .onAppear {
                scrollProxy = proxy
                displayedLineIndex = lyricsManager.currentLineIndex
                // Jump (no animation) to the current line on first layout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    animateToLine(lyricsManager.currentLineIndex, proxy: proxy, animated: false)
                }
            }
            .onChange(of: lyricsManager.currentLineIndex) { newIndex in
                guard !isManualScrolling else { return }
                animateToLine(newIndex, proxy: proxy)
            }
            .onUserScroll {
                guard !isAutoScrolling else { return }
                isManualScrolling = true
            }
            .onChange(of: lyricsManager.enrichment.count) { _ in
                // Enrichment toggled (translation/romanization) changes line heights, so
                // re-center the current line once the new layout settles.
                isManualScrolling = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    animateToLine(lyricsManager.currentLineIndex, proxy: proxy)
                }
            }
        }
    }

    private var lyricPanelFadeMask: some View {
        let stops = LyricPanelFadeStops()
        return LinearGradient(
            stops: [
                .init(color: .clear, location: stops.topClear),
                .init(color: .black, location: stops.topOpaque),
                .init(color: .black, location: stops.bottomOpaque),
                .init(color: .clear, location: stops.bottomClear)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Builds a line view. Every line uses the same `TimelineView` structure to keep
    /// SwiftUI view identity stable across active-state changes. Only the active
    /// karaoke/glow line actually runs per-frame; others are paused (zero cost).
    @ViewBuilder
    private func lineView(index: Int, line: LyricLine) -> some View {
        let activeIndex = displayedLineIndex
        let showsLyricLine = LyricLineVisualStyle.showsLyricLine(
            index: index,
            activeIndex: activeIndex,
            isInstrumentalBreak: lyricsManager.isInstrumentalBreak
        )
        let showsInstrumentalBreak = LyricLineVisualStyle.showsInlineInstrumentalBreak(
            index: index,
            activeIndex: activeIndex,
            isInstrumentalBreak: lyricsManager.isInstrumentalBreak
        )
        let isActive = LyricLineVisualStyle.isLineActive(
            index: index,
            activeIndex: activeIndex,
            isInstrumentalBreak: lyricsManager.isInstrumentalBreak
        )
        let lineEnrichment = lyricsManager.enrichment[index]
        let shareHandler: (LyricLine, LineEnrichment?) -> Void = { line, enrichment in
            generateCardPreview(line: line, enrichment: enrichment)
        }
        let needsPerFrame = isActive && (animationMode == .karaoke || animationMode == .glow)

        VStack(spacing: 8) {
            if showsLyricLine {
                TimelineView(.animation(minimumInterval: nil, paused: !needsPerFrame)) { _ in
                    LyricLineView(
                        line: line,
                        isActive: isActive,
                        offset: index - activeIndex,
                        mode: animationMode,
                        position: playerManager.playbackPosition,
                        lineEnd: lineEnd(at: index),
                        enrichment: lineEnrichment,
                        onShareAsCard: shareHandler
                    )
                }
            }

            if showsInstrumentalBreak {
                InlineInstrumentalBreakLineView(lyricsManager: lyricsManager)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    /// Effective end time for a line: its own end, else the next line's start.
    private func lineEnd(at index: Int) -> TimeInterval {
        let lines = lyricsManager.currentLines
        guard index < lines.count else { return 0 }
        if let end = lines[index].endTime { return end }
        if index + 1 < lines.count { return lines[index + 1].timestamp }
        return lines[index].timestamp + 5
    }

    private func generateCardPreview(line: LyricLine, enrichment: LineEnrichment?) {
        guard let track = playerManager.currentTrack else { return }
        let artworkURL = playerManager.artworkURL

        Task {
            // Download album artwork for the card background
            var artwork: NSImage?
            if let url = artworkURL {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    artwork = NSImage(data: data)
                }
            }

            let image = cardGenerator.generateCard(
                line: line,
                enrichment: enrichment,
                title: track.title,
                artist: track.artist,
                artworkImage: artwork
            )
            cardPreviewImage = image
            showCardPreview = true
        }
    }

    private func statusView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.45))

            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        // Render-server breathing — no per-frame main-thread re-evaluation. These idle states
        // (waiting / loading / no lyrics) can persist for a whole track, so a TimelineView here
        // would burn the main thread at the display refresh rate for purely decorative motion.
        .breathing()
    }
}

// MARK: - Square Album background

private struct AlbumArtworkBackground: View {
    let artworkURL: URL?
    let opacity: Double

    @State private var artworkImage: NSImage?
    @State private var tintColor = Color(red: 0.18, green: 0.08, blue: 0.05)

    var body: some View {
        ZStack {
            tintOnlyBackground

            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }

            tintColor
                .opacity(0.16 + opacity * 0.24)

            Color.black
                .opacity(0.22 + opacity * 0.42)

            LinearGradient(
                colors: [
                    .black.opacity(0.12 + opacity * 0.16),
                    .clear,
                    .black.opacity(0.30 + opacity * 0.26)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: artworkURL) {
            await loadArtwork()
        }
    }

    private var tintOnlyBackground: some View {
        LinearGradient(
            colors: [
                tintColor.opacity(0.42 + opacity * 0.28),
                Color.black.opacity(0.82),
                tintColor.opacity(0.22 + opacity * 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @MainActor
    private func loadArtwork() async {
        guard let artworkURL else {
            artworkImage = nil
            tintColor = Color(red: 0.18, green: 0.08, blue: 0.05)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: artworkURL)
            guard let image = NSImage(data: data) else {
                artworkImage = nil
                return
            }
            artworkImage = image
            if let color = image.averageColor {
                tintColor = Color(nsColor: color)
            }
        } catch {
            artworkImage = nil
        }
    }
}

private extension NSImage {
    var averageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = 1
        let height = 1
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var pixel = [UInt8](repeating: 0, count: 4)

        guard let context = CGContext(
            data: &pixel,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return NSColor(
            calibratedRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}

// MARK: - Lyric panel fade

public struct LyricPanelFadeStops: Equatable {
    public let topClear: CGFloat
    public let topOpaque: CGFloat
    public let bottomOpaque: CGFloat
    public let bottomClear: CGFloat

    public init(
        topClear: CGFloat = 0,
        topOpaque: CGFloat = 0.16,
        bottomOpaque: CGFloat = 0.84,
        bottomClear: CGFloat = 1
    ) {
        self.topClear = topClear
        self.topOpaque = topOpaque
        self.bottomOpaque = bottomOpaque
        self.bottomClear = bottomClear
    }
}

// MARK: - AI summary marquee

public struct SummaryMarqueeMetrics: Equatable {
    public static let minimumDuration: Double = 5
    public static let pointsPerSecond: CGFloat = 22
    private static let measurementTolerance: CGFloat = 1

    public let containerWidth: CGFloat
    public let contentWidth: CGFloat

    public init(containerWidth: CGFloat, contentWidth: CGFloat) {
        self.containerWidth = max(0, containerWidth)
        self.contentWidth = max(0, contentWidth)
    }

    public var shouldScroll: Bool {
        contentWidth > containerWidth + Self.measurementTolerance
    }

    public var scrollDistance: CGFloat {
        shouldScroll ? contentWidth - containerWidth : 0
    }

    public var duration: Double {
        guard shouldScroll else { return 0 }
        return max(Self.minimumDuration, Double(scrollDistance / Self.pointsPerSecond))
    }
}

private struct SummaryMarqueeText: View {
    let text: String

    @State private var containerWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var isShiftedLeft = false
    @State private var animationGeneration = 0

    init(_ text: String) {
        self.text = text
    }

    private var metrics: SummaryMarqueeMetrics {
        SummaryMarqueeMetrics(containerWidth: containerWidth, contentWidth: contentWidth)
    }

    var body: some View {
        GeometryReader { proxy in
            let currentMetrics = SummaryMarqueeMetrics(
                containerWidth: proxy.size.width,
                contentWidth: contentWidth
            )

            Text(text)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .italic()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: isShiftedLeft && currentMetrics.shouldScroll ? -currentMetrics.scrollDistance : 0)
                .background(
                    GeometryReader { textProxy in
                        Color.clear.preference(key: SummaryTextWidthPreferenceKey.self, value: textProxy.size.width)
                    }
                )
                .animation(
                    currentMetrics.shouldScroll
                        ? .easeInOut(duration: currentMetrics.duration).repeatForever(autoreverses: true)
                        : .default,
                    value: isShiftedLeft
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .onAppear {
                    containerWidth = proxy.size.width
                    restartAnimation()
                }
                .onChange(of: proxy.size.width) { width in
                    containerWidth = width
                    restartAnimation()
                }
        }
        .frame(height: 14)
        .clipped()
        .onPreferenceChange(SummaryTextWidthPreferenceKey.self) { width in
            contentWidth = width
            restartAnimation()
        }
        .onChange(of: text) { _ in
            restartAnimation()
        }
    }

    private func restartAnimation() {
        animationGeneration += 1
        let generation = animationGeneration
        isShiftedLeft = false

        guard metrics.shouldScroll else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard generation == animationGeneration else { return }
            isShiftedLeft = true
        }
    }
}

private struct SummaryTextWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Render-server breathing pulse

/// A gentle scale+opacity "breathing" loop driven entirely by Core Animation (the render
/// server), so it costs nothing on the main thread — unlike `TimelineView(.animation)`, which
/// re-evaluates the SwiftUI body every frame. Use for purely decorative, always-on motion.
struct BreathingModifier: ViewModifier {
    var duration: Double = 1.7
    var minScale: CGFloat = 1.0
    var maxScale: CGFloat = 1.05
    var minOpacity: Double = 0.7
    var maxOpacity: Double = 1.0

    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? maxScale : minScale)
            .opacity(on ? maxOpacity : minOpacity)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

extension View {
    func breathing(duration: Double = 1.7, minScale: CGFloat = 1.0, maxScale: CGFloat = 1.05,
                   minOpacity: Double = 0.7, maxOpacity: Double = 1.0) -> some View {
        modifier(BreathingModifier(duration: duration, minScale: minScale, maxScale: maxScale,
                                   minOpacity: minOpacity, maxOpacity: maxOpacity))
    }
}

// MARK: - Window-level hover tracking

/// Uses NSEvent mouseMoved monitoring to track whether the cursor is inside
/// the hosting window. Much more reliable than SwiftUI's .onHover in NSPanel.
struct WindowHoverModifier: ViewModifier {
    let onHoverChanged: (Bool) -> Void
    @State private var monitor: Any?
    @State private var isInside = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { event in
                    guard let window = event.window ?? NSApp.windows.first(where: {
                        $0 is NSPanel && $0.isVisible && $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        if isInside {
                            isInside = false
                            onHoverChanged(false)
                        }
                        return event
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let inside = window.frame.contains(mouseLocation)

                    if inside != isInside {
                        isInside = inside
                        onHoverChanged(inside)
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
    }
}

// MARK: - Scroll wheel detection

struct UserScrollModifier: ViewModifier {
    let onUserScroll: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    let isUserTrackpad = event.phase == .began || event.phase == .changed
                    let isMouseWheel = event.phase == []
                        && event.momentumPhase == []
                        && abs(event.deltaY) > 0.5

                    if isUserTrackpad || isMouseWheel {
                        onUserScroll()
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
    }
}

extension View {
    func onUserScroll(_ action: @escaping () -> Void) -> some View {
        modifier(UserScrollModifier(onUserScroll: action))
    }

    func onWindowHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(WindowHoverModifier(onHoverChanged: action))
    }
}

// MARK: - Native window drag support

/// A small native AppKit drag region for borderless SwiftUI overlay windows.
///
/// macOS can deliver mouse events directly to the SwiftUI hosting view, which
/// makes `isMovableByWindowBackground` unreliable for a borderless panel.
/// This view hands the mouse-down event directly to AppKit's window server.
private final class OverlayWindowDragHandle: NSView {
    override func mouseDown(with event: NSEvent) {
        // A non-activating panel can receive the initial mouse-down without
        // activating the app. Activate immediately before handing the exact
        // same mouse-down to Window Server so the drag starts on the first
        // press, rather than requiring a preliminary click.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.performDrag(with: event)
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayWindowDragHandle {
        let view = OverlayWindowDragHandle()
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: OverlayWindowDragHandle, context: Context) {}
}

// MARK: - SpotifyLyricsCore/Overlay/LyricsOverlayWindow.swift

private func overlayWindowCornerRadius(for size: OverlaySize) -> CGFloat {
    switch size {
    case .mini:
        return 24
    default:
        return 16
    }
}

private final class FocusableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

public final class LyricsOverlayWindow {
    private var panel: NSPanel?
    private var currentSize: OverlaySize = .medium

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    public init() {}

    public func show(with view: some View, size: OverlaySize = .medium) {
        currentSize = size

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let (width, height) = size.dimensions
        let cornerRadius = overlayWindowCornerRadius(for: size)
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + 20

        let panel = FocusableOverlayPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // Keep the lyrics panel above normal application windows without
        // re-ordering it every time the user switches apps. This avoids the
        // brief disappear/reappear flicker during app-to-app transitions.
        panel.level = .statusBar
        panel.canHide = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // The SwiftUI background is rounded, but the hosting view itself is
        // rectangular by default. Clip the native view too so translucent
        // pixels cannot create a grey/white halo at the four corners.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView?.addSubview(hostingView)

        let frameName = size.frameAutosaveName
        panel.setFrameUsingName(frameName)
        panel.setFrameAutosaveName(frameName)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    /// Replace the panel content with a new view (used when switching between full/mini modes).
    public func replaceContent(with view: some View, size: OverlaySize) {
        currentSize = size
        guard let panel else { return }

        // Remove old hosting view
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }

        // Resize
        let (width, height) = size.dimensions
        let cornerRadius = overlayWindowCornerRadius(for: size)
        let currentFrame = panel.frame
        let newX = currentFrame.midX - width / 2
        let newY = currentFrame.midY - height / 2
        panel.setFrame(NSRect(x: newX, y: newY, width: width, height: height), display: true, animate: true)

        // Set frame autosave for the new mode
        panel.setFrameAutosaveName(size.frameAutosaveName)

        // Insert new hosting view
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView?.addSubview(hostingView)
    }

    public func showIfCreated() {
        panel?.orderFront(nil)
    }

    /// Kept for compatibility with older callers. The panel now stays visible
    /// through app switches without being re-ordered on every deactivation.
    public func maintainVisibilityAfterDeactivation() {
        // Intentionally empty. Re-ordering here caused the app-switch flicker.
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            panel?.orderFront(nil)
        }
    }

    public func setAlwaysOnTop(_ enabled: Bool) {
        panel?.level = enabled ? .floating : .normal
    }

    public func setOpacity(_ opacity: Double) {
        // No longer setting panel alphaValue — opacity is handled
        // per-view on the background only, so text/controls stay fully visible.
    }

    public func resize(to size: OverlaySize) {
        guard let panel else { return }
        let (width, height) = size.dimensions
        let currentFrame = panel.frame
        let newX = currentFrame.midX - width / 2
        let newY = currentFrame.midY - height / 2
        panel.setFrame(NSRect(x: newX, y: newY, width: width, height: height), display: true, animate: true)
        panel.setFrameAutosaveName(size.frameAutosaveName)
    }

    public func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - SpotifyLyricsCore/Overlay/MiniOverlayView.swift

/// Single-line subtitle bar overlay showing only the current lyric with karaoke fill.
/// Minimal screen real estate alternative to the full lyrics overlay.
public struct MiniOverlayView: View {
    @ObservedObject var lyricsManager: LyricsManager
    @ObservedObject var playerManager: SpotifyPlayerManager
    @Binding var backgroundOpacity: Double
    @Binding var animationMode: AnimationMode
    var onSwitchToFull: (() -> Void)?
    var onClose: (() -> Void)?

    public init(
        lyricsManager: LyricsManager,
        playerManager: SpotifyPlayerManager,
        backgroundOpacity: Binding<Double> = .constant(0.85),
        animationMode: Binding<AnimationMode> = .constant(.karaoke),
        onSwitchToFull: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.lyricsManager = lyricsManager
        self.playerManager = playerManager
        self._backgroundOpacity = backgroundOpacity
        self._animationMode = animationMode
        self.onSwitchToFull = onSwitchToFull
        self.onClose = onClose
    }

    @State private var isHovered = false

    public var body: some View {
        ZStack {
            // Background pill
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(backgroundOpacity)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)

            if !playerManager.isSpotifyRunning {
                miniStatusText("Waiting for Spotify...")
            } else if lyricsManager.isLoading {
                miniStatusText("Loading lyrics...")
            } else if !lyricsManager.hasLyrics {
                miniStatusText("No lyrics available")
            } else if lyricsManager.isInstrumentalBreak {
                MiniInstrumentalBreakView(lyricsManager: lyricsManager)
                    .transition(.opacity)
            } else {
                currentLineContent
                    .blur(radius: playerManager.playerState == .paused ? 5 : 0)
                    .animation(.easeInOut(duration: 0.35), value: playerManager.playerState == .paused)
            }

            if lyricsManager.hasLyrics {
                miniPausedOverlay
                    .opacity(playerManager.playerState == .paused ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: playerManager.playerState == .paused)
            }

            // Hover controls
            if isHovered {
                HStack(spacing: 6) {
                    Spacer()

                    Button(action: { onSwitchToFull?() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }
                    .buttonStyle(MiniButtonStyle())
                    .help("Switch to full overlay")

                    Button(action: { onClose?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }
                    .buttonStyle(MiniButtonStyle())
                    .help("Hide overlay")
                }
                .padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        // Natural drag area for the mini pill. Most of the pill is draggable,
        // while the right edge stays free for the hover controls.
        .overlay(alignment: .topLeading) {
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onWindowHover { isHovered = $0 }
    }

    private var miniPausedOverlay: some View {
        ZStack {
            // Translucent tint only; the blurred lyric line remains visible.
            Color.black.opacity(0.18)
                .clipShape(Capsule())

            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Paused")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.94))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var currentLineContent: some View {
        let lines = lyricsManager.currentLines
        let index = lyricsManager.currentLineIndex
        if index < lines.count {
            let line = lines[index]
            let enrichment = lyricsManager.enrichment[index]
            let hasEnrichment = enrichment?.isEmpty == false

            if hasEnrichment {
                miniEnrichedLine(line: line, enrichment: enrichment!)
            } else {
                miniLine(line: line)
            }
        }
    }

    /// Single line with karaoke fill, no enrichment
    @ViewBuilder
    private func miniLine(line: LyricLine) -> some View {
        let isKaraokeOrGlow = animationMode == .karaoke || animationMode == .glow
        if isKaraokeOrGlow {
            TimelineView(.animation) { _ in
                miniLyricText(line: line)
            }
        } else {
            miniLyricText(line: line)
        }
    }

    /// Single line with enrichment text stacked
    @ViewBuilder
    private func miniEnrichedLine(line: LyricLine, enrichment: LineEnrichment) -> some View {
        let isKaraokeOrGlow = animationMode == .karaoke || animationMode == .glow
        if isKaraokeOrGlow {
            TimelineView(.animation) { _ in
                VStack(spacing: 2) {
                    if let rom = enrichment.romanization {
                        Text(rom)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    miniLyricText(line: line)
                    if let trans = enrichment.translation {
                        Text(trans)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
        } else {
            VStack(spacing: 2) {
                if let rom = enrichment.romanization {
                    Text(rom)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                }
                miniLyricText(line: line)
                if let trans = enrichment.translation {
                    Text(trans)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func miniLyricText(line: LyricLine) -> some View {
        let lineEnd = effectiveLineEnd(for: lyricsManager.currentLineIndex)
        if animationMode == .karaoke {
            let fraction = line.fillFraction(at: playerManager.playbackPosition, lineEnd: lineEnd)
            baseText(line.text, color: .white.opacity(0.4))
                .overlay(alignment: .leading) {
                    baseText(line.text, color: .white)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle().frame(width: geo.size.width * fraction)
                            }
                        }
                }
        } else if animationMode == .glow {
            let pulse = (sin(playerManager.playbackPosition * 3) + 1) / 2
            baseText(line.text, color: .white)
                .shadow(color: .white.opacity(0.25 + 0.45 * pulse), radius: 3 + 9 * pulse)
        } else {
            baseText(line.text, color: .white)
        }
    }

    private func baseText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
    }

    private func miniStatusText(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        // Render-server breathing — no per-frame main-thread work (see BreathingModifier).
        .breathing()
    }

    private func effectiveLineEnd(for index: Int) -> TimeInterval {
        let lines = lyricsManager.currentLines
        guard index < lines.count else { return 0 }
        if let end = lines[index].endTime { return end }
        if index + 1 < lines.count { return lines[index + 1].timestamp }
        return lines[index].timestamp + 5
    }
}

// MARK: - Mini button style

private struct MiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

// MARK: - SpotifyLyricsCore/Overlay/OverlayRecenterButtonPresentation.swift

public enum OverlayRecenterButtonPresentation {
    public static let accessibilityLabel = "Current"

    public static func showsTitle(for overlaySize: OverlaySize) -> Bool {
        overlaySize != .squareAlbum
    }
}

// MARK: - App/DominantColorExtractor.swift

@MainActor
final class DominantColorExtractor: ObservableObject {
    @Published var dominantColor: Color = .white
    @Published var accentColor: Color = .gray
    @Published var backgroundColor: Color = .black
    @Published var albumText: [String] = []

    private let visionAnalyzer = VisionAnalyzer()
    private var cachedURL: URL?

    func extractColor(from url: URL?) {
        guard let url, url != cachedURL else { return }
        cachedURL = url

        // Use Vision-based analysis for rich palette
        visionAnalyzer.analyze(imageURL: url)

        // Observe Vision results
        Task { @MainActor in
            // Give Vision a moment to process
            try? await Task.sleep(nanoseconds: 500_000_000)

            if let palette = self.visionAnalyzer.palette {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.dominantColor = Color(nsColor: palette.dominant)
                    self.accentColor = Color(nsColor: palette.accent)
                    self.backgroundColor = Color(nsColor: palette.background)
                }
            } else {
                // Fallback to simple average color
                guard let color = DominantColorExtractor.computeAverageColor(from: url) else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.dominantColor = Color(nsColor: color)
                }
            }

            self.albumText = self.visionAnalyzer.detectedText
        }
    }

    private nonisolated static func computeAverageColor(from url: URL) -> NSColor? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = 1
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]

        guard let context = CGContext(
            data: &pixel,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0

        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let adjustedBrightness = max(brightness, 0.6)
        let adjustedSaturation = min(saturation * 1.2, 1.0)

        return NSColor(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: 1.0)
    }
}

// MARK: - App/MenuBarView.swift

// Keeps the popover window in sync with the SwiftUI drawer height.
private struct PopoverWindowModifier: NSViewRepresentable {
    let contentSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.hasShadow = true
            if window.contentView?.frame.size != contentSize {
                window.setContentSize(contentSize)
            }

            // Remove the rounded corner mask on the visual effect view.
            if let contentView = window.contentView?.superview {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 0
                contentView.layer?.masksToBounds = true
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var playerManager: SpotifyPlayerManager
    @EnvironmentObject var lyricsManager: LyricsManager
    @EnvironmentObject var overlayController: OverlayController
    @EnvironmentObject var soundClassifier: SoundClassifier

    @StateObject private var colorExtractor = DominantColorExtractor()
    @State private var isHovering = false
    @State private var showClearCacheConfirmation = false
    @AppStorage("menuBarSettingsExpanded") private var isSettingsExpanded = false
    private let appVersionText = AppVersionDisplay.currentMarketingVersion()
    private let popupWidth: CGFloat = 300
    private let artworkSize: CGFloat = 300
    private let expandedSettingsHeight: CGFloat = 346
    private let collapsedPopupHeight: CGFloat = 374
    private let expandedPopupHeight: CGFloat = 728

    var body: some View {
        VStack(spacing: 0) {
            miniPlayerSection
                .frame(width: artworkSize, height: artworkSize)
                .clipped()
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isHovering = hovering
                    }
                }

            Spacer().frame(height: 8)

            Divider()

            settingsSection
        }
        .frame(width: popupWidth, height: isSettingsExpanded ? expandedPopupHeight : collapsedPopupHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            PopoverWindowModifier(
                contentSize: CGSize(
                    width: popupWidth,
                    height: isSettingsExpanded ? expandedPopupHeight : collapsedPopupHeight
                )
            )
        )
        .onChange(of: playerManager.artworkURL) { url in
            colorExtractor.extractColor(from: url)
        }
        .onAppear {
            colorExtractor.extractColor(from: playerManager.artworkURL)
        }
    }

    // MARK: - Mini Player Section

    private var miniPlayerSection: some View {
        ZStack {
            if let track = playerManager.currentTrack {
                AsyncImage(url: playerManager.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipped()

                LinearGradient(
                    colors: [
                        .black.opacity(0),
                        .black.opacity(isHovering ? 0.55 : 0.68)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )

                trackCaption(track)

                if isHovering {
                    AsyncImage(url: playerManager.artworkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 30)
                                .scaleEffect(1.3)
                        }
                    }
                    .frame(width: artworkSize, height: artworkSize)
                    .transition(.opacity)

                    Color.black.opacity(0.42)
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        Spacer()

                        Text(track.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
                            .padding(.horizontal, 22)

                        Text(track.artist)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
                            .padding(.horizontal, 22)
                            .padding(.top, 3)

                        Spacer().frame(height: 22)

                        HStack(spacing: 34) {
                            hoverPlaybackButton(
                                systemName: "backward.fill",
                                size: 18,
                                label: "Previous track",
                                action: playerManager.previousTrack
                            )

                            Button { playerManager.playPause() } label: {
                                ZStack {
                                    Circle()
                                        .fill(colorExtractor.dominantColor.opacity(0.9))
                                        .frame(width: 64, height: 64)
                                        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)

                                    Image(systemName: playerManager.playerState == .playing ? "pause.fill" : "play.fill")
                                        .font(.system(size: 27, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .offset(x: playerManager.playerState == .playing ? 0 : 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(playerManager.playerState == .playing ? "Pause" : "Play")
                            .help(playerManager.playerState == .playing ? "Pause" : "Play")

                            hoverPlaybackButton(
                                systemName: "forward.fill",
                                size: 18,
                                label: "Next track",
                                action: playerManager.nextTrack
                            )
                        }

                        Spacer()

                        SeekBarView(playerManager: playerManager, showTotalDuration: true)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 18)
                    }
                    .transition(.opacity)
                }
            } else {
                placeholder
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("No track playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text("Open Spotify to control lyrics")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No track playing. Open Spotify to control lyrics.")
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.2), Color(white: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(spacing: 8) {
            if isSettingsExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 10) {
                        overlaySettingsGroup
                        lyricsSettingsGroup
                        enrichmentSettingsGroup
                        appSettingsGroup
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
                .frame(width: popupWidth, height: expandedSettingsHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSettingsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isSettingsExpanded ? 0 : 180))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isSettingsExpanded ? "Collapse settings" : "Expand settings")
                .help(isSettingsExpanded ? "Collapse settings" : "Expand settings")

                Spacer()

                Text(appVersionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityLabel("App version \(appVersionText)")

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("Quit")
                            .font(.system(size: 12))
                        Image(systemName: "power")
                            .font(.system(size: 14))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .accessibilityLabel("Quit SpotifyLyrics")
                .help("Quit SpotifyLyrics")
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .confirmationDialog("Clear cached lyrics?", isPresented: $showClearCacheConfirmation) {
            Button("Clear Cache", role: .destructive) {
                lyricsManager.clearCache()
                if let track = playerManager.currentTrack {
                    lyricsManager.fetchLyrics(for: track)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached lyrics will be removed and the current track will be fetched again.")
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            content()
        }
        .frame(minHeight: 26)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

            VStack(spacing: 5) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
    }

    private var overlaySettingsGroup: some View {
        settingsGroup("Overlay") {
            settingsRow("Show Lyrics") {
                Toggle("", isOn: Binding(
                    get: { overlayController.isVisible },
                    set: { _ in overlayController.toggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Show Lyrics")
                .help("Show or hide the lyrics overlay")
            }

            settingsRow("Always on Top") {
                Toggle("", isOn: $overlayController.alwaysOnTop)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Always on Top")
                    .help("Keep the lyrics overlay above other windows")
            }

            settingsRow("Opacity") {
                HStack(spacing: 8) {
                    Slider(value: $overlayController.overlayOpacity, in: 0.3...1.0)
                        .controlSize(.small)
                        .frame(width: 112)
                        .onChange(of: overlayController.overlayOpacity) { _ in
                            overlayController.commitOpacity()
                        }
                        .accessibilityLabel("Overlay opacity")

                    Text("\(Int(overlayController.overlayOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }

            settingsRow("Size") {
                Picker("", selection: $overlayController.overlaySize) {
                    ForEach(OverlaySize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 128, alignment: .trailing)
                .accessibilityLabel("Overlay size")
            }

            settingsRow("Animation") {
                Picker("", selection: $overlayController.animationMode) {
                    ForEach(AnimationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 128, alignment: .trailing)
                .accessibilityLabel("Animation")
            }
        }
    }

    private var lyricsSettingsGroup: some View {
        settingsGroup("Lyrics") {
            if lyricsManager.lyricsOptions.count > 1 {
                settingsRow("Source") {
                    Picker("", selection: Binding(
                        get: {
                            lyricsManager.selectedOptionID
                                ?? lyricsManager.lyricsOptions.first?.id
                                ?? -1
                        },
                        set: { lyricsManager.selectOption($0) }
                    )) {
                        ForEach(lyricsManager.lyricsOptions) { option in
                            Text(option.menuLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 148, alignment: .trailing)
                    .accessibilityLabel("Lyrics source")
                }
            }

            settingsRow("Translation") {
                Toggle("", isOn: $overlayController.showTranslation)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Translation")
                    .help("Show translated lyrics")
            }

            if overlayController.showTranslation {
                settingsRow("Language") {
                    Picker("", selection: $overlayController.targetLanguage) {
                        ForEach(TranslationLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName)
                                .lineLimit(1)
                                .tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 128, alignment: .trailing)
                    .accessibilityLabel("Translation language")
                }

                if let notice = lyricsManager.translationNotice {
                    noticeRow(systemName: "exclamationmark.triangle", tint: .orange, text: notice)
                }
            }
        }
    }

    private var enrichmentSettingsGroup: some View {
        settingsGroup("Enrichment") {
            settingsRow("Romanization") {
                Toggle("", isOn: $overlayController.showRomanization)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Romanization")
                    .help("Show romanized lyrics where available")
            }

            if AITranslationMode.isAIAvailable {
                settingsRow("AI Summary") {
                    Toggle("", isOn: $overlayController.showSongSummary)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel("AI Summary")
                        .help("Show the song summary when available")
                }

                if overlayController.showTranslation {
                    settingsRow("AI Translation") {
                        Picker("", selection: $overlayController.aiTranslationMode) {
                            ForEach(AITranslationMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 128, alignment: .trailing)
                        .accessibilityLabel("AI Translation mode")
                        .help(
                            "Primary: AI translates directly. Refine: standard translation first, then AI improves it. Off: standard translation only."
                        )
                    }
                }
            } else {
                noticeRow(
                    systemName: "info.circle",
                    tint: .secondary,
                    text: "AI features require Apple Intelligence. Enable it in Settings > Apple Intelligence & Siri."
                )
            }

            if soundClassifier.currentMood != .unknown {
                settingsRow("Mood") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                Color(
                                    hue: soundClassifier.currentMood.themeHue,
                                    saturation: 0.7,
                                    brightness: 0.9
                                )
                            )
                            .frame(width: 8, height: 8)
                        Text(soundClassifier.currentMood.rawValue.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Mood \(soundClassifier.currentMood.rawValue.capitalized)")
                }
            }
        }
    }

    private var appSettingsGroup: some View {
        settingsGroup("App") {
            settingsRow("Lyrics Cache") {
                Button(role: .destructive) {
                    showClearCacheConfirmation = true
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Clear lyrics cache")
                .help("Clear cached lyrics and refetch the current track")
            }
        }
    }

    private func trackCaption(_ track: TrackInfo) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
            .opacity(isHovering ? 0 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.artist)")
    }

    private func hoverPlaybackButton(
        systemName: String,
        size: CGFloat,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func noticeRow(systemName: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

}

// MARK: - App/SpotifyLyricsApp.swift

struct SpotifyLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class OverlayController: ObservableObject {
    @Published var isVisible = true {
        didSet { UserDefaults.standard.set(isVisible, forKey: "overlayVisible") }
    }
    @Published var alwaysOnTop = true {
        didSet {
            overlayWindow.setAlwaysOnTop(alwaysOnTop)
            UserDefaults.standard.set(alwaysOnTop, forKey: "overlayAlwaysOnTop")
        }
    }
    @Published var overlayOpacity: Double = 0.9
    private var opacitySaveTask: DispatchWorkItem?
    /// Remembers the last non-mini size so we can restore it when leaving mini mode.
    private var lastFullSize: OverlaySize = .medium
    @Published var overlaySize: OverlaySize = .medium {
        didSet {
            UserDefaults.standard.set(overlaySize.rawValue, forKey: "overlaySize")
            // Switching between mini ↔ full requires replacing the view, not just resizing
            if oldValue.isMini != overlaySize.isMini {
                switchOverlayMode?()
            } else {
                overlayWindow.resize(to: overlaySize)
            }
            if !overlaySize.isMini {
                lastFullSize = overlaySize
            }
        }
    }
    @Published var animationMode: AnimationMode = .karaoke {
        didSet { UserDefaults.standard.set(animationMode.rawValue, forKey: "animationMode") }
    }
    @Published var showRomanization: Bool = false {
        didSet { UserDefaults.standard.set(showRomanization, forKey: "showRomanization") }
    }
    @Published var showTranslation: Bool = false {
        didSet { UserDefaults.standard.set(showTranslation, forKey: "showTranslation") }
    }
    @Published var showSongSummary: Bool = true {
        didSet { UserDefaults.standard.set(showSongSummary, forKey: "showSongSummary") }
    }
    @Published var aiTranslationMode: AITranslationMode = .refine {
        didSet { UserDefaults.standard.set(aiTranslationMode.rawValue, forKey: "aiTranslationMode") }
    }
    @Published var targetLanguage: TranslationLanguage = .indonesian {
        didSet { UserDefaults.standard.set(targetLanguage.rawValue, forKey: "targetLanguage") }
    }
    let overlayWindow = LyricsOverlayWindow()

    /// Callback set by AppDelegate to rebuild the overlay when switching mini ↔ full.
    var switchOverlayMode: (() -> Void)?

    /// Switch to mini mode, or back to the last full size.
    func toggleMiniMode() {
        if overlaySize.isMini {
            overlaySize = lastFullSize
        } else {
            lastFullSize = overlaySize
            overlaySize = .mini
        }
    }

    /// Debounced opacity persistence — avoids disk I/O on every slider frame.
    func commitOpacity() {
        opacitySaveTask?.cancel()
        let value = overlayOpacity
        let task = DispatchWorkItem {
            UserDefaults.standard.set(value, forKey: "overlayOpacity")
        }
        opacitySaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    init() {
        let defaults = UserDefaults.standard

        if let saved = defaults.string(forKey: "overlaySize"),
           let size = OverlaySize(rawValue: saved) {
            self._overlaySize = Published(initialValue: size)
            if !size.isMini {
                self.lastFullSize = size
            }
        }
        if defaults.object(forKey: "overlayOpacity") != nil {
            self._overlayOpacity = Published(initialValue: defaults.double(forKey: "overlayOpacity"))
        }
        if defaults.object(forKey: "overlayAlwaysOnTop") != nil {
            self._alwaysOnTop = Published(initialValue: defaults.bool(forKey: "overlayAlwaysOnTop"))
        }
        if defaults.object(forKey: "overlayVisible") != nil {
            self._isVisible = Published(initialValue: defaults.bool(forKey: "overlayVisible"))
        }
        if let saved = defaults.string(forKey: "animationMode"),
           let mode = AnimationMode(rawValue: saved) {
            self._animationMode = Published(initialValue: mode)
        }
        if defaults.object(forKey: "showRomanization") != nil {
            self._showRomanization = Published(initialValue: defaults.bool(forKey: "showRomanization"))
        }
        if defaults.object(forKey: "showTranslation") != nil {
            self._showTranslation = Published(initialValue: defaults.bool(forKey: "showTranslation"))
        }
        if defaults.object(forKey: "showSongSummary") != nil {
            self._showSongSummary = Published(initialValue: defaults.bool(forKey: "showSongSummary"))
        }
        if let saved = defaults.string(forKey: "aiTranslationMode"),
           let mode = AITranslationMode(rawValue: saved) {
            self._aiTranslationMode = Published(initialValue: mode)
        }
        if let saved = defaults.string(forKey: "targetLanguage"),
           let lang = TranslationLanguage(rawValue: saved) {
            self._targetLanguage = Published(initialValue: lang)
        }
    }

    func show(lyricsManager: LyricsManager, playerManager: SpotifyPlayerManager) {
        if overlaySize.isMini {
            showMini(lyricsManager: lyricsManager, playerManager: playerManager)
        } else {
            showFull(lyricsManager: lyricsManager, playerManager: playerManager)
        }
    }

    private func showFull(lyricsManager: LyricsManager, playerManager: SpotifyPlayerManager) {
        let opacityBinding = Binding<Double>(
            get: { [weak self] in self?.overlayOpacity ?? 0.9 },
            set: { [weak self] in self?.overlayOpacity = $0 }
        )
        let animationModeBinding = Binding<AnimationMode>(
            get: { [weak self] in self?.animationMode ?? .karaoke },
            set: { [weak self] in self?.animationMode = $0 }
        )
        let overlaySizeBinding = Binding<OverlaySize>(
            get: { [weak self] in self?.overlaySize ?? .medium },
            set: { [weak self] in self?.overlaySize = $0 }
        )
        let view = LyricsOverlayView(
            lyricsManager: lyricsManager,
            playerManager: playerManager,
            backgroundOpacity: opacityBinding,
            animationMode: animationModeBinding,
            overlaySize: overlaySizeBinding,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        overlayWindow.show(with: view, size: overlaySize)
        isVisible = true
    }

    private func showMini(lyricsManager: LyricsManager, playerManager: SpotifyPlayerManager) {
        let opacityBinding = Binding<Double>(
            get: { [weak self] in self?.overlayOpacity ?? 0.9 },
            set: { [weak self] in self?.overlayOpacity = $0 }
        )
        let animationModeBinding = Binding<AnimationMode>(
            get: { [weak self] in self?.animationMode ?? .karaoke },
            set: { [weak self] in self?.animationMode = $0 }
        )
        let view = MiniOverlayView(
            lyricsManager: lyricsManager,
            playerManager: playerManager,
            backgroundOpacity: opacityBinding,
            animationMode: animationModeBinding,
            onSwitchToFull: { [weak self] in
                self?.toggleMiniMode()
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        overlayWindow.show(with: view, size: .mini)
        isVisible = true
    }

    /// Rebuild the overlay with the correct view type after switching mini ↔ full.
    func rebuildOverlay(lyricsManager: LyricsManager, playerManager: SpotifyPlayerManager) {
        if overlaySize.isMini {
            let opacityBinding = Binding<Double>(
                get: { [weak self] in self?.overlayOpacity ?? 0.9 },
                set: { [weak self] in self?.overlayOpacity = $0 }
            )
            let animationModeBinding = Binding<AnimationMode>(
                get: { [weak self] in self?.animationMode ?? .karaoke },
                set: { [weak self] in self?.animationMode = $0 }
            )
            let view = MiniOverlayView(
                lyricsManager: lyricsManager,
                playerManager: playerManager,
                backgroundOpacity: opacityBinding,
                animationMode: animationModeBinding,
                onSwitchToFull: { [weak self] in
                    self?.toggleMiniMode()
                },
                onClose: { [weak self] in
                    self?.hide()
                }
            )
            overlayWindow.replaceContent(with: view, size: .mini)
        } else {
            let opacityBinding = Binding<Double>(
                get: { [weak self] in self?.overlayOpacity ?? 0.9 },
                set: { [weak self] in self?.overlayOpacity = $0 }
            )
            let animationModeBinding = Binding<AnimationMode>(
                get: { [weak self] in self?.animationMode ?? .karaoke },
                set: { [weak self] in self?.animationMode = $0 }
            )
            let overlaySizeBinding = Binding<OverlaySize>(
                get: { [weak self] in self?.overlaySize ?? .medium },
                set: { [weak self] in self?.overlaySize = $0 }
            )
            let view = LyricsOverlayView(
                lyricsManager: lyricsManager,
                playerManager: playerManager,
                backgroundOpacity: opacityBinding,
                animationMode: animationModeBinding,
                overlaySize: overlaySizeBinding,
                onClose: { [weak self] in
                    self?.hide()
                }
            )
            overlayWindow.replaceContent(with: view, size: overlaySize)
        }
    }

    func toggle() {
        overlayWindow.toggle()
        isVisible = overlayWindow.isVisible
    }

    func hide() {
        overlayWindow.hide()
        isVisible = false
    }
}

/// Shared app state singleton for App Intents access.
@MainActor
final class AppState {
    static let shared = AppState()
    var playerManager: SpotifyPlayerManager?
    var lyricsManager: LyricsManager?
    var overlayController: OverlayController?
    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playerManager = SpotifyPlayerManager()
    let lyricsManager = LyricsManager()
    let overlayController = OverlayController()
    let soundClassifier = SoundClassifier()
    private var statusBarController: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    private var enrichmentDebounceTask: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Expose shared state for App Intents
        AppState.shared.playerManager = playerManager
        AppState.shared.lyricsManager = lyricsManager
        AppState.shared.overlayController = overlayController

        // Setup menu bar status item with scrolling track info
        statusBarController = StatusBarController(
            playerManager: playerManager,
            lyricsManager: lyricsManager,
            overlayController: overlayController,
            soundClassifier: soundClassifier
        )

        // Sync enrichment settings to LyricsManager
        lyricsManager.showRomanization = overlayController.showRomanization
        lyricsManager.showTranslation = overlayController.showTranslation
        lyricsManager.showSongSummary = overlayController.showSongSummary
        lyricsManager.aiTranslationMode = overlayController.aiTranslationMode
        lyricsManager.targetLanguage = overlayController.targetLanguage.rawValue

        // Sync enrichment settings and debounce refresh to avoid
        // multiple expensive enrichment calls when toggling quickly.
        overlayController.$showRomanization
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.lyricsManager.showRomanization = value
                self.scheduleEnrichmentRefresh()
            }
            .store(in: &cancellables)

        overlayController.$showTranslation
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.lyricsManager.showTranslation = value
                self.scheduleEnrichmentRefresh()
            }
            .store(in: &cancellables)

        overlayController.$targetLanguage
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.lyricsManager.targetLanguage = value.rawValue
                if self.lyricsManager.showTranslation {
                    self.scheduleEnrichmentRefresh()
                }
            }
            .store(in: &cancellables)

        overlayController.$showSongSummary
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.lyricsManager.showSongSummary = value
            }
            .store(in: &cancellables)

        overlayController.$aiTranslationMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (value: AITranslationMode) in
                guard let self else { return }
                self.lyricsManager.aiTranslationMode = value
                if self.lyricsManager.showTranslation {
                    self.scheduleEnrichmentRefresh()
                }
            }
            .store(in: &cancellables)

        // Wire up mini ↔ full switching callback
        overlayController.switchOverlayMode = { [weak self] in
            guard let self else { return }
            self.overlayController.rebuildOverlay(
                lyricsManager: self.lyricsManager,
                playerManager: self.playerManager
            )
        }

        playerManager.onTrackChanged = { [weak self] track in
            guard let self else { return }
            Task { @MainActor in
                self.lyricsManager.fetchLyrics(for: track)
            }
        }

        playerManager.startPolling()

        // Position tracking: fixed-interval fallback at 200ms. Exact line boundaries are hit by
        // the predictive timer (onPredictiveLineSwitch); this is only a coarse backstop and to
        // drive the instrumental-break countdown, so a lower rate is plenty. Skipped entirely
        // while not playing — the position is frozen, so there's nothing to recompute.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playerManager.playerState == .playing,
                      self.lyricsManager.hasLyrics else { return }
                let pos = self.playerManager.playbackPosition
                self.lyricsManager.updateCurrentLine(at: pos)
                self.lyricsManager.updateInstrumentalBreak(at: pos)
                self.scheduleNextLine()
            }
        }

        // Predictive line switching: fires precisely at next line's timestamp
        playerManager.onPredictiveLineSwitch = { [weak self] position in
            guard let self else { return }
            self.lyricsManager.updateCurrentLine(at: position)
            self.lyricsManager.updateInstrumentalBreak(at: position)
            self.scheduleNextLine()
        }

        // Show overlay (respect saved visibility)
        overlayController.show(lyricsManager: lyricsManager, playerManager: playerManager)
        if !overlayController.isVisible {
            overlayController.hide()
        }

        // Auto-hide overlay when Spotify closes, re-show when it opens
        playerManager.$isSpotifyRunning
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                if running {
                    if self.overlayController.isVisible {
                        self.overlayController.overlayWindow.showIfCreated()
                    }
                } else {
                    // Keep the floating lyrics window on screen. The overlay
                    // itself already displays a “Waiting for Spotify…” state.
                    // It should only disappear when the user explicitly closes
                    // it or quits the app.
                    if self.overlayController.isVisible {
                        self.overlayController.overlayWindow.showIfCreated()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Coalesces rapid enrichment setting changes into a single refresh.
    private func scheduleEnrichmentRefresh() {
        enrichmentDebounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.lyricsManager.refreshEnrichment()
        }
        enrichmentDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func scheduleNextLine() {
        if let nextTimestamp = lyricsManager.nextLineTimestamp {
            playerManager.scheduleNextLineSwitch(at: nextTimestamp)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        playerManager.stopPolling()
        overlayController.overlayWindow.close()
    }
}

// MARK: - App/StatusBarController.swift

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(playerManager: SpotifyPlayerManager,
         lyricsManager: LyricsManager,
         overlayController: OverlayController,
         soundClassifier: SoundClassifier) {

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 460)
        popover.behavior = .transient
        popover.animates = true

        let hostingController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(playerManager)
                .environmentObject(lyricsManager)
                .environmentObject(overlayController)
                .environmentObject(soundClassifier)
        )
        popover.contentViewController = hostingController

        // Setup button
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "SpotifyLyrics")
            button.image?.isTemplate = true
            button.action = #selector(handleButtonClick(_:))
            button.target = self
        }
    }

    @objc private func handleButtonClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            removeMonitors()
        } else {
            // Activate the app before showing the popover so its SwiftUI controls
            // (toggles, menus, pickers, etc.) receive the first click immediately.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // NSPopover creates its own window. Make that window key after the
            // popover has been attached so the controls are immediately active.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.popover.contentViewController?.view.window?.makeKey()
            }

            addMonitors()
        }
    }

    private func addMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.removeMonitors()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.popover.isShown {
                if let button = self.statusItem.button, event.window == button.window {
                    return event
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: - App/Intents/CurrentSongIntent.swift

struct CurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Returns the current track info and active lyric line.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let pm = AppState.shared.playerManager else {
            throw IntentError.appNotReady
        }

        guard let track = pm.currentTrack else {
            return .result(value: "Nothing is playing.")
        }

        var result = "\(track.title) by \(track.artist)"

        if let lm = AppState.shared.lyricsManager,
           lm.hasLyrics,
           lm.currentLineIndex < lm.currentLines.count {
            let line = lm.currentLines[lm.currentLineIndex]
            result += "\n\"\(line.text)\""
        }

        return .result(value: result)
    }
}

// MARK: - App/Intents/IntentError.swift

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "SpotifyLyrics is not ready. Please launch the app first."
        }
    }
}

// MARK: - App/Intents/SetOverlayModeIntent.swift

/// AppEnum wrapper for OverlaySize.
enum OverlaySizeEnum: String, AppEnum {
    case mini, small, medium, large, squareAlbum

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Overlay Size")
    static var caseDisplayRepresentations: [OverlaySizeEnum: DisplayRepresentation] = [
        .mini: "Mini",
        .small: "Small",
        .medium: "Medium",
        .large: "Large",
        .squareAlbum: "Square Album",
    ]

    var toOverlaySize: OverlaySize {
        OverlaySize(rawValue: rawValue) ?? .medium
    }
}

/// AppEnum wrapper for AnimationMode.
enum AnimationModeEnum: String, AppEnum {
    case karaoke, smooth, spring, glow

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Animation Mode")
    static var caseDisplayRepresentations: [AnimationModeEnum: DisplayRepresentation] = [
        .karaoke: "Karaoke",
        .smooth: "Smooth",
        .spring: "Spring",
        .glow: "Glow",
    ]

    var toAnimationMode: AnimationMode {
        AnimationMode(rawValue: rawValue) ?? .karaoke
    }
}

struct SetOverlayModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Overlay Mode"
    static var description = IntentDescription("Change the overlay size and/or animation mode.")

    @Parameter(title: "Size")
    var size: OverlaySizeEnum?

    @Parameter(title: "Animation")
    var animation: AnimationModeEnum?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = AppState.shared.overlayController else {
            throw IntentError.appNotReady
        }

        if let size {
            controller.overlaySize = size.toOverlaySize
        }
        if let animation {
            controller.animationMode = animation.toAnimationMode
        }

        return .result()
    }
}

// MARK: - App/Intents/ShowLyricsIntent.swift

enum OverlayAction: String, AppEnum {
    case show, hide, toggle

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Overlay Action")
    static var caseDisplayRepresentations: [OverlayAction: DisplayRepresentation] = [
        .show: "Show",
        .hide: "Hide",
        .toggle: "Toggle",
    ]
}

struct ShowLyricsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Lyrics"
    static var description = IntentDescription("Show, hide, or toggle the lyrics overlay.")

    @Parameter(title: "Action", default: .toggle)
    var action: OverlayAction

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = AppState.shared.overlayController else {
            throw IntentError.appNotReady
        }

        switch action {
        case .show:
            if !controller.isVisible,
               let lm = AppState.shared.lyricsManager,
               let pm = AppState.shared.playerManager {
                controller.show(lyricsManager: lm, playerManager: pm)
            }
        case .hide:
            controller.hide()
        case .toggle:
            if controller.isVisible {
                controller.hide()
            } else if let lm = AppState.shared.lyricsManager,
                      let pm = AppState.shared.playerManager {
                controller.show(lyricsManager: lm, playerManager: pm)
            }
        }

        return .result()
    }
}

// MARK: - App/Intents/SpotifyLyricsShortcuts.swift

struct SpotifyLyricsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowLyricsIntent(),
            phrases: [
                "Show lyrics in \(.applicationName)",
                "Toggle lyrics in \(.applicationName)",
                "Hide lyrics in \(.applicationName)",
            ],
            shortTitle: "Show Lyrics",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: CurrentSongIntent(),
            phrases: [
                "What song is playing in \(.applicationName)",
                "Current lyrics in \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.quarternote.3"
        )
        AppShortcut(
            intent: ToggleTranslationIntent(),
            phrases: [
                "Translate lyrics in \(.applicationName)",
            ],
            shortTitle: "Toggle Translation",
            systemImageName: "character.book.closed"
        )
    }
}

// MARK: - App/Intents/ToggleTranslationIntent.swift

/// AppEnum wrapper for TranslationLanguage so Shortcuts can display a picker.
enum TranslationLanguageEnum: String, AppEnum {
    case indonesian = "id"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case thai = "th"
    case vietnamese = "vi"
    case arabic = "ar"
    case russian = "ru"
    case hindi = "hi"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Translation Language")
    static var caseDisplayRepresentations: [TranslationLanguageEnum: DisplayRepresentation] = [
        .indonesian: "Indonesia",
        .english: "English",
        .japanese: "日本語",
        .korean: "한국어",
        .chinese: "中文",
        .spanish: "Español",
        .french: "Français",
        .german: "Deutsch",
        .portuguese: "Português",
        .thai: "ไทย",
        .vietnamese: "Tiếng Việt",
        .arabic: "العربية",
        .russian: "Русский",
        .hindi: "हिन्दी",
    ]

    var toTranslationLanguage: TranslationLanguage {
        TranslationLanguage(rawValue: rawValue) ?? .english
    }
}

struct ToggleTranslationIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Translation"
    static var description = IntentDescription("Enable or disable lyrics translation with optional language choice.")

    @Parameter(title: "Enabled")
    var enabled: Bool

    @Parameter(title: "Language")
    var language: TranslationLanguageEnum?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = AppState.shared.overlayController else {
            throw IntentError.appNotReady
        }

        controller.showTranslation = enabled
        if let language {
            controller.targetLanguage = language.toTranslationLanguage
        }

        return .result()
    }
}


// MARK: - Flattened single-file application entry point

SpotifyLyricsApp.main()
