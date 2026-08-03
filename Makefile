.PHONY: build test app dmg run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

dmg:
	./Scripts/build-dmg.sh

run:
	swift run ACMD

clean:
	swift package clean
