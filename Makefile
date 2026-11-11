APP := build/xcode/Build/Products/Debug/Squelch.app

.PHONY: project build run selftest release install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -quiet -project Squelch.xcodeproj -scheme Squelch -configuration Debug \
		-derivedDataPath build/xcode -allowProvisioningUpdates build

# 不開視窗，實際連 YouTube 跑一次核心流程（清單、音軌、分段播放、跳轉、倍速、存檔）。
selftest: build
	$(APP)/Contents/MacOS/Squelch --selftest

run: build
	open $(APP)

# 公證版：make release VERSION=0.1.0 && make install VERSION=0.1.0
release:
	scripts/release.sh $(VERSION)

install:
	scripts/install.sh $(VERSION)

clean:
	rm -rf build Squelch.xcodeproj
