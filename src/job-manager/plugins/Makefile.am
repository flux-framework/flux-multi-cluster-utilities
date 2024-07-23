AM_CFLAGS = \
	$(WARNING_CFLAGS) \
	$(CODE_COVERAGE_CFLAGS) \
    $(FLUX_CORE_CFLAGS) \
    $(JANSSON_CFLAGS)

AM_LDFLAGS = \
	$(CODE_COVERAGE_LIBS)

jobtapdir = \
    $(fluxlibdir)/job-manager/plugins/

jobtap_LTLIBRARIES = \
	delegate.la

delegate_la_SOURCES = \
	delegate.c

delegate_la_LDFLAGS = \
	$(AM_LDFLAGS) \
	-module \
	-avoid-version

delegate_la_LIBADD= \
    $(FLUX_CORE_LIBS) \
    $(JANSSON_LIBS)
