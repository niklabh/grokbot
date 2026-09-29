import SwiftUI

struct KeyedClipView: View {
    @ObservedObject var clips: ClipPlayer

    var body: some View {
        if let frame = clips.frame {
            Image(uiImage: frame)
                .resizable()
        } else {
            Color.clear
        }
    }
}
