APP_NAME = Marina
BUILD_DIR = build
APP = $(BUILD_DIR)/$(APP_NAME).app
BIN = .build/release/$(APP_NAME)
# assembled + signed off the file-provider volume, then copied into build/
STAGE = /tmp/marina-bundle/$(APP_NAME).app
# the installer's payload root, and where the component package is staged
PKG_ROOT = /tmp/marina-pkg-root
PKG_STAGE = /tmp/marina-pkg-stage
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
PKG = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg
# macOS pins file-access permissions (Desktop, Documents, …) to the code
# signature. An ad-hoc signature changes with every build, so every rebuild used
# to throw the grants away and prompt again. Signing with a self-signed identity
# keeps the designated requirement — and therefore the permissions — stable.
# Create it once with Support/make-signing-cert.sh; without it, ad-hoc is used.
SIGN_ID = Marina Dev Signing

.PHONY: build release app run pkg clean

build:
	swift build

release:
	swift build -c release

app: release
	@# The bundle is assembled and signed outside the project: Desktop is a
	@# file-provider volume that keeps putting com.apple.FinderInfo back on the
	@# bundle root, and codesign refuses to sign anything carrying it. Stripping
	@# it in place loses the race — /tmp does not add it in the first place.
	rm -rf $(STAGE) $(APP)
	mkdir -p $(STAGE)/Contents/MacOS $(STAGE)/Contents/Resources $(BUILD_DIR)
	cp -X $(BIN) $(STAGE)/Contents/MacOS/$(APP_NAME)
	cp -X Support/Info.plist $(STAGE)/Contents/Info.plist
	@if ls .build/release/*.bundle >/dev/null 2>&1; then \
		cp -RX .build/release/*.bundle $(STAGE)/Contents/Resources/; \
	fi
	cat Support/Marina.icns > $(STAGE)/Contents/Resources/Marina.icns
	@# the ⌘3 viewer's markdown and code page — see Support/Viewer/vendor/PROVENANCE.md
	cp -RX Support/Viewer $(STAGE)/Contents/Resources/Viewer
	@find $(STAGE) -exec xattr -c {} \; 2>/dev/null; true
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)"; then \
		echo 'codesign --force --sign "$(SIGN_ID)" $(STAGE)'; \
		codesign --force --sign "$(SIGN_ID)" $(STAGE); \
	else \
		echo "warning: '$(SIGN_ID)' is not in the keychain — signing ad-hoc."; \
		echo "         macOS will then ask for file permissions again after every build;"; \
		echo "         run Support/make-signing-cert.sh once to stop that."; \
		codesign --force --sign - $(STAGE); \
	fi
	ditto --noextattr --norsrc $(STAGE) $(APP)
	codesign --verify --deep $(APP) && echo "Built $(APP)"

# Installer that puts Marina in ~/Applications — a per-user install, so it
# never asks for an admin password and never touches anyone else's account.
# The component still says /Applications; the distribution's enable_currentUserHome
# is what makes that path relative to the home directory.
#
# Unsigned: signing an installer needs a Developer ID Installer certificate from
# Apple, which the self-signed code-signing identity is not. The app inside keeps
# its own signature, so the permissions granted to it survive the move out of
# build/ — macOS matches those on the certificate, not the path.
pkg: app
	rm -rf $(PKG_ROOT) $(PKG_STAGE)
	mkdir -p $(PKG_ROOT) $(PKG_STAGE) $(BUILD_DIR)
	ditto --noextattr --norsrc $(APP) $(PKG_ROOT)/$(APP_NAME).app
	@# Turn bundle relocation OFF. Left on, the installer hunts down any existing
	@# org.fherwig.marina bundle — build/Marina.app, say — decides that is where
	@# the app really lives, and installs over it instead. It deleted the build
	@# tree's copy once already and left ~/Applications empty.
	pkgbuild --analyze --root $(PKG_ROOT) $(PKG_STAGE)/component.plist
	/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" $(PKG_STAGE)/component.plist
	pkgbuild --root $(PKG_ROOT) \
		--component-plist $(PKG_STAGE)/component.plist \
		--identifier org.fherwig.marina.pkg \
		--version $(VERSION) \
		--install-location /Applications \
		$(PKG_STAGE)/component.pkg
	sed 's/__VERSION__/$(VERSION)/' Support/distribution.xml > $(PKG_STAGE)/distribution.xml
	productbuild --distribution $(PKG_STAGE)/distribution.xml \
		--package-path $(PKG_STAGE) \
		$(PKG)
	@echo "Built $(PKG)"

icon:
	swift Support/gen-icon.swift /tmp/marina-icon-1024.png
	rm -rf /tmp/Marina.iconset && mkdir /tmp/Marina.iconset
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/marina-icon-1024.png --out /tmp/Marina.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s*2)); \
		sips -z $$d $$d /tmp/marina-icon-1024.png --out /tmp/Marina.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/Marina.iconset -o Support/Marina.icns
	@echo "Regenerated Support/Marina.icns"
	@echo "Built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) .build
