// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import bmm150 show Bmm150

/**
Takes one reading a second in forced mode. Between readings the chip sits in
  sleep mode, which suits battery projects that only need an occasional
  reading. Suspend mode would use even less current, but the chip loses its
  settings there and needs 3 ms to wake.
*/

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

  10.repeat:
    // The chip runs forced measurements from sleep mode. The driver puts it
    // there first if it is still in normal mode.
    sensor.set-mode Bmm150.MODE-FORCED
    // The call waits for the measurement and returns the bytes.
    print "$sensor.read-mag-compensated µT"
    sleep --ms=1000
