APP := build/Perch.app

.PHONY: build debug run install uninstall icon test clean

build:
	@./scripts/build-app.sh

debug:
	@CONFIG=debug ./scripts/build-app.sh

run: build
	@pkill -x Perch 2>/dev/null || true
	@open $(APP)

install: build
	@pkill -x Perch 2>/dev/null || true
	@rm -rf /Applications/Perch.app
	@cp -R $(APP) /Applications/Perch.app
	@open /Applications/Perch.app
	@echo "✓ Installed to /Applications/Perch.app"

uninstall:
	@pkill -x Perch 2>/dev/null || true
	@rm -rf /Applications/Perch.app
	@echo "✓ Removed /Applications/Perch.app (remove the sudoers rule from Perch Settings first, or: sudo rm /etc/sudoers.d/perch)"

icon:
	@./scripts/make-icon.sh

test:
	@swift test

clean:
	@rm -rf .build build
