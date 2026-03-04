default: build

set shell := ["bash", "-c"]
set windows-shell := ["powershell", "-NoProfile", "-Command"]

ext := if os() == "windows" { ".exe" } else { "" }

build:
	odin build . -out:suite{{ext}} -o:speed

debug:
	odin build . -out:suite{{ext}} -debug

clean:
	rm -f suite{{ext}}

install: build
	cp suite{{ext}} ~/.local/bin/suite{{ext}}
