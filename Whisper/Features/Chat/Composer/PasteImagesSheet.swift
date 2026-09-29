import SwiftUI

/// 粘贴图片前先看一眼：发成图片，或者（只有一张时）当表情发，不带气泡、小小一张
struct PasteImagesSheet: View {
    let images: [UIImage]
    let onSend: (_ asSticker: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Text(images.count > 1 ? "发送这 \(images.count) 张图片" : "发送剪贴板里的图片")
                    .font(.headline)
                HStack {
                    Button("取消", action: onCancel)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: images.count > 1 ? 150 : 260, maxHeight: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .frame(height: 196)

            HStack(spacing: 12) {
                if images.count == 1 {
                    Button {
                        onSend(true)
                    } label: {
                        Label("当表情发", systemImage: "face.smiling").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                Button {
                    onSend(false)
                } label: {
                    Label("发送", systemImage: "arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .tint(Theme.accentColor)
    }
}
