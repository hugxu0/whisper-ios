import CoreGraphics
import Foundation

// 和服务端接口一一对应的数据结构。时间都是毫秒时间戳。

struct ProfileTag: Codable, Identifiable, Hashable {
    let id: String
    var text: String
    var createdBy: String
    var likes: Int
    var colorIndex: Int
    var createdAt: Double
}

struct User: Codable, Identifiable, Hashable {
    let id: String
    var username: String
    var displayName: String
    var kind: String
    var avatarMediaId: String?
    var bio: String
    var status: String
    var tags: [ProfileTag]

    var isBot: Bool { kind == "bot" }
}

struct Presence: Codable, Hashable {
    let userId: String
    var online: Bool
    var lastSeenAt: Double?
}

struct MessageMedia: Codable, Hashable {
    let id: String
    let kind: String
    let mime: String
    let size: Int
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let name: String?
    let hasThumb: Bool

    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return kind == "video" ? 16.0 / 9.0 : 4.0 / 3.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// 消息的附加数据。不同类型用到不同字段，都可以缺省。
struct MessagePayload: Codable, Hashable {
    var media: [MessageMedia]?
    var mentions: [String]?
    var markdown: Bool?
    var legacyType: String?
    var missing: Bool?
    var interaction: String?
    var waveform: [Double]?
    var transcript: String?
    var stickerId: String?
    // 卡牌消息
    var playId: String?
    var key: String?
    var rarity: String?
    var title: String?
    var summary: String?
    var icon: String?
    var category: String?
    var effect: String?
    var durationMs: Int?
    var status: String?
    var fromUser: String?
    var toUser: String?
    var startedAt: Double?
    var endsAt: Double?
    var copiedTitle: String?
    var targetPlayId: String?
    // 提醒消息；大橘的确认卡片（status 为 pending / done / cancelled）
    var planId: String?
    var body: String?
    var ownerId: String?
    var requesterId: String?
    var handledBy: String?
    var plan: ConfirmPlan?
    // 链接预览（服务端抓好后补上）
    var link: LinkPreview?

    static let empty = MessagePayload()
}

/// 大橘提议建的计划（确认卡片里）
struct ConfirmPlan: Codable, Hashable {
    let kind: String
}

struct LinkPreview: Codable, Hashable {
    let url: String
    let title: String
    let description: String
    let siteName: String
    let imageMediaId: String?
}

struct ReplyPreview: Codable, Hashable {
    let id: String
    let senderId: String
    let kind: String
    let text: String
    let recalled: Bool
}

struct Reaction: Codable, Hashable {
    let userId: String
    let emoji: String
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String
    let seq: Int
    let senderId: String
    let kind: String
    var text: String
    var payload: MessagePayload
    var replyTo: ReplyPreview?
    var reactions: [Reaction]
    let createdAt: Double
    var editedAt: Double?
    var recalledAt: Double?

    var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var isRecalled: Bool { recalledAt != nil }
    var media: [MessageMedia] { payload.media ?? [] }
}

struct ReadState: Codable, Hashable {
    let userId: String
    var seq: Int
}

struct ConversationSummary: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let ownerId: String?
    var lastMessage: Message?
    var unreadCount: Int
    var readStates: [ReadState]
}

struct Sticker: Codable, Identifiable, Hashable {
    let id: String
    let media: MessageMedia
    let createdAt: Double
    var usedAt: Double?
}

struct Features: Codable, Hashable {
    var daju: Bool
    var transcribe: Bool
}

struct SettingsBag: Codable, Hashable {
    var shared: [String: JSONValue]
    var mine: [String: JSONValue]
}

struct Bootstrap: Codable {
    let me: User
    let users: [User]
    let presence: [Presence]
    let conversations: [ConversationSummary]
    let settings: SettingsBag
    let stickers: [Sticker]
    let latestSeq: Int
    let serverTime: Double
    let features: Features
}

struct MessagePage: Codable {
    let messages: [Message]
    let hasOlder: Bool
    let hasNewer: Bool
}

struct EventRecord: Codable {
    let seq: Int
    let kind: String
    let payload: JSONValue
    let createdAt: Double
}

struct EventPage: Codable {
    let events: [EventRecord]
    let hasMore: Bool
    let latestSeq: Int
}

struct MediaInfo: Codable, Hashable {
    let id: String
    let kind: String
    let mime: String
    let size: Int
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let name: String?
    let note: String?
    let hasThumb: Bool
    let createdAt: Double

    var asMessageMedia: MessageMedia {
        MessageMedia(id: id, kind: kind, mime: mime, size: size, width: width, height: height, durationMs: durationMs, name: name, hasThumb: hasThumb)
    }
}

struct LoginResponse: Codable {
    let token: String
    let sessionId: String
    let user: User
}

struct GalleryItem: Codable, Hashable, Identifiable {
    let messageId: String
    let seq: Int
    let senderId: String
    let createdAt: Double
    let media: MessageMedia
    var id: String { "\(messageId)-\(media.id)" }
}

struct GalleryPage: Codable {
    let items: [GalleryItem]
    let hasMore: Bool
    let nextBefore: Int?
}

struct ActivityDay: Codable, Hashable {
    let day: String
    let count: Int
}

struct SessionInfo: Codable, Identifiable, Hashable {
    let id: String
    let deviceName: String
    let platform: String
    let appVersion: String
    let createdAt: Double
    let lastSeenAt: Double
    let current: Bool
}

struct PushTarget: Codable, Identifiable, Hashable {
    let id: String
    let server: String
    let keyHint: String
    var label: String
    var enabled: Bool
    let createdAt: Double
}

// MARK: - 我们

struct Anniversary: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var date: String
    var kind: String
    var emoji: String
    var pinned: Bool
    let createdBy: String
    let createdAt: Double
    var updatedAt: Double
}

struct PlanItem: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var done: Bool
}

struct Plan: Codable, Identifiable, Hashable {
    let id: String
    var kind: String
    var scope: String
    let ownerId: String
    var title: String
    var body: String
    var items: [PlanItem]
    var remindAt: Double?
    var repeatRule: String
    var notify: String
    var pinned: Bool
    var doneAt: Double?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, scope, ownerId, title, body, items, remindAt, notify, pinned, doneAt, createdAt, updatedAt
        case repeatRule = "repeat"
    }
}

struct Album: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var note: String?
    var coverMediaId: String?
    var count: Int
    var postCount: Int?
    var lastPostAt: Double?
    var previewMediaIds: [String]
    let createdBy: String
    let createdAt: Double
    var updatedAt: Double
}

/// 相册里的一条动态：同一次发表的几张照片视频和一段文案
struct AlbumPost: Codable, Identifiable, Hashable {
    let id: String
    var caption: String
    let addedBy: String
    let addedAt: Double
    let media: [MessageMedia]
}

struct AlbumItem: Codable, Identifiable, Hashable {
    let media: MessageMedia
    var note: String
    let addedBy: String
    let addedAt: Double
    var id: String { media.id }
}

struct Wish: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var note: String
    var photoMediaId: String?
    var doneAt: Double?
    let createdBy: String
    let createdAt: Double
    var updatedAt: Double
}

struct TimeCapsule: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    let openAt: Double
    let opened: Bool
    let body: String?
    let createdBy: String
    let createdAt: Double
}

struct Milestone: Codable, Hashable {
    let kind: String
    let value: Int
    let title: String
    let date: String?
    let reached: Bool
}

struct Together: Codable {
    let togetherSince: String?
    let daysTogether: Int?
    let messageCount: Int
    let mediaCount: Int
    let firstMessageAt: Double?
    let milestones: [Milestone]
}

struct OnThisDayYear: Codable, Identifiable {
    let year: Int
    let date: String
    let messageCount: Int
    let messages: [Message]
    let media: [OnThisDayMedia]
    var id: Int { year }
}

struct OnThisDayMedia: Codable, Hashable {
    let messageId: String
    let media: MessageMedia
}

struct OnThisDay: Codable {
    let date: String
    let years: [OnThisDayYear]
}

struct EmojiCount: Codable, Hashable {
    let emoji: String
    let count: Int
}

struct StickerCount: Codable, Hashable {
    let media: MessageMedia
    let count: Int
}

struct MonthCount: Codable, Hashable {
    let month: String
    let count: Int
}

struct StreakInfo: Codable {
    struct Longest: Codable {
        let days: Int
        let from: String?
        let to: String?
    }
    let longest: Longest
    let current: Int
}

struct Stats: Codable {
    let year: Int?
    let total: Int
    let bySender: [String: Int]
    let byMonth: [MonthCount]
    let byHour: [Int]
    let byWeekday: [Int]
    let activeDays: Int
    let busiestDay: ActivityDay?
    let streaks: StreakInfo
    let topEmojis: [EmojiCount]
    let topStickers: [StickerCount]
    let firstMessage: Message?
}

// MARK: - 大橘

struct PetOutfit: Codable, Hashable, Identifiable {
    let key: String
    let title: String
    let level: Int
    let unlocked: Bool
    var id: String { key }
}

struct PetActionRecord: Codable, Hashable {
    let userId: String
    let action: String
    let at: Double
}

struct PetLimit: Codable, Hashable {
    let used: Int
    let max: Int
}

struct Pet: Codable, Hashable {
    let name: String
    let level: Int
    let xp: Int
    let xpToNext: Int
    let stage: String
    let stageLabel: String
    let satiety: Int
    let cleanliness: Int
    let mood: Int
    let energy: Int
    let sleeping: Bool
    let sleepingSince: Double?
    let status: String
    let outfit: String?
    let outfits: [PetOutfit]
    let recent: [PetActionRecord]
    let limits: [String: PetLimit]
}

struct PetActionResponse: Codable {
    let pet: Pet
    let reply: String
    let leveledUp: Bool
}

struct CardDefinition: Codable, Hashable {
    let key: String
    let title: String
    let category: String
    let rarity: String
    let summary: String
    let icon: String
    let effect: String
    let durationMs: Int?
}

struct Card: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let rarity: String
    let title: String
    let summary: String
    let icon: String
    let category: String
    let effect: String
    let durationMs: Int?
    let source: String
    let giftedFrom: String?
    let obtainedAt: Double
}

struct CardPlay: Codable, Identifiable, Hashable {
    let id: String
    let cardId: String
    let fromUser: String
    let toUser: String
    let key: String
    let rarity: String
    let title: String
    let summary: String
    let icon: String
    let effect: String
    let status: String
    let durationMs: Int?
    let startedAt: Double?
    let endsAt: Double?
    let messageId: String?
    let createdAt: Double
}

struct CardCollectionEntry: Codable, Hashable {
    let key: String
    let rarity: String
}

struct CardPity: Codable, Hashable {
    let sinceLegendary: Int
    let guaranteeAt: Int
}

/// 今天翻过的一张牌：没翻中时 card 为空
struct CardFlip: Codable, Hashable {
    let slot: Int
    let card: Card?
}

struct CardDrawResult: Codable {
    let slot: Int
    let card: Card?
    let flipsLeft: Int
}

struct CardOverview: Codable {
    let cards: [Card]
    let partnerCards: [Card]
    var flipsPerDay: Int?
    var todayFlips: [CardFlip]?
    let drawnToday: Bool
    let todayCard: Card?
    let pity: CardPity
    let plays: [CardPlay]
    let collection: [CardCollectionEntry]
    let catalog: [CardDefinition]
}

struct DajuMemory: Codable, Identifiable, Hashable {
    let id: String
    var content: String
    /// profile 画像 / state 近况 / event 往事
    var kind: String
    /// 说的是谁：用户 id 或 both
    var subject: String
    var topic: String
    var eventDate: String?
    /// 近况的截止时间（那天结束，毫秒）
    var expiresAt: Double?
    /// 不为空表示只有这个人知道（来自私聊）
    var ownerId: String?
    let source: String
    let createdAt: Double
    var updatedAt: Double

    /// 近况有效到哪天
    var untilDate: Date? { expiresAt.map { Date(timeIntervalSince1970: ($0 - 1) / 1000) } }
}

struct DajuDiary: Codable, Identifiable, Hashable {
    let day: String
    let content: String
    let createdAt: Double
    var id: String { day }
}

struct DajuLogEntry: Codable, Hashable {
    let at: Double
    let type: String
    let detail: String
}

struct DajuRun: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String
    let requesterId: String
    let status: String
    let question: String
    let log: [DajuLogEntry]
    let error: String?
    let createdAt: Double
    let finishedAt: Double?
}

// MARK: - 任意 JSON

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }

    /// 转成具体类型（事件 payload 里嵌着的消息、用户等）
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
