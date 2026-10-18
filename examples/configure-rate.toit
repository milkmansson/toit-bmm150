// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

// Picks a preset and an output data rate, then reads back what the chip uses.
// More repetitions per measurement lower the noise at the cost of current.

import i2c
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

  sensor := Bmm150 (bus.device Bmm150.I2C-ADDRESS)

  // The high accuracy preset averages 47 times on X and Y, and 83 times on Z.
  // It runs at 20 Hz. The explicit rate below replaces that.
  sensor.set-preset Bmm150.PRESET-HIGH-ACCURACY
  sensor.set-odr Bmm150.ODR-15HZ
  print "Asked for the high accuracy preset at 15 Hz."
  print "The chip now runs at $(Bmm150.odr-to-hz sensor.get-odr) Hz with $sensor.get-repetitions-xy repetitions on X and Y and $sensor.get-repetitions-z on Z."

  // One measurement takes this long. The rate has to leave room for it.
  time-us := Bmm150.measurement-time-us sensor.get-repetitions-xy sensor.get-repetitions-z
  print "One measurement takes about $(time-us / 1000.0) ms."

  10.repeat:
    print "$sensor.read-mag-compensated µT"
