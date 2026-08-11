cmake_minimum_required(VERSION 3.16)
project(OtaGui LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Qt6_DIR used to be hardcoded to /home/gemy/Qt/6.10.2/gcc_64/lib/cmake/Qt6,
# which is one developer's machine. Point CMake at your Qt with the standard
# variable instead, and it will be found normally when Qt is on the default
# search path:
#
#     cmake -B build -DCMAKE_PREFIX_PATH=$HOME/Qt/6.10.2/gcc_64
#
# QuickControls2 is a real link dependency now: main.cpp calls
# QQuickStyle::setStyle() to select Material before the engine loads any QML.
find_package(Qt6 REQUIRED COMPONENTS Quick Qml Network Widgets QuickControls2)

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

set(APP_QML_FILES
    main.qml
    Theme.qml
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

add_executable(ota_gui
    main.cpp
    mqttclient.h
    mqttclient.cpp
    control.cpp
    ${APP_QML_FILES}
)

target_link_libraries(ota_gui PRIVATE
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Widgets
    Qt6::QuickControls2
)

if(WITH_MQTT)
    target_include_directories(ota_gui PRIVATE ${PAHO_MQTT_INCLUDE_DIR})
    target_link_libraries(ota_gui PRIVATE ${PAHO_MQTT_LIBRARY})
    target_compile_definitions(ota_gui PRIVATE HAVE_MQTT)
endif()

qt6_add_resources(ota_gui "resources"
    PREFIX "/"
    FILES ${APP_QML_FILES}
)

install(TARGETS ota_gui RUNTIME DESTINATION bin)
