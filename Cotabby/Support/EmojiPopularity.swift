import Foundation

/// File overview:
/// A hand-curated popularity prior for emoji, keyed by canonical gemoji alias and ordered most-used
/// first. Two consumers:
///
/// 1. `EmojiMatcher` uses `rank(forAlias:)` as a late tiebreak so that, among results of equal
///    relevance, the emoji people actually use float up (e.g. ❤️ before a obscure heart variant).
/// 2. The inline picker shows `starterAliases` on a bare `:` for a user with no personal history yet,
///    so the very first `:` is useful instead of empty.
///
/// Why hard-coded: the bundled gemoji dataset carries no frequency or popularity signal, and its file
/// order is roughly age-based, not usage-based. A curated list is the cheapest way to encode "what
/// people reach for" until per-user history (see `EmojiUsageStore`) takes over. Aliases that are not
/// present in the active catalog simply never rank or resolve, so a stale entry here is harmless.
nonisolated enum EmojiPopularity {
    /// Ranked aliases, most popular first. The index is the rank, so order is the contract; keep the
    /// highest-traffic reactions at the top. Grouped only for readability.
    static let ordered: [String] = [
        // Core reactions
        "joy", "heart", "sob", "pray", "thumbsup", "fire", "ok_hand", "tada", "eyes", "heart_eyes",
        "smile", "smirk", "grin", "sweat_smile", "rofl", "blush", "clap", "raised_hands", "wave", "100",
        "thinking", "cry", "wink", "sunglasses", "sparkles", "rocket", "skull", "pensive", "weary", "muscle",
        "thumbsdown", "facepalm", "shrug", "see_no_evil", "smiley", "laughing", "kissing_heart", "yum", "smiling_imp",
        // Faces
        "slightly_smiling_face", "upside_down_face", "relaxed", "relieved", "neutral_face", "expressionless",
        "unamused", "roll_eyes", "flushed", "pleading_face", "disappointed", "tired_face", "sleepy",
        "yawning_face", "scream", "fearful", "cold_sweat", "disappointed_relieved", "sweat", "hushed",
        "astonished", "dizzy_face", "open_mouth", "grimacing", "confused", "worried", "frowning_face",
        "persevere", "confounded", "triumph", "angry", "rage", "innocent", "nerd_face", "partying_face",
        "woozy_face", "zany_face", "hugs", "shushing_face", "lying_face", "raised_eyebrow", "star_struck",
        "stuck_out_tongue", "stuck_out_tongue_winking_eye", "drooling_face", "sleeping", "mask", "hot_face",
        "cold_face", "sneezing_face", "nauseated_face", "money_mouth_face", "cowboy_hat_face", "smiling_face_with_tear",
        // Hands and people
        "point_up", "point_down", "point_left", "point_right", "v", "crossed_fingers", "fist", "facepunch",
        "handshake", "writing_hand", "nail_care", "open_hands", "raised_hand", "vulcan_salute", "call_me_hand",
        "metal", "middle_finger", "ok_woman", "raising_hand", "tipping_hand_person",
        // Hearts and symbols
        "orange_heart", "yellow_heart", "green_heart", "blue_heart", "purple_heart", "black_heart", "white_heart",
        "broken_heart", "two_hearts", "revolving_hearts", "heartbeat", "heartpulse", "sparkling_heart", "cupid",
        "gift_heart", "anger", "boom", "dizzy", "sweat_drops", "dash", "star", "star2", "zzz", "exclamation",
        "question", "bangbang", "white_check_mark", "heavy_check_mark", "x", "negative_squared_cross_mark",
        "warning", "no_entry", "recycle", "droplet", "zap", "snowflake", "rainbow",
        // Celebration, food, drink
        "confetti_ball", "balloon", "gift", "birthday", "cake", "champagne", "clinking_glasses", "beers", "beer",
        "wine_glass", "cocktail", "coffee", "pizza", "hamburger", "fries", "hotdog", "taco", "sushi", "ramen",
        "doughnut", "cookie", "ice_cream", "lollipop", "candy", "chocolate_bar", "popcorn", "apple", "banana",
        "watermelon", "strawberry", "cherries", "peach", "eggplant", "hot_pepper", "avocado", "bread",
        // Animals and nature
        "dog", "cat", "mouse", "rabbit", "fox_face", "bear", "panda_face", "koala", "tiger", "lion", "cow", "pig",
        "frog", "monkey", "monkey_face", "hear_no_evil", "speak_no_evil", "chicken", "penguin", "bird",
        "baby_chick", "duck", "owl", "wolf", "horse", "unicorn", "bee", "bug", "butterfly", "snail", "turtle",
        "snake", "octopus", "whale", "dolphin", "fish", "shark", "elephant", "giraffe", "hedgehog", "sloth",
        "sheep", "deer", "peacock", "parrot", "flamingo", "seedling", "herb", "four_leaf_clover", "evergreen_tree",
        "palm_tree", "cactus", "christmas_tree", "maple_leaf", "fallen_leaf", "leaves", "mushroom", "sunflower",
        "rose", "tulip", "cherry_blossom", "bouquet", "sunny", "cloud", "ocean", "full_moon", "crescent_moon",
        "earth_americas",
        // Objects, travel, tech
        "poop", "ghost", "alien", "robot", "clown_face", "jack_o_lantern", "gem", "crown", "ring", "lipstick",
        "tophat", "mortar_board", "dress", "shirt", "trophy", "medal_sports", "soccer", "basketball", "football",
        "baseball", "tennis", "volleyball", "8ball", "dart", "bowling", "video_game", "game_die", "musical_note",
        "notes", "microphone", "headphones", "guitar", "clapper", "art", "bulb", "flashlight", "computer",
        "keyboard", "iphone", "camera", "movie_camera", "tv", "telephone", "email", "envelope", "package",
        "memo", "pencil2", "paperclip", "scissors", "pushpin", "round_pushpin", "calendar", "bar_chart",
        "chart_with_upwards_trend", "clipboard", "books", "book", "newspaper", "mag", "lock", "unlock", "key",
        "hammer", "wrench", "gear", "link", "moneybag", "dollar", "credit_card", "bell", "loudspeaker", "mega",
        "speech_balloon", "thought_balloon", "airplane", "car", "taxi", "bus", "train", "bike", "ship",
        "rotating_light", "house", "office", "hospital", "school", "mountain", "beach_umbrella"
    ]

    /// Alias -> rank lookup. Lower is more popular. Built once from `ordered`; an alias not present
    /// returns `notRanked` so the matcher's tiebreak places it after every curated-popular emoji.
    static let notRanked = Int.max

    private static let rankByAlias: [String: Int] = {
        var map: [String: Int] = [:]
        map.reserveCapacity(ordered.count)
        // First occurrence wins, so a duplicate left in `ordered` by accident keeps its better rank.
        for (index, alias) in ordered.enumerated() where map[alias] == nil {
            map[alias] = index
        }
        return map
    }()

    /// The popularity rank of an alias, or `notRanked` when it is not in the curated list.
    static func rank(forAlias alias: String) -> Int {
        rankByAlias[alias.lowercased()] ?? notRanked
    }

    /// Aliases to seed the bare-`:` panel for a user with no personal history, in popularity order.
    static func starterAliases(limit: Int) -> [String] {
        Array(ordered.prefix(max(0, limit)))
    }
}
