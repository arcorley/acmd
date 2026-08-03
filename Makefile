.PHONY: build test app dmg notarized-dmg run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

dmg:
	./Scripts/build-dmg.sh

notarized-dmg:
	ACMD_NOTARY_PROFILE="$${ACMD_NOTARY_PROFILE:-ACMD-notary}" ./Scripts/build-dmg.sh

run:
	swift run ACMD

clean:
	swift package clean
