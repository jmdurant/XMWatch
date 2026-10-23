import Foundation

#if SKIP
/// Opens the platform media output controls from an explicit foreground action.
public final class AudioOutputLink {
    public static func open() -> String {
        return AudioOutput.open(ProcessInfo.processInfo.androidContext)
    }
}
#endif
