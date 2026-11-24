import Foundation

/// iCloud Private Relay state, read from macOS's own preferences.
enum Relay {
    static let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.networkserviceproxy.plist"

    // Inferred from observed transitions; codes are not documented by Apple.
    static let statusLabels: [Int: String] = [
        0: "unknown",
        1: "off",
        2: "unavailable on this network",
        3: "failed",
        4: "starting up",
        5: "on",
    ]

    /// NSKeyedArchiver references arrive as opaque CFKeyedArchiverUID objects; their index is only in the description.
    static func uid(_ v: Any) -> Int? {
        let d = String(describing: v)
        guard d.hasPrefix("<CFKeyedArchiverUID") else { return nil }
        return first(#"value = (\d+)"#, d).flatMap(Int.init)
    }

    /// Minimal NSKeyedArchiver reader: resolve UIDs into plain dictionaries.
    static func unarchive(_ blob: Data) -> [String: Any]? {
        guard let d = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let objs = d["$objects"] as? [Any], let top = d["$top"] as? [String: Any] else { return nil }
        func deref(_ v: Any, _ depth: Int) -> Any {
            if depth > 12 { return NSNull() }
            if let i = uid(v) { return i < objs.count ? deref(objs[i], depth + 1) : NSNull() }
            if let dict = v as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, x) in dict where !["$class", "$classname", "$classes"].contains(k) { out[k] = deref(x, depth + 1) }
                return out
            }
            if let arr = v as? [Any] { return arr.map { deref($0, depth + 1) } }
            return v
        }
        return top.mapValues { deref($0, 0) }
    }

    static func state() -> RelayInfo {
        var out = RelayInfo()
        out.daemonRunning = !run([Bin.pgrep, "-x", "networkserviceproxy"]).trimmed.isEmpty
        guard let raw = FileManager.default.contents(atPath: plistPath),
              let pl = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] else { return out }
        out.present = true
        guard let blob = pl["NSPServiceStatusManagerInfo"] as? Data, let top = unarchive(blob) else { return out }
        let svc = top["ServiceStatus"] as? [String: Any] ?? [:]
        let code = (svc["PrivacyProxyServiceStatus"] as? NSNumber)?.intValue
        out.statusCode = code
        out.statusLabel = code.map { statusLabels[$0] ?? "unrecognised code \($0)" } ?? "unknown"
        let nets = svc["PrivacyProxyNetworkStatuses"]
        let entries = ((nets as? [String: Any])?["NS.objects"] as? [Any]) ?? (nets as? [Any]) ?? []
        if let n = entries.first as? [String: Any] {
            out.networkName = n["PrivacyProxyNetworkName"] as? String
            out.networkStatus = (n["PrivacyProxyNetworkStatus"] as? NSNumber)?.intValue
        }
        return out
    }
}
