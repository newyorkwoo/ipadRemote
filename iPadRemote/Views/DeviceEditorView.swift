import SwiftUI

struct DeviceEditorView: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var device: SavedMac
    @State private var code: String
    @State private var portText: String
    @State private var wakePortText: String
    private let isNew: Bool

    init(target: EditorTarget) {
        _device = State(initialValue: target.device)
        _code = State(initialValue: target.pairingCode)
        _portText = State(initialValue: String(target.device.port))
        _wakePortText = State(initialValue: String(target.device.wakePort))
        isNew = target.isNew
    }

    private var canSave: Bool {
        guard !device.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // 已配對的 Mac 可以不填配對碼；填了就代表要重新配對
        return PairingCode.isValid(code) || (code.isEmpty && device.isPaired)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱", text: $device.name)
                        .accessibilityIdentifier("field.name")
                    TextField(device.isPaired ? "已配對（重新配對時才需填寫）" : "XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
                        .accessibilityIdentifier("field.code")
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: code) { _, newValue in
                            let formatted = PairingCode.format(newValue)
                            if formatted != newValue && PairingCode.normalize(newValue).count <= PairingCode.length {
                                code = formatted
                            }
                        }
                } header: {
                    Text("配對")
                } footer: {
                    if !code.isEmpty && !PairingCode.isValid(code) {
                        Text("配對碼應為 20 個字元。").foregroundStyle(.red)
                    } else {
                        Text(device.isPaired
                             ? "已配對：這台 iPad 使用 Mac 發給它的專屬金鑰連線。只有在 Mac 上移除了這台 iPad 時，才需要輸入新的配對碼重新配對。"
                             : "在 Mac 選單列點 iPad Remote 圖示即可看到配對碼。配對碼只能使用一次，配對成功後 Mac 會發給這台 iPad 專屬金鑰，存在鑰匙圈中。")
                    }
                }

                Section {
                    TextField("例如 myhome.ddns.net 或 100.64.0.2", text: $device.host)
                        .accessibilityIdentifier("field.host")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("連接埠") {
                        TextField("52800", text: $portText)
                            .accessibilityIdentifier("field.port")
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("從不同網路連線")
                } footer: {
                    Text("通常不用填：在 Mac 選單列與「我的 Mac」頁面的「跨網路連線」登入同一個帳號，App 就會自動找到 Mac。已另外安裝 Tailscale App 的話，也可以填 Mac 的 Tailscale 位址（100.x.x.x）。不建議在路由器轉發連接埠（DDNS / 公網 IP），那會讓 Mac 直接暴露在網際網路上。")
                }

                Section {
                    TextField("自動取得", text: $device.macAddress)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("外部喚醒位址（選填）", text: $device.wakeHost)
                        .accessibilityIdentifier("field.wakeHost")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("喚醒 UDP 埠") {
                        TextField("9", text: $wakePortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("喚醒（Wake‑on‑LAN）")
                } footer: {
                    Text("第一次成功連線後會自動記下 MAC 位址。從外部喚醒需要路由器將 UDP 埠轉發到區網廣播，或家中有一台常開的裝置（例如 Apple TV / HomePod 作為睡眠代理）。")
                }
            }
            .navigationTitle(isNew ? "加入 Mac" : "編輯 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        device.name = device.name.trimmingCharacters(in: .whitespaces)
                        device.host = device.host.trimmingCharacters(in: .whitespaces)
                        device.port = UInt16(portText) ?? RemoteConstants.defaultPort
                        device.wakePort = UInt16(wakePortText) ?? 9
                        store.save(device, pairingCode: code)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
