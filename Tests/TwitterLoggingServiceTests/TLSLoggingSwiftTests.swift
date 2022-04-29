//
//  TLSLoggingSwiftTests.swift
//  TwitterLoggingService
//
//  Created on 2/4/16.
//  Copyright (c) 2016 Twitter, Inc.
//

import TwitterLoggingService
import TwitterLoggingServiceObjC
import XCTest

extension Notification.Name {
    fileprivate static let LoggingSwiftTestOutputStreamNotification = Notification.Name(rawValue: "TLSLoggingSwiftTestOutputStreamNotification")
    fileprivate static let LoggingSwiftTestDiscardedMessageNotification = Notification.Name(rawValue: "TLSLoggingSwiftTestDiscardedMessageNotification")
}

class TLSLoggingSwiftTestOutputStream : NSObject, TLSOutputStream
{
    var shouldPrint: Bool = true

    func tls_outputLogInfo(_ logInfo: TLSLogMessageInfo)
    {
        DispatchQueue.main.async(execute: {
            if (self.shouldPrint) {
                print(logInfo.composeFormattedMessage())
            }
            NotificationCenter.default.post(name: .LoggingSwiftTestOutputStreamNotification, object: logInfo)
        })
    }
}

class TLSLoggingSwiftTestMessageInfo : TLSLogMessageInfo
{
    var didGetLevel: Bool = false
    override var level: TLSLogLevel {
        didGetLevel = true
        return super.level
    }
    var didGetFile: Bool = false
    override var file: String {
        didGetFile = true
        return super.file
    }
    var didGetFunction: Bool = false
    override var function: String {
        didGetFunction = true
        return super.function
    }
    var didGetLine: Bool = false
    override var line: Int {
        didGetLine = true
        return super.line
    }
    var didGetChannel: Bool = false
    override var channel: String {
        didGetChannel = true
        return super.channel
    }
    var didGetContextObject: Bool = false
    override var contextObject: Any? {
        didGetContextObject = true
        return super.contextObject
    }
    var didGetTimestamp: Bool = false
    override var timestamp: Date {
        didGetTimestamp = true
        return super.timestamp
    }
    var didGetLogLifespan: Bool = false
    override var logLifespan: TimeInterval {
        didGetLogLifespan = true
        return super.logLifespan
    }
    var didGetThreadId: Bool = false
    override var threadId: UInt32 {
        didGetThreadId = true
        return super.threadId
    }
    var didGetMessage: Bool = false
    override var message: String {
        didGetMessage = true
        return super.message
    }

    var didComposeFormattedMessage: Bool = false
    var lastSeenComposeFormattedMessage: TLSComposeLogMessageInfoOptions = []
    override func composeFormattedMessage(options: TLSComposeLogMessageInfoOptions = []) -> String {
        didComposeFormattedMessage = true
        lastSeenComposeFormattedMessage = options
        return super.composeFormattedMessage(options: options)
    }

    var didComposeFileFunctionLineString: Bool = false
    override func composeFileFunctionLineString() -> String
    {
        didComposeFileFunctionLineString = true
        return super.composeFileFunctionLineString()
    }

    internal func reset()
    {
        didGetLevel = false
        didGetChannel = false
        didGetMessage = false
        didGetThreadId = false
        didGetTimestamp = false
        didGetLogLifespan = false
        didGetContextObject = false
        didGetFile = false
        didGetFunction = false
        didGetLine = false
        didComposeFormattedMessage = false
        lastSeenComposeFormattedMessage = []
        didComposeFileFunctionLineString = false
    }
}

class TLSLoggingSwiftTestCrashlyticsOutputStream : TLSCrashlyticsOutputStream
{
    var didOutputLogMessageToCrashlytics: Bool = false
    override func outputLogMessage(toCrashlytics message: String)
    {
        didOutputLogMessageToCrashlytics = true
    }

    fileprivate var _discardLargeLogMessagesOverride:Bool = false
    var discardLargeLogMessagesOverride: Bool
    {
        get {
            return _discardLargeLogMessagesOverride
        }
        set {
            _discardLargeLogMessagesOverride = newValue
        }
    }
    override func discardLargeLogMessages() -> Bool
    {
        return self.discardLargeLogMessagesOverride
    }

    func reset()
    {
        _discardLargeLogMessagesOverride = false
        didOutputLogMessageToCrashlytics = false
    }
}

class TLSLoggingSwiftTestServiceDelegate : NSObject, TLSLoggingServiceDelegate
{
    func tls_loggingService(_ service: TLSLoggingService, lengthToLogForMessageExceedingMaxSafeLength maxSafeLength: UInt, level: TLSLogLevel, channel: String, file: String, function: String, line: Int, contextObject: Any?, message: String) -> UInt {

        DispatchQueue.main.async(execute: {
            NotificationCenter.default.post(name: .LoggingSwiftTestDiscardedMessageNotification, object: nil)
        })
        return 0
    }
}

class TLSLoggingSwiftTest: XCTestCase
{
    let testOutputStream = TLSLoggingSwiftTestOutputStream()

    override func setUp() {
        super.setUp()
        TLSLoggingService.sharedInstance().addOutputStream(testOutputStream)
    }

    override func tearDown() {
        TLSLoggingService.sharedInstance().removeOutputStream(testOutputStream)
        super.tearDown()
    }

    func setExpectationForLoggingLevel(_ level: TLSLogLevel)  {
        _ = expectation(forNotification: .LoggingSwiftTestOutputStreamNotification, object: nil) { note in
            let messageInfo: TLSLogMessageInfo = note.object as! TLSLogMessageInfo
            return messageInfo.level == level
        }
    }

    func dummyLogMessageInfo(_ message: String = "Some Message") -> TLSLoggingSwiftTestMessageInfo {
        return TLSLoggingSwiftTestMessageInfo(level: .error, file:#file, function:#function ,line:#line, channel: "SomeChannel", timestamp: Date(), logLifespan: 0.1, threadId: 1, threadName: TLSCurrentThreadName(), contextObject: nil, message: message)
    }

    func testSwiftLogging() {
        let context = Date()

        setExpectationForLoggingLevel(.error)
        TLSLog.error("TestChannel", "Message with context: \(context)")
        waitForExpectations(timeout: 10)

        setExpectationForLoggingLevel(.warning)
        TLSLog.warning("TestChannel", "Message with context: \(context)")
        waitForExpectations(timeout: 10)

        setExpectationForLoggingLevel(.information)
        TLSLog.information("TestChannel", "Message with context: \(context)")
        waitForExpectations(timeout: 10)

        setExpectationForLoggingLevel(.alert)
        TLSLog.log(.alert, "TestChannel", context, "Message with context: \(context)")
        waitForExpectations(timeout: 10)

#if DEBUG
        setExpectationForLoggingLevel(.debug)
        TLSLog.debug("TestChannel", "Message with context: \(context)") // documentation explicitly states this only logs to debug builds
        waitForExpectations(timeout: 10)
#endif

        var delayedDate = Date()
        func delayedEvaluation() -> String {
            delayedDate = Date()
            return delayedDate.description
        }
        Thread.sleep(forTimeInterval: 0.000001)
        let dateBeforeLog = Date()
        XCTAssert(delayedDate < dateBeforeLog)
        TLSLog.information("TestChannel", delayedEvaluation())
        XCTAssert(dateBeforeLog < delayedDate)
    }

    func testConsoleOutputStreams()
    {
        let messageInfo = self.dummyLogMessageInfo()

        let NSLogOutputStream = TLSNSLogOutputStream()
        NSLogOutputStream.tls_outputLogInfo(messageInfo)
        XCTAssertTrue(messageInfo.didGetFile)
        XCTAssertTrue(messageInfo.didGetFunction)
        XCTAssertTrue(messageInfo.didGetLine)
        XCTAssertTrue(messageInfo.didGetLevel)
        XCTAssertTrue(messageInfo.didGetChannel)
        XCTAssertTrue(messageInfo.didGetMessage)
        XCTAssertTrue(messageInfo.didComposeFileFunctionLineString)
        XCTAssertTrue(messageInfo.didComposeFormattedMessage)
        messageInfo.reset()

        let stdOutOutputStream = TLSStdErrOutputStream()
        stdOutOutputStream.tls_outputLogInfo(messageInfo)
        XCTAssertFalse(messageInfo.didGetFile) // caching prevents access
        XCTAssertFalse(messageInfo.didGetFunction) // caching prevents access
        XCTAssertFalse(messageInfo.didGetLine) // caching prevents access
        XCTAssertTrue(messageInfo.didGetLevel)
        XCTAssertTrue(messageInfo.didGetChannel)
        XCTAssertTrue(messageInfo.didGetMessage)
        XCTAssertTrue(messageInfo.didComposeFileFunctionLineString) // cached value, access will not reconstruct string
        XCTAssertTrue(messageInfo.didComposeFormattedMessage) // does use "composeFormattedMessage"
        messageInfo.reset()
    }

    func testCrashlyticsOutputStream()
    {
        var longMessage = "This is a long message that will exceed 16KB so that we can test that it will be discarded."
        while (longMessage.count < 16 * 1024) {
            longMessage += longMessage
        }
        let crashlyticsOutputStream = TLSLoggingSwiftTestCrashlyticsOutputStream()
        let messageInfo = self.dummyLogMessageInfo()
        let longMessageInfo = self.dummyLogMessageInfo(longMessage)

        crashlyticsOutputStream.tls_outputLogInfo(messageInfo)
        XCTAssertTrue(messageInfo.didGetMessage)
        XCTAssertTrue(crashlyticsOutputStream.didOutputLogMessageToCrashlytics)
        crashlyticsOutputStream.reset()
        messageInfo.reset()

        crashlyticsOutputStream.discardLargeLogMessagesOverride = true
        crashlyticsOutputStream.tls_outputLogInfo(messageInfo)
        XCTAssertFalse(messageInfo.didGetMessage) // cached
        XCTAssertTrue(crashlyticsOutputStream.didOutputLogMessageToCrashlytics)
        crashlyticsOutputStream.reset()
        messageInfo.reset()

        crashlyticsOutputStream.tls_outputLogInfo(longMessageInfo)
        XCTAssertTrue(longMessageInfo.didGetMessage)
        XCTAssertTrue(crashlyticsOutputStream.didOutputLogMessageToCrashlytics)
        crashlyticsOutputStream.reset()
        longMessageInfo.reset()

        crashlyticsOutputStream.discardLargeLogMessagesOverride = true
        crashlyticsOutputStream.tls_outputLogInfo(longMessageInfo)
        XCTAssertFalse(longMessageInfo.didGetMessage) // cached
        XCTAssertFalse(crashlyticsOutputStream.didOutputLogMessageToCrashlytics)
        crashlyticsOutputStream.reset()
        longMessageInfo.reset()
    }

    func testExtraLargeLogMessage()
    {
        var longMessage = "This is a long message that will exceed 16KB so that we can test that it will be discarded."
        while (longMessage.count < 16 * 1024) {
            longMessage += longMessage
        }

        var expectation: XCTestExpectation
        let service = TLSLoggingService()
        let delegate = TLSLoggingSwiftTestServiceDelegate()
        let outputStream = TLSLoggingSwiftTestOutputStream()

        service.delegate = delegate
        outputStream.shouldPrint = false
        service.addOutputStream(outputStream)

        // will log
        service.maximumSafeMessageLength = 0
        expectation = self.expectation(forNotification: NSNotification.Name(rawValue: Notification.Name.LoggingSwiftTestOutputStreamNotification.rawValue), object: nil, handler: nil)
        TLSLogString(service, TLSLogLevel.error, "AnyChannel", #file, #function, #line, nil, TLSLogMessageOptions(), longMessage)
        self.waitForExpectations(timeout: 10, handler: nil)

        // won't log
        service.maximumSafeMessageLength = 16 * 1024
        expectation = self.expectation(forNotification: NSNotification.Name(rawValue: Notification.Name.LoggingSwiftTestDiscardedMessageNotification.rawValue), object: nil, handler: nil)
        TLSLogString(service, TLSLogLevel.error, "AnyChannel", #file, #function, #line, nil, TLSLogMessageOptions(), longMessage)
        self.waitForExpectations(timeout: 10, handler: nil)

        // just to avoid the compiler warning :(
        // can't do `(void)expectation;` like in C/ObjC
        if expectation.isKind(of: XCTestExpectation.self) {

        }
    }
}
