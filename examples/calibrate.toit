// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import math
import bmm150 show Bmm150
import bmm150.calibration show MagCalibration MagCalibrator
import pixel-display show *
import pixel-display.two-color show BLACK

import .display-views

/**
  Works out a calibration for the board and prints it as a line of Toit. It
  also works out how the dial in compass-display.toit should be turned to match
  the way the chip sits on the breadboard.

  The board needs to be mounted where it will live, with its wires and battery
  in place, before this runs. During the collection time, the board needs to
  be turned slowly through every orientation, like tracing a figure of eight
  in the air. The scatter plot on the right shows the raw X and Y readings.
  Then the example shows the corrected readings for ten seconds, which shows
  whether the ring sits on the cross.

  The steps are:
  1. A short countdown, then the turning phase for the calibration.
  2. Ten seconds of corrected readings, to judge the ring.
  3. "Point N": the board is held level with the top of the display towards
     magnetic north, and kept still. A watch or phone compass finds north.
     The board stays away from steel and magnets.
  4. "Point E": the board is turned a quarter turn clockwise, as seen from
     above, so that the top of the display points east, and kept still.

  The orientation steps come after the calibration on purpose. The angle of the
  field is only meaningful once the offsets are removed.

  The two poses give the dial rotation. Pose 1 gives the angle between the
  display and the chip's X axis. Pose 2 tells whether the chip turns the way I
  assume. I assume that, with Z pointing up, a clockwise turn of the board
  raises the angle of the field by 90 degrees. If it lowers the angle, the
  result is "mirrored". Both are guesses about how breakouts are built, so
  they need to be checked against what the needle does.

  The lines it prints go into compass-display.toit.

  When it finishes, the display shows "Done" and then steps through the
  numbers, one every few seconds, to the right of that word. The letter o
  stands for an offset in microtesla and s for a scale, followed by the axis.
  That way the calibration can be read from the display when the board runs
  from a battery and no serial output is in reach. To copy it by hand, a
  line such as `MagCalibration --offset-x=12.35 --scale-x=1.020` is built,
  with the other axes added in the same way. The display rounds, so the printed line is
  slightly more exact.
*/

// How long to wait before collecting starts, in seconds, so there is time to
// pick the board up. A choice made for this example.
START-DELAY-SECONDS ::= 5

// How long each number stays on the display at the end, in seconds. A choice
// made for this example.
SHOW-SECONDS ::= 3

// How long to wait in each pose before sampling, in seconds, to leave time
// to move the board and let it settle, and how long to sample for. Both are
// choices made for this example.
POSE-SETTLE-SECONDS ::= 6
POSE-SAMPLE-SECONDS ::= 3

// The dial rotation is rounded to a multiple of this many degrees. A chip on a
// breadboard usually sits square to the edges, and a handheld pose is only
// good to some degrees, so the rounding hides the pointing error. A value of 1
// keeps the measured angle. A choice made for this example.
SNAP-DEGREES ::= 90

// A turn smaller than this many degrees between the two poses is treated as
// unclear. A choice made for this example.
MIN-TURN-DEGREES ::= 30

// How long to collect for, in seconds. A choice made for this example.
COLLECT-SECONDS ::= 40

// How long to show the corrected readings afterwards, in seconds.
CHECK-SECONDS ::= 10

// Turns the picture on the display, clockwise, by 0, 90, 180 or 270 degrees. 0
// is how the picture looked before this setting existed. This turns the screen
// only. The orientation poses at the end measure how the chip sits relative to
// the dial, which is a separate thing.
DISPLAY-ROTATION ::= 0

// Mirrors the picture top to bottom. Some display modules need it, and turning
// cannot fix a mirror image.
DISPLAY-FLIP ::= false

SCATTER-RANGE ::= 80

// Turns only the scatter plot, clockwise, by 0, 90, 180 or 270 degrees. The
// plot normally shows the chip's X axis to the right and its Y axis up, which
// may not match how the chip sits on the board. The dial and the poses are not
// affected.
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

  sensor := Bmm150 (bus.device Bmm150.I2C-ADDRESS)
      --preset=Bmm150.PRESET-ENHANCED
      --odr=Bmm150.ODR-25HZ

  // A wide picture has the plot across the top and the two text lines side by
  // side underneath. A tall picture has a square plot and the text lines one
  // under the other.
  scatter-width := portrait ? 64 : 128
  scatter-height := portrait ? 64 : 48
  readout-y := portrait ? 80 : 61
  values-x := portrait ? 0 : 56
  values-y := portrait ? 95 : 61
  scatter := ScatterView --x=0 --y=0 --width=scatter-width --height=scatter-height --range=SCATTER-RANGE --keep=100 --rotate-degrees=PLOT-ROTATION --mirror=PLOT-MIRROR
  readout := Label --x=2 --y=readout-y --text="Ready" --style=text-style
  values := Label --x=values-x --y=values-y --text="" --style=text-style
  display.add
      Div --x=0 --y=0 --w=(picture-width DISPLAY-ROTATION) --h=(picture-height DISPLAY-ROTATION) --background=BLACK [
          scatter,
          readout,
          values,
      ]

  START-DELAY-SECONDS.repeat:
    values.text = "start in $(START-DELAY-SECONDS - it)"
    display.draw
    sleep --ms=1000

  readout.text = "Turn"
  calibrator := MagCalibrator
  print "Collecting for $COLLECT-SECONDS seconds. Turn the board through every orientation."
  start := Time.monotonic-us
  last-draw := start
  while (Time.monotonic-us - start) < COLLECT-SECONDS * 1_000_000:
    field := sensor.read-mag-compensated
    calibrator.add field
    scatter.add field.x field.y
    now := Time.monotonic-us
    if now - last-draw >= 100_000:
      left := COLLECT-SECONDS - (now - start) / 1_000_000
      values.text = "$(%d left)s $(%d (calibrator.progress * 100).round)%"
      display.draw
      last-draw = now

  print "Spans: X $(%.1f calibrator.span-x) uT, Y $(%.1f calibrator.span-y) uT, Z $(%.1f calibrator.span-z) uT"
  if not calibrator.is-ready:
    print "Not every axis covered enough range. Turn the board further and run it again."
    readout.text = "Failed"
    values.text = "turn more"
    display.draw
    return

  calibration := calibrator.calibration
  print "Calibration: $calibration"
  print "Paste this into compass-display.toit:"
  print "CALIBRATION ::= $calibration.to-source"

  scatter.clear
  readout.text = "Check"
  values.text = ""
  end := Time.monotonic-us + CHECK-SECONDS * 1_000_000
  while Time.monotonic-us < end:
    field := calibration.apply sensor.read-mag-compensated
    scatter.add field.x field.y
    now := Time.monotonic-us
    if now - last-draw >= 100_000:
      display.draw
      last-draw = now
  north-angle := pose-angle sensor calibration scatter display readout values "Point N"
  east-angle := pose-angle sensor calibration scatter display readout values "Point E"
  turn := east-angle - north-angle
  while turn > 180.0: turn -= 360.0
  while turn <= -180.0: turn += 360.0
  print "Turn between the poses: $(%.1f turn) degrees. About +90 is expected, if the chip is not mirrored."
  if turn.abs < MIN-TURN-DEGREES:
    print "The turn was small, so the mirror result is unreliable. Run it again."
  mirrored := turn < 0.0
  // A mirrored chip reverses the sense of the angle.
  reference := mirrored ? -north-angle : north-angle
  rotate := ((reference / SNAP-DEGREES).round * SNAP-DEGREES)
  rotate = ((rotate % 360) + 360) % 360
  print "Measured angle in pose 1: $(%.1f north-angle) degrees. Rounded to $SNAP-DEGREES: $rotate"
  print "Paste these into compass-display.toit:"
  print "ROTATE-DEGREES ::= $rotate"
  print "MIRROR ::= $mirrored"

  readout.text = "Done"
  entries := [
    "rot $rotate",
    "mirror $(mirrored ? "yes" : "no")",
    "oX $(offset-text calibration.offset-x)",
    "oY $(offset-text calibration.offset-y)",
    "oZ $(offset-text calibration.offset-z)",
    "sX $(%.3f calibration.scale-x)",
    "sY $(%.3f calibration.scale-y)",
    "sZ $(%.3f calibration.scale-z)",
  ]
  shown := entries.size - 1
  last-change := 0
  while true:
    field := calibration.apply sensor.read-mag-compensated
    scatter.add field.x field.y
    now := Time.monotonic-us
    if now - last-change >= SHOW-SECONDS * 1_000_000:
      shown = (shown + 1) % entries.size
      values.text = entries[shown]
      last-change = now
    if now - last-draw >= 100_000:
      display.draw
      last-draw = now

/**
Returns the $offset as text with two decimals, or one decimal from 100 up.

The one decimal keeps a long number inside the width of a tall picture.
*/
offset-text offset/float -> string:
  if offset.abs >= 100.0: return "$(%.1f offset)"
  return "$(%.2f offset)"

/**
Holds a pose for the user, then returns the angle of the corrected field.

Counts down for $POSE-SETTLE-SECONDS with the $prompt and the countdown on
  the display, then
  averages the corrected X and Y for $POSE-SAMPLE-SECONDS. The angle is in
  degrees, from the chip's X axis towards its Y axis.
*/
pose-angle -> float
    sensor/Bmm150
    calibration/MagCalibration
    scatter/ScatterView
    display/PixelDisplay
    readout/Label
    values/Label
    prompt/string:
  readout.text = prompt
  start := Time.monotonic-us
  settle-end := start + POSE-SETTLE-SECONDS * 1_000_000
  sample-end := settle-end + POSE-SAMPLE-SECONDS * 1_000_000
  last-draw := start
  sum-x := 0.0
  sum-y := 0.0
  while true:
    now := Time.monotonic-us
    if now >= sample-end: break
    field := calibration.apply sensor.read-mag-compensated
    scatter.add field.x field.y
    if now >= settle-end:
      sum-x += field.x
      sum-y += field.y
      values.text = "hold"
    else:
      values.text = "$(1 + (settle-end - now) / 1_000_000)"
    if now - last-draw >= 100_000:
      display.draw
      last-draw = now
  return (math.atan2 sum-y sum-x) * 180.0 / math.PI
