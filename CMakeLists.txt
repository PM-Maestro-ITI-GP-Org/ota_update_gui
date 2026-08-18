#
# ota_update_gui -- the OTA update app.
#
# Builds two ways and both matter:
#
#   * on its own, as it always has: cmake -B build && ./build/ota_gui
#   * as a library inside PdM-Maestro_gui, where it becomes the OTA tab
#
# The split is the library below plus a main() that is only compiled when this
# repository is the top-level project. See docs/INTEGRATION_CONTRACT.md in the
# Maestro repo for the rules and the breakage each one prevents.
#
cmake_minimum_required(VERSION 3.21)

project(OtaGui
    VERSION 0.2.0
    DESCRIPTION "Hypervisor management and OTA update"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 6.5, up from the unversioned find_package this used to do. The QML module
# machinery below (qt_add_qml_module, loadFromModule, static plugin handling)
# wants it, and the system Qt 6.2.4 will no longer do -- point CMake at a newer
# one the normal way:
#
#   cmake -B build -DCMAKE_PREFIX_PATH=$HOME/Qt/6.10.3/gcc_64
#
# QuickControls2 is a real link dependency: main.cpp calls QQuickStyle::setStyle()
# to select Material before the engine loads any QML.
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Qml Network Widgets QuickControls2)

qt_standard_project_setup(REQUIRES 6.5)

# The palette, message bus and app registry. Carried as a submodule so this repo
# still builds when cloned on its own; the guard is what stops it being added a
# second time inside a Maestro build, where Maestro has already added its own
# pinned copy and both would claim the PdM.Core module URI.
if(NOT TARGET pdm_core)
    add_subdirectory(core)
endif()

# Find Paho MQTT C library
find_path(PAHO_MQTT_INCLUDE_DIR MQTTClient.h)
find_library(PAHO_MQTT_LIBRARY NAMES paho-mqtt3c paho-mqtt3a)

if(NOT PAHO_MQTT_INCLUDE_DIR OR NOT PAHO_MQTT_LIBRARY)
    message(WARNING "Paho MQTT C library not found — building without MQTT "
                    "(the UI runs, but cannot talk to HMS). "
                    "Install it with: sudo apt install libpaho-mqtt-dev")
    set(WITH_MQTT OFF)
else()
    set(WITH_MQTT ON)
endif()

#
# ---- the app, as a library --------------------------------------------------
#
qt_add_library(pdm_ota STATIC)

# OtaAppPage.qml is the root -- the page that used to be main.qml. OtaPage.qml
# is one of the five screens inside it and always was; the names are close
# enough to be worth pointing out.
#
# Main.qml is deliberately not in this list. It belongs to the standalone
# executable's module further down, because a file that imports PdM.Ota cannot
# also be a member of it.
qt_add_qml_module(pdm_ota
    URI PdM.Ota
    VERSION 1.0
    SOURCES
        mqttclient.h
        mqttclient.cpp
        control.h
        control.cpp
        otaapp.h
        otaapp.cpp
    QML_FILES
        OtaAppPage.qml
        AppCard.qml
        SectionTitle.qml
        StatusPill.qml
        FilledButton.qml
        LogPanel.qml
        GuestMonitor.qml
        GuestsPage.qml
        OtaPage.qml
        ShellPage.qml
        StatsParser.js
)

# So the shell can reach otaapp.h to call registerWithShell().
target_include_directories(pdm_ota PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
)

target_link_libraries(pdm_ota PUBLIC
    pdm_core
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Widgets
    Qt6::QuickControls2
)

if(WITH_MQTT)
    target_include_directories(pdm_ota PRIVATE ${PAHO_MQTT_INCLUDE_DIR})
    target_link_libraries(pdm_ota PRIVATE ${PAHO_MQTT_LIBRARY})
    target_compile_definitions(pdm_ota PRIVATE HAVE_MQTT)
endif()

#
# ---- the standalone app -----------------------------------------------------
#
# Not compiled when Maestro pulls this repository in with add_subdirectory():
# there, PROJECT_IS_TOP_LEVEL is false and the shell owns the only main().
#
if(PROJECT_IS_TOP_LEVEL)
    qt_add_executable(ota_gui main.cpp)

    # Its own module, so Main.qml can import PdM.Ota without the circularity of
    # being a member of the module it imports.
    qt_add_qml_module(ota_gui
        URI OtaGuiApp
        VERSION 1.0
        QML_FILES Main.qml
    )

    # Both halves of each static QML module: the library carries the types, the
    # plugin carries the registration that Q_IMPORT_QML_PLUGIN in main.cpp
    # refers to. Linking only the libraries fails at link time; omitting the
    # macros builds clean and fails at run time with a missing type.
    target_link_libraries(ota_gui PRIVATE
        pdm_ota
        pdm_otaplugin
        pdm_core
        pdm_coreplugin
    )

    install(TARGETS ota_gui RUNTIME DESTINATION bin)
endif()
