.PHONY: t
t:
	zig build test -fsummary -freference-trace
