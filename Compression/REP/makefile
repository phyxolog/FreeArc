include ../../common.mak

ALL: $(TEMPDIR)/C_REP.o $(TEMPDIR)/cels-rep.o

CODE_FLAGS  = -fno-exceptions -fno-rtti -Wall \
              -Wno-unknown-pragmas -Wno-sign-compare -Wno-conversion
OPT_FLAGS   = -O3 \
              -fomit-frame-pointer -fstrict-aliasing \
              -fforce-addr -funroll-loops
DEBUG_FLAGS = -g0
CFLAGS = $(CODE_FLAGS) $(OPT_FLAGS) $(DEBUG_FLAGS) $(DEFINES)

$(TEMPDIR)/C_REP.o: C_REP.cpp C_REP.h rep.cpp makefile ../MultiThreading.h
	$(GCC) -c $(CFLAGS) -o $*.o $<

$(TEMPDIR)/cels-rep.o: cels-rep.cpp rep.cpp makefile ../MultiThreading.h
	$(GCC) -c $(CFLAGS) -fexceptions -o $*.o $<
