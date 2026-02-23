import SwiftUI

public struct RemoteBackgroundView: View {
    public enum ContentMode {
        case fill
        case fit
    }

    private let imageName: String
    private let contentMode: ContentMode
    private let placeholder: Color
    private let overlay: AnyShapeStyle?

    public init(
        imageName: String,
        contentMode: ContentMode = .fill,
        placeholder: Color = .clear,
        overlay: AnyShapeStyle? = nil
    ) {
        self.imageName = imageName
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.overlay = overlay
    }

    public var body: some View {
        ZStack {
            placeholder
            Image(imageName)
                .resizable()
                .modifier(Scaled(mode: contentMode))
                .clipped()
            if let overlay {
                Rectangle().fill(overlay)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Scaled: ViewModifier {
        let mode: ContentMode
        func body(content: Content) -> some View {
            switch mode {
            case .fill:
                content.scaledToFill()
            case .fit:
                content.scaledToFit()
            }
        }
    }
}

public extension View {
    /// Applies an asset catalog image as a non-intrusive, full-screen background that doesn't affect layout.
    func assetBackground(
        _ imageName: String,
        contentMode: RemoteBackgroundView.ContentMode = .fill,
        placeholder: Color = .clear
    ) -> some View {
        self.background(
            RemoteBackgroundView(
                imageName: imageName,
                contentMode: contentMode,
                placeholder: placeholder,
                overlay: nil
            )
        )
    }

    /// Applies an asset catalog image as a non-intrusive, full-screen background with a customizable overlay (e.g. Material or Color with opacity).
    func assetBackground(
        _ imageName: String,
        contentMode: RemoteBackgroundView.ContentMode = .fill,
        placeholder: Color = .clear,
        overlay: AnyShapeStyle
    ) -> some View {
        self.background(
            RemoteBackgroundView(
                imageName: imageName,
                contentMode: contentMode,
                placeholder: placeholder,
                overlay: overlay
            )
        )
    }
}

#Preview("Asset background with/without overlay") {
    VStack(spacing: 24) {
        Group {
            Text("Zonder overlay")
                .font(.headline)
            Text("Voorgrond content")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)

        Divider()

        Group {
            Text("Met overlay (.ultraThinMaterial.opacity(0.25))")
                .font(.headline)
            Text("Voorgrond content")
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)

        Spacer()
    }
    .padding()
    .assetBackground("RemoteBackground")
    .assetBackground("RemoteBackground", overlay: .ultraThinMaterial.opacity(0.25))
}
