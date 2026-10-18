// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Self-checking tests for a BMM150 wired to an ESP32. Needs real hardware.

Wire the module's SDA, SCL, power and ground to the ESP32, edit the pin numbers
  below if yours differ, and run with Jaguar. To test the DRDY and INT pins too,
  wire them to the pins named by $DRDY-PIN and $INT-PIN. Leave a pin at null if
  it is not wired:
```
jag run -d <your device> tests/bmm150-hardware-test.toit
```

Keep the board still and a few centimeters away from motors, magnets, speakers
  and steel tables while it runs. Every check prints PASS, FAIL, WARN or SKIP.
  A FAIL means something is wrong with the driver, the wiring or the chip. A
  WARN means a value is odd but not wrong, usually because of the surroundings.

The thresholds come from two places. Limits taken from the datasheet say so in
  their comments. The others are choices made for this test, and they are
  marked as such. Change them at the top of the file if your setup needs it.

Set $ROTATE-TEST to true to add a hands-on check. It asks you to turn the board
  through all orientations and checks that the field strength stays constant.
*/

import gpio
import i2c
import log
import math show sqrt
import bmm150 show *
import bmm150.calibration show MagCalibrator
import .test-helpers

SDA-PIN ::= 21
SCL-PIN ::= 20
I2C-FREQUENCY ::= 400_000

/** The ESP32 pin that the chip's DRDY pin is wired to, or null if it is not wired. */
DRDY-PIN/int? ::= null

/** The ESP32 pin that the chip's INT pin is wired to, or null if it is not wired. */
INT-PIN/int? ::= null

/** Set to true to run the hands-on rotation check. */
ROTATE-TEST ::= false

/** How long the rotation check watches, in seconds. */
ROTATE-SECONDS ::= 20

// Datasheet limits. The measurement range is typically ±1300 µT on X and Y and
// ±2500 µT on Z (table 1).
FIELD-MAX-XY-UT ::= 1300.0
FIELD-MAX-Z-UT ::= 2500.0

// Datasheet, table 1: in normal mode the regular preset gives an output data
// rate of 9.2 Hz to 10.8 Hz, which is 8 % either side of 10 Hz. The test warns
// beyond that and fails at 15 %, which is a choice made for this test.
RATE-WARN-RATIO ::= 0.08
RATE-FAIL-RATIO ::= 0.15

// Datasheet, table 1: typical output noise per preset in µT, as X/Y and Z. The
// low power preset has a separate Z value. The test warns at 1.5 times the
// figure and fails at 3 times, which are choices made for this test.
NOISE-WARN-FACTOR ::= 1.5
NOISE-FAIL-FACTOR ::= 3.0
NOISE-PRESETS ::= [
  // Preset, X/Y noise, Z noise, name.
  [Bmm150.PRESET-LOW-POWER, 1.0, 1.4, "low power"],
  [Bmm150.PRESET-REGULAR, 0.6, 0.6, "regular"],
  [Bmm150.PRESET-ENHANCED, 0.5, 0.5, "enhanced"],
  [Bmm150.PRESET-HIGH-ACCURACY, 0.3, 0.3, "high accuracy"],
]

// Choices made for this test. Earth's field is commonly given as roughly 25 to
// 65 µT, and the room adds to it, so the test only warns outside 15 to 100 µT.
// The datasheet gives no range for the Hall resistance count. The test warns
// outside 1000 to 16000 of the 14-bit range, a guess based on the figures in
// Bosch's reference code.
FIELD-WARN-LOW-UT ::= 15.0
FIELD-WARN-HIGH-UT ::= 100.0
RHALL-WARN-LOW ::= 1000
RHALL-WARN-HIGH ::= 16000

// Choices made for this test: how far the field may move across a soft reset,
// a suspend and a forced measurement on a still board.
SHIFT-WARN-UT ::= 2.0
SHIFT-FAIL-UT ::= 10.0

// Choices made for this test: how far a measurement may be from the time that
// the datasheet formula gives, after the I2C overhead is taken out. The formula
// is marked as approximate in the datasheet.
FORCED-TIME-WARN-RATIO ::= 0.25
FORCED-TIME-FAIL-RATIO ::= 0.6

// Choice made for this test: how much the field strength may vary when the
// board is rotated in a roughly uniform field.
ROTATE-MAX-SPREAD ::= 0.25

RATES ::= [
  Bmm150.ODR-2HZ,
  Bmm150.ODR-6HZ,
  Bmm150.ODR-10HZ,
  Bmm150.ODR-15HZ,
  Bmm150.ODR-20HZ,
  Bmm150.ODR-25HZ,
  Bmm150.ODR-30HZ,
]

class Stats:
  count/int := 0
  sum/float := 0.0
  sum-of-squares/float := 0.0
  low/float := 1.0e30
  high/float := -1.0e30

  add value/float -> none:
    count++
    sum += value
    sum-of-squares += value * value
    if value < low: low = value
    if value > high: high = value

  mean -> float:
    return sum / count

  std-dev -> float:
    variance := sum-of-squares / count - mean * mean
    return variance > 0.0 ? sqrt variance : 0.0

magnitude x/float y/float z/float -> float:
  return sqrt (x * x + y * y + z * z)

// Averages some compensated readings, to compare before and after an action.
average-field sensor/Bmm150 samples/int=10 -> List:
  x := Stats
  y := Stats
  z := Stats
  samples.repeat:
    field := sensor.read-mag-compensated
    x.add field.x
    y.add field.y
    z.add field.z
  return [x.mean, y.mean, z.mean]

distance a/List b/List -> float:
  return magnitude (a[0] - b[0]) (a[1] - b[1]) (a[2] - b[2])

// Judges a shift in the field after some action, as a warning or a failure.
judge-shift run/TestRun name/string before/List after/List -> none:
  shift := distance before after
  if shift > SHIFT-FAIL-UT:
    throw "field moved by $(%.2f shift) µT"
  if shift > SHIFT-WARN-UT:
    run.warn name "field moved by $(%.2f shift) µT"

main:
  run := TestRun
  run.section "Bus and identity"

  bus/i2c.Bus? := null
  sensor/Bmm150? := null

  run.check "I2C bus opens":
    bus = i2c.Bus
        --sda=SDA-PIN
        --scl=SCL-PIN
        --frequency=I2C-FREQUENCY

  run.check "chip answers at 0x$(%02x Bmm150.I2C-ADDRESS)":
    if not bus: throw "no bus"
    if not (bus.test Bmm150.I2C-ADDRESS):
      throw "nothing at 0x$(%02x Bmm150.I2C-ADDRESS). Check wiring and the CSB and SDO pins (0x11 to 0x13 when they are high)."

  run.check "driver starts":
    sensor = Bmm150 (bus.device Bmm150.I2C-ADDRESS) --logger=(log.default.with-level log.WARN-LEVEL)
    require-equals 0x32 sensor.get-chip-id

  if sensor == null:
    run.skip "everything else" "the driver did not start"
    run.finish
    return

  run-hardware-tests sensor run
  if DRDY-PIN:
    run-drdy-pin-tests sensor run
  else:
    run.section "DRDY pin"
    run.skip "DRDY pin" "set DRDY-PIN to the pin the chip's DRDY line is wired to"
  if INT-PIN:
    run-int-pin-tests sensor run
  else:
    run.section "INT pin"
    run.skip "INT pin" "set INT-PIN to the pin the chip's INT line is wired to"
  run.finish

/**
Runs every check that only needs a started driver.
*/
run-hardware-tests sensor/Bmm150 run/TestRun -> none:
  run.section "Self-test"

  run.check "the chip's normal self-test passes":
    require sensor.self-test
    sensor.set-mode Bmm150.MODE-NORMAL

  run.section "Readings"

  run.check "no axis is out of range":
    require-not (sensor.has-overflow)

  run.check "the field is inside the datasheet range":
    field := sensor.read-mag-compensated
    require field.x.abs <= FIELD-MAX-XY-UT --message="X is $(%.1f field.x) µT"
    require field.y.abs <= FIELD-MAX-XY-UT --message="Y is $(%.1f field.y) µT"
    require field.z.abs <= FIELD-MAX-Z-UT --message="Z is $(%.1f field.z) µT"

  run.check "the field strength is plausible":
    field := sensor.read-mag-compensated
    strength := magnitude field.x field.y field.z
    if strength < FIELD-WARN-LOW-UT or strength > FIELD-WARN-HIGH-UT:
      run.warn "field strength" "$(%.1f strength) µT is outside $(%.0f FIELD-WARN-LOW-UT) to $(%.0f FIELD-WARN-HIGH-UT) µT. Earth's field plus the room usually lands inside."

  run.check "the Hall resistance is not zero":
    rhall := sensor.read-rhall
    require rhall > 0 --message="rhall is $rhall"
    if rhall < RHALL-WARN-LOW or rhall > RHALL-WARN-HIGH:
      run.warn "rhall" "$rhall is outside $RHALL-WARN-LOW to $RHALL-WARN-HIGH."

  run.check "raw counts and compensated field have the same signs":
    // Both come from one burst, so they describe the same instant. The
    // corrections scale and shift the counts but are small next to a field of
    // a few tens of µT.
    bytes := sensor.read-raw-data
    raw := sensor.read-mag-raw bytes
    field := sensor.read-mag-compensated bytes
    require ((raw.x < 0) == (field.x < 0) or field.x.abs < 5.0) --message="X: raw $raw.x, field $(%.1f field.x)"
    require ((raw.y < 0) == (field.y < 0) or field.y.abs < 5.0) --message="Y: raw $raw.y, field $(%.1f field.y)"
    require ((raw.z < 0) == (field.z < 0) or field.z.abs < 5.0) --message="Z: raw $raw.z, field $(%.1f field.z)"

  run.section "Configuration"

  run.check "every output data rate reads back":
    RATES.do: | odr |
      sensor.set-odr odr
      require-equals odr sensor.get-odr
    sensor.set-odr Bmm150.ODR-10HZ

  run.check "every preset reads back its repetitions":
    [[Bmm150.PRESET-LOW-POWER, 3, 3], [Bmm150.PRESET-REGULAR, 9, 15],
        [Bmm150.PRESET-ENHANCED, 15, 27], [Bmm150.PRESET-HIGH-ACCURACY, 47, 83]].do: | row |
      sensor.set-preset row[0]
      require-equals row[1] sensor.get-repetitions-xy
      require-equals row[2] sensor.get-repetitions-z
    sensor.set-preset Bmm150.PRESET-REGULAR

  run.section "Timing"

  RATES.do: | odr |
    run.check "measured rate at $(Bmm150.odr-to-hz odr) Hz":
      sensor.set-preset Bmm150.PRESET-REGULAR
      sensor.set-odr odr
      hz := Bmm150.odr-to-hz odr
      // Let the first sample at the new rate go by, then time the next ones.
      sensor.read-raw-data
      count := max 4 (min 30 (hz * 2.0).to-int)
      start := Time.monotonic-us
      count.repeat: sensor.read-raw-data
      seconds := (Time.monotonic-us - start) / 1_000_000.0
      measured := count / seconds
      error := ((measured - hz) / hz).abs
      if error > RATE-FAIL-RATIO: throw "measured $(%.2f measured) Hz, off by $(%.1f error * 100) %"
      if error > RATE-WARN-RATIO:
        run.warn "rate at $hz Hz" "measured $(%.2f measured) Hz, off by $(%.1f error * 100) %. The datasheet allows 8 % at 10 Hz."
  sensor.set-odr Bmm150.ODR-10HZ

  run.check "forced measurements take about as long as the datasheet formula says":
    overhead := forced-overhead-ms sensor
    [[3, 3], [9, 15], [15, 27], [47, 83]].do: | row |
      sensor.set-repetitions --xy=row[0] --z=row[1]
      expected := (Bmm150.measurement-time-us row[0] row[1]) / 1000.0 + overhead
      measured := median-forced-ms sensor
      error := ((measured - expected) / expected).abs
      if error > FORCED-TIME-FAIL-RATIO:
        throw "xy $row[0], z $row[1]: took $(%.1f measured) ms, expected about $(%.1f expected) ms"
      if error > FORCED-TIME-WARN-RATIO:
        run.warn "forced time" "xy $row[0], z $row[1]: took $(%.1f measured) ms, expected about $(%.1f expected) ms"
    sensor.set-preset Bmm150.PRESET-REGULAR
    sensor.set-mode Bmm150.MODE-NORMAL

  run.check "the Z register counts repetitions as 1 + 2 * register":
    // The datasheet's register text gives 1 + register, while its preset table
    // and Bosch's code fit 1 + 2 * register. The driver follows the preset
    // table. Z register 40 means 81 repetitions one way and 41 the other, and
    // the two differ by 20 ms in measurement time.
    overhead := forced-overhead-ms sensor
    sensor.set-repetitions --xy=1 --z=81
    measured := median-forced-ms sensor
    as-doubled := (Bmm150.measurement-time-us 1 81) / 1000.0 + overhead
    as-plain := (Bmm150.measurement-time-us 1 41) / 1000.0 + overhead
    sensor.set-preset Bmm150.PRESET-REGULAR
    sensor.set-mode Bmm150.MODE-NORMAL
    print "        measured $(%.1f measured) ms. 1 + 2 * register predicts $(%.1f as-doubled) ms, 1 + register predicts $(%.1f as-plain) ms."
    if (measured - as-plain).abs < (measured - as-doubled).abs:
      throw "the chip behaves like 1 + REPZ, so set-repetitions and the presets are wrong for Z"

  // A failed timing check can leave the chip in sleep mode or with odd
  // repetitions. Put it back before the checks that need normal mode.
  sensor.set-preset Bmm150.PRESET-REGULAR
  sensor.set-mode Bmm150.MODE-NORMAL

  run.section "Noise on a still board"

  NOISE-PRESETS.do: | row |
    run.check "noise with the $row[3] preset":
      sensor.set-preset row[0]
      sensor.set-odr Bmm150.ODR-20HZ
      x := Stats
      y := Stats
      z := Stats
      sensor.read-raw-data  // Skip a sample that predates the new settings.
      80.repeat:
        field := sensor.read-mag-compensated
        x.add field.x
        y.add field.y
        z.add field.z
      print "        std dev X $(%.2f x.std-dev) Y $(%.2f y.std-dev) Z $(%.2f z.std-dev) µT. The datasheet says $(%.1f row[1]) for X and Y and $(%.1f row[2]) for Z."
      judge-noise run "X" x.std-dev row[1]
      judge-noise run "Y" y.std-dev row[1]
      judge-noise run "Z" z.std-dev row[2]
  sensor.set-preset Bmm150.PRESET-REGULAR

  run.section "Modes and resets"

  run.check "a forced measurement agrees with normal mode":
    before := average-field sensor
    sensor.set-mode Bmm150.MODE-FORCED
    bytes := sensor.read-raw-data
    require-equals Bmm150.MODE-SLEEP sensor.get-mode
    field := sensor.read-mag-compensated bytes
    judge-shift run "forced measurement" before [field.x, field.y, field.z]
    sensor.set-mode Bmm150.MODE-NORMAL

  run.check "suspend mode keeps the settings the driver writes back":
    sensor.set-preset Bmm150.PRESET-ENHANCED
    sensor.set-odr Bmm150.ODR-15HZ
    before := average-field sensor
    sensor.set-mode Bmm150.MODE-SUSPEND
    require-equals Bmm150.MODE-SUSPEND sensor.get-mode
    sleep --ms=200
    sensor.set-mode Bmm150.MODE-NORMAL
    require-equals Bmm150.ODR-15HZ sensor.get-odr
    require-equals 15 sensor.get-repetitions-xy
    require-equals 27 sensor.get-repetitions-z
    judge-shift run "suspend and wake" before (average-field sensor)

  run.check "soft reset returns the power-on settings":
    before := average-field sensor
    sensor.soft-reset
    require-equals Bmm150.MODE-SLEEP sensor.get-mode
    require-equals Bmm150.ODR-10HZ sensor.get-odr
    require-equals 1 sensor.get-repetitions-xy
    sensor.set-preset Bmm150.PRESET-REGULAR
    sensor.set-mode Bmm150.MODE-NORMAL
    judge-shift run "soft reset" before (average-field sensor)

  run.check "a disabled axis reads zero and the others keep working":
    sensor.enable-axis --no-x
    field := sensor.read-mag-compensated
    require-equals 0.0 field.x
    require (field.y != 0.0 and field.z != 0.0)
    sensor.enable-axis --no-x --no-y
    field = sensor.read-mag-compensated
    require (field.x == 0.0 and field.y == 0.0 and field.z != 0.0)
    sensor.enable-axis
    field = sensor.read-mag-compensated
    require (field.x != 0.0 and field.y != 0.0 and field.z != 0.0)

  if ROTATE-TEST:
    run.section "Rotation"
    run.check "field strength stays constant while the board turns":
      check-rotation sensor run
  else:
    run.skip "rotation" "set ROTATE-TEST to true to run it"

// Judges one axis of noise against the datasheet figure.
judge-noise run/TestRun axis/string measured/float datasheet/float -> none:
  if measured > datasheet * NOISE-FAIL-FACTOR:
    throw "$axis noise is $(%.2f measured) µT, against $datasheet in the datasheet"
  if measured > datasheet * NOISE-WARN-FACTOR:
    run.warn "noise $axis" "$(%.2f measured) µT, against $datasheet in the datasheet"

// Takes one forced measurement and returns how long it took, in milliseconds.
// The time includes the I2C traffic around the measurement.
forced-ms sensor/Bmm150 -> float:
  start := Time.monotonic-us
  sensor.set-mode Bmm150.MODE-FORCED
  sensor.read-raw-data
  return (Time.monotonic-us - start) / 1000.0

median-forced-ms sensor/Bmm150 -> float:
  times := List 5: forced-ms sensor
  times.sort --in-place
  return times[2]

// Works out how much of a forced measurement is I2C traffic and polling, by
// timing the shortest measurement the chip can make. The datasheet formula
// gives its duration as 1.6 ms.
forced-overhead-ms sensor/Bmm150 -> float:
  sensor.set-repetitions --xy=1 --z=1
  shortest := (Bmm150.measurement-time-us 1 1) / 1000.0
  return (median-forced-ms sensor) - shortest

// Opens a pin as an input for the block, and closes it again afterwards.
with-pin pin-number/int --pull-up/bool=false --pull-down/bool=false [block] -> none:
  pin := gpio.Pin.in pin-number
      --pull-up=pull-up
      --pull-down=pull-down
  try:
    block.call pin
  finally:
    pin.close

// Waits up to the given time for the pin to reach a level, and says whether it
// did.
reaches-level pin/gpio.Pin level/int --ms/int -> bool:
  error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
    with-timeout (Duration --ms=ms): pin.wait-for level
  return error == null

/**
Checks the chip's DRDY pin with a wire from it to the ESP32.

Needs $DRDY-PIN to be wired. The slow rate leaves time between samples to look
  at the pin before the next one arrives. It is a choice made for this test.
*/
run-drdy-pin-tests sensor/Bmm150 run/TestRun -> none:
  run.section "DRDY pin (GPIO $DRDY-PIN)"
  sensor.set-preset Bmm150.PRESET-REGULAR
  sensor.set-odr Bmm150.ODR-6HZ
  sensor.set-drdy-pin false
  sensor.set-drdy-pin-polarity true

  run.check "the pin stays low while the DRDY output is off":
    with-pin DRDY-PIN --pull-down: | pin |
      sleep --ms=400
      require-equals 0 pin.get

  run.check "the pin goes high with a new measurement and low when it is read":
    sensor.set-drdy-pin true
    with-pin DRDY-PIN --pull-down: | pin |
      require (reaches-level pin 1 --ms=500) --message="the pin never went high"
      sleep --ms=20
      require-equals 1 pin.get --message="the pin did not stay high until the data was read"
      sensor.read-raw-data --no-wait
      require-equals 0 pin.get --message="the pin stayed high after the read"

  run.check "active-low polarity inverts the pin":
    sensor.set-drdy-pin-polarity false
    with-pin DRDY-PIN --pull-up: | pin |
      // A measurement is waiting, so the pin is low.
      require (reaches-level pin 0 --ms=500) --message="the pin never went low"
      sensor.read-raw-data --no-wait
      require-equals 1 pin.get --message="the pin stayed low after the read"
    sensor.set-drdy-pin-polarity true

  run.check "the pin delivers one pulse per sample":
    with-pin DRDY-PIN --pull-down: | pin |
      count := 0
      start := Time.monotonic-us
      while Time.monotonic-us - start < 3_000_000:
        if reaches-level pin 1 --ms=500:
          sensor.read-raw-data --no-wait
          count++
      hz := Bmm150.odr-to-hz Bmm150.ODR-6HZ
      expected := hz * 3.0
      error := ((count - expected) / expected).abs
      print "        $count pulses in 3 s, $(%.0f expected) expected."
      if error > RATE-FAIL-RATIO * 2.0: throw "the pulse count is off by $(%.1f error * 100) %"
      if error > RATE-WARN-RATIO: run.warn "pulse rate" "off by $(%.1f error * 100) %."

  sensor.set-drdy-pin false
  sensor.set-odr Bmm150.ODR-10HZ

/**
Checks the chip's INT pin with a wire from it to the ESP32.

Needs $INT-PIN to be wired. The test uses a high threshold of -128, which the
  field exceeds on every axis unless a strong magnet is near, so the interrupt
  fires without any hands-on step.
*/
run-int-pin-tests sensor/Bmm150 run/TestRun -> none:
  run.section "INT pin (GPIO $INT-PIN)"
  sensor.set-preset Bmm150.PRESET-REGULAR
  sensor.set-odr Bmm150.ODR-2HZ
  sensor.set-int-pin false
  sensor.set-int-pin-polarity true
  sensor.set-int-latched-mode true
  sensor.disable-high-threshold-interrupt
  sensor.disable-low-threshold-interrupt
  sensor.read-interrupt-status

  run.check "the pin stays low while the INT output is off":
    sensor.enable-high-threshold-interrupt -128
    with-pin INT-PIN --pull-down: | pin |
      sleep --ms=1200
      require-equals 0 pin.get
    sensor.disable-high-threshold-interrupt

  run.check "a latched interrupt stays high until the status is read":
    sensor.set-int-pin true
    sensor.enable-high-threshold-interrupt -128
    with-pin INT-PIN --pull-down: | pin |
      require (reaches-level pin 1 --ms=1500) --message="the pin never went high"
      sleep --ms=50
      require-equals 1 pin.get --message="the pin did not stay high"
      status := sensor.read-interrupt-status
      require-equals 0 pin.get --message="the pin stayed high after the status read"
      high := Bmm150.INT-STATUS-HIGH-X | Bmm150.INT-STATUS-HIGH-Y | Bmm150.INT-STATUS-HIGH-Z
      require-equals high (status & high) --message="status was 0b$(%b status)"

  run.check "a non-latched interrupt follows the condition":
    sensor.set-int-latched-mode false
    with-pin INT-PIN --pull-down: | pin |
      sensor.read-interrupt-status
      require (reaches-level pin 1 --ms=1500) --message="the pin never went high"
      sensor.disable-high-threshold-interrupt
      require (reaches-level pin 0 --ms=1500) --message="the pin stayed high after the condition went away"
    sensor.set-int-latched-mode true

  run.check "a low threshold of 127 fires too":
    sensor.enable-low-threshold-interrupt 127
    with-pin INT-PIN --pull-down: | pin |
      require (reaches-level pin 1 --ms=1500) --message="the pin never went high"
      status := sensor.read-interrupt-status
      require (status & Bmm150.INT-STATUS-LOW-Z) != 0 --message="status was 0b$(%b status)"
    sensor.disable-low-threshold-interrupt

  run.check "active-low polarity inverts the pin":
    sensor.set-int-pin-polarity false
    with-pin INT-PIN --pull-up: | pin |
      sensor.read-interrupt-status
      sleep --ms=700
      require-equals 1 pin.get --message="the pin is not high without a condition"
      sensor.enable-high-threshold-interrupt -128
      require (reaches-level pin 0 --ms=1500) --message="the pin never went low"
    sensor.disable-high-threshold-interrupt
    sensor.set-int-pin-polarity true
    sensor.read-interrupt-status

  sensor.set-int-pin false
  sensor.set-odr Bmm150.ODR-10HZ

// Watches the field while the user turns the board, and compares how constant
// the strength stays. It also prints the hard-iron centre as a starting point
// for a calibration.
check-rotation sensor/Bmm150 run/TestRun -> none:
  sensor.set-preset Bmm150.PRESET-ENHANCED
  sensor.set-odr Bmm150.ODR-25HZ
  print "        Turn the board slowly through every orientation for $ROTATE-SECONDS s."
  print "        Starting in 5 s."
  sleep --ms=5000
  print "        Go."

  comp-strength := Stats
  calibrated-strength := Stats
  readings := []
  calibrator := MagCalibrator
  axes := [Stats, Stats, Stats]
  start := Time.monotonic-us
  while Time.monotonic-us - start < ROTATE-SECONDS * 1_000_000:
    comp := sensor.read-mag-compensated
    readings.add comp
    calibrator.add comp
    comp-strength.add (magnitude comp.x comp.y comp.z)
    axes[0].add comp.x
    axes[1].add comp.y
    axes[2].add comp.z
  print "        Done."

  calibration := calibrator.calibration
  readings.do: | comp |
    fixed := calibration.apply comp
    calibrated-strength.add (magnitude fixed.x fixed.y fixed.z)

  comp-spread := (comp-strength.high - comp-strength.low) / comp-strength.mean
  fixed-spread := (calibrated-strength.high - calibrated-strength.low) / calibrated-strength.mean
  print "        strength, compensated: mean $(%.1f comp-strength.mean) µT, spread $(%.1f comp-spread * 100) %"
  print "        strength, calibrated:  mean $(%.1f calibrated-strength.mean) µT, spread $(%.1f fixed-spread * 100) %"
  print "        calibration from this run: $calibration"
  if axes[0].high - axes[0].low < 10.0 and axes[1].high - axes[1].low < 10.0 and axes[2].high - axes[2].low < 10.0:
    throw "the field hardly changed, so the board was probably not turned"
  if fixed-spread > ROTATE-MAX-SPREAD:
    throw "strength varies by $(%.1f fixed-spread * 100) % even after calibration. A steel object or magnet is probably nearby."
  if fixed-spread > comp-spread + 0.02:
    run.warn "rotation" "calibration made the strength less constant ($(%.1f fixed-spread * 100) % against $(%.1f comp-spread * 100) %)."
