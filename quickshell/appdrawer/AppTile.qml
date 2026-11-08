import QtQuick

// One app in the grid. Falls back to a lettered tile when no icon file could
// be resolved, so a missing theme entry degrades instead of leaving a hole.
Item {
    id: tile

    required property var app
    property bool selected: false

    signal triggered()
    signal menu()

    implicitWidth: Theme.tileWidth
    implicitHeight: Theme.tileHeight

    // Pressed tiles sink a little, released ones spring back: the press is
    // felt before the launch happens. Scale is a transform on the GPU, no
    // relayout.
    scale: press.pressed ? 0.94 : 1.0
    Behavior on scale {
        NumberAnimation {
            duration: press.pressed ? Theme.durPress : Theme.durMove
            easing.type: press.pressed ? Easing.OutCubic : Easing.OutBack
            easing.overshoot: 2.2
        }
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        anchors.margins: 3
        radius: Theme.tileRadius
        color: tile.selected ? Theme.selectedSoft
                              : (hover.hovered ? Theme.hoverSoft : "transparent")
        border.width: tile.selected || hover.hovered ? 1 : 0
        border.color: tile.selected ? Theme.alpha(Theme.accent, 0.55) : Theme.glassHighlight
        Behavior on color {
            ColorAnimation { duration: Theme.durHover }
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }

    Column {
        anchors.centerIn: parent
        spacing: 6
        width: parent.width

        Item {
            width: Theme.iconSize
            height: Theme.iconSize
            anchors.horizontalCenter: parent.horizontalCenter

            // app.icon is already an absolute filesystem path (Icons.path),
            // because Qt's Image cannot resolve freedesktop theme names.
            Image {
                id: icon
                anchors.fill: parent
                visible: tile.app.icon !== ""
                source: tile.app.icon
                asynchronous: true
                // Fade in once decoded instead of popping in mid-scroll.
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: Theme.durMove; easing.type: Easing.OutCubic }
                }
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Theme.iconSize * 2
                sourceSize.height: Theme.iconSize * 2

                Rectangle {
                    parent: icon.parent
                    anchors.fill: parent
                    visible: icon.status === Image.Error || icon.status === Image.Null
                    radius: 10
                    color: Theme.accent
                    opacity: 0.22

                    Text {
                        anchors.centerIn: parent
                        text: tile.app.name.length > 0 ? tile.app.name.charAt(0).toUpperCase() : "?"
                        color: Theme.accent
                        font.pixelSize: 20
                        font.bold: true
                    }
                }
            }
        }

        Text {
            width: parent.width - 10
            horizontalAlignment: Text.AlignHCenter
            text: tile.app.name
            color: Theme.text
            opacity: tile.selected || hover.hovered ? 1.0 : 0.88
            font.pixelSize: 12
            font.weight: tile.selected ? Font.DemiBold : Font.Normal
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
        }
    }

    TapHandler {
        id: press
        acceptedButtons: Qt.LeftButton
        onTapped: tile.triggered()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: tile.menu()
    }
}