.PHONY: test test-server test-emacs dist clean

test: test-server test-emacs

test-server:
	cd server && go test ./...

test-emacs:
	./scripts/test-emacs.sh

dist:
	./scripts/build-dist.sh

clean:
	rm -f dist/rimgd-linux-amd64 dist/rimgd-linux-arm64 \
		dist/rvidd-linux-amd64 dist/rvidd-linux-arm64 dist/checksums.txt
