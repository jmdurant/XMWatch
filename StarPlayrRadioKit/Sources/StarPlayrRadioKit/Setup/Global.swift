import Foundation

//source
public var usePrime: Bool = false
public let http: String = "https://"

public var root: String = "player.siriusxm.com/rest/v2/experience/modules"
public var playerDomain = "player.siriusxm.com"
public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
public var appRegion = "US"

public var hls_sources = Dictionary<String, String>()

public var MemBase = Dictionary<String?, String?>()
public let audioFormat = "audio/aac"

public typealias LoginData = ( email:String, pass:String, channels:  Dictionary<String, Any>,
    ids:  Dictionary<String, Any>, channel: String, token: String, loggedin: Bool,  gupid: String, consumer: String, key: String, keyurl: String )
public var userX = ( email:"", pass:"", channels: [:], ids: [:], channel: "", token: "", loggedin: false, gupid: "", consumer: "", key: "", keyurl: "" ) as LoginData

public typealias PostReturnTuple = (message: String, success: Bool, data: Dictionary<String, Any>, response: HTTPURLResponse? )

//Completion Handlers
public typealias CompletionHandler = (_ success:Bool) 			  	   -> Void
public typealias PostTupleHandler  = (_ tuple:PostReturnTuple?) 	   -> Void
public typealias DictionaryHandler = (_ dict:NSDictionary?) 		   -> Void
public typealias DataHandler       = (_ data:Data?) 				   -> Void
public typealias TextHandler       = (_ text:String?) 			   	   -> Void
public typealias PdtHandler        = (_ struct:DiscoverChannelList?)  -> Void
public typealias LiveHandler 		= (_ struct:NowPlayingLiveStruct?) -> Void

