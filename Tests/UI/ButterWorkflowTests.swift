import XCTest

extension ButterUITests {
	private func replace(_ identifier: String, with value: String) {
		let field = app.textFields[identifier]
		XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click()
		field.typeKey("a", modifierFlags: .command); field.typeText(value); field.typeKey(.tab, modifierFlags: [])
	}
	private func choose(_ identifier: String, _ value: String) {
		let control = app.descendants(matching: .any)[identifier].firstMatch
		XCTAssertTrue(control.waitForExistence(timeout: 5)); control.click(); app.menuItems[value].click()
	}
	func openPath(_ url: URL, selectAll: Bool = false) {
		let directory = selectAll ? url : url.deletingLastPathComponent()
		let file = selectAll ? (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().first) : url.lastPathComponent
		guard let file else { XCTFail("Missing torrent fixture"); return }
		app.typeKey("o", modifierFlags: .command)
		let panel = app.windows["open-panel"]
		XCTAssertTrue(panel.waitForExistence(timeout: 5))
		app.typeKey("g", modifierFlags: [.command, .shift])
		let navigation = panel.sheets["GoToWindow"], path = navigation.textFields["PathTextField"]
		XCTAssertTrue(path.waitForExistence(timeout: 5))
		path.click(); path.typeKey("a", modifierFlags: .command)
		path.typeText(directory.resolvingSymlinksInPath().path)
		XCTAssertTrue(navigation.tables.firstMatch.tableRows.firstMatch.waitForExistence(timeout: 5), "The Go to Folder sheet did not resolve the fixture directory")
		path.typeKey(.return, modifierFlags: [])
		let navigated = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: navigation)
		wait(for: [navigated], timeout: 5)
		let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
		let item = panel.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", [file, stem], [file, stem])).firstMatch
		XCTAssertTrue(item.waitForExistence(timeout: 10), panel.debugDescription)
		let windowFrame = panel.frame, itemFrame = item.frame
		XCTAssertTrue(windowFrame.contains(itemFrame), panel.debugDescription)
		let offset = CGVector(dx: itemFrame.midX - windowFrame.minX, dy: itemFrame.midY - windowFrame.minY)
		panel.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
		if selectAll { app.typeKey("a", modifierFlags: .command) }
		let open = panel.buttons["OKButton"]
		let enabled = expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: open)
		wait(for: [enabled], timeout: 5)
		open.click()
		XCTAssertTrue(app.buttons["torrent-add"].waitForExistence(timeout: 5))
	}
	private func savedPreferences() -> [String: Any]? {
		guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
			let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
		return saved["preferences"] as? [String: Any]
	}
	private func waitForPreferences(_ message: String, _ matches: @escaping ([String: Any]) -> Bool) {
		let saved = expectation(for: NSPredicate { _, _ in self.savedPreferences().map(matches) == true }, evaluatedWith: nil)
		saved.expectationDescription = message; wait(for: [saved], timeout: 5)
	}
	@objc func testQueuedSheetsAndMultipleSelection() throws {
		let incoming = root.appendingPathComponent("Incoming")
		try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
		for name in ["First bundle", "Second bundle"] {
			let info: [String: Any] = ["name": name, "length": 4, "piece length": 16384, "pieces": Data(repeating: 0, count: 20)]
			try bencode(["info": info]).write(to: incoming.appendingPathComponent(name + ".torrent"))
		}
		openPath(incoming, selectAll: true)
		let firstHeading = app.staticTexts["First bundle"].firstMatch
		let either = expectation(for: NSPredicate { _, _ in firstHeading.exists || self.app.staticTexts["Second bundle"].firstMatch.exists }, evaluatedWith: nil)
		wait(for: [either], timeout: 5); let first = firstHeading.exists ? "First bundle" : "Second bundle"
		app.buttons["torrent-add"].click()
		let second = first == "First bundle" ? "Second bundle" : "First bundle"
		XCTAssertTrue(app.staticTexts[second].waitForExistence(timeout: 5))
		app.buttons["torrent-add"].click()
		let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'transfer-row-'"))
		XCTAssertTrue(app.staticTexts["First bundle"].firstMatch.waitForExistence(timeout: 10))
		let both = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
		wait(for: [both], timeout: 5)
		rows.element(boundBy: 0).click()
		XCUIElement.perform(withKeyModifiers: .command) { rows.element(boundBy: 1).click() }
		app.menuBars.menuBarItems["Transfers"].click(); app.menuItems["Pause Selected"].click()
		let paused = expectation(for: NSPredicate { _, _ in
			guard let data = try? Data(contentsOf: self.root.appendingPathComponent("state.json")), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let records = state["transfers"] as? [[String: Any]] else { return false }
			return records.count == 2 && records.allSatisfy { $0["wanted"] as? Bool == false }
		}, evaluatedWith: nil)
		let pauseResult = XCTWaiter.wait(for: [paused], timeout: 5)
		let saved = (try? String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)) ?? "Unreadable state"
		XCTAssertEqual(pauseResult, .completed, "Saved state: \(saved)\n\(app.debugDescription)")
		app.menuBars.menuBarItems["Transfers"].click(); app.menuItems["Remove Selected"].click()
		XCTAssertTrue(app.staticTexts["No transfers"].waitForExistence(timeout: 5))
	}
	@objc func testLocalFolderAndFileRename() throws {
		let source = root.appendingPathComponent("Downloads/folder")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
		let original = Data([9, 8, 7, 6])
		try original.write(to: source.appendingPathComponent("a.bin")); try original.write(to: source.appendingPathComponent("b.bin"))
		openPath(root.appendingPathComponent("fixture.torrent"))
		app.buttons["torrent-add"].click()
		let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'transfer-row-'")).firstMatch
		XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click(); app.radioButtons["Files"].click()
		app.checkBoxes["Download folder"].rightClick(); app.menuItems["Rename Local Folder"].click()
		replace("local-name", with: "renamed")
		XCTAssertTrue(app.checkBoxes["Download renamed"].waitForExistence(timeout: 10))
		app.checkBoxes["Download a.bin"].rightClick(); app.menuItems["Rename Local File"].click()
		replace("local-name", with: "new.bin")
		XCTAssertTrue(app.checkBoxes["Download new.bin"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.staticTexts["Original: a.bin"].exists)
		XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Downloads/renamed/new.bin")), original)
		XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Downloads/renamed/b.bin")), original)
	}
	@objc func testBandwidthLimitsPersistInDecimalMegabytes() {
		app.typeKey(",", modifierFlags: .command); app.buttons["Transfers"].click()
		app.windows.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
		let separator = Locale.current.decimalSeparator ?? "."
		replace("download-bandwidth", with: "62" + separator + "5")
		replace("upload-bandwidth", with: "1" + separator + "25")
		waitForPreferences("Fractional bandwidth limits persist in bytes per second") {
			$0["downloadLimit"] as? Int == 62_500_000 && $0["uploadLimit"] as? Int == 1_250_000
		}
		replace("download-bandwidth", with: "0")
		waitForPreferences("Download cap clears independently") { $0["downloadLimit"] == nil && $0["uploadLimit"] as? Int == 1_250_000 }
	}
	@objc func testGroupAndTrackerEditorsPersist() {
		app.typeKey(",", modifierFlags: .command); app.buttons["Groups"].click(); app.buttons["Add group"].click()
		replace("group-name", with: "Linux")
		choose("group-colour", "Green"); choose("group-priority", "High")
		replace("group-tracker-hosts", with: "tracker.example"); replace("group-min-size", with: "1")
		replace("group-max-size", with: "2"); replace("group-keywords", with: "linux, image")
		app.buttons["Add group"].click(); replace("group-name", with: "Second")
		app.buttons["Move selected group earlier"].click()
		waitForPreferences("Group order persists") { ($0["groups"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["Second", "Linux"] }
		app.buttons["Delete selected group"].click()
		waitForPreferences("Group removal persists") { ($0["groups"] as? [[String: Any]])?.count == 1 }
		app.buttons["Favourite Trackers"].click()
		replace("tracker-name", with: "Local"); replace("tracker-url", with: "https://:80/announce")
		XCTAssertFalse(app.buttons["Add Favourite"].isEnabled)
		replace("tracker-url", with: "http://127.0.0.1:1/announce"); app.buttons["Add Favourite"].click()
		app.buttons["Edit"].click(); replace("tracker-url", with: "http://127.0.0.1:2/announce"); app.buttons["Save Changes"].click()
		waitForPreferences("Tracker edit persists") { ($0["trackers"] as? [[String: Any]])?.first?["url"] as? String == "http://127.0.0.1:2/announce" }
		app.buttons["Edit"].click(); replace("tracker-name", with: "Discarded"); app.buttons["Cancel"].click()
		XCTAssertTrue(app.staticTexts["Local"].exists); XCTAssertFalse(app.staticTexts["Discarded"].exists)
		app.terminate(); app.launch(); app.typeKey(",", modifierFlags: .command); app.buttons["Groups"].click(); app.staticTexts["Linux"].click()
		XCTAssertEqual(app.textFields["group-min-size"].value as? String, "1")
		XCTAssertEqual(app.textFields["group-tracker-hosts"].value as? String, "tracker.example")
		XCTAssertEqual(app.textFields["group-keywords"].value as? String, "linux, image")
		app.buttons["Favourite Trackers"].click(); app.buttons["Delete favourite tracker Local"].click()
		waitForPreferences("Tracker removal persists") { ($0["trackers"] as? [[String: Any]])?.isEmpty == true }
	}
	@objc func testAllTabsCompositorCaptures() {
		openPath(root.appendingPathComponent("fixture.torrent")); app.buttons["torrent-add"].click()
		let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'transfer-row-'")).firstMatch
		XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
		for style in ["Light", "Dark"] {
			app.typeKey(",", modifierFlags: .command); app.buttons["General"].click(); choose("appearance", style)
			for tab in ["General", "Transfers", "Network", "Groups", "Favourite Trackers"] {
				app.buttons[tab].click()
				if tab == "Groups" && app.buttons["Add group"].exists { app.buttons["Add group"].click(); replace("group-name", with: "Long group name for layout and accessibility review") }
				if tab == "Groups" { XCTAssertGreaterThanOrEqual(app.textFields["group-name"].frame.width, 150, "Long list names must not collapse the group editor") }
				capture("Settings-\(tab)-\(style)")
			}
			app.typeKey("w", modifierFlags: .command)
			for tab in ["Info", "Trackers", "Peers", "Files"] { app.radioButtons[tab].click(); capture("Inspector-\(tab)-\(style)") }
			row.click(); capture("SelectedTransfer-\(style)")
			row.rightClick(); app.typeKey(.downArrow, modifierFlags: [])
			capture("SelectedTransferMenu-\(style)"); app.typeKey(.escape, modifierFlags: [])
		}
	}
	private func capture(_ name: String) {
		let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
		attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
	}
}
