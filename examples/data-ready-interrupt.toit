// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import bmm150 show Bmm150

/**
Reads the BMM150 each time its DRDY pin reports a new measurement.

The chip's DRDY pin needs to be wired to the ESP32 pin named in $DRDY-PIN. The
  program turns on the data ready signal, then waits for the pin to go high instead of asking
  the chip over I2C whether a sample is ready. That leaves the processor free
  between samples.

The DRDY pin is active high and not latched: it goes high when a measurement
  is stored and low again when the data registers are read. The program reads
  them without waiting for the flag, because the pin has already said that the
  data is there.
*/

SDA-PIN ::= 21
SCL-PIN ::= 20
DRDY-PIN ::= 7

// Choices made for this example. A slow rate keeps the output readable.
RATE ::= Bmm150.ODR-10HZ
READINGS ::= 50
TIMEOUT ::= Duration --s=2

main:
  bus := i2c.Bus
    --sda=SDA-PIN
    --scl=SCL-PIN
    --frequency=400_000

  if not (bus.test Bmm150.I2C-ADDRESS):
    print "No BMM150 found on the bus. Check the wiring and the I2C address."
    return

  sensor := Bmm150 (bus.device Bmm150.I2C-ADDRESS) --odr=RATE

  // Report data ready on the DRDY pin.
  sensor.set-drdy-pin-polarity true
  sensor.set-drdy-pin true

  // The pull-down keeps the input low if the wire comes loose.
  drdy := gpio.Pin.in DRDY-PIN --pull-down

  count := 0
  first-us := 0
  last-us := 0
  while count < READINGS:
    timed-out := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      with-timeout TIMEOUT: drdy.wait-for 1
    if timed-out:
      print "No signal for $TIMEOUT. Check that DRDY is wired to GPIO $DRDY-PIN."
      break
    // The pin is high, so the sample is ready. Reading it clears the pin.
    bytes := sensor.read-raw-data --no-wait
    last-us = Time.monotonic-us
    if count == 0: first-us = last-us
    count++
    print "$(sensor.read-mag-compensated bytes) µT"

  if count > 1:
    seconds := (last-us - first-us) / 1_000_000.0
    rate := (count - 1) / seconds
    print "$count readings, about $(%.1f rate) Hz. Asked for $(%.1f Bmm150.odr-to-hz RATE) Hz."

  sensor.set-drdy-pin false
  drdy.close
