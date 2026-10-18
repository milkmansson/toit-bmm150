// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import math show Point3f

/**
Calibration for a magnetometer that sits on a particular board.

The chip's own trim values, which the driver applies in
  `read-mag-compensated`, fix errors inside the chip. They cannot fix
  what the rest of the board does to the field. A magnet, a steel screw or a
  current-carrying wire near the sensor adds to the field it measures, and
  that error moves with the board.

This class holds two corrections:
- An offset per axis, in microtesla, subtracted from every reading. It
  removes a steady field that turns with the board, usually called hard-iron
  error.
- A scale per axis, multiplied in after the offset. It evens out the
  difference in sensitivity between the axes, which is a simplified form of
  soft-iron correction. It does not handle a tilted ellipsoid.

The two corrections come from the min/max method, which is a common technique
  and not something from the datasheet or from Bosch. See $MagCalibrator.

A calibration reaches the driver through the `--calibration` argument of the
  constructor, or later through `sensor.calibration = ...`. The driver applies
  it in `read-mag-compensated`.

The calibration belongs to the whole assembly, not to the chip alone. Moving
  the sensor, changing the battery or adding a wire can change it. A
  second board built the same way will probably need its own.
*/
class MagCalibration:
  /** The offset to subtract from X, in microtesla. */
  offset-x/float
  /** The offset to subtract from Y, in microtesla. */
  offset-y/float
  /** The offset to subtract from Z, in microtesla. */
  offset-z/float
  /** The factor applied to X after the offset. */
  scale-x/float
  /** The factor applied to Y after the offset. */
  scale-y/float
  /** The factor applied to Z after the offset. */
  scale-z/float

  /** A calibration that changes nothing. */
  static NONE ::= MagCalibration

  constructor
      --.offset-x/float=0.0
      --.offset-y/float=0.0
      --.offset-z/float=0.0
      --.scale-x/float=1.0
      --.scale-y/float=1.0
      --.scale-z/float=1.0:

  /**
  Builds a calibration from a map made by $to-map.

  Missing keys fall back to no correction, so a map can hold only the offsets.
  */
  constructor.from-map map/Map:
    offset-x = (map.get "offset-x" --if-absent=: 0.0).to-float
    offset-y = (map.get "offset-y" --if-absent=: 0.0).to-float
    offset-z = (map.get "offset-z" --if-absent=: 0.0).to-float
    scale-x = (map.get "scale-x" --if-absent=: 1.0).to-float
    scale-y = (map.get "scale-y" --if-absent=: 1.0).to-float
    scale-z = (map.get "scale-z" --if-absent=: 1.0).to-float

  /**
  Returns the corrected field for the given $x, $y and $z, in microtesla.
  */
  apply x/num y/num z/num -> Point3f:
    return Point3f
        (x - offset-x) * scale-x
        (y - offset-y) * scale-y
        (z - offset-z) * scale-z

  /** Returns the corrected version of the $field. */
  apply field/Point3f -> Point3f:
    return apply field.x field.y field.z

  /**
  Returns this calibration as a map of numbers.

  The map works with JSON, with the SDK's storage buckets, and with
    $MagCalibration.from-map.
  */
  to-map -> Map:
    return {
      "offset-x": offset-x,
      "offset-y": offset-y,
      "offset-z": offset-z,
      "scale-x": scale-x,
      "scale-y": scale-y,
      "scale-z": scale-z,
    }

  /**
  Returns Toit source that rebuilds this calibration.

  Printing it once after calibrating gives a line to paste into the application
  code.
  */
  to-source -> string:
    return "MagCalibration"
        + " --offset-x=$(%.3f offset-x) --offset-y=$(%.3f offset-y)"
        + " --offset-z=$(%.3f offset-z)"
        + " --scale-x=$(%.4f scale-x) --scale-y=$(%.4f scale-y)"
        + " --scale-z=$(%.4f scale-z)"

  stringify -> string:
    return "offset ($(%.2f offset-x), $(%.2f offset-y), $(%.2f offset-z)) uT, scale ($(%.3f scale-x), $(%.3f scale-y), $(%.3f scale-z))"

/**
Collects readings while the board is turned, and works out a $MagCalibration.

Readings go in through $add while the board rotates through every
  orientation. It remembers the smallest and largest value on each axis. For
  each axis, half the sum of the two is the offset. The scale makes the three
  half-ranges equal, using their average as the target.

This method assumes that the Earth's field is the only thing the board should
  see, and that the readings trace a sphere. Heavy distortion makes the result
  less accurate. A fitted ellipsoid would do better, and this class does not
  do that.
*/
class MagCalibrator:
  min-x_/float := 0.0
  max-x_/float := 0.0
  min-y_/float := 0.0
  max-y_/float := 0.0
  min-z_/float := 0.0
  max-z_/float := 0.0
  count_/int := 0

  /** The number of readings added so far. */
  count -> int: return count_

  /** Adds a reading, in microtesla. */
  add x/num y/num z/num -> none:
    if count_ == 0:
      min-x_ = max-x_ = x.to-float
      min-y_ = max-y_ = y.to-float
      min-z_ = max-z_ = z.to-float
    else:
      min-x_ = min min-x_ x.to-float
      max-x_ = max max-x_ x.to-float
      min-y_ = min min-y_ y.to-float
      max-y_ = max max-y_ y.to-float
      min-z_ = min min-z_ z.to-float
      max-z_ = max max-z_ z.to-float
    count_++

  /** Adds the $field as one reading. */
  add field/Point3f -> none:
    add field.x field.y field.z

  /** The range covered on X, in microtesla. Zero before any reading. */
  span-x -> float: return max-x_ - min-x_
  /** The range covered on Y, in microtesla. Zero before any reading. */
  span-y -> float: return max-y_ - min-y_
  /** The range covered on Z, in microtesla. Zero before any reading. */
  span-z -> float: return max-z_ - min-z_

  /**
  Returns how far the smallest axis range reaches, from 0.0 to 1.0.

  The result is the smallest span divided by the target span of a full sphere
    of $field-strength microtesla, which is twice that value. It is a rough
    guide to how much of a full turn the board has covered. It reaches 1.0 once
    every axis has seen the field at both ends.

  The $field-strength is a guess that can be changed. The default of 50 µT
    is my assumption for the order of magnitude of the Earth's field, and
    it is not taken from the datasheet. The strength expected at the
    location is the value to use.
  */
  progress --field-strength/num=50.0 -> float:
    smallest := min span-x (min span-y span-z)
    return min 1.0 (smallest / (2.0 * field-strength))

  /**
  Whether every axis has covered at least $min-span microtesla.

  The default of 40 µT is a choice made for this class, aimed at a field of
    about 50 µT. A different value suits a stronger or weaker field.
  */
  is-ready --min-span/num=40.0 -> bool:
    if count_ < 2: return false
    return span-x >= min-span and span-y >= min-span and span-z >= min-span

  /**
  Returns the calibration for the readings added so far.

  Throws if an axis has no range at all, because there is nothing to
    calibrate from. $is-ready checks first that there is enough data.
  */
  calibration -> MagCalibration:
    if count_ < 2 or span-x <= 0.0 or span-y <= 0.0 or span-z <= 0.0:
      throw "Not enough variation on every axis to calibrate"
    half-x := span-x / 2.0
    half-y := span-y / 2.0
    half-z := span-z / 2.0
    average := (half-x + half-y + half-z) / 3.0
    return MagCalibration
        --offset-x=(max-x_ + min-x_) / 2.0
        --offset-y=(max-y_ + min-y_) / 2.0
        --offset-z=(max-z_ + min-z_) / 2.0
        --scale-x=average / half-x
        --scale-y=average / half-y
        --scale-z=average / half-z

  /** Forgets all readings. */
  reset -> none:
    min-x_ = 0.0
    max-x_ = 0.0
    min-y_ = 0.0
    max-y_ = 0.0
    min-z_ = 0.0
    max-z_ = 0.0
    count_ = 0
