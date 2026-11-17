# build every program: hello, the C tests (plus host golden outputs) and CoreMark
all:
	$(MAKE) -C hello
	$(MAKE) -C tests all golden
	$(MAKE) -C coremark
clean:
	$(MAKE) -C hello clean
	$(MAKE) -C tests clean
	$(MAKE) -C coremark clean
	rm -f coremark/*.o
.PHONY: all clean
