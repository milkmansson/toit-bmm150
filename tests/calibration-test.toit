// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import math
import bmm150.calibration show MagCalibration MagCalibrator
import .test-helpers

// The test builds readings from a known sphere or ellipsoid, then checks that
// the calibrator finds the offsets and scales that were put in. The numbers
// are made up for this test.

FIELD ::= 50.0
OFFSET-X ::= 12.0
OFFSET-Y ::= -30.0
OFFSET-Z ::= 7.5
SENS-X ::= 1.0
SENS-Y ::= 0.8
SENS-Z ::= 1.25

/**
Calls the $block with points spread over a unit sphere, evenly enough that
  the extremes on each axis are close to the poles. The six axis directions
  are included exactly, so the extremes are exact.
*/
unit-points [block] -> none:
  block.call 1.0 0.0 0.0
  block.call -1.0 0.0 0.0
  block.call 0.0 1.0 0.0
  block.call 0.0 -1.0 0.0
  block.call 0.0 0.0 1.0
  block.call 0.0 0.0 -1.0
  count := 200
  golden := math.PI * (3.0 - (math.sqrt 5.0))
  count.repeat:
    z := 1.0 - 2.0 * (it + 0.5) / count
    r := math.sqrt (1.0 - z * z)
    angle := golden * it
    block.call (r * (math.cos angle)) (r * (math.sin angle)) z

radius x/num y/num z/num -> float:
  return math.sqrt (x * x + y * y + z * z)

main:
  run := TestRun

  run.section "Hard-iron offset"
  run.check "offset is recovered from a shifted sphere": 
    calibrator := MagCalibrator
    unit-points: | ux uy uz |
      calibrator.add
          OFFSET-X + FIELD * ux
          OFFSET-Y + FIELD * uy
          OFFSET-Z + FIELD * uz
    calibration := calibrator.calibration
    require-close OFFSET-X calibration.offset-x 0.001 "offset-x"
    require-close OFFSET-Y calibration.offset-y 0.001 "offset-y"
    require-close OFFSET-Z calibration.offset-z 0.001 "offset-z"
    require-close 1.0 calibration.scale-x 0.001 "scale-x"
    require-close 1.0 calibration.scale-y 0.001 "scale-y"
    require-close 1.0 calibration.scale-z 0.001 "scale-z"

  run.check "corrected readings are centred on zero":
    calibrator := MagCalibrator
    readings := []
    unit-points: | ux uy uz |
      x := OFFSET-X + FIELD * ux
      y := OFFSET-Y + FIELD * uy
      z := OFFSET-Z + FIELD * uz
      readings.add [x, y, z]
      calibrator.add x y z
    calibration := calibrator.calibration
    sum-x := 0.0
    sum-y := 0.0
    sum-z := 0.0
    readings.do:
      corrected := calibration.apply it[0] it[1] it[2]
      sum-x += corrected.x
      sum-y += corrected.y
      sum-z += corrected.z
    // The points are spread evenly, so the mean of the corrected readings
    // should sit near zero. The tolerance is a choice made for this test.
    require-close 0.0 sum-x / readings.size 0.5 "mean x"
    require-close 0.0 sum-y / readings.size 0.5 "mean y"
    require-close 0.0 sum-z / readings.size 0.5 "mean z"

  run.section "Axis scale"
  run.check "different sensitivities are evened out":
    calibrator := MagCalibrator
    unit-points: | ux uy uz |
      calibrator.add
          OFFSET-X + SENS-X * FIELD * ux
          OFFSET-Y + SENS-Y * FIELD * uy
          OFFSET-Z + SENS-Z * FIELD * uz
    calibration := calibrator.calibration
    average := (SENS-X + SENS-Y + SENS-Z) / 3.0
    require-close OFFSET-X calibration.offset-x 0.001 "offset-x"
    require-close OFFSET-Y calibration.offset-y 0.001 "offset-y"
    require-close OFFSET-Z calibration.offset-z 0.001 "offset-z"
    require-close (average / SENS-X) calibration.scale-x 0.001 "scale-x"
    require-close (average / SENS-Y) calibration.scale-y 0.001 "scale-y"
    require-close (average / SENS-Z) calibration.scale-z 0.001 "scale-z"

  run.check "corrected readings sit on one sphere":
    calibrator := MagCalibrator
    readings := []
    unit-points: | ux uy uz |
      x := OFFSET-X + SENS-X * FIELD * ux
      y := OFFSET-Y + SENS-Y * FIELD * uy
      z := OFFSET-Z + SENS-Z * FIELD * uz
      readings.add [x, y, z]
      calibrator.add x y z
    calibration := calibrator.calibration
    average := (SENS-X + SENS-Y + SENS-Z) / 3.0
    readings.do:
      corrected := calibration.apply it[0] it[1] it[2]
      require-close (average * FIELD) (radius corrected.x corrected.y corrected.z) 0.001 "radius"

  run.section "MagCalibrator state"
  run.check "no data throws":
    require-throw "Not enough variation on every axis to calibrate": (MagCalibrator).calibration

  run.check "one flat axis throws":
    calibrator := MagCalibrator
    calibrator.add 10.0 5.0 3.0
    calibrator.add -10.0 -5.0 3.0
    require-throw "Not enough variation on every axis to calibrate": calibrator.calibration

  run.check "is-ready follows the span":
    calibrator := MagCalibrator
    require-not calibrator.is-ready
    calibrator.add 0 0 0
    calibrator.add 30 30 30
    require-not calibrator.is-ready
    require-not (calibrator.is-ready --min-span=31)
    require (calibrator.is-ready --min-span=30)
    calibrator.add -20 0 0
    require-not (calibrator.is-ready --min-span=40)
    require-equals 3 calibrator.count

  run.check "progress runs from zero to one":
    calibrator := MagCalibrator
    require-close 0.0 calibrator.progress 0.0001 "empty"
    calibrator.add 0 0 0
    calibrator.add 25 50 100
    // The smallest span is 25. A 50 uT field wants a span of 100.
    require-close 0.25 calibrator.progress 0.0001 "quarter"
    calibrator.add 100 100 100
    require-close 1.0 calibrator.progress 0.0001 "full"

  run.check "reset clears everything":
    calibrator := MagCalibrator
    calibrator.add 1 2 3
    calibrator.add 4 5 6
    calibrator.reset
    require-equals 0 calibrator.count
    require-close 0.0 calibrator.span-x 0.0001 "span-x"

  run.check "first reading sets both ends of the range":
    // A start value of zero would hide a reading that is always positive.
    calibrator := MagCalibrator
    calibrator.add 40.0 50.0 60.0
    calibrator.add 42.0 54.0 66.0
    require-close 2.0 calibrator.span-x 0.0001 "span-x"
    require-close 4.0 calibrator.span-y 0.0001 "span-y"
    require-close 6.0 calibrator.span-z 0.0001 "span-z"

  run.section "MagCalibration"
  run.check "NONE changes nothing":
    point := MagCalibration.NONE.apply 1.5 -2.5 3.5
    require-close 1.5 point.x 0.0001 "x"
    require-close -2.5 point.y 0.0001 "y"
    require-close 3.5 point.z 0.0001 "z"

  run.check "apply subtracts the offset before scaling":
    calibration := MagCalibration
        --offset-x=10.0
        --offset-y=20.0
        --offset-z=30.0
        --scale-x=2.0
        --scale-y=3.0
        --scale-z=4.0
    point := calibration.apply 11.0 22.0 33.0
    require-close 2.0 point.x 0.0001 "x"
    require-close 6.0 point.y 0.0001 "y"
    require-close 12.0 point.z 0.0001 "z"

  run.check "map round trip":
    calibration := MagCalibration
        --offset-x=1.25
        --offset-y=-2.5
        --offset-z=3.75
        --scale-x=1.1
        --scale-y=0.9
        --scale-z=1.0
    copy := MagCalibration.from-map calibration.to-map
    // Maps compare by identity in Toit, so check each key.
    calibration.to-map.do: | key value |
      require-equals value copy.to-map[key]

  run.check "a partial map keeps the defaults":
    calibration := MagCalibration.from-map {"offset-x": 4}
    require-close 4.0 calibration.offset-x 0.0001 "offset-x"
    require-close 1.0 calibration.scale-z 0.0001 "scale-z"

  run.check "to-source names every field":
    text := (MagCalibration --offset-x=1.0 --scale-y=0.5).to-source
    [
      "MagCalibration", "--offset-x=1.000", "--offset-y=0.000",
      "--offset-z=0.000", "--scale-x=1.0000", "--scale-y=0.5000",
      "--scale-z=1.0000",
    ].do: require (text.contains it) --message="Missing $it in $text"

  run.finish
