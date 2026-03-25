AM_CFLAGS = \
	$(WARNING_CFLAGS) \
	$(CODE_COVERAGE_CFLAGS)

AM_LDFLAGS = \
	$(CODE_COVERAGE_LIBS)

AM_CPPFLAGS = \
	-I$(top_srcdir) \
	$(FLUX_CORE_CFLAGS) \
	$(JANSSON_CFLAGS) \
	$(CODE_COVERAGE_CPPFLAGS)

noinst_LTLIBRARIES = libutil.la

libutil_la_SOURCES = \
	eventlog.h \
	eventlog.c \
	idf58.h
