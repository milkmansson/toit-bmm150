// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c

sda-pin-number := 21
scl-pin-number := 20

main:
  bus := i2c.Bus
      --sda=sda-pin-number // (gpio.Pin sda-pin-number)
      --scl=scl-pin-number // (gpio.Pin scl-pin-number)
      --frequency=400_000
  print "Devices found:"
  bus.scan.do: print " Device found on 0x$(%02x it)"
