// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import spi
import bmm150 show Bmm150

/**
Reads the BMM150 over 4-wire SPI.

The chip's PS pin needs to be tied to GND, which selects SPI. CSB goes to
  $CS-PIN, SCK to $CLOCK-PIN, SDI to $MOSI-PIN and SDO to $MISO-PIN. See the
  wiring and SPI sections of the README for the pin roles and the drawbacks.

Apart from the bus, the driver is used exactly as over I2C.
*/

READS ::= 100

// Choices made for this example. The SDK's SPI bus accepts any free GPIOs, so
// they can be changed to match the board.
CLOCK-PIN ::= 6
MOSI-PIN ::= 18
MISO-PIN ::= 19
CS-PIN ::= 22

// The datasheet gives 10 MHz as the highest clock (table 29). The lower value
// is a cautious choice for this example, for loose jumper wires.
FREQUENCY ::= 1_000_000

main:
  print
  print
  bus := spi.Bus
      --clock=gpio.Pin CLOCK-PIN
      --mosi=gpio.Pin MOSI-PIN
      --miso=gpio.Pin MISO-PIN
  // The datasheet says the chip works in SPI modes 0 and 3 ("00" and "11").
  device := bus.device
      --cs=gpio.Pin CS-PIN
      --frequency=FREQUENCY
      --mode=0

  sensor/Bmm150? := null
  error := catch: sensor = Bmm150 device
  if error:
    print "No BMM150 answered over SPI: $error"
    print "The wiring, the PS pin (GND for SPI) and the pin numbers above"
    print "are the first things to look at."
    bus.close
    return

  print "Hardware ID: 0x$(%02x sensor.get-chip-id)"
  print "Executing $READS (compensated) reads...."
  sleep --ms=1000
  READS.repeat:
    print "$("$it".pad 5 --left ' ')  -  $(sensor.read-mag-compensated) "
