import CoreGraphics
import Foundation

struct GameplayHUDRegion:
    Identifiable,
    Equatable {

    enum Kind:
        String,
        CaseIterable {

        case speedometer
        case speedOCR
        case minimap
        case checkpoint
    }

    let kind:
        Kind

    let name:
        String

    // Coordinates use a top-left origin and are stored
    // as fractions of the complete gameplay frame.
    let normalizedRect:
        CGRect

    var id:
        Kind {

        kind
    }

    func pixelRect(
        frameWidth:
            Int,
        frameHeight:
            Int
    ) -> CGRect {

        CGRect(
            x:
                normalizedRect.minX *
                CGFloat(frameWidth),
            y:
                normalizedRect.minY *
                CGFloat(frameHeight),
            width:
                normalizedRect.width *
                CGFloat(frameWidth),
            height:
                normalizedRect.height *
                CGFloat(frameHeight)
        )
        .integral
    }
}

enum MotorfestHUDLayout {

    static let speedUnit =
        "KM/H"

    // MARK: - Speedometer

    static let speedometer =
        GameplayHUDRegion(
            kind:
                .speedometer,
            name:
                "Speedometer",
            normalizedRect:
                CGRect(
                    x:
                        0.015,
                    y:
                        0.605,
                    width:
                        0.225,
                    height:
                        0.375
                )
        )

    // MARK: - Speed OCR

    static let speedOCR =
        GameplayHUDRegion(
            kind:
                .speedOCR,
            name:
                "Speed OCR",
            normalizedRect:
                CGRect(
                    x:
                        0.070,
                    y:
                        0.840,
                    width:
                        0.095,
                    height:
                        0.075
                )
        )

    // MARK: - Minimap Debug Region

    // Broad visual box used by the HUD overlay.
    static let minimap =
        GameplayHUDRegion(
            kind:
                .minimap,
            name:
                "Minimap / Route",
            normalizedRect:
                CGRect(
                    x:
                        0.785,
                    y:
                        0.590,
                    width:
                        0.205,
                    height:
                        0.390
                )
        )

    // MARK: - Minimap Computer Vision Crop

    // Tighter crop around the circular Motorfest minimap.
    //
    // Updated calibration:
    // - shifted left so routes near the left edge are preserved;
    // - shifted upward to capture the full circular minimap;
    // - keeps the crop tight enough to avoid excess gameplay.
    //
    // Coordinates calibrated against the current
    // 1920 x 1080 Motorfest HUD.
    static let minimapAnalysisRect =
        CGRect(
            x:
                0.780,
            y:
                0.620,
            width:
                0.180,
            height:
                0.325
        )

    // MARK: - Checkpoint

    static let checkpoint =
        GameplayHUDRegion(
            kind:
                .checkpoint,
            name:
                "Checkpoint",
            normalizedRect:
                CGRect(
                    x:
                        0.385,
                    y:
                        0.145,
                    width:
                        0.170,
                    height:
                        0.220
                )
        )

    // MARK: - Debug Regions

    static let debugRegions:
        [GameplayHUDRegion] = [
            speedometer,
            speedOCR,
            minimap,
            checkpoint
        ]
}
