// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import font show Font
import gpio
import i2c
import math
import pixel-display show *
import pixel-display.element show CustomElement
import pixel-display.two-color show WHITE BLACK
import ssd1306 show Ssd1306

/**
Drawing helpers shared by compass-display.toit and calibrate.toit.

They are written for a 128x64 monochrome SSD1306 or SSD1308 on I2C. The
  pixel_display package has no line call, so the lines here are drawn pixel by
  pixel with Bresenham's algorithm.
*/

SDA-PIN ::= 21
SCL-PIN ::= 20

// The size of the display, as the driver sees it, before any turn.
DISPLAY-WIDTH ::= 128
DISPLAY-HEIGHT ::= 64

/** Whether a $rotation of 90 or 270 degrees gives a tall picture. */
is-portrait rotation/int -> bool:
  return rotation == 90 or rotation == 270

/** The width of the picture in pixels after the $rotation. */
picture-width rotation/int -> int:
  return (is-portrait rotation) ? DISPLAY-HEIGHT : DISPLAY-WIDTH

/** The height of the picture in pixels after the $rotation. */
picture-height rotation/int -> int:
  return (is-portrait rotation) ? DISPLAY-WIDTH : DISPLAY-HEIGHT

/**
Opens the I2C bus on $SDA-PIN and $SCL-PIN.

The sensor and the display share this bus. Their addresses differ, so they
  do not clash.
*/
open-bus -> i2c.Bus:
  return i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=400_000

/**
Returns a display for the SSD1306 on the $bus, or throws if none answers.

The $rotation turns the picture clockwise by 0, 90, 180 or 270 degrees. 0 is
  the orientation that these examples used before the setting existed. If the
  picture is turned, the other values may fix it. With 90 or 270 the picture
  is tall, with 64 pixels across and 128 down, and the examples lay
  themselves out to match.

The $flip option mirrors the picture top to bottom in the driver's own frame.
  Some display modules need it. It fixes a picture that is a mirror image,
  which turning cannot do.

Swapped black and white are fixed by adding `--inverse` to the driver call
  below. That is the driver's option, and it is different from the turn.
*/
open-display bus/i2c.Bus --rotation/int=0 --flip/bool=false -> PixelDisplay:
  if not [0, 90, 180, 270].contains rotation:
    throw "Display rotation must be 0, 90, 180 or 270, but was $rotation"
  if not (bus.test Ssd1306.I2C-ADDRESS):
    throw "No SSD1306 display found on the bus. Check the wiring."
  driver := Ssd1306.i2c (bus.device Ssd1306.I2C-ADDRESS) --flip=flip
  return display-for driver rotation

/**
Returns a display on the $driver, with the picture turned by the $rotation.

The pixel_display package turns a picture with two options. A portrait picture
  is turned a quarter, and `--inverted` turns it a further half. The pairs
  below were found by drawing each rotation and comparing the results.
*/
display-for driver/AbstractDriver rotation/int -> PixelDisplay:
  portrait := is-portrait rotation
  inverted := rotation == 0 or rotation == 270
  return PixelDisplay.two-color --portrait=portrait --inverted=inverted driver

/** Draws a one pixel dot. */
draw-dot_ canvas/Canvas x/int y/int -> none:
  canvas.rectangle x y --w=1 --h=1 --color=WHITE

/** Draws a line from ($x0, $y0) to ($x1, $y1) in white. */
draw-line_ canvas/Canvas x0/int y0/int x1/int y1/int -> none:
  x := x0
  y := y0
  dx := (x1 - x0).abs
  dy := -(y1 - y0).abs
  step-x := x0 < x1 ? 1 : -1
  step-y := y0 < y1 ? 1 : -1
  error := dx + dy
  while true:
    draw-dot_ canvas x y
    if x == x1 and y == y1: break
    doubled := 2 * error
    if doubled >= dy:
      error += dy
      x += step-x
    if doubled <= dx:
      error += dx
      y += step-y

/**
A compass dial with a needle.

The needle points at magnetic north as seen from the board. The top of the
  dial stands for the board's +X direction, and the dial assumes the board is
  level with the chip's Z axis pointing up. Both of those are assumptions,
  and the real axis directions depend on how the chip sits on the breakout.
  The `rotate-degrees` argument of $update turns the dial until it matches
  the board.
*/
class CompassView extends CustomElement:
  size_/int
  needle-x_/int := 0
  needle-y_/int := 0
  has-reading_/bool := false

  type -> string: return "compass-view"

  constructor --x/int=0 --y/int=0 --size/int=64:
    size_ = size
    super --x=x --y=y --w=size --h=size

  /**
  Moves the needle for a field of $field-x and $field-y microtesla.

  The $rotate-degrees turns the whole dial, clockwise.
  */
  update field-x/num field-y/num --rotate-degrees/num=0 -> none:
    if field-x == 0 and field-y == 0: return
    // North sits at atan2(y, x) counterclockwise from the board's +X axis,
    // which is the same angle clockwise on the other side of the dial.
    north := math.atan2 field-y field-x
    angle := (rotate-degrees * math.PI / 180.0) - north
    length := (size_ / 2) - 4
    needle-x_ = ((math.sin angle) * length).round
    needle-y_ = (-(math.cos angle) * length).round
    has-reading_ = true
    invalidate

  custom-draw canvas/Canvas -> none:
    centre := size_ / 2
    radius := centre - 1
    // The dial: 48 dots round the edge, with a longer tick at the top.
    48.repeat:
      angle := it * 2.0 * math.PI / 48.0
      draw-dot_ canvas
          centre + ((math.sin angle) * radius).round
          centre - ((math.cos angle) * radius).round
    draw-line_ canvas centre 0 centre 3
    if not has-reading_: return
    // The needle, drawn two pixels wide, with a short tail on the other side.
    draw-line_ canvas centre centre (centre + needle-x_) (centre + needle-y_)
    draw-line_ canvas (centre + 1) centre (centre + needle-x_ + 1) (centre + needle-y_)
    draw-line_ canvas centre centre (centre - needle-x_ / 4) (centre - needle-y_ / 4)
    // A small box at the tip marks which end is north.
    canvas.rectangle (centre + needle-x_ - 1) (centre + needle-y_ - 1) --w=3 --h=3 --color=WHITE

/**
A scatter plot of the most recent X and Y readings.

X runs to the right and Y runs up. The cross marks zero field. While the
  board turns flat on a table, the dots trace a ring. A ring that is centred
  on the cross means the offset is small. A ring that sits off to one side
  shows the offset the calibration has to remove. The plot only shows
  the X and Y axes, so it says nothing about Z.
*/
class ScatterView extends CustomElement:
  width_/int
  height_/int
  range_/float
  rotate-degrees_/int
  mirror_/bool
  points-x_/List
  points-y_/List
  next_/int := 0
  filled_/int := 0

  type -> string: return "scatter-view"

  /**
  Creates a scatter plot of $width by $height pixels.

  The edge of the plot stands for $range microtesla from zero. The plot keeps
    the latest $keep points.

  The plot normally shows the chip's X axis to the right and its Y axis up.
    With $mirror the Y axis is reversed first. Then $rotate-degrees turns the
    plot clockwise by 0, 90, 180 or 270 degrees. This changes the plot only,
    not the rest of the picture.
  */
  constructor
      --x/int=64
      --y/int=0
      --width/int=64
      --height/int=48
      --range/num=80
      --keep/int=60
      --rotate-degrees/int=0
      --mirror/bool=false:
    if not [0, 90, 180, 270].contains rotate-degrees:
      throw "rotate-degrees must be 0, 90, 180 or 270"
    width_ = width
    height_ = height
    range_ = range.to-float
    rotate-degrees_ = rotate-degrees
    mirror_ = mirror
    points-x_ = List keep: 0
    points-y_ = List keep: 0
    super --x=x --y=y --w=width --h=height

  /** Adds a reading of $field-x and $field-y microtesla. */
  add field-x/num field-y/num -> none:
    half-w := width_ / 2
    half-h := height_ / 2
    plot-x := field-x
    plot-y := mirror_ ? -field-y : field-y
    // The turn is clockwise on the plot, where X is right and Y is up.
    if rotate-degrees_ == 90:
      plot-x = plot-y
      plot-y = -field-x
    else if rotate-degrees_ == 180:
      plot-x = -plot-x
      plot-y = -plot-y
    else if rotate-degrees_ == 270:
      plot-x = -plot-y
      plot-y = field-x
    points-x_[next_] = half-w + ((plot-x / range_) * half-w).round
    points-y_[next_] = half-h - ((plot-y / range_) * half-h).round
    next_ = (next_ + 1) % points-x_.size
    if filled_ < points-x_.size: filled_++
    invalidate

  /** Removes all points. */
  clear -> none:
    next_ = 0
    filled_ = 0
    invalidate

  custom-draw canvas/Canvas -> none:
    // A frame, and a cross at zero field.
    draw-line_ canvas 0 0 (width_ - 1) 0
    draw-line_ canvas 0 (height_ - 1) (width_ - 1) (height_ - 1)
    draw-line_ canvas 0 0 0 (height_ - 1)
    draw-line_ canvas (width_ - 1) 0 (width_ - 1) (height_ - 1)
    centre-x := width_ / 2
    centre-y := height_ / 2
    draw-line_ canvas (centre-x - 3) centre-y (centre-x + 3) centre-y
    draw-line_ canvas centre-x (centre-y - 3) centre-x (centre-y + 3)
    filled_.repeat:
      px := points-x_[it]
      py := points-y_[it]
      if 1 <= px < width_ - 1 and 1 <= py < height_ - 1:
        draw-dot_ canvas px py
    // The newest point is drawn larger.
    if filled_ > 0:
      newest := (next_ - 1 + points-x_.size) % points-x_.size
      px := points-x_[newest]
      py := points-y_[newest]
      if 1 <= px < width_ - 2 and 1 <= py < height_ - 2:
        canvas.rectangle px py --w=2 --h=2 --color=WHITE

/** Returns a style for small white text. */
text-style -> Style:
  return Style --color=WHITE --font=(Font.get "sans10")
