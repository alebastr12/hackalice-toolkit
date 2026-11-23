#!/bin/sh
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/start.sh" stop
