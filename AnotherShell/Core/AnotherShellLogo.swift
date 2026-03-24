import SwiftUI

enum AnotherShellLogoAsset {
    static let supportedSizes: [Int] = [16, 24, 32, 48, 64, 96, 128, 256, 512, 1024]

    static func name(for requestedSize: CGFloat) -> String {
        let target = max(Int(requestedSize.rounded()), 1)
        let nearest = supportedSizes.min(by: { abs($0 - target) < abs($1 - target) }) ?? 64
        return "AnotherShellLogo\(nearest)"
    }
}

struct AnotherShellLogoImage: View {
    let size: CGFloat
    var cornerRatio: CGFloat = 0.25

    var body: some View {
        Image(AnotherShellLogoAsset.name(for: size))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous))
    }
}
