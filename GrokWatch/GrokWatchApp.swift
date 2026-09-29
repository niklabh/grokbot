import SwiftUI

@main
struct GrokWatchApp: App {
    var body: some Scene {
        WindowGroup {
            FaceView()
        }
    }
}

struct FaceView: View {
    @StateObject private var model = FaceModel()
    @StateObject private var clips = ClipPlayer()

    var body: some View {
        VStack(spacing: 2) {
            KeyedClipView(clips: clips)
                .aspectRatio(512.0 / 592.0, contentMode: .fit)
                .allowsHitTesting(false)
            Text(model.caption)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.18))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { model.talk() }
        .onAppear { clips.play("idle") }
        .onChange(of: model.phase) { _, phase in
            clips.play(phase)
        }
        .preferredColorScheme(.light)
        .accessibilityLabel("Grok")
        .accessibilityHint("Tap to talk")
    }
}
