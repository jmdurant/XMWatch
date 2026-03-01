// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//

// CutContentType has been removed because parsing it is too unpredictable and we are currently not using it

import Foundation

// MARK: - DiscoverChannelList
public struct DiscoverChannelList: Codable {
    public var moduleListResponse: ModuleListResponse?

    enum CodingKeys: String, CodingKey {
        case moduleListResponse = "ModuleListResponse"
    }
}

// MARK: - ModuleListResponse
public struct ModuleListResponse: Codable {
    public var messages: [Message]?
    public var status: Int?
    public var moduleList: ModuleList?
}

// MARK: - Message
public struct Message: Codable {
    public var code: Int?
    public var message: String?
}

// MARK: - ModuleList
public struct ModuleList: Codable {
    public var modules: [Module]?
}

// MARK: - Module
public struct Module: Codable {
    public var moduleResponse: ModuleResponse?
}

// MARK: - ModuleResponse
public struct ModuleResponse: Codable {
    public var moduleDetails: ModuleDetails?
}

// MARK: - ModuleDetails
public struct ModuleDetails: Codable {
    public var liveChannelResponse: ModuleDetailsLiveChannelResponse?
}

// MARK: - ModuleDetailsLiveChannelResponse
public struct ModuleDetailsLiveChannelResponse: Codable {
    public var liveChannelResponses: [LiveChannelResponseElement]?
}

// MARK: - LiveChannelResponseElement
public struct LiveChannelResponseElement: Codable {
    public var channelID: String?
    public var markerLists: [MarkerList]?

    enum CodingKeys: String, CodingKey {
        case channelID = "channelId"
        case markerLists
    }
}

// MARK: - MarkerList
public struct MarkerList: Codable {
    public var layer: Layer?
    public var markers: [Marker]?
}

public enum Layer: String, Codable {
    case cut = "cut"
    case episode = "episode"
}

// MARK: - Marker
public struct Marker: Codable {
    public var assetGUID, consumptionInfo: String?
    public var layer: Layer?
    public var time: Int?
    public var timestamp: Timestamp?
    public var containerGUID: String?
    public var liveGame: Bool?
    public var cut: Cut?
    public var duration: Double?
    public var episode: Episode?
}

// MARK: - Cut
public struct Cut: Codable {
    public var legacyIDS: LegacyIDS?
    public var title: String?
    public var artists: [Artist]?
    public var album: Album?
    public var clipGUID, galaxyAssetID: String?
    public var memberOfSpotBlock: Bool?
    public var mref: String?
    public var externalIDS: [ExternalID]?
    public var spotBlockID: String?
    public var firstCutOfSpotBlock: Bool?
    public var contentInfo: String?

    enum CodingKeys: String, CodingKey {
        case legacyIDS = "legacyIds"
        case title, artists, album, clipGUID
        case galaxyAssetID = "galaxyAssetId"
        case memberOfSpotBlock, mref
        case externalIDS = "externalIds"
        case spotBlockID = "spotBlockId"
        case firstCutOfSpotBlock, contentInfo
    }
}

// MARK: - Album
public struct Album: Codable {
    public var title: String?
}

// MARK: - Artist
public struct Artist: Codable {
    public var name: String?
}

// MARK: - ExternalID
public struct ExternalID: Codable {
    public var id: ID?
    public var value: String?
}

public enum ID: String, Codable {
    case iTunes = "iTunes"
}

// MARK: - LegacyIDS
public struct LegacyIDS: Codable {
    public var siriusXMID, pid: String?

    enum CodingKeys: String, CodingKey {
        case siriusXMID = "siriusXMId"
        case pid
    }
}

// MARK: - Episode
public struct Episode: Codable {
    public var isLiveVideoEligible: Bool?
}

// MARK: - Timestamp
public struct Timestamp: Codable {
    public var absolute: String?
}
