#
# Self-checking C tests: `make` builds build/<test>/{app.elf,app.dump,code.hex,data.hex};
# `make golden` runs the same sources on the host (x86-64 gcc) to produce build/<test>/golden.txt,
# which sim/run_tests.sh compares with the UART output of the RTL simulation.
#
TESTS = int_ops float_ops string_mem control platform
XCFLAGS = -ffp-contract=off
HOSTCC ?= gcc
HOSTCFLAGS = -O2 -DHOST -funsigned-char -ffp-contract=off -Ihost -Wall

all: $(TESTS:%=build/%/code.hex)
golden: $(TESTS:%=build/%/golden.txt)

build/%/code.hex: %.c test.h ../software_tools/Makefile.inc
	$(MAKE) -f ../software_tools/Makefile.inc SRCS=$< BUILD=build/$* XCFLAGS="$(XCFLAGS)" XLDFLAGS="-u _printf_float"

build/%/golden.txt: %.c test.h
	@mkdir -p build/$*
	$(HOSTCC) $(HOSTCFLAGS) -o build/$*/host $< -lm
	./build/$*/host > $@; echo "exit $$?" >> $@

clean:
	rm -rf build
.PHONY: all golden clean
