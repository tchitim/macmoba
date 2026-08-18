// The MobaXterm "Tools" menu, three panes: wake a host, scan its ports, resolve
// a name. All the logic is in MacMobaCore.NetworkTools; the scan and resolve run
// off the main thread so a slow host does not freeze the panel.

import MacMobaCore
import SwiftUI

struct NetworkToolsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Network Tools").font(.headline)
            WakeOnLANPane()
            Divider()
            PortScanPane()
            Divider()
            DNSPane()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct WakeOnLANPane: View {
    @State private var mac = ""
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wake-on-LAN").font(.subheadline).bold()
            HStack {
                TextField("MAC address", text: $mac, prompt: Text("aa:bb:cc:dd:ee:ff"))
                    .font(.system(.body, design: .monospaced))
                Button("Wake") { wake() }
                    .disabled(WakeOnLAN.parseMAC(mac) == nil)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func wake() {
        do {
            try WakeOnLAN.send(mac: mac)
            note = "Magic packet broadcast to \(mac)."
        } catch {
            note = "Could not send: \(error)"
        }
    }
}

private struct PortScanPane: View {
    @State private var host = ""
    @State private var open: [Int] = []
    @State private var scanning = false
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Port Scan").font(.subheadline).bold()
            HStack {
                TextField("Host", text: $host, prompt: Text("host or IP"))
                Button(scanning ? "Scanning…" : "Scan") { scan() }
                    .disabled(host.isEmpty || scanning)
            }
            Text("Checks common ports: \(PortScanner.commonPorts.map(String.init).joined(separator: ", "))")
                .font(.caption2).foregroundStyle(.secondary)
            if done {
                if open.isEmpty {
                    Text("No common ports open.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Open: " + open.map(String.init).joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private func scan() {
        scanning = true; done = false
        let target = host.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PortScanner.scan(host: target, ports: PortScanner.commonPorts, timeout: 1)
            DispatchQueue.main.async {
                open = result; scanning = false; done = true
            }
        }
    }
}

private struct DNSPane: View {
    @State private var host = ""
    @State private var addresses: [String] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DNS Lookup").font(.subheadline).bold()
            HStack {
                TextField("Host", text: $host, prompt: Text("example.com"))
                Button("Resolve") { resolve() }
                    .disabled(host.isEmpty)
            }
            if done {
                if addresses.isEmpty {
                    Text("Did not resolve.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(addresses.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func resolve() {
        let target = host.trimmingCharacters(in: .whitespaces)
        done = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DNSLookup.resolve(target)
            DispatchQueue.main.async { addresses = result; done = true }
        }
    }
}
