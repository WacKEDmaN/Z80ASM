# emukeys.sh - source this for tools/emutest.sh key strings
# CPC key codes are Caprice32's CPC_KEYS enum values (src/keyboard.h),
# sent as "\a" followed by the code.
UP=$'\a\x78'; DN=$'\a\x75'; LT=$'\a\x76'; RT=$'\a\x77'; ESC=$'\a\x82'; RET=$'\n'
W=CAP32_DELAY; SHOT=CAP32_SCRNSHOT; QUIT=CAP32_EXIT
# rep TEXT N : TEXT repeated N times
rep() { local s=""; for ((i=0;i<$2;i++)); do s+="$1"; done; printf '%s' "$s"; }
# example: scan the error test disc in drive B and screenshot the map
#   . tools/emukeys.sh
#   tools/emutest.sh /tmp/shots "build/disctest.dsk build/tests/test_data_errors.dsk" \
#     "run\"disctest${RET}$(rep $W 4)1 $(rep $W 16)${SHOT}${W}${QUIT}"
