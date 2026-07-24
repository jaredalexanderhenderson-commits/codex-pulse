# Codex Pulse installation

1. Unzip `Codex-Pulse.zip`. The archive is the canonical signed deliverable.
2. Drag **Codex Pulse.app** into your Applications folder, or run it directly from the delivered folder.
3. If macOS asks for confirmation because the app is ad-hoc signed, Control-click the app, choose **Open**, then confirm.
4. Codex Pulse appears in both the Dock and the menu bar. Closing the dashboard leaves the tracker active.
5. To keep it permanently in the Dock even when it is not running, Control-click its Dock icon and choose **Options → Keep in Dock**.

Move the dashboard by dragging its Codex Pulse header at the top of the window. The Refresh and Settings controls remain clickable.

The menu-bar percentage and dashboard weekly-limit card show the percentage remaining. The three usage rows in the menu are clickable and open the full dashboard.

Codex Pulse checks for signed updates after launch. You can also choose **Check for Updates…** from the menu-bar menu. Beginning with version 1.4.2, updates download, verify, install, and relaunch directly from the app.

On first launch, Codex Pulse imports eligible local token events from the preceding seven days. It retains recent local detail for up to 14 days and caps the ledger at 25,000 events to keep long-running installations responsive.

The app reads `~/.codex/sessions` and `~/.codex/archived_sessions`. It does not modify those directories and does not retain prompts, responses, tool output, or reasoning text.

Tracker state lives in:

```text
~/Library/Application Support/Codex Pulse/usage-store.json
```

Use **Settings → Reset & re-import seven days** to rebuild the tracker ledger without affecting Codex data.

To remove Codex Pulse, quit it from the menu-bar menu and move the app to Trash. Its Application Support folder may be removed separately if you also want to discard the tracker ledger.
