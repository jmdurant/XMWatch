//
//  nowPlayingLive.swift
//  COpenSSL
//
//  Created by Todd Bruss on 4/5/20.
//

import Foundation

//MARK: After
public func nowPlayingLiveAsync(endpoint: String, LiveHandler: @escaping LiveHandler) {
    guard let url = URL(string: endpoint) else { LiveHandler(.none); return }
    let decoder = JSONDecoder()
    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = "GET"
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
    urlReq.timeoutInterval = TimeInterval(60)
    
    let task = URLSession.shared.dataTask(with: urlReq ) { data, r, e  in
        guard let data = data else { LiveHandler(.none); return }
        do { let nowPlayingLive = try decoder.decode(NowPlayingLiveStruct.self, from: data)
            LiveHandler(nowPlayingLive)
            
        } catch {
            //print(error) [ Talk stations are producing an error, no data ]
            LiveHandler(.none)
        }
    }
    
    task.resume()
}

public func nowPlayingLive(channelid: String) -> String {
    
    let timeInterval = Date().timeIntervalSince1970
    let convert = timeInterval * 1000000 as NSNumber
    let intTime = Int(truncating: convert) / 1000
    let time = String(intTime)
    let endpoint = "https://\(playerDomain)/rest/v4/experience/modules/tune/now-playing-live?channelId=\(channelid)&hls_output_mode=none&marker_mode=all_separate_cue_points&ccRequestType=AUDIO_VIDEO&result-template=web&time=" + time
    
    return endpoint
}

public func processNPL(data: NowPlayingLiveStruct) {
    autoreleasepool {
        guard
            let markers = data.moduleListResponse.moduleList.modules.first?.moduleResponse.liveChannelData.markerLists
        else {
            return
        }
        
        MemBase = [:]
        
        for m in markers {
            
            for i in m.markers {
                let cut = i.cut
                
                if let artist = cut?.artists.first?.name, let song = cut?.title, let art = cut?.album?.creativeArts {

                    for albumart in art.reversed() where albumart.relativeURL.contains("_m.") {
                       
                        guard
                            let key = sha256(artist + song)
                        else {
                            return
                        }
                        
                        MemBase[key] = albumart.relativeURL.replacingOccurrences(of: "%Album_Art%", with: "http://albumart.siriusxm.com")
                    }
                }
            }
        }
    }
}

// MARK: - NowPlayingLiveStruct
public struct NowPlayingLiveStruct: Codable {
    public let moduleListResponse: ModuleListResponse

    enum CodingKeys: String, CodingKey {
        case moduleListResponse = "ModuleListResponse"
    }


    // MARK: - ModuleListResponse
    public struct ModuleListResponse: Codable {
        public let messages: [Message]
        public let status: Int
        public let moduleList: ModuleList
    }

    // MARK: - Message
    public struct Message: Codable {
        public let code: Int
        public let message: String
    }

    // MARK: - ModuleList
    public struct ModuleList: Codable {
        public let modules: [Module]
    }

    // MARK: - Module
    public struct Module: Codable {
        public let moduleResponse: ModuleResponse
        public let moduleArea, moduleType: String
        public let updateFrequency: Int
        public let wallClockRenderTime: String
    }

    // MARK: - ModuleResponse
    public struct ModuleResponse: Codable {
        public let liveChannelData: LiveChannelData
    }

    // MARK: - LiveChannelData
    public struct LiveChannelData: Codable {
        public let channelID: String?
        public let liveDelay, aodEpisodeCount: Int?
        public let markerLists: [MarkerList]?
        public let cuePointList: CuePointList?
        public let hlsConsumptionInfo: String?
        public let connectInfo: ConnectInfo?
        public let inactivityTimeOut: Int?

        enum CodingKeys: String, CodingKey {
            case channelID = "channelId"
            case liveDelay, aodEpisodeCount, markerLists, cuePointList, hlsConsumptionInfo, connectInfo, inactivityTimeOut
        }
    }

    // MARK: - ConnectInfo
    public struct ConnectInfo: Codable {
        public let phone, email, twitter: String?
        public let twitterLink: String?
        public let facebook: String?
        public let facebookLink: String?
    }

    // MARK: - CuePointList
    public struct CuePointList: Codable {
        public let cuePoints: [CuePoint]
    }

    // MARK: - CuePoint
    public struct CuePoint: Codable {
        public let assetGUID: String
        public let layer: Layer
        public let time: Int
        public let timestamp: Timestamp
        public let event: Event
        public let markerGUID: String?
        public let active: Bool?

        enum CodingKeys: String, CodingKey {
            case assetGUID, layer, time, timestamp, event
            case markerGUID = "markerGuid"
            case active
        }
    }

    public enum Event: String, Codable {
        case end = "END"
        case instantaneous = "INSTANTANEOUS"
        case start = "START"
    }

    public enum Layer: String, Codable {
        case cut = "cut"
        case episode = "episode"
        case livepoint = "livepoint"
        case segment = "segment"
        case show = "show"
    }

    // MARK: - Timestamp
    public struct Timestamp: Codable {
        public let absolute: String
    }

    // MARK: - MarkerList
    public struct MarkerList: Codable {
        public let layer: String
        public let markers: [Marker]
    }

    // MARK: - Marker
    public struct Marker: Codable {
        public let assetGUID: String
        public let layer: Layer
        public let time: Int
        public let timestamp: Timestamp
        public let containerGUID: String
        public let duration: Double
        public let episode: Episode?
        public let pandoraSegmentGUID: String?
        public let segment: Segment?
        public let consumptionInfo, pandoraCutGUID: String?
        public let cut: Cut?
        public let pivotStation: String?
        public let gameInProgress: Bool?
    }

    // MARK: - Cut
    public struct Cut: Codable {
        public let legacyIDS: CutLegacyIDS
        public let title: String?
        public let artists: [Artist]
        public let album: Album?
        public let clipGUID: String?
        public let galaxyAssetID: String?
        public let cutContentType: CutContentType?
        public let mref: String?
        public let memberOfSpotBlock: Bool?
        public let pandoraClipGUID, pandoraMrefGUID: String?
        public let externalIDS: [ExternalID]?

        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case title, artists, album, clipGUID
            case galaxyAssetID = "galaxyAssetId"
            case cutContentType, mref, memberOfSpotBlock
            case pandoraClipGUID = "pandoraClipGuid"
            case pandoraMrefGUID = "pandoraMrefGuid"
            case externalIDS = "externalIds"
        }
    }

    // MARK: - Album
    public struct Album: Codable {
        public let title: String?
        public let creativeArts: [AlbumCreativeArt]?
    }

    // MARK: - AlbumCreativeArt
    public struct AlbumCreativeArt: Codable {
        public let url: String
        public let relativeURL: String
        public let size: Size
        public let type: TypeEnum

        enum CodingKeys: String, CodingKey {
            case url
            case relativeURL = "relativeUrl"
            case size, type
        }
    }

    public enum Size: String, Codable {
        case medium = "MEDIUM"
        case small = "SMALL"
        case thumbnail = "THUMBNAIL"
    }

    public enum TypeEnum: String, Codable {
        case image = "IMAGE"
    }

    // MARK: - Artist
    public struct Artist: Codable {
        public let name: String
    }

    public enum CutContentType: String, Codable {
        case exp = "Exp"
        case link = "Link"
        case song = "Song"
    }

    // MARK: - ExternalID
    public struct ExternalID: Codable {
        public let id, value: String
    }

    // MARK: - CutLegacyIDS
    public struct CutLegacyIDS: Codable {
        public let siriusXMID: String
        public let pid: String?

        enum CodingKeys: String, CodingKey {
            case siriusXMID = "siriusXMId"
            case pid
        }
    }

    // MARK: - Episode
    public struct Episode: Codable {
        public let legacyIDS: EpisodeLegacyIDS?
        public let mediumTitle, longTitle, shortDescription, longDescription: String?
        public let keywords: Entities?
        public let episodeGUID: String?
        public let originalAirDate: String?
        public let valuable: Bool?
        public let show: Show?
        public let hot, highlighted: Bool?
        public let dmcaInfo: DMCAInfo?
        public let entities, topics: Entities?
        public let live, episodeRepeat: Bool?
        public let dataSiftFilterName: String?
        public let featuredTweetCoordinate: FeaturedTweetCoordinate?
        public let mref, pandoraLiveEpisodeGUID: String?
        public let host: [String]?

        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case mediumTitle, longTitle, shortDescription, longDescription, keywords, episodeGUID, originalAirDate, valuable, show, hot, highlighted, dmcaInfo, entities, topics, live
            case episodeRepeat = "repeat"
            case dataSiftFilterName, featuredTweetCoordinate, mref
            case pandoraLiveEpisodeGUID = "pandoraLiveEpisodeGuid"
            case host
        }
    }

    // MARK: - DMCAInfo
    public struct DMCAInfo: Codable {
        public let maxBackSkips, maxTotalSkips, maxSkipDur: Int
        public let irNavClass, playOnSelect, channelContentType: String
        public let fwdSkipDur, backSkipDur, maxFwdSkips: Int
    }

    // MARK: - Entities
    public struct Entities: Codable {
    }

    // MARK: - FeaturedTweetCoordinate
    public struct FeaturedTweetCoordinate: Codable {
        public let handle, hashtag: String
    }

    // MARK: - EpisodeLegacyIDS
    public struct EpisodeLegacyIDS: Codable {
        public let shortID: String

        enum CodingKeys: String, CodingKey {
            case shortID = "shortId"
        }
    }

    // MARK: - Show
    public struct Show: Codable {
        public let legacyIDS: EpisodeLegacyIDS?
        public let mediumTitle, longTitle, shortDescription, longDescription: String?
        public let isLiveVideoEligible: Bool?
        public let guid: String
        public let creativeArts: [ShowCreativeArt]?
        public let showGUID: String
        public let connectInfo: ConnectInfo?
        public let disableRecommendations: [String]?
        public let futureAirings: [FutureAiring]?
        public let pandoraShowGUID, programType: String?
        public let isPlaceholderShow: Bool?

        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case mediumTitle, longTitle, shortDescription, longDescription, isLiveVideoEligible, guid, creativeArts, showGUID, connectInfo, disableRecommendations, futureAirings, pandoraShowGUID, programType, isPlaceholderShow
        }
    }

    // MARK: - ShowCreativeArt
    public struct ShowCreativeArt: Codable {
        public let name: String
        public let url: String
        public let relativeURL: String
        public let height, width: Int
        public let type: TypeEnum

        enum CodingKeys: String, CodingKey {
            case name, url
            case relativeURL = "relativeUrl"
            case height, width, type
        }
    }

    // MARK: - FutureAiring
    public struct FutureAiring: Codable {
        public let channelID: String
        public let satelliteOnlyChannel: Bool
        public let timestamp: String
        public let duration: Int

        enum CodingKeys: String, CodingKey {
            case channelID = "channelId"
            case satelliteOnlyChannel, timestamp, duration
        }
    }

    // MARK: - Segment
    public struct Segment: Codable {
        public let legacyIDS: EpisodeLegacyIDS
        public let segmentType: SegmentType

        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case segmentType
        }
    }

    public enum SegmentType: String, Codable {
        case soft = "SOFT"
    }
}
