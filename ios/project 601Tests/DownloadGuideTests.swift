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
        // Closed at 2 (counted after 1.5 s away), progress line 15 s after that is noticed.
        XCTAssertEqual(after, [.stillDownloading, .stillDownloading])
        XCTAssertEqual(g.finished(ok: true, now: 46), .ready)
        XCTAssertEqual(DownloadGuide(start: 0).finished(ok: false, now: 10), .failed)
    }

    /// X on the window: Apple answers right away, so it closed without the language.
    func testClosedWithXSaysClosed() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        _ = g.tick(sheetShowing: false, now: 2)
        XCTAssertEqual(g.finished(ok: false, now: 2.5), .sheetClosed)
        // Apple gave up with the window still open: also closed.
        var h = DownloadGuide(start: 0)
        _ = h.tick(sheetShowing: true, now: 1)
        XCTAssertEqual(h.finished(ok: false, now: 450), .sheetClosed)
    }

    /// Tapped, the window went, Apple kept going and then failed: the download failed.
    func testFailureAfterTheTapIsADownloadFailure() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        for t in stride(from: 2.0, through: 5, by: 1) { _ = g.tick(sheetShowing: false, now: t) }
        XCTAssertEqual(g.finished(ok: false, now: 30), .failed)
    }

    /// A window that comes back gets the where-the-button-is line again.
    func testReopenedWindowSaysWhereTheButtonIsAgain() {
        var g = DownloadGuide(start: 0)
        XCTAssertEqual(g.tick(sheetShowing: true, now: 1), .sheetOpened)
        for t in stride(from: 2.0, through: 5, by: 1) { _ = g.tick(sheetShowing: false, now: t) }
        XCTAssertEqual(g.tick(sheetShowing: true, now: 6), .sheetOpened)
    }

    /// Away for under 1.5 s is a flicker: no new opened line, reminders keep their schedule.
    func testFlickerIsNotAClose() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        XCTAssertNil(g.tick(sheetShowing: false, now: 2))
        XCTAssertNil(g.tick(sheetShowing: true, now: 3))
        XCTAssertTrue(g.sheetUp)
        for t in stride(from: 4.0, through: 15, by: 1) { XCTAssertNil(g.tick(sheetShowing: true, now: t)) }
        XCTAssertEqual(g.tick(sheetShowing: true, now: 16), .sheetWaiting)
    }

    /// Locked for two minutes: no line on the first tick after waking, the wait starts over.
    func testNoLineRightAfterAnUnlock() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        XCTAssertNil(g.tick(sheetShowing: true, now: 121))
        for t in stride(from: 122.0, through: 138, by: 1) { XCTAssertNil(g.tick(sheetShowing: true, now: t)) }
        XCTAssertEqual(g.tick(sheetShowing: true, now: 139), .sheetWaiting)
    }

    /// Apple's window came up while the phone was locked: quiet for 3 s after waking, then where the button is.
    func testWindowThatOpenedDuringALockWaitsAfterWaking() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: false, now: 1)
        XCTAssertNil(g.tick(sheetShowing: true, now: 100))
        XCTAssertNil(g.tick(sheetShowing: true, now: 101))
        XCTAssertNil(g.tick(sheetShowing: true, now: 102))
        XCTAssertEqual(g.tick(sheetShowing: true, now: 103), .sheetOpened)
    }

    /// Up for minutes, then gone: no progress line on the very tick it closes.
    func testLongOpenWindowClosingIsQuietForFifteenSeconds() {
        var g = DownloadGuide(start: 0)
        _ = g.tick(sheetShowing: true, now: 1)
        for t in stride(from: 2.0, through: 150, by: 1) { _ = g.tick(sheetShowing: true, now: t) }
        // Last reminder at 106; away from 151, counted closed at 153 (after 1.5 s).
        XCTAssertNil(g.tick(sheetShowing: false, now: 151))
        XCTAssertNil(g.tick(sheetShowing: false, now: 152))
        XCTAssertNil(g.tick(sheetShowing: false, now: 153))
        for t in stride(from: 154.0, through: 167, by: 1) { XCTAssertNil(g.tick(sheetShowing: false, now: t)) }
        XCTAssertEqual(g.tick(sheetShowing: false, now: 168), .stillDownloading)
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
                       "Español no se descargó: la ventana de Apple se cerró antes, o la descarga se detuvo. Revisa la conexión a internet y vuelve a tocar Descarga español en Ajustes, en Tu idioma.")
    }
}
