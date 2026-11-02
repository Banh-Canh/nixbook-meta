pragma Singleton
import Quickshell
import "theme_moods.js" as Moods

/**
 * A mood asked of the desktop as one of the shell's themes (theme_moods.js,
 * plain code): "make my desktop calmer and cozier" → Studio Ghibli. For
 * QuickIntent; anything unsure (two moods, a negation, a question) is null.
 */
Singleton {
    function mood(text) {
        return Moods.mood(text)
    }
}
