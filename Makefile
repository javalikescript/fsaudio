
LUACLIBS := ../luaclibs

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	PLAT ?= linux
else
	PLAT ?= windows
endif

SO_windows=dll
EXE_windows=.exe
STATIC_FLAGS_windows=lua/src/wlua.res -mwindows

SO_linux=so
EXE_linux=
STATIC_FLAGS_linux=

SO := $(SO_$(PLAT))
EXE := $(EXE_$(PLAT))

release:
	$(MAKE) -C $(LUACLIBS) \
		STATIC_RESOURCES="-R ../fsaudio/assets ../fsaudio/htdocs -l ../fsaudio/fsaudio.lua" \
		LUAJLS=../luajls "STATIC_EXECUTE=require('fsaudio')" \
		STATIC_FLAGS="$(STATIC_FLAGS_$(PLAT))" static-full
	mv $(LUACLIBS)/dist/luajls$(EXE) fsaudio$(EXE)
