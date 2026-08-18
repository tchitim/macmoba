// Master-password gate: create the vault on first launch, unlock afterwards.
// Optional Touch ID unlock (password remembered in the login keychain).

import MacMobaCore
import SwiftUI

struct VaultGateView: View {
    @EnvironmentObject var app: AppState
    @State private var password = ""
    @State private var confirm = ""
    @AppStorage("touchIDUnlock") private var touchIDEnabled = true
    @State private var autoPrompted = false
    @FocusState private var focused: Bool

    private var creating: Bool { !app.vaultExists }
    private var canOfferTouchID: Bool {
        !creating && BiometricUnlock.biometryAvailable && BiometricUnlock.hasStoredPassword
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: canOfferTouchID ? "touchid" : "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(creating ? "Create Master Password" : "Unlock MacMoba")
                .font(.title2.bold())
            Text(creating
                 ? "Sessions and credentials are stored in an encrypted vault\n(scrypt + AES-256-GCM), compatible with the Electron version."
                 : "Enter your master password to decrypt the vault.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if canOfferTouchID {
                Button {
                    app.unlockWithTouchID()
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .frame(width: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(spacing: 8) {
                SecureField("Master password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if creating {
                    SecureField("Confirm password", text: $confirm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
            }
            .frame(width: 280)

            if BiometricUnlock.biometryAvailable {
                Toggle("Remember in Keychain for Touch ID unlock", isOn: $touchIDEnabled)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            if canOfferTouchID {
                Button(creating ? "Create Vault" : "Unlock", action: submit)
                    .buttonStyle(.bordered)
                    .disabled(password.isEmpty || (creating && password != confirm))
            } else {
                Button(creating ? "Create Vault" : "Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || (creating && password != confirm))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            if canOfferTouchID && touchIDEnabled && !autoPrompted {
                autoPrompted = true
                app.unlockWithTouchID()
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let remember = BiometricUnlock.biometryAvailable && touchIDEnabled
        if creating {
            guard password == confirm else { return }
            app.createVault(masterPassword: password, rememberForTouchID: remember)
        } else {
            app.unlockVault(masterPassword: password, rememberForTouchID: remember)
        }
        password = ""
        confirm = ""
    }
}

