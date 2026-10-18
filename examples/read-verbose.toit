// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import bmm150 show Bmm150
import math

READS := 10
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
  print "Taking raw data (once per loop), do $READS reads, and display the raw counts,"
  print "the compensated field in µT with its magnitude, and the Hall resistance."
  sleep --ms=1000
  READS.repeat:
    bytes := sensor.read-raw-data
    counts := sensor.read-mag-raw bytes
    field := sensor.read-mag-compensated bytes
    rhall := sensor.read-rhall bytes

    print "$("$it".pad 4 --left ' ') - raw $counts  $field [mag: $(%0.3f magnitude field)] µT  rhall $rhall"

magnitude point/math.Point3f -> float:
  return math.sqrt ( (point.x * point.x) + (point.y * point.y) + (point.z * point.z) )
