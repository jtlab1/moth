import Foundation

/// Model identifier, not the marketing name: one marketing name can cover different sensors.
public enum DeviceIdentity {

    public static let modelIdentifier: String = resolveModelIdentifier()

    private static func resolveModelIdentifier() -> String {
        // `hw.machine` reports the host Mac in the simulator, sharing one calibration across devices.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulator:\(simulated)"
        }

        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        // Drop the NUL and anything after it, or the identifier compares unequal to itself.
        let text = bytes.prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self)
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
