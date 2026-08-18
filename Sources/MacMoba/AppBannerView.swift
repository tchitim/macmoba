// The non-blocking notification banner (P0-3). Slides in at the top of the
// window for results and errors that used to interrupt with an OK-only alert;
// click to dismiss early, or it leaves on its own.

import SwiftUI

struct AppBannerView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack {
            if let banner = app.banner {
                HStack(spacing: 8) {
                    Image(systemName: banner.isError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Color.red : Color.green)
                    Text(banner.text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .frame(maxWidth: 560)
                .contentShape(Rectangle())
                .onTapGesture { app.dismissBanner() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 10)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(duration: 0.3), value: app.banner)
        .allowsHitTesting(app.banner != nil)
    }
}
