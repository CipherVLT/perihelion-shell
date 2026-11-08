import QtQuick
import Quickshell

// One wallpaper in the picker grid: a thumbnail of the image itself with its
// filename underneath.
//
// The thumbnail is the image loaded straight off disk rather than an icon
// lookup -- recognising a wallpaper by its filename alone is guesswork, and
// these files are 4K originals that may not even have thumbnails cached.
Rectangle {
    id: root

    // Wallpaper record: { path, name }
    required property var wp
    property bool active: false

    signal picked(string path)

    width: 156
    height: 132
    radius: 12
    color: hover.hovered ? Theme.hoverSoft : "transparent"
    scale: tapScale.pressed ? 0.96 : 1.0
    Behavior on scale {
        NumberAnimation {
            duration: tapScale.pressed ? Theme.durPress : Theme.durMove
            easing.type: tapScale.pressed ? Easing.OutCubic : Easing.OutBack
        }
    }
    Behavior on color {
        ColorAnimation { duration: Theme.durHover }
    }
    border.width: active ? 2 : 1
    // The active wallpaper gets the accent colour so "which one is showing" is
    // answerable at a glance rather than by comparing thumbnails.
    border.color: active ? Theme.accent : Theme.separator
    Behavior on border.color {
        ColorAnimation { duration: 90 }
    }

    // 16:10 preview area, matching how most of these are actually used
    // (swaybg -m fill on a 16:9 screen). A Rectangle, not an Item: rounding the
    // clipped thumbnail needs `radius`, which only Rectangle has.
    Rectangle {
        id: shot
        anchors.top: parent.top
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.right: parent.right
        anchors.rightMargin: 6
        height: 86
        clip: true
        radius: 6
        color: Theme.window

        Image {
            id: thumb
            anchors.fill: parent
            // encodeURI, not raw concatenation: every one of these filenames has
            // spaces in it, and a file:// URL with a bare space is rejected
            // rather than decoded, which shows as an empty tile.
            source: "file://" + encodeURI(root.wp.path)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // Decode at tile size (2x for HiDPI), not the 4K original: a full
            // decode is ~40 MB per tile and the stall that made scrolling
            // choppy. Crop mode needs both dimensions set.
            sourceSize.width: 288
            sourceSize.height: 172
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: Theme.durMove; easing.type: Easing.OutCubic }
            }
            // Deliberately no cache: switching tabs should not re-decode 4K
            // JPEGs, and these fill far more cache than they are worth.
            cache: false
            smooth: true
            mipmap: false
        }

        // Formats Qt cannot decode (a .jxl, say) leave the tile blank with no
        // explanation. Say so rather than showing an empty rounded box.
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: "#000000"
            opacity: 0.45
            visible: thumb.status === Image.Error

            Text {
                anchors.centerIn: parent
                text: "Can't preview"
                color: Theme.text
                font.pixelSize: 11
            }
        }
    }

    Text {
        anchors.top: shot.bottom
        anchors.topMargin: 5
        anchors.left: parent.left
        anchors.leftMargin: 9
        anchors.right: parent.right
        anchors.rightMargin: 9
        text: root.wp.name
        color: root.active ? Theme.accent : Theme.text
        font.pixelSize: 11
        elide: Text.ElideMiddle
        horizontalAlignment: Text.AlignHCenter
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler {
        id: tapScale
        onTapped: root.picked(root.wp.path)
    }
}