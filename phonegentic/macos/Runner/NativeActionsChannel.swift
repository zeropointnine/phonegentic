import Cocoa
import FlutterMacOS
import EventKit

class NativeActionsChannel {
    private let channel: FlutterMethodChannel
    private let eventStore = EKEventStore()
    private var remindersAccessGranted = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.agentic_ai/native_actions",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAvailableActions":
            getAvailableActions(result: result)
        case "createReminder":
            guard let args = call.arguments as? [String: Any],
                  let title = args["title"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing title", details: nil))
                return
            }
            createReminder(
                title: title,
                body: args["body"] as? String,
                dueDateMs: args["dueDateMs"] as? Int64,
                remindDateMs: args["remindDateMs"] as? Int64,
                priority: args["priority"] as? Int,
                listName: args["listName"] as? String,
                result: result
            )
        case "getReminderLists":
            getReminderLists(result: result)
        case "startFaceTimeCall":
            guard let args = call.arguments as? [String: Any],
                  let target = args["target"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing target", details: nil))
                return
            }
            let audioOnly = args["audioOnly"] as? Bool ?? true
            startFaceTimeCall(target: target, audioOnly: audioOnly, result: result)
        case "createNote":
            guard let args = call.arguments as? [String: Any],
                  let title = args["title"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing title", details: nil))
                return
            }
            createNote(
                title: title,
                body: args["body"] as? String,
                folderName: args["folderName"] as? String,
                result: result
            )
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Available Actions

    private func getAvailableActions(result: @escaping FlutterResult) {
        var actions: [String: Bool] = [
            "reminders": true,
            "facetime": true,
            "notes": isNotesAvailable(),
        ]
        result(actions)
    }

    private func isNotesAvailable() -> Bool {
        #if APP_STORE_BUILD
        return false
        #else
        let testScript = NSAppleScript(source: "tell application \"System Events\" to return name of current application")
        var error: NSDictionary?
        testScript?.executeAndReturnError(&error)
        return error == nil
        #endif
    }

    // MARK: - Reminders (EventKit)

    private func requestRemindersAccess(completion: @escaping (Bool) -> Void) {
        if remindersAccessGranted {
            completion(true)
            return
        }
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                self?.remindersAccessGranted = granted
                completion(granted)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { [weak self] granted, error in
                self?.remindersAccessGranted = granted
                completion(granted)
            }
        }
    }

    private func createReminder(
        title: String,
        body: String?,
        dueDateMs: Int64?,
        remindDateMs: Int64?,
        priority: Int?,
        listName: String?,
        result: @escaping FlutterResult
    ) {
        requestRemindersAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PERMISSION_DENIED", message: "Reminders access denied", details: nil))
                }
                return
            }

            let reminder = EKReminder(eventStore: self.eventStore)
            reminder.title = title
            reminder.notes = body

            if let ms = dueDateMs {
                let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
                let cal = Calendar.current
                reminder.dueDateComponents = cal.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: date
                )
            }

            if let ms = remindDateMs {
                let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
                let alarm = EKAlarm(absoluteDate: date)
                reminder.addAlarm(alarm)
            }

            if let p = priority {
                reminder.priority = p
            }

            if let name = listName {
                let calendars = self.eventStore.calendars(for: .reminder)
                if let target = calendars.first(where: { $0.title == name }) {
                    reminder.calendar = target
                } else {
                    reminder.calendar = self.eventStore.defaultCalendarForNewReminders()
                }
            } else {
                reminder.calendar = self.eventStore.defaultCalendarForNewReminders()
            }

            do {
                try self.eventStore.save(reminder, commit: true)
                DispatchQueue.main.async {
                    result(["id": reminder.calendarItemIdentifier])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func getReminderLists(result: @escaping FlutterResult) {
        requestRemindersAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PERMISSION_DENIED", message: "Reminders access denied", details: nil))
                }
                return
            }

            let calendars = self.eventStore.calendars(for: .reminder)
            let defaultCal = self.eventStore.defaultCalendarForNewReminders()
            let list = calendars.map { cal -> [String: Any] in
                return [
                    "title": cal.title,
                    "isDefault": cal.calendarIdentifier == defaultCal?.calendarIdentifier,
                ]
            }
            DispatchQueue.main.async {
                result(list)
            }
        }
    }

    // MARK: - FaceTime (URL Scheme)

    private func startFaceTimeCall(target: String, audioOnly: Bool, result: @escaping FlutterResult) {
        let scheme = audioOnly ? "facetime-audio" : "facetime"
        let sanitized = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
        guard let url = URL(string: "\(scheme)://\(sanitized)") else {
            result(FlutterError(code: "INVALID_URL", message: "Could not build FaceTime URL for \(target)", details: nil))
            return
        }
        NSWorkspace.shared.open(url)
        result(nil)
    }

    // MARK: - Notes (AppleScript)

    private func createNote(title: String, body: String?, folderName: String?, result: @escaping FlutterResult) {
        guard isNotesAvailable() else {
            result(FlutterError(
                code: "UNAVAILABLE",
                message: "Notes creation is not available in this build (requires direct distribution)",
                details: nil
            ))
            return
        }

        let escapedTitle = escapeAppleScriptString(title)
        let htmlBody = escapeAppleScriptString(body ?? "")
        let folder = escapeAppleScriptString(folderName ?? "Notes")

        let scriptSource = """
        tell application "Notes"
            activate
            tell account "iCloud"
                make new note at folder "\(folder)" with properties {name:"\(escapedTitle)", body:"\(htmlBody)"}
            end tell
        end tell
        """

        var error: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        let output = script?.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            result(FlutterError(code: "APPLESCRIPT_ERROR", message: message, details: nil))
        } else {
            result(["success": true])
        }
    }

    private func escapeAppleScriptString(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
