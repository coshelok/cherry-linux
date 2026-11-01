BUILD_DIR ?= build
export BUILD_DIR

.PHONY: all build run test smoke smoke-iso clean
all: build
build:
	./build.sh
run:
	./run.sh
test:
	bash -n build.sh rootfs.sh run.sh scripts/*.sh
	sh -n scripts/live-login utils/chepm utils/cherryfetch utils/cherry-help utils/cherry-status
	gcc -std=gnu11 -Wall -Wextra -Wpedantic -Werror -fsyntax-only src/boot_init.c src/init.c src/shutdown.c
	python3 -m unittest discover -s tests -v
smoke:
	python3 tests/smoke.py --build-dir "$(BUILD_DIR)"
	python3 tests/tls.py --build-dir "$(BUILD_DIR)"
	python3 tests/console.py --build-dir "$(BUILD_DIR)"
smoke-iso:
	python3 tests/iso_boot.py --build-dir "$(BUILD_DIR)"
clean:
	python3 scripts/clean.py "$(BUILD_DIR)"
