import Foundation

/// Persisted identity metadata shared by canonical Meeting items and legacy Todo ownership.
struct MeetingItemMetadata: Codable {
        let v: Int
        let id: String
        let owner: String?
        var review: String
        let origin: String
        let legacyID: String?
        let citations: [MeetingOutcomeCitation]

        enum CodingKeys: String, CodingKey { case v, id, owner, review, origin, legacyID, citations }
        init(v: Int, id: String, owner: String?, review: String, origin: String, legacyID: String?, citations: [MeetingOutcomeCitation]) {
            self.v = v; self.id = id; self.owner = owner; self.review = review; self.origin = origin; self.legacyID = legacyID; self.citations = citations
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            v = try values.decode(Int.self, forKey: .v)
            id = try values.decode(String.self, forKey: .id)
            owner = try values.decodeIfPresent(String.self, forKey: .owner)
            review = try values.decode(String.self, forKey: .review)
            origin = try values.decode(String.self, forKey: .origin)
            legacyID = try values.decodeIfPresent(String.self, forKey: .legacyID)
            citations = try values.decodeIfPresent([MeetingOutcomeCitation].self, forKey: .citations) ?? []
        }
}
