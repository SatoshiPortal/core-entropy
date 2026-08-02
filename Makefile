CXX      ?= c++
CXXSTD   ?= -std=c++20
OPT      ?= -O2 -g
WARN     ?= -Wall -Wextra -Wno-unused-parameter
INCLUDES := -Ishim -Icore -Isrc
# gc-sections lets the linker drop GetDevURandom(), which Core compiles as
# [[maybe_unused]] even though the build config makes it unreachable.
CXXFLAGS ?= $(CXXSTD) $(OPT) $(WARN) $(INCLUDES) -fPIC -ffunction-sections -fdata-sections

CORE_SRC := \
  core/random.cpp \
  core/clientversion.cpp \
  core/randomenv.cpp \
  core/crypto/chacha20.cpp \
  core/crypto/sha256.cpp \
  core/crypto/sha512.cpp \
  core/crypto/hex_base.cpp \
  core/support/cleanse.cpp \
  core/support/lockedpool.cpp \
  core/sync.cpp \
  core/logging.cpp \
  core/uint256.cpp \
  core/util/check.cpp \
  core/util/strencodings.cpp \
  core/util/string.cpp \
  core/util/time.cpp \
  core/util/threadnames.cpp \
  core/util/syserror.cpp \
  core/util/fs.cpp

OWN_SRC  := src/core_entropy.cpp
SRC      := $(CORE_SRC) $(OWN_SRC)
OBJ      := $(patsubst %.cpp,build/%.o,$(SRC))

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHLIB   := build/libcore_entropy.dylib
  LDFLAGS += -dynamiclib -Wl,-dead_strip
else
  SHLIB   := build/libcore_entropy.so
  LDFLAGS += -shared -Wl,--gc-sections
endif

.PHONY: all lib test clean verify
all: lib

lib: $(SHLIB)

$(SHLIB): $(OBJ)
	$(CXX) $(LDFLAGS) -o $@ $^

build/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

test: $(SHLIB)
	$(CXX) $(CXXSTD) $(OPT) $(INCLUDES) tests/harness.cpp -o build/harness \
	  -Lbuild -lcore_entropy -Wl,-rpath,@loader_path
	./build/harness

verify:
	@bash scripts/verify_provenance.sh

clean:
	rm -rf build
