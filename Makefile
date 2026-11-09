.PHONY: compile eunit ct test test-rustfs test-all check garage-up garage-down rustfs-up rustfs-down \
	dialyzer xref lint fmt clean

compile:
	rebar3 compile

eunit:
	rebar3 eunit

ct:
	rebar3 ct

## Bring Garage up, run the integration suite, tear Garage down.
## The exit code of the suite is kept so a failure fails the target, after the
## store has been torn down either way.
test: garage-up
	@rc=0; LIVERY_S3_BACKEND=garage rebar3 ct --suite test/livery_s3_garage_SUITE || rc=$$?; \
	$(MAKE) garage-down; exit $$rc

## Same suite against RustFS, which implements features Garage lacks (tagging,
## anonymous access, SSE-S3/SSE-KMS) and enforces conditional writes.
test-rustfs: rustfs-up
	@rc=0; LIVERY_S3_BACKEND=rustfs \
	 LIVERY_S3_ENDPOINT=http://127.0.0.1:9000 \
	 LIVERY_S3_REGION=us-east-1 \
	 LIVERY_S3_ACCESS_KEY=rustfsadmin \
	 LIVERY_S3_SECRET_KEY=rustfsadmin \
	 LIVERY_S3_PUBLIC_BUCKET=livery-s3-public \
	 rebar3 ct --suite test/livery_s3_garage_SUITE || rc=$$?; \
	$(MAKE) rustfs-down; exit $$rc

## Both integration targets, one after the other.
test-all: test test-rustfs

garage-up:
	./test/docker/garage-up.sh

garage-down:
	./test/docker/garage-down.sh

rustfs-up:
	./test/docker/rustfs-up.sh

rustfs-down:
	./test/docker/rustfs-down.sh

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
