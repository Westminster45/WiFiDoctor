import CoreLocation
import CoreWLAN
import Foundation

/// Recent macOS hides the Wi-Fi network name from apps without Location access.
enum NetworkName {
    /// Best available name and where it came from. Private Relay's record of the name isn't used,
    /// because it can still hold the previous network's name after a change.
    static func find(dhcp: DHCPInfo) -> (name: String?, source: String?) {
        if let s = CWWiFiClient.shared().interface()?.ssid() { return (s, "Wi-Fi") }
        if let s = dhcp.ssid { return (s, "ipconfig") }
        if let s = SystemInfo.airportNetwork() { return (s, "networksetup") }
        return (nil, nil)
    }
}

/// Asks for Location access once, so the network name can be shown, and reports when it is granted.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onGranted: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isGranted: Bool {
        [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
    }

    var canAsk: Bool { manager.authorizationStatus == .notDetermined }

    func request() { manager.requestWhenInUseAuthorization() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isGranted { onGranted?() }
    }
}
