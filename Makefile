
LUACLIBS := ../luaclibs
FSAUDIO := ../fsaudio

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	PLAT ?= linux
else
	PLAT ?= windows
endif

EXE_windows=.exe
EXE_linux=
EXE := $(EXE_$(PLAT))

STATIC_FLAGS_windows=lua/src/wlua.res -mwindows
STATIC_FLAGS_linux=

release:
	$(MAKE) -C $(LUACLIBS) \
		STATIC_RESOURCES="-R $(FSAUDIO)/assets $(FSAUDIO)/htdocs -l $(FSAUDIO)/fsaudio.lua" \
		LUAJLS=luajls "STATIC_EXECUTE=require('fsaudio')" \
		STATIC_FLAGS="$(STATIC_FLAGS_$(PLAT))" static-full
	mv $(LUACLIBS)/dist/luajls$(EXE) fsaudio$(EXE)
