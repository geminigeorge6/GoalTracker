import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class FirebaseManager: ObservableObject {
    static let shared = FirebaseManager()

    @Published var uid: String = ""
    @Published var authEmail: String = ""
    @Published var isAnonymousUser: Bool = true
    @Published var myProfile: AppUser?
    @Published var friends: [AppUser] = []
    @Published var incomingRequests: [Friendship] = []
    @Published var myGoals: [SharedGoal] = []
    @Published var sharedGoals: [SharedGoal] = []

    private let db = Firestore.firestore()
    private var listeners: [ListenerRegistration] = []

    private init() {}

    // MARK: - Auth

    func signInIfNeeded(displayName: String) async throws {
        if let current = Auth.auth().currentUser {
            uid = current.uid
            try await upsertUserDoc(name: displayName)
            refreshAuthState()
            startListeners()
            return
        }

        let result = try await Auth.auth().signInAnonymously()
        uid = result.user.uid
        try await upsertUserDoc(name: displayName)
        refreshAuthState()
        startListeners()
    }

    func refreshAuthState() {
        let user = Auth.auth().currentUser
        authEmail = user?.email ?? ""
        isAnonymousUser = user?.isAnonymous ?? true
    }

    func signUpOrLink(email: String, password: String) async throws {
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)

        if let user = Auth.auth().currentUser, user.isAnonymous {
            _ = try await user.link(with: credential)
        } else if Auth.auth().currentUser == nil {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
        } else {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        }

        uid = Auth.auth().currentUser?.uid ?? ""
        refreshAuthState()
        startListeners()
    }

    func signIn(email: String, password: String) async throws {
        _ = try await Auth.auth().signIn(withEmail: email, password: password)
        uid = Auth.auth().currentUser?.uid ?? ""
        refreshAuthState()
        startListeners()
    }

    func signOut() throws {
        try Auth.auth().signOut()
        uid = ""
        authEmail = ""
        isAnonymousUser = true
        myProfile = nil
        friends = []
        incomingRequests = []
        myGoals = []
        sharedGoals = []
        stopListeners()
    }

    // MARK: - User/Profile

    func upsertUserDoc(name: String) async throws {
        let ref = db.collection("users").document(uid)
        let snap = try await ref.getDocument()

        if snap.exists {
            let d = snap.data() ?? [:]
            myProfile = AppUser(
                id: uid,
                name: d["name"] as? String ?? name,
                allowFriendNudges: d["allowFriendNudges"] as? Bool ?? true,
                quietHoursEnabled: d["quietHoursEnabled"] as? Bool ?? false,
                quietStartHour: d["quietStartHour"] as? Int ?? 22,
                quietEndHour: d["quietEndHour"] as? Int ?? 8
            )
        } else {
            try await ref.setData([
                "name": name,
                "allowFriendNudges": true,
                "quietHoursEnabled": false,
                "quietStartHour": 22,
                "quietEndHour": 8,
                "createdAt": FieldValue.serverTimestamp()
            ])
            myProfile = AppUser(
                id: uid,
                name: name,
                allowFriendNudges: true,
                quietHoursEnabled: false,
                quietStartHour: 22,
                quietEndHour: 8
            )
        }
    }

    func updateNudgeSettings(allow: Bool, quietEnabled: Bool, quietStart: Int, quietEnd: Int) async throws {
        try await db.collection("users").document(uid).updateData([
            "allowFriendNudges": allow,
            "quietHoursEnabled": quietEnabled,
            "quietStartHour": quietStart,
            "quietEndHour": quietEnd
        ])
        myProfile?.allowFriendNudges = allow
        myProfile?.quietHoursEnabled = quietEnabled
        myProfile?.quietStartHour = quietStart
        myProfile?.quietEndHour = quietEnd
    }

    func updateFCMToken(_ token: String) async throws {
        guard !uid.isEmpty else { return }
        try await db.collection("users").document(uid).setData([
            "fcmTokens": FieldValue.arrayUnion([token])
        ], merge: true)
    }

    // MARK: - Goals / Checkins

    func createGoal(title: String, colorHex: String = "#3B82F6", sharedWith: [String] = []) async throws {
        let ref = db.collection("goals").document()
        try await ref.setData([
            "ownerId": uid,
            "title": title,
            "colorHex": colorHex,
            "sharedWith": sharedWith,
            "createdAt": FieldValue.serverTimestamp()
        ])
    }

    func toggleCheckin(goalId: String, dateKey: String, done: Bool) async throws {
        try await db.collection("goals").document(goalId)
            .collection("checkins").document(dateKey)
            .setData([
                "done": done,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    func shareGoal(goalId: String, with friendUid: String) async throws {
        try await db.collection("goals").document(goalId).updateData([
            "sharedWith": FieldValue.arrayUnion([friendUid])
        ])
    }

    // MARK: - Friends

    func sendFriendRequest(to friendUid: String) async throws {
        let id = [uid, friendUid].sorted().joined(separator: "_")
        try await db.collection("friendships").document(id).setData([
            "users": [uid, friendUid],
            "status": "pending",
            "requesterId": uid,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func acceptFriendRequest(_ friendshipId: String) async throws {
        try await db.collection("friendships").document(friendshipId).updateData([
            "status": "accepted"
        ])
    }

    // MARK: - Nudge

    func sendNudge(to friendUid: String, goalId: String, dateKey: String) async throws {
        try await db.collection("nudges").addDocument(data: [
            "fromUid": uid,
            "toUid": friendUid,
            "goalId": goalId,
            "dateKey": dateKey,
            "createdAt": FieldValue.serverTimestamp()
        ])
    }

    // MARK: - Listeners

    private func startListeners() {
        stopListeners()
        guard !uid.isEmpty else { return }

        let pending = db.collection("friendships")
            .whereField("users", arrayContains: uid)
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                self.incomingRequests = docs.compactMap { d in
                    let data = d.data()
                    let requester = data["requesterId"] as? String ?? ""
                    guard requester != self.uid else { return nil }
                    return Friendship(
                        id: d.documentID,
                        users: data["users"] as? [String] ?? [],
                        status: data["status"] as? String ?? "pending",
                        requesterId: requester,
                        createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    )
                }
            }

        let accepted = db.collection("friendships")
            .whereField("users", arrayContains: uid)
            .whereField("status", isEqualTo: "accepted")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                let friendIDs: [String] = docs.compactMap {
                    let users = $0.data()["users"] as? [String] ?? []
                    return users.first(where: { $0 != self.uid })
                }

                Task {
                    var list: [AppUser] = []
                    for fid in friendIDs {
                        let s = try? await self.db.collection("users").document(fid).getDocument()
                        guard let d = s?.data() else { continue }
                        list.append(AppUser(
                            id: fid,
                            name: d["name"] as? String ?? "Friend",
                            allowFriendNudges: d["allowFriendNudges"] as? Bool ?? true,
                            quietHoursEnabled: d["quietHoursEnabled"] as? Bool ?? false,
                            quietStartHour: d["quietStartHour"] as? Int ?? 22,
                            quietEndHour: d["quietEndHour"] as? Int ?? 8
                        ))
                    }
                    self.friends = list
                }
            }

        let mine = db.collection("goals")
            .whereField("ownerId", isEqualTo: uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                self.myGoals = docs.map { d in
                    let data = d.data()
                    return SharedGoal(
                        id: d.documentID,
                        ownerId: data["ownerId"] as? String ?? "",
                        title: data["title"] as? String ?? "",
                        colorHex: data["colorHex"] as? String ?? "#3B82F6",
                        sharedWith: data["sharedWith"] as? [String] ?? [],
                        createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    )
                }
            }

        let shared = db.collection("goals")
            .whereField("sharedWith", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                self.sharedGoals = docs.map { d in
                    let data = d.data()
                    return SharedGoal(
                        id: d.documentID,
                        ownerId: data["ownerId"] as? String ?? "",
                        title: data["title"] as? String ?? "",
                        colorHex: data["colorHex"] as? String ?? "#3B82F6",
                        sharedWith: data["sharedWith"] as? [String] ?? [],
                        createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    )
                }
            }

        listeners = [pending, accepted, mine, shared]
    }

    private func stopListeners() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }
}

