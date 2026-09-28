import CSystem
import Darwin
import Foundation

final class NetworkCollector: Collector {
    let name = "network"

    private let exclude: Matcher
    private var buffer = [psk_netif_t](repeating: psk_netif_t(), count: 64)

    init(config: Config) throws {
        exclude = try Matcher(config.networkDeviceExclude)
    }

    func collect() throws -> [MetricFamily] {
        var found = buffer.withUnsafeMutableBufferPointer { psk_netif_list($0.baseAddress, Int32($0.count)) }
        if found > Int32(buffer.count) {
            buffer = [psk_netif_t](repeating: psk_netif_t(), count: Int(found) + 8)
            found = buffer.withUnsafeMutableBufferPointer { psk_netif_list($0.baseAddress, Int32($0.count)) }
        }
        guard found >= 0 else { throw CollectorError("IFMIB sysctl failed: \(errnoString())") }

        func counter(_ n: String, _ h: String) -> MetricFamily { MetricFamily(name: n, help: h, type: .counter) }
        var rxBytes = counter("node_network_receive_bytes_total", "Bytes received.")
        var txBytes = counter("node_network_transmit_bytes_total", "Bytes transmitted.")
        var rxPackets = counter("node_network_receive_packets_total", "Packets received.")
        var txPackets = counter("node_network_transmit_packets_total", "Packets transmitted.")
        var rxErrs = counter("node_network_receive_errs_total", "Receive errors.")
        var txErrs = counter("node_network_transmit_errs_total", "Transmit errors.")
        var rxDrop = counter("node_network_receive_drop_total", "Packets dropped on input.")
        var txDrop = counter("node_network_transmit_drop_total", "Packets dropped in the send queue.")
        var rxMulticast = counter("node_network_receive_multicast_total", "Multicast packets received.")
        var txMulticast = counter("node_network_transmit_multicast_total", "Multicast packets transmitted.")
        var collisions = counter("node_network_transmit_colls_total", "Collisions on transmit.")
        var noproto = counter("macos_network_receive_noproto_total", "Packets received for an unsupported protocol.")
        var up = MetricFamily(name: "node_network_up", help: "Interface is up and running (1) or not (0).", type: .gauge)
        var mtu = MetricFamily(name: "node_network_mtu_bytes", help: "Interface MTU in bytes.", type: .gauge)
        var speed = MetricFamily(name: "node_network_speed_bytes", help: "Interface link speed in bytes per second, when known.", type: .gauge)

        for i in 0..<min(Int(found), buffer.count) {
            let iface = buffer[i]
            let device = cString(iface.name)
            if device.isEmpty || exclude.matches(device) { continue }
            let labels = [("device", device)]
            rxBytes.add(Double(iface.ibytes), labels)
            txBytes.add(Double(iface.obytes), labels)
            rxPackets.add(Double(iface.ipackets), labels)
            txPackets.add(Double(iface.opackets), labels)
            rxErrs.add(Double(iface.ierrors), labels)
            txErrs.add(Double(iface.oerrors), labels)
            rxDrop.add(Double(iface.iqdrops), labels)
            txDrop.add(Double(max(iface.snd_drops, 0)), labels)
            rxMulticast.add(Double(iface.imcasts), labels)
            txMulticast.add(Double(iface.omcasts), labels)
            collisions.add(Double(iface.collisions), labels)
            noproto.add(Double(iface.noproto), labels)
            let running = UInt32(IFF_UP) | UInt32(IFF_RUNNING)
            up.add(iface.flags & running == running ? 1 : 0, labels)
            mtu.add(Double(iface.mtu), labels)
            if iface.baudrate > 0 { speed.add(Double(iface.baudrate) / 8, labels) }
        }
        return [rxBytes, txBytes, rxPackets, txPackets, rxErrs, txErrs, rxDrop, txDrop,
                rxMulticast, txMulticast, collisions, noproto, up, mtu, speed]
    }
}
