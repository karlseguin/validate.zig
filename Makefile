.PHONY: t
t:
	zig build test --summary all -freference-trace
