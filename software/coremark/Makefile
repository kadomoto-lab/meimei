#
# CoreMark for the meimei SoC
#   make ITERATIONS=<n>   (default 2: a simulation-friendly run; CoreMark rules ask for >= 10 s)
#
ITERATIONS ?= 2
OPT ?= -O2
SRCS = core_list_join.c core_main.c core_matrix.c core_state.c core_util.c port/core_portme.c
XCFLAGS = -Iport -I. -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=1 -DTOTAL_DATA_SIZE=2000 \
          -DFLAGS_STR='"$(OPT) -march=rv64imfdc_zicsr"' -funroll-loops -fno-inline-functions-called-once -Wno-unused
include ../software_tools/Makefile.inc
