#===============================================================================
# Direct MPAS restart remapper
#
# Environment:
#   go-oper
#
# Usage:
#   make
#   make check
#   make clean
#===============================================================================

.RECIPEPREFIX := >

FC      := ftn
TARGET  := mpas_remap_state
SOURCE  := mpas_remap_state_v3_restart_fastio.F90

NF_FFLAGS := $(shell nf-config --fflags)
NF_PREFIX := $(shell nf-config --prefix)
NC_LIBDIR := $(shell nc-config --libdir)

FFLAGS := -O3 -qopenmp

LDFLAGS := -L$(NF_PREFIX)/lib \
           -L$(NC_LIBDIR) \
           -Wl,-rpath,$(NF_PREFIX)/lib \
           -Wl,-rpath,$(NC_LIBDIR)

LIBS := -lnetcdff -lnetcdf -lm

.PHONY: all check clean

all: $(TARGET)

$(TARGET): $(SOURCE)
>$(FC) $(FFLAGS) $(NF_FFLAGS) $< $(LDFLAGS) $(LIBS) -o $@

check: $(TARGET)
>ldd ./$(TARGET) | grep -E 'netcdf|hdf5|svml|imf|iomp|not found' || true

clean:
>rm -f $(TARGET) *.o *.mod
