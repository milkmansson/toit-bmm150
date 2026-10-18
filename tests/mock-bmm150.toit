// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import serial

/**
A simulated BMM150 register file, for testing the driver without hardware.

The simulation follows the datasheet and the Bosch Sensortec reference code:
- In suspend mode only the power control register answers. The chip ID reads
  as 0x00 and every other write is ignored. When the chip goes into suspend
  mode, the other registers lose their contents, except the trim values.
- A soft reset needs both reset bits, brings the chip into sleep mode, and
  keeps the power control bit and the trim values.
- Reading any data register clears the data ready flag.
- A forced measurement stores a sample and sets the operation mode back to
  sleep.
- A disabled axis keeps its last value in the data registers, and a disabled Z
  axis takes the Hall resistance to zero.

It does not model the analog side. Tests choose the raw counts themselves.

The simulation produces samples against the real clock in normal mode, so rate
  tests need real time to pass.
*/
class MockBmm150Registers extends serial.Registers:
  static CHIP-ID ::= 0x32

  regs_/ByteArray := ByteArray 0x80
  powered_/bool := false
  normal-next-us_/int := 0
  drdy_/bool := false
  selftest-results_/int := 0b111

  /** Every register write as `[register, value]`, oldest first. */
  writes/List := []

  /** The trim registers 0x5D to 0x71, served as they are. */
  trim/ByteArray := ByteArray 21

  /** Raw counts for the next sample. */
  raw-x/int := 0
  raw-y/int := 0
  raw-z/int := 0
  raw-rhall/int := 5700

  /** The chip ID the chip answers with once it is powered. */
  chip-id/int := CHIP-ID

  /** The number of soft resets the chip has seen. */
  reset-count/int := 0

  /** The number of samples the chip has stored. */
  sample-count/int := 0

  constructor:
    super
    reset-registers_

  reset-registers_ -> none:
    regs_.fill 0
    regs_[0x4C] = 0x06  // Sleep mode, 10 Hz.
    regs_[0x4D] = 0x3F
    regs_[0x4E] = 0x07
    drdy_ = false

  /** Reads a register without any side effects, for assertions. */
  peek register/int -> int:
    return regs_[register]

  /** Overwrites a register directly, for setting up a test. */
  poke register/int value/int -> none:
    regs_[register] = value

  /** Whether the chip is powered, which means it is not in suspend mode. */
  is-powered -> bool: return powered_

  /** The operation mode bits of register 0x4C. */
  op-mode -> int: return (regs_[0x4C] >> 1) & 0b11

  /** Whether a measurement waits to be read. */
  is-data-pending -> bool: return drdy_

  /** Makes the self-test report the given result bits: X is 1, Y is 2, Z is 4. */
  set-self-test-results bits/int -> none:
    selftest-results_ = bits

  /** The output data rate in Hz, from register 0x4C. */
  odr-hz -> float:
    return [10.0, 2.0, 6.0, 8.0, 15.0, 20.0, 25.0, 30.0][(regs_[0x4C] >> 3) & 0b111]

  /**
  Stores a sample now, as if the conversion just finished.

  Uses $raw-x, $raw-y, $raw-z and $raw-rhall.
  */
  inject-sample -> none:
    store-sample_

  /** Stores the given 8 bytes as the data registers 0x42 to 0x49. */
  inject-bytes bytes/ByteArray -> none:
    assert: bytes.size == 8
    bytes.size.repeat: regs_[0x42 + it] = bytes[it]
    drdy_ = true
    sample-count++

  store-sample_ -> none:
    enabled-x := (regs_[0x4E] & 0b00001000) == 0
    enabled-y := (regs_[0x4E] & 0b00010000) == 0
    enabled-z := (regs_[0x4E] & 0b00100000) == 0
    // The self-test flags in bit 0 stay as they are.
    if enabled-x:
      regs_[0x42] = ((raw-x & 0x1F) << 3) | (regs_[0x42] & 1)
      regs_[0x43] = (raw-x >> 5) & 0xFF
    if enabled-y:
      regs_[0x44] = ((raw-y & 0x1F) << 3) | (regs_[0x44] & 1)
      regs_[0x45] = (raw-y >> 5) & 0xFF
    if enabled-z:
      regs_[0x46] = ((raw-z & 0x7F) << 1) | (regs_[0x46] & 1)
      regs_[0x47] = (raw-z >> 7) & 0xFF
      regs_[0x48] = (regs_[0x48] & 0b11) | ((raw-rhall & 0x3F) << 2)
      regs_[0x49] = (raw-rhall >> 6) & 0xFF
    else:
      regs_[0x48] = regs_[0x48] & 0b11
      regs_[0x49] = 0
    drdy_ = true
    sample-count++

  /** Produces a sample when one is due, based on the real clock. */
  advance_ -> none:
    if not powered_ or op-mode != 0: return
    now := Time.monotonic-us
    if now < normal-next-us_: return
    store-sample_
    period := (1_000_000.0 / odr-hz).to-int
    normal-next-us_ += period
    if normal-next-us_ < now: normal-next-us_ = now + period

  read-bytes register/int count/int -> ByteArray:
    advance_
    result := ByteArray count
    touched-data := false
    count.repeat:
      address := register + it
      result[it] = read-register_ address
      if 0x42 <= address and address <= 0x49: touched-data = true
    // Reading a data register clears the flag after the read is over.
    if touched-data: drdy_ = false
    return result

  read-register_ register/int -> int:
    if not powered_ and register != 0x4B: return 0
    if 0x5D <= register and register <= 0x71: return trim[register - 0x5D]
    if register == 0x40: return chip-id
    if register == 0x48: return regs_[0x48] | (drdy_ ? 1 : 0)
    if register == 0x4B: return regs_[0x4B]
    return regs_[register]

  write-bytes register/int data/ByteArray -> none:
    data.size.repeat:
      writes.add [register + it, data[it]]
      write-register_ (register + it) data[it]

  write-register_ register/int value/int -> none:
    if register == 0x4B:
      write-power-control_ value
      return
    if not powered_: return  // Ignored in suspend mode.
    if register == 0x4C:
      write-op-mode_ value
      return
    if 0x40 <= register and register <= 0x4A: return  // Read-only.
    regs_[register] = value

  write-power-control_ value/int -> none:
    was-powered := powered_
    powered_ = (value & 1) == 1
    if was-powered and not powered_:
      // Suspend mode: the registers lose their contents.
      reset-registers_
    if not was-powered and powered_:
      reset-registers_
    // Both reset bits together reset the chip, and the chip ignores them in
    // suspend mode.
    if powered_ and (value & 0b10000010) == 0b10000010:
      reset-count++
      reset-registers_
    regs_[0x4B] = value & 0b00000101  // The reset bits clear themselves.

  write-op-mode_ value/int -> none:
    mode := (value >> 1) & 0b11
    regs_[0x4C] = value & 0xFE  // The self-test bit clears itself below.
    if (value & 1) == 1:
      // Self-test needs sleep mode. The result goes into bit 0 of the LSB
      // registers of X, Y and Z.
      if mode == 0b11:
        regs_[0x42] = (regs_[0x42] & 0xFE) | (selftest-results_ & 1)
        regs_[0x44] = (regs_[0x44] & 0xFE) | ((selftest-results_ >> 1) & 1)
        regs_[0x46] = (regs_[0x46] & 0xFE) | ((selftest-results_ >> 2) & 1)
    if mode == 0b00:
      normal-next-us_ = Time.monotonic-us + (1_000_000.0 / odr-hz).to-int
    else if mode == 0b01:
      store-sample_
      regs_[0x4C] = (regs_[0x4C] & ~0b110) | (0b11 << 1)  // Back to sleep.

/**
A $serial.Device wrapper around $MockBmm150Registers.
*/
class MockBmm150Device implements serial.Device:
  registers/MockBmm150Registers

  constructor:
    registers = MockBmm150Registers

  read amount/int -> ByteArray:
    throw "UNIMPLEMENTED"

  write bytes/ByteArray -> none:
    throw "UNIMPLEMENTED"
