// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import io
import serial
import log
import math show Point3f

import .calibration show MagCalibration

/**
Toit driver for the Bosch Sensortec BMM150 magnetometer.

The BMM150 measures the magnetic field on three axes. This driver talks to the
  chip over I2C and reports the field in microtesla (µT). The chip also has an
  SPI interface, which this driver does not implement.

The chip has no temperature output. It measures the resistance of its Hall
  plate instead, and the driver uses that value to correct the field readings
  ("RHALL", datasheet section 4.3).

The constructor powers up the chip, loads its factory trim values, applies a
  preset and starts continuous measurement. After that, $read-mag-compensated
  returns the field with the trim values applied:

```
import i2c
import bmm150

main:
  bus := i2c.Bus --sda=21 --scl=20
  sensor := bmm150.Bmm150 (bus.device bmm150.Bmm150.I2C-ADDRESS)
  print sensor.read-mag-compensated
```

# Calibration
The factory trim values fix errors inside the chip, and the driver applies them
  in $read-mag-compensated. What the rest of the board adds to the field is
  different for every board. Pass a $MagCalibration with the constructor's
  `--calibration` argument and $read-mag-compensated applies that as well.
  $read-mag-raw never does.

# Reading data
Each call to $read-raw-data returns one burst of bytes that holds a single
  measurement: three axes and the Hall resistance. The $read-mag-compensated,
  $read-mag-raw, $read-rhall and $has-overflow methods all accept those bytes.
  Passing the same bytes to several of them keeps every value from the same
  instant. Without an argument, each call takes a fresh measurement.

# Power modes
The chip has four power modes: suspend, sleep, normal and forced. In suspend
  mode the datasheet says "only registers which store power control bit
  information and SPI3 wire enable can be accessed by the user" and "All
  registers lose their content, except the control register (0x4B)" (section
  4.2.2). The driver therefore refuses to touch other registers in suspend
  mode, and it writes its stored settings back when it wakes the chip.

# Inheritance
Registers are one byte wide and the chip sends no dummy bytes, unlike the
  BMM350. $read-register_ and $write-register_ take a mask for single fields.
*/
class Bmm150:
  /** I2C address when the CSB and SDO pins are both low. */
  static I2C-ADDRESS         ::= 0x10

  /** I2C address when the SDO pin is high and the CSB pin is low. */
  static I2C-ADDRESS-SDO     ::= 0x11

  /** I2C address when the CSB pin is high and the SDO pin is low. */
  static I2C-ADDRESS-CSB     ::= 0x12

  /** I2C address when the CSB and SDO pins are both high. */
  static I2C-ADDRESS-CSB-SDO ::= 0x13

  /** Output data rate of 10 Hz. This is the power-on default. */
  static ODR-10HZ ::= 0x00
  /** Output data rate of 2 Hz. */
  static ODR-2HZ  ::= 0x01
  /** Output data rate of 6 Hz. */
  static ODR-6HZ  ::= 0x02
  /** Output data rate of 8 Hz. */
  static ODR-8HZ  ::= 0x03
  /** Output data rate of 15 Hz. */
  static ODR-15HZ ::= 0x04
  /** Output data rate of 20 Hz. */
  static ODR-20HZ ::= 0x05
  /** Output data rate of 25 Hz. */
  static ODR-25HZ ::= 0x06
  /** Output data rate of 30 Hz. */
  static ODR-30HZ ::= 0x07

  /** Preset: 3 repetitions on X/Y and Z at 10 Hz. Lowest current, most noise. */
  static PRESET-LOW-POWER     ::= 0
  /** Preset: 9 repetitions on X/Y and 15 on Z at 10 Hz. */
  static PRESET-REGULAR       ::= 1
  /** Preset: 15 repetitions on X/Y and 27 on Z at 10 Hz. */
  static PRESET-ENHANCED      ::= 2
  /** Preset: 47 repetitions on X/Y and 83 on Z at 20 Hz. Lowest noise. */
  static PRESET-HIGH-ACCURACY ::= 3

  /** Power mode: continuous measurements at the configured rate. */
  static MODE-NORMAL  ::= 0x00
  /** Power mode: one measurement on request, then back to sleep. */
  static MODE-FORCED  ::= 0x01
  /** Power mode: no measurements, all registers readable. */
  static MODE-SLEEP   ::= 0x03
  /** Power mode: lowest power. Settings are lost until the chip wakes. */
  static MODE-SUSPEND ::= 0x04

  /** Interrupt status bit: X below the low threshold. */
  static INT-STATUS-LOW-X     ::= 0b00000001
  /** Interrupt status bit: Y below the low threshold. */
  static INT-STATUS-LOW-Y     ::= 0b00000010
  /** Interrupt status bit: Z below the low threshold. */
  static INT-STATUS-LOW-Z     ::= 0b00000100
  /** Interrupt status bit: X above the high threshold. */
  static INT-STATUS-HIGH-X    ::= 0b00001000
  /** Interrupt status bit: Y above the high threshold. */
  static INT-STATUS-HIGH-Y    ::= 0b00010000
  /** Interrupt status bit: Z above the high threshold. */
  static INT-STATUS-HIGH-Z    ::= 0b00100000
  /** Interrupt status bit: an axis went beyond the measurement range. */
  static INT-STATUS-OVERFLOW  ::= 0b01000000
  /** Interrupt status bit: data was replaced before it was read. */
  static INT-STATUS-OVERRUN   ::= 0b10000000

  static CHIP-ID_ ::= 0x32

  static REG-CHIP-ID_       ::= 0x40
  static REG-DATA-X-LSB_    ::= 0x42
  static REG-RHALL-LSB_     ::= 0x48
  static REG-INT-STATUS_    ::= 0x4A
  static REG-POWER-CONTROL_ ::= 0x4B
  static REG-OP-MODE_       ::= 0x4C
  static REG-INT-CONFIG_    ::= 0x4D
  static REG-AXES-ENABLE_   ::= 0x4E
  static REG-LOW-THRESHOLD_ ::= 0x4F
  static REG-HIGH-THRESHOLD_ ::= 0x50
  static REG-REP-XY_        ::= 0x51
  static REG-REP-Z_         ::= 0x52

  // Masks: $REG-RHALL-LSB_
  static RHALL-DRDY_ ::= 0b00000001

  // Masks: $REG-POWER-CONTROL_
  static POWER-CONTROL-ON_    ::= 0b00000001
  static POWER-CONTROL-RESET_ ::= 0b10000010  // Both soft reset bits.

  // Masks: $REG-OP-MODE_
  static OP-MODE-SELF-TEST_ ::= 0b00000001
  static OP-MODE-MODE_      ::= 0b00000110
  static OP-MODE-ODR_       ::= 0b00111000

  // Masks: $REG-INT-CONFIG_
  static INT-CONFIG-OVERRUN-EN_   ::= 0b10000000  // 1=enabled.
  static INT-CONFIG-OVERFLOW-EN_  ::= 0b01000000  // 1=enabled.
  static INT-CONFIG-HIGH-MASK_    ::= 0b00111000  // Active low, per axis.
  static INT-CONFIG-LOW-MASK_     ::= 0b00000111  // Active low, per axis.

  // Masks: $REG-AXES-ENABLE_
  static AXES-DRDY-PIN-EN_   ::= 0b10000000  // 1=DRDY pin on.
  static AXES-INT-PIN-EN_    ::= 0b01000000  // 1=INT pin on.
  static AXES-DISABLE-Z_     ::= 0b00100000  // 1=Z (and RHALL) off.
  static AXES-DISABLE-Y_     ::= 0b00010000  // 1=Y off.
  static AXES-DISABLE-X_     ::= 0b00001000  // 1=X off.
  static AXES-DRDY-POLARITY_ ::= 0b00000100  // 1=Active high.
  static AXES-INT-LATCH_     ::= 0b00000010  // 1=Latched.
  static AXES-INT-POLARITY_  ::= 0b00000001  // 1=Active high.

  static ENABLE-X_ ::= 0b001
  static ENABLE-Y_ ::= 0b010
  static ENABLE-Z_ ::= 0b100

  // The power-on values of registers 0x4D to 0x52. The chip loses them in
  // suspend mode, so the driver keeps a copy.
  static CONFIG-DEFAULTS_ ::= #[0x3F, 0x07, 0x00, 0x00, 0x00, 0x00]

  // The data registers 0x42 to 0x49.
  static DATA-LENGTH_ ::= 8

  static ODR-HZ_ ::= [10.0, 2.0, 6.0, 8.0, 15.0, 20.0, 25.0, 30.0]

  // Repetitions per preset, as register values: [xy, z, odr]. The values come
  // from the Bosch reference code (bmm150_defs.h). They give the repetition
  // counts of datasheet table 3 when n = 1 + 2 * register is used for both
  // XY and Z.
  static PRESETS_ ::= [
    [0x01, 0x01, ODR-10HZ],  // Low power.
    [0x04, 0x07, ODR-10HZ],  // Regular.
    [0x07, 0x0D, ODR-10HZ],  // Enhanced.
    [0x17, 0x29, ODR-20HZ],  // High accuracy.
  ]

  // Waits. The start-up time is datasheet table 1 (3.0 ms from suspend to
  // sleep). Bosch's code waits 1 ms after a soft reset. The datasheet gives no
  // figure, so the driver waits for the start-up time instead.
  static WAIT-START-UP_    ::= Duration --ms=3
  static WAIT-SOFT-RESET_  ::= Duration --ms=3
  static WAIT-SELF-TEST_   ::= Duration --ms=2
  static SELF-TEST-TIMEOUT_ ::= Duration --ms=100
  static DRDY-TIMEOUT_     ::= Duration --ms=1500
  static DRDY-POLL-MS_     ::= 1

  /**
  The calibration that $read-mag-compensated applies after the chip's own
    corrections, or null for none.

  It can be set or removed at any time. A calibration belongs to the whole
    assembly, not to the chip alone.
  */
  calibration/MagCalibration? := null

  dev_/serial.Device
  reg_/serial.Registers
  logger_/log.Logger
  trim_/Bmm150Trim
  axes_/int := ENABLE-X_ | ENABLE-Y_ | ENABLE-Z_
  odr_/int := ODR-10HZ
  suspended_/bool := false
  config_/ByteArray := CONFIG-DEFAULTS_.copy

  /**
  Powers up the chip and starts continuous measurement.

  Measurement runs in normal mode. The $preset sets the number of repetitions
    per measurement and a matching output data rate. Pass one of the PRESET
    constants, such as $PRESET-REGULAR. Pass an $odr, such as $ODR-25HZ, to
    replace the preset's rate. Repetitions work like averaging: more of them
    lower the noise and raise the current.

  With a $calibration, $read-mag-compensated also corrects the field for the
    board the chip sits on. Leave it out to get the field as the chip reports
    it, with only the factory corrections.

  The constructor resets the chip's settings to their power-on values first.

  Throws an exception if the chip does not answer with the BMM150 chip ID.
  */
  constructor device/serial.Device
      --preset/int=PRESET-REGULAR
      --odr/int?=null
      --calibration/MagCalibration?=null
      --logger/log.Logger=log.default:
    this.calibration = calibration
    dev_ = device
    reg_ = device.registers
    logger_ = logger.with-name "bmm150"

    // The sequence follows bmm150_init in the Bosch reference code: power up,
    // wait for the start-up time, check the chip ID and read the trim values.
    reg_.write-u8 REG-POWER-CONTROL_ POWER-CONTROL-ON_
    sleep WAIT-START-UP_
    id := reg_.read-u8 REG-CHIP-ID_
    if id != CHIP-ID_:
      throw "Unexpected chip id [0x$(%02x id)]"
    logger_.info "BMM150 chip id" --tags={"id": "0x$(%02x id)"}

    // A previous program may have left the chip in any state, so start from
    // the power-on values. The reset keeps the trim registers.
    reg_.write-u8 REG-POWER-CONTROL_ (POWER-CONTROL-ON_ | POWER-CONTROL-RESET_)
    sleep WAIT-SOFT-RESET_
    trim_ = read-trim_ reg_

    set-preset preset
    if odr: set-odr odr
    set-mode MODE-NORMAL

  /**
  Reads the chip ID.

  Returns 0x32 for a BMM150. The chip only answers when it is not in suspend
    mode, so the driver throws in suspend mode.
  */
  get-chip-id -> int:
    return read-register_ REG-CHIP-ID_

  /**
  Resets the chip to its power-on settings and leaves it in sleep mode.

  The trim values stay valid. Call $set-preset or $set-odr, and then $set-mode,
    to resume measuring. The reset also clears the interrupt settings and turns
    all axes back on.

  The chip ignores a soft reset in suspend mode, so the driver wakes it first.
  */
  soft-reset -> none:
    if suspended_: wake_
    reg_.write-u8 REG-POWER-CONTROL_ (POWER-CONTROL-ON_ | POWER-CONTROL-RESET_)
    sleep WAIT-SOFT-RESET_
    config_ = CONFIG-DEFAULTS_.copy
    odr_ = ODR-10HZ
    axes_ = ENABLE-X_ | ENABLE-Y_ | ENABLE-Z_

  /**
  Sets the power mode to $MODE-NORMAL, $MODE-FORCED, $MODE-SLEEP or
    $MODE-SUSPEND.

  The chip leaves suspend mode first when needed, which takes the start-up
    time of 3 ms (datasheet table 1 lists 3.0 ms). After a suspend, the chip has
    lost its settings, and the driver writes back the ones it keeps. Those are
    the output data rate, the repetitions, the axes, the thresholds and the
    interrupt settings.

  In forced mode the chip takes one measurement and returns to sleep mode. Read
    the result with $read-raw-data afterwards, which waits for it. The datasheet
    says this is "useful to achieve synchronized operation between host
    microcontroller and BMM150" (section 4.2.4). The driver reads the data
    registers once before it starts, so an unread result from before cannot
    pass for the new one.
  */
  set-mode mode/int -> none:
    if mode != MODE-NORMAL and mode != MODE-FORCED and mode != MODE-SLEEP and mode != MODE-SUSPEND:
      throw "Unsupported power mode $mode"

    if mode == MODE-SUSPEND:
      reg_.write-u8 REG-POWER-CONTROL_ 0
      suspended_ = true
      logger_.debug "mode configured" --tags={"mode": "suspend"}
      return

    if suspended_: wake_
    if mode == MODE-FORCED:
      // The datasheet starts forced measurements from sleep mode.
      write-register_ REG-OP-MODE_ MODE-SLEEP --mask=OP-MODE-MODE_
      // Reading the data registers clears a data ready flag left over.
      reg_.read-bytes REG-DATA-X-LSB_ DATA-LENGTH_
    write-register_ REG-OP-MODE_ mode --mask=OP-MODE-MODE_
    logger_.debug "mode configured" --tags={"mode": mode}

  /**
  Reads the power mode from the chip.

  Returns $MODE-NORMAL, $MODE-FORCED, $MODE-SLEEP or $MODE-SUSPEND. A chip that
    has finished a forced measurement reports $MODE-SLEEP.
  */
  get-mode -> int:
    if ((reg_.read-u8 REG-POWER-CONTROL_) & POWER-CONTROL-ON_) == 0: return MODE-SUSPEND
    return read-register_ REG-OP-MODE_ --mask=OP-MODE-MODE_

  // Powers the chip up from suspend and writes back the settings the driver keeps.
  wake_ -> none:
    reg_.write-u8 REG-POWER-CONTROL_ POWER-CONTROL-ON_
    sleep WAIT-START-UP_
    suspended_ = false
    reg_.write-u8 REG-OP-MODE_ ((odr_ << OP-MODE-ODR_.count-trailing-zeros) | (MODE-SLEEP << OP-MODE-MODE_.count-trailing-zeros))
    config_.size.repeat: | index |
      reg_.write-u8 (REG-INT-CONFIG_ + index) config_[index]

  /**
  Sets the output data rate to $odr, one of the ODR constants.

  In normal mode the chip measures at this rate. The rate only helps if one
    measurement fits into the period. See $measurement-time-us.
  */
  set-odr odr/int=ODR-10HZ -> none:
    if not 0 <= odr < ODR-HZ_.size: throw "Invalid output data rate $odr"
    write-register_ REG-OP-MODE_ odr --mask=OP-MODE-ODR_
    odr_ = odr

  /**
  Reads the output data rate from the chip.

  Returns one of the ODR constants, such as $ODR-25HZ.
  */
  get-odr -> int:
    return read-register_ REG-OP-MODE_ --mask=OP-MODE-ODR_

  /**
  Returns the rate in Hz for one of the ODR constants.
  */
  static odr-to-hz odr/int -> float:
    return ODR-HZ_[odr]

  /**
  Sets the repetitions and the output data rate of one of the presets.

  Pass one of $PRESET-LOW-POWER, $PRESET-REGULAR, $PRESET-ENHANCED or
    $PRESET-HIGH-ACCURACY. Datasheet table 3 lists their noise and current.
    The register values come from the Bosch reference code.
  */
  set-preset preset/int=PRESET-REGULAR -> none:
    if not 0 <= preset < PRESETS_.size: throw "Invalid preset $preset"
    values := PRESETS_[preset]
    write-register_ REG-REP-XY_ values[0]
    write-register_ REG-REP-Z_ values[1]
    set-odr values[2]

  /**
  Sets the number of repetitions per measurement on X and Y, and on Z.

  More repetitions lower the noise and raise the current. The counts $xy and
    $z must be odd and between 1 and 511.

  Assumption: the chip counts $z the same way as $xy, as 1 + 2 * register. The
    datasheet's register description for Z gives nZ = 1 + REPZ (section 5.8),
    but its preset table (table 3) and Bosch's reference code only fit
    1 + 2 * REPZ. This driver follows the preset table. The hardware test
    compares the two readings against a measured time.
  */
  set-repetitions --xy/int --z/int -> none:
    if not (1 <= xy <= 511 and xy % 2 == 1): throw "Invalid X/Y repetitions $xy"
    if not (1 <= z <= 511 and z % 2 == 1): throw "Invalid Z repetitions $z"
    write-register_ REG-REP-XY_ (xy - 1) / 2
    write-register_ REG-REP-Z_ (z - 1) / 2

  /** Reads the number of repetitions on X and Y from the chip. */
  get-repetitions-xy -> int:
    return 1 + 2 * (read-register_ REG-REP-XY_)

  /**
  Reads the number of repetitions on Z from the chip.

  See $set-repetitions for how this count is worked out.
  */
  get-repetitions-z -> int:
    return 1 + 2 * (read-register_ REG-REP-Z_)

  /**
  Returns the time one measurement takes, in microseconds, for the repetition
    counts $xy and $z.

  The datasheet gives the highest read-out rate in forced mode as
    f max,ODR ≈ 1 / (145 µs × nXY + 500 µs × nZ + 980 µs), written here on one
    line (section 4.2.4). This is the denominator of that formula, and it is an
    approximation.
  */
  static measurement-time-us xy/int z/int -> int:
    return 145 * xy + 500 * z + 980

  /**
  Turns the measurement of individual axes on or off.

  Disabled axes read as 0.0 from $read-mag-compensated and $read-mag-raw.

  The Z axis always stays on. The datasheet says that "If the Z channel is
    disabled, the resistance measurement will also be disabled and the
    resistance output value will be set to zero" (section 5.7), and the X and Y
    corrections need that resistance.
  */
  enable-axis --x/bool=true --y/bool=true -> none:
    // The channel bits are active low. Bit 0 of the field is X, bit 1 is Y, and
    // bit 2 is Z, which stays on.
    value := 0
    if not x: value |= 0b001
    if not y: value |= 0b010
    write-register_ REG-AXES-ENABLE_ value --mask=(AXES-DISABLE-X_ | AXES-DISABLE-Y_ | AXES-DISABLE-Z_)
    axes_ = ENABLE-Z_
    if x: axes_ |= ENABLE-X_
    if y: axes_ |= ENABLE-Y_

  /**
  Reads one measurement as raw bytes.

  The 8 bytes hold the registers 0x42 to 0x49: X, Y and Z, then the Hall
    resistance and the data ready flag. They come from a single burst read, so
    they all belong to the same measurement. The datasheet recommends this:
    "it is recommended to read out at all data at once (0x42 to 0x49 or 0x4A if
    status bits are also required) with a burst read" (section 4.3.1). Pass
    them to $read-mag-compensated, $read-mag-raw, $read-rhall or $has-overflow
    to convert them.

  With $wait set, which is the default, this waits for the data ready flag and
    throws if it stays low for 1.5 seconds, which is what happens in sleep or
    suspend mode. With $wait off, it returns whatever the data registers hold
    at that moment. Use that when the DRDY pin has told you that a measurement
    is ready.
  */
  read-raw-data --wait/bool=true -> ByteArray:
    if not wait: return reg_.read-bytes REG-DATA-X-LSB_ DATA-LENGTH_
    deadline := Time.monotonic-us + DRDY-TIMEOUT_.in-us
    while true:
      bytes := reg_.read-bytes REG-DATA-X-LSB_ DATA-LENGTH_
      if (bytes[6] & RHALL-DRDY_) != 0: return bytes
      if Time.monotonic-us > deadline:
        throw "BMM150 data ready timeout (is it in sleep mode?)"
      sleep --ms=DRDY-POLL-MS_

  /**
  Whether a new measurement is ready.

  The flag clears when the data registers are read, and reading this register
    counts. The measurement stays in the data registers.
  */
  is-data-ready -> bool:
    return (read-register_ REG-RHALL-LSB_ --mask=RHALL-DRDY_) == 1

  /**
  Reads the magnetic field in µT, corrected with the chip's trim values.

  The corrections use the trim values stored in the chip. The math follows the
    Bosch reference code. They are not part of the datasheet, which only says
    that the Bosch driver does the compensation (section 4.3.2). If a
    $calibration is set, it is applied last. Disabled axes (see $enable-axis)
    read as 0.0, with or without a calibration.

  Throws an exception if an enabled axis is out of range. The datasheet says
    that the data register "is saturated to the most negative value" then
    (section 4.6.6). Use $has-overflow to test for that first.
  */
  read-mag-compensated bytes/ByteArray=read-raw-data -> Point3f:
    raw := parse_ bytes
    if has-overflow bytes: throw "BMM150 measurement out of range"
    rhall := raw[3]
    x := (axes_ & ENABLE-X_) != 0 ? trim_.compensate-x raw[0] rhall : 0.0
    y := (axes_ & ENABLE-Y_) != 0 ? trim_.compensate-y raw[1] rhall : 0.0
    z := trim_.compensate-z raw[2] rhall
    if x == null or y == null or z == null:
      throw "BMM150 measurement cannot be compensated"
    board := calibration
    if board:
      corrected := board.apply x y z
      x = (axes_ & ENABLE-X_) != 0 ? corrected.x : 0.0
      y = (axes_ & ENABLE-Y_) != 0 ? corrected.y : 0.0
      z = corrected.z
    return Point3f x y z

  /**
  Reads the raw X, Y and Z counts, with no corrections at all.

  The values are counts of the chip's data registers, not µT. Use
    $read-mag-compensated for readings that are meant to be accurate. This
    version is cheaper and is useful for comparing against the compensated
    values. Disabled axes (see $enable-axis) read as 0.0.
  */
  read-mag-raw bytes/ByteArray=read-raw-data -> Point3f:
    raw := parse_ bytes
    x := (axes_ & ENABLE-X_) != 0 ? raw[0].to-float : 0.0
    y := (axes_ & ENABLE-Y_) != 0 ? raw[1].to-float : 0.0
    return Point3f x y raw[2].to-float

  /**
  Reads the Hall resistance of a measurement, as a 14-bit count.

  The trim corrections use it. It is zero when Z is off.
  */
  read-rhall bytes/ByteArray=read-raw-data -> int:
    return (parse_ bytes)[3]

  /**
  Whether an enabled axis of the measurement went out of range.

  The datasheet gives the saturated values as -4096 for X and Y and -16384 for
    Z (section 4.6.6). The Hall resistance counts as out of range when it is
    zero, since the corrections cannot use it.
  */
  has-overflow bytes/ByteArray=read-raw-data -> bool:
    raw := parse_ bytes
    if (axes_ & ENABLE-X_) != 0 and raw[0] == Bmm150Trim.OVERFLOW-RAW-XY_: return true
    if (axes_ & ENABLE-Y_) != 0 and raw[1] == Bmm150Trim.OVERFLOW-RAW-XY_: return true
    return raw[2] == Bmm150Trim.OVERFLOW-RAW-Z_ or raw[3] == 0

  // Splits the data bytes into signed X, Y and Z counts and the Hall resistance.
  parse_ bytes/ByteArray -> List:
    assert: bytes.size >= DATA-LENGTH_
    // X and Y have 13 bits: 5 in the first byte (bits 7 to 3), 8 in the second.
    x := ((io.LITTLE-ENDIAN.int8 bytes 1) << 5) | (bytes[0] >> 3)
    y := ((io.LITTLE-ENDIAN.int8 bytes 3) << 5) | (bytes[2] >> 3)
    // Z has 15 bits: 7 in the first byte (bits 7 to 1), 8 in the second.
    z := ((io.LITTLE-ENDIAN.int8 bytes 5) << 7) | (bytes[4] >> 1)
    // The Hall resistance has 14 bits: 6 in the first byte (bits 7 to 2).
    rhall := (bytes[7] << 6) | (bytes[6] >> 2)
    return [x, y, z, rhall]

  /**
  Turns the DRDY pin output on or off.

  The pin goes high when a new measurement is ready and drops when the data
    registers are read. It is not latched. It floats while it is off.
  */
  set-drdy-pin enabled/bool -> none:
    write-register_ REG-AXES-ENABLE_ (enabled ? 1 : 0) --mask=AXES-DRDY-PIN-EN_

  /** Whether the DRDY pin output is on. */
  is-drdy-pin-set -> bool:
    return (read-register_ REG-AXES-ENABLE_ --mask=AXES-DRDY-PIN-EN_) == 1

  /**
  Sets the DRDY pin to active-high when $high is true, or active-low when it is
    false.

  Active-high is the default.
  */
  set-drdy-pin-polarity high/bool -> none:
    write-register_ REG-AXES-ENABLE_ (high ? 1 : 0) --mask=AXES-DRDY-POLARITY_

  /**
  Turns the INT pin output on or off.

  The pin reports the threshold and overflow interrupts. It floats while it is
    off.
  */
  set-int-pin enabled/bool -> none:
    write-register_ REG-AXES-ENABLE_ (enabled ? 1 : 0) --mask=AXES-INT-PIN-EN_

  /** Whether the INT pin output is on. */
  is-int-pin-set -> bool:
    return (read-register_ REG-AXES-ENABLE_ --mask=AXES-INT-PIN-EN_) == 1

  /**
  Sets the INT pin to active-high when $high is true, or active-low when it is
    false.

  Active-high is the default.
  */
  set-int-pin-polarity high/bool -> none:
    write-register_ REG-AXES-ENABLE_ (high ? 1 : 0) --mask=AXES-INT-POLARITY_

  /**
  Sets the INT pin to stay asserted until $read-interrupt-status is called when
    $latched is true, or to follow the condition when it is false.

  Latched is the default.

  The datasheet is not consistent about where this bit lives. Section 4.6.1
    says "register 0x4A bit1", and table 20 and the Bosch reference code say
    register 0x4E bit1. This driver follows the table.
  */
  set-int-latched-mode latched/bool -> none:
    write-register_ REG-AXES-ENABLE_ (latched ? 1 : 0) --mask=AXES-INT-LATCH_

  /**
  Reads the interrupt status register.

  Returns a combination of the INT-STATUS bits, such as $INT-STATUS-OVERFLOW.
    Reading it releases a latched INT pin.
  */
  read-interrupt-status -> int:
    return read-register_ REG-INT-STATUS_

  /**
  Turns the overflow interrupt on or off.

  The datasheet describes the setting as "Activates mapping of Overflow flag
    status to the INT pin" (table 19).
  */
  set-overflow-interrupt enabled/bool -> none:
    write-register_ REG-INT-CONFIG_ (enabled ? 1 : 0) --mask=INT-CONFIG-OVERFLOW-EN_

  /**
  Turns data overrun reporting on or off.

  With it on, $INT-STATUS-OVERRUN shows when the chip replaced a measurement
    that nobody had read.
  */
  set-overrun-flag enabled/bool -> none:
    write-register_ REG-INT-CONFIG_ (enabled ? 1 : 0) --mask=INT-CONFIG-OVERRUN-EN_

  /**
  Turns on the low threshold interrupt for the chosen axes.

  An axis triggers when its raw value drops below $threshold times 16. The
    datasheet says "one bit in 'Low Threshold' corresponds to roughly 6µT (not
    exactly, as the raw magnetic field values DATAX, DATAY and DATAZ are not
    temperature compensated)" (section 4.6.4). The $threshold is a signed
    8-bit number.

  Assumption: the register is signed. The datasheet does not say, and
    Bosch's code stores the value in an unsigned byte. A negative low
    threshold only makes sense if the chip treats the byte as signed.
  */
  enable-low-threshold-interrupt threshold/int --x/bool=true --y/bool=true --z/bool=true -> none:
    if not -128 <= threshold <= 127: throw "Invalid threshold $threshold"
    write-register_ REG-LOW-THRESHOLD_ (threshold & 0xFF)
    // The enable bits are active low.
    value := 0
    if not x: value |= 0b001
    if not y: value |= 0b010
    if not z: value |= 0b100
    write-register_ REG-INT-CONFIG_ value --mask=INT-CONFIG-LOW-MASK_

  /** Turns off the low threshold interrupt on all axes. */
  disable-low-threshold-interrupt -> none:
    write-register_ REG-INT-CONFIG_ 0b111 --mask=INT-CONFIG-LOW-MASK_

  /**
  Turns on the high threshold interrupt for the chosen axes.

  An axis triggers when its raw value rises above $threshold times 16. See
    $enable-low-threshold-interrupt for the scale and for the assumption about
    the sign.
  */
  enable-high-threshold-interrupt threshold/int --x/bool=true --y/bool=true --z/bool=true -> none:
    if not -128 <= threshold <= 127: throw "Invalid threshold $threshold"
    write-register_ REG-HIGH-THRESHOLD_ (threshold & 0xFF)
    value := 0
    if not x: value |= 0b001
    if not y: value |= 0b010
    if not z: value |= 0b100
    write-register_ REG-INT-CONFIG_ value --mask=INT-CONFIG-HIGH-MASK_

  /** Turns off the high threshold interrupt on all axes. */
  disable-high-threshold-interrupt -> none:
    write-register_ REG-INT-CONFIG_ 0b111 --mask=INT-CONFIG-HIGH-MASK_

  /**
  Runs the chip's normal self-test.

  Returns true when X, Y and Z all pass. The datasheet describes it as a check
    of "FlipCore (X and Y) connection to ASIC", the Hall sensor connections and
    the signal path (section 4.4.1). The advanced self-test is not implemented.

  The test needs sleep mode, so this leaves the chip in sleep mode. Call
    $set-mode afterwards to measure again.
  */
  self-test -> bool:
    set-mode MODE-SLEEP
    write-register_ REG-OP-MODE_ 1 --mask=OP-MODE-SELF-TEST_
    sleep WAIT-SELF-TEST_
    // The chip clears the bit when the test is over.
    deadline := Time.monotonic-us + SELF-TEST-TIMEOUT_.in-us
    while (read-register_ REG-OP-MODE_ --mask=OP-MODE-SELF-TEST_) == 1:
      if Time.monotonic-us > deadline: throw "BMM150 self-test timeout"
      sleep --ms=1
    // Each result flag is bit 0 of the LSB register of an axis.
    bytes := reg_.read-bytes REG-DATA-X-LSB_ 5
    passed-x := (bytes[0] & 1) == 1
    passed-y := (bytes[2] & 1) == 1
    passed-z := (bytes[4] & 1) == 1
    logger_.debug "self-test" --tags={"x": passed-x, "y": passed-y, "z": passed-z}
    return passed-x and passed-y and passed-z

  // Reads the trim registers 0x5D to 0x71. The reads follow the Bosch code,
  // which skips the registers in between.
  static read-trim_ reg/serial.Registers -> Bmm150Trim:
    bytes := ByteArray Bmm150Trim.LENGTH
    first := Bmm150Trim.FIRST-REGISTER
    bytes.replace 0 (reg.read-bytes 0x5D 2)
    bytes.replace (0x62 - first) (reg.read-bytes 0x62 4)
    bytes.replace (0x68 - first) (reg.read-bytes 0x68 10)
    return Bmm150Trim.from-registers bytes

  /*
  Reads and optionally masks register data.

  The chip answers nothing useful for most registers in suspend mode, so this
    throws there instead of returning zeros.
  */
  read-register_ register/int --mask/int=0xFF -> int:
    if suspended_ and register != REG-POWER-CONTROL_:
      throw "BMM150 is in suspend mode, call set-mode first"
    return ((reg_.read-u8 register) & mask) >> mask.count-trailing-zeros

  /*
  Writes register data, either as a full register write or as a masked
    read-modify-write.

  Registers 0x4D to 0x52 are copied to $config_ as well, to restore them after
    a suspend.
  */
  write-register_ register/int value/int --mask/int=0xFF -> none:
    if suspended_ and register != REG-POWER-CONTROL_:
      throw "BMM150 is in suspend mode, call set-mode first"
    offset := mask.count-trailing-zeros
    field-mask := mask >> offset
    assert: 0 <= value and value <= field-mask
    new-value := value
    if mask != 0xFF:
      old-value := reg_.read-u8 register
      new-value = (old-value & ~mask) | ((value & field-mask) << offset)
    reg_.write-u8 register new-value
    if REG-INT-CONFIG_ <= register and register <= REG-REP-Z_:
      config_[register - REG-INT-CONFIG_] = new-value

/**
The factory trim values of a BMM150, and the math that applies them.

The chip keeps 21 bytes of trim data in the registers 0x5D to 0x71. The
  datasheet only says that the Bosch driver reads them and does the
  compensation (sections 4.3.2 and 4.5). The register layout and the formulas
  here follow Bosch's reference code (bmm150.c, the floating-point version).

The $Bmm150 class fills one of these from the chip at construction. Tests can
  build one from bytes with $Bmm150Trim.from-registers.
*/
class Bmm150Trim:
  // Raw values that mean the axis went out of range (datasheet section 4.6.6).
  static OVERFLOW-RAW-XY_ ::= -4096
  static OVERFLOW-RAW-Z_  ::= -16384

  /** The number of bytes from register 0x5D to register 0x71. */
  static LENGTH ::= 21
  /** The address of the first trim register. */
  static FIRST-REGISTER ::= 0x5D

  /** Trim value dig_x1, a signed byte. */
  x1/int
  /** Trim value dig_y1, a signed byte. */
  y1/int
  /** Trim value dig_x2, a signed byte. */
  x2/int
  /** Trim value dig_y2, a signed byte. */
  y2/int
  /** Trim value dig_z1, an unsigned 16-bit number. */
  z1/int
  /** Trim value dig_z2, a signed 16-bit number. */
  z2/int
  /** Trim value dig_z3, a signed 16-bit number. */
  z3/int
  /** Trim value dig_z4, a signed 16-bit number. */
  z4/int
  /** Trim value dig_xy1, an unsigned byte. */
  xy1/int
  /** Trim value dig_xy2, a signed byte. */
  xy2/int
  /** Trim value dig_xyz1, a 15-bit number. */
  xyz1/int

  /**
  Decodes the $bytes read from registers 0x5D to 0x71.

  The byte at index 0 is register 0x5D. Bytes for registers that hold no trim
    value are ignored.
  */
  constructor.from-registers bytes/ByteArray:
    assert: bytes.size == LENGTH
    x1 = io.LITTLE-ENDIAN.int8 bytes 0x00      // 0x5D.
    y1 = io.LITTLE-ENDIAN.int8 bytes 0x01      // 0x5E.
    z4 = io.LITTLE-ENDIAN.int16 bytes 0x05     // 0x62 and 0x63.
    x2 = io.LITTLE-ENDIAN.int8 bytes 0x07      // 0x64.
    y2 = io.LITTLE-ENDIAN.int8 bytes 0x08      // 0x65.
    z2 = io.LITTLE-ENDIAN.int16 bytes 0x0B     // 0x68 and 0x69.
    z1 = io.LITTLE-ENDIAN.uint16 bytes 0x0D    // 0x6A and 0x6B.
    xyz1 = (io.LITTLE-ENDIAN.uint16 bytes 0x0F) & 0x7FFF  // 0x6C and 0x6D.
    z3 = io.LITTLE-ENDIAN.int16 bytes 0x11     // 0x6E and 0x6F.
    xy2 = io.LITTLE-ENDIAN.int8 bytes 0x13     // 0x70.
    xy1 = bytes[0x14]                          // 0x71.

  /**
  Returns the corrected X field in µT for the raw X count $raw and the Hall
    resistance $rhall, or null if the chip reported an overflow.
  */
  compensate-x raw/int rhall/int -> float?:
    return compensate-xy_ raw rhall x1 x2

  /**
  Returns the corrected Y field in µT for the raw Y count $raw and the Hall
    resistance $rhall, or null if the chip reported an overflow.
  */
  compensate-y raw/int rhall/int -> float?:
    return compensate-xy_ raw rhall y1 y2

  // X and Y use the same formula with their own pair of trim values.
  compensate-xy_ raw/int rhall/int offset-trim/int gain-trim/int -> float?:
    if raw == OVERFLOW-RAW-XY_ or rhall == 0 or xyz1 == 0: return null
    r := xyz1 * 16384.0 / rhall - 16384.0
    p1 := xy2 * (r * r / 268435456.0)
    p2 := p1 + r * xy1 / 16384.0
    p3 := gain-trim + 160.0
    p4 := raw * ((p2 + 256.0) * p3)
    return (p4 / 8192.0 + offset-trim * 8.0) / 16.0

  /**
  Returns the corrected Z field in µT for the raw Z count $raw and the Hall
    resistance $rhall, or null if the chip reported an overflow.
  */
  compensate-z raw/int rhall/int -> float?:
    if raw == OVERFLOW-RAW-Z_ or z2 == 0 or z1 == 0 or xyz1 == 0 or rhall == 0:
      return null
    p0 := (raw - z4).to-float
    p1 := (rhall - xyz1).to-float
    p2 := z3 * p1
    p3 := z1 * rhall / 32768.0
    p4 := z2 + p3
    p5 := p0 * 131072.0 - p2
    return (p5 / (p4 * 4.0)) / 16.0

  stringify -> string:
    return "x1=$x1 y1=$y1 x2=$x2 y2=$y2 z1=$z1 z2=$z2 z3=$z3 z4=$z4 xy1=$xy1 xy2=$xy2 xyz1=$xyz1"
