pragma Singleton
import Quickshell
import "away_changes.js" as Changes

/**
 * The calendar's changes while the user was away (away_changes.js, plain
 * code): "While you were away" (services/AwaySummary.qml).
 */
Singleton {
    function changes(before, current, now) {
        return Changes.changes(before, current, now)
    }
}
