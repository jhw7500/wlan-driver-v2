# File : mlanevent/Makefile
#
# Copyright 2008-2022 NXP

# Path to the top directory of the wlan distribution
PATH_TO_TOP = ../..

ifeq ($(findstring IMX_ANDROID,$(ccflags-y)),IMX_ANDROID)
CC=/usr/local/arm/android-ndk-r23-beta5/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang
endif

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
# Platform-specific install suffix (moal/mlan/mlanutl과 동일한 패턴)
#   e.g. imx93 → mlanevent_imx93, imx8 → mlanevent_imx8
# 빌드 산출물 이름은 'mlanevent'로 유지하고, 설치 복사 단계에서만 suffix를 붙인다.
# -----------------------------------------------------------------------------
MOD_SUFFIX ?=

# ?= : Yocto SDK env (aarch64-poky-linux-*) 가 export 하는 값을 우선한다
STRIP ?= $(CROSS_COMPILE)strip
OBJCOPY ?= $(CROSS_COMPILE)objcopy

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

#CFLAGS += -DAP22 -fshort-enums
CFLAGS += -Wall
# 디버그 심볼 생성 — 설치 단계에서 strip + .debug 분리되므로 배포본 크기 무영향
CFLAGS += -g
#ECHO = @
ifeq (,$(findstring ANDROID_KERNEL, $(CFLAGS)))
LIBS=-lrt
endif



.PHONY: default tags all

OBJECTS = mlanevent.o
HEADERS = mlanevent.h

exectarget=mlanevent
TARGET := $(exectarget)

build appsbuild default: $(TARGET)
	@cp -f $(TARGET) $(INSTALLPATH)/$(exectarget)$(MOD_SUFFIX)
	$(OBJCOPY) --only-keep-debug $(INSTALLPATH)/$(exectarget)$(MOD_SUFFIX) $(INSTALLPATH)/$(exectarget)$(MOD_SUFFIX).debug
	$(STRIP) $(INSTALLPATH)/$(exectarget)$(MOD_SUFFIX)
	cd $(INSTALLPATH) && $(OBJCOPY) --add-gnu-debuglink=$(exectarget)$(MOD_SUFFIX).debug $(exectarget)$(MOD_SUFFIX)

all : tags default

$(TARGET): $(OBJECTS) $(HEADERS)
	$(ECHO)$(CC) $(LIBS) -o $@ $(OBJECTS)

%.o: %.c $(HEADERS)
	$(ECHO)$(CC) $(CFLAGS) -c -o $@ $<

tags:
	ctags -R -f tags.txt

distclean clean:
	$(ECHO)$(RM) $(OBJECTS) $(TARGET)
# 구 NXP 산출물명(mlanevent.exe) 잔재 제거 — 몇 릴리스 뒤 삭제 가능
	$(ECHO)$(RM) mlanevent.exe
	$(ECHO)$(RM) tags.txt

