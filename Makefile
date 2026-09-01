.PHONY: demo reset-demo test audit

demo:
	./scripts/demo.sh

reset-demo:
	./scripts/reset-demo.sh

test:
	./scripts/check.sh

audit:
	./scripts/public-release-audit.sh
