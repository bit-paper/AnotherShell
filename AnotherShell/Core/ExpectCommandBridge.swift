import Foundation

enum ExpectCommandBridge {
    struct LaunchSpec {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let scriptURL: URL
    }

    enum Mode {
        case interactive
        case batch(timeout: TimeInterval)
    }

    static func makeLaunchSpec(
        command: String,
        arguments: [String],
        password: String,
        mode: Mode
    ) -> LaunchSpec? {
        let cleanedPassword = password
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")

        guard !cleanedPassword.isEmpty else {
            return nil
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anothershell-expect-\(UUID().uuidString).exp")

        let script = scriptContents(for: mode)

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        var environment: [String: String] = [
            "ANOTHERSHELL_SSH_PASSWORD": cleanedPassword
        ]

        if case let .batch(timeout) = mode {
            environment["ANOTHERSHELL_EXPECT_TIMEOUT"] = String(Int(timeout.rounded(.up)))
        }

        return LaunchSpec(
            executablePath: "/usr/bin/expect",
            arguments: [scriptURL.path, command] + arguments,
            environment: environment,
            scriptURL: scriptURL
        )
    }

    static func removeScript(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func scriptContents(for mode: Mode) -> String {
        switch mode {
        case .interactive:
            return """
            set password ""
            if {[info exists env(ANOTHERSHELL_SSH_PASSWORD)]} {
                set password $env(ANOTHERSHELL_SSH_PASSWORD)
            }
            set timeout 20
            set acceptedHostKey 0
            set passwordSent 0

            proc maybe_accept_host_key {} {
                global acceptedHostKey
                if {$acceptedHostKey == 0} {
                    set acceptedHostKey 1
                    send -- "yes\\r"
                }
            }

            proc maybe_send_password {} {
                global password
                global passwordSent
                if {$password ne "" && $passwordSent == 0} {
                    set passwordSent 1
                    send -- "$password\\r"
                }
            }

            eval spawn -noecho $argv

            expect {
                -re "(?i)yes/no" {
                    maybe_accept_host_key
                    exp_continue
                }
                -re "(?i)password:" {
                    maybe_send_password
                }
                -re "(?i)passphrase for key" {
                    maybe_send_password
                }
                timeout {
                }
                eof {
                    catch wait waitResult
                    if {[llength $waitResult] >= 4} {
                        exit [lindex $waitResult 3]
                    }
                    exit 0
                }
            }

            set timeout -1
            interact
            catch wait waitResult
            if {[llength $waitResult] >= 4} {
                exit [lindex $waitResult 3]
            }
            exit 0
            """
        case .batch:
            return """
            set password ""
            if {[info exists env(ANOTHERSHELL_SSH_PASSWORD)]} {
                set password $env(ANOTHERSHELL_SSH_PASSWORD)
            }
            set timeout 120
            if {[info exists env(ANOTHERSHELL_EXPECT_TIMEOUT)]} {
                catch { set timeout [expr {int($env(ANOTHERSHELL_EXPECT_TIMEOUT))}] }
            }
            set acceptedHostKey 0
            set passwordSent 0

            proc maybe_accept_host_key {} {
                global acceptedHostKey
                if {$acceptedHostKey == 0} {
                    set acceptedHostKey 1
                    send -- "yes\\r"
                }
            }

            proc maybe_send_password {} {
                global password
                global passwordSent
                if {$password ne "" && $passwordSent == 0} {
                    set passwordSent 1
                    send -- "$password\\r"
                }
            }

            eval spawn -noecho $argv

            expect {
                -re "(?i)yes/no" {
                    maybe_accept_host_key
                    exp_continue
                }
                -re "(?i)password:" {
                    maybe_send_password
                    exp_continue
                }
                -re "(?i)passphrase for key" {
                    maybe_send_password
                    exp_continue
                }
                timeout {
                    send_error "Timed out waiting for command completion\\n"
                    exit 124
                }
                eof {
                }
            }

            catch wait waitResult
            if {[llength $waitResult] >= 4} {
                exit [lindex $waitResult 3]
            }
            exit 0
            """
        }
    }
}
