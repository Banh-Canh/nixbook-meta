//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
// Remove two slashes below and adjust the value to change the UI scale
////@ pragma Env QT_SCALE_FACTOR=1
import "modules/common"
import "services"
import "panelFamilies"
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.modules.ii.equalizer

ShellRoot {
    id: root

    ReloadPopup {}

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme()
        NightLightService.load()
        FirstRunExperience.load()
        ConflictKiller.load()
        Cliphist.refresh()
        Wallpapers.load()
        UpdateState.load()
        CalendarEvents.load()
        CalendarReminders.load()
        MemoryReminders.load()
        Initiative.load()
        RecentContext.load()
        Routines.load()
        SelfImprove.load()
        ThemeWallpapers.load()
        NiriThemeAnimations.load()
        Preloader.load()
        DesktopControl.load()
        WindowLayouts.load()
        // Projects (projects IPC) and teach mode (teach IPC).
        Projects.load()
        TeachMode.load()
        AppTheming.load()
        // Their IPC targets (widgets, notes, todo, contacts, timers,
        // musicRecognition, equalizer) exist once they are loaded.
        DesktopWidgets.load()
        Notes.load()
        KeepSync.load()
        Todo.load()
        Contacts.load()
        TimerService.load()
        SongRec.load()
        EqualizerAutoService.load()
        // Quick AI's targets (quickAi, voice, kiroshi, nixOnboarding): the keys
        // call them before any of their panels was opened.
        QuickAi.load()
        Voice.load()
        // Read this to me, and the voice-only preset's Full AI mode at login.
        Accessibility.load()
        Kiroshi.load()
        NixOnboarding.load()
        FullAi.load()
        Addressee.load()
        MascotState.load()
        SmartClipboard.load()
        // Autonomy and reactivity: the journal and trust (journal IPC), the
        // background tasks (tasks IPC), the offers before being asked.
        Autonomy.load()
        MuseTasks.load()
        ContextTriggers.load()
        // The meeting companion: its `meeting` IPC target, the offers, the
        // old transcripts pruned.
        Meeting.load()
        // "Next up": its IPC target (the accept key) from the start.
        NextUp.load()
        // "While you were away": watching for the user leaving from the start.
        AwaySummary.load()
        // The daily brief (its day-start and evening cards), the reply
        // batch (its offer, the `replies` target), the phone handoff.
        DailyBrief.load()
        ReplyBatch.load()
        PhoneHandoff.load()
    }
    
    PanelFamilyLoader {
        identifier: "ii"
        component: IllogicalImpulseFamily {}
    }

    component PanelFamilyLoader: LazyLoader {
        required property string identifier
        active: Config.ready && Config.options.panelFamily === identifier
    }
}