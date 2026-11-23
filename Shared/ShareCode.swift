import CoreGraphics
import CoreImage
import Foundation

enum DownloadCode {
    static func address(storeID: String) -> String {
        guard !storeID.isEmpty, storeID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return "https://hgsldswk-alt.github.io/daynoted-support/"
        }
        return "https://apps.apple.com/app/id" + storeID
    }

    static func image(for address: String, side: Int = 192) -> CGImage? {
        guard let output = CIFilter(name: "CIQRCodeGenerator", parameters: [
            "inputMessage": Data(address.utf8),
            "inputCorrectionLevel": "M"
        ])?.outputImage else { return nil }
        let modules = Int(output.extent.width)
        let scale = max(side / (modules + 8), 1)
        let dimension = max(side, modules + 8)
        let quiet = CGFloat((dimension - modules * scale) / 2)
        let sized = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            .transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(dimension), height: CGFloat(dimension))
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        return CIContext().createCGImage(sized.composited(over: background), from: bounds)
    }
}

