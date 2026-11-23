#!/bin/sh
# ---------------------------------------------------------------------------
# add.sh — print the sum of its integer arguments.
#
#   sh add.sh 2 3 4   -> 9
#   sh add.sh         -> 0
#   sh add.sh 2 nine  -> stderr "add: not an integer: nine", exit 2
#
# POSIX sh only: no bashisms, no external tools. Under factory-probe/b it is a
# deliberately tiny target for the code factory's engine probe.
# ---------------------------------------------------------------------------
set -u

sum=0

for arg in "$@"; do
  # Split the optional sign from the digits so the digit test stays strict.
  case $arg in
    -[0-9]* | +[0-9]*)
      sign=${arg%"${arg#?}"}
      digits=${arg#?}
      ;;
    [0-9]*)
      sign=''
      digits=$arg
      ;;
    *)
      printf 'add: not an integer: %s\n' "$arg" >&2
      exit 2
      ;;
  esac

  case $digits in
    *[!0-9]*)
      printf 'add: not an integer: %s\n' "$arg" >&2
      exit 2
      ;;
  esac

  # Strip leading zeros: `$((08))` is an octal error in dash, and `10#` is a
  # bashism. A bare "0" is kept so the arithmetic below still has a number.
  while :; do
    case $digits in
      0?*) digits=${digits#0} ;;
      *) break ;;
    esac
  done

  if [ "$sign" = '-' ]; then
    sum=$((sum - digits))
  else
    sum=$((sum + digits))
  fi
done

printf '%s\n' "$sum"
exit 0
