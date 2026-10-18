// Copyright (C) 2026 Toit Contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

// A compass dial and an X-Y scatter plot on a 128x64 SSD1306 display.
//
// The sensor and the display share one I2C bus.
//
// Hold the board flat and turn it. The needle should keep pointing the same
// way in the room while the board turns under it, and the dots on the right
// should trace a ring.
//
// Run calibrate.toit first to get numbers for CALIBRATION. Without them, the
// needle will be off by an amount that depends on the board.

import math
import bmm150 show Bmm150
import bmm150.calibration show MagCalibration
import pixel-display show *
import pixel-display.two-color show BLACK

import .display-views

// Paste the line that calibrate.toit prints here.
//CALIBRATION ::= MagCalibration.NONE
CALIBRATION ::= MagCalibration --offset-x=-103.442 --offset-y=31.554 --offset-z=-177.869 --scale-x=1.0779 --scale-y=1.0861 --scale-z=0.8684

// Whether the chip turns the opposite way to what the dial assumes. Run
// calibrate.toit to find out, or leave it false and try it.
// MIRROR ::= false
MIRROR ::= true

// Turns the dial clockwise by this many degrees, to match how the chip sits on
// your breakout. Try 90, 180 or 270 if the needle moves the wrong way.
// ROTATE-DEGREES ::= 270
ROTATE-DEGREES ::= 180

// Turns the picture on the display, clockwise, by 0, 90, 180 or 270 degrees. 0
// is how the picture looked before this setting existed. This turns the screen
// only. ROTATE-DEGREES above matches the dial to the chip.
DISPLAY-ROTATION ::= 0

// Mirrors the picture top to bottom. Some display modules need it, and turning
// cannot fix a mirror image.
DISPLAY-FLIP ::= false

// The edge of the scatter plot, in microtesla from zero. A choice made for this
// example, wide enough to hold the Earth's field plus a modest offset.
SCATTER-RANGE ::= 80

// Turns only the scatter plot, clockwise, by 0, 90, 180 or 270 degrees. The
// plot normally shows the chip's X axis to the right and its Y axis up. The
// dial is not affected.
PLOT-ROTATION ::= 90

// Reverses the plot's Y axis, before the turn above.
PLOT-MIRROR ::= true

main:
  bus := open-bus
  if not (bus.test Bmm150.I2C-ADDRESS):
    print "No BMM150 found on the bus. Check the wiring and the I2C address."
    return
  display := open-display bus --rotation=DISPLAY-ROTATION --flip=DISPLAY-FLIP
  portrait := is-portrait DISPLAY-ROTATION

  sensor := Bmm150 (bus.device Bmm150.I2C-ADDRESS) --calibration=CALIBRATION
      --preset=Bmm150.PRESET-ENHANCED
      --odr=Bmm150.ODR-25HZ

  // A wide picture puts the scatter plot beside the dial. A tall one puts it
  // underneath.
  scatter-x := portrait ? 0 : 64
  scatter-y := portrait ? 64 : 0
  readout-x := portrait ? 2 : 66
  readout-y := portrait ? 125 : 61
  compass := CompassView --x=0 --y=0 --size=64
  scatter := ScatterView --x=scatter-x --y=scatter-y --width=64 --height=48 --range=SCATTER-RANGE --rotate-degrees=PLOT-ROTATION --mirror=PLOT-MIRROR
  readout := Label --x=readout-x --y=readout-y --text="" --style=text-style
  display.add
      Div --x=0 --y=0 --w=(picture-width DISPLAY-ROTATION) --h=(picture-height DISPLAY-ROTATION) --background=BLACK [
          compass,
          scatter,
          readout,
      ]

  last-draw := Time.monotonic-us
  last-print := last-draw
  while true:
    field := sensor.read-mag-compensated
    // A mirrored chip reverses the sense of the Y axis for the compass.
    compass-y := MIRROR ? -field.y : field.y
    compass.update field.x compass-y --rotate-degrees=ROTATE-DEGREES
    scatter.add field.x field.y

    // The heading follows the dial, so it includes ROTATE-DEGREES.
    heading := (math.atan2 compass-y field.x) * 180.0 / math.PI - ROTATE-DEGREES
    while heading < 0.0: heading += 360.0
    while heading >= 360.0: heading -= 360.0
    strength := math.sqrt (field.x * field.x + field.y * field.y + field.z * field.z)

    now := Time.monotonic-us
    if now - last-draw >= 100_000:
      readout.text = "$(%3d heading.round) $(%3d strength.round)uT"
      display.draw
      last-draw = now
    if now - last-print >= 1_000_000:
      print "Heading $(%d heading.round) degrees, strength $(%.1f strength) uT"
      last-print = now
