# Tests for the BMM150 driver

These tests are for people working on the driver. Using the driver does not need
them. There are three kinds: tests that run without any hardware, a test that runs
on a board with the chip attached, and tests for the calibration maths.

The files in this folder:

- `bmm150-mock-test.toit` runs the driver against a simulated chip.
- `mock-bmm150.toit` is the simulated chip.
- `golden-vectors.toit` holds numbers from Bosch's own sensor API, and
  `golden/bmm150-golden.c` is the program that makes them.
- `calibration-test.toit` checks the calibration maths.
- `bmm150-hardware-test.toit` runs on a real board.
- `test-helpers.toit` is a small test runner shared by the mock and hardware
  tests.

Everything runs from this folder. The first time, the packages need installing:

```
toit pkg install
```

## Without hardware

```
toit bmm150-mock-test.toit
```

The mock test runs against a simulated chip in `mock-bmm150.toit`. The
simulation answers nothing but the power control register in suspend mode and
loses its settings there, as the datasheet describes. It resets on a soft reset
only when both reset bits are set, clears the data ready flag when a data
register is read, returns to sleep mode after a forced measurement, and keeps
the last value of a disabled axis in its data registers.

The compensation checks compare the driver with numbers from Bosch's own sensor
API. `golden/bmm150-golden.c` feeds made-up trim bytes and raw register bytes
into Bosch's code, and `golden-vectors.toit` holds what came back. The same
file checks how the driver decodes the trim bytes and the raw counts. Regenerating
it needs Bosch's API files (`bmm150.c`, `bmm150.h` and `bmm150_defs.h`) in
`.reference/` at the root of the package, and then:

```
cd golden
gcc -std=gnu99 -I../../.reference -o bmm150-golden bmm150-golden.c -lm
./bmm150-golden > ../golden-vectors.toit
```

The vectors use Bosch's floating-point code, which computes in 32-bit floats.
The test allows 0.01 µT of difference. Bosch's code returns 0.0 for an axis that
is out of range. The driver throws instead, so the golden cases leave that
branch out and the mock test covers it separately.

The test exits with a non-zero code when a check fails, so it can run in CI.

`calibration-test.toit` checks the calibration maths without any hardware. It
builds readings from a sphere with a known offset and known axis sensitivities,
and checks that the calibrator finds them again.

## On the board

```
jag run bmm150-hardware-test.toit
```

The board needs to be kept still and away from motors, magnets and steel while
the test runs. The test checks the chip ID, the chip's own self-test, the field and Hall resistance
ranges, every rate and preset, the measured rate at seven rates, the forced
measurement time against the datasheet formula, the noise of every preset
against the datasheet, forced mode, suspend and wake, soft reset and axis
switching.

One check settles an open question. The datasheet's text for the Z repetitions
register disagrees with its own preset table. The test sets Z to 81
repetitions (register value 40), times a forced measurement, and compares the
time with both readings. It fails if the chip follows the register text. The
result is printed, and the numbers are worth a look even when the check passes.

If the chip's DRDY pin or INT pin is wired to the ESP32, the test also watches
the pin. `DRDY-PIN` and `INT-PIN` at the top of the file hold the ESP32 pins
they are wired to. Both are `null` by default, which skips the pin checks. The
DRDY checks cover:

- the pin staying low while the output is off,
- the pin going high with a measurement and low again when the data is read,
- active-low polarity,
- the pulse count over three seconds against the data rate.

The INT checks use a high threshold of -128 and a low threshold of 127, which
the field exceeds on every axis unless a strong magnet is near, so no hands-on
step is needed:

- the pin staying low while the INT output is off,
- latched mode, where the pin rises and stays high until the status is read,
- non-latched mode, where the pin follows the condition,
- the low threshold,
- active-low polarity.

Setting `USE-SPI` to `true` at the top of the file runs the same checks over
4-wire SPI. `SPI-CLOCK-PIN`, `SPI-MOSI-PIN`, `SPI-MISO-PIN` and `SPI-CS-PIN` name
the ESP32 pins, and the chip's PS pin needs to be tied to GND. The I2C address
check does not apply then. Most checks are about the chip and do not depend on
the bus, so a failure that appears only over SPI points at the SPI path. The
mock test cannot show that, because it replaces the bus.

Each line ends in PASS, FAIL, WARN or SKIP. A FAIL points at the driver, the
wiring or the chip. A WARN means a value looks odd without being wrong, usually
because of the surroundings. Limits from the datasheet are named in the source.
The others are choices made for this test and are marked as such at the top of
the file.

Setting `ROTATE-TEST` to `true` adds a hands-on check. It asks for the board to
be turned through every orientation for 20 seconds, then compares how constant the
field strength stays with and without a calibration made from the same run. It
also prints that calibration, which is a starting point for a real one.

The hardware test has not been run on a real chip yet. Its checks were tried
against the simulated chip, where only the two timing checks fail, because the
simulated measurement takes no time.
