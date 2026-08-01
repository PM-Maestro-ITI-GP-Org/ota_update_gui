cmake_minimum_required(VERSION 3.16)
project(OtaGui)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(Qt6_DIR "/home/gemy/Qt/6.10.2/gcc_64/lib/cmake/Qt6" CACHE PATH "Qt6 installation directory")
find_package(Qt6 REQUIRED COMPONENTS Quick Qml Network Widgets)

# Find Paho MQTT C library
find_path(PAHO_MQTT_INCLUDE_DIR MQTTClient.h)
find_library(PAHO_MQTT_LIBRARY NAMES paho-mqtt3c paho-mqtt3a)

if(NOT PAHO_MQTT_INCLUDE_DIR OR NOT PAHO_MQTT_LIBRARY)
    message(WARNING "Paho MQTT C library not found — building without MQTT")
    set(WITH_MQTT OFF)
else()
    set(WITH_MQTT ON)
    include_directories(${PAHO_MQTT_INCLUDE_DIR})
endif()

add_executable(ota_gui
    main.cpp
    mqttclient.h
    mqttclient.cpp
    main.qml
    LogPanel.qml
    GuestMonitor.qml
    StatsParser.js
)

target_link_libraries(ota_gui PRIVATE
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Widgets
)

if(WITH_MQTT)
    target_link_libraries(ota_gui PRIVATE ${PAHO_MQTT_LIBRARY})
    target_compile_definitions(ota_gui PRIVATE HAVE_MQTT)
endif()

qt6_add_resources(ota_gui "resources"
    PREFIX "/"
    FILES main.qml LogPanel.qml GuestMonitor.qml StatsParser.js
)

install(TARGETS ota_gui RUNTIME DESTINATION bin)
