import Foundation

struct AppUser: Identifiable {
    let id: String
    var name: String
    var allowFriendNudges: Bool
    var quietHoursEnabled: Bool
    var quietStartHour: Int
    var quietEndHour: Int
}

struct Friendship: Identifiable {
    let id: String
    var users: [String]
    var status: String
    var requesterId: String
    var createdAt: Date
}

struct SharedGoal: Identifiable {
    let id: String
    var ownerId: String
    var title: String
    var colorHex: String
    var sharedWith: [String]
    var createdAt: Date
}
