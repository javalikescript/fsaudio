
LUACLIBS := ../luaclibs
FSAUDIO := ../fsaudio

PLAT ?= $(shell grep ^platform $(LUACLIBS)/dist/versions.txt | cut -f2)
TARGET_NAME ?= $(shell grep ^target $(LUACLIBS)/dist/versions.txt | cut -f2)

EXE_windows=.exe
EXE_linux=
EXE := $(EXE_$(PLAT))

ZIP_windows=.zip
ZIP_linux=.tar.gz
ZIP := $(ZIP_$(PLAT))

RELEASE_DATE = $(shell date '+%Y%m%d')
RELEASE_NAME ?= -$(TARGET_NAME).$(RELEASE_DATE)
RELEASE_FILES ?= fsaudio$(EXE) README.md

STATIC_FLAGS_windows=lua/src/wlua.res -mwindows
STATIC_FLAGS_linux=

release: bin release$(ZIP)

bin:
	$(MAKE) -C $(LUACLIBS) OPENSSL_LIBNAMES= OPENSSL_LIBS= \
		STATIC_RESOURCES="-R $(FSAUDIO)/assets $(FSAUDIO)/htdocs -l $(FSAUDIO)/fsaudio.lua" \
		LUAJLS=luajls "STATIC_EXECUTE=require('fsaudio')" \
		STATIC_FLAGS="$(STATIC_FLAGS_$(PLAT))" static-full
	mv $(LUACLIBS)/dist/luajls$(EXE) fsaudio$(EXE)

release.tar.gz:
	-rm fsaudio$(RELEASE_NAME).tar.gz
	tar --group=jls --owner=jls -zcvf fsaudio$(RELEASE_NAME).tar.gz $(RELEASE_FILES)

release.zip:
	-rm fsaudio$(RELEASE_NAME).zip
	zip -r fsaudio$(RELEASE_NAME).zip $(RELEASE_FILES)
