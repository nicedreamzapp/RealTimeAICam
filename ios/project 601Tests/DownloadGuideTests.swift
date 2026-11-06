import XCTest
@testable import RealTime_Ai_Cam

/// Apple's download window waits for a tap (real iPhone 12, 2026-11-05): the guide says where
/// the button is, reminds while it waits, and says once if it closed without the language.
final class DownloadGuideTests: XCTestCase {
    func testWindowOpeningSaysWhereTheButtonIsOnce() {
        var g = DownloadGuide(start: 0)
        XCTAssertNil(g.tick(sheetShowing: false, now: 1))
        XCTAssertEqual(g.tick(sheetShowing: true, now: 2), .sheetOpened)
        XCTAssertNil(g.tick(sheetShowing: true, now: 3))
    }

    func testWhileTheWindowWaitsItRemindsNotStillDownloading() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        var said: [(TimeInterval, DownloadGuide.Line)] = []
        for t in stride(from: 2.0, through: 300, by: 1) {
            if let l = g.tick(sheetShowing: true, now: t) { said.append((t, l)) }
        }
        XCTAssertTrue(said.allSatisfy { $0.1 == .sheetWaiting }, "\(said)")
        // Three at 15 s, then once a minute: 16, 31, 46, 106, 166, 226, 286.
        XCTAssertEqual(said.map(\.0), [16, 31, 46, 106, 166, 226, 286])
    }

    func testNoWindowKeepsTheStillDownloadingLine() {
        var g = DownloadGuide(start: 0)
        var said: [DownloadGuide.Line] = []
        for t in stride(from: 1.0, through: 45, by: 1) {
            if let l = g.tick(sheetShowing: false, now: t) { said.append(l) }
        }
        XCTAssertEqual(said, [.stillDownloading, .stillDownloading, .stillDownloading])
    }

    func testWindowClosedWithoutTheLanguageSaysSoAndHowToRetry() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        // Gone while Apple keeps going: the plain progress line again, never the tap reminder.
        var after: [DownloadGuide.Line] = []
        for t in stride(from: 2.0, through: 45, by: 1) {
            if let l = g.tick(sheetShowing: false, now: t) { after.append(l) }
        }
        XCTAssertEqual(after, [.stillDownloading, .stillDownloading])
        XCTAssertEqual(g.finished(ok: false), .sheetClosed)
        XCTAssertEqual(g.finished(ok: true), .ready)
        XCTAssertEqual(DownloadGuide(start: 0).finished(ok: false), .failed)
    }

    /// Up for minutes, then gone: no progress line on the very tick it closes.
    func testLongOpenWindowClosingIsQuietForFifteenSeconds() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        for t in stride(from: 2.0, through: 150, by: 1) { _ = g.tick(sheetShowing: true, now: t) }
        // Last reminder at 106; closed at 151 (45 s later).
        XCTAssertNil(g.tick(sheetShowing: false, now: 151))
        XCTAssertNil(g.tick(sheetShowing: false, now: 165))
        XCTAssertEqual(g.tick(sheetShowing: false, now: 166), .stillDownloading)
    }

    func testLinesInEnglishAndSpanish() {
        UserDefaults.standard.set("en", forKey: AppLang.forcedKey)
        XCTAssertTrue(DownloadGuide.text(.sheetOpened, code: "es").contains("lower half of the screen"))
        XCTAssertTrue(DownloadGuide.text(.sheetClosed, code: "es").contains("Check the internet connection"))
        XCTAssertTrue(DownloadGuide.text(.sheetClosed, code: "es").contains("tap Download Spanish again"))
        UserDefaults.standard.set("es", forKey: AppLang.forcedKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLang.forcedKey) }
        XCTAssertEqual(DownloadGuide.text(.sheetOpened, code: "es"),
                       "Apple abrió una ventana para descargar español, en la mitad de abajo de la pantalla. Toca el botón redondo con una flecha hacia abajo a la derecha, junto a los nombres de los idiomas.")
        XCTAssertTrue(DownloadGuide.text(.sheetWaiting, code: "es").hasPrefix("La descarga de español espera tu toque"))
        XCTAssertEqual(DownloadGuide.text(.sheetClosed, code: "es"),
                       "La ventana de descarga de Apple se cerró antes de descargar español. Revisa la conexión a internet y vuelve a tocar Descarga español en Ajustes, en Tu idioma.")
    }
}
