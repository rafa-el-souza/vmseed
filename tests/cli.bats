#!/usr/bin/env bats
# Dispatch, global option parsing, and the per-command config gate.

load helpers

@test "help: exits 0 and documents the three commands" {
  run bash "$SCRIPT" help
  assert_success
  assert_contains "build"
  assert_contains "boot"
  assert_contains "run"
  assert_contains "MODE"
}

@test "help: -h and --help are aliases" {
  run bash "$SCRIPT" -h
  assert_success
  run bash "$SCRIPT" --help
  assert_success
}

@test "dispatch: no subcommand defaults to help" {
  run bash "$SCRIPT"
  assert_success
  assert_contains "Usage:"
}

@test "dispatch: an unknown subcommand is refused" {
  run bash "$SCRIPT" frobnicate
  assert_failure
  assert_contains "unknown command 'frobnicate'"
}

@test "--config: refuses to be the last word with no file after it" {
  run bash "$SCRIPT" --config
  assert_failure
  assert_contains "--config requires a file argument"
}

@test "--config=FILE: the joined form is accepted too" {
  local conf; conf="$(mkconf)"
  run bash "$SCRIPT" "--config=$conf" build
  assert_success
}

@test "--: everything after the terminator is a positional, not an option" {
  local conf; conf="$(mkconf)"
  run bash "$SCRIPT" --config "$conf" -- build
  assert_success
}

# build/boot/run cannot run without a config; help can.

@test "build: requires --config" {
  run bash "$SCRIPT" build
  assert_failure
  assert_contains "'--config <file>' is required for the 'build' command"
}

@test "boot: requires --config" {
  run bash "$SCRIPT" boot
  assert_failure
  assert_contains "'--config <file>' is required for the 'boot' command"
}

@test "run: requires --config" {
  run bash "$SCRIPT" run
  assert_failure
  assert_contains "'--config <file>' is required for the 'run' command"
}

@test "build: requires OVERLAY_IMAGE_DIR (it has no default)" {
  local conf; conf="$(mkconf_raw "BASE_IMAGE_DIR=$TMP/base")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "OVERLAY_IMAGE_DIR is required"
}

@test "run: requires BASE_IMAGE_DIR (it has no default)" {
  local conf; conf="$(mkconf_raw "OVERLAY_IMAGE_DIR=$TMP/overlay")"
  run bash "$SCRIPT" --config "$conf" run
  assert_failure
  assert_contains "BASE_IMAGE_DIR is required"
}
