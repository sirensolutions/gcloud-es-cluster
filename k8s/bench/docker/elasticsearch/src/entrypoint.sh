#!/bin/bash
set -e

if [ "$1" = 'elasticsearch' ]; then
	set -- gosu elasticsearch "$@"
	ES_JAVA_OPTS="-Des.logger.level=$LOG_LEVEL -Xms$HEAP_SIZE -Xmx$HEAP_SIZE"  $@
else
	exec $@
fi
