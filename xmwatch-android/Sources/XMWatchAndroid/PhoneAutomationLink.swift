#if SKIP
import Foundation

public final class PhoneAutomationLink {
    public static func synchronize(_ json: String) {
        PhoneAutomation.synchronize(ProcessInfo.processInfo.androidContext, json)
    }
    public static func pin(_ region: String, _ id: String, _ name: String, _ number: String) -> Bool {
        return PhoneAutomation.pin(ProcessInfo.processInfo.androidContext, region, id, name, number)
    }
}
#endif
