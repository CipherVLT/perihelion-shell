import QtQuick

// Smooth mouse-wheel scrolling for a Flickable (the drawer's grids).
//
// A Flickable moves a fixed step per wheel notch and repaints the jump in
// one frame, which is what made the drawer feel choppy. This handler takes
// over notched mouse wheels only: each notch extends a destination and one
// eased animation glides contentY there, so fast spins accumulate into one
// smooth glide instead of a stutter of restarts. Touchpads keep Qt's own
// pixel-precise kinetic scrolling, which is already smooth.
//
// Cost: one NumberAnimation per view, idle unless the wheel turns.
WheelHandler {
    id: wheel

    required property Flickable flick
    // Pixels per notch: about one row of tiles.
    property real step: 96

    target: null
    acceptedDevices: PointerDevice.Mouse

    property real dest: 0

    function maxY() {
        return flick.originY + Math.max(0, flick.contentHeight - flick.height)
    }

    onWheel: (event) => {
        const notches = event.angleDelta.y / 120
        if (notches === 0)
            return
        if (!glide.running)
            dest = flick.contentY
        dest = Math.max(flick.originY, Math.min(maxY(), dest - notches * step))
        glide.to = dest
        glide.restart()
    }

    property NumberAnimation glide: NumberAnimation {
        target: wheel.flick
        property: "contentY"
        duration: Theme.durScroll
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Theme.curveOut
    }
}
