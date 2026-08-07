pragma Singleton

import QtQuick

/*
 * The single source of colour, type and spacing for the whole app.
 *
 * Registered as a singleton from main.cpp (qmlRegisterSingletonType with this
 * file's URL), so every page says `Theme.surface` rather than repeating a hex
 * literal. The old UI had the GitHub-dark palette pasted inline in roughly
 * three hundred places, which is why it was dark-only and why no two panels
 * quite agreed on a shade of grey.
 *
 * `pragma Singleton` is required alongside the C++ registration: Qt synthesises
 * a qmldir entry marking the type a singleton and refuses to load the file
 * without it.
 *
 * Light is the default. Flip `dark` to switch; every colour below is derived
 * from it, so nothing else needs to know which mode is on.
 */
QtObject {
    id: theme

    /* ---------------- mode ---------------- */

    property bool dark: false

    /* ---------------- surfaces ---------------- */

    readonly property color background:     dark ? "#0F151B" : "#EFF2F6"
    readonly property color surface:        dark ? "#18212B" : "#FFFFFF"
    readonly property color surfaceVariant: dark ? "#212D39" : "#EDF1F6"
    readonly property color surfaceSunken:  dark ? "#131A22" : "#F8FAFC"
    readonly property color outline:        dark ? "#2C3A48" : "#DFE5EC"
    readonly property color overlay:        dark ? "#B0000000" : "#551B2A3A"

    /* ---------------- text ---------------- */

    readonly property color textPrimary:    dark ? "#E9EEF4" : "#16202C"
    readonly property color textSecondary:  dark ? "#9BACBD" : "#5C6C7E"
    readonly property color textDisabled:   dark ? "#5E6E7E" : "#A3AFBB"
    readonly property color textOnAccent:   "#FFFFFF"

    /* ---------------- accents ----------------
       Material palette steps, picked one shade apart between modes so both
       keep contrast against their own background rather than one being a
       washed-out version of the other. */

    readonly property color primary:        dark ? "#5CA8F0" : "#1565C0"
    readonly property color primaryHover:   dark ? "#7CBCF5" : "#0D47A1"
    readonly property color primarySoft:    dark ? "#225CA8F0" : "#141565C0"

    readonly property color success:        dark ? "#5DBE63" : "#2E7D32"
    readonly property color successSoft:    dark ? "#225DBE63" : "#142E7D32"

    readonly property color warning:        dark ? "#F0A93B" : "#B26A00"
    readonly property color warningSoft:    dark ? "#22F0A93B" : "#14B26A00"

    readonly property color danger:         dark ? "#EF5F5B" : "#C62828"
    readonly property color dangerSoft:     dark ? "#22EF5F5B" : "#14C62828"

    readonly property color neutralSoft:    dark ? "#1F9BACBD" : "#145C6C7E"

    /* ---------------- type ----------------
       The old UI ran at 11-12px almost everywhere, which is what made it hard
       to read. The base is 15px now and nothing user-facing is below 13. */

    readonly property int fontTiny:    12
    readonly property int fontSmall:   13
    readonly property int fontBody:    15
    readonly property int fontMedium:  16
    readonly property int fontLarge:   18
    readonly property int fontTitle:   22
    readonly property int fontDisplay: 26

    readonly property string monoFamily: Qt.platform.os === "windows"
        ? "Consolas" : "DejaVu Sans Mono"

    /* ---------------- metrics ---------------- */

    readonly property int radiusSmall:  8
    readonly property int radius:       12
    readonly property int radiusLarge:  16

    readonly property int spacingTight: 8
    readonly property int spacing:      16
    readonly property int spacingLoose: 24

    readonly property int controlHeight: 44
    readonly property int rowHeight:     64
    readonly property int headerHeight:  40

    /* Shadow strength for AppCard; deliberately subtle in light mode, since a
       heavy drop shadow on white is the fastest way to make a UI look dated. */
    readonly property color shadowColor: dark ? "#70000000" : "#1A0F213A"
}
