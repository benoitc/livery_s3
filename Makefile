.PHONY: compile eunit ct test check garage-up garage-down dialyzer xref lint fmt clean

compile:
	rebar3 compile

eunit:
	rebar3 eunit

ct:
	rebar3 ct

## Bring Garage up, run the integration suite, tear Garage down.
test: garage-up
	-rebar3 ct --suite test/livery_s3_garage_SUITE
	$(MAKE) garage-down

garage-up:
	./test/docker/garage-up.sh

garage-down:
	./test/docker/garage-down.sh

dialyzer:
	rebar3 dialyzer

xref:
	rebar3 xref

lint:
	rebar3 lint

fmt:
	rebar3 fmt --check

## Full offline gate: build, static checks, style, unit tests.
check: compile xref dialyzer lint fmt eunit

clean:
	rebar3 clean
