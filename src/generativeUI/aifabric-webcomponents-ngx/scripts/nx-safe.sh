#!/bin/sh
set -eu

export NX_DAEMON="${NX_DAEMON:-false}"
export NX_ISOLATE_PLUGINS="${NX_ISOLATE_PLUGINS:-false}"
export NX_NATIVE_COMMAND_RUNNER="${NX_NATIVE_COMMAND_RUNNER:-false}"

exec ./node_modules/.bin/nx "$@"
