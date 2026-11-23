import XCTest

final class DisplayScalerTests: XCTestCase {
    private typealias M = DisplayScaler.ModeInfo

    private func mode(_ w: Int, _ h: Int, hiDPI: Bool = false, hz: Double = 60, desktop: Bool = true) -> M {
        M(width: w, height: h, pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h,
          refreshRate: hz, usableForDesktop: desktop)
    }

    /// 27 吋 2560×1440 外接螢幕常見的模式
    private lazy var qhd: [M] = [
        mode(2560, 1440), mode(1920, 1080), mode(1920, 1080, hiDPI: true), mode(1600, 900),
        mode(1600, 900, hiDPI: true), mode(1280, 720, hiDPI: true), mode(1280, 720),
        mode(1280, 1024), mode(1024, 768), mode(640, 360, hiDPI: true),
    ]

    func testPicksClosestHiDPIModeWithSameAspect() {
        let original = mode(2560, 1440)
        let pick = { DisplayScaler.chooseMode(original: original, candidates: self.qhd, targetWidth: $0).map { self.qhd[$0] } }
        XCTAssertEqual(pick(1920), mode(1920, 1080, hiDPI: true))
        XCTAssertEqual(pick(1600), mode(1600, 900, hiDPI: true))
        XCTAssertEqual(pick(1280), mode(1280, 720, hiDPI: true))
    }

    func testNoChangeWhenAlreadySmallEnough() {
        // MacBook 內建螢幕預設 1512×982，目標 1920 時不需要調整
        let original = mode(1512, 982, hiDPI: true)
        XCTAssertNil(DisplayScaler.chooseMode(original: original, candidates: [mode(1147, 745, hiDPI: true)], targetWidth: 1920))
    }

    func testIgnoresOtherAspectRatiosAndNonDesktopModes() {
        let original = mode(2560, 1440)
        let candidates = [mode(1280, 1024), mode(1600, 900, desktop: false), mode(1680, 945, hz: 30), mode(1680, 945)]
        XCTAssertEqual(DisplayScaler.chooseMode(original: original, candidates: candidates, targetWidth: 1600), 3)
    }

    func testReturnsNilWithoutCandidates() {
        XCTAssertNil(DisplayScaler.chooseMode(original: mode(2560, 1440), candidates: [mode(1024, 768)], targetWidth: 1600))
    }
}
