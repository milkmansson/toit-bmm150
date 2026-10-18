// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Tests the BMM150 driver against a simulated chip. No hardware is needed.

Run on the host with:
```
toit pkg install
toit bmm150-mock-test.toit
```

The compensation checks compare the driver's output with numbers produced by
  Bosch Sensortec's own C code (see golden/bmm150-golden.c). The register
  checks use $MockBmm150Registers, which follows the datasheet closely enough
  to catch the mistakes that matter: settings lost in suspend mode, clobbered
  neighbouring bits, stale data after a forced measurement, and a Z axis that
  cannot be switched off.
*/

import log
import bmm150 show *
import .golden-vectors
import .mock-bmm150
import bmm150.calibration show MagCalibration
import .test-helpers

REG-OP-MODE ::= 0x4C
REG-INT-CONFIG ::= 0x4D
REG-AXES-ENABLE ::= 0x4E
REG-LOW-THRESHOLD ::= 0x4F
REG-HIGH-THRESHOLD ::= 0x50
REG-REP-XY ::= 0x51
REG-REP-Z ::= 0x52

// Tolerance for the golden vectors in µT. Bosch computes in 32-bit floats.
MAG-TOLERANCE ::= 0.01

new-sensor mock/MockBmm150Device -> Bmm150
    --preset/int=Bmm150.PRESET-REGULAR
    --odr/int?=null
    --calibration/MagCalibration?=null:
  logger := log.default.with-level log.ERROR-LEVEL
  return Bmm150 mock --preset=preset --odr=odr --calibration=calibration --logger=logger

// Returns the index of the first write of `[register, value]` at or after
// `from`, or -1.
index-of-write mock/MockBmm150Device register/int value/int --from/int=0 -> int:
  writes := mock.registers.writes
  for i := from; i < writes.size; i++:
    if writes[i][0] == register and writes[i][1] == value: return i
  return -1

// Loads one golden case into the mock and returns a sensor on it.
golden-sensor mock/MockBmm150Device case/Map -> Bmm150:
  trim := case["trim"]
  trim.size.repeat: mock.registers.trim[it] = trim[it]
  return new-sensor mock

main:
  run := TestRun

  run.section "Boot"

  run.check "boots and identifies the chip":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-equals 0x32 sensor.get-chip-id
    require mock.registers.is-powered
    require-equals 0 mock.registers.op-mode  // Normal mode.

  run.check "rejects a chip with the wrong ID":
    mock := MockBmm150Device
    mock.registers.chip-id = 0x44
    require-throw "Unexpected chip id [0x44]": new-sensor mock

  run.check "powers up before it reads the chip ID":
    mock := MockBmm150Device
    new-sensor mock
    require-equals [0x4B, 0x01] mock.registers.writes[0]

  run.check "resets the settings before it applies its own":
    mock := MockBmm150Device
    new-sensor mock
    reset := index-of-write mock 0x4B 0x83
    preset := index-of-write mock REG-REP-XY 4
    require reset >= 0
    require reset < preset
    require-equals 1 mock.registers.reset-count

  run.check "starts with the regular preset":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-equals 9 sensor.get-repetitions-xy
    require-equals 15 sensor.get-repetitions-z
    require-equals Bmm150.ODR-10HZ sensor.get-odr

  run.section "Presets and rates"

  run.check "every preset writes the repetitions of datasheet table 3":
    // Preset, X/Y repetitions, Z repetitions, ODR in Hz.
    expected := [
      [Bmm150.PRESET-LOW-POWER, 3, 3, 10.0],
      [Bmm150.PRESET-REGULAR, 9, 15, 10.0],
      [Bmm150.PRESET-ENHANCED, 15, 27, 10.0],
      [Bmm150.PRESET-HIGH-ACCURACY, 47, 83, 20.0],
    ]
    expected.do: | row |
      mock := MockBmm150Device
      sensor := new-sensor mock --preset=row[0]
      require-equals row[1] sensor.get-repetitions-xy
      require-equals row[2] sensor.get-repetitions-z
      require-equals row[3] (Bmm150.odr-to-hz sensor.get-odr)

  run.check "an explicit rate replaces the preset's rate":
    mock := MockBmm150Device
    sensor := new-sensor mock --preset=Bmm150.PRESET-HIGH-ACCURACY --odr=Bmm150.ODR-25HZ
    require-equals Bmm150.ODR-25HZ sensor.get-odr
    require-equals 47 sensor.get-repetitions-xy

  run.check "setting the rate keeps the mode bits":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-odr Bmm150.ODR-30HZ
    require-equals Bmm150.ODR-30HZ sensor.get-odr
    require-equals Bmm150.MODE-NORMAL sensor.get-mode

  run.check "rate table matches datasheet table 17":
    expected := [10.0, 2.0, 6.0, 8.0, 15.0, 20.0, 25.0, 30.0]
    expected.size.repeat: require-equals expected[it] (Bmm150.odr-to-hz it)

  run.check "rejects an unknown rate and preset":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-throw "Invalid output data rate 8": sensor.set-odr 8
    require-throw "Invalid preset 4": sensor.set-preset 4

  run.check "sets repetitions from counts":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-repetitions --xy=47 --z=83
    require-equals 23 (mock.registers.peek REG-REP-XY)
    require-equals 41 (mock.registers.peek REG-REP-Z)
    require-equals 47 sensor.get-repetitions-xy
    require-equals 83 sensor.get-repetitions-z

  run.check "rejects repetition counts the register cannot hold":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-throw "Invalid X/Y repetitions 8": sensor.set-repetitions --xy=8 --z=15
    require-throw "Invalid Z repetitions 513": sensor.set-repetitions --xy=9 --z=513
    require-throw "Invalid X/Y repetitions 0": sensor.set-repetitions --xy=0 --z=15

  run.check "measurement time follows the datasheet formula":
    // 145 us * 9 + 500 us * 15 + 980 us.
    require-equals 9785 (Bmm150.measurement-time-us 9 15)

  run.section "Decoding"

  run.check "decodes the raw counts at the edges of their ranges":
    // X and Y have 13 bits and Z has 15 bits, in two's complement.
    cases := [
      [0, 0, 0, 0],
      [1, -1, 1, 1],
      [4095, 4095, 16383, 16383],
      [-4095, -4095, -16383, 100],
      [-4096, -4096, -16384, 8000],
      [31, 32, 127, 128],
      [-32, -33, -128, 129],
    ]
    cases.do: | raw |
      mock := MockBmm150Device
      sensor := new-sensor mock
      mock.registers.raw-x = raw[0]
      mock.registers.raw-y = raw[1]
      mock.registers.raw-z = raw[2]
      mock.registers.raw-rhall = raw[3]
      mock.registers.inject-sample
      bytes := sensor.read-raw-data
      point := sensor.read-mag-raw bytes
      require-equals raw[0].to-float point.x
      require-equals raw[1].to-float point.y
      require-equals raw[2].to-float point.z
      require-equals raw[3] (sensor.read-rhall bytes)

  run.check "returns the registers 0x42 to 0x49":
    mock := MockBmm150Device
    sensor := new-sensor mock
    mock.registers.inject-sample
    require-equals 8 sensor.read-raw-data.size

  run.section "Compensation against Bosch's code"

  GOLDEN-CASES.do: | case |
    run.check "golden: $case["name"]":
      mock := MockBmm150Device
      sensor := golden-sensor mock case
      mock.registers.inject-bytes case["bytes"]
      bytes := sensor.read-raw-data
      raw := case["raw"]
      point := sensor.read-mag-raw bytes
      require-equals raw[0].to-float point.x
      require-equals raw[1].to-float point.y
      require-equals raw[2].to-float point.z
      require-equals raw[3] (sensor.read-rhall bytes)
      mag := case["mag"]
      field := sensor.read-mag-compensated bytes
      require-close mag[0] field.x MAG-TOLERANCE "x"
      require-close mag[1] field.y MAG-TOLERANCE "y"
      require-close mag[2] field.z MAG-TOLERANCE "z"

  GOLDEN-CASES.do: | case |
    run.check "golden trims: $case["name"]":
      trim := Bmm150Trim.from-registers case["trim"]
      decoded := case["decoded"]
      actual := [trim.x1, trim.y1, trim.x2, trim.y2, trim.z1, trim.z2, trim.z3, trim.z4, trim.xy1, trim.xy2, trim.xyz1]
      require-equals decoded actual

  run.check "reading the trim registers skips the gaps between them":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    sensor := golden-sensor mock case
    // Poke garbage into the registers that hold no trim value.
    mock.registers.trim[0x02] = 0xEE
    mock.registers.trim[0x03] = 0xEE
    mock.registers.trim[0x04] = 0xEE
    mock.registers.inject-bytes case["bytes"]
    field := sensor.read-mag-compensated
    require-close case["mag"][0] field.x MAG-TOLERANCE "x"

  run.section "Out of range"

  run.check "flags X, Y and Z at their saturated values":
    [[-4096, 0, 0], [0, -4096, 0], [0, 0, -16384]].do: | raw |
      mock := MockBmm150Device
      sensor := new-sensor mock
      mock.registers.raw-x = raw[0]
      mock.registers.raw-y = raw[1]
      mock.registers.raw-z = raw[2]
      mock.registers.inject-sample
      bytes := sensor.read-raw-data
      require (sensor.has-overflow bytes)
      require-throw "BMM150 measurement out of range": sensor.read-mag-compensated bytes

  run.check "a normal reading is not out of range":
    mock := MockBmm150Device
    sensor := golden-sensor mock GOLDEN-CASES[0]
    mock.registers.inject-bytes GOLDEN-CASES[0]["bytes"]
    require-not (sensor.has-overflow sensor.read-raw-data)

  run.check "a disabled axis does not count as out of range":
    mock := MockBmm150Device
    sensor := golden-sensor mock GOLDEN-CASES[0]
    sensor.enable-axis --no-x
    mock.registers.inject-bytes #[0x01, 0xF0, 0x59, 0xFD, 0x6D, 0x02, 0x11, 0x59]  // X = -4096.
    bytes := sensor.read-raw-data
    require-not (sensor.has-overflow bytes)

  run.section "Axes"

  run.check "switches X and Y off without touching other bits":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-int-pin true
    before := mock.registers.peek REG-AXES-ENABLE
    sensor.enable-axis --no-x --no-y
    after := mock.registers.peek REG-AXES-ENABLE
    require-equals (before | 0b00011000) after
    sensor.enable-axis
    require-equals before (mock.registers.peek REG-AXES-ENABLE)

  run.check "never switches Z off":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.enable-axis --no-x --no-y
    require-equals 0 ((mock.registers.peek REG-AXES-ENABLE) & 0b00100000)

  run.check "disabled axes read as zero":
    mock := MockBmm150Device
    sensor := golden-sensor mock GOLDEN-CASES[0]
    sensor.enable-axis --no-y
    mock.registers.inject-bytes GOLDEN-CASES[0]["bytes"]
    bytes := sensor.read-raw-data
    require-equals 0.0 (sensor.read-mag-compensated bytes).y
    require-equals 0.0 (sensor.read-mag-raw bytes).y
    require (sensor.read-mag-compensated bytes).x != 0.0

  run.section "Power modes"

  run.check "forced mode takes one measurement and returns to sleep":
    mock := MockBmm150Device
    sensor := new-sensor mock
    mock.registers.raw-x = 77
    sensor.set-mode Bmm150.MODE-FORCED
    bytes := sensor.read-raw-data
    require-equals 77.0 (sensor.read-mag-raw bytes).x
    require-equals Bmm150.MODE-SLEEP sensor.get-mode

  run.check "forced mode starts from sleep mode":
    mock := MockBmm150Device
    sensor := new-sensor mock
    before := mock.registers.writes.size
    sensor.set-mode Bmm150.MODE-FORCED
    sleep-write := index-of-write mock REG-OP-MODE 0x06 --from=before
    forced-write := index-of-write mock REG-OP-MODE 0x02 --from=before
    require sleep-write >= 0
    require sleep-write < forced-write

  run.check "forced mode drops a stale measurement":
    mock := MockBmm150Device
    sensor := new-sensor mock
    mock.registers.raw-x = 10
    mock.registers.inject-sample  // Nobody reads this one.
    mock.registers.raw-x = 20
    sensor.set-mode Bmm150.MODE-FORCED
    require-equals 20.0 (sensor.read-mag-raw sensor.read-raw-data).x

  run.check "waits for data and times out in sleep mode":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-mode Bmm150.MODE-SLEEP
    require-throw "BMM150 data ready timeout (is it in sleep mode?)": sensor.read-raw-data

  run.check "returns the registers at once without waiting":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-mode Bmm150.MODE-SLEEP
    require-equals 8 (sensor.read-raw-data --no-wait).size

  run.check "reading the data ready flag clears it":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-mode Bmm150.MODE-SLEEP
    mock.registers.inject-sample
    require sensor.is-data-ready
    require-not sensor.is-data-ready

  run.check "normal mode delivers samples at the rate":
    mock := MockBmm150Device
    sensor := new-sensor mock --odr=Bmm150.ODR-30HZ
    start := Time.monotonic-us
    count := 10
    count.repeat: sensor.read-raw-data
    seconds := (Time.monotonic-us - start) / 1_000_000.0
    // Ten samples at 30 Hz take about a third of a second.
    require (seconds > 0.25 and seconds < 0.6) --message="10 samples took $seconds s"

  run.check "reports the mode the chip is in":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-equals Bmm150.MODE-NORMAL sensor.get-mode
    sensor.set-mode Bmm150.MODE-SLEEP
    require-equals Bmm150.MODE-SLEEP sensor.get-mode
    sensor.set-mode Bmm150.MODE-SUSPEND
    require-equals Bmm150.MODE-SUSPEND sensor.get-mode

  run.check "rejects an unknown mode":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-throw "Unsupported power mode 2": sensor.set-mode 2

  run.section "Suspend mode"

  run.check "refuses to touch registers in suspend mode":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-mode Bmm150.MODE-SUSPEND
    require-not mock.registers.is-powered
    message := "BMM150 is in suspend mode, call set-mode first"
    require-throw message: sensor.set-odr Bmm150.ODR-30HZ
    require-throw message: sensor.get-chip-id
    require-throw message: sensor.enable-axis --no-x

  run.check "writes its settings back when it wakes":
    mock := MockBmm150Device
    sensor := new-sensor mock --preset=Bmm150.PRESET-ENHANCED --odr=Bmm150.ODR-25HZ
    sensor.enable-axis --no-y
    sensor.set-int-pin true
    sensor.set-int-pin-polarity false
    sensor.enable-low-threshold-interrupt 20 --no-z
    sensor.enable-high-threshold-interrupt 40
    registers := [REG-INT-CONFIG, REG-AXES-ENABLE, REG-LOW-THRESHOLD, REG-HIGH-THRESHOLD, REG-REP-XY, REG-REP-Z]
    before := registers.map: mock.registers.peek it
    sensor.set-mode Bmm150.MODE-SUSPEND
    // The chip lost everything.
    require-equals 0x3F (mock.registers.peek REG-INT-CONFIG)
    sensor.set-mode Bmm150.MODE-NORMAL
    after := registers.map: mock.registers.peek it
    require-equals before after
    require-equals Bmm150.ODR-25HZ sensor.get-odr
    require-equals Bmm150.MODE-NORMAL sensor.get-mode

  run.check "wakes the chip before a forced measurement":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-mode Bmm150.MODE-SUSPEND
    mock.registers.raw-x = 55
    sensor.set-mode Bmm150.MODE-FORCED
    require-equals 55.0 (sensor.read-mag-raw sensor.read-raw-data).x

  run.check "soft reset restores the power-on settings":
    mock := MockBmm150Device
    sensor := new-sensor mock --preset=Bmm150.PRESET-HIGH-ACCURACY
    sensor.enable-axis --no-x
    sensor.soft-reset
    require-equals Bmm150.MODE-SLEEP sensor.get-mode
    require-equals 1 sensor.get-repetitions-xy
    require-equals Bmm150.ODR-10HZ sensor.get-odr
    // The driver forgot the old settings too, so a later suspend and wake
    // does not bring them back.
    sensor.set-mode Bmm150.MODE-SUSPEND
    sensor.set-mode Bmm150.MODE-SLEEP
    require-equals 1 sensor.get-repetitions-xy
    require-equals 0 ((mock.registers.peek REG-AXES-ENABLE) & 0b00111000)

  run.check "soft reset wakes a suspended chip first":
    mock := MockBmm150Device
    sensor := new-sensor mock
    resets := mock.registers.reset-count
    sensor.set-mode Bmm150.MODE-SUSPEND
    sensor.soft-reset
    require-equals (resets + 1) mock.registers.reset-count

  run.section "Pins and interrupts"

  run.check "each pin setter changes only its own bit":
    mock := MockBmm150Device
    sensor := new-sensor mock
    start := mock.registers.peek REG-AXES-ENABLE  // 0x07.
    sensor.set-drdy-pin true
    require-equals (start | 0b10000000) (mock.registers.peek REG-AXES-ENABLE)
    require sensor.is-drdy-pin-set
    sensor.set-int-pin true
    require-equals (start | 0b11000000) (mock.registers.peek REG-AXES-ENABLE)
    require sensor.is-int-pin-set
    sensor.set-drdy-pin-polarity false
    require-equals 0b11000011 (mock.registers.peek REG-AXES-ENABLE)
    sensor.set-int-pin-polarity false
    require-equals 0b11000010 (mock.registers.peek REG-AXES-ENABLE)
    sensor.set-int-latched-mode false
    require-equals 0b11000000 (mock.registers.peek REG-AXES-ENABLE)
    sensor.set-int-latched-mode true
    sensor.set-drdy-pin false
    sensor.set-int-pin false
    require-equals 0b00000010 (mock.registers.peek REG-AXES-ENABLE)

  run.check "the low threshold bits are active low":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.enable-low-threshold-interrupt 20 --no-y --no-z
    require-equals 20 (mock.registers.peek REG-LOW-THRESHOLD)
    require-equals 0b00111110 (mock.registers.peek REG-INT-CONFIG)
    sensor.disable-low-threshold-interrupt
    require-equals 0b00111111 (mock.registers.peek REG-INT-CONFIG)

  run.check "the high threshold bits are active low":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.enable-high-threshold-interrupt -5 --z=false
    require-equals 0xFB (mock.registers.peek REG-HIGH-THRESHOLD)
    require-equals 0b00100111 (mock.registers.peek REG-INT-CONFIG)
    sensor.disable-high-threshold-interrupt
    require-equals 0b00111111 (mock.registers.peek REG-INT-CONFIG)

  run.check "rejects a threshold that does not fit":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require-throw "Invalid threshold 128": sensor.enable-low-threshold-interrupt 128
    require-throw "Invalid threshold -129": sensor.enable-high-threshold-interrupt -129

  run.check "overflow and overrun settings change only their bit":
    mock := MockBmm150Device
    sensor := new-sensor mock
    sensor.set-overflow-interrupt true
    require-equals 0b01111111 (mock.registers.peek REG-INT-CONFIG)
    sensor.set-overrun-flag true
    require-equals 0b11111111 (mock.registers.peek REG-INT-CONFIG)
    sensor.set-overflow-interrupt false
    sensor.set-overrun-flag false
    require-equals 0b00111111 (mock.registers.peek REG-INT-CONFIG)

  run.check "reads the interrupt status":
    mock := MockBmm150Device
    sensor := new-sensor mock
    mock.registers.poke 0x4A (Bmm150.INT-STATUS-OVERFLOW | Bmm150.INT-STATUS-HIGH-Z)
    status := sensor.read-interrupt-status
    require (status & Bmm150.INT-STATUS-OVERFLOW) != 0
    require (status & Bmm150.INT-STATUS-HIGH-Z) != 0
    require (status & Bmm150.INT-STATUS-LOW-X) == 0

  run.section "Self-test"

  run.check "passes when all three axes pass":
    mock := MockBmm150Device
    sensor := new-sensor mock
    require sensor.self-test
    require-equals Bmm150.MODE-SLEEP sensor.get-mode

  run.check "fails when one axis fails":
    [0b110, 0b101, 0b011, 0b000].do: | bits |
      mock := MockBmm150Device
      mock.registers.set-self-test-results bits
      sensor := new-sensor mock
      require-not (sensor.self-test) --message="bits $bits"

  run.section "Calibration"

  run.check "applies the calibration after the chip's own corrections":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    calibration := MagCalibration --offset-x=5.0 --offset-y=-3.0 --offset-z=10.0 --scale-x=1.1 --scale-y=0.9 --scale-z=1.0
    sensor := golden-sensor mock case
    sensor.calibration = calibration
    mock.registers.inject-bytes case["bytes"]
    bytes := sensor.read-raw-data
    mag := case["mag"]
    field := sensor.read-mag-compensated bytes
    require-close ((mag[0] - 5.0) * 1.1) field.x MAG-TOLERANCE "x"
    require-close ((mag[1] + 3.0) * 0.9) field.y MAG-TOLERANCE "y"
    require-close (mag[2] - 10.0) field.z MAG-TOLERANCE "z"

  run.check "passes the calibration in through the constructor":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    trim := case["trim"]
    trim.size.repeat: mock.registers.trim[it] = trim[it]
    sensor := new-sensor mock --calibration=(MagCalibration --offset-x=5.0)
    mock.registers.inject-bytes case["bytes"]
    require-close (case["mag"][0] - 5.0) (sensor.read-mag-compensated).x MAG-TOLERANCE "x"

  run.check "never applies it to the raw counts":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    sensor := golden-sensor mock case
    sensor.calibration = MagCalibration --offset-x=5.0
    mock.registers.inject-bytes case["bytes"]
    require-equals case["raw"][0].to-float (sensor.read-mag-raw).x

  run.check "removing the calibration restores the plain reading":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    sensor := golden-sensor mock case
    sensor.calibration = MagCalibration --offset-x=5.0
    sensor.calibration = null
    mock.registers.inject-bytes case["bytes"]
    require-close case["mag"][0] (sensor.read-mag-compensated).x MAG-TOLERANCE "x"

  run.check "keeps disabled axes at zero with a calibration":
    mock := MockBmm150Device
    case := GOLDEN-CASES[0]
    sensor := golden-sensor mock case
    sensor.calibration = MagCalibration --offset-x=5.0 --offset-y=5.0
    sensor.enable-axis --no-x --no-y
    mock.registers.inject-bytes case["bytes"]
    field := sensor.read-mag-compensated
    require-equals 0.0 field.x
    require-equals 0.0 field.y

  run.finish
