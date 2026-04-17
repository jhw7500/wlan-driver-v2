#
# File : mlanconfig/Makefile
#
# Copyright 2008-2022 NXP

# Path to the top directory of the mlandriver distribution
PATH_TO_TOP = ../..

# Determine how we should copy things to the install directory
ABSPATH := $(filter /%, $(INSTALLDIR))
RELPATH := $(filter-out /%, $(INSTALLDIR))
INSTALLPATH := $(ABSPATH)
ifeq ($(strip $(INSTALLPATH)),)
INSTALLPATH := $(PATH_TO_TOP)/$(RELPATH)
endif

# Override CFLAGS for application sources, remove __ kernel namespace defines
CFLAGS := $(filter-out -D__%, $(ccflags-y))
# remove KERNEL include dir
CFLAGS := $(filter-out -I$(KERNELDIR)%, $(CFLAGS))

# -----------------------------------------------------------------------------
# Yocto SDK/크로스 환경 보강
# - CC가 --sysroot를 포함하지 않으면 강제로 붙여줌
# - CFLAGS/LDFLAGS에도 --sysroot 보강
# -----------------------------------------------------------------------------
# CC가 비어있거나(--sysroot 미포함)면 SDK sysroot를 붙인다
ifneq (,$(findstring --sysroot,$(CC)))
  # CC already has --sysroot (OK)
else
  ifneq ($(strip $(SDKTARGETSYSROOT)),)
    CC := $(if $(CC),$(CC),$(CROSS_COMPILE)gcc) --sysroot=$(SDKTARGETSYSROOT)
  endif
endif

# CFLAGS/LDFLAGS에 sysroot가 없다면 보강
ifneq ($(strip $(SDKTARGETSYSROOT)),)
  ifeq (,$(findstring --sysroot,$(CFLAGS)))
    CFLAGS += --sysroot=$(SDKTARGETSYSROOT)
  endif
  ifeq (,$(findstring --sysroot,$(LDFLAGS)))
    LDFLAGS += --sysroot=$(SDKTARGETSYSROOT)
  endif
endif

# 기본 최적화/안전 플래그(필요 시 조정)
CFLAGS += -O2 -pipe

#
# List of application executables to create
#
libobjs:= mlanconfig.o mlanhostcmd.o mlanmisc.o
exectarget=mlanconfig
TARGETS := $(exectarget)

#
# Make target rules
#

# All rule compiles list of TARGETS using builtin program target from src rule
all :
$(exectarget): $(libobjs)
	$(CC) $(CFLAGS) $(libobjs) -o $(exectarget)

# Update any needed TARGETS and then copy to the install path
build appsbuild install: $(TARGETS)
	@cp -rf config $(INSTALLPATH)

clean:
	@rm -f $(exectarget)
	@rm -f *.o

distclean: clean
	@rm -f *~ core
	@rm -f tags
