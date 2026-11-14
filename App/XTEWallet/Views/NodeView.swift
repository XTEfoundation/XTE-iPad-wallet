// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct NodeView: View {
    @EnvironmentObject var model: AppModel
    @State private var customHost = ""
    @State private var customPort = "14485"
    @State private var customSSL = false

    var body: some View {
        Form {
            Section("Current node") {
                LabeledContent("Node", value: "\(model.node.name) (\(model.node.baseURL.absoluteString))")
                LabeledContent("Sync path", value: model.fastPathActive ? "Fast RPC gateway (\(Gateway.endpoint(for: model.node).absoluteString))" : "Node REST API")
                if let info = model.daemonInfo {
                    LabeledContent("Node height", value: "\(info.localHeight)")
                    LabeledContent("Network height", value: "\(info.networkTopHeight)")
                    LabeledContent("Node synced", value: info.localHeight + 1 >= info.networkTopHeight ? "Yes" : "No")
                    LabeledContent("Peers", value: "\(info.peers)")
                    if let d = info.difficulty { LabeledContent("Difficulty", value: "\(d)") }
                    if let v = info.version { LabeledContent("Version", value: v) }
                } else if let e = model.nodeError {
                    Text(e).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                Button("Refresh") { Task { await model.refreshInfo() } }
            }
            Section("Public nodes") {
                ForEach(model.nodes) { n in
                    Button {
                        model.node = n
                        Task { await model.refreshInfo() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(n.name)
                                Text(n.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if n == model.node { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button("Reload node list") { Task { await model.refreshNodeList() } }
            }
            Section("Custom node") {
                TextField("Host", text: $customHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $customPort).keyboardType(.numberPad)
                Toggle("HTTPS", isOn: $customSSL)
                Button("Use custom node") {
                    guard let port = Int(customPort), !customHost.isEmpty else { return }
                    model.node = NodeInfo(name: customHost, host: customHost, port: port, ssl: customSSL)
                    Task { await model.refreshInfo() }
                }
            }
        }
        .navigationTitle("Node")
        .task {
            await model.refreshNodeList()
            await model.refreshInfo()
        }
    }
}
