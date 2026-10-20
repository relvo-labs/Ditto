QT += qml dbus network
QT -= gui
CONFIG += plugin c++17 no_qt_rpath
TEMPLATE = lib
TARGET = dittonetwork
SOURCES = network.cpp
