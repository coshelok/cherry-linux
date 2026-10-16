VERSION := $(shell tr -d '[:space:]' < VERSION)
BUILD_DIR ?= build

.PHONY: all build run clean

all: build

build:
	./build.sh

run:
	./run.sh

clean:
	rm -rf $(BUILD_DIR)
