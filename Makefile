.PHONY: test-fast test-package test-hosted test-e2e test-controls test-full

# FILTER is a SwiftPM regex for fast/package, an Xcode class/method for other profiles.
test-fast:
	python3 scripts/test.py fast $(if $(FILTER),--filter '$(FILTER)')

test-package:
	python3 scripts/test.py package $(if $(FILTER),--filter '$(FILTER)')

test-hosted:
	python3 scripts/test.py hosted $(if $(FILTER),--filter '$(FILTER)')

test-e2e:
	python3 scripts/test.py e2e $(if $(FILTER),--filter '$(FILTER)')

test-controls:
	python3 scripts/test.py controls $(if $(FILTER),--filter '$(FILTER)')

test-full:
	python3 scripts/test.py full --base '$(or $(BASE),HEAD)'
