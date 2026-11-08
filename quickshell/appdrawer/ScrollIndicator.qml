import QtQuick

// A thin GNOME-style scroll indicator: shows while the view moves or is
// hovered, then fades out. Plain Rectangles, no QtQuick.Controls.
Item {
    id: ind

    required property Flickable flick
    property bool hovered: false

    readonly property bool needed: flick.contentHeight > flick.height + 1
    readonly property bool active: flick.moving || hovered || hideDelay.running

    anchors.top: flick.top
    anchors.bottom: flick.bottom
    anchors.right: flick.right
    anchors.topMargin: 4
    anchors.bottomMargin: 4
    width: 6
    visible: needed && opacity > 0.01
    opacity: active ? 1 : 0
    Behavior on opacity {
        NumberAnimation { duration: Theme.durHover * 2; easing.type: Easing.OutCubic }
    }

    // Lingers briefly after a glide ends, so a wheel scroll shows it too.
    Timer { id: hideDelay; interval: 700 }
    Connections {
        target: ind.flick
        function onContentYChanged() { hideDelay.restart() }
    }

    Rectangle {
        readonly property real ratio: ind.flick.height / Math.max(1, ind.flick.contentHeight)
        readonly property real travel: ind.height - height
        width: 4
        anchors.right: parent.right
        radius: 2
        height: Math.max(28, ind.height * ratio)
        y: travel * Math.max(0, Math.min(1, (ind.flick.contentY - ind.flick.originY)
                                         / Math.max(1, ind.flick.contentHeight - ind.flick.height)))
        color: Theme.alpha(Theme.text, 0.35)
    }
}
