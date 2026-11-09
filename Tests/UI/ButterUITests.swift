import XCTest

final class ButterUITests: XCTestCase {
	private var root: URL!
	private var app: XCUIApplication!
	override func setUpWithError() throws {
		continueAfterFailure = false
		root = FileManager.default.temporaryDirectory.appendingPathComponent("ButterUI-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try Data().write(to: root.appendingPathComponent(".butter-ui-test"))
		let metadata: [String: Any] = ["info": ["name": "folder", "piece length": 16384, "pieces": Data(repeating: 0, count: 20), "files": [["length": 4, "path": ["a.bin"]], ["length": 4, "path": ["b.bin"]]]]]
		try bencode(metadata).write(to: root.appendingPathComponent("fixture.torrent"))
		app = XCUIApplication()
		app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
		app.launchEnvironment["BUTTER_UI_TEST_ROOT"] = root.path
		app.launch()
		XCTAssertTrue(app.buttons["add-magnet"].waitForExistence(timeout: 15))
	}
	override func tearDownWithError() throws {
		app?.terminate()
		if let root { try FileManager.default.removeItem(at: root) }
	}
	func testMagnetSheetAndKeyboardShortcuts() {
		app.typeKey("l", modifierFlags: .command)
		let field = app.textFields["magnet-link"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		XCTAssertFalse(app.buttons["magnet-continue"].isEnabled)
		field.click(); field.typeText("magnet:?xt=urn:btih:0123456789012345678901234567890123456789")
		app.buttons["magnet-continue"].click()
		XCTAssertTrue(app.buttons["torrent-add"].waitForExistence(timeout: 5))
		app.buttons["torrent-add"].click()
		XCTAssertTrue(app.staticTexts["Resolving metadata"].waitForExistence(timeout: 10))
		app.typeKey("i", modifierFlags: [.command, .option])
		XCTAssertEqual(app.buttons["toggle-inspector"].value as? String, "Hidden")
		app.typeKey("i", modifierFlags: [.command, .option])
		XCTAssertEqual(app.buttons["toggle-inspector"].value as? String, "Shown")
	}
	func testSearchAndSettings() {
		let search = app.searchFields["transfer-search"]
		XCTAssertTrue(search.exists)
		search.click(); search.typeText("missing")
		XCTAssertTrue(app.staticTexts["No matching transfers"].waitForExistence(timeout: 5))
		search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])
		XCTAssertTrue(app.staticTexts["No transfers"].waitForExistence(timeout: 5))
		app.typeKey("n", modifierFlags: .command)
		XCTAssertTrue(app.staticTexts["Create Torrent"].waitForExistence(timeout: 5))
		XCTAssertFalse(app.buttons["Create"].isEnabled)
		app.typeKey(.escape, modifierFlags: [])
		app.typeKey(",", modifierFlags: .command)
		XCTAssertTrue(app.buttons["Register for Magnet Links"].waitForExistence(timeout: 5))
		app.buttons["Register for Magnet Links"].click()
		XCTAssertTrue(app.staticTexts["Isolated test configuration."].waitForExistence(timeout: 5))
	}
	func testTorrentFilesSelectionAndRemoval() {
		app.typeKey("o", modifierFlags: .command)
		app.typeKey("g", modifierFlags: [.command, .shift])
		app.typeText(root.appendingPathComponent("fixture.torrent").path)
		app.typeKey(.return, modifierFlags: [])
		let open = app.buttons["Open"].firstMatch
		XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
		let add = app.buttons["torrent-add"]
		XCTAssertTrue(add.waitForExistence(timeout: 5))
		app.checkBoxes["folder/b.bin"].click()
		add.click()
		let row = app.staticTexts["folder"].firstMatch
		XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
		app.menuBars.menuBarItems["Transfers"].click(); app.menuItems["Pause Selected"].click()
		XCTAssertTrue(app.staticTexts["Paused"].firstMatch.waitForExistence(timeout: 5))
		app.menuBars.menuBarItems["Transfers"].click(); app.menuItems["Force Start Selected"].click()
		app.radioButtons["Files"].click()
		let folder = app.checkBoxes["Download folder"]
		XCTAssertTrue(folder.waitForExistence(timeout: 5))
		XCTAssertEqual((folder.value as? NSNumber)?.intValue, 2)
		folder.click()
		let a = app.checkBoxes["Download a.bin"], b = app.checkBoxes["Download b.bin"]
		XCTAssertTrue(a.waitForExistence(timeout: 5))
		let selected = NSPredicate(format: "value == 1")
		expectation(for: selected, evaluatedWith: a); expectation(for: selected, evaluatedWith: b)
		waitForExpectations(timeout: 5)
		app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'transfer-row-'")).firstMatch.rightClick()
		app.menuItems["Rename…"].click()
		let rename = app.textFields["transfer-name"]
		XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.click(); rename.typeKey("a", modifierFlags: .command); rename.typeText("Renamed fixture")
		app.buttons["Rename"].click()
		XCTAssertTrue(app.staticTexts["Renamed fixture"].firstMatch.waitForExistence(timeout: 5))
		app.menuBars.menuBarItems["Transfers"].click()
		app.menuItems["Remove and Delete Data…"].click()
		XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); app.buttons["Cancel"].click()
		app.menuBars.menuBarItems["Transfers"].click(); app.menuItems["Remove Selected"].click()
		XCTAssertTrue(app.staticTexts["No transfers"].waitForExistence(timeout: 5))
	}
	func testTypedPeerLimitAndPersistence() {
		app.typeKey(",", modifierFlags: .command)
		app.buttons["Network"].click()
		let peers = app.textFields["Global peer limit"]
		XCTAssertTrue(peers.waitForExistence(timeout: 5)); peers.click(); peers.typeKey("a", modifierFlags: .command); peers.typeText("321"); peers.typeKey(.tab, modifierFlags: [])
		XCTAssertEqual(peers.value as? String, "321")
		app.windows.firstMatch.typeKey("w", modifierFlags: .command)
		app.typeKey("q", modifierFlags: .command)
		XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
		app.launch(); app.typeKey(",", modifierFlags: .command); app.buttons["Network"].click()
		XCTAssertTrue(peers.waitForExistence(timeout: 5)); XCTAssertEqual(peers.value as? String, "321")
	}
	func testAppearanceAndQuitConfirmation() {
		app.typeKey(",", modifierFlags: .command)
		app.buttons["General"].click()
		let appearance = app.descendants(matching: .any)["appearance"].firstMatch
		XCTAssertTrue(appearance.waitForExistence(timeout: 5))
		for style in ["Light", "Dark"] {
			appearance.click(); app.menuItems[style].click()
			let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
			screenshot.name = "Settings-\(style)"; screenshot.lifetime = .keepAlways; add(screenshot)
		}
		app.descendants(matching: .any)["quit-mode"].firstMatch.click(); app.menuItems["Always"].click()
		app.typeKey("w", modifierFlags: .command); app.typeKey("q", modifierFlags: .command)
		XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); app.buttons["Cancel"].click()
		XCTAssertEqual(app.state, .runningForeground)
		app.typeKey(",", modifierFlags: .command); app.buttons["General"].click()
		app.descendants(matching: .any)["quit-mode"].firstMatch.click(); app.menuItems["Never"].click()
		app.typeKey("w", modifierFlags: .command); app.typeKey("q", modifierFlags: .command)
		XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
	}
	private func bencode(_ value: Any) -> Data {
		if let bytes = value as? Data { return Data("\(bytes.count):".utf8) + bytes }
		if let text = value as? String { return bencode(Data(text.utf8)) }
		if let number = value as? Int { return Data("i\(number)e".utf8) }
		if let array = value as? [Any] { return Data("l".utf8) + array.reduce(Data()) { $0 + bencode($1) } + Data("e".utf8) }
		let dictionary = value as! [String: Any]
		return Data("d".utf8) + dictionary.keys.sorted().reduce(Data()) { $0 + bencode($1) + bencode(dictionary[$1]!) } + Data("e".utf8)
	}
}
