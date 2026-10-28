import XCTest

final class WowNavigationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlanReminderTwoMinuteNotificationWhileClosed() throws {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let title = "Test Plan " + UUID().uuidString.prefix(6)
        app.launch()
        app.buttons["Open today’s plans"].tap()
        app.buttons["Add a plan"].tap()
        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons.matching(NSPredicate(format: "identifier == 'wow.editor.save'")).firstMatch.tap()
        let bell = app.buttons["提醒：" + title]
        XCTAssertTrue(bell.waitForExistence(timeout: 5), app.debugDescription)
        bell.tap()
        let picker = app.datePickers["plan.reminder.date"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        // Compact date/time control opens the native time wheels.
        picker.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch.tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let target = Date().addingTimeInterval(120)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: target)
        let hour = parts.hour!
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: String(hour % 12 == 0 ? 12 : hour % 12))
        if wheels.count > 2 { wheels.element(boundBy: 2).adjust(toPickerWheelValue: hour < 12 ? "AM" : "PM") }
        let minuteWheel = wheels.element(boundBy: 1)
        // Native wheel adjustment can settle on an adjacent row; confirm the actual selected value.
        for _ in 0..<3 {
            minuteWheel.adjust(toPickerWheelValue: String(format: "%02d", parts.minute!))
            let minuteSelected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Int((minuteWheel.value as? String ?? "").split(separator: " ").first ?? "") == parts.minute!
            }, object: minuteWheel)
            if XCTWaiter.wait(for: [minuteSelected], timeout: 2) == .completed { break }
        }
        XCTAssertEqual(Int((minuteWheel.value as? String ?? "").split(separator: " ").first ?? ""), parts.minute!)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        app.buttons.matching(NSPredicate(format: "identifier == 'plan.reminder.save'")).firstMatch.tap()
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            let allow = springboard.alerts.buttons["Allow"]
            XCTAssertTrue(allow.exists, springboard.debugDescription)
            allow.tap()
        }
        XCTAssertTrue(bell.waitForExistence(timeout: 5), app.debugDescription)
        let subtitle = app.buttons["Edit " + title].staticTexts.matching(NSPredicate(format: "label CONTAINS '提醒 ·'")).firstMatch
        XCTAssertTrue(subtitle.exists)
        let expectedTime = target.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
        print("Native reminder target: \(target); persisted subtitle: \(subtitle.label)")
        XCTAssertTrue(subtitle.label.contains(expectedTime), "Selected time must match the saved reminder: \(expectedTime) / \(subtitle.label)")
        app.terminate()
        XCTAssertTrue(springboard.staticTexts[title].waitForExistence(timeout: 160), springboard.debugDescription)
        attachScreenshot(springboard, name: "Native Plan notification with Wow terminated")
        app.launch()
        app.buttons["Open today’s plans"].tap()
        XCTAssertTrue(app.buttons["Edit " + title].waitForExistence(timeout: 5))
        app.buttons["Edit " + title].tap()
        app.buttons["Delete"].tap()
        XCTAssertFalse(app.buttons["Edit " + title].exists)
    }

    // Run on a fresh isolated simulator; retained QA accounts are used in screenshot evidence.
    func testCounterCustomAccountWalletCreationEditingPersistenceAndTransfer() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        createCounterAccount(app, preset: "yuebao", name: "余额宝", icon: "alipay", balance: "100.00")
        createCounterAccount(app, preset: "investment", name: "基金", icon: "fund", balance: "100.00")
        createCounterAccount(app, preset: "cash", name: "纸币现金", icon: "cash", balance: "100.00")
        XCTAssertTrue(walletCard(app, name: "余额宝").exists)
        XCTAssertTrue(walletCard(app, name: "基金").exists)
        XCTAssertTrue(walletCard(app, name: "纸币现金").exists)
        attachScreenshot(app, name: "Wallet with custom names and three distinct icons")

        // Metadata-only edit must preserve the displayed current balance.
        let fund = walletCard(app, name: "基金")
        scrollTo(fund, in: app)
        XCTAssertLessThan(fund.frame.height, 110, "Every account starts compact, including the first")
        fund.tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(app, name: "V2 expanded account and ledger")
        app.buttons["accounts.edit"].tap()
        let name = app.textFields["account.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(name, with: "长期基金")
        app.buttons["account.chooseIcon"].tap()
        app.buttons["account.cardIcon.investment"].tap()
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        app.buttons["accounts.closeDetail"].tap()
        XCTAssertTrue(walletCard(app, name: "长期基金").label.contains("100.00"))

        let netWorthBefore = app.staticTexts["accounts.netWorth"].label
        app.buttons["accounts.transfer"].tap()
        let amount = app.textFields["transfer.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("10.00")
        app.buttons["transfer.save"].tap()
        XCTAssertTrue(app.buttons["accounts.transfer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["accounts.netWorth"].label, netWorthBefore)
        XCTAssertTrue(walletCard(app, name: "余额宝").label.contains("90.00"))
        XCTAssertTrue(walletCard(app, name: "长期基金").label.contains("110.00"))

        app.terminate()
        app.launch()
        openCounterAccounts(app)
        XCTAssertTrue(walletCard(app, name: "余额宝").label.contains("90.00"))
        XCTAssertTrue(walletCard(app, name: "长期基金").label.contains("110.00"))
        XCTAssertTrue(walletCard(app, name: "纸币现金").label.contains("100.00"))
        // Verify the selected icon is still the editor's choice after a full launch.
        let reopenedFund = walletCard(app, name: "长期基金")
        scrollTo(reopenedFund, in: app)
        reopenedFund.tap()
        app.buttons["accounts.edit"].tap()
        XCTAssertTrue(app.buttons["account.chooseIcon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["account.chooseIcon"].label.contains("投资"))
        attachScreenshot(app, name: "Persisted account name and icon in shared editor")
        app.buttons["取消"].tap()
        app.buttons["accounts.closeDetail"].tap()

        // Enough cards to exceed the viewport, using the same unified custom creation flow.
        for index in 1...8 {
            createCounterAccount(app, preset: "custom", name: "备用账户 \(index)", icon: index.isMultiple(of: 2) ? "star" : "wallet")
        }
        XCTAssertTrue(walletCard(app, name: "备用账户 8").isHittable, "The new account is visible at the top")
        attachScreenshot(app, name: "V2 eleven accounts default collapsed")
        let first = walletCard(app, name: "备用账户 8")
        let previous = walletCard(app, name: "备用账户 7")
        previous.press(forDuration: 1.2, thenDragTo: first, withVelocity: .slow, thenHoldForDuration: 1.0)
        XCTAssertLessThan(previous.frame.minY, first.frame.minY, "Native drag reordering must still work")
        let last = walletCard(app, name: "余额宝")
        scrollTo(last, in: app)
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(app.buttons["accounts.add"].isHittable)
        XCTAssertTrue(app.buttons["accounts.transfer"].isHittable)
        XCTAssertFalse(app.buttons["accounts.addBottom"].exists, "No duplicate or obstructing bottom add action")
        attachScreenshot(app, name: "V2 lower accounts scrolling with unobstructed actions")
        last.tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        app.buttons["accounts.closeDetail"].tap()
    }

    // Run on an isolated simulator: exercise changing the recipient, not just its default value.
    func testCounterBorrowingIntoCashKeepsLiabilityAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        openCounterAccounts(app)
        let suffix = String(UUID().uuidString.prefix(6))
        let wechatName = "收款微信 " + suffix
        let cashName = "收款现金 " + suffix
        let creditorName = "出借人妈妈 " + suffix
        func createRecipient(preset: String, name: String, balance: String) {
            app.buttons["accounts.add"].tap()
            let option = app.buttons["account.provider." + preset]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            scrollTo(option, in: app)
            option.tap()
            XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
            replaceText(app.textFields["account.name"], with: name)
            app.buttons["account.dismissKeyboard"].tap()
            let amount = app.textFields["account.balance"]
            scrollTo(amount, in: app)
            replaceText(amount, with: balance)
            app.buttons["account.save"].tap()
            XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
        }
        createRecipient(preset: "wechat", name: wechatName, balance: "10.00")
        createRecipient(preset: "cash", name: cashName, balance: "100.00")
        let netWorthBefore = app.staticTexts["accounts.netWorth"].label
        app.buttons["accounts.add"].tap()
        let borrowing = app.buttons["account.provider.borrowing"]
        XCTAssertTrue(borrowing.waitForExistence(timeout: 5), app.debugDescription)
        borrowing.tap()
        XCTAssertTrue(app.buttons["account.type"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.type"].isEnabled, "Borrowing must retain the creditor's liability nature")
        replaceText(app.textFields["account.name"], with: creditorName)
        app.buttons["account.dismissKeyboard"].tap()
        replaceText(app.textFields["account.balance"], with: "14284.00")
        app.buttons["account.dismissKeyboard"].tap()
        let recipient = app.buttons["account.borrowing.recipient"]
        scrollTo(recipient, in: app)
        recipient.tap()
        let cash = app.buttons[cashName]
        XCTAssertTrue(cash.waitForExistence(timeout: 5), app.debugDescription)
        cash.tap()
        XCTAssertTrue(app.buttons["account.type"].label.contains("借入"), app.debugDescription)
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5), app.debugDescription)
        let mother = walletCard(app, name: creditorName)
        XCTAssertTrue(mother.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mother.label.contains("欠款 ¥14284.00"), mother.label)
        XCTAssertTrue(walletCard(app, name: cashName).label.contains("余额 ¥14384.00"))
        XCTAssertTrue(walletCard(app, name: wechatName).label.contains("余额 ¥10.00"))
        XCTAssertEqual(app.staticTexts["accounts.netWorth"].label, netWorthBefore)
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        XCTAssertTrue(walletCard(app, name: creditorName).label.contains("欠款 ¥14284.00"))
        XCTAssertTrue(walletCard(app, name: cashName).label.contains("余额 ¥14384.00"))
        XCTAssertEqual(app.staticTexts["accounts.netWorth"].label, netWorthBefore)
    }

    private func openCounterAccounts(_ app: XCUIApplication) {
        let mascot = app.buttons["wow.counterMascot"]
        XCTAssertTrue(mascot.waitForExistence(timeout: 10))
        mascot.tap()
        let companion = app.buttons["home.companionMenu"]
        XCTAssertTrue(companion.waitForExistence(timeout: 8))
        companion.tap()
        let accounts = app.buttons["home.companion.账户"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
    }

    private func createCounterAccount(_ app: XCUIApplication, preset: String, name: String, icon: String, balance: String? = nil) {
        app.buttons["accounts.add"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if preset == "yuebao" {
            attachScreenshot(app, name: "V2 searchable account chooser")
            search.tap()
            search.typeText("余额宝")
            XCTAssertFalse(app.buttons["account.provider.wechat"].exists)
        } else if preset == "investment" {
            search.tap()
            search.typeText("基金")
        } else if preset == "cash" {
            search.tap()
            search.typeText("现金")
        }
        let option = app.buttons["account.provider." + preset]
        scrollTo(option, in: app)
        option.tap()
        let field = app.textFields["account.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if field.value as? String != name { replaceText(field, with: name) }
        if app.buttons["account.dismissKeyboard"].exists { app.buttons["account.dismissKeyboard"].tap() }
        let chooseIcon = app.buttons["account.chooseIcon"]
        scrollTo(chooseIcon, in: app)
        chooseIcon.tap()
        let iconOption = app.buttons["account.cardIcon." + icon]
        scrollTo(iconOption, in: app)
        iconOption.tap()
        if let balance {
            let amount = app.textFields["account.balance"]
            scrollTo(amount, in: app)
            replaceText(amount, with: balance)
        }
        if preset == "custom" && name == "备用账户 1" { attachScreenshot(app, name: "V2 custom name icon category balance editor") }
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(walletCard(app, name: name).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(walletCard(app, name: name).isHittable, "Saved account must be visible")
        if preset == "cash" { attachScreenshot(app, name: "V2 three accounts created successfully") }
    }

    private func walletCard(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'accounts.card.' AND label BEGINSWITH %@", name + "，")).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let exists = element.exists
            if exists {
                let isCard = element.identifier.hasPrefix("accounts.card.")
                let fitsViewport = !isCard || (element.frame.minY >= 108 && element.frame.maxY <= app.frame.maxY - 34)
                if element.isHittable && fitsViewport { return }
            }
            // Native Form/List virtualizes offscreen rows: an absent element still requires scrolling.
            let scroll = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                ?? app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                ?? app.scrollViews.firstMatch
            if exists && element.frame.maxY < 108 { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty && (existing != field.placeholderValue || field.identifier == "account.balance") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    // A short recheck for the populated QA ledger left by the full creation scenario.
    func testCounterPopulatedWalletReorderAndCategoryEditing() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        let first = walletCard(app, name: "备用账户 8")
        let moving = walletCard(app, name: "备用账户 7")
        guard first.exists && moving.exists else { throw XCTSkip("Run the complete account creation scenario on an isolated QA simulator first") }
        let upper = moving.frame.minY < first.frame.minY ? moving : first
        let lower = moving.frame.minY < first.frame.minY ? first : moving
        lower.press(forDuration: 1.2, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 1.0)
        XCTAssertLessThan(lower.frame.minY, upper.frame.minY)
        attachScreenshot(app, name: "V2 final eleven accounts collapsed")
        let fund = walletCard(app, name: "长期基金")
        scrollTo(fund, in: app)
        attachScreenshot(app, name: "V2 final lower accounts")
        fund.tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "V2 final expanded account")
        app.buttons["accounts.edit"].tap()
        XCTAssertTrue(app.buttons["account.type"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["account.name"].value as? String, "长期基金")
        app.buttons["account.type"].tap()
        XCTAssertFalse(app.buttons["信用卡"].exists, "Existing assets must not be reinterpreted as liabilities")
        app.buttons["account.type.eWallet"].tap()
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["电子钱包"].exists)
        app.buttons["accounts.edit"].tap()
        XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["account.name"].value as? String, "长期基金")
        app.buttons["account.type"].tap()
        app.buttons["account.type.investment"].tap()
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        app.buttons["accounts.closeDetail"].tap()
        scrollTo(walletCard(app, name: "长期基金"), in: app)
        XCTAssertTrue(walletCard(app, name: "长期基金").label.contains("110.00"))
        XCTAssertTrue(walletCard(app, name: "长期基金").label.contains("投资账户"))

        // Verify the second account identity and its unchanged amount when editing its category.
        let cash = walletCard(app, name: "纸币现金")
        scrollTo(cash, in: app)
        cash.tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        app.buttons["accounts.edit"].tap()
        XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["account.name"].value as? String, "纸币现金")
        app.buttons["account.type"].tap()
        app.buttons["account.type.cash"].tap()
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        app.buttons["accounts.closeDetail"].tap()
        scrollTo(cash, in: app)
        XCTAssertTrue(cash.label.contains("纸币现金，现金，余额 ¥100.00"))
    }

    func testCounterWalletAppearanceAndCustomEditor() throws {
        let app = XCUIApplication()
        let accountName = "旅行备用金 \(UUID().uuidString.prefix(4))"
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        attachScreenshot(app, name: "V2 appearance collapsed accounts")
        app.buttons["accounts.add"].tap()
        XCTAssertTrue(app.buttons["account.provider.custom"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "V2 final searchable chooser")
        app.buttons["account.provider.custom"].tap()
        XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
        replaceText(app.textFields["account.name"], with: accountName)
        app.buttons["account.chooseIcon"].tap()
        let icon = app.buttons["account.cardIcon.travel"]
        scrollTo(icon, in: app)
        icon.tap()
        app.buttons["account.type"].tap()
        app.buttons["account.type.cash"].tap()
        replaceText(app.textFields["account.balance"], with: "50.00")
        // Dismiss the decimal keyboard without discarding the draft.
        app.buttons["account.dismissKeyboard"].tap()
        attachScreenshot(app, name: "V2 final custom account editor")
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(walletCard(app, name: accountName).isHittable)
        attachScreenshot(app, name: "V2 final saved account visible")
    }

    // Read-only: run against a populated QA ledger without adding or editing accounts.
    func testCounterWalletStackExpansionKeepsScrollPosition() throws {
        let app = XCUIApplication()
        app.launch()
        openCounterAccounts(app)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'accounts.card.'"))
        guard cards.count >= 3 else { throw XCTSkip("Requires a populated QA wallet") }
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)
        XCTAssertEqual(first.frame.height, 64, accuracy: 1)
        XCTAssertEqual(second.frame.minY - first.frame.minY, 64, accuracy: 1)
        attachScreenshot(app, name: "Wallet overlapping cards")

        func checkExpansion(_ card: XCUIElement) {
            let name = card.label.components(separatedBy: "，")[0]
            let originalY = card.frame.minY
            card.tap()
            XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
            let selected = app.staticTexts["accounts.selectedCard"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            XCTAssertTrue(selected.label.contains(name), "The exposed strip must select its own account")
            XCTAssertTrue(app.buttons["accounts.edit"].exists)
            XCTAssertTrue(app.buttons["accounts.record"].exists)
            let cardY = selected.frame.minY
            let ledgerHeading = app.staticTexts["最近流水"]
            let headingY = ledgerHeading.frame.minY
            let hasPopulatedLedger = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "工资入账")).firstMatch.exists
            app.scrollViews["accounts.activityScroll"].swipeUp(velocity: .slow)
            if hasPopulatedLedger {
                XCTAssertLessThan(ledgerHeading.frame.minY, headingY - 5, "The populated ledger must actually scroll")
            }
            XCTAssertEqual(selected.frame.minY, cardY, accuracy: 1, "The account card stays above the scrolling ledger")
            app.buttons["accounts.closeDetail"].tap()
            XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
            expectation(for: NSPredicate { _, _ in abs(card.frame.minY - originalY) < 1 }, evaluatedWith: card)
            waitForExpectations(timeout: 3)
        }

        checkExpansion(first)
        checkExpansion(second)
        let overview = app.scrollViews["accounts.overviewScroll"]
        overview.swipeUp(velocity: .slow)
        let visible = cards.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > 140 && $0.frame.maxY < app.frame.maxY - 50
        }
        XCTAssertFalse(visible.isEmpty)
        if let middle = visible.first { checkExpansion(middle) }
        attachScreenshot(app, name: "Wallet preserves scrolled position after collapse")

        // Existing sheets still open and cancel without mutating the ledger.
        app.buttons["accounts.transfer"].tap()
        XCTAssertTrue(app.textFields["transfer.amount"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        app.buttons["accounts.add"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.buttons["account.provider.custom"].tap()
        XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
    }

    func testCounterWalletReadOnlyAppearance() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        attachScreenshot(app, name: "V2 readonly appearance collapsed")
        let fund = walletCard(app, name: "长期基金")
        guard fund.exists else { throw XCTSkip("Use the populated QA fixture") }
        scrollTo(fund, in: app)
        attachScreenshot(app, name: "V2 readonly appearance lower accounts")
        fund.tap()
        XCTAssertTrue(app.buttons["accounts.closeDetail"].waitForExistence(timeout: 5))
        let close = app.buttons["accounts.closeDetail"]
        expectation(for: NSPredicate { _, _ in close.frame.minY >= 62 }, evaluatedWith: close)
        waitForExpectations(timeout: 3)
        attachScreenshot(app, name: "V2 readonly appearance expanded")
        app.buttons["accounts.closeDetail"].tap()
        app.buttons["accounts.add"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "V2 readonly appearance chooser")
        app.buttons["account.provider.custom"].tap()
        XCTAssertTrue(app.textFields["account.name"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "V2 readonly appearance custom editor")
        app.buttons["取消"].tap()
    }

    func testCounterAccountSearchAliasesAndHuabeiNature() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        openCounterAccounts(app)
        app.buttons["accounts.add"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("招行")
        XCTAssertTrue(app.buttons["account.provider.cmb"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.provider.wechat"].exists)
        replaceText(search, with: "花呗")
        app.buttons["account.provider.huabei"].tap()
        XCTAssertTrue(app.buttons["account.type"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["account.type"].label.contains("信用卡"), "Huabei must default to a liability")
        app.buttons["account.type"].tap()
        app.buttons["account.type.otherDebt"].tap()
        XCTAssertTrue(app.buttons["account.type"].label.contains("其他负债"))
        app.buttons["取消"].tap()
    }

    func testCounterRepaymentUsesMonthlyDayPicker() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        app.buttons["wow.counterMascot"].tap()
        let companion = app.buttons["home.companionMenu"]
        XCTAssertTrue(companion.waitForExistence(timeout: 8))
        companion.tap()
        let accounts = app.buttons["home.companion.账户"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()
        app.buttons["accounts.add"].tap()
        let custom = app.buttons["account.provider.custom"]
        if !custom.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Unified account chooser with types and presets")
        custom.tap()
        app.buttons["account.type"].tap()
        app.buttons["account.type.creditCard"].tap()
        let toggle = app.switches["account.repaymentReminder"]
        if !toggle.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(toggle, in: app)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(app.datePickers.count, 0, "还款日不能要求年或月")
        let dayPicker = app.buttons["account.repaymentDay"]
        XCTAssertTrue(dayPicker.waitForExistence(timeout: 5), app.debugDescription)
        dayPicker.tap()
        let lastDay = app.buttons["每月 31 日"]
        for _ in 0..<4 {
            if lastDay.exists && lastDay.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(lastDay.waitForExistence(timeout: 5), app.debugDescription)
        lastDay.tap()
        XCTAssertTrue(app.buttons["account.repaymentDay"].label.contains("每月 31 日"))
        attachScreenshot(app, name: "Counter monthly repayment day 31")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
    }

    func testPictureRemarkerEntryAndReturn() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let entry = app.buttons["Open Picture Remarker"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        entry.tap()
        let home = app.buttons["wowHomeButton"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Picture Marker"].exists)
        let photo = app.buttons.matching(NSPredicate(format: "label == 'Photo' OR label == '相册'")).firstMatch
        XCTAssertTrue(photo.exists)
        photo.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        // Reopening catches stale modal/navigation state after dismissal.
        entry.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(app.buttons["Open today’s plans"].waitForExistence(timeout: 5))
    }

    func testTeleprompterRecordControlsAndReturn() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let entry = app.buttons["Open Teleprompter"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        entry.tap()
        let editor = app.textViews["scriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        let open = app.buttons["openTeleprompterButton"]
        XCTAssertFalse(open.isEnabled)
        editor.tap()
        editor.typeText("Wow integration test. Read, record, and return home.")
        XCTAssertTrue(open.isEnabled)
        open.tap()
        let record = app.buttons["startPauseButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 8), app.debugDescription)
        attachScreenshot(app, name: "Teleprompter reading area")
        record.tap()
        let stop = app.buttons.matching(NSPredicate(format: "identifier == 'startPauseButton' AND label CONTAINS '停止'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(app, name: "Teleprompter recording")
        stop.tap()
        let back = app.buttons["返回"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: back)
        waitForExpectations(timeout: 8)
        back.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Wow integration test. Read, record, and return home.")
        app.buttons["wowHomeButton"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Picture Remarker"].exists)
    }

    func testMascotVideoActuallyMovesInWowAndCounter() throws {
        let app = XCUIApplication()
        app.launch()
        func assertMoves(_ element: XCUIElement) throws {
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            let region = element.frame.insetBy(dx: 8, dy: 8)
            var frames = Set<Data>()
            for _ in 0..<6 {
                let image = try XCTUnwrap(app.screenshot().image.cgImage)
                let scaleX = CGFloat(image.width) / app.frame.width
                let scaleY = CGFloat(image.height) / app.frame.height
                let rect = CGRect(x: region.minX * scaleX, y: region.minY * scaleY,
                                  width: region.width * scaleX, height: region.height * scaleY)
                let crop = try XCTUnwrap(image.cropping(to: rect))
                // Re-encode only the mascot crop, excluding the clock and other screen content.
                let pixels = try XCTUnwrap(UIImage(cgImage: crop).pngData())
                frames.insert(pixels)
                Thread.sleep(forTimeInterval: 0.4)
            }
            XCTAssertGreaterThan(frames.count, 1, "The visible mascot must change frames rather than remain a static avatar")
        }
        let wowMascot = app.buttons["wow.counterMascot"]
        try assertMoves(wowMascot)
        wowMascot.tap()
        let counterMascot = app.buttons["home.companionMenu"]
        try assertMoves(counterMascot)
        app.buttons["wowHomeButton"].tap()
        try assertMoves(wowMascot)
    }

    func testCounterEntryAndReturn() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let entry = app.buttons["wow.counterMascot"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(entry.isHittable)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == 'Open Counter'")).count, 0)
        XCTAssertFalse(app.staticTexts["Track income and expenses"].exists)
        XCTAssertLessThan(entry.frame.maxY, app.buttons["Open today’s plans"].frame.minY)
        XCTAssertGreaterThan(entry.frame.midX, app.frame.midX)
        attachScreenshot(app, name: "Wow dynamic Counter entry")
        entry.tap()

        let home = app.buttons["wowHomeButton"]
        let addEntry = app.buttons["home.add"]
        let companion = app.buttons["home.companionMenu"]
        XCTAssertTrue(home.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(addEntry.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(companion.exists)
        attachScreenshot(app, name: "Original Counter companion")

        // The existing Counter menu currently has three entries; keep all of them.
        for title in ["账户", "分类", "设置"] {
            companion.tap()
            let menuEntry = app.buttons["home.companion.\(title)"]
            XCTAssertTrue(menuEntry.waitForExistence(timeout: 5), app.debugDescription)
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menuEntry)
            waitForExpectations(timeout: 5)
            attachScreenshot(app, name: "Counter dealt menu - \(title)")
            menuEntry.tap()
            let back = app.buttons["返回"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 8), app.debugDescription)
            let destination = title == "账户" ? app.buttons["accounts.add"]
                : app.staticTexts[title == "分类" ? "分类" : "管理與設定"].firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
            back.tap()
            XCTAssertTrue(addEntry.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(companion.exists)
        }

        home.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        XCTAssertTrue(addEntry.waitForExistence(timeout: 5), app.debugDescription)
        home.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    func testToolReorderPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        app.swipeUp()

        let pictureRemarker = app.buttons["Open Picture Remarker"]
        let teleprompter = app.buttons["Open Teleprompter"]
        XCTAssertTrue(pictureRemarker.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(teleprompter.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(pictureRemarker.isHittable, app.debugDescription)
        XCTAssertTrue(teleprompter.isHittable, app.debugDescription)
        let pictureWasFirst = pictureRemarker.frame.midY < teleprompter.frame.midY
        pictureRemarker.press(forDuration: 0.48, thenDragTo: teleprompter)
        XCTAssertEqual(pictureRemarker.frame.midY < teleprompter.frame.midY, !pictureWasFirst)

        app.terminate()
        app.launch()
        let pictureAfterRelaunch = app.buttons["Open Picture Remarker"]
        let teleprompterAfterRelaunch = app.buttons["Open Teleprompter"]
        XCTAssertTrue(pictureAfterRelaunch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(teleprompterAfterRelaunch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(pictureAfterRelaunch.frame.midY < teleprompterAfterRelaunch.frame.midY, !pictureWasFirst,
                       "The remaining Tools must retain their order after relaunch")
        XCTAssertEqual(abs(pictureAfterRelaunch.frame.midY - teleprompterAfterRelaunch.frame.midY), 90, accuracy: 1,
                       "Removing Counter must leave no empty row")
        XCTAssertFalse(app.staticTexts["Track income and expenses"].exists)

        app.swipeUp()
        pictureAfterRelaunch.press(forDuration: 0.48, thenDragTo: teleprompterAfterRelaunch)
        XCTAssertEqual(pictureAfterRelaunch.frame.midY < teleprompterAfterRelaunch.frame.midY, pictureWasFirst,
                       "Restore the order that existed before the test")
    }

    func testLegacyCounterToolOrderIsIgnored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-wow.tools.order.v1", "counter,teleprompter,counter,unknown,pictureRemarker,teleprompter"]
        app.launch()
        let picture = app.buttons["Open Picture Remarker"]
        let teleprompter = app.buttons["Open Teleprompter"]
        XCTAssertTrue(teleprompter.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(picture.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Open Picture Remarker").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "Open Teleprompter").count, 1)
        XCTAssertLessThan(teleprompter.frame.midY, picture.frame.midY)
        XCTAssertEqual(picture.frame.midY - teleprompter.frame.midY, 90, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Counter"].exists)
        XCTAssertFalse(app.staticTexts["Track income and expenses"].exists)
        XCTAssertTrue(app.buttons["wow.counterMascot"].exists)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        // UIKit keyboard/toolbars can still be visually animating after XCTest reports idle.
        if name.hasPrefix("V2 ") { Thread.sleep(forTimeInterval: 1) }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPicturePinchZoomDrawResetAndExport() throws {
        let app = XCUIApplication()
        app.launch()
        let entry = app.buttons["Open Picture Remarker"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Photo' OR label == '相册'")).firstMatch.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH '照片'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let canvas = app.scrollViews["picture.canvas"]
        let reset = app.buttons["picture.zoom.reset"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertEqual(reset.value as? String, "100%")
        let arrow = app.buttons.matching(NSPredicate(format: "label == 'Arrow' OR label == '箭头'")).firstMatch
        arrow.tap()
        // Pinching with a drawing tool active must zoom, not create an annotation.
        canvas.pinch(withScale: 2.5, velocity: 1)
        let zoomed = NSPredicate { _, _ in
            Int((reset.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? 0 > 150
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: zoomed, object: reset)], timeout: 5) == .completed, app.debugDescription)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        start.press(forDuration: 0.15, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        let count = app.staticTexts.matching(NSPredicate(format: "label == '1 Annotation' OR label == '1 Annotations' OR label CONTAINS '1 个标注'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(app, name: "Picture canvas zoomed annotation")
        reset.tap()
        XCTAssertEqual(reset.value as? String, "100%")
        XCTAssertTrue(count.exists)
        app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == '完成'")).firstMatch.tap()
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save to Photos' OR label == '保存到照片'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 10)
        attachScreenshot(app, name: "Picture zoom annotation original-resolution export")
    }

    func testPictureImportDrawAndExport() throws {
        let app = XCUIApplication()
        app.launch()
        let entry = app.buttons["Open Picture Remarker"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        let photo = app.buttons.matching(NSPredicate(format: "label == 'Photo' OR label == '相册'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let image = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH '照片'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), app.debugDescription)
        // Photos exposes thumbnails as non-hittable images on iOS 26 even
        // though their visible centers accept a touch.
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let arrow = app.buttons.matching(NSPredicate(format: "label == 'Arrow' OR label == '箭头'")).firstMatch
        XCTAssertTrue(arrow.waitForExistence(timeout: 10), app.debugDescription)
        arrow.tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0.15, thenDragTo: end)
        let count = app.staticTexts.matching(NSPredicate(format: "label == '1 Annotation' OR label == '1 Annotations' OR label CONTAINS '1 个标注'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), app.debugDescription)
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == '完成'")).firstMatch
        done.tap()
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save to Photos' OR label == '保存到照片'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Picture Remarker annotated export"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Export → editor → Picture Remarker → Wow.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Back' OR label == '返回'")).firstMatch.tap()
        app.buttons["wowHomeButton"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

}

extension WowNavigationTests {
    private func dragReading(_ reading: XCUIElement, hold: TimeInterval, dx: CGFloat, dy: CGFloat) {
        let start = reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: hold, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
    }

    private func moveReading(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) {
        app.otherElements["teleprompterText"].tap()
        let handle = app.buttons["teleprompterMoveHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3), app.debugDescription)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
    }

    private func readableLines(_ app: XCUIApplication) -> Int {
        let value = app.buttons["teleprompterMoveHandle"].value as? String ?? ""
        return Int(value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }

    private func resizeReading(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) {
        let reading = app.otherElements["teleprompterText"]
        reading.tap()
        let handle = app.buttons["teleprompterResizeHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3), app.debugDescription)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
    }

    func testFloatingTeleprompterMoveResizeScrollAndFontAreIndependent() throws {
        let app = openReadingScript(String(repeating: "Keep your eyes near the lens, and speak naturally. 让眼神自然地交流，不要追着文字跑。\n", count: 8))
        let reading = app.otherElements["teleprompterText"]
        let original = reading.frame
        let progress = reading.value as? String
        moveReading(app, dx: 20, dy: 100)
        XCTAssertGreaterThan(reading.frame.minY, original.minY + 70)
        XCTAssertGreaterThan(reading.frame.minX, original.minX + 15)
        XCTAssertEqual(reading.frame.size.width, original.width, accuracy: 1)
        XCTAssertEqual(reading.value as? String, progress, "Moving must not scroll words")
        let moved = reading.frame
        resizeReading(app, dx: -100, dy: -80)
        XCTAssertLessThan(reading.frame.width, moved.width - 60)
        XCTAssertLessThan(reading.frame.height, moved.height - 50)
        XCTAssertEqual(reading.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(reading.frame.minY, moved.minY, accuracy: 1)
        XCTAssertEqual(reading.value as? String, progress, "Resize handle must not scroll words")
        let resized = reading.frame
        dragReading(reading, hold: 0.05, dx: 0, dy: -80)
        XCTAssertNotEqual(reading.value as? String, progress, "Quick swipe must scroll words")
        XCTAssertEqual(reading.frame.minX, resized.minX, accuracy: 1)
        XCTAssertEqual(reading.frame.minY, resized.minY, accuracy: 1)
        app.buttons["adjustmentToggleButton"].tap()
        let beforeFont = reading.frame.size
        app.sliders["fontSizeSlider"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(reading.frame.width, beforeFont.width, accuracy: 1)
        XCTAssertEqual(reading.frame.height, beforeFont.height, accuracy: 1)
        attachScreenshot(app, name: "Floating small window large font")
        let font = app.sliders["fontSizeSlider"].value as? String
        app.buttons["resetLayoutButton"].tap()
        XCTAssertEqual(app.sliders["fontSizeSlider"].value as? String, font)
        XCTAssertGreaterThan(reading.frame.width, beforeFont.width + 60)
        XCTAssertLessThan(reading.frame.minY, original.minY + 2)
    }

    func testFloatingTeleprompterPersistsAcrossRelaunchAndCorrectsRotation() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let script = String(repeating: "Read a phrase naturally, and then continue. 自然说完这一句，再继续下一句。\n", count: 3)
        let app = openReadingScript(script)
        let reading = app.otherElements["teleprompterText"]
        resizeReading(app, dx: -110, dy: -80)
        moveReading(app, dx: 60, dy: 100)
        app.buttons["adjustmentToggleButton"].tap()
        app.sliders["fontSizeSlider"].adjust(toNormalizedSliderPosition: 0.75)
        let font = app.sliders["fontSizeSlider"].value as? String
        app.buttons["adjustmentToggleButton"].tap()
        let saved = reading.frame
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Open Teleprompter"].waitForExistence(timeout: 15))
        app.buttons["Open Teleprompter"].tap()
        app.textViews["scriptEditor"].tap()
        app.textViews["scriptEditor"].typeText(script)
        app.buttons["openTeleprompterButton"].tap()
        XCTAssertTrue(reading.waitForExistence(timeout: 8))
        XCTAssertEqual(reading.frame.minX, saved.minX, accuracy: 2)
        XCTAssertEqual(reading.frame.minY, saved.minY, accuracy: 2)
        XCTAssertEqual(reading.frame.width, saved.width, accuracy: 2)
        XCTAssertEqual(reading.frame.height, saved.height, accuracy: 2)
        app.buttons["adjustmentToggleButton"].tap()
        XCTAssertEqual(app.sliders["fontSizeSlider"].value as? String, font)
        app.buttons["adjustmentToggleButton"].tap()
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                let window = app.windows.firstMatch.frame
                let correctOrientation = orientation == .portrait ? window.height > window.width : window.width > window.height
                let correctSide = orientation == .portrait || (orientation == .landscapeLeft ? reading.frame.midX < window.midX : reading.frame.midX > window.midX)
                return correctOrientation && correctSide && window.contains(reading.frame) && app.buttons["startPauseButton"].isHittable
            }, evaluatedWith: reading)
            waitForExpectations(timeout: 8)
        }
        XCTAssertEqual(reading.frame.minX, saved.minX, accuracy: 2)
        XCTAssertEqual(reading.frame.minY, saved.minY, accuracy: 2)
        attachScreenshot(app, name: "Floating saved layout restored")
    }

    func testFloatingTeleprompterAdjustsDuringRecordingAndResumesScrolling() throws {
        let app = openReadingScript(String(repeating: "Keep your eyes near the lens. 自然表达，而不是逐字朗读。\n", count: 8))
        let reading = app.otherElements["teleprompterText"]
        resizeReading(app, dx: -100, dy: -80)
        app.buttons["startPauseButton"].tap()
        XCTAssertTrue(app.staticTexts["recordingStatus"].waitForExistence(timeout: 5))
        let original = reading.frame
        moveReading(app, dx: 20, dy: 80)
        XCTAssertGreaterThan(reading.frame.minY, original.minY + 50)
        resizeReading(app, dx: 60, dy: 50)
        XCTAssertTrue(app.buttons["startPauseButton"].label.contains("停止"))
        let progress = reading.value as? String
        expectation(for: NSPredicate { _, _ in reading.value as? String != progress }, evaluatedWith: reading)
        waitForExpectations(timeout: 6)
        attachScreenshot(app, name: "Floating recording continues after resize")
        app.buttons["startPauseButton"].tap()
        XCTAssertTrue(app.buttons["返回"].isEnabled)
    }

    func testFloatingTeleprompterBoundsRepeatedResizeAndChromeHide() throws {
        let app = openReadingScript("This reading area can move freely, without losing your place. 让阅读区靠近自然视线，继续说完这一句。")
        let reading = app.otherElements["teleprompterText"]
        let progress = reading.value as? String
        // Collapse to the supported minimum at the upper-left boundary.
        resizeReading(app, dx: -240, dy: -220)
        XCTAssertEqual(reading.frame.width, 120, accuracy: 1)
        XCTAssertEqual(reading.frame.height, 80, accuracy: 1)
        // Keep the physical touch inside the display. An off-screen endpoint
        // can leave Simulator's synthesized touch/rotation state stuck.
        moveReading(app, dx: 12 - reading.frame.midX, dy: 80 - reading.frame.midY)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["teleprompterMoveHandle"].frame))
        XCTAssertTrue(app.buttons["返回"].isHittable)
        // Repeated expansion/contraction neither moves the anchor nor scrolls.
        let anchor = reading.frame.origin
        for _ in 0..<3 {
            resizeReading(app, dx: 85, dy: 65)
            resizeReading(app, dx: -85, dy: -65)
            XCTAssertEqual(reading.frame.minX, anchor.x, accuracy: 1)
            XCTAssertEqual(reading.frame.minY, anchor.y, accuracy: 1)
            XCTAssertEqual(reading.frame.width, 120, accuracy: 1)
            XCTAssertEqual(reading.frame.height, 80, accuracy: 1)
            XCTAssertEqual(reading.value as? String, progress)
        }
        let window = app.windows.firstMatch.frame
        // Reach both far edges; the whole window stays inside and controls work.
        moveReading(app, dx: window.width - reading.frame.midX - 20, dy: window.height - reading.frame.midY - 60)
        XCTAssertTrue(window.contains(app.buttons["teleprompterMoveHandle"].frame))
        XCTAssertLessThanOrEqual(app.buttons["teleprompterMoveHandle"].frame.maxY, app.buttons["startPauseButton"].frame.minY)
        XCTAssertTrue(app.buttons["startPauseButton"].isHittable)
        let handle = app.buttons["teleprompterResizeHandle"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: handle)
        waitForExpectations(timeout: 5)
        reading.tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 2))
        attachScreenshot(app, name: "Floating smallest window at safe edge")
    }

    func testFloatingHeightGrowthShowsMoreTextAndSmallFontSurvivesReflow() throws {
        let app = openReadingScript(String(repeating: "Read one phrase naturally. 下一句内容仍然清晰可见。\n", count: 20))
        let reading = app.otherElements["teleprompterText"]
        app.buttons["adjustmentToggleButton"].tap()
        app.sliders["fontSizeSlider"].adjust(toNormalizedSliderPosition: 0)
        app.buttons["adjustmentToggleButton"].tap()
        // Move to the legal upper edge before enlarging, keeping the whole
        // test viewport visible so the screenshot proves real usable height.
        moveReading(app, dx: 0, dy: 80 - app.buttons["teleprompterMoveHandle"].frame.midY)
        resizeReading(app, dx: -20, dy: 300 - reading.frame.height)
        let original = reading.frame
        reading.tap()
        let count = readableLines(app)
        XCTAssertGreaterThan(count, 8, "12 pt must render more than the old eight-row cap")
        attachScreenshot(app, name: "Repair real text viewport 300 pt")
        resizeReading(app, dx: 0, dy: 150)
        XCTAssertGreaterThan(reading.frame.height, original.height * 1.45)
        let grownCount = readableLines(app)
        XCTAssertGreaterThanOrEqual(Double(grownCount), Double(count) * 1.4)
        let metrics = XCTAttachment(string: "原高度 \(original.height) pt：\(count) 行\n新高度 \(reading.frame.height) pt：\(grownCount) 行\n可读行数增长：\(Double(grownCount) / Double(count)) 倍")
        metrics.name = "Actual rendered viewport growth metrics"
        metrics.lifetime = .keepAlways
        add(metrics)
        XCTAssertEqual(reading.frame.width, original.width, accuracy: 1)
        attachScreenshot(app, name: "Repair real text viewport 450 pt")
        let progress = reading.value as? String
        resizeReading(app, dx: -90, dy: 0)
        XCTAssertEqual(reading.value as? String, progress, "Rewrap must retain reading place")
        dragReading(reading, hold: 0.05, dx: 0, dy: -90)
        XCTAssertNotEqual(reading.value as? String, progress)
    }

    func testFloatingMoveHandleMovesLeftRightWithoutScrollingBody() throws {
        let app = openReadingScript(String(repeating: "Move this window in both directions. 文字只负责滚动稿件。\n", count: 6))
        let reading = app.otherElements["teleprompterText"]
        let original = reading.frame
        let progress = reading.value as? String
        moveReading(app, dx: -100, dy: 70)
        XCTAssertLessThan(reading.frame.minX, original.minX - 70)
        XCTAssertGreaterThan(reading.frame.minY, original.minY + 50)
        XCTAssertEqual(reading.value as? String, progress)
        let left = reading.frame
        moveReading(app, dx: 180, dy: -40)
        XCTAssertGreaterThan(reading.frame.minX, left.minX + 140)
        XCTAssertLessThan(reading.frame.minY, left.minY - 25)
        XCTAssertEqual(reading.value as? String, progress)
        let moved = reading.frame
        dragReading(reading, hold: 0.6, dx: 0, dy: -80)
        XCTAssertEqual(reading.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(reading.frame.minY, moved.minY, accuracy: 1)
        XCTAssertNotEqual(reading.value as? String, progress, "Even a held drag on text must only scroll")
        attachScreenshot(app, name: "Repair explicit two dimensional move grip")
    }

    private func openReadingScript(_ script: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TELEPROMPTER_SETTINGS_SUITE"] = "com.chris.teleprompter.ui-tests.\(UUID().uuidString)"
        app.launch()
        let entry = app.buttons["Open Teleprompter"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        entry.tap()
        let editor = app.textViews["scriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(script)
        app.buttons["openTeleprompterButton"].tap()
        XCTAssertTrue(app.otherElements["teleprompterText"].waitForExistence(timeout: 8), app.debugDescription)
        return app
    }

    func testTeleprompterNarrowFocusSettingsAndStartPoint() throws {
        let script = String(repeating: "今天，我们来聊镜头感。让眼神停在镜头旁，自然地表达。Today I want to share something that changed the way I use my phone.\n", count: 4)
        let app = openReadingScript(script)
        let reading = app.otherElements["teleprompterText"]
        XCTAssertLessThan(reading.frame.width, app.frame.width * 0.82)
        XCTAssertLessThan(reading.frame.minY, app.frame.height * 0.12)
        attachScreenshot(app, name: "Focus portrait mixed script")
        let upper = reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let lower = reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        upper.press(forDuration: 0.15, thenDragTo: lower)
        let savedProgress = reading.value as? String
        XCTAssertNotEqual(savedProgress, "阅读进度 0%")
        app.buttons["startPointButton"].tap()
        XCTAssertTrue(app.buttons["startPointButton"].label.contains("起点已设"))
        app.buttons["adjustmentToggleButton"].tap()
        XCTAssertTrue(app.sliders["fontSizeSlider"].waitForExistence(timeout: 5))
        app.sliders["fontSizeSlider"].adjust(toNormalizedSliderPosition: 1)
        attachScreenshot(app, name: "Focus portrait largest font")
        app.buttons["adjustmentToggleButton"].tap()
        let speed = app.staticTexts["currentSpeedLabel"].value as? String
        app.buttons["increaseSpeedButton"].tap()
        XCTAssertNotEqual(app.staticTexts["currentSpeedLabel"].value as? String, speed)
        app.buttons["decreaseSpeedButton"].tap()
        XCTAssertEqual(app.staticTexts["currentSpeedLabel"].value as? String, speed)
        app.buttons["startPauseButton"].tap()
        XCTAssertTrue(app.staticTexts["recordingStatus"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["startPauseButton"].tap()
        app.buttons["resetButton"].tap()
        XCTAssertEqual(reading.value as? String, "阅读进度 0%")
        XCTAssertFalse(app.buttons["startPointButton"].label.contains("起点已设"))
    }

    func testTeleprompterBothLandscapeDirectionsAndReflow() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openReadingScript("Keep your eyes near the lens.\n让文字经过焦点，而不是追着整页文字。\nNow continue speaking naturally.")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let reading = app.otherElements["teleprompterText"]
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["startPauseButton"])
            waitForExpectations(timeout: 8)
            let window = app.windows.firstMatch
            expectation(for: NSPredicate { _, _ in
                orientation == .landscapeLeft
                    ? reading.frame.midX < window.frame.midX
                    : reading.frame.midX > window.frame.midX
            }, evaluatedWith: reading)
            waitForExpectations(timeout: 8)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Landscape hierarchy \(orientation.rawValue)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTAssertLessThan(max(reading.frame.width, reading.frame.height), min(window.frame.width, window.frame.height) * 0.82)
            XCTAssertTrue(app.buttons["startPauseButton"].isHittable, app.debugDescription)
            attachScreenshot(app, name: "Focus landscape \(orientation.rawValue)")
            app.buttons["adjustmentToggleButton"].tap()
            let slider = app.sliders["fontSizeSlider"]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            if !slider.isHittable { app.swipeUp() }
            slider.adjust(toNormalizedSliderPosition: orientation == .landscapeLeft ? 1 : 0)
            attachScreenshot(app, name: "Focus landscape font \(orientation.rawValue)")
            app.buttons["adjustmentToggleButton"].tap()
        }
    }

    func testTeleprompterScrollFinishesWithoutStoppingRecording() throws {
        let app = openReadingScript("你好\n继续\n最后一句")
        app.buttons["adjustmentToggleButton"].tap()
        app.sliders["speedSlider"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["adjustmentToggleButton"].tap()
        app.buttons["startPauseButton"].tap()
        let reading = app.otherElements["teleprompterText"]
        expectation(for: NSPredicate(format: "value == %@", "阅读进度 100%"), evaluatedWith: reading)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["startPauseButton"].label.contains("停止"))
        XCTAssertFalse(app.buttons["返回"].isEnabled)
        attachScreenshot(app, name: "Focus final line recording continues")
        app.buttons["startPauseButton"].tap()
        XCTAssertTrue(app.buttons["返回"].isEnabled)
        app.buttons["返回"].tap()
        XCTAssertEqual(app.textViews["scriptEditor"].value as? String, "你好\n继续\n最后一句")
    }
}
