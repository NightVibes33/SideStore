import SwiftUI
import UIKit
@preconcurrency import AltSign

struct ManualSigningPackageView: View {
    @Environment(\.dismiss) private var dismiss

    let certificates: [ALTX509Certificate]
    let team: ALTTeam
    let session: ALTAppleAPISession

    @State private var selectedSerial = ""
    @State private var deviceName = ""
    @State private var udid = ""
    @State private var appIDName = "Signing Package"
    @State private var bundleIdentifier = ""
    @State private var p12Password = ""
    @State private var isWorking = false
    @State private var status = ""
    @State private var errorMessage: String?

    private var exportableCertificates: [ALTX509Certificate] {
        certificates.filter { CertificateManager.shared.getSignableCertificate(for: $0.serialNumber) != nil }
    }

    private var selectedCertificate: ALTX509Certificate? {
        exportableCertificates.first { $0.serialNumber == selectedSerial }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Device") {
                    TextField("Device name", text: $deviceName)
                        .textInputAutocapitalization(.words)
                    TextField("UDID", text: $udid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("The entered UDID is checked against your team and registered only when it is missing. SideStore does not substitute this device's UDID.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("App ID") {
                    TextField("Portal name", text: $appIDName)
                    TextField("Bundle identifier", text: $bundleIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("An existing App ID is reused. Otherwise SideStore creates this exact identifier before requesting the profile.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Certificate") {
                    Picker("Signing certificate", selection: $selectedSerial) {
                        ForEach(exportableCertificates, id: \.serialNumber) { certificate in
                            Text(certificate.machineName ?? certificate.name)
                                .tag(certificate.serialNumber)
                        }
                    }
                    SecureField(".p12 password", text: $p12Password)
                    if exportableCertificates.isEmpty {
                        Text("Create or import a certificate with its private key first.")
                            .foregroundColor(.red)
                    }
                }

                if !status.isEmpty {
                    Section("Status") {
                        Text(status)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button {
                        exportPackage()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView().padding(.trailing, 6) }
                            Text("Register Device and Export")
                            Spacer()
                        }
                    }
                    .disabled(isWorking || selectedCertificate == nil)
                }
            }
            .navigationTitle("Signing Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if selectedSerial.isEmpty {
                    selectedSerial = exportableCertificates.first?.serialNumber ?? ""
                }
            }
            .alert("Export Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func exportPackage() {
        guard let certificate = selectedCertificate,
              let signableCertificate = CertificateManager.shared.getSignableCertificate(for: certificate.serialNumber) else {
            errorMessage = "Select a certificate that includes its private key."
            return
        }

        let cleanedUDID = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAppIDName = appIDName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidUDID(cleanedUDID) else {
            errorMessage = "Enter a valid Apple device UDID."
            return
        }
        guard !cleanedDeviceName.isEmpty else {
            errorMessage = "Enter a device name."
            return
        }
        guard Self.isValidBundleIdentifier(cleanedBundleID) else {
            errorMessage = "Enter a valid bundle identifier."
            return
        }
        guard !p12Password.isEmpty else {
            errorMessage = "Set a password for the exported .p12."
            return
        }

        isWorking = true
        status = "Checking registered devices..."

        Task { @MainActor in
            do {
                let devices = try await DeveloperPortalService.shared.fetchDevices(
                    for: team,
                    types: [.iphone, .ipad],
                    session: session
                )
                if devices.contains(where: { $0.identifier.caseInsensitiveCompare(cleanedUDID) == .orderedSame }) {
                    status = "Device is already registered. Checking App ID..."
                } else {
                    status = "Registering \(cleanedDeviceName)..."
                    _ = try await DeveloperPortalService.shared.registerDevice(
                        name: cleanedDeviceName,
                        identifier: cleanedUDID,
                        type: .iphone,
                        team: team,
                        session: session
                    )
                    status = "Device registered. Checking App ID..."
                }

                let appIDs = try await ALTAppleAPI.shared.fetchAppIDs(for: team, session: session)
                let appID: ALTAppID
                if let existing = appIDs.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(cleanedBundleID) == .orderedSame }) {
                    appID = existing
                } else {
                    let portalName = cleanedAppIDName.isEmpty ? cleanedBundleID : cleanedAppIDName
                    guard portalName.unicodeScalars.allSatisfy(\.isASCII) else {
                        throw ExportError.invalidPortalName
                    }
                    status = "Creating App ID..."
                    appID = try await ALTAppleAPI.shared.addAppID(
                        withName: portalName,
                        bundleIdentifier: cleanedBundleID,
                        team: team,
                        session: session
                    )
                }

                status = "Requesting provisioning profile..."
                var profile = try await ALTAppleAPI.shared.fetchProvisioningProfile(
                    for: appID,
                    deviceType: .iphone,
                    team: team,
                    session: session
                )

                let hasDevice = profile.deviceIDs.contains {
                    $0.caseInsensitiveCompare(cleanedUDID) == .orderedSame
                }
                let hasCertificate = profile.certificates.contains {
                    $0.serialNumber == certificate.serialNumber
                }
                if !hasDevice || !hasCertificate {
                    status = "Refreshing provisioning profile..."
                    try await ALTAppleAPI.shared.deleteProvisioningProfile(profile, for: team, session: session)
                    profile = try await ALTAppleAPI.shared.fetchProvisioningProfile(
                        for: appID,
                        deviceType: .iphone,
                        team: team,
                        session: session
                    )
                }

                guard profile.deviceIDs.contains(where: {
                    $0.caseInsensitiveCompare(cleanedUDID) == .orderedSame
                }) else {
                    throw ExportError.deviceNotInProfile
                }
                guard profile.certificates.contains(where: { $0.serialNumber == certificate.serialNumber }) else {
                    throw ExportError.certificateNotInProfile
                }
                guard let p12Data = signableCertificate.encryptedP12Data(password: p12Password) else {
                    throw ExportError.p12CreationFailed
                }

                status = "Preparing export..."
                try Self.share(
                    p12Data: p12Data,
                    profileData: profile.data,
                    baseName: Self.safeFilename(cleanedDeviceName)
                )
                status = "Export ready for \(cleanedDeviceName) (\(cleanedUDID))."
            } catch {
                errorMessage = error.localizedDescription
                status = ""
            }
            isWorking = false
        }
    }

    private static func isValidUDID(_ value: String) -> Bool {
        guard (20...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0)
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "SideStore-Signing-Package" : result
    }

    private static func share(p12Data: Data, profileData: Data, baseName: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideStore-Signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let p12URL = directory.appendingPathComponent("\(baseName).p12")
        let profileURL = directory.appendingPathComponent("\(baseName).mobileprovision")
        try p12Data.write(to: p12URL, options: .atomic)
        try profileData.write(to: profileURL, options: .atomic)

        let activity = UIActivityViewController(activityItems: [p12URL, profileURL], applicationActivities: nil)
        guard let root = UIApplication.shared.windows.first?.rootViewController else {
            throw ExportError.noPresenter
        }
        let presenter = root.presentedViewController ?? root
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private enum ExportError: LocalizedError {
        case invalidPortalName
        case deviceNotInProfile
        case certificateNotInProfile
        case p12CreationFailed
        case noPresenter

        var errorDescription: String? {
            switch self {
            case .invalidPortalName:
                return "The App ID portal name must contain ASCII characters only."
            case .deviceNotInProfile:
                return "Apple returned a profile that does not include the entered UDID. Check the device registration in the developer portal and try again."
            case .certificateNotInProfile:
                return "Apple returned a profile that does not contain the selected certificate. Select SideStore's active certificate or create a new profile after activating it."
            case .p12CreationFailed:
                return "SideStore could not export the selected certificate and private key as .p12."
            case .noPresenter:
                return "SideStore could not open the share sheet."
            }
        }
    }
}
