import Foundation
import AppKit

enum UpdateInstaller {
    enum InstallError: Error {
        case downloadFailed
        case unzipFailed
        case appNotFound
    }

    /// Downloads the zip, verifies its build provenance, replaces the running .app via a
    /// helper script, then quits.
    static func install(from downloadURL: URL, version: String) async throws {
        // 1. Download zip
        var request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("ClaudeOMeter", forHTTPHeaderField: "User-Agent")
        guard let (zipTemp, response) = try? await URLSession.shared.download(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.downloadFailed
        }

        // Move zip to a stable temp path before URLSession cleans it up
        let zipPath = NSTemporaryDirectory() + "ClaudeOMeter_update.zip"
        try? FileManager.default.removeItem(atPath: zipPath)
        try FileManager.default.moveItem(at: zipTemp, to: URL(fileURLWithPath: zipPath))

        // 1a. Verify before anything touches the installed app. We are about to strip the
        // Gatekeeper quarantine flag ourselves, so this is the only integrity check the
        // user gets. Throwing here leaves the current install untouched.
        try await UpdateVerifier.verify(zipAt: URL(fileURLWithPath: zipPath), version: version)

        // 2. Unzip
        let destDir = NSTemporaryDirectory() + "ClaudeOMeter_update"
        try? FileManager.default.removeItem(atPath: destDir)
        try await runProcess("/usr/bin/unzip", args: ["-q", zipPath, "-d", destDir])

        let newAppPath = destDir + "/ClaudeOMeter.app"
        guard FileManager.default.fileExists(atPath: newAppPath) else {
            throw InstallError.appNotFound
        }

        // 3. Write a helper script that waits for us to exit, replaces the app, and relaunches.
        //
        // The destination is wherever this bundle is actually running from, not a hardcoded
        // /Applications. scripts/install.sh installs to ~/Applications, so hardcoding left
        // those users with a second copy in /Applications while the one they launched stayed
        // stale, and failed outright when /Applications was not writable.
        //
        // The new bundle is staged alongside the destination and swapped in by rename, so a
        // failed copy can no longer delete a working install and leave nothing behind.
        // Under `swift run` the main bundle is a build directory rather than a .app, so fall
        // back instead of letting the swap overwrite it.
        let script = helperScript(destPath: installDestination(),
                                  newAppPath: newAppPath,
                                  destDir: destDir,
                                  zipPath: zipPath,
                                  quittingPID: ProcessInfo.processInfo.processIdentifier)
        let scriptPath = NSTemporaryDirectory() + "claudeometer_update.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // 4. Launch the script detached, then quit so it can replace us
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath]
        try task.run()

        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Where the update should land: wherever this bundle is actually running from.
    ///
    /// Hardcoding /Applications was wrong because scripts/install.sh installs to
    /// ~/Applications, so those users got a second copy in /Applications while the one they
    /// had launched stayed stale. Under `swift run` the main bundle is a build directory
    /// rather than a .app, so fall back instead of overwriting it.
    static func installDestination(bundleURL: URL = Bundle.main.bundleURL,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard bundleURL.pathExtension != "app" else { return bundleURL.path }
        // Dev fallback only. ~/Applications rather than /Applications, matching where
        // install.sh puts the app: it needs no admin rights, so an update can always be
        // written without prompting for a password.
        return home.appendingPathComponent("Applications/ClaudeOMeter.app").path
    }

    /// Replaces the installed bundle and relaunches it.
    ///
    /// The new bundle is staged beside the destination and swapped in by rename, so a failed
    /// copy can no longer delete a working install and leave nothing behind. Every failure
    /// path restores what was there and relaunches it.
    static func helperScript(destPath: String,
                             newAppPath: String,
                             destDir: String,
                             zipPath: String,
                             quittingPID: Int32 = 0) -> String {
        """
        #!/bin/bash
        set -u

        # Guard rail for every recursive delete below. A path is only ever removed if it is
        # absolute, at least two levels deep, and free of "..". An empty or malformed
        # variable therefore deletes nothing rather than something catastrophic, which
        # matters because these paths are interpolated from the running process.
        safe_rm() {
          target="${1:-}"
          case "$target" in
            ''|'/')  return 0 ;;
            *..*)    return 0 ;;
            /*/*)    rm -rf "$target" ;;
            *)       return 0 ;;
          esac
        }

        DEST="\(destPath)"

        # Same reasoning applied to the destination itself: refuse to run at all unless it
        # looks like an app bundle nested at least two levels down.
        case "$DEST" in
          *..*)      echo "unsafe destination: $DEST" >&2; exit 1 ;;
          /*/*.app)  ;;
          *)         echo "unsafe destination: $DEST" >&2; exit 1 ;;
        esac

        STAGE="$DEST.new"
        BACKUP="$DEST.old"

        # Wait for the app to actually exit. A fixed sleep races a slow shutdown and would
        # swap the bundle out from under a live process, which then relaunches as a second
        # instance. Polling the pid is deterministic; the timeout only bounds the wait.
        PID=\(quittingPID)
        WAITED=0
        LIMIT="${CLAUDEOMETER_EXIT_TIMEOUT:-30}"
        while [ "$PID" -gt 0 ] && kill -0 "$PID" 2>/dev/null && [ "$WAITED" -lt "$LIMIT" ]; do
          sleep 1
          WAITED=$((WAITED + 1))
        done

        # If it never exited, do not swap the bundle out from under a live process. That
        # would also poison the launch check below, which asks whether a ClaudeOMeter is
        # running: the *old* one still would be, so a crashed new build would look
        # healthy and the rollback copy would be thrown away.
        if [ "$PID" -gt 0 ] && kill -0 "$PID" 2>/dev/null; then
          echo "app is still running after ${LIMIT}s; leaving the current version alone" >&2
          exit 1
        fi

        sleep "${CLAUDEOMETER_UPDATE_DELAY:-1}"

        safe_rm "$STAGE"
        safe_rm "$BACKUP"

        if ! cp -R "\(newAppPath)" "$STAGE"; then
          safe_rm "$STAGE"
          open "$DEST" 2>/dev/null
          exit 1
        fi
        xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null

        if [ -e "$DEST" ] && ! mv "$DEST" "$BACKUP"; then
          safe_rm "$STAGE"
          open "$DEST" 2>/dev/null
          exit 1
        fi
        if ! mv "$STAGE" "$DEST"; then
          [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
          safe_rm "$STAGE"
          open "$DEST" 2>/dev/null
          exit 1
        fi

        # Keep the previous version until the new one proves it can start. Discarding it
        # first meant a build that crashed on launch left no way back at all, with the
        # working copy already deleted.
        open "$DEST"

        STARTED=0
        WAITED=0
        LIMIT="${CLAUDEOMETER_LAUNCH_TIMEOUT:-20}"
        # Without pgrep there is no way to tell, and rolling back a healthy install on a
        # missing tool would be worse than skipping the check.
        if ! command -v pgrep >/dev/null 2>&1; then
          STARTED=1
        fi
        while [ "$STARTED" -eq 0 ] && [ "$WAITED" -lt "$LIMIT" ]; do
          if pgrep -x "ClaudeOMeter" >/dev/null 2>&1; then STARTED=1; break; fi
          sleep 1
          WAITED=$((WAITED + 1))
        done

        if [ "$STARTED" -eq 1 ]; then
          safe_rm "$BACKUP"
        elif [ -d "$BACKUP" ]; then
          # Roll back. Every branch must leave *some* working bundle at $DEST: ending up
          # with none is the failure this whole dance exists to avoid.
          echo "new version did not start; restoring the previous one" >&2
          safe_rm "$DEST.failed"
          if mv "$DEST" "$DEST.failed" 2>/dev/null; then
            if mv "$BACKUP" "$DEST"; then
              safe_rm "$DEST.failed"
            else
              # Could not put the old one back, so return the new one rather than
              # leave the destination empty.
              mv "$DEST.failed" "$DEST" 2>/dev/null
            fi
          fi
          open "$DEST"
        fi

        safe_rm "\(destDir)"
        [ -n "\(zipPath)" ] && rm -f "\(zipPath)"
        rm -- "$0"
        """
    }

    private static func runProcess(_ executable: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            do {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: NSError(domain: "UpdateInstaller",
                                                      code: Int(process.terminationStatus)))
                    }
                }
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
