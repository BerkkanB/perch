import Carbon.HIToolbox
import XCTest
@testable import Perch

final class PMSetTests: XCTestCase {
    func testReadsSleepDisabled() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         sleep                1 (sleep prevented by powerd)
        """
        XCTAssertTrue(PMSet.parseSleepDisabled(output))
    }

    func testReadsSleepAllowed() {
        XCTAssertFalse(PMSet.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\n"))
    }

    func testMissingLineMeansSleepAllowed() {
        XCTAssertFalse(PMSet.parseSleepDisabled("Currently in use:\n sleep 1\n"))
    }

    func testCommand() {
        XCTAssertEqual(PMSet.command(disableSleep: true), ["/usr/bin/pmset", "-a", "disablesleep", "1"])
        XCTAssertEqual(PMSet.command(disableSleep: false), ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }
}

final class SudoersRuleTests: XCTestCase {
    func testRuleAllowsOnlyTheGivenCommands() throws {
        let rule = try PrivilegedAccess.ruleText(user: "dev", commands: [
            PMSet.command(disableSleep: false),
            PMSet.command(disableSleep: true),
        ])
        XCTAssertTrue(rule.hasSuffix(
            "dev ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        ))
        XCTAssertFalse(rule.contains("'"), "Lines are single-quoted in the install script")
    }

    func testRejectsUnsafeUserNames() {
        XCTAssertThrowsError(try PrivilegedAccess.ruleText(user: "bob ALL=(ALL) ALL", commands: []))
        XCTAssertThrowsError(try PrivilegedAccess.ruleText(user: "", commands: []))
    }

    func testEscapesSudoersSpecialCharacters() {
        XCTAssertEqual(PrivilegedAccess.escapeSudoersArgument("a,b:c=d\\e"), #"a\,b\:c\=d\\e"#)
    }

    func testInstallScriptChecksBeforeMovingIntoPlace() throws {
        let script = PrivilegedAccess.installScript(ruleText: "line one\nline two")
        let check = try XCTUnwrap(script.range(of: "visudo -cqf"))
        let move = try XCTUnwrap(script.range(of: "/bin/mv -f"))
        XCTAssertLessThan(check.lowerBound, move.lowerBound)
        XCTAssertTrue(script.contains("'line one' 'line two'"))
    }

    func testShellQuote() {
        XCTAssertEqual(PrivilegedAccess.shellQuote("it's"), #"'it'\''s'"#)
    }
}

final class FormattingTests: XCTestCase {
    func testPresets() {
        XCTAssertEqual(DurationFormat.preset(15 * 60), "15m")
        XCTAssertEqual(DurationFormat.preset(60 * 60), "1h")
        XCTAssertEqual(DurationFormat.preset(90 * 60), "1h 30m")
    }

    func testCompact() {
        XCTAssertEqual(DurationFormat.compact(30), "30s")
        XCTAssertEqual(DurationFormat.compact(42 * 60), "42m")
        XCTAssertEqual(DurationFormat.compact(2 * 60 * 60), "2h")
        XCTAssertEqual(DurationFormat.compact(65 * 60), "1h 5m")
    }

    func testRemaining() {
        XCTAssertEqual(DurationFormat.remaining(59), "59s left")
        XCTAssertEqual(DurationFormat.remaining(61), "2m left")
        XCTAssertEqual(DurationFormat.remaining(3_900), "1h 05m left")
    }

    func testKeyComboDisplay() {
        XCTAssertEqual(KeyCombo.stayAwakeDefault.keycaps.dropLast(), ["⌃", "⌥", "⌘"])
        XCTAssertEqual(KeyCombo(keyCode: kVK_F5, modifiers: []).keyName, "F5")
        XCTAssertEqual(KeyCombo(keyCode: kVK_Space, modifiers: .command).display, "⌘Space")
    }
}

@MainActor
final class AutoOffTimerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)")
    }

    func testFiresAndClears() async throws {
        let timer = AutoOffTimer(storageKey: "t", defaults: defaults)
        let fired = expectation(description: "fired")
        timer.onExpire = { fired.fulfill() }
        timer.start(duration: 0.05)
        XCTAssertTrue(timer.isRunning)
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(defaults.dictionary(forKey: "t"))
    }

    func testSurvivesRelaunch() {
        let first = AutoOffTimer(storageKey: "t", defaults: defaults)
        first.start(duration: 600)
        let restored = AutoOffTimer(storageKey: "t", defaults: defaults)
        XCTAssertEqual(restored.duration, 600)
        XCTAssertEqual(restored.endsAt?.timeIntervalSince1970 ?? 0, first.endsAt?.timeIntervalSince1970 ?? 1, accuracy: 0.01)
        first.cancel()
    }
}

final class SystemReadingTests: XCTestCase {
    func testStorageSizesAreDecimalLikeFinder() {
        XCTAssertEqual(ByteFormat.storage(82_400_000_000), "82 GB")
        XCTAssertEqual(ByteFormat.storage(8_440_000_000), "8.4 GB")
        XCTAssertEqual(ByteFormat.storage(1_240_000_000_000), "1.2 TB")
        XCTAssertEqual(ByteFormat.storage(2_000_000_000_000), "2 TB")
        XCTAssertEqual(ByteFormat.storage(640_000_000), "640 MB")
    }

    func testMemorySizesAreBinaryLikeActivityMonitor() {
        XCTAssertEqual(ByteFormat.memory(16 * ByteFormat.gibibyte), "16 GB")
        XCTAssertEqual(ByteFormat.memory(11 * ByteFormat.gibibyte + ByteFormat.gibibyte / 5), "11.2 GB")
        XCTAssertEqual(ByteFormat.memory(640 << 20), "640 MB")
        XCTAssertEqual(ByteFormat.memory(17 * ByteFormat.gibibyte + ByteFormat.gibibyte * 3 / 5, of: 24 * ByteFormat.gibibyte), "17.6 of 24 GB")
        XCTAssertEqual(ByteFormat.memory(640 << 20, of: 8 * ByteFormat.gibibyte), "640 MB of 8 GB")
    }

    func testStorageLevelsAreInGigabytes() {
        let gigabyte = ByteFormat.gigabyte
        XCTAssertEqual(StorageReading(total: 494 * gigabyte, available: 82 * gigabyte).level, .ok)
        XCTAssertEqual(StorageReading(total: 494 * gigabyte, available: 25 * gigabyte).level, .low)
        XCTAssertEqual(StorageReading(total: 2_000 * gigabyte, available: 9 * gigabyte).level, .critical)
    }

    func testUsedFraction() {
        let storage = StorageReading(total: 400, available: 100)
        XCTAssertEqual(storage.used, 300)
        XCTAssertEqual(storage.usedFraction, 0.75)
        XCTAssertEqual(MemoryReading(total: 0, used: 10, swapUsed: 0, pressure: .normal).usedFraction, 0)
    }
}
