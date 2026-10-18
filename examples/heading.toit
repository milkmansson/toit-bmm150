// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
A bare-bones compass: the angle of the field in the X-Y plane.

This only works while the board is held level, and it has no calibration for
  nearby steel or magnets. Which way the board points at 0 degrees depends on
  how the chip sits on the breakout.
*/

import i2c
import math
import bmm150 show Bmm150

SDA-PIN := 21
SCL-PIN := 20

main:
  bus := i2c.Bus
    --sda=SDA-PIN
    --scl=SCL-PIN
    --frequency=400_000

  if not (bus.test Bmm150.I2C-ADDRESS):
    print "No BMM150 found on the bus. Check the wiring and the I2C address."
    return

  sensor := Bmm150 (bus.device Bmm150.I2C-ADDRESS) --preset=Bmm150.PRESET-ENHANCED --odr=Bmm150.ODR-10HZ

  while true:
    field := sensor.read-mag-compensated
    heading := (math.atan2 field.y field.x) * 180.0 / math.PI
    if heading < 0.0: heading += 360.0
    print "Heading $(%d heading.round) degrees"
