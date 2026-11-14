// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import CoreImage.CIFilterBuiltins
import SwiftUI
import XTEWalletCore

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct ReceiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var amountText = ""
    @State private var paymentID = ""

    private var uri: String {
        PaymentURI(address: model.address, amount: Amount.parse(amountText),
                   paymentID: isHex64(paymentID) ? paymentID.lowercased() : nil).uriString()
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    if let img = QRCode.image(for: amountText.isEmpty && paymentID.isEmpty ? model.address : uri) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 280, height: 280)
                            .accessibilityLabel("QR code of your address")
                    }
                    Spacer()
                }
                Text(model.address).font(.body.monospaced()).textSelection(.enabled)
                HStack {
                    Button { UIPasteboard.general.string = model.address; Haptics.play(.success) } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    Spacer()
                    ShareLink(item: model.address) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            Section("Payment request (optional)") {
                TextField("Amount in XTE", text: $amountText).keyboardType(.decimalPad)
                TextField("Payment ID (64 hex)", text: $paymentID).font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !amountText.isEmpty || !paymentID.isEmpty {
                    Text(uri).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: URL(string: uri) ?? URL(string: "about:blank")!,
                              subject: Text("\(XTEConfig.ticker) payment request"),
                              message: Text("Please pay \(Amount.parse(amountText).map { Amount.format($0) } ?? XTEConfig.ticker)")) {
                        Label("Share payment request", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Receive")
        // Handoff: show the same address / request on another device.
        .userActivity(SharedConfig.receiveActivityType, isActive: !model.address.isEmpty) { activity in
            Handoff.receive(activity, uri: uri)
        }
    }
}
