import SwiftUI

// SEC-3: Opaque shield shown in place of sensitive content while a screen
// capture / external mirror is active. Driven by `ScreenCaptureMonitor`.
//
// Copy is mechanism-description per ARCH §1.3 / I6 — names the observed
// trigger ("screen capture or mirroring detected") and the response
// ("document hidden") without making an outcome promise. No partial
// redaction: per the SEC-3 posture, leaving doc-chrome (page
// count, layout) visible to a screen recorder would still be a regression.

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            // Fully opaque background — matches the SEC-4 app-switcher
            // overlay so the shield reads as the same "content withheld"
            // visual language across both privacy paths.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("Document hidden \u{2014} screen capture or mirroring detected")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityIdentifier("privacyShield")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Document hidden because screen capture or mirroring was detected.")
    }
}

#Preview {
    PrivacyShieldView()
}
