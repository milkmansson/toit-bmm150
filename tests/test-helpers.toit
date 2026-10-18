// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
A small test runner shared by the mock and hardware tests.

It prints one line per check and a summary at the end. A check passes when its
  block returns, fails when it throws, and is skipped or warned about when the
  test asks for it.
*/
class TestRun:
  passed/int := 0
  failed/int := 0
  warned/int := 0
  skipped/int := 0
  failures/List := []

  /** Runs the $block as the check called $name. A throw counts as a failure. */
  check name/string [block] -> none:
    error := catch: block.call
    if error == null:
      passed++
      print "  PASS  $name"
    else:
      failed++
      failures.add name
      print "  FAIL  $name: $error"

  /** Records a result worth a look that should not fail the run. */
  warn name/string message/string -> none:
    warned++
    print "  WARN  $name: $message"

  /** Records that a check could not run, with the $reason. */
  skip name/string reason/string -> none:
    skipped++
    print "  SKIP  $name: $reason"

  /** Prints a heading line. */
  section title/string -> none:
    print ""
    print "== $title"

  /** Prints the summary, and exits with a non-zero code if anything failed. */
  finish -> none:
    print ""
    print "$passed passed, $failed failed, $warned warnings, $skipped skipped."
    if failed > 0:
      print "Failed checks:"
      failures.do: print "  - $it"
      exit 1

// The assertions below throw, so that a failed check is recorded and the run
// carries on. The assertions in the SDK's expect library exit the program on
// the first failure.

/** Throws unless the $condition is true. */
require condition/bool --message/string="Condition was false" -> none:
  if not condition: throw message

/** Throws unless the $condition is false. */
require-not condition/bool --message/string="Condition was true" -> none:
  if condition: throw message

/**
Throws unless $actual equals $expected.

Adds the $message to the exception when there is one.
*/
require-equals expected actual --message/string?=null -> none:
  if expected != actual:
    detail := message ? " ($message)" : ""
    throw "Expected <$expected>, but was <$actual>$detail"

/** Throws unless $actual is within $tolerance of $expected. */
require-close expected/num actual/num tolerance/num what/string -> none:
  if (expected - actual).abs > tolerance:
    throw "$what: expected $expected, got $actual (tolerance $tolerance)"

/** Throws unless the two byte arrays hold the same bytes. */
require-bytes-equal expected/ByteArray actual/ByteArray -> none:
  if expected != actual: throw "Expected <$expected>, but was <$actual>"

/** Throws unless running the $block throws exactly the $expected value. */
require-throw expected [block] -> none:
  actual := catch: block.call
  if actual != expected: throw "Expected throw with <$expected>, but was <$actual>"
