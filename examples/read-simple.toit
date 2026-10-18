// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import bmm150 show Bmm150

READS := 100
SDA-PIN := 21
SCL-PIN := 20

main:
  print
  print
  bus := i2c.Bus
    --sda=SDA-PIN
    --scl=SCL-PIN
    --frequency=400_000

  if not (bus.test Bmm150.I2C-ADDRESS):
    print "No BMM150 found on the bus. Check the wiring and the I2C address."
    return

  device := bus.device Bmm150.I2C-ADDRESS
  sensor := Bmm150 device
  print "Hardware ID: 0x$(%02x sensor.get-chip-id)"
  print "Executing $READS (compensated) reads...."
  sleep --ms=1000
  READS.repeat:
    print "$("$it".pad 5 --left ' ')  -  $(sensor.read-mag-compensated) "
